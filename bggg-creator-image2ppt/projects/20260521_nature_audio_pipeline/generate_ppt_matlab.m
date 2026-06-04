%% Auto-decompose image -> editable PPT layers (text/image/arrows/lines)
% 目标：将单张图拆成可编辑图层：文本框 + 图片组件 + 箭头/线条。
% 输出：
%   <name>_fully_editable.pptx
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

%% A) OCR -> 文本框（位置/颜色/字号近似保留）
ocrRes = ocr(I);
words = ocrRes.Words;
wb = ocrRes.WordBoundingBoxes;
conf = ocrRes.WordConfidences;
valid = ~cellfun(@isempty,words) & conf > 0.35;
words = words(valid); wb = wb(valid,:);

textItems = struct('text',{},'bbox',{},'rgb',{},'fontSize',{});
for i=1:numel(words)
    b = round(wb(i,:));
    x1=max(1,b(1)); y1=max(1,b(2)); x2=min(W,b(1)+b(3)-1); y2=min(H,b(2)+b(4)-1);
    patch = I(y1:y2,x1:x2,:);
    med = squeeze(median(reshape(double(patch),[],3),1));
    textItems(i).text = words{i};
    textItems(i).bbox = [x1 y1 (x2-x1+1) (y2-y1+1)];
    textItems(i).rgb = uint8(med');
    textItems(i).fontSize = max(8, min(42, round((y2-y1+1)*0.65*72/96))); % px->pt 近似
end

%% B) 线条/箭头检测（Hough）
E = edge(G,'Canny');
[Hh,T,R] = hough(E);
P  = houghpeaks(Hh, 80, 'Threshold', ceil(0.2*max(Hh(:))));
L  = houghlines(E,T,R,P,'FillGap',18,'MinLength',24);
lineItems = struct('p1',{},'p2',{},'width',{},'rgb',{});
for i=1:numel(L)
    p1 = L(i).point1; p2 = L(i).point2;
    if norm(double(p1-p2)) < 20, continue; end
    cx = round((p1(1)+p2(1))/2); cy = round((p1(2)+p2(2))/2);
    x1=max(1,cx-2); x2=min(W,cx+2); y1=max(1,cy-2); y2=min(H,cy+2);
    cpatch = I(y1:y2,x1:x2,:);
    crgb = uint8(squeeze(median(reshape(double(cpatch),[],3),1))');
    lineItems(end+1).p1 = p1; %#ok<AGROW>
    lineItems(end).p2 = p2;
    lineItems(end).width = 1.5;
    lineItems(end).rgb = crgb;
end

%% C) 组件图像检测（排除文字和线条）
BW = edge(G,'Canny');
BW = imdilate(BW, strel('rectangle',[3 3]));
BW = imclose(BW, strel('rectangle',[15 15]));
BW = imfill(BW,'holes');
BW = bwareaopen(BW, round(W*H*0.00035));

maskText = false(H,W);
for i=1:size(wb,1)
    b=round(wb(i,:)); x1=max(1,b(1)); y1=max(1,b(2)); x2=min(W,b(1)+b(3)-1); y2=min(H,b(2)+b(4)-1);
    maskText(y1:y2,x1:x2)=true;
end
BW(maskText)=0;

% 去除线条附近
maskLine = false(H,W);
for i=1:numel(lineItems)
    p1=lineItems(i).p1; p2=lineItems(i).p2;
    n=max(abs(p1-p2))+1;
    xs=round(linspace(p1(1),p2(1),n)); ys=round(linspace(p1(2),p2(2),n));
    idx=sub2ind([H,W], max(1,min(H,ys)), max(1,min(W,xs)));
    maskLine(idx)=true;
end
maskLine = imdilate(maskLine, strel('disk',2));
BW(maskLine)=0;

CC = bwconncomp(BW);
st = regionprops(CC,'BoundingBox');
boxes=[];
for i=1:numel(st)
    bb=st(i).BoundingBox; a=bb(3)*bb(4);
    if a < W*H*0.002 || a > W*H*0.90, continue; end
    if bb(3)<24 || bb(4)<24, continue; end
    boxes(end+1,:)=bb; %#ok<AGROW>
end
boxes=mergeOverlaps(boxes,0.5);

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

meta = struct('components',{components},'texts',{textItems},'lines',{lineItems});
fid=fopen(fullfile(assetDir,'components.json'),'w'); fwrite(fid,jsonencode(meta),'char'); fclose(fid);

%% D) 组装PPT（无整页底图）
slideW_in=13.333; slideH_in=slideW_in*(H/W);
SW=slideW_in*72; SH=slideH_in*72;
px2pt=@(x,y,w,h)[x/W*SW, y/H*SH, w/W*SW, h/H*SH];
ptX=@(x) x/W*SW; ptY=@(y) y/H*SH;
outFile=fullfile(fp,[baseName '_fully_editable.pptx']);

ppt=actxserver('PowerPoint.Application'); ppt.Visible=1;
pres=ppt.Presentations.Add; pres.PageSetup.SlideWidth=SW; pres.PageSetup.SlideHeight=SH;
slide=invoke(pres.Slides,'Add',1,12);

% 图片组件层
for i=1:numel(components)
    c=components(i); q=px2pt(c.x,c.y,c.w,c.h);
    shp=slide.Shapes.AddPicture(fullfile(assetDir,c.file),0,-1,q(1),q(2),q(3),q(4));
    shp.Name=c.name;
end

% 线条/箭头层（默认线，按长度阈值改箭头）
for i=1:numel(lineItems)
    li=lineItems(i);
    ln = slide.Shapes.AddLine(ptX(li.p1(1)), ptY(li.p1(2)), ptX(li.p2(1)), ptY(li.p2(2)));
    ln.Line.ForeColor.RGB = rgb2ppt(double(li.rgb));
    ln.Line.Weight = li.width;
    if norm(double(li.p1-li.p2)) > 40
        ln.Line.EndArrowheadStyle = 3; % triangle
    end
    ln.Name = sprintf('line_%03d',i);
end

% 文本层
for i=1:numel(textItems)
    t=textItems(i); b=t.bbox; q=px2pt(b(1),b(2),b(3),b(4));
    tx=slide.Shapes.AddTextbox(1,q(1),q(2),max(q(3),6),max(q(4),6));
    tr=tx.TextFrame.TextRange;
    tr.Text=char(t.text);
    tr.Font.Name='Arial';
    tr.Font.Size=t.fontSize;
    tr.Font.Bold=0;
    tr.Font.Color.RGB=rgb2ppt(double(t.rgb));
    tx.Name=sprintf('text_%03d',i);
end

pres.SaveAs(outFile); pres.Close; ppt.Quit; delete(ppt);
fprintf('已生成: %s\n', outFile);
fprintf('组件:%d 文本:%d 线条/箭头:%d\n', numel(components), numel(textItems), numel(lineItems));

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
