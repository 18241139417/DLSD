%% build_svm_feature_matrix.m
% SVM用特征矩阵构建与标准化脚本（输出未标准化特征）
% MATLAB R2021a+

clearvars;
clc;

%% Step 1: 选择并读取CSV汇总文件
[csvName, csvPath] = uigetfile({'*.csv','CSV Files (*.csv)'}, ...
    '请选择 Acoustic_Feature_Extractor 导出的CSV文件');
if isequal(csvName, 0)
    error('未选择CSV文件，脚本终止。');
end

csvFile = fullfile(csvPath, csvName);
T = readtable(csvFile, 'TextType', 'string');

requiredVars = ["Sample_Name","Main_Freq_Hz","Bandwidth_Hz", ...
    "Q_Factor","Peak_Amplitude","SNR_Estimate_dB"];
missingVars = requiredVars(~ismember(requiredVars, string(T.Properties.VariableNames)));
if ~isempty(missingVars)
    error('CSV缺少必要字段: %s', strjoin(missingVars, ', '));
end

%% Step 2: 选择WAV文件夹并获取文件列表
wavFolder = uigetdir(pwd, '请选择已对齐WAV文件夹');
if isequal(wavFolder, 0)
    error('未选择WAV文件夹，脚本终止。');
end

wavInfo = dir(fullfile(wavFolder, '*aligned.wav'));
if isempty(wavInfo)
    error(['所选文件夹中未找到 *aligned.wav 文件。\n' ...
           '请确认选择的是 Blind_Dictionary_Denoise 的输出目录。']);
end

%% Step 3: 遍历WAV文件，提取并拼接特征
N = numel(wavInfo);
X_raw = nan(N, 8);
Y = categorical(strings(N,1), ["Intact","Mineralized"]);
file_list = strings(N,1);
nan_mask = false(N,1);

sampleNames = string(T.Sample_Name);

for i = 1:N
    fname = wavInfo(i).name;
    fpath = fullfile(wavInfo(i).folder, fname);
    file_list(i) = string(fname);

    % (a) 读取并预处理
    [y, fs] = audioread(fpath);
    if size(y,2) > 1
        y = mean(y, 2);
    end
    y = y - mean(y, 'omitnan');
    peakAbs = max(abs(y));
    if peakAbs > 0
        y = y ./ peakAbs;
    end

    % (b) 时域特征
    tdFeat = extractTimeDomainFeatures(y, fs);

    % (c) CSV匹配对应样本（contains，不区分大小写）
    [~, baseName, ~] = fileparts(fname);
    [~, sampleBaseNames] = cellfun(@(s) fileparts(char(s)), ...
        cellstr(sampleNames), 'UniformOutput', false);
    sampleBaseNames = string(sampleBaseNames);
    matchMask = strcmp(sampleBaseNames, baseName);
    idx = find(matchMask, 1, 'first');
    if isempty(idx)
        warning('未在CSV中精确匹配到样本: %s。对应频域特征将保留NaN。', fname);
    end

    if isempty(idx)
        warning('未在CSV中匹配到样本: %s。对应频域特征将保留NaN。', fname);
        Q = nan; f0 = nan; BW = nan; SNR = nan; Peak = nan;
    else
        Q = T.Q_Factor(idx);
        f0 = T.Main_Freq_Hz(idx);
        BW = T.Bandwidth_Hz(idx);
        SNR = T.SNR_Estimate_dB(idx);
        Peak = T.Peak_Amplitude(idx);
    end

    % (d) 特征向量顺序固定: [Q, f0, BW, SNR, Peak, tau, T_eff, rms]
    featRow = [Q, f0, BW, SNR, Peak, tdFeat.decay_tau_s, tdFeat.T_eff_s, tdFeat.rms_energy];
    X_raw(i, :) = featRow;

    % (e) 标签规则
    Y(i) = categorical(get_bronze_label(fname), ["Intact","Mineralized"]);

    % Step 4(a): 数值保护与告警
    if any(~isfinite(featRow) | isnan(featRow))
        nan_mask(i) = any(isnan(featRow));
        warning('样本存在NaN/Inf特征: %s', fname);
    end
end

%% Step 4(b): 统计输出
numIntact = sum(Y == 'Intact');
numMineralized = sum(Y == 'Mineralized');
numNaN = sum(nan_mask);

%% Step 5: 输出变量并保存
feat_names = ["Q_Factor","Main_Freq_Hz","Bandwidth_Hz","SNR_dB", ...
              "Peak_Amplitude","decay_tau_s","T_eff_s","rms_energy"];

save('feature_matrix.mat', 'X_raw', 'Y', 'feat_names', 'file_list', 'nan_mask');

fprintf('特征矩阵构建完成：N=%d，Intact=%d，Mineralized=%d，含NaN=%d\n', ...
    N, numIntact, numMineralized, numNaN);
