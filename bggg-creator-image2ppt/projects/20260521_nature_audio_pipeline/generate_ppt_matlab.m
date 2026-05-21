%% Auto image -> editable PPT (no single big pasted image)
% 目标：不要整页大图；自动拆分组件图片 + OCR文本框（可编辑）
% 输出：
%   <name>_editable.pptx
%   <name>_layers_auto/component_XXX.png
%   <name>_layers_auto/components.json

[fn, fp] = uigetfile({'*.png;*.jpg;*.jpeg','Image Files (*.png,*.jpg,*.jpeg)'}, '选择要转换的图片');
if isequal(fn,0), error('未选择图片，已取消。'); end
imgPath = fullfile(fp, fn);
[~, baseName, ~] = fileparts(imgPath);

I0 = imread(imgPath);
if size(I0,3)==1, I = repmat(I0,[1 1 3]); else, I = I0; end
G = rgb2gray(I);
[H,W,~] = size(I);

assetDir = fullfile(fp, [baseName '_layers_auto']);
if ~exist(assetDir,'dir'), mkdir(assetDir); end

%% 1) OCR 提取文本（转原生文本框）
ocrRes = ocr(I);
words = ocrRes.Words;
wb = ocrRes.WordBoundingBoxes;
conf = ocrRes.WordConfidences;
valid = ~cellfun(@isempty,words) & conf>0.45;
words = words(valid); wb = wb(valid,:);

%% 2) 图像组件提取（排除文本区域）
BW = edge(G,'Canny');
BW = imdilate(BW, strel('rectangle',[3 3]));
BW = imclose(BW, strel('rectangle',[13 13]));
BW = imfill(BW,'holes');
BW = bwareaopen(BW, round(W*H*0.00025));

% 把OCR文本区从图像组件mask中剔除
textMask = false(H,W);
for i=1:size(wb,1)
    b = round(wb(i,:)); % x y w h
    x1=max(1,b(1)); y1=max(1,b(2)); x2=min(W,b(1)+b(3)-1); y2=min(H,b(2)+b(4)-1);
    textMask(y1:y2, x1:x2)=true;
end
BW(textMask)=0;

CC = bwconncomp(BW);
st = regionprops(CC,'BoundingBox');
boxes=[];
for i=1:numel(st)
    bb = st(i).BoundingBox;
    a = bb(3)*bb(4);
    if a < W*H*0.0015 || a > W*H*0.85, continue; end
    if bb(3)<20 || bb(4)<20, continue; end
    boxes(end+1,:)=bb; %#ok<AGROW>
end
boxes = mergeOverlaps(boxes,0.5);

%% 3) 导出组件PNG
components = struct('name',{},'x',{},'y',{},'w',{},'h',{},'file',{});
for i=1:size(boxes,1)
    b=boxes(i,:);
    x1=max(1,floor(b(1))); y1=max(1,floor(b(2)));
    x2=min(W,ceil(b(1)+b(3)-1)); y2=min(H,ceil(b(2)+b(4)-1));
    crop=I(y1:y2,x1:x2,:);
    fnc=sprintf('component_%03d.png',i);
    imwrite(crop, fullfile(assetDir,fnc));
    components(i).name=sprintf('component_%03d',i);
    components(i).x=x1; components(i).y=y1; components(i).w=x2-x1+1; components(i).h=y2-y1+1;
    components(i).file=fnc;
end
fid=fopen(fullfile(assetDir,'components.json'),'w'); fwrite(fid,jsonencode(components),'char'); fclose(fid);

%% 4) 生成PPT（只放组件，不放整页大图）
slideW_in=13.333; slideH_in=slideW_in*(H/W);
SW=slideW_in*72; SH=slideH_in*72;
px2pt=@(x,y,w,h)[x/W*SW, y/H*SH, w/W*SW, h/H*SH];
outFile=fullfile(fp,[baseName '_editable.pptx']);

ppt=actxserver('PowerPoint.Application'); ppt.Visible=1;
pres=ppt.Presentations.Add; pres.PageSetup.SlideWidth=SW; pres.PageSetup.SlideHeight=SH;
slide=invoke(pres.Slides,'Add',1,12);

% 组件独立图层
for i=1:numel(components)
    c=components(i); q=px2pt(c.x,c.y,c.w,c.h);
    shp=slide.Shapes.AddPicture(fullfile(assetDir,c.file),0,-1,q(1),q(2),q(3),q(4));
    shp.Name=c.name;
end

% OCR文本作为可编辑文本框
for i=1:numel(words)
    b=wb(i,:); q=px2pt(b(1),b(2),b(3),b(4));
    t=slide.Shapes.AddTextbox(1,q(1),q(2),max(q(3),8),max(q(4),8));
    tr=t.TextFrame.TextRange;
    tr.Text=char(words{i});
    tr.Font.Name='Arial'; tr.Font.Size=max(8,min(24,round(q(4)*0.55)));
    tr.Font.Bold=0; tr.Font.Color.RGB=rgb2ppt([20 20 20]);
    t.Name=sprintf('text_%03d',i);
end

pres.SaveAs(outFile); pres.Close; ppt.Quit; delete(ppt);

fprintf('已生成: %s\n', outFile);
fprintf('组件图层: %d, OCR文本框: %d\n', numel(components), numel(words));

function c=rgb2ppt(rgb), c=rgb(1)+bitshift(rgb(2),8)+bitshift(rgb(3),16); end
function boxesOut=mergeOverlaps(boxesIn,thr)
if isempty(boxesIn), boxesOut=boxesIn; return; end
keep=true(size(boxesIn,1),1);
for i=1:size(boxesIn,1)
 if ~keep(i), continue; end
 for j=i+1:size(boxesIn,1)
  if ~keep(j), continue; end
  if iou(boxesIn(i,:),boxesIn(j,:))>thr
   ai=boxesIn(i,3)*boxesIn(i,4); aj=boxesIn(j,3)*boxesIn(j,4);
   if ai>=aj, keep(j)=false; else, keep(i)=false; break; end
  end
 end
end
boxesOut=boxesIn(keep,:);
end
function v=iou(a,b)
ax1=a(1); ay1=a(2); ax2=a(1)+a(3); ay2=a(2)+a(4);
bx1=b(1); by1=b(2); bx2=b(1)+b(3); by2=b(2)+b(4);
ix1=max(ax1,bx1); iy1=max(ay1,by1); ix2=min(ax2,bx2); iy2=min(ay2,by2);
iw=max(0,ix2-ix1); ih=max(0,iy2-iy1); inter=iw*ih; ua=a(3)*a(4)+b(3)*b(4)-inter;
if ua<=0, v=0; else, v=inter/ua; end
end
