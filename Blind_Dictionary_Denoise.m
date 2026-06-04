% =========================================================================
% 青铜器敲击声 - 粗对齐 + 盲字典去噪 + 精对齐 + 导出训练集 (最终最终版)
% 修复点：
% 1) 短音频自适应 STFT 参数
% 2) stft/istft 成对使用 + FrequencyRange='onesided'
% 3) 防止 rows/windowLength 冲突
% =========================================================================
clear; clc; close all;

%% =========================
% 1) 全局参数（建议只改这里）
% ==========================
% --- 截取窗口 ---
pre_peak_sec_coarse = 0.05;   % 粗对齐：峰前时长(s)
post_peak_sec_coarse = 1.00;  % 粗对齐：峰后时长(s)

pre_peak_sec_fine = 0.05;     % 精对齐：峰前时长(s)
post_peak_sec_fine = 1.00;    % 精对齐：峰后时长(s)

% --- 粗/精寻峰平滑 ---
env_smooth_sec_coarse = 0.003; % 3ms
env_smooth_sec_fine   = 0.005; % 5ms

% --- 盲字典（SVD低秩稀疏重构） ---
dict_energy_ratio = 0.90;      % 0.80~0.95 建议
win_len_default = 1024;
hop_len_default = 256;
nfft_default = 1024;
min_win_len = 64;              % 短音频兜底窗长

% --- 谱图导出 ---
db_range = 75;                 % dB动态范围
fmax_display = 8000;           % 谱图显示上限频率
image_dpi = 300;

% --- 输出控制 ---
save_wav = true;
save_png = true;
save_mat = true;

%% =========================
% 2) 选择输入文件
% ==========================
disp('请选择多个 WAV 文件（可按住 Ctrl 或 Shift 多选）...');
[fileList, pathName] = uigetfile('*.wav', '请选择WAV文件', 'MultiSelect', 'on');

if isequal(fileList, 0)
    disp('取消选择，程序结束。');
    return;
end

if ischar(fileList)
    fileList = {fileList};
end
numFiles = numel(fileList);

% 输出目录
out_dir = fullfile(pathName, 'Blind_Denoised_Aligned_Outputs');
if ~exist(out_dir, 'dir')
    mkdir(out_dir);
end

% 日志
log_file = fullfile(out_dir, 'pipeline_log.csv');
fid = fopen(log_file, 'w');
fprintf(fid, ['filename,fs,orig_len,coarse_peak_idx,coarse_start,coarse_end,', ...
              'K_atoms,energy_ratio_real,fine_peak_idx,fine_start,fine_end,', ...
              'final_len,stft_win,stft_hop,stft_nfft,status,message\n']);

disp(['共选择 ', num2str(numFiles), ' 个文件，开始处理...']);

%% =========================
% 3) 主循环
% ==========================
for i = 1:numFiles
    fileName = fileList{i};
    inputFile = fullfile(pathName, fileName);
    [~, baseName, ext] = fileparts(fileName);

    % 默认日志字段（失败时也能写）
    fs = 0; orig_len = 0;
    coarse_peak_idx = -1; coarse_start = -1; coarse_end = -1;
    K_atoms = -1; energy_ratio_real = 0;
    fine_peak_idx = -1; fine_start = -1; fine_end = -1;
    final_len = 0;
    win_len_eff = -1; hop_len_eff = -1; nfft_eff = -1;
    status = 'OK'; msg = '';

    fprintf('\n[%d/%d] %s\n', i, numFiles, fileName);

    try
        %% ---------- A. 读取与预处理 ----------
        [x, fs] = audioread(inputFile);
        if size(x,2) > 1
            x = mean(x, 2); % 转单声道
        end
        x = x(:);
        orig_len = length(x);

        if isempty(x)
            error('音频为空');
        end

        %% ---------- B. 第一次：时域粗对齐截取 ----------
        env_win_coarse = max(1, round(env_smooth_sec_coarse * fs));
        env_coarse = movmean(abs(x), env_win_coarse);
        [~, coarse_peak_idx] = max(env_coarse);

        pre_samples_c = round(pre_peak_sec_coarse * fs);
        post_samples_c = round(post_peak_sec_coarse * fs);
        coarse_target_len = pre_samples_c + post_samples_c + 1;

        coarse_signal = zeros(coarse_target_len, 1);

        coarse_start = coarse_peak_idx - pre_samples_c;
        coarse_end   = coarse_peak_idx + post_samples_c;
        pad_start = 1; pad_end = coarse_target_len;

        if coarse_start < 1
            pad_start = 2 - coarse_start;
            coarse_start = 1;
        end
        if coarse_end > length(x)
            pad_end = coarse_target_len - (coarse_end - length(x));
            coarse_end = length(x);
        end

        coarse_signal(pad_start:pad_end) = x(coarse_start:coarse_end);

        % 防除零归一化（粗截取）
        m = max(abs(coarse_signal));
        if m > 0
            coarse_signal = coarse_signal / m;
        end

        %% ---------- C. 短音频自适应 STFT 参数 ----------
        sig_len = length(coarse_signal);
        if sig_len < min_win_len
            coarse_signal = [coarse_signal; zeros(min_win_len - sig_len, 1)];
            sig_len = min_win_len;
        end

        win_len_eff = min(win_len_default, sig_len);
        if mod(win_len_eff, 2) ~= 0
            win_len_eff = win_len_eff - 1; % 强制偶数
        end
        win_len_eff = max(win_len_eff, min_win_len);

        hop_len_eff = min(hop_len_default, win_len_eff - 1);
        hop_len_eff = max(1, hop_len_eff);

        nfft_eff = max(nfft_default, win_len_eff);

        % 保险：窗口长度不超过 nfft
        win_len_eff = min(win_len_eff, nfft_eff);
        hop_len_eff = min(hop_len_eff, win_len_eff - 1);
        hop_len_eff = max(1, hop_len_eff);

        noverlap_eff = win_len_eff - hop_len_eff;
        win_func_eff = blackmanharris(win_len_eff);

        %% ---------- D. 时频域盲字典去噪（低秩+稀疏近似） ----------
        % 用 stft/istft 成对，显式 onesided，避免 rows/windowLength 报错
        S_c = stft(coarse_signal, fs, ...
            'Window', win_func_eff, ...
            'OverlapLength', noverlap_eff, ...
            'FFTLength', nfft_eff, ...
            'FrequencyRange', 'onesided');

        mag = abs(S_c);
        phase = angle(S_c);

        % 尺寸保护
        if isempty(mag) || size(mag,1) < 2 || size(mag,2) < 2
            error('STFT结果尺寸过小，无法进行稳定SVD分解。');
        end

        [U, S_mat, V] = svd(mag, 'econ');
        svals = diag(S_mat);
        sv2 = svals.^2;
        total_energy = sum(sv2);

        if total_energy <= 0
            K_atoms = 1;
            energy_ratio_real = 0;
            mag_clean = mag;
        else
            cume = cumsum(sv2);
            K_atoms = find(cume >= dict_energy_ratio * total_energy, 1, 'first');
            if isempty(K_atoms)
                K_atoms = length(svals);
            end
            energy_ratio_real = cume(K_atoms) / total_energy;

            mag_clean = U(:,1:K_atoms) * S_mat(1:K_atoms,1:K_atoms) * V(:,1:K_atoms)';
            mag_clean = max(mag_clean, 0);
        end

        S_clean = mag_clean .* exp(1i * phase);

        y_clean = istft(S_clean, fs, ...
            'Window', win_func_eff, ...
            'OverlapLength', noverlap_eff, ...
            'FFTLength', nfft_eff, ...
            'FrequencyRange', 'onesided');

        y_clean = real(y_clean);
        y_clean = y_clean(:);

        % 长度对齐到粗截取长度
        if length(y_clean) > coarse_target_len
            y_clean = y_clean(1:coarse_target_len);
        elseif length(y_clean) < coarse_target_len
            y_clean = [y_clean; zeros(coarse_target_len - length(y_clean), 1)];
        end

        %% ---------- E. 第二次：去噪后精对齐 ----------
        env_win_fine = max(1, round(env_smooth_sec_fine * fs));
        env_fine = movmean(abs(y_clean), env_win_fine);
        [~, fine_peak_idx] = max(env_fine);

        pre_samples_f = round(pre_peak_sec_fine * fs);
        post_samples_f = round(post_peak_sec_fine * fs);
        fine_target_len = pre_samples_f + post_samples_f + 1;

        final_signal = zeros(fine_target_len, 1);

        fine_start = fine_peak_idx - pre_samples_f;
        fine_end   = fine_peak_idx + post_samples_f;
        pad_start2 = 1; pad_end2 = fine_target_len;

        if fine_start < 1
            pad_start2 = 2 - fine_start;
            fine_start = 1;
        end
        if fine_end > length(y_clean)
            pad_end2 = fine_target_len - (fine_end - length(y_clean));
            fine_end = length(y_clean);
        end

        final_signal(pad_start2:pad_end2) = y_clean(fine_start:fine_end);

        % 最终归一化
        m2 = max(abs(final_signal));
        if m2 > 0
            final_signal = final_signal / m2;
        end

        if length(final_signal) > fine_target_len
            final_signal = final_signal(1:fine_target_len);
        elseif length(final_signal) < fine_target_len
            final_signal = [final_signal; zeros(fine_target_len - length(final_signal), 1)];
        end
        final_len = length(final_signal);

        %% ---------- F. 导出 WAV ----------
        output_wav = fullfile(out_dir, [baseName, '_blind_denoised_aligned', ext]);
        if save_wav
            audiowrite(output_wav, final_signal, fs);
        end

        %% ---------- G. 导出谱图 + 矩阵 ----------
        % 这里只用于可视化与特征导出，用 spectrogram 没问题
        [~, F2, T2, P2] = spectrogram(final_signal, win_func_eff, noverlap_eff, nfft_eff, fs);
        P2 = max(P2, realmin('double'));
        log_spec_raw = 10 * log10(P2);

        max_p = max(log_spec_raw(:));
        floor_p = max_p - db_range;
        log_spec_matrix = max(log_spec_raw, floor_p);
        log_spec_matrix = (log_spec_matrix - floor_p) / db_range; % [0,1]

        if save_png
            output_png = fullfile(out_dir, [baseName, '_spectrogram.png']);
            fig = figure('Visible', 'off', 'Position', [100,100,800,600]);
            imagesc(T2, F2, log_spec_matrix);
            axis xy;
            colormap turbo;
            c = colorbar;
            c.Label.String = 'Power (dB)';
            xlabel('Time (s)');
            ylabel('Frequency (Hz)');
            title(['Log-Spectrogram: ', strrep(baseName, '_', '\_')]);
            ylim([0 min(fs/2, fmax_display)]);
            exportgraphics(gca, output_png, 'Resolution', image_dpi);
            close(fig);
        end

        if save_mat
            output_mat = fullfile(out_dir, [baseName, '_matrix.mat']);
            save(output_mat, 'log_spec_matrix', 'F2', 'T2', 'fs');
        end

        fprintf('  -> 完成: K=%d, energy=%.2f%%, win/hop/nfft=%d/%d/%d\n', ...
            K_atoms, energy_ratio_real*100, win_len_eff, hop_len_eff, nfft_eff);

    catch ME
        status = 'FAIL';
        msg = strrep(ME.message, ',', ';'); % 防CSV错列
        fprintf('  -> 失败: %s\n', ME.message);
    end

    % 写日志
    fprintf(fid, '%s,%d,%d,%d,%d,%d,%d,%.8f,%d,%d,%d,%d,%d,%d,%d,%s,%s\n', ...
        fileName, fs, orig_len, coarse_peak_idx, coarse_start, coarse_end, ...
        K_atoms, energy_ratio_real, fine_peak_idx, fine_start, fine_end, ...
        final_len, win_len_eff, hop_len_eff, nfft_eff, status, msg);
end

fclose(fid);

disp(' ');
disp('========= 🎉 全部处理完成！ =========');
disp(['输出目录：', out_dir]);
disp(['日志文件：', log_file]);