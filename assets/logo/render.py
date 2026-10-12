#!/usr/bin/env python3
"""SVG → moonui.png + moonui.ico 的重渲脚本（需要 macOS 的 qlmanage 与 Python 的 Pillow）。

qlmanage 的缩略图是白底（没有透明通道），所以这里按 SVG 里的圆角矩形几何
重建 alpha，并把白底合成过的边缘反解回来（observed = c*a + 255*(1-a)）。
改了 moonui-logo.svg 之后跑一遍：

    cd assets/logo && qlmanage -t -s 1024 -o . moonui-logo.svg && python3 render.py
"""

from PIL import Image, ImageDraw
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "moonui-logo.svg.png")  # qlmanage 产物固定叫这个名字

# 与 moonui-logo.svg 里的背景矩形逐字对齐：画布 1024，矩形 (64,64)-(960,960)，圆角 192。
CANVAS = 1024
RECT = (64, 64, 960, 960)
RADIUS = 192
ICO_SIZES = [16, 32, 48, 64, 128, 256]


def main():
    im = Image.open(SRC).convert("RGBA")
    assert im.size == (CANVAS, CANVAS), f"qlmanage 产物不是 {CANVAS}x{CANVAS}：{im.size}"

    # 4 倍超采样画圆角矩形掩码，边缘才有抗锯齿
    s = 4
    mask = Image.new("L", (CANVAS * s, CANVAS * s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [c * s for c in RECT], radius=RADIUS * s, fill=255
    )
    mask = mask.resize((CANVAS, CANVAS), Image.LANCZOS)

    out = im.copy()
    out.putalpha(mask)
    px = out.load()
    for y in range(CANVAS):
        for x in range(CANVAS):
            _, _, _, a = px[x, y]
            if a == 255 or a == 0:
                continue
            if a < 12:  # 残边：直接透明
                px[x, y] = (0, 0, 0, 0)
                continue
            af = a / 255.0
            r, g, b, _ = px[x, y]
            px[x, y] = tuple(
                max(0, min(255, round((c - 255.0 * (1 - af)) / af))) for c in (r, g, b)
            ) + (a,)

    png_path = os.path.join(HERE, "moonui.png")
    out.save(png_path)
    print("saved", png_path)

    ico_path = os.path.join(HERE, "moonui.ico")
    out.save(ico_path, sizes=[(s_, s_) for s_ in ICO_SIZES])
    print("saved", ico_path)


if __name__ == "__main__":
    main()
