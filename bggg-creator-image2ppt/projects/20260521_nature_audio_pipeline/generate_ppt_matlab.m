%% Interactive image -> editable PPT (MATLAB + PowerPoint COM)
% 功能：运行后选择 PNG/JPG 图片，自动生成同尺寸比例的可编辑 PPT。
% 输出：与图片同目录同名 .pptx（并可编辑：背景图 + 文本框覆盖层）。
% 依赖：Windows + Microsoft PowerPoint + MATLAB COM 支持。

[fn, fp] = uigetfile({'*.png;*.jpg;*.jpeg','Image Files (*.png,*.jpg,*.jpeg)'}, ...
    '选择要转换的图片');
if isequal(fn,0)
    error('未选择图片，已取消。');
end
imgPath = fullfile(fp, fn);
[~, baseName, ~] = fileparts(imgPath);
outFile = fullfile(fp, [baseName '.pptx']);

imgInfo = imfinfo(imgPath);
pxW = double(imgInfo.Width);
pxH = double(imgInfo.Height);

% 设定输出宽度为 13.333in（Nature 常见 16:9 宽度基线），高度按原图比例自动计算
slideW_in = 13.333;
slideH_in = slideW_in * (pxH / pxW);
slideW_pt = slideW_in * 72;
slideH_pt = slideH_in * 72;

ppt = actxserver('PowerPoint.Application');
ppt.Visible = 1;
pres = ppt.Presentations.Add;
pres.PageSetup.SlideWidth = slideW_pt;
pres.PageSetup.SlideHeight = slideH_pt;

% ppLayoutBlank = 12
slide = invoke(pres.Slides, 'Add', 1, 12);

% 整图作为底图
slide.Shapes.AddPicture(imgPath, 0, -1, 0, 0, slideW_pt, slideH_pt);

% 添加可编辑标题文本框（用户可在PPT内修改）
titleH = max(24, 0.065 * slideH_pt);
titleBox = slide.Shapes.AddTextbox(1, 0.035*slideW_pt, 0.02*slideH_pt, 0.93*slideW_pt, titleH);
tRange = titleBox.TextFrame.TextRange;
tRange.Text = 'Editable Title (Arial)';
tRange.Font.Name = 'Arial';
tRange.Font.Size = max(14, round(titleH*0.45));
tRange.Font.Bold = -1;
tRange.Font.Color.RGB = rgb2ppt([20 24 28]);

% 添加可编辑注释文本框（Nature风格参考）
capH = max(22, 0.05 * slideH_pt);
capY = slideH_pt - capH - 0.02*slideH_pt;
capBox = slide.Shapes.AddTextbox(1, 0.035*slideW_pt, capY, 0.93*slideW_pt, capH);
cRange = capBox.TextFrame.TextRange;
cRange.Text = 'Caption / Notes (Arial, editable)';
cRange.Font.Name = 'Arial';
cRange.Font.Size = max(10, round(capH*0.38));
cRange.Font.Bold = 0;
cRange.Font.Color.RGB = rgb2ppt([55 65 81]);

pres.SaveAs(outFile);
pres.Close;
ppt.Quit;
delete(ppt);

fprintf('已生成PPT: %s\n', outFile);
fprintf('图片尺寸: %.0f x %.0f px\n', pxW, pxH);
fprintf('幻灯片尺寸: %.3f x %.3f in\n', slideW_in, slideH_in);

function c = rgb2ppt(rgb)
% [R G B] -> PowerPoint RGB整数
c = rgb(1) + bitshift(rgb(2),8) + bitshift(rgb(3),16);
end
