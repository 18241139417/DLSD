% =========================================================================
% [论文分析] 频域特征与 Q 因子计算器 (Acoustic_Feature_Extractor_Pro.m)
% 目的：
%   1) 批量计算中心频率、带宽、Q值
%   2) 输出总览频谱图 + 每样本频谱图
%   3) 输出汇总指标表（Excel + CSV）
%   4) 输出 Origin 工程文件（.opju，需 Windows + 已安装 Origin）
%      - 每样本 Book + 图页
%      - 总览 Book（多列）
%      - 总览叠加图页
% =========================================================================
clear; clc; close all;

disp('选择已对齐的 WAV 文件 (可多选)...');
[filenames, pathname] = uigetfile('*aligned.wav', '选择文件', 'MultiSelect', 'on');
if isequal(filenames, 0); return; end
if ischar(filenames); filenames = {filenames}; end
num_files = numel(filenames);

% 输出目录
fig_dir = fullfile(pathname, 'Individual_Spectra');
if ~exist(fig_dir, 'dir')
    mkdir(fig_dir);
end

% 参数
method_version = "Acoustic_Feature_Extractor_Pro_vFinal_1.1.0";
f_low = 20;
f_high = 5000;
cutoff = 10^(-3/20); % -3 dB 振幅比
smooth_win_default = 15;
nfft_factor = 4;

% 总览图
figure('Color', 'w', 'Name', '频域特征分析', 'Position', [150, 150, 900, 600]);
hold on;
colors = lines(num_files);
legend_str = {};

% 有效样本存储（含曲线点，用于 Origin 导出）
valid_data = struct([]);
k = 0;

disp('正在分析频域特征...');

for i = 1:num_files
    file_name = filenames{i};
    file_full = fullfile(pathname, file_name);

    try
        [y, fs] = audioread(file_full);
    catch
        warning('读取失败，已跳过: %s', file_name);
        continue;
    end

    % 转单声道 + 去直流
    if size(y,2) > 1
        y = mean(y,2);
    end
    y = y - mean(y);

    % 信号有效性
    if max(abs(y)) < 1e-6
        warning('信号能量过低，已跳过: %s', file_name);
        continue;
    end
    N = length(y);
    if N < 32
        warning('样本过短，已跳过: %s', file_name);
        continue;
    end

    % FFT（Hann窗 + 零填充）
    w = hann(N);
    yw = y .* w;
    Nfft = 2^nextpow2(max(N, nfft_factor * N));

    Y = fft(yw, Nfft);
    P2 = abs(Y / N);
    P1 = P2(1:floor(Nfft/2)+1);
    if numel(P1) > 2
        P1(2:end-1) = 2 * P1(2:end-1);
    end
    f = fs * (0:floor(Nfft/2)) / Nfft;

    f = f(:);
    P1 = P1(:);

    % 频段限制
    valid_mask = (f > f_low) & (f < f_high);
    if ~any(valid_mask)
        warning('有效频段无数据，已跳过: %s', file_name);
        continue;
    end
    f_val = f(valid_mask);
    P1_raw = P1(valid_mask);

    % 平滑（自适应奇数窗长）
    sm_len = min(smooth_win_default, max(3, 2*floor(numel(P1_raw)/20)+1));
    if mod(sm_len,2)==0
        sm_len = sm_len + 1;
    end
    if sm_len >= 3
        P1_val = smoothdata(P1_raw, 'gaussian', sm_len);
    else
        P1_val = P1_raw;
    end

    pmax = max(P1_val);
    if pmax <= 0 || ~isfinite(pmax)
        warning('频谱异常，已跳过: %s', file_name);
        continue;
    end
    P1_norm = P1_val / pmax;

    % 主峰
    [~, idx_peak] = max(P1_norm);
    f0 = f_val(idx_peak);
    peak_amplitude = P1_val(idx_peak);

    % ---- -3dB 带宽（线性插值）----
    nPts = numel(P1_norm);

    % 左交点
    idx_left_low = find(P1_norm(1:idx_peak) < cutoff, 1, 'last');
    if isempty(idx_left_low) || idx_left_low >= idx_peak
        f_left = f_val(1);
    else
        x1 = f_val(idx_left_low);   y1 = P1_norm(idx_left_low);
        x2 = f_val(idx_left_low+1); y2 = P1_norm(idx_left_low+1);
        if y2 ~= y1
            f_left = x1 + (cutoff-y1)*(x2-x1)/(y2-y1);
        else
            f_left = x1;
        end
    end

    % 右交点
    idx_right_rel = find(P1_norm(idx_peak:end) < cutoff, 1, 'first');
    if isempty(idx_right_rel)
        f_right = f_val(end);
    else
        idx_right_low = idx_peak + idx_right_rel - 1;
        if idx_right_low <= idx_peak || idx_right_low > nPts
            f_right = f_val(end);
        else
            x1 = f_val(idx_right_low-1); y1 = P1_norm(idx_right_low-1);
            x2 = f_val(idx_right_low);   y2 = P1_norm(idx_right_low);
            if y2 ~= y1
                f_right = x1 + (cutoff-y1)*(x2-x1)/(y2-y1);
            else
                f_right = x2;
            end
        end
    end

    bw = f_right - f_left;
    if ~isfinite(bw) || bw <= eps
        Q = NaN;
    else
        Q = f0 / bw;
    end

    % ---- SNR 估计（频域粗估）----
    peak_power = peak_amplitude^2;
    excl_half_width = max(3, round(0.05 * nPts)); % 剔除峰附近 ±5% 频点
    idx_lo = max(1, idx_peak - excl_half_width);
    idx_hi = min(nPts, idx_peak + excl_half_width);
    noise_vec = P1_val;
    noise_vec(idx_lo:idx_hi) = [];

    if isempty(noise_vec)
        noise_power_med = NaN;
    else
        noise_power_med = median(noise_vec.^2, 'omitnan');
    end

    if ~isfinite(noise_power_med) || noise_power_med <= eps || peak_power <= 0
        snr_estimate_db = NaN;
    else
        snr_estimate_db = 10 * log10(peak_power / noise_power_med);
    end

    [~, bName, ~] = fileparts(file_name);

    % 保存有效样本数据
    k = k + 1;
    valid_data(k).Sample_Name        = string(file_name);
    valid_data(k).Base_Name          = string(bName);
    valid_data(k).Method_Version     = method_version;
    valid_data(k).Fs_Hz              = fs;
    valid_data(k).N_Samples          = N;
    valid_data(k).Nfft               = Nfft;
    valid_data(k).Freq_Range_Low_Hz  = f_low;
    valid_data(k).Freq_Range_High_Hz = f_high;
    valid_data(k).Cutoff_Amplitude   = cutoff;
    valid_data(k).Cutoff_dB          = -3;
    valid_data(k).Smooth_Method      = "gaussian";
    valid_data(k).Smooth_Window      = sm_len;
    valid_data(k).Window_Type        = "hann";
    valid_data(k).Nfft_Factor_Min    = nfft_factor;

    valid_data(k).Main_Freq_Hz       = f0;
    valid_data(k).Bandwidth_Hz       = bw;
    valid_data(k).Q_Factor           = Q;
    valid_data(k).Left_Cutoff_Hz     = f_left;
    valid_data(k).Right_Cutoff_Hz    = f_right;
    valid_data(k).Peak_Amplitude     = peak_amplitude;
    valid_data(k).SNR_Estimate_dB    = snr_estimate_db;

    % 用于 Origin
    valid_data(k).f_val              = f_val;
    valid_data(k).P1_norm            = P1_norm;

    % ---- MATLAB 总览图 ----
    col = colors(i,:);
    plot(f_val, P1_norm, 'Color', col, 'LineWidth', 1.5);
    plot(f0, 1, 'o', 'MarkerSize', 5, 'MarkerFaceColor', col, 'MarkerEdgeColor', 'none');
    legend_str{end+1} = sprintf('%s (Q=%.1f)', strrep(bName, '_', '\_'), Q);

    % ---- MATLAB 每样本图 ----
    fig_single = figure('Color', 'w', 'Visible', 'off', 'Position', [120, 120, 900, 560]);
    hold on;
    plot(f_val, P1_norm, 'Color', [0.15 0.35 0.75], 'LineWidth', 1.7);
    plot(f0, 1, 'o', 'MarkerSize', 6, 'MarkerFaceColor', [0.85 0.2 0.2], 'MarkerEdgeColor', 'none');
    yline(cutoff, '--', '-3 dB', 'Color', [0.2 0.2 0.2], 'LineWidth', 1.0, ...
          'LabelHorizontalAlignment', 'left', 'LabelVerticalAlignment', 'bottom');
    xline(f_left,  ':', 'Color', [0.4 0.4 0.4], 'LineWidth', 1.0);
    xline(f_right, ':', 'Color', [0.4 0.4 0.4], 'LineWidth', 1.0);

    set(gca, 'FontName', 'Times New Roman', 'FontSize', 12, 'LineWidth', 1);
    box on; grid on; set(gca, 'GridAlpha', 0.2);
    title(sprintf('Frequency Spectrum and Q-Factor: %s', strrep(bName,'_','\_')), ...
          'FontName', 'Times New Roman', 'FontSize', 14, 'FontWeight', 'bold');
    xlabel('Frequency (Hz)', 'FontName', 'Times New Roman');
    ylabel('Normalized Amplitude', 'FontName', 'Times New Roman');
    xlim([0, 4000]); ylim([0, 1.1]);

    txtQ = sprintf('F0 = %.1f Hz\nBW = %.1f Hz\nQ = %.2f\nSNR = %.2f dB', f0, bw, Q, snr_estimate_db);
    text(0.68*4000, 0.95, txtQ, 'FontName', 'Times New Roman', 'FontSize', 11, ...
         'VerticalAlignment', 'top', 'BackgroundColor', 'w', 'EdgeColor', [0.8 0.8 0.8]);

    hold off;
    png_name = fullfile(fig_dir, sprintf('%s_spectrum.png', bName));
    fig_name = fullfile(fig_dir, sprintf('%s_spectrum.fig', bName));
    exportgraphics(fig_single, png_name, 'Resolution', 300);
    savefig(fig_single, fig_name);
    close(fig_single);
end

% ---- MATLAB 总览图美化与导出 ----
set(gca, 'FontName', 'Times New Roman', 'FontSize', 12, 'LineWidth', 1);
box on; grid on; set(gca, 'GridAlpha', 0.2);
title('Frequency Spectra and Q-Factor of Bronze Impacts', ...
      'FontName', 'Times New Roman', 'FontSize', 14, 'FontWeight', 'bold');
xlabel('Frequency (Hz)', 'FontName', 'Times New Roman');
ylabel('Normalized Amplitude', 'FontName', 'Times New Roman');
xlim([0, 4000]); ylim([0, 1.1]);
if ~isempty(legend_str)
    legend(legend_str, 'Location', 'northeast', 'FontSize', 10);
end

overview_png = fullfile(pathname, 'Acoustic_Q_Factor_Overview.png');
overview_fig = fullfile(pathname, 'Acoustic_Q_Factor_Overview.fig');
exportgraphics(gcf, overview_png, 'Resolution', 300);
savefig(gcf, overview_fig);

if isempty(valid_data)
    disp('未得到有效样本结果，请检查输入音频质量或文件内容。');
    return;
end

% =========================================================================
% 汇总指标表导出（Excel + CSV）
% =========================================================================
n = numel(valid_data);
Sample_Name     = strings(n,1);
Base_Name       = strings(n,1);
Method_Version  = strings(n,1);
Fs_Hz           = nan(n,1);
N_Samples       = nan(n,1);
Nfft            = nan(n,1);
Freq_Low_Hz     = nan(n,1);
Freq_High_Hz    = nan(n,1);
Cutoff_Amp      = nan(n,1);
Cutoff_dB       = nan(n,1);
Smooth_Method   = strings(n,1);
Smooth_Window   = nan(n,1);
Window_Type     = strings(n,1);
Nfft_Factor_Min = nan(n,1);
Main_Freq_Hz    = nan(n,1);
Bandwidth_Hz    = nan(n,1);
Q_Factor        = nan(n,1);
Left_Cutoff_Hz  = nan(n,1);
Right_Cutoff_Hz = nan(n,1);
Peak_Amplitude  = nan(n,1);
SNR_Estimate_dB = nan(n,1);

for ii = 1:n
    Sample_Name(ii)     = valid_data(ii).Sample_Name;
    Base_Name(ii)       = valid_data(ii).Base_Name;
    Method_Version(ii)  = valid_data(ii).Method_Version;
    Fs_Hz(ii)           = valid_data(ii).Fs_Hz;
    N_Samples(ii)       = valid_data(ii).N_Samples;
    Nfft(ii)            = valid_data(ii).Nfft;
    Freq_Low_Hz(ii)     = valid_data(ii).Freq_Range_Low_Hz;
    Freq_High_Hz(ii)    = valid_data(ii).Freq_Range_High_Hz;
    Cutoff_Amp(ii)      = valid_data(ii).Cutoff_Amplitude;
    Cutoff_dB(ii)       = valid_data(ii).Cutoff_dB;
    Smooth_Method(ii)   = valid_data(ii).Smooth_Method;
    Smooth_Window(ii)   = valid_data(ii).Smooth_Window;
    Window_Type(ii)     = valid_data(ii).Window_Type;
    Nfft_Factor_Min(ii) = valid_data(ii).Nfft_Factor_Min;
    Main_Freq_Hz(ii)    = valid_data(ii).Main_Freq_Hz;
    Bandwidth_Hz(ii)    = valid_data(ii).Bandwidth_Hz;
    Q_Factor(ii)        = valid_data(ii).Q_Factor;
    Left_Cutoff_Hz(ii)  = valid_data(ii).Left_Cutoff_Hz;
    Right_Cutoff_Hz(ii) = valid_data(ii).Right_Cutoff_Hz;
    Peak_Amplitude(ii)  = valid_data(ii).Peak_Amplitude;
    SNR_Estimate_dB(ii) = valid_data(ii).SNR_Estimate_dB;
end

SummaryT = table( ...
    Sample_Name, Base_Name, Method_Version, ...
    Fs_Hz, N_Samples, Nfft, Freq_Low_Hz, Freq_High_Hz, Cutoff_Amp, Cutoff_dB, ...
    Smooth_Method, Smooth_Window, Window_Type, Nfft_Factor_Min, ...
    round(Main_Freq_Hz,1), round(Bandwidth_Hz,1), round(Q_Factor,2), ...
    round(Left_Cutoff_Hz,1), round(Right_Cutoff_Hz,1), ...
    Peak_Amplitude, round(SNR_Estimate_dB,2), ...
    'VariableNames', { ...
    'Sample_Name','Base_Name','Method_Version', ...
    'Fs_Hz','N_Samples','Nfft','Freq_Range_Low_Hz','Freq_Range_High_Hz','Cutoff_Amplitude','Cutoff_dB', ...
    'Smooth_Method','Smooth_Window','Window_Type','Nfft_Factor_Min', ...
    'Main_Freq_Hz','Bandwidth_Hz','Q_Factor','Left_Cutoff_Hz','Right_Cutoff_Hz', ...
    'Peak_Amplitude','SNR_Estimate_dB'} ...
);

xlsx_name = fullfile(pathname, 'Acoustic_Q_Factor_Results.xlsx');
csv_name  = fullfile(pathname, 'Acoustic_Q_Factor_Results.csv');

try
    writetable(SummaryT, xlsx_name);
    disp(['汇总指标表(Excel)已保存: ', xlsx_name]);
catch
    disp('警告: Excel 写入失败（可能文件被占用）。');
end

try
    writetable(SummaryT, csv_name);
    disp(['汇总指标表(CSV)已保存: ', csv_name]);
catch
    disp('警告: CSV 写入失败。');
end

% =========================================================================
% Origin 工程导出（.opju）
% 说明：需 Windows + 已安装 Origin，且支持 COM（Origin.ApplicationSI）
% 包含：
%   A) 每样本 Book + 曲线图
%   B) 总览 Book（X + 多个Y）
%   C) 总览叠加图页
% =========================================================================
opju_file = fullfile(pathname, 'Acoustic_Q_Factor_Origin.opju');

try
    originObj = actxserver('Origin.ApplicationSI');
    invoke(originObj, 'Execute', 'doc -mc 1;');    % 新建工程
    invoke(originObj, 'Execute', 'sec -p 0;');     % 关闭脚本窗口弹出

    % ---------- A) 每样本 Book + 图 ----------
    for s = 1:numel(valid_data)
        bName = char(valid_data(s).Base_Name);

        % 新建 Book
        cmd_newbook = sprintf('newbook name:="%s" result:=BookName;', bName);
        invoke(originObj, 'Execute', cmd_newbook);

        % 临时 CSV
        temp_csv = fullfile(pathname, sprintf('__temp_%s_points.csv', bName));
        Ttmp = table(valid_data(s).f_val, valid_data(s).P1_norm, ...
            'VariableNames', {'Frequency_Hz','Amplitude_Norm'});
        writetable(Ttmp, temp_csv);

        temp_csv_origin = strrep(temp_csv, '\', '/');
        cmd_imp = sprintf('impASC fname:="%s" options.sparklines:=0;', temp_csv_origin);
        invoke(originObj, 'Execute', cmd_imp);

        % 列类型 X/Y，绘图
        invoke(originObj, 'Execute', 'wks.col1.type=4;'); % X
        invoke(originObj, 'Execute', 'wks.col2.type=1;'); % Y
        invoke(originObj, 'Execute', 'plotxy iy:=(1,2) plot:=200;'); % line
    end

    % ---------- B) 总览 Book（X + 多Y） ----------
    % 对齐长度：取所有样本最短长度，保证同一 X 可拼成多列
    minLen = inf;
    for s = 1:numel(valid_data)
        minLen = min(minLen, numel(valid_data(s).f_val));
    end

    % 构造总览 CSV：第一列 Frequency_Hz，后续每列一个样本 Y
    freq_common = valid_data(1).f_val(1:minLen);
    allMat = nan(minLen, numel(valid_data)+1);
    allMat(:,1) = freq_common;

    varNames = cell(1, numel(valid_data)+1);
    varNames{1} = 'Frequency_Hz';

    for s = 1:numel(valid_data)
        ytmp = valid_data(s).P1_norm(1:minLen);
        allMat(:,s+1) = ytmp;
        nm = char(valid_data(s).Base_Name);
        nm = regexprep(nm, '[^a-zA-Z0-9_]', '_'); % 避免非法列名
        if isempty(nm), nm = sprintf('Sample_%d', s); end
        varNames{s+1} = ['Y_' nm];
    end

    overviewTable = array2table(allMat, 'VariableNames', varNames);
    overview_csv = fullfile(pathname, '__temp_overview_all.csv');
    writetable(overviewTable, overview_csv);

    % 在 Origin 新建总览 Book 并导入
    invoke(originObj, 'Execute', 'newbook name:="Overview_Book" result:=BookName;');
    overview_csv_origin = strrep(overview_csv, '\', '/');
    cmd_imp_overview = sprintf('impASC fname:="%s" options.sparklines:=0;', overview_csv_origin);
    invoke(originObj, 'Execute', cmd_imp_overview);

    % 设置列类型：col1=X，col2..end=Y
    invoke(originObj, 'Execute', 'wks.col1.type=4;');
    for s = 1:numel(valid_data)
        cmd_setY = sprintf('wks.col%d.type=1;', s+1);
        invoke(originObj, 'Execute', cmd_setY);
    end

    % ---------- C) 总览叠加图页 ----------
    % 激活 Overview_Book 并以 X=1, Y=2..Ncol 叠加绘图
    invoke(originObj, 'Execute', 'win -a Overview_Book;');
    nCols = numel(valid_data) + 1;

    % 构造 iy:=(1,2) (1,3) ... (1,nCols)
    pairStr = '';
    for c = 2:nCols
        pairStr = [pairStr, sprintf(' (1,%d)', c)]; %#ok<AGROW>
    end
    cmd_plot_overlay = sprintf('plotxy iy:=(%s ) plot:=200 ogl:=<new name:="Overview_Overlay">;', strtrim(pairStr));
    % 为稳妥再去掉可能双空格
    cmd_plot_overlay = regexprep(cmd_plot_overlay, '\s+', ' ');
    invoke(originObj, 'Execute', cmd_plot_overlay);

    % 给总览图页加标题（LabTalk）
    invoke(originObj, 'Execute', ...
        'win -a Overview_Overlay; label -s -n title "Frequency Spectra and Q-Factor of Bronze Impacts";');

    % 保存工程
    opju_origin = strrep(opju_file, '\', '/');
    cmd_save = sprintf('save -ix "%s";', opju_origin);
    invoke(originObj, 'Execute', cmd_save);

    % 关闭 Origin
    invoke(originObj, 'Exit');
    delete(originObj);

    % 删除临时 CSV
    temp_files = dir(fullfile(pathname, '__temp_*'));
    for t = 1:numel(temp_files)
        delete(fullfile(pathname, temp_files(t).name));
    end

    disp(['Origin 工程已保存: ', opju_file]);

catch ME
    warning('未能自动生成 .opju（可能非 Windows 或未安装 Origin）。错误: %s', ME.message);
    disp('已成功输出：MATLAB图与汇总指标表（Excel/CSV）。');
end

disp('分析完成。');