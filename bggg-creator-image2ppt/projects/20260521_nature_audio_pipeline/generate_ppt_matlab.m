%% Generate editable PPT (Windows + PowerPoint COM)
% This version avoids mlreportgen API compatibility issues.
% Requirement: Windows + Microsoft PowerPoint installed.

projectDir = fileparts(mfilename('fullpath'));
outFile = fullfile(projectDir, 'output_matlab.pptx');

% Source canvas ratio
pxW = 1536; pxH = 1024;
slideW = 960;   % points (13.333in * 72)
slideH = 640;   % points (8.889in * 72)

% Helper: px -> points
px2pt = @(x,y,w,h) [x/pxW*slideW, y/pxH*slideH, w/pxW*slideW, h/pxH*slideH];

ppt = actxserver('PowerPoint.Application');
ppt.Visible = 1;
pres = ppt.Presentations.Add;

% ppLayoutBlank = 12
slide = invoke(pres.Slides, 'Add', 1, 12);
pres.PageSetup.SlideWidth = slideW;
pres.PageSetup.SlideHeight = slideH;

% msoTrue = -1
msoTrue = -1;

% ---------- Background ----------
p = px2pt(0,0,1536,1024);
sh = slide.Shapes.AddShape(1, p(1), p(2), p(3), p(4)); % 1=Rectangle
sh.Fill.ForeColor.RGB = rgb2ppt([243 244 246]);
sh.Line.ForeColor.RGB = rgb2ppt([243 244 246]);

% ---------- Title ----------
p = px2pt(60,24,1410,50);
addText(slide, p, 'Audio preprocessing and dual-track modeling pipeline', 20, 'Arial', msoTrue, [17 24 39]);

% ---------- Section 1 ----------
p = px2pt(20,90,1490,140);
sh = slide.Shapes.AddShape(5, p(1), p(2), p(3), p(4)); % 5=RoundRect
sh.Fill.ForeColor.RGB = rgb2ppt([229 231 235]);
sh.Line.ForeColor.RGB = rgb2ppt([156 163 175]);

p = px2pt(40,118,1450,90);
addText(slide, p, '1  Raw bronze impact audio -> STFT/SVD denoising -> two-stage peak alignment -> normalized time-domain signal', 16, 'Arial', 0, [31 41 55]);

% ---------- Section 2A ----------
p = px2pt(20,250,800,540);
sh = slide.Shapes.AddShape(5, p(1), p(2), p(3), p(4));
sh.Fill.ForeColor.RGB = rgb2ppt([239 246 255]);
sh.Line.ForeColor.RGB = rgb2ppt([59 130 246]);

p = px2pt(40,268,760,40);
addText(slide, p, '2A  MobileNetV2 primary scheme (deep learning)', 17, 'Arial', msoTrue, [30 58 138]);

% ---------- Section 2B ----------
p = px2pt(840,250,670,540);
sh = slide.Shapes.AddShape(5, p(1), p(2), p(3), p(4));
sh.Fill.ForeColor.RGB = rgb2ppt([236 253 245]);
sh.Line.ForeColor.RGB = rgb2ppt([34 197 94]);

p = px2pt(860,268,630,40);
addText(slide, p, '2B  SVM + SHAP baseline scheme (traditional ML)', 17, 'Arial', msoTrue, [22 101 52]);

% ---------- Section 3 ----------
p = px2pt(20,810,1490,190);
sh = slide.Shapes.AddShape(5, p(1), p(2), p(3), p(4));
sh.Fill.ForeColor.RGB = rgb2ppt([245 243 255]);
sh.Line.ForeColor.RGB = rgb2ppt([139 92 246]);

p = px2pt(40,835,1450,120);
addText(slide, p, '3  Model fusion, uncertainty band, and final mineralization output with XAI attribution report', 16, 'Arial', 0, [49 46 129]);

p = px2pt(40,970,1450,36);
addText(slide, p, 'Font guideline: Nature-like sans serif (Arial/Helvetica), high-pixel journal export.', 10, 'Arial', 0, [75 85 99]);

pres.SaveAs(outFile);
pres.Close;
ppt.Quit;
delete(ppt);

fprintf('Generated: %s\n', outFile);


function addText(slide, p, txt, fontSize, fontName, boldFlag, rgb)
box = slide.Shapes.AddTextbox(1, p(1), p(2), p(3), p(4)); % 1 = horizontal textbox
tr = box.TextFrame.TextRange;
tr.Text = txt;
tr.Font.Name = fontName;
tr.Font.Size = fontSize;
tr.Font.Bold = boldFlag;
tr.Font.Color.RGB = rgb2ppt(rgb);
end

function c = rgb2ppt(rgb)
% Convert [R G B] to PowerPoint RGB integer (BGR byte order)
c = rgb(1) + bitshift(rgb(2),8) + bitshift(rgb(3),16);
end
