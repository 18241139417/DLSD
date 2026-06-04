%% =========================================================================
% 【Codex规格 C】MobileNetV2迁移学习主方案
% 文件名：bronze_mobilenet_transfer.m
% 语言：MATLAB R2021a及以上
% 工具箱：Deep Learning Toolbox（使用本地 assembleMobileNetv2 预训练权重）
%% =========================================================================

clear; clc; close all;
rng(2026, 'twister');

%% 第三方MobileNetV2路径（离线环境）
% 若以下默认路径不存在，请手动修改为 assembleMobileNetv2.m 所在目录
mobileNetLocalDir = 'E:\10-43\矿化程度声学表征\代码\mobilenet-v2-master';
if exist(mobileNetLocalDir, 'dir')
    addpath(mobileNetLocalDir);
else
    warning('未找到默认MobileNet目录：%s。将尝试使用当前路径中的 assembleMobileNetv2。', mobileNetLocalDir);
end

if exist('assembleMobileNetv2', 'file') ~= 2
    error(['未找到 assembleMobileNetv2.m。请确认第三方mobilenet-v2-master已放置到脚本可搜索路径，' ...
           '或手动执行 addpath(你的mobilenet目录)。']);
end

%% 顶部参数区（仿照bronze_acoustic_bo_cnn.m风格）
Outer_K      = 5;           % 外层K折（分层），样本<K时自动退化为LOOCV
maxBO_iter   = 15;          % 贝叶斯优化迭代次数
innerHoldout = 0.2;         % 内层验证比例
maxEpochs    = 30;          % 微调最大轮次（仅训练分类头，收敛快）
reportDir    = fullfile(pwd, 'MobileNet_Paper_Figures');

if ~exist(reportDir, 'dir')
    mkdir(reportDir);
end

%% 数据加载（与bronze_acoustic_bo_cnn.m完全相同）
dataFolder = uigetdir(pwd, '选择包含 *_matrix.mat 文件的数据文件夹');
if isequal(dataFolder, 0)
    error('未选择数据文件夹，脚本终止。');
end

fileList = dir(fullfile(dataFolder, '*_matrix.mat'));
if isempty(fileList)
    error('在所选目录下未找到 *_matrix.mat 文件。');
end

numSamples = numel(fileList);
XCell = cell(numSamples, 1);
YCell = cell(numSamples, 1);

for i = 1:numSamples
    data = load(fullfile(fileList(i).folder, fileList(i).name));
    if ~isfield(data, 'log_spec_matrix')
        error('文件 %s 不含字段 log_spec_matrix。', fileList(i).name);
    end
    spec = single(data.log_spec_matrix);
    XCell{i} = spec;

    lowerName = lower(fileList(i).name);
    if contains(lowerName, 'bad') || contains(lowerName, 'mineral')
        YCell{i} = 'Mineralized';
    else
        YCell{i} = 'Intact';
    end
end

H = size(XCell{1}, 1);
W = size(XCell{1}, 2);
resizeCount = 0;
for i = 2:numSamples
    curH = size(XCell{i}, 1);
    curW = size(XCell{i}, 2);
    if ~isequal([curH, curW], [H, W])
        XCell{i} = imresize(XCell{i}, [H, W]);
        resizeCount = resizeCount + 1;
        warning('样本尺寸不一致：%s 原始尺寸为 [%d %d]，已重采样到 [%d %d]。', ...
            fileList(i).name, curH, curW, H, W);
    end
end
if resizeCount > 0
    fprintf('检测到 %d 个样本尺寸与首样本不一致，已统一重采样到 [%d %d]。\n', resizeCount, H, W);
end

XData = zeros(H, W, 1, numSamples, 'single');
for i = 1:numSamples
    XData(:,:,1,i) = XCell{i};
end
YLabels = categorical(YCell);
classes = categories(YLabels);
numClasses = numel(classes);
if numClasses ~= 2
    error('当前方案要求二分类，但检测到 %d 个类别。', numClasses);
end

%% MobileNetV2预处理（关键步骤，不得省略）
% 盗版/离线MATLAB场景：使用本地第三方 assembleMobileNetv2，不调用官方 mobilenetv2()
net_pretrained = assembleMobileNetv2();
inputSize = net_pretrained.Layers(1).InputSize;

XData_MN = zeros(inputSize(1), inputSize(2), inputSize(3), numSamples, 'single');
for i = 1:numSamples
    XData_MN(:,:,:,i) = preprocessForMobileNet(XData(:,:,1,i), inputSize);
end

%% 外层CV设置（样本<K时自动退化为LOOCV）
kOuter = min(Outer_K, numSamples);
if kOuter < 2
    error('样本数量不足以进行交叉验证。');
end
outerCV = cvpartition(YLabels, 'KFold', kOuter);

results = struct();
results.fold = repmat(struct(), kOuter, 1);
allScores = nan(numSamples, 1);
allTrue = strings(numSamples, 1);
bestFoldAUC = -inf;
bestNet = [];
bestFoldInfo = struct();

optimVars = [
    optimizableVariable('InitialLearnRate', [1e-5,1e-2], 'Transform', 'log')
    optimizableVariable('FCWidth', [32,256], 'Type', 'integer')
];

for fold = 1:kOuter
    fprintf('\n========== Outer Fold %d/%d ==========' , fold, kOuter); fprintf('\n');

    idxTrain = training(outerCV, fold);
    idxTest  = test(outerCV, fold);

    XOuterTrain = XData_MN(:,:,:,idxTrain);
    YOuterTrain = YLabels(idxTrain);
    XOuterTest  = XData_MN(:,:,:,idxTest);
    YOuterTest  = YLabels(idxTest);

    innerCV = cvpartition(YOuterTrain, 'HoldOut', innerHoldout);
    XInnerTrain = XOuterTrain(:,:,:,training(innerCV));
    YInnerTrain = YOuterTrain(training(innerCV));
    XInnerVal   = XOuterTrain(:,:,:,test(innerCV));
    YInnerVal   = YOuterTrain(test(innerCV));

    ObjFcn = @(optVars) bayesOptMobileNet( ...
        optVars, XInnerTrain, YInnerTrain, XInnerVal, YInnerVal, ...
        net_pretrained, numClasses);

    boResults = bayesopt(ObjFcn, optimVars, ...
        'MaxObjectiveEvaluations', maxBO_iter, ...
        'AcquisitionFunctionName', 'expected-improvement-plus', ...
        'Verbose', 0, ...
        'PlotFcn', {});

    bestHyp = bestPoint(boResults);

    finalCV = cvpartition(YOuterTrain, 'HoldOut', 0.15);
    XFinalTrain = XOuterTrain(:,:,:,training(finalCV));
    YFinalTrain = YOuterTrain(training(finalCV));
    XFinalVal   = XOuterTrain(:,:,:,test(finalCV));
    YFinalVal   = YOuterTrain(test(finalCV));

    lgraph = buildMobileNetTransferLayers(net_pretrained, numClasses, bestHyp.FCWidth, 0.3);
    nTrain = numel(YFinalTrain);
    miniBatch = min(16, nTrain);

    trainOpts = trainingOptions('adam', ...
        'InitialLearnRate', bestHyp.InitialLearnRate, ...
        'L2Regularization', 1e-4, ...
        'MaxEpochs', maxEpochs, ...
        'MiniBatchSize', miniBatch, ...
        'Shuffle', 'every-epoch', ...
        'LearnRateSchedule', 'piecewise', ...
        'LearnRateDropFactor', 0.5, ...
        'LearnRateDropPeriod', 10, ...
        'ValidationData', {XFinalVal, YFinalVal}, ...
        'ValidationFrequency', max(1, floor(nTrain / miniBatch)), ...
        'ValidationPatience', 5, ...
        'Plots', 'none', ...
        'Verbose', false);

    netFold = trainNetwork(XFinalTrain, YFinalTrain, lgraph, trainOpts);

    [YPred, scores] = classify(netFold, XOuterTest);
    [acc, f1, bacc, auc, cm, fpr, tpr] = calcMetricsBinary(YOuterTest, YPred, scores, 'Mineralized');

    % 保存外层预测
    testIdxGlobal = find(idxTest);
    posIdx = getScorePositiveIndex(netFold, 'Mineralized', YOuterTest);
    allScores(testIdxGlobal) = scores(:, posIdx);
    allTrue(testIdxGlobal) = string(YOuterTest);

    % 保存每折结果
    results.fold(fold).bestHyp = bestHyp;
    results.fold(fold).acc = acc;
    results.fold(fold).f1 = f1;
    results.fold(fold).bacc = bacc;
    results.fold(fold).auc = auc;
    results.fold(fold).confMat = cm;

    % 每折图输出
    figCM = figure('Visible', 'off');
    confusionchart(cm, categories(YOuterTest));
    title(sprintf('Fold %d Confusion Matrix', fold));
    saveas(figCM, fullfile(reportDir, sprintf('Fold_%d_Confusion.png', fold)));
    close(figCM);

    figROC = figure('Visible', 'off');
    plot(fpr, tpr, 'LineWidth', 1.8); hold on; plot([0,1],[0,1],'k--');
    xlabel('False Positive Rate'); ylabel('True Positive Rate');
    title(sprintf('Fold %d ROC (AUC=%.3f)', fold, auc)); grid on;
    saveas(figROC, fullfile(reportDir, sprintf('Fold_%d_ROC.png', fold)));
    close(figROC);

    figBO = figure('Visible', 'off');
    traceVals = extractBOTrace(boResults);
    plot(traceVals, '-o', 'LineWidth', 1.5);
    xlabel('Iteration'); ylabel('Best Objective (Val Error)');
    title(sprintf('Fold %d BO Convergence', fold)); grid on;
    saveas(figBO, fullfile(reportDir, sprintf('Fold_%d_BO_Trace.png', fold)));
    close(figBO);

    if auc > bestFoldAUC
        bestFoldAUC = auc;
        bestNet = netFold;
        bestFoldInfo.fold = fold;
        bestFoldInfo.idxTest = idxTest;
    end
end

%% 汇总ROC
validMask = ~isnan(allScores);
YAll = categorical(allTrue(validMask));
SAll = allScores(validMask);
[posClass, ~] = findPositiveClass(YAll, 'Mineralized');
[Xroc, Yroc, ~, AUCAll] = perfcurve(YAll, SAll, posClass);
figAll = figure('Visible', 'off');
plot(Xroc, Yroc, 'LineWidth', 2); hold on; plot([0,1],[0,1],'k--');
grid on; xlabel('FPR'); ylabel('TPR');
title(sprintf('All Folds ROC Summary (AUC=%.3f)', AUCAll));
saveas(figAll, fullfile(reportDir, 'AllFolds_ROC_Summary.png'));
close(figAll);

%% Grad-CAM（最优折示例）
if ~isempty(bestNet)
    idxBestTest = find(bestFoldInfo.idxTest);
    if ~isempty(idxBestTest)
        sampleIdx = idxBestTest(1);
        originalSpec = XData(:,:,1,sampleIdx);
        inputImg = XData_MN(:,:,:,sampleIdx);
        cam = gradCAM(bestNet, inputImg, 'Mineralized', ...
            'FeatureLayer', 'out_relu', ...
            'ReductionLayer', 'fc_output');

        camResized = imresize(cam, [H, W]);
        camNorm = camResized ./ max(camResized(:) + eps);
        cmap = jet(256);
        camRGB = ind2rgb(uint8(camNorm*255), cmap);
        baseRGB = repmat(mat2gray(originalSpec), [1,1,3]);
        alpha = 0.5;
        overlay = (1-alpha)*baseRGB + alpha*camRGB;

        figCAM = figure('Visible', 'off');
        imagesc(overlay); axis image off;
        title(sprintf('Grad-CAM Overlay (Fold %d)', bestFoldInfo.fold));
        saveas(figCAM, fullfile(reportDir, 'GradCAM_BestFold.png'));
        close(figCAM);
    end
end

%% 结果汇总输出与保存
accs = arrayfun(@(s) s.acc, results.fold);
f1s  = arrayfun(@(s) s.f1, results.fold);
bacs = arrayfun(@(s) s.bacc, results.fold);
aucs = arrayfun(@(s) s.auc, results.fold);

fprintf('\n===== MobileNetV2 Transfer Learning Results =====\n');
fprintf('Acc : %.4f ± %.4f\n', mean(accs), std(accs));
fprintf('F1  : %.4f ± %.4f\n', mean(f1s), std(f1s));
fprintf('BAcc: %.4f ± %.4f\n', mean(bacs), std(bacs));
fprintf('AUC : %.4f ± %.4f\n', mean(aucs), std(aucs));

save(fullfile(reportDir, 'Bronze_MobileNet_Transfer.mat'), 'bestNet', 'results', 'bestFoldInfo');

%% ====== Local Functions ======
function imgOut = preprocessForMobileNet(specMat, inputSize)
    img = single(specMat);
    img = max(0, min(1, img));
    imgResized = imresize(img, inputSize(1:2));
    imgOut = repmat(imgResized, [1, 1, 3]);
    imgOut = single(imgOut);
end

function lgraph = buildMobileNetTransferLayers(net_pretrained, numClasses, fcWidth, dropoutRate)
    lgraph = layerGraph(net_pretrained);
    layers = lgraph.Layers;

    last_conv_relu_name = 'out_relu';
    if ~any(strcmp({layers.Name}, last_conv_relu_name))
        error('未找到指定特征层：%s。', last_conv_relu_name);
    end

    % 第三方 assembleMobileNetv2 常见尾部层（含 GAP）需要一并移除，避免出现未连接输出
    removeNamesRequired = {'Logits', 'Logits_softmax', 'ClassificationLayer_Logits'};
    if ~all(ismember(removeNamesRequired, {layers.Name}))
        error('分类头层缺失，无法按预期删除：%s', strjoin(removeNamesRequired, ', '));
    end
    removeNamesOptional = {'global_average_pooling2d_1'};
    removeNames = [removeNamesRequired, removeNamesOptional(ismember(removeNamesOptional, {layers.Name}))];
    lgraph = removeLayers(lgraph, removeNames);

    for i = 1:numel(lgraph.Layers)
        lyr = lgraph.Layers(i);
        if isa(lyr, 'nnet.cnn.layer.Convolution2DLayer')
            lyr.WeightLearnRateFactor = 0;
            lyr.BiasLearnRateFactor = 0;
            lgraph = replaceLayer(lgraph, lyr.Name, lyr);
        elseif isa(lyr, 'nnet.cnn.layer.BatchNormalizationLayer')
            lyr.OffsetLearnRateFactor = 0;
            lyr.ScaleLearnRateFactor = 0;
            lyr.TrainedMean = lyr.TrainedMean;
            lyr.TrainedVariance = lyr.TrainedVariance;
            lgraph = replaceLayer(lgraph, lyr.Name, lyr);
        end
    end

    newHead = [
        globalAveragePooling2dLayer('Name', 'gap_transfer')
        fullyConnectedLayer(fcWidth, 'Name', 'fc_transfer')
        reluLayer('Name', 'relu_transfer')
        dropoutLayer(dropoutRate, 'Name', 'dropout_transfer')
        fullyConnectedLayer(numClasses, 'Name', 'fc_output')
        softmaxLayer('Name', 'softmax_output')
        classificationLayer('Name', 'output')
    ];

    lgraph = addLayers(lgraph, newHead);
    lgraph = connectLayers(lgraph, last_conv_relu_name, 'gap_transfer');
end

function objective = bayesOptMobileNet(optVars, XTrain, YTrain, XVal, YVal, net_pretrained, numClasses)
    lgraph = buildMobileNetTransferLayers(net_pretrained, numClasses, optVars.FCWidth, 0.3);
    nTrain = numel(YTrain);
    miniBatch = min(16, nTrain);

    opts = trainingOptions('adam', ...
        'InitialLearnRate', optVars.InitialLearnRate, ...
        'L2Regularization', 1e-4, ...
        'MaxEpochs', 15, ...
        'MiniBatchSize', miniBatch, ...
        'Shuffle', 'every-epoch', ...
        'ValidationData', {XVal, YVal}, ...
        'ValidationFrequency', max(1, floor(nTrain / miniBatch)), ...
        'ValidationPatience', 3, ...
        'Verbose', false, ...
        'Plots', 'none');

    net = trainNetwork(XTrain, YTrain, lgraph, opts);
    YPred = classify(net, XVal);
    objective = 1 - mean(YPred == YVal);
end

function [acc, f1, bacc, auc, cm, fpr, tpr] = calcMetricsBinary(yTrue, yPred, scores, posClassName)
    yTrue = categorical(yTrue);
    yPred = categorical(yPred);
    [posClass, posIdx] = findPositiveClass(yTrue, posClassName);

    cm = confusionmat(yTrue, yPred, 'Order', categories(yTrue));
    acc = mean(yTrue == yPred);

    yTruePos = (yTrue == posClass);
    yPredPos = (yPred == posClass);

    tp = sum(yTruePos & yPredPos);
    fp = sum(~yTruePos & yPredPos);
    fn = sum(yTruePos & ~yPredPos);
    tn = sum(~yTruePos & ~yPredPos);

    precision = tp / max(tp + fp, eps);
    recall = tp / max(tp + fn, eps);
    f1 = 2 * precision * recall / max(precision + recall, eps);
    tprPos = tp / max(tp + fn, eps);
    tnr = tn / max(tn + fp, eps);
    bacc = 0.5 * (tprPos + tnr);

    [fpr, tpr, ~, auc] = perfcurve(yTrue, scores(:, posIdx), posClass);
end

function [posClass, posIdx] = findPositiveClass(yCat, posClassName)
    cats = categories(yCat);
    posIdx = find(strcmp(cats, posClassName), 1);
    if isempty(posIdx)
        error('未找到正类 %s。', posClassName);
    end
    posClass = categorical(string(posClassName), cats);
end

function traceVals = extractBOTrace(boResults)
    vals = boResults.ObjectiveTrace;
    traceVals = cummin(vals);
end

function idxUncertain = markUncertainByScore(scoresPos, lowThr, highThr)
    idxUncertain = (scoresPos >= lowThr) & (scoresPos <= highThr);
end

function [lowThr, highThr] = selectUncertaintyBand(scoresPos, bandWidth)
    lowThr = max(0, 0.5 - bandWidth/2);
    highThr = min(1, 0.5 + bandWidth/2);
    if nargin < 2
        lowThr = 0.4;
        highThr = 0.6;
    end
end

function posIdx = getScorePositiveIndex(netObj, posClassName, yRef)
    posIdx = [];
    if isprop(netObj.Layers(end), 'Classes')
        classNames = string(netObj.Layers(end).Classes);
        posIdx = find(classNames == string(posClassName), 1);
    end
    if isempty(posIdx)
        [~, posIdx] = ismember(posClassName, categories(categorical(yRef)));
    end
    if isempty(posIdx) || posIdx < 1
        error('无法确定正类 %s 在 scores 中的列索引。', posClassName);
    end
end
