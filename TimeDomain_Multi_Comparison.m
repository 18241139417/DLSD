% =========================================================================
% [论文绘图] 多文件时域衰减对比图 (TimeDomain_Multi_Comparison.m)
% 目的：支持 2~N 个文件自动堆叠对比，采用 SCI 期刊级无缝紧凑排版
% 额外输出：除图片外，同时导出数据点表（CSV）
% =========================================================================
clear; clc; close all;

%% 参数区（可按需修改）
targetFsForPlot = 20000;      % 仅用于显示的目标采样率（提高大文件绘图速度）
uniformYLim     = true;       % true: 所有子图统一[-1,1]；false: 每个文件自适应
exportPNG       = false;      % true: 自动导出 600 dpi PNG
exportDataTable = true;       % true: 自动导出数据点表 CSV
lineW           = 1.1;
fontMain        = 'Times New Roman';

%% 选择文件
disp('请选择已对齐的 WAV 文件 (支持按住 Ctrl/Shift 多选)...');
[filenames, pathname] = uigetfile('*.wav', '选择对比文件', 'MultiSelect', 'on');

if isequal(filenames, 0)
    disp('取消了选择。');
    return;
end
if ischar(filenames)
    filenames = {filenames};
end

numFiles = numel(filenames);
if numFiles < 2
    warning('当前仅选择了 1 个文件。建议至少选择 2 个文件以体现对比效果。');
end

%% 图窗与排版
figH = max(420, 150 * numFiles + 120);
figure('Color', 'w', 'Name', '多文件时域衰减对比', ...
    'Position', [100, 100, 900, figH]);

tlo = tiledlayout(numFiles, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
colors = lines(numFiles);
axList = gobjects(numFiles, 1);
maxTime = 0;

% 用于导出数据表（每个文件一张表，字段：time_s, amplitude）
dataTables = cell(numFiles, 1);
baseNames  = cell(numFiles, 1);

%% 绘图主循环
for i = 1:numFiles
    fpath = fullfile(pathname, filenames{i});

    % 读音频（转单声道）
    [y, fs] = audioread(fpath);
    if size(y, 2) > 1
        y = mean(y, 2);
    end

    % 去直流 + 归一化（避免音量差异影响比较）
    y = y - mean(y, 'omitnan');
    peak = max(abs(y));
    if peak > 0
        y = y / peak;
    end

    % 仅用于绘图的降采样（不改变原始数据本质）
    if fs > targetFsForPlot
        yPlot = resample(y, targetFsForPlot, fs);
        fsPlot = targetFsForPlot;
    else
        yPlot = y;
        fsPlot = fs;
    end

    t = (0:numel(yPlot)-1).' / fsPlot;
    maxTime = max(maxTime, t(end));

    % 保存数据点表（导出的就是绘图使用的数据点）
    dataTables{i} = table(t, yPlot, 'VariableNames', {'time_s', 'amplitude'});

    [~, bName, ~] = fileparts(filenames{i});
    baseNames{i} = bName;

    axList(i) = nexttile;
    plot(t, yPlot, 'Color', colors(i, :), 'LineWidth', lineW);

    set(axList(i), 'FontName', fontMain, 'FontSize', 11, 'LineWidth', 1, ...
        'GridAlpha', 0.2, 'Layer', 'top');
    box(axList(i), 'on');
    grid(axList(i), 'on');

    if uniformYLim
        ylim(axList(i), [-1.05, 1.05]);
    else
        thisPeak = max(abs(yPlot));
        ylim(axList(i), 1.05 * [-thisPeak, thisPeak + eps]);
    end

    title(axList(i), strrep(bName, '_', '\_'), 'FontName', fontMain, ...
        'FontSize', 11, 'FontWeight', 'bold');

    if i < numFiles
        axList(i).XTickLabel = [];
    end
end

%% 全局锁定与共享标签
linkaxes(axList, 'x');
xlim(axList, [0, maxTime]);

xlabel(tlo, 'Time (s)', 'FontName', fontMain, 'FontSize', 14, 'FontWeight', 'bold');
ylabel(tlo, 'Normalized Amplitude', 'FontName', fontMain, 'FontSize', 14, 'FontWeight', 'bold');
title(tlo, 'Time-Domain Decay Comparison of Bronze Impacts', ...
    'FontName', fontMain, 'FontSize', 16, 'FontWeight', 'bold');

%% 可选自动导出图片
if exportPNG
    outPng = fullfile(pathname, sprintf('TimeDomain_Multi_Comparison_%s.png', datestr(now, 'yyyymmdd_HHMMSS')));
    exportgraphics(gcf, outPng, 'Resolution', 600);
    fprintf('已导出图片: %s\n', outPng);
end

%% 可选自动导出数据点表 CSV
if exportDataTable
    ts = datestr(now, 'yyyymmdd_HHMMSS');
    for i = 1:numFiles
        outCsv = fullfile(pathname, sprintf('%s_points_%s.csv', baseNames{i}, ts));
        writetable(dataTables{i}, outCsv);
        fprintf('已导出数据点表: %s\n', outCsv);
    end
end

disp('多文件对比绘图完成！如已开启 exportDataTable，将同时生成数据点表。');
