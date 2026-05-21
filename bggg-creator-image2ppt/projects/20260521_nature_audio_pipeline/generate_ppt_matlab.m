%% Generate Nature-style editable PPT from provided PNG layout (MATLAB)
% Requirement: MATLAB Report Generator Toolbox (mlreportgen.ppt)
% Output: output_matlab.pptx in current project folder

import mlreportgen.ppt.*

projectDir = fileparts(mfilename('fullpath'));
outFile = fullfile(projectDir, 'output_matlab.pptx');

ppt = Presentation(outFile);
open(ppt);

% Use blank layout for fully custom placement
slide = add(ppt, 'Blank');

% Canvas follows source ratio 1536x1024 = 3:2
% We'll place everything in normalized percentages over 13.333 x 8.888 in slide
slideW = 13.333;
slideH = 8.888;

% helper
pxW = 1536; pxH = 1024;
px2in = @(x,y,w,h) [x/pxW*slideW, y/pxH*slideH, w/pxW*slideW, h/pxH*slideH];

% Background
bg = addShape(slide,'Rectangle');
bg.X = '0in'; bg.Y = '0in'; bg.Width = sprintf('%.3fin',slideW); bg.Height = sprintf('%.3fin',slideH);
bg.FillColor = '#F3F4F6';
bg.LineColor = '#F3F4F6';

% Title
p = px2in(60,24,1410,50);
t = addTextBox(slide,sprintf('%.3fin',p(1)),sprintf('%.3fin',p(2)),sprintf('%.3fin',p(3)),sprintf('%.3fin',p(4)));
replace(t, 'Audio preprocessing and dual-track modeling pipeline');
t.Style = {FontFamily('Arial'), FontSize('20pt'), Bold(true), FontColor('#111827')};

% Section 1
p = px2in(20,90,1490,140);
s1 = addShape(slide,'RoundRect');
s1.X=sprintf('%.3fin',p(1)); s1.Y=sprintf('%.3fin',p(2)); s1.Width=sprintf('%.3fin',p(3)); s1.Height=sprintf('%.3fin',p(4));
s1.FillColor='#E5E7EB'; s1.LineColor='#9CA3AF';

p = px2in(40,118,1450,90);
t1 = addTextBox(slide,sprintf('%.3fin',p(1)),sprintf('%.3fin',p(2)),sprintf('%.3fin',p(3)),sprintf('%.3fin',p(4)));
replace(t1,'1  Raw bronze impact audio -> STFT/SVD denoising -> two-stage peak alignment -> normalized time-domain signal');
t1.Style = {FontFamily('Arial'), FontSize('16pt'), FontColor('#1F2937')};

% Section 2A
p = px2in(20,250,800,540);
a = addShape(slide,'RoundRect');
a.X=sprintf('%.3fin',p(1)); a.Y=sprintf('%.3fin',p(2)); a.Width=sprintf('%.3fin',p(3)); a.Height=sprintf('%.3fin',p(4));
a.FillColor='#EFF6FF'; a.LineColor='#3B82F6';

p = px2in(40,268,760,40);
ta = addTextBox(slide,sprintf('%.3fin',p(1)),sprintf('%.3fin',p(2)),sprintf('%.3fin',p(3)),sprintf('%.3fin',p(4)));
replace(ta,'2A  MobileNetV2 primary scheme (deep learning)');
ta.Style = {FontFamily('Arial'), FontSize('17pt'), Bold(true), FontColor('#1E3A8A')};

% Section 2B
p = px2in(840,250,670,540);
b = addShape(slide,'RoundRect');
b.X=sprintf('%.3fin',p(1)); b.Y=sprintf('%.3fin',p(2)); b.Width=sprintf('%.3fin',p(3)); b.Height=sprintf('%.3fin',p(4));
b.FillColor='#ECFDF5'; b.LineColor='#22C55E';

p = px2in(860,268,630,40);
tb = addTextBox(slide,sprintf('%.3fin',p(1)),sprintf('%.3fin',p(2)),sprintf('%.3fin',p(3)),sprintf('%.3fin',p(4)));
replace(tb,'2B  SVM + SHAP baseline scheme (traditional ML)');
tb.Style = {FontFamily('Arial'), FontSize('17pt'), Bold(true), FontColor('#166534')};

% Section 3
p = px2in(20,810,1490,190);
c = addShape(slide,'RoundRect');
c.X=sprintf('%.3fin',p(1)); c.Y=sprintf('%.3fin',p(2)); c.Width=sprintf('%.3fin',p(3)); c.Height=sprintf('%.3fin',p(4));
c.FillColor='#F5F3FF'; c.LineColor='#8B5CF6';

p = px2in(40,835,1450,120);
t3 = addTextBox(slide,sprintf('%.3fin',p(1)),sprintf('%.3fin',p(2)),sprintf('%.3fin',p(3)),sprintf('%.3fin',p(4)));
replace(t3,'3  Model fusion, uncertainty band, and final mineralization output with XAI attribution report');
t3.Style = {FontFamily('Arial'), FontSize('16pt'), FontColor('#312E81')};

p = px2in(40,970,1450,36);	note = addTextBox(slide,sprintf('%.3fin',p(1)),sprintf('%.3fin',p(2)),sprintf('%.3fin',p(3)),sprintf('%.3fin',p(4)));
replace(note,'Font guideline: Nature-like sans serif (Arial/Helvetica), high-pixel journal export.');
note.Style = {FontFamily('Arial'), FontSize('10pt'), FontColor('#4B5563')};

close(ppt);
fprintf('Generated: %s\n', outFile);
