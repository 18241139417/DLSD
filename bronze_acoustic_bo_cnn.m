% =========================================================================
% 青铜器声谱 2D-CNN 深度学习训练程序（论文图表最终版）
% (嵌套分层交叉验证 + 内嵌贝叶斯优化 + 分段学习率退火 + 人工复核不确定类)
% =========================================================================
clear; clc; close all;

%% 0. 全局随机种子（保证可复现）
rng(2026, 'twister');

%% 0.1 论文图表输出目录
reportDir = fullfile(pwd, 'Paper_Figures');
if ~exist(reportDir, 'dir')
    mkdir(reportDir);
end
disp(['论文图表将输出到: ', reportDir]);

%% 1. 数据准备与加载
dataFolder = uigetdir(pwd, '请选择包含 _matrix.mat 文件的文件夹');
if dataFolder == 0; return; end

matFiles = dir(fullfile(dataFolder, '*_matrix.mat'));
numSamples = length(matFiles);

if numSamples == 0
    errordlg('未找到任何 *_matrix.mat 文件，请检查文件夹！', '出错');
    return;
end

disp(['准备加载 ', num2str(numSamples), ' 个 .mat 数据...']);

tempData = load(fullfile(dataFolder, matFiles(1).name));
assert(isfield(tempData, 'log_spec_matrix'), '首个文件缺少 log_spec_matrix 字段！');
[H, W] = size(tempData.log_spec_matrix);
C = 1;
disp(['自动检测到标准特征尺寸为: 高H=', num2str(H), ', 宽W=', num2str(W)]);

XData = zeros(H, W, C, numSamples, 'single');
YLabels = strings(numSamples, 1);

for i = 1:numSamples
    fileName = matFiles(i).name;
    loadedData = load(fullfile(dataFolder, fileName));
    assert(isfield(loadedData, 'log_spec_matrix'), ['文件缺少 log_spec_matrix: ', fileName]);

    featureMatrix = loadedData.log_spec_matrix;
    if size(featureMatrix, 1) ~= H || size(featureMatrix, 2) ~= W
        featureMatrix = imresize(featureMatrix, [H, W]);
    end
    XData(:, :, 1, i) = single(featureMatrix);

    if contains(lower(fileName), 'bad') || contains(lower(fileName), 'mineral')
        YLabels(i) = "Mineralized";
    else
        YLabels(i) = "Intact";
    end
end

YLabels = categorical(YLabels);
classList = categories(YLabels);
numClasses = numel(classList);

if numClasses < 2
    error('当前仅检测到单一类别，无法进行二分类训练！');
end

disp('数据加载完毕，张量构建成功！');
disp('类别统计如下：');
disp(countcats(YLabels));

%% 2. 嵌套交叉验证与贝叶斯优化核心配置
Outer_K = 5;          % 外层 K 折交叉验证数
maxBO_iter = 15;      % 内层贝叶斯优化最大探索次数
bo_repeats = 2;       % 每组超参重复训练次数（增强稳健性，1=关闭）
innerHoldout = 0.2;   % 内层验证比例
uncertaintyBandGrid = 0.05:0.02:0.25; % 不确定带宽搜索网格
reviewPenalty = 0.20; % 人工复核惩罚系数（越大越倾向少复核）

if Outer_K > numSamples
    warning('指定的 K 值大于总样本数，自动退化为留一法');
    Outer_K = numSamples;
    outer_c = cvpartition(numSamples, 'LeaveOut');
else
    outer_c = cvpartition(YLabels, 'KFold', Outer_K);  % 分层
end

optimVars = [
    optimizableVariable('InitialLearnRate', [1e-4, 1e-1], 'Transform', 'log')
    optimizableVariable('L2Regularization', [1e-6, 1e-2], 'Transform', 'log')
    optimizableVariable('DropoutRate', [0.1, 0.6], 'Type', 'real')
    optimizableVariable('FCWidth', [64, 256], 'Type', 'integer')
];

disp(['====== 启动 Nested CV (嵌套交叉验证) 与贝叶斯优化 ======']);
disp(['总计算量预估：外层 ', num2str(Outer_K), ' 折 × 内层 ', num2str(maxBO_iter), ...
      ' 次 × 重复 ', num2str(bo_repeats), ' = 约 ', num2str(Outer_K * maxBO_iter * bo_repeats), ' 次训练']);

%% 3. 嵌套验证主循环
numOuter = outer_c.NumTestSets;
foldAccs = zeros(numOuter, 1);
foldF1s = zeros(numOuter, 1);
foldBAccs = zeros(numOuter, 1);

bestAcc = -inf;
bestNet = [];
bestFold = 0;
bestHyperAll = cell(numOuter, 1);
confMats = cell(numOuter, 1);

% 论文图表与统计容器
rocData = cell(numOuter, 1);
boTrace = cell(numOuter, 1);
foldAUCs = nan(numOuter, 1);
bestBandPerFold = nan(numOuter, 1);
paretoData = cell(numOuter, 1);

for fold = 1:numOuter
    fprintf('\n==================================================\n');
    fprintf('--> 开始评估 外层第 [ %d / %d ] 折\n', fold, numOuter);
    fprintf('==================================================\n');

    trainOuterIdx = training(outer_c, fold);
    testOuterIdx  = test(outer_c, fold);

    XOuterTrain = XData(:, :, :, trainOuterIdx);
    YOuterTrain = YLabels(trainOuterIdx);
    XOuterTest  = XData(:, :, :, testOuterIdx);
    YOuterTest  = YLabels(testOuterIdx);

    inner_c = cvpartition(YOuterTrain, 'HoldOut', innerHoldout);
    innerTrainIdx = training(inner_c);
    innerValIdx   = test(inner_c);

    XInnerTrain = XOuterTrain(:, :, :, innerTrainIdx);
    YInnerTrain = YOuterTrain(innerTrainIdx);
    XInnerVal   = XOuterTrain(:, :, :, innerValIdx);
    YInnerVal   = YOuterTrain(innerValIdx);

    fprintf('[自动调参] 当前折运行贝叶斯优化 (%d 次迭代)...\n', maxBO_iter);

    foldSeed = 2026 + fold * 1000;

    ObjFcn = @(optVars) bayesOptObjectiveStable( ...
        optVars, XInnerTrain, YInnerTrain, XInnerVal, YInnerVal, ...
        H, W, numClasses, bo_repeats, foldSeed);

    boResults = bayesopt(ObjFcn, optimVars, ...
        'MaxObjectiveEvaluations', maxBO_iter, ...
        'IsObjectiveDeterministic', false, ...
        'UseParallel', false, ...
        'PlotFcn', [], ...
        'Verbose', 0);

    boTrace{fold} = extractBOTrace(boResults);

    bestHyperparams = boResults.XAtMinObjective;
    bestHyperAll{fold} = bestHyperparams;

    fprintf('   [调参完成] 最优初始学习率: %.6f | 最优 L2正则化: %.6f\n', ...
        bestHyperparams.InitialLearnRate, bestHyperparams.L2Regularization);
    fprintf('              最优 Dropout: %.3f | 最优 FC宽度: %d\n', ...
        bestHyperparams.DropoutRate, bestHyperparams.FCWidth);

    fprintf('   [最终训练] 使用最优参数 + 早停机制 拟合本折完整训练数据...\n');

    finalLayers = buildCNNLayers(H, W, numClasses, bestHyperparams.FCWidth, bestHyperparams.DropoutRate);

    finalVal_c = cvpartition(YOuterTrain, 'HoldOut', 0.15);
    finalTrainIdx = training(finalVal_c);
    finalValIdx   = test(finalVal_c);

    XFinalTrain = XOuterTrain(:, :, :, finalTrainIdx);
    YFinalTrain = YOuterTrain(finalTrainIdx);
    XFinalVal   = XOuterTrain(:, :, :, finalValIdx);
    YFinalVal   = YOuterTrain(finalValIdx);

    finalOptions = trainingOptions('adam', ...
        'InitialLearnRate', bestHyperparams.InitialLearnRate, ...
        'L2Regularization', bestHyperparams.L2Regularization, ...
        'MaxEpochs', 40, ...
        'MiniBatchSize', min(16, length(YFinalTrain)), ...
        'Shuffle', 'every-epoch', ...
        'LearnRateSchedule', 'piecewise', ...
        'LearnRateDropFactor', 0.5, ...
        'LearnRateDropPeriod', 10, ...
        'ValidationData', {XFinalVal, YFinalVal}, ...
        'ValidationFrequency', max(1, floor(length(YFinalTrain) / min(16, length(YFinalTrain)))), ...
        'ValidationPatience', 5, ...
        'Plots', 'none', ...
        'Verbose', false);

    [netFold, ~] = trainNetwork(XFinalTrain, YFinalTrain, finalLayers, finalOptions);

    [YPred, YScore] = classify(netFold, XOuterTest);
    [YPredVal, YScoreVal] = classify(netFold, XFinalVal);

    foldAcc = mean(YPred == YOuterTest);
    [foldF1, foldBAcc, cm] = calcMetricsBinary(YOuterTest, YPred, classList);

    foldAccs(fold)  = foldAcc;
    foldF1s(fold)   = foldF1;
    foldBAccs(fold) = foldBAcc;
    confMats{fold}  = cm;

    fprintf('   ★ 本折测试 Acc: %.2f%% | F1: %.4f | BAcc: %.4f\n', ...
        foldAcc * 100, foldF1, foldBAcc);

    % ROC 正类明确写死为矿化类
    posClass = categorical("Mineralized", categories(YOuterTest));
    posIdx = find(strcmp(categories(YOuterTest), 'Mineralized'), 1);
    if isempty(posIdx)
        error('类别中未找到 Mineralized，无法计算指定正类 ROC。');
    end
    uniqueTestClasses = categories(removecats(YOuterTest));
    if numel(uniqueTestClasses) < 2
        fpRate = [0; 1];
        tpRate = [0; 1];
        AUC = NaN;
        warning('外层第 %d 折测试集仅包含单一类别，跳过 perfcurve，AUC 记为 NaN。', fold);
        fprintf('   ☆ 本折 AUC(正类=Mineralized): NaN (测试集单一类别)\n');
    else
        [fpRate, tpRate, ~, AUC] = perfcurve(YOuterTest, YScore(:, posIdx), posClass);
        fprintf('   ☆ 本折 AUC(正类=Mineralized): %.4f\n', AUC);
    end

    rocData{fold} = struct('fpRate', fpRate, 'tpRate', tpRate, 'AUC', AUC, 'posClass', 'Mineralized');
    foldAUCs(fold) = AUC;

    % 自动标注“不确定类”：人工二次确认队列（不参与训练标签）
    [uncertaintyBand, pareto] = selectUncertaintyBand(YFinalVal, YPredVal, YScoreVal(:, posIdx), uncertaintyBandGrid, reviewPenalty);
    bestBandPerFold(fold) = uncertaintyBand;
    paretoData{fold} = pareto;
    predReview = markUncertainByScore(YScore(:, posIdx), uncertaintyBand);
    numReview = sum(predReview == "Uncertain_Review");
    fprintf('   ※ 本折最优 uncertaintyBand: %.3f | 不确定样本数(待人工复核): %d\n', uncertaintyBand, numReview);

    if foldAcc > bestAcc
        bestAcc = foldAcc;
        bestNet = netFold;
        bestFold = fold;
    end

    fig_cm = figure('Color', 'w', 'Visible', 'off', 'Position', [100,100,680,560]);
    cmChart = confusionchart(YOuterTest, YPred, 'RowSummary', 'row-normalized', 'ColumnSummary', 'column-normalized');
    cmChart.Title = sprintf('Fold %d Confusion Matrix', fold);
    cmChart.FontName = 'Times New Roman';
    cmChart.FontSize = 12;
    exportgraphics(fig_cm, fullfile(reportDir, sprintf('Fold_%02d_ConfusionMatrix.png', fold)), 'Resolution', 300);
    close(fig_cm);

    fig_roc = figure('Color', 'w', 'Visible', 'off', 'Position', [100,100,680,560]);
    plot(fpRate, tpRate, 'b-', 'LineWidth', 2); hold on;
    plot([0 1], [0 1], 'k--', 'LineWidth', 1.2);
    grid on; box on;
    xlabel('False Positive Rate', 'FontName', 'Times New Roman');
    ylabel('True Positive Rate', 'FontName', 'Times New Roman');
    if isnan(AUC)
        rocTitle = sprintf('Fold %d ROC Curve (AUC = NaN, single-class test fold)', fold);
    else
        rocTitle = sprintf('Fold %d ROC Curve (AUC = %.4f)', fold, AUC);
    end
    title(rocTitle, 'FontName', 'Times New Roman', 'FontWeight', 'bold');
    legend({'ROC', 'Random Guess'}, 'Location', 'southeast');
    set(gca, 'FontName', 'Times New Roman', 'FontSize', 12, 'LineWidth', 1.2);
    exportgraphics(fig_roc, fullfile(reportDir, sprintf('Fold_%02d_ROC.png', fold)), 'Resolution', 300);
    close(fig_roc);

    trace = boTrace{fold};
    fig_bo = figure('Color', 'w', 'Visible', 'off', 'Position', [100,100,680,560]);
    plot(trace.iter, trace.rawObj, 'o-', 'Color', [0.6 0.6 0.6], 'LineWidth', 1.0, 'MarkerSize', 4); hold on;
    plot(trace.iter, trace.bestObj, 'r-', 'LineWidth', 2.2);
    grid on; box on;
    xlabel('BO Iteration', 'FontName', 'Times New Roman');
    ylabel('Objective (Validation Error)', 'FontName', 'Times New Roman');
    title(sprintf('Fold %d Bayesian Optimization Convergence', fold), 'FontName', 'Times New Roman', 'FontWeight', 'bold');
    legend({'Observed Objective', 'Best-So-Far'}, 'Location', 'northeast');
    set(gca, 'FontName', 'Times New Roman', 'FontSize', 12, 'LineWidth', 1.2);
    exportgraphics(fig_bo, fullfile(reportDir, sprintf('Fold_%02d_BO_Convergence.png', fold)), 'Resolution', 300);
    close(fig_bo);

    % 论文图4：双目标前沿图（自动准确率-人工复核率）
    fig_pareto = figure('Color', 'w', 'Visible', 'off', 'Position', [100,100,680,560]);
    plot(pareto.reviewRate, pareto.autoAcc, 'o-', 'LineWidth', 1.8, 'Color', [0.1 0.45 0.85]); hold on;
    plot(pareto.reviewRate(pareto.bestIdx), pareto.autoAcc(pareto.bestIdx), 'rp', ...
        'MarkerSize', 12, 'MarkerFaceColor', 'r');
    grid on; box on;
    xlabel('Manual Review Rate', 'FontName', 'Times New Roman');
    ylabel('Auto Decision Accuracy', 'FontName', 'Times New Roman');
    title(sprintf('Fold %d Accuracy-Review Pareto (best band=%.3f)', fold, uncertaintyBand), ...
        'FontName', 'Times New Roman', 'FontWeight', 'bold');
    legend({'Band Grid Curve', 'Selected Band'}, 'Location', 'southeast');
    set(gca, 'FontName', 'Times New Roman', 'FontSize', 12, 'LineWidth', 1.2);
    exportgraphics(fig_pareto, fullfile(reportDir, sprintf('Fold_%02d_Pareto_AccReview.png', fold)), 'Resolution', 300);
    close(fig_pareto);
end

disp(' ');
disp('====== 嵌套交叉验证与超参数优化 全部结束 ======');

%% 4. 学术指标汇总与模型保存
meanAcc = mean(foldAccs) * 100; stdAcc = std(foldAccs) * 100;
meanF1 = mean(foldF1s);         stdF1 = std(foldF1s);
meanBAcc = mean(foldBAccs);     stdBAcc = std(foldBAccs);
meanAUC = mean(foldAUCs, 'omitnan'); stdAUC = std(foldAUCs, 'omitnan');

fprintf('\n==================================================\n');
fprintf('   Nested K-Fold + BO + 退火 + 多指标 实验报告（学术版）\n');
fprintf('==================================================\n');
fprintf('  外层评估折数 (K)    : %d\n', numOuter);
fprintf('  内层贝叶斯寻优次数  : %d 次/折\n', maxBO_iter);
fprintf('  各折测试准确率(%%)   : %s\n', mat2str(round(foldAccs * 100, 2)));
fprintf('  平均Acc ± Std       : %.2f%% ± %.2f%%\n', meanAcc, stdAcc);
fprintf('  平均F1  ± Std       : %.4f ± %.4f\n', meanF1, stdF1);
fprintf('  平均BAcc± Std       : %.4f ± %.4f\n', meanBAcc, stdBAcc);
fprintf('  平均AUC ± Std       : %.4f ± %.4f (正类=Mineralized)\n', meanAUC, stdAUC);
fprintf('  ------------------------------------------------\n');
fprintf('  (已保留第 %d 折产生的最高 Acc 模型用于 Grad-CAM 溯源)\n', bestFold);
fprintf('==================================================\n');

fig_allroc = figure('Color', 'w', 'Position', [100,100,760,620]); hold on; grid on; box on;
colors = lines(numOuter);
for k = 1:numOuter
    if isempty(rocData{k}), continue; end
    plot(rocData{k}.fpRate, rocData{k}.tpRate, '-', 'LineWidth', 1.8, 'Color', colors(k,:), ...
        'DisplayName', sprintf('Fold %d (AUC=%.3f)', k, rocData{k}.AUC));
end
plot([0 1], [0 1], 'k--', 'LineWidth', 1.2, 'DisplayName', 'Random Guess');
xlabel('False Positive Rate', 'FontName', 'Times New Roman');
ylabel('True Positive Rate', 'FontName', 'Times New Roman');
title(sprintf('Nested-CV ROC Curves (Mean AUC = %.4f ± %.4f)', meanAUC, stdAUC), ...
    'FontName', 'Times New Roman', 'FontWeight', 'bold');
legend('Location', 'southeast');
set(gca, 'FontName', 'Times New Roman', 'FontSize', 12, 'LineWidth', 1.2);
exportgraphics(fig_allroc, fullfile(reportDir, 'AllFolds_ROC_Summary.png'), 'Resolution', 300);
close(fig_allroc);

results = struct();
results.foldAccs = foldAccs;
results.foldF1s = foldF1s;
results.foldBAccs = foldBAccs;
results.foldAUCs = foldAUCs;
results.confMats = confMats;
results.rocData = rocData;
results.boTrace = boTrace;
results.bestFold = bestFold;
results.bestAcc = bestAcc;
results.bestHyperAll = bestHyperAll;
results.classList = classList;
results.rngSeed = 2026;
results.reportDir = reportDir;
results.bestBandPerFold = bestBandPerFold;
results.paretoData = paretoData;
results.uncertaintyBandGrid = uncertaintyBandGrid;
results.reviewPenalty = reviewPenalty;
results.uncertainRule = 'band tuned per-fold: |P(Mineralized)-0.5| <= bestBand => Uncertain_Review';
results.timestamp = datestr(now, 31);

save('Bronze_Acoustic_BO_CNN.mat', 'bestNet', 'results', '-v7.3');

%% 5. 可解释性 AI (XAI)：基于 Grad-CAM 的物理特征溯源可视化
disp('====== 开始生成 Grad-CAM 注意力热力图 ======');

tempInfo = load(fullfile(dataFolder, matFiles(1).name));
assert(isfield(tempInfo, 'T') && isfield(tempInfo, 'F'), 'Grad-CAM 绘图所需 T/F 缺失！');
T = tempInfo.T; F = tempInfo.F;

idx_intact = find(YLabels == "Intact", 1);
idx_mineral = find(YLabels == "Mineralized", 1);

test_indices = [idx_intact, idx_mineral];
class_names = ["Intact", "Mineralized"];

if all(isempty(test_indices))
    warning('未找到用于可视化的样本，跳过 Grad-CAM。');
    return;
end

layerNames = string({bestNet.Layers.Name});
if ~any(layerNames == "relu_3") || ~any(layerNames == "fc")
    warning('bestNet 中未找到 relu_3/fc 层名，Grad-CAM 跳过。');
    return;
end

figure('Color', 'w', 'Name', 'Grad-CAM 物理特征溯源 (最优折)', 'Position', [100, 100, 1000, 450]);
tiledlayout(1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

all_scoreMaps = cell(length(test_indices), 1);
all_vals = [];
for i = 1:length(test_indices)
    idx = test_indices(i);
    if isempty(idx) || isnan(idx), continue; end

    scoreMap = gradCAM(bestNet, XData(:, :, :, idx), YLabels(idx), 'FeatureLayer', 'relu_3', 'ReductionLayer', 'fc');
    all_scoreMaps{i} = scoreMap;
    all_vals = [all_vals; scoreMap(:)]; %#ok<AGROW>
end

if isempty(all_vals)
    warning('Grad-CAM 未得到有效激活图，跳过显示。');
    return;
end

global_max = max(all_vals);
if global_max <= 0
    global_max = 1;
end

for i = 1:length(test_indices)
    idx = test_indices(i);
    nexttile;

    if isempty(idx) || isnan(idx) || isempty(all_scoreMaps{i})
        text(0.5, 0.5, [char(class_names(i)), ' 样本缺失'], 'HorizontalAlignment', 'center', 'FontName', 'Times New Roman');
        axis off;
        continue;
    end

    img_tensor = XData(:, :, :, idx);
    scoreMap_norm = all_scoreMaps{i} / global_max;
    scoreMap_norm(scoreMap_norm > 1) = 1;
    scoreMap_norm(scoreMap_norm < 0) = 0;

    img_display = mat2gray(img_tensor);
    base_RGB = repmat(img_display, [1, 1, 3]);
    cmap = jet(256);
    heat_RGB = ind2rgb(gray2ind(scoreMap_norm, 256), cmap);

    alpha_val = 0.5;
    overlay_RGB = base_RGB .* (1 - alpha_val) + heat_RGB .* alpha_val;

    imagesc(T, F, overlay_RGB);
    axis xy; xlim([0 1.05]); ylim([0 8000]);
    set(gca, 'FontName', 'Times New Roman', 'FontSize', 12, 'LineWidth', 1.2);

    [predLabel, predScore] = classify(bestNet, XData(:, :, :, idx));
    mineralizedIdx = find(strcmp(categories(predLabel), 'Mineralized'), 1);
    if isempty(mineralizedIdx), mineralizedIdx = 1; end
    reviewFlag = markUncertainByScore(predScore(mineralizedIdx), 0.15);
    title(sprintf('%s | Pred: %s | %s', class_names(i), string(predLabel), reviewFlag), ...
        'FontName', 'Times New Roman', 'FontWeight', 'bold');
    xlabel('Time (s)', 'FontName', 'Times New Roman');
    if i == 1; ylabel('Frequency (Hz)', 'FontName', 'Times New Roman'); end
end

sgtitle('Visual Explanation via Grad-CAM (Best BO Model)', 'FontName', 'Times New Roman', 'FontSize', 16, 'FontWeight', 'bold');
disp('热力图渲染完毕！');

% =========================================================================
% 本地子函数区域
% =========================================================================

function valError = bayesOptObjectiveStable(optVars, XTrain, YTrain, XVal, YVal, H, W, numClasses, repeats, baseSeed)
    errs = zeros(repeats, 1);

    for r = 1:repeats
        rng(baseSeed + r, 'twister');

        layers = buildCNNLayers(H, W, numClasses, optVars.FCWidth, optVars.DropoutRate);

        options = trainingOptions('adam', ...
            'InitialLearnRate', optVars.InitialLearnRate, ...
            'L2Regularization', optVars.L2Regularization, ...
            'MaxEpochs', 12, ...
            'MiniBatchSize', min(16, length(YTrain)), ...
            'LearnRateSchedule', 'piecewise', ...
            'LearnRateDropFactor', 0.5, ...
            'LearnRateDropPeriod', 8, ...
            'ValidationData', {XVal, YVal}, ...
            'ValidationFrequency', max(1, floor(length(YTrain) / min(16, length(YTrain)))), ...
            'ValidationPatience', 3, ...
            'Verbose', false, ...
            'Plots', 'none');

        netBO = trainNetwork(XTrain, YTrain, layers, options);
        YPred = classify(netBO, XVal);
        valAcc = mean(YPred == YVal);
        errs(r) = 1 - valAcc;
    end

    valError = mean(errs);
end

function layers = buildCNNLayers(H, W, numClasses, fcWidth, dropoutRate)
    % 轻量学术结构：卷积特征提取 + GAP + FC128 + Dropout + 分类头
    % 说明：
    % 1) GAP 降低参数量、抑制过拟合；
    % 2) FC128 提供中等容量非线性表征；
    % 3) Dropout 提升泛化稳定性。
    if nargin < 4 || isempty(fcWidth)
        fcWidth = 128;
    end
    if nargin < 5 || isempty(dropoutRate)
        dropoutRate = 0.3;
    end
    dropoutRate = min(max(dropoutRate, 0.05), 0.8);
    fcWidth = max(16, round(fcWidth));

    layers = [
        imageInputLayer([H W 1], 'Normalization', 'zscore', 'Name', 'input')

        convolution2dLayer(3, 16, 'Padding', 'same', 'Name', 'conv_1')
        batchNormalizationLayer('Name', 'BN_1')
        reluLayer('Name', 'relu_1')
        maxPooling2dLayer(2, 'Stride', 2, 'Name', 'pool_1')

        convolution2dLayer(3, 32, 'Padding', 'same', 'Name', 'conv_2')
        batchNormalizationLayer('Name', 'BN_2')
        reluLayer('Name', 'relu_2')
        maxPooling2dLayer(2, 'Stride', 2, 'Name', 'pool_2')

        convolution2dLayer(3, 64, 'Padding', 'same', 'Name', 'conv_3')
        batchNormalizationLayer('Name', 'BN_3')
        reluLayer('Name', 'relu_3')
        maxPooling2dLayer(2, 'Stride', 2, 'Name', 'pool_3')

        globalAveragePooling2dLayer('Name', 'gap')
        fullyConnectedLayer(fcWidth, 'Name', 'fc_128')
        reluLayer('Name', 'relu_fc')
        dropoutLayer(dropoutRate, 'Name', 'dropout_03')

        fullyConnectedLayer(numClasses, 'Name', 'fc')
        softmaxLayer('Name', 'softmax')
        classificationLayer('Name', 'output')
    ];
end

function [F1, BAcc, cm] = calcMetricsBinary(yTrue, yPred, classList)
    cm = confusionmat(yTrue, yPred, 'Order', categorical(classList));

    if size(cm, 1) ~= 2 || size(cm, 2) ~= 2
        F1 = NaN;
        BAcc = NaN;
        return;
    end

    TN = cm(1,1); FP = cm(1,2);
    FN = cm(2,1); TP = cm(2,2);

    precision = TP / max(TP + FP, eps);
    recall    = TP / max(TP + FN, eps);
    F1        = 2 * precision * recall / max(precision + recall, eps);

    TNR = TN / max(TN + FP, eps);
    BAcc = (recall + TNR) / 2;
end

function trace = extractBOTrace(boResults)
    rawObj = boResults.ObjectiveTrace;
    rawObj = rawObj(:);
    iter = (1:numel(rawObj))';
    bestObj = cummin(rawObj);

    trace = struct();
    trace.iter = iter;
    trace.rawObj = rawObj;
    trace.bestObj = bestObj;
end

function outLabel = markUncertainByScore(scoreMineralized, band)
    if nargin < 2, band = 0.15; end
    scoreMineralized = max(min(scoreMineralized, 1), 0);
    if abs(scoreMineralized - 0.5) <= band
        outLabel = "Uncertain_Review";
    elseif scoreMineralized > 0.5
        outLabel = "Mineralized";
    else
        outLabel = "Intact";
    end
end

function [bestBand, pareto] = selectUncertaintyBand(yTrue, yPred, scoreMineralized, bandGrid, penalty)
    % 在验证集上自动折中“自动准确率”和“人工复核比例”
    % utility = autoAcc - penalty * reviewRate
    if nargin < 4 || isempty(bandGrid)
        bandGrid = 0.05:0.02:0.25;
    end
    if nargin < 5
        penalty = 0.2;
    end

    bestBand = 0.15;
    bestUtility = -inf;
    nBand = numel(bandGrid);
    autoAccVec = nan(nBand, 1);
    reviewRateVec = nan(nBand, 1);
    utilityVec = nan(nBand, 1);
    bestIdx = 1;

    for i = 1:nBand
        b = bandGrid(i);
        reviewLabels = markUncertainByScore(scoreMineralized, b);
        autoMask = reviewLabels ~= "Uncertain_Review";

        reviewRate = 1 - mean(autoMask);
        if any(autoMask)
            autoAcc = mean(yPred(autoMask) == yTrue(autoMask));
        else
            autoAcc = 0;
        end

        utility = autoAcc - penalty * reviewRate;
        autoAccVec(i) = autoAcc;
        reviewRateVec(i) = reviewRate;
        utilityVec(i) = utility;
        if utility > bestUtility
            bestUtility = utility;
            bestBand = b;
            bestIdx = i;
        end
    end

    pareto = struct();
    pareto.bandGrid = bandGrid(:);
    pareto.autoAcc = autoAccVec;
    pareto.reviewRate = reviewRateVec;
    pareto.utility = utilityVec;
    pareto.bestIdx = bestIdx;
end
