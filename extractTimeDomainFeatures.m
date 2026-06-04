function out = extractTimeDomainFeatures(varargin)
%EXTRACTTIMEDOMAINFEATURES Single entry for file selection + feature extraction.
%
% Mode A (interactive multi-file processing):
%   out = extractTimeDomainFeatures();
%
% Mode B (given file list):
%   out = extractTimeDomainFeatures(fileList);
%   fileList can be char/string/cellstr of WAV paths.
%
% Mode C (direct signal processing, original interface):
%   feat = extractTimeDomainFeatures(y, fs);
%
% Output:
%   - For Mode A/B: struct array with fields
%       file_path, decay_tau_s, T_eff_s, rms_energy, peak_time_s
%   - For Mode C: struct with fields
%       decay_tau_s, T_eff_s, rms_energy, peak_time_s

% Route by input pattern so users only need one function entry point.
if nargin == 0 || (nargin == 1 && (ischar(varargin{1}) || isstring(varargin{1}) || iscell(varargin{1})))
    out = processFilesMode(varargin{:});
    return;
end

% Keep compatibility with original signal interface y, fs.
if nargin >= 2
    y = varargin{1};
    fs = varargin{2};
    out = computeSignalFeatures(y, fs);
    return;
end

% Fallback for unsupported call signatures.
out = struct('decay_tau_s', NaN, 'T_eff_s', NaN, 'rms_energy', NaN, 'peak_time_s', NaN);
end

function results = processFilesMode(fileList)
% Use interactive file selection when caller does not provide file paths.
if nargin < 1 || isempty(fileList)
    [names, folder] = uigetfile({'*.wav;*.WAV', 'WAV Files (*.wav)'}, ...
        '选择一个或多个WAV文件', 'MultiSelect', 'on');

    % Return empty result if user cancels file selection.
    if isequal(names, 0)
        results = struct('file_path', {}, 'decay_tau_s', {}, 'T_eff_s', {}, ...
            'rms_energy', {}, 'peak_time_s', {});
        return;
    end

    % Normalize single/multiple selected names into a cell array.
    if ischar(names)
        names = {names};
    end
    fileList = fullfile(folder, names);
end

% Normalize input path list into a cell array for uniform iteration.
if ischar(fileList) || isstring(fileList)
    fileList = cellstr(fileList);
end

% Preallocate output struct array to hold file-wise feature results.
nFiles = numel(fileList);
results = repmat(struct('file_path', '', 'decay_tau_s', NaN, 'T_eff_s', NaN, ...
    'rms_energy', NaN, 'peak_time_s', NaN), nFiles, 1);

for k = 1:nFiles
    % Record source path for downstream traceability.
    results(k).file_path = char(fileList{k});

    % Read waveform and sampling rate from current WAV file.
    [x, fs] = audioread(results(k).file_path);

    % Convert to mono signal to match extractor interface expectations.
    if size(x, 2) > 1
        y = mean(x, 2);
    else
        y = x;
    end

    % Normalize peak amplitude to approximately one for consistent scaling.
    peak = max(abs(y));
    if isfinite(peak) && peak > eps
        y = y / peak;
    end

    % Extract requested time-domain decay features for this file.
    feat = computeSignalFeatures(y, fs);

    % Copy extracted metrics into per-file output record.
    results(k).decay_tau_s = feat.decay_tau_s;
    results(k).T_eff_s = feat.T_eff_s;
    results(k).rms_energy = feat.rms_energy;
    results(k).peak_time_s = feat.peak_time_s;
end
end

function feat = computeSignalFeatures(y, fs)
% Initialize all outputs to NaN for robust fail-safe behavior.
feat = struct('decay_tau_s', NaN, 'T_eff_s', NaN, 'rms_energy', NaN, 'peak_time_s', NaN);

% Basic input validity check: empty, too short, non-finite, or invalid sampling rate.
if isempty(y) || ~isvector(y) || numel(y) < 10 || ~isscalar(fs) || ~isfinite(fs) || fs <= 0
    return;
end

% Ensure column vector for consistent indexing behavior.
y = y(:);

% Reject all-zero or non-finite signals as invalid measurements.
if all(y == 0) || any(~isfinite(y))
    return;
end

% Compute absolute-amplitude envelope using 5 ms moving-average smoothing.
win = max(1, round(0.005 * fs));
env = movmean(abs(y), win);

% Guard against invalid envelope values before downstream computations.
if isempty(env) || any(~isfinite(env))
    return;
end

% Locate the envelope peak as the excitation reference point.
[peak_val_env, peak_idx_env] = max(env);

% Locate the absolute-signal peak for alignment quality control timing.
[~, peak_idx_abs] = max(abs(y));

% Peak time indicates onset alignment quality in seconds.
if fs > eps
    feat.peak_time_s = (peak_idx_abs - 1) / fs;
end

% RMS energy describes global signal energy under normalized amplitude.
feat.rms_energy = sqrt(mean(y .^ 2));

% Invalid or near-zero peak amplitude cannot support robust decay analysis.
if ~(isfinite(peak_val_env) && peak_val_env > eps)
    return;
end

% Effective duration is the total time where envelope exceeds 1% of peak.
mask_eff = env >= 0.01 * peak_val_env;
feat.T_eff_s = sum(mask_eff) / fs;

% Extract post-peak envelope segment to characterize exponential decay.
env_post = env(peak_idx_env:end);
if isempty(env_post)
    return;
end

% Determine valid decay interval up to first sample below 1% peak level.
first_below = find(env_post < 0.01 * peak_val_env, 1, 'first');
if isempty(first_below)
    end_idx = numel(env_post);
else
    end_idx = first_below;
end

% Take only the first 80% of valid decay to reduce noise-floor fitting bias.
fit_len = max(1, floor(0.8 * end_idx));
fit_seg = env_post(1:fit_len);

% Keep strictly positive and finite points for logarithmic linearization.
valid_pts = isfinite(fit_seg) & (fit_seg > 0);
fit_seg = fit_seg(valid_pts);

% Require sufficient samples to estimate a physically meaningful slope.
if numel(fit_seg) < 5
    return;
end

% Build time axis for regression of log-envelope versus time.
t = (0:numel(fit_seg)-1).' / fs;
log_env = log(fit_seg(:));

% Fit linear decay model in log domain with warning-safe fallback.
warnState = warning('off', 'all');
fit_ok = true;
try
    p = polyfit(t, log_env, 1);
catch
    fit_ok = false;
    p = [NaN, NaN];
end
warning(warnState);

% Convert fitted slope to decay time constant tau = -1/slope.
if ~fit_ok || any(~isfinite(p))
    return;
end

slope = p(1);
if slope >= 0 || abs(slope) < 1e-6 || abs(slope) <= eps
    return;
end

feat.decay_tau_s = -1 / slope;
if ~isfinite(feat.decay_tau_s) || feat.decay_tau_s <= 0
    feat.decay_tau_s = NaN;
end

if false
    % Self-test: synthesize an exponentially decaying pulse and extract features.
    fs_t = 48000;
    t_t = (0:fs_t-1).' / fs_t;
    y_t = sin(2*pi*1000*t_t) .* exp(-t_t/0.08);
    y_t = y_t / max(abs(y_t));
    feat_t = computeSignalFeatures(y_t, fs_t); %#ok<NASGU>
end
end
