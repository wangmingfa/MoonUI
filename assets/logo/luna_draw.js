#!/usr/bin/env node
/* 自绘原创 Luna 图标（luna.png 1024 + luna.ico 多尺寸）——音乐播放器示例的图标。
 * 设计：圆角方形深蓝渐变徽标 + 月牙（crescent）+ 均衡器柱条，纯几何原创，无任何
 * 品牌/产品外观，可由本脚本完整复现（证明是算出来的、不是从别处拆的）。
 * 内容近满幅（alpha 包围盒 ~95%），由后端 set_app_icon 按 macOS 图标网格补留白
 * （见同目录 README.md）。
 *
 * 重渲：node assets/logo/luna_draw.js [输出目录]
 * 2026-11-09 从 luna_draw.py 迁来：Pillow 的 rounded_rectangle / ellipse /
 * ImageChops.subtract / ICO 缩放全部由 scripts/png-image.js 按 Pillow 的整数
 * 栅格化与定点 LANCZOS 口径复刻，无需 Pillow、无需 npm 依赖。判据见
 * scripts/logo-check.js（与仓库里现存的 Pillow 产物逐像素对拍）。
 */

'use strict';
const fs = require('fs');
const path = require('path');
const img = require('../../scripts/png-image.js');

const S = 1024;
const MARGIN = 24;
const RADIUS = 200;
const TOP = [34, 70, 110];
const BOT = [58, 110, 165];
const MOON = [234, 242, 251];
const BAR = [143, 192, 240];
const ICO_SIZES = [16, 32, 48, 64, 128, 256];

function lerp(a, b, t) {
  return [0, 1, 2].map((i) => img.pyRound(a[i] + (b[i] - a[i]) * t));
}

/** 把 ellipseSpans 的逐行线段填进一张 L 图（Pillow ImageDraw.ellipse）。 */
function ellipseMask(x0, y0, x1, y1) {
  const m = new Uint8Array(S * S);
  for (const [y, v] of img.ellipseSpans(x0, y0, x1, y1, S)) {
    m.fill(255, y * S + v[0], y * S + v[1] + 1);
  }
  return m;
}

function draw() {
  const canvas = Buffer.alloc(S * S * 4); // RGBA 全 0 = 透明
  const grad = new Uint8Array(S * 3);
  for (let y = 0; y < S; y++) {
    const c = lerp(TOP, BOT, y / (S - 1));
    grad[y * 3] = c[0]; grad[y * 3 + 1] = c[1]; grad[y * 3 + 2] = c[2];
  }

  // 1) 圆角方形掩码 → 合成徽标（paste 用 L 掩码，255 处取渐变、0 处保持透明）
  const mask = img.roundedRect(S, MARGIN, MARGIN, S - MARGIN, S - MARGIN, RADIUS, 255);
  for (let y = 0; y < S; y++) {
    for (let x = 0; x < S; x++) {
      if (mask[y * S + x] === 0) continue;
      const o = (y * S + x) * 4;
      canvas[o] = grad[y * 3]; canvas[o + 1] = grad[y * 3 + 1];
      canvas[o + 2] = grad[y * 3 + 2]; canvas[o + 3] = 255;
    }
  }

  // 2) 月牙 = 大圆减偏移小圆（ImageChops.subtract），露出背后的渐变
  const full = ellipseMask(185, 205, 615, 635);
  const cut = ellipseMask(305, 135, 735, 565);
  for (let i = 0; i < S * S; i++) {
    if (full[i] === 0 || cut[i] !== 0) continue; // crescent = subtract(full, cut)
    const o = i * 4;
    canvas[o] = MOON[0]; canvas[o + 1] = MOON[1]; canvas[o + 2] = MOON[2];
    canvas[o + 3] = 255;
  }

  // 3) 均衡器柱条（4 根，圆角，右下角）
  const bars = [[690, 640, 742, 760], [766, 590, 818, 760],
    [842, 545, 894, 760], [918, 600, 970, 760]];
  for (const [x0, y0, x1, y1] of bars) {
    const m = img.roundedRect(S, x0, y0, x1, y1, 26, 255);
    for (let i = 0; i < S * S; i++) {
      if (m[i] === 0) continue;
      const o = i * 4;
      canvas[o] = BAR[0]; canvas[o + 1] = BAR[1]; canvas[o + 2] = BAR[2];
      canvas[o + 3] = 255;
    }
  }
  return { w: S, h: S, data: canvas };
}

function alphaBBox(im) {
  let x0 = im.w, y0 = im.h, x1 = -1, y1 = -1;
  for (let y = 0; y < im.h; y++) {
    for (let x = 0; x < im.w; x++) {
      if (im.data[(y * im.w + x) * 4 + 3] === 0) continue;
      if (x < x0) x0 = x; if (x > x1) x1 = x;
      if (y < y0) y0 = y; if (y > y1) y1 = y;
    }
  }
  return [x0, y0, x1 + 1, y1 + 1];
}

function main() {
  const outDir = process.argv[2] || __dirname;
  const im = draw();
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'luna.png'), img.encodePNG(im.data, im.w, im.h));
  fs.writeFileSync(path.join(outDir, 'luna.ico'), img.icoFromImage(im, ICO_SIZES));
  const [x0, y0, x1, y1] = alphaBBox(im);
  process.stdout.write(
    `saved ${path.join(outDir, 'luna.png')} alpha-bbox (${x0}, ${y0}, ${x1}, ${y1})` +
    ` -> ${(100 * (x1 - x0) / S).toFixed(1)}%x${(100 * (y1 - y0) / S).toFixed(1)}%\n`);
  process.stdout.write(`saved ${path.join(outDir, 'luna.ico')}\n`);
}

module.exports = { draw, alphaBBox, ICO_SIZES };
if (require.main === module) main();
