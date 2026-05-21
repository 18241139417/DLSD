%% Auto image -> layered editable PPT (MATLAB + PowerPoint COM)
% 自动识别并分离组件（无需手动框选）
% 输出：
% 1) <image>_editable_layers.pptx
% 2) <image>_layers_auto/ 组件PNG
% 3) <image>_layers_auto/components.json 组件坐标

[fn, fp] = uigetfile({'*.png;*.jpg;*.jpeg','Image Files (*.png,*.jpg,*.jpeg)'}, '选择要转换的图片');
if isequal(fn,0), error('未选择图片，已取消。'); end
imgPath = fullfile(fp, fn);
[~, baseName, ~] = fileparts(imgPath);

I = imread(imgPath);
if size(I,3) == 1
    Irgb = repmat(I,[1 1 3]);
else
    Irgb = I;
end
G = rgb2gray(Irgb);
[pxH, pxW, ~] = size(Irgb);

assetDir = fullfile(fp, [baseName '_layers_auto']);
if ~exist(assetDir,'dir'), mkdir(assetDir); end

%% ---- 自动组件检测 ----
% 思路：边缘 + 形态学闭合 + 连通域筛选，提取模块级组件
BW = edge(G, 'Canny');
BW = imdilate(BW, strel('rectangle',[3 3]));
BW = imclose(BW, strel('rectangle',[15 15]));
BW = imfill(BW, 'holes');
BW = bwareaopen(BW, round(pxW*pxH*0.00035));

CC = bwconncomp(BW);
stats = regionprops(CC, 'BoundingBox', 'Area', 'Extent');

boxes = [];
minArea = pxW * pxH * 0.002;   % 过滤微小噪声
maxArea = pxW * pxH * 0.92;    % 排除整页背景
for k = 1:numel(stats)
    bb = stats(k).BoundingBox; % [x y w h]
    area = bb(3) * bb(4);
    if area < minArea || area > maxArea
        continue;
    end
    if bb(3) < 30 || bb(4) < 20
        continue;
    end
    boxes(end+1,:) = bb; %#ok<AGROW>
end

% 若检测失败，退化为单组件（整图）
if isempty(boxes)
    boxes = [1 1 pxW pxH];
end

% 非极大合并：去重重叠框
boxes = mergeOverlaps(boxes, 0.55);

%% ---- 导出组件图 ----
layerFiles = cell(size(boxes,1),1);
components = struct('name',{},'x',{},'y',{},'w',{},'h',{},'file',{});
for i = 1:size(boxes,1)
    bb = boxes(i,:);
    x1 = max(1, floor(bb(1)));
    y1 = max(1, floor(bb(2)));
    x2 = min(pxW, ceil(bb(1)+bb(3)-1));
    y2 = min(pxH, ceil(bb(2)+bb(4)-1));

    crop = Irgb(y1:y2, x1:x2, :);
    fname = sprintf('component_%03d.png', i);
    fpath = fullfile(assetDir, fname);
    imwrite(crop, fpath);
    layerFiles{i} = fpath;

    components(i).name = sprintf('component_%03d', i);
    components(i).x = x1; components(i).y = y1;
    components(i).w = x2-x1+1; components(i).h = y2-y1+1;
    components(i).file = fname;
end

jsonText = jsonencode(components);
fid = fopen(fullfile(assetDir,'components.json'),'w'); fwrite(fid,jsonText,'char'); fclose(fid);

%% ---- 生成PPT（独立图层）----
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
slide = invoke(pres.Slides, 'Add', 1, 12);

% 背景层（可删）
bg = slide.Shapes.AddPicture(imgPath, 0, -1, 0, 0, slideW_pt, slideH_pt);
bg.Name = 'reference_background';
bg.ZOrder(1); % send backward

% 自动组件层
for i = 1:numel(components)
    c = components(i);
    q = px2pt(c.x, c.y, c.w, c.h);
    shp = slide.Shapes.AddPicture(fullfile(assetDir,c.file), 0, -1, q(1), q(2), q(3), q(4));
    shp.Name = c.name;
end

% 可编辑文本层：自动标题和注释（可直接改）
tb1 = slide.Shapes.AddTextbox(1, 0.03*slideW_pt, 0.02*slideH_pt, 0.94*slideW_pt, 0.06*slideH_pt);
tr1 = tb1.TextFrame.TextRange;
tr1.Text = 'Editable Title (Auto-layered)';
tr1.Font.Name = 'Arial'; tr1.Font.Size = 18; tr1.Font.Bold = -1;
tr1.Font.Color.RGB = rgb2ppt([17 24 39]);
tb1.Name = 'text_title';

tb2 = slide.Shapes.AddTextbox(1, 0.03*slideW_pt, 0.92*slideH_pt, 0.94*slideW_pt, 0.05*slideH_pt);
tr2 = tb2.TextFrame.TextRange;
tr2.Text = sprintf('Auto components: %d', numel(components));
tr2.Font.Name = 'Arial'; tr2.Font.Size = 11; tr2.Font.Bold = 0;
tr2.Font.Color.RGB = rgb2ppt([75 85 99]);
tb2.Name = 'text_caption';

pres.SaveAs(outFile);
pres.Close; ppt.Quit; delete(ppt);

fprintf('已生成分层PPT: %s\n', outFile);
fprintf('自动识别组件数: %d\n', numel(components));
fprintf('组件目录: %s\n', assetDir);

%% ---------- helpers ----------
function c = rgb2ppt(rgb)
c = rgb(1) + bitshift(rgb(2),8) + bitshift(rgb(3),16);
end

function boxesOut = mergeOverlaps(boxesIn, iouThr)
if isempty(boxesIn), boxesOut = boxesIn; return; end
boxes = boxesIn;
keep = true(size(boxes,1),1);
for i = 1:size(boxes,1)
    if ~keep(i), continue; end
    bi = boxes(i,:);
    for j = i+1:size(boxes,1)
        if ~keep(j), continue; end
        bj = boxes(j,:);
        iou = calcIoU(bi,bj);
        if iou > iouThr
            % 保留面积更大的框
            ai = bi(3)*bi(4); aj = bj(3)*bj(4);
            if ai >= aj
                keep(j) = false;
            else
                keep(i) = false;
                break;
            end
        end
    end
end
boxesOut = boxes(keep,:);
end

function v = calcIoU(a,b)
ax1=a(1); ay1=a(2); ax2=a(1)+a(3); ay2=a(2)+a(4);
bx1=b(1); by1=b(2); bx2=b(1)+b(3); by2=b(2)+b(4);
ix1=max(ax1,bx1); iy1=max(ay1,by1);
ix2=min(ax2,bx2); iy2=min(ay2,by2);
iw=max(0,ix2-ix1); ih=max(0,iy2-iy1);
inter=iw*ih;
ua=a(3)*a(4)+b(3)*b(4)-inter;
if ua<=0, v=0; else, v=inter/ua; end
end
