#!/usr/bin/env python3
"""自绘原创 Luna 图标（luna.png 1024 + luna.ico 多尺寸）——音乐播放器示例的图标。
设计：圆角方形深蓝渐变徽标 + 月牙（crescent）+ 均衡器柱条，纯几何原创，无任何
品牌/产品外观，可由本脚本完整复现（证明是算出来的、不是从别处拆的）。
内容近满幅（alpha 包围盒 ~95%），由后端 set_app_icon 按 macOS 图标网格补留白
（见同目录 README.md）。

重渲：
    python3 assets/logo/luna_draw.py
"""
import os
from PIL import Image, ImageDraw, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024
MARGIN = 24
RADIUS = 200

TOP = (34, 70, 110)      # 深蓝顶
BOT = (58, 110, 165)     # 浅蓝底
MOON = (234, 242, 251)   # 月牙浅色
BAR = (143, 192, 240)    # 均衡器强调色


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    # 1) 垂直渐变底
    grad = Image.new("RGB", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(TOP, BOT, y / (S - 1)))

    # 2) 圆角方形掩码 -> 合成徽标
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [MARGIN, MARGIN, S - MARGIN, S - MARGIN], radius=RADIUS, fill=255
    )
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas.paste(grad, (0, 0), mask)

    # 3) 月牙 = 大圆减偏移小圆（减法掩码，露出背后的渐变）
    full = Image.new("L", (S, S), 0)
    ImageDraw.Draw(full).ellipse([185, 205, 615, 635], fill=255)   # 大圆
    cut = Image.new("L", (S, S), 0)
    ImageDraw.Draw(cut).ellipse([305, 135, 735, 565], fill=255)    # 偏移圆
    crescent = ImageChops.subtract(full, cut)
    moon_layer = Image.new("RGBA", (S, S), MOON + (255,))
    canvas.paste(moon_layer, (0, 0), crescent)

    # 4) 均衡器柱条（4 根，圆角，右下角，示意“音乐”）
    bd = ImageDraw.Draw(canvas)
    bars = [(690, 640, 742, 760), (766, 590, 818, 760),
            (842, 545, 894, 760), (918, 600, 970, 760)]
    for x0, y0, x1, y1 in bars:
        bd.rounded_rectangle([x0, y0, x1, y1], radius=26, fill=BAR + (255,))

    # 5) 落盘
    png = os.path.join(HERE, "luna.png")
    canvas.save(png)
    bbox = canvas.getbbox()
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    print("saved", png, "alpha-bbox", bbox, f"-> {100 * w / S:.1f}%x{100 * h / S:.1f}%")
    ico = os.path.join(HERE, "luna.ico")
    canvas.save(ico, sizes=[(s, s) for s in [16, 32, 48, 64, 128, 256]])
    print("saved", ico)


if __name__ == "__main__":
    main()
