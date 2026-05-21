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
bg = Shape('Rectangle');
bg.X = '0in'; bg.Y = '0in'; bg.Width = sprintf('%.3fin',slideW); bg.Height = sprintf('%.3fin',slideH);
bg.FillColor = '#F3F4F6';
bg.LineColor = '#F3F4F6';
add(slide,bg);

% Title
p = px2in(60,24,1410,50);
t = TextBox('Audio preprocessing and dual-track modeling pipeline');
t.X=sprintf('%.3fin',p(1)); t.Y=sprintf('%.3fin',p(2)); t.Width=sprintf('%.3fin',p(3)); t.Height=sprintf('%.3fin',p(4));
t.Style = {FontFamily('Arial'), FontSize('20pt'), Bold(true), FontColor('#111827')};
add(slide,t);

% Section 1
p = px2in(20,90,1490,140);
s1 = Shape('RoundRect');
s1.X=sprintf('%.3fin',p(1)); s1.Y=sprintf('%.3fin',p(2)); s1.Width=sprintf('%.3fin',p(3)); s1.Height=sprintf('%.3fin',p(4));
s1.FillColor='#E5E7EB'; s1.LineColor='#9CA3AF';
add(slide,s1);

p = px2in(40,118,1450,90);
t1 = TextBox('1  Raw bronze impact audio -> STFT/SVD denoising -> two-stage peak alignment -> normalized time-domain signal');
t1.X=sprintf('%.3fin',p(1)); t1.Y=sprintf('%.3fin',p(2)); t1.Width=sprintf('%.3fin',p(3)); t1.Height=sprintf('%.3fin',p(4));
t1.Style = {FontFamily('Arial'), FontSize('16pt'), FontColor('#1F2937')};
add(slide,t1);

% Section 2A
p = px2in(20,250,800,540);
a = Shape('RoundRect');
a.X=sprintf('%.3fin',p(1)); a.Y=sprintf('%.3fin',p(2)); a.Width=sprintf('%.3fin',p(3)); a.Height=sprintf('%.3fin',p(4));
a.FillColor='#EFF6FF'; a.LineColor='#3B82F6';
add(slide,a);

p = px2in(40,268,760,40);
ta = TextBox('2A  MobileNetV2 primary scheme (deep learning)');
ta.X=sprintf('%.3fin',p(1)); ta.Y=sprintf('%.3fin',p(2)); ta.Width=sprintf('%.3fin',p(3)); ta.Height=sprintf('%.3fin',p(4));
ta.Style = {FontFamily('Arial'), FontSize('17pt'), Bold(true), FontColor('#1E3A8A')};
add(slide,ta);

% Section 2B
p = px2in(840,250,670,540);
b = Shape('RoundRect');
b.X=sprintf('%.3fin',p(1)); b.Y=sprintf('%.3fin',p(2)); b.Width=sprintf('%.3fin',p(3)); b.Height=sprintf('%.3fin',p(4));
b.FillColor='#ECFDF5'; b.LineColor='#22C55E';
add(slide,b);

p = px2in(860,268,630,40);
tb = TextBox('2B  SVM + SHAP baseline scheme (traditional ML)');
tb.X=sprintf('%.3fin',p(1)); tb.Y=sprintf('%.3fin',p(2)); tb.Width=sprintf('%.3fin',p(3)); tb.Height=sprintf('%.3fin',p(4));
tb.Style = {FontFamily('Arial'), FontSize('17pt'), Bold(true), FontColor('#166534')};
add(slide,tb);

% Section 3
p = px2in(20,810,1490,190);
c = Shape('RoundRect');
c.X=sprintf('%.3fin',p(1)); c.Y=sprintf('%.3fin',p(2)); c.Width=sprintf('%.3fin',p(3)); c.Height=sprintf('%.3fin',p(4));
c.FillColor='#F5F3FF'; c.LineColor='#8B5CF6';
add(slide,c);

p = px2in(40,835,1450,120);
t3 = TextBox('3  Model fusion, uncertainty band, and final mineralization output with XAI attribution report');
t3.X=sprintf('%.3fin',p(1)); t3.Y=sprintf('%.3fin',p(2)); t3.Width=sprintf('%.3fin',p(3)); t3.Height=sprintf('%.3fin',p(4));
t3.Style = {FontFamily('Arial'), FontSize('16pt'), FontColor('#312E81')};
add(slide,t3);

p = px2in(40,970,1450,36);	note = TextBox('Font guideline: Nature-like sans serif (Arial/Helvetica), high-pixel journal export.');
note.X=sprintf('%.3fin',p(1)); note.Y=sprintf('%.3fin',p(2)); note.Width=sprintf('%.3fin',p(3)); note.Height=sprintf('%.3fin',p(4));
note.Style = {FontFamily('Arial'), FontSize('10pt'), FontColor('#4B5563')};
add(slide,note);

close(ppt);
fprintf('Generated: %s\n', outFile);
