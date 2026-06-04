#!/usr/bin/env python3
"""
image2ppt.py

Usage examples:
  # 1) Offline auto mode (no API): infer background + simple color blocks from image
  python image2ppt.py --input slide.png --output slide.pptx

  # 2) HTML/SVG input (rendered by Playwright at 1920x1080, then offline inference)
  python image2ppt.py --input page.html --output page.pptx
  python image2ppt.py --input art.svg --output art.pptx

  # 3) High-fidelity editable mode: provide explicit layout JSON
  python image2ppt.py --input slide.png --layout-json layout.json --output slide.pptx
"""

from __future__ import annotations

import argparse
import io
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

from PIL import Image
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN
from pptx.util import Inches, Pt
from playwright.sync_api import sync_playwright

SLIDE_WIDTH_INCH = 13.33
SLIDE_HEIGHT_INCH = 7.5
TARGET_WIDTH = 1920
TARGET_HEIGHT = 1080


# ----------------------------- CLI -----------------------------
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert PNG/JPEG/HTML/SVG to editable PPTX without cloud API dependencies."
    )
    parser.add_argument("input", nargs="?", help="Input file path: png/jpeg/html/svg")
    parser.add_argument("output", nargs="?", help="Output .pptx file path")
    parser.add_argument("--input", dest="input_opt", help="Input file path: png/jpeg/html/svg")
    parser.add_argument("--output", dest="output_opt", help="Output .pptx file path")
    parser.add_argument(
        "--layout-json",
        help="Optional JSON file with explicit layout schema for high-fidelity editable reconstruction",
    )
    args = parser.parse_args()

    input_path = args.input_opt or args.input
    output_path = args.output_opt or args.output
    args.input = input_path
    args.output = output_path
    return args


# ----------------------------- Input to PNG -----------------------------
def normalize_to_png(input_path: Path) -> bytes:
    suffix = input_path.suffix.lower()

    if suffix in {".png", ".jpg", ".jpeg"}:
        return image_file_to_png(input_path)
    if suffix in {".html", ".htm", ".svg"}:
        return browser_render_to_png(input_path)

    raise ValueError(f"Unsupported input type: {suffix}")


def image_file_to_png(path: Path) -> bytes:
    with Image.open(path) as img:
        if img.mode != "RGB":
            img = img.convert("RGB")

        canvas = Image.new("RGB", (TARGET_WIDTH, TARGET_HEIGHT), color=(255, 255, 255))
        src_w, src_h = img.size
        scale = min(TARGET_WIDTH / src_w, TARGET_HEIGHT / src_h)
        new_size = (max(1, int(src_w * scale)), max(1, int(src_h * scale)))
        resized = img.resize(new_size, Image.Resampling.LANCZOS)
        offset_x = (TARGET_WIDTH - new_size[0]) // 2
        offset_y = (TARGET_HEIGHT - new_size[1]) // 2
        canvas.paste(resized, (offset_x, offset_y))

        buf = io.BytesIO()
        canvas.save(buf, format="PNG")
        return buf.getvalue()


def browser_render_to_png(path: Path) -> bytes:
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": TARGET_WIDTH, "height": TARGET_HEIGHT})
        page.goto(path.resolve().as_uri(), wait_until="networkidle")
        image = page.screenshot(type="png", full_page=False)
        browser.close()
        return image


# ----------------------------- Layout -----------------------------
def parse_json_from_text(text: str) -> Dict[str, Any]:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", text, flags=re.DOTALL)
        if not match:
            raise
        return json.loads(match.group(0))


def load_layout_from_json(path: Path) -> Dict[str, Any]:
    return parse_json_from_text(path.read_text(encoding="utf-8"))


def infer_layout_offline(png_data: bytes) -> Dict[str, Any]:
    """
    Offline heuristic extractor (no API):
    - Estimate background color from image corners.
    - Detect simple non-background connected regions as rectangle shapes.

    Note: This cannot recover text content from raster images without OCR/LLM.
    """
    img = Image.open(io.BytesIO(png_data)).convert("RGB")
    w, h = img.size
    px = img.load()

    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    bg = tuple(int(sum(c[i] for c in corners) / 4) for i in range(3))

    def color_dist(a: tuple[int, int, int], b: tuple[int, int, int]) -> int:
        return abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])

    threshold = 60
    mask = [[color_dist(px[x, y], bg) > threshold for x in range(w)] for y in range(h)]
    visited = [[False] * w for _ in range(h)]

    regions: List[Dict[str, Any]] = []
    min_area = max(600, int(w * h * 0.0015))

    for y in range(h):
        for x in range(w):
            if visited[y][x] or not mask[y][x]:
                continue

            stack = [(x, y)]
            visited[y][x] = True
            min_x = max_x = x
            min_y = max_y = y
            count = 0
            rs = gs = bs = 0

            while stack:
                cx, cy = stack.pop()
                count += 1
                r, g, b = px[cx, cy]
                rs += r
                gs += g
                bs += b
                min_x = min(min_x, cx)
                max_x = max(max_x, cx)
                min_y = min(min_y, cy)
                max_y = max(max_y, cy)

                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if 0 <= nx < w and 0 <= ny < h and not visited[ny][nx] and mask[ny][nx]:
                        visited[ny][nx] = True
                        stack.append((nx, ny))

            if count < min_area:
                continue

            fill = (int(rs / count), int(gs / count), int(bs / count))
            regions.append(
                {
                    "type": "shape",
                    "role": "decoration",
                    "text": "",
                    "x": min_x / w,
                    "y": min_y / h,
                    "width": max(1, (max_x - min_x + 1)) / w,
                    "height": max(1, (max_y - min_y + 1)) / h,
                    "font_size": 18,
                    "font_bold": False,
                    "font_color": "#000000",
                    "align": "left",
                    "fill_color": rgb_to_hex(fill),
                    "border_color": "",
                }
            )

    regions = sorted(regions, key=lambda e: e["width"] * e["height"], reverse=True)[:40]
    return {"background_color": rgb_to_hex(bg), "elements": regions}


def rgb_to_hex(rgb: tuple[int, int, int]) -> str:
    return f"#{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X}"


def clamp01(v: Any, default: float) -> float:
    try:
        x = float(v)
    except (TypeError, ValueError):
        x = default
    return max(0.0, min(1.0, x))


def parse_hex_color(value: Optional[str], default: str = "#000000") -> RGBColor:
    s = (value or default).strip()
    if not re.fullmatch(r"#?[0-9a-fA-F]{6}", s):
        s = default
    s = s.lstrip("#")
    return RGBColor(int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def map_align(align: str) -> PP_ALIGN:
    align = (align or "left").lower()
    if align == "center":
        return PP_ALIGN.CENTER
    if align == "right":
        return PP_ALIGN.RIGHT
    return PP_ALIGN.LEFT


# ----------------------------- PPT build -----------------------------
def build_ppt(layout: Dict[str, Any], output_path: Path) -> None:
    prs = Presentation()
    prs.slide_width = Inches(SLIDE_WIDTH_INCH)
    prs.slide_height = Inches(SLIDE_HEIGHT_INCH)
    slide = prs.slides.add_slide(prs.slide_layouts[6])

    bg = slide.background.fill
    bg.solid()
    bg.fore_color.rgb = parse_hex_color(layout.get("background_color"), "#FFFFFF")

    elements: List[Dict[str, Any]] = layout.get("elements", [])
    for el in elements:
        typ = (el.get("type") or "").lower()
        left = Inches(SLIDE_WIDTH_INCH * clamp01(el.get("x"), 0.0))
        top = Inches(SLIDE_HEIGHT_INCH * clamp01(el.get("y"), 0.0))
        width = Inches(SLIDE_WIDTH_INCH * clamp01(el.get("width"), 0.2))
        height = Inches(SLIDE_HEIGHT_INCH * clamp01(el.get("height"), 0.1))

        if typ == "text":
            shape = slide.shapes.add_textbox(left, top, width, height)
            tf = shape.text_frame
            tf.clear()
            p = tf.paragraphs[0]
            p.alignment = map_align(el.get("align", "left"))
            run = p.add_run()
            run.text = str(el.get("text") or "")
            run.font.size = Pt(float(el.get("font_size") or 18))
            run.font.bold = bool(el.get("font_bold", False))
            run.font.color.rgb = parse_hex_color(el.get("font_color"), "#000000")

            fill_color = el.get("fill_color")
            if fill_color:
                shape.fill.solid()
                shape.fill.fore_color.rgb = parse_hex_color(fill_color)
            else:
                shape.fill.background()

            border_color = el.get("border_color")
            if border_color:
                shape.line.color.rgb = parse_hex_color(border_color)
            else:
                shape.line.fill.background()

        elif typ == "shape":
            shape = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, left, top, width, height)
            shape.fill.solid()
            shape.fill.fore_color.rgb = parse_hex_color(el.get("fill_color"), "#DDDDDD")
            border_color = el.get("border_color")
            if border_color:
                shape.line.color.rgb = parse_hex_color(border_color)
            else:
                shape.line.fill.background()

    prs.save(str(output_path))



def pick_input_file() -> Optional[Path]:
    try:
        import tkinter as tk
        from tkinter import filedialog
    except Exception:
        return None

    root = tk.Tk()
    root.withdraw()
    root.update()
    filename = filedialog.askopenfilename(
        title="选择要转换的图片/页面文件",
        filetypes=[
            ("Supported", "*.png *.jpg *.jpeg *.html *.htm *.svg"),
            ("PNG", "*.png"),
            ("JPEG", "*.jpg *.jpeg"),
            ("HTML", "*.html *.htm"),
            ("SVG", "*.svg"),
            ("All Files", "*.*"),
        ],
    )
    root.destroy()
    if not filename:
        return None
    return Path(filename)


def resolve_paths(args: argparse.Namespace) -> tuple[Path, Path]:
    input_path = Path(args.input) if args.input else None

    if input_path is None:
        input_path = pick_input_file()
        if input_path is None:
            raise ValueError("未选择输入文件。请通过文件选择框选择，或使用 --input/位置参数传入。")

    if args.output:
        output_path = Path(args.output)
    else:
        output_path = input_path.with_suffix(".pptx")

    return input_path, output_path

def main() -> int:
    args = parse_args()
    input_path, output_path = resolve_paths(args)

    if not input_path.exists():
        print(f"Input not found: {input_path}", file=sys.stderr)
        return 1

    try:
        png_data = normalize_to_png(input_path)
        if args.layout_json:
            layout = load_layout_from_json(Path(args.layout_json))
        else:
            layout = infer_layout_offline(png_data)
        build_ppt(layout, output_path)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Saved PPTX: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
