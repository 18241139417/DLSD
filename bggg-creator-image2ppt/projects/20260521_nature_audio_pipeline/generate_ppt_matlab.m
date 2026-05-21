%% Interactive image -> layered editable PPT (MATLAB + PowerPoint COM)
% 按最初指令：把元素拆成独立图层，便于编辑。
% 流程：
% 1) 选择 PNG/JPG 原图
% 2) 选择若干 ROI 作为独立组件图层（双击完成每个框，回车结束）
% 3) 每个 ROI 导出为透明度无损 PNG（矩形裁切），分别放入 PPT 独立图层
% 4) 额外添加可编辑文本框（标题/注释）

[fn, fp] = uigetfile({'*.png;*.jpg;*.jpeg','Image Files (*.png,*.jpg,*.jpeg)'}, '选择要转换的图片');
if isequal(fn,0), error('未选择图片，已取消。'); end
imgPath = fullfile(fp, fn);
[~, baseName, ~] = fileparts(imgPath);

img = imread(imgPath);
info = imfinfo(imgPath);
pxW = double(info.Width); pxH = double(info.Height);

assetDir = fullfile(fp, [baseName '_layers']);
if ~exist(assetDir,'dir'), mkdir(assetDir); end

% 交互式框选组件
h = figure('Name','框选要拆分的组件图层（回车结束）','NumberTitle','off');
imshow(img); title('依次框选组件图层，完成双击；全部结束请按 Enter');
rois = {};
idx = 1;
while true
    r = drawrectangle('Color',[0 0.4470 0.7410]);
    if isempty(r), break; end
    pos = round(r.Position); % [x y w h]
    if any(pos(3:4) <= 1)
        delete(r);
        break;
    end
    rois{idx} = pos; %#ok<AGROW>
    idx = idx + 1;
    waitforbuttonpress;
    % Enter 结束；其他键继续
    ch = get(h,'CurrentCharacter');
    if double(ch) == 13
        break;
    end
end
close(h);

% 导出 ROI 组件
layerFiles = {};
for i = 1:numel(rois)
    p = rois{i};
    x1 = max(1,p(1)); y1 = max(1,p(2));
    x2 = min(size(img,2), p(1)+p(3)-1);
    y2 = min(size(img,1), p(2)+p(4)-1);
    crop = img(y1:y2, x1:x2, :);
    layerName = sprintf('layer_%02d.png', i);
    layerPath = fullfile(assetDir, layerName);
    imwrite(crop, layerPath);
    layerFiles{i} = layerPath; %#ok<AGROW>
end

% 幻灯片尺寸按原图比例
slideW_in = 13.333;
slideH_in = slideW_in * (pxH / pxW);
slideW_pt = slideW_in * 72;
slideH_pt = slideH_in * 72;
px2pt = @(x,y,w,h) [x/pxW*slideW_pt, y/pxH*slideH_pt, w/pxW*slideW_pt, h/pxH*slideH_pt];

outFile = fullfile(fp, [baseName '_editable_layers.pptx']);

ppt = actxserver('PowerPoint.Application');
ppt.Visible = 1;
pres = ppt.Presentations.Add;
pres.PageSetup.SlideWidth = slideW_pt;
pres.PageSetup.SlideHeight = slideH_pt;
slide = invoke(pres.Slides, 'Add', 1, 12); % blank

% 底图作为参考层（可删）
bg = slide.Shapes.AddPicture(imgPath, 0, -1, 0, 0, slideW_pt, slideH_pt);
bg.Name = 'reference_background';

% 逐个组件独立图层
for i = 1:numel(rois)
    p = rois{i};
    q = px2pt(p(1), p(2), p(3), p(4));
    shp = slide.Shapes.AddPicture(layerFiles{i}, 0, -1, q(1), q(2), q(3), q(4));
    shp.Name = sprintf('component_%02d', i);
end

% 可编辑文本层
tb1 = slide.Shapes.AddTextbox(1, 0.03*slideW_pt, 0.02*slideH_pt, 0.94*slideW_pt, 0.06*slideH_pt);
tr1 = tb1.TextFrame.TextRange;
tr1.Text = 'Editable Title (Arial)';
tr1.Font.Name = 'Arial'; tr1.Font.Size = 18; tr1.Font.Bold = -1;
tr1.Font.Color.RGB = rgb2ppt([17 24 39]);
tb1.Name = 'text_title';

tb2 = slide.Shapes.AddTextbox(1, 0.03*slideW_pt, 0.92*slideH_pt, 0.94*slideW_pt, 0.05*slideH_pt);
tr2 = tb2.TextFrame.TextRange;
tr2.Text = 'Editable Caption / Notes';
tr2.Font.Name = 'Arial'; tr2.Font.Size = 11; tr2.Font.Bold = 0;
tr2.Font.Color.RGB = rgb2ppt([75 85 99]);
tb2.Name = 'text_caption';

pres.SaveAs(outFile);
pres.Close; ppt.Quit; delete(ppt);

fprintf('已生成分层PPT: %s\n', outFile);
fprintf('组件图层数量: %d\n', numel(rois));
fprintf('组件目录: %s\n', assetDir);

function c = rgb2ppt(rgb)
c = rgb(1) + bitshift(rgb(2),8) + bitshift(rgb(3),16);
end
