% =========================================================================
% 青铜器敲击声 - 批量特征提取 (优化版)
% 说明：
% 1) 统一输入输出与异常处理，避免单文件失败中断全流程
% 2) 预计算与复用参数，减少循环内重复开销
% 3) 增强数值稳定性（静音/零向量防护）
% 4) 保持与原始流程一致的结果语义：峰值对齐 + 频谱图导出 + 矩阵保存
% =========================================================================
clear; clc; close all;

[fileList, pathName] = uigetfile('*.wav', '请选择 WAV 文件（可多选）', 'MultiSelect', 'on');
if isequal(fileList, 0)
    disp('未选择文件，程序结束。');
    return;
end
if ischar(fileList)
    fileList = {fileList};
end

numFiles = numel(fileList);
fprintf('成功选择 %d 个文件，开始处理...\n', numFiles);

% ---------------------- 固定参数（一次定义，循环复用）----------------------
pre_peak_sec  = 0.05;
post_peak_sec = 1.0;
win_len       = 1024;
nfft          = 1024;
noverlap      = win_len - 256;      % hop length 256
window_func   = blackmanharris(win_len, 'periodic'); % must match win_func_eff in Blind_Dictionary_Denoise.m
db_range      = 75;
freq_upper    = 8000;

% 处理结果统计
okCount = 0;
failCount = 0;

for i = 1:numFiles
    fileName = fileList{i};
    inputFile = fullfile(pathName, fileName);
    [~, baseName, ~] = fileparts(fileName);
    outputImage = fullfile(pathName, [baseName, '_spectrogram.png']);
    outputMatrix = fullfile(pathName, [baseName, '_matrix.mat']);

    fprintf('进度 (%d/%d): %s\n', i, numFiles, fileName);

    try
        [x, fs] = audioread(inputFile);

        % 多声道转单声道
        if size(x, 2) > 1
            x = mean(x, 2);
        end

        % 空音频或全零防护
        if isempty(x) || ~any(x)
            warning('文件 %s 为空或全零，已跳过。', fileName);
            failCount = failCount + 1;
            continue;
        end

        % 峰值对齐截取
        [~, peak_idx] = max(abs(x));
        pre_samples   = round(pre_peak_sec * fs);
        post_samples  = round(post_peak_sec * fs);
        total_samples = pre_samples + post_samples + 1;

        valid_signal = zeros(total_samples, 1, 'like', x);

        act_start = peak_idx - pre_samples;
        act_end   = peak_idx + post_samples;
        pad_start = 1;
        pad_end   = total_samples;

        if act_start < 1
            pad_start = 2 - act_start;
            act_start = 1;
        end
        if act_end > numel(x)
            pad_end = total_samples - (act_end - numel(x));
            act_end = numel(x);
        end

        valid_signal(pad_start:pad_end) = x(act_start:act_end);

        % 归一化防止除零
        peak_abs = max(abs(valid_signal));
        if peak_abs > 0
            valid_signal = valid_signal ./ peak_abs;
        end

        % 频谱计算
        [~, F, T, P] = spectrogram(valid_signal, window_func, noverlap, nfft, fs);
        log_spec_raw = 10 * log10(P + eps('single'));

        % 动态范围裁剪 + [0,1] 归一化
        max_p = max(log_spec_raw(:));
        floor_p = max_p - db_range;
        log_spec_matrix = max(log_spec_raw, floor_p);
        log_spec_matrix = (log_spec_matrix - floor_p) / db_range;

        % 绘图并导出
        fig = figure('Visible', 'off', 'Position', [100, 100, 800, 600]);
        ax = axes(fig);
        imagesc(ax, T, F, log_spec_matrix);
        axis(ax, 'xy');
        colormap(ax, turbo);
        c = colorbar(ax);
        c.Label.String = 'Power (dB, clipped & normalized)';
        xlabel(ax, 'Time (s)');
        ylabel(ax, 'Frequency (Hz)');
        title(ax, ['Log-Spectrogram: ', strrep(baseName, '_', '\_')]);
        ylim(ax, [0, min(fs/2, freq_upper)]);

        exportgraphics(ax, outputImage, 'Resolution', 300);
        close(fig);

        save(outputMatrix, 'log_spec_matrix', 'F', 'T', 'fs');
        okCount = okCount + 1;

    catch ME
        warning('处理失败 [%s]: %s', fileName, ME.message);
        failCount = failCount + 1;
        if exist('fig', 'var') && isgraphics(fig)
            close(fig);
        end
    end
end

fprintf('========= 批量处理完成：成功 %d，失败 %d =========\n', okCount, failCount);
