#!/usr/bin/env node
/* SVG → moonui.png + moonui.ico 的重渲脚本（需要 macOS 的 qlmanage 生成中间图）。
 *
 * qlmanage 的缩略图是白底（没有透明通道），所以这里按 SVG 里的圆角矩形几何
 * 重建 alpha，并把白底合成过的边缘反解回来（observed = c*a + 255*(1-a)）。
 * 改了 moonui-logo.svg 之后跑一遍：
 *
 *     cd assets/logo && qlmanage -t -s 1024 -o . moonui-logo.svg && node render.js
 *
 * 2026-11-09 从 render.py 迁来：4x 超采样的圆角矩形、LANCZOS 缩小、ICO 缩放
 * 全由 scripts/png-image.js 按 Pillow 的整数口径复刻，零 npm 依赖。qlmanage 在
 * 受限沙箱里跑不起来（sandbox initialization failed），所以本机的端到端重渲
 * 验不了；scripts/logo-check.js 用仓库里现存的 moonui.png 独立验证掩码与 ICO，
 * 反解公式用一张合成白底图验证。证据边界写在那份判据的头注里。
 *
 * 用法：node assets/logo/render.js [--src <png>] [--outdir <dir>]
 * 默认 src=同目录 moonui-logo.svg.png，outdir=同目录。
 */

'use strict';
const fs = require('fs');
const path = require('path');
const img = require('../../scripts/png-image.js');

const CANVAS = 1024;
const RECT = [64, 64, 960, 960]; // 与 moonui-logo.svg 的背景矩形逐字对齐
const RADIUS = 192;
const SCALE = 4;                 // 4 倍超采样画圆角矩形掩码，边缘才有抗锯齿
const ICO_SIZES = [16, 32, 48, 64, 128, 256];

/** 4x 超采样圆角矩形 → LANCZOS 缩到 1024 的 8bit alpha 掩码。 */
function buildMask() {
  const s = CANVAS * SCALE;
  const big = img.roundedRect(s, RECT[0] * SCALE, RECT[1] * SCALE,
    RECT[2] * SCALE, RECT[3] * SCALE, RADIUS * SCALE, 255);
  return img.resizeL(big, s, CANVAS);
}

/**
 * 把 qlmanage 的白底图修成带 alpha 的 RGBA：
 *   - a == 255 / a == 0 的边缘不动（没有白底混进来 / 已经全透明）；
 *   - a < 12 的残边直接置全透明；
 *   - 其余按 observed = c*a + 255*(1-a) 反解，clamp 到 0..255。
 */
function render(src, maskOverride) {
  if (src.w !== CANVAS || src.h !== CANVAS) {
    throw new Error(`qlmanage 产物不是 ${CANVAS}x${CANVAS}：${src.w}x${src.h}`);
  }
  // maskOverride 只给判据用：4x 超采样 + 缩小要跑几秒，同一轮判据里
  // 复用已经独立验过的那份掩码，避免重复算两遍。CLI 不传，行为不变。
  const mask = maskOverride || buildMask();
  const out = Buffer.from(src.data);
  for (let i = 0; i < CANVAS * CANVAS; i++) {
    const o = i * 4;
    let a = mask[i];
    if (a < 12) { out[o] = out[o + 1] = out[o + 2] = out[o + 3] = 0; continue; }
    out[o + 3] = a;
    if (a === 255 || a === 0) continue;
    const af = a / 255;
    for (let c = 0; c < 3; c++) {
      out[o + c] = Math.max(0, Math.min(255,
        img.pyRound((out[o + c] - 255 * (1 - af)) / af)));
    }
  }
  return { w: CANVAS, h: CANVAS, data: out };
}

function main() {
  const argv = process.argv.slice(2);
  let srcPath = path.join(__dirname, 'moonui-logo.svg.png');
  let outDir = __dirname;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--src' && argv[i + 1]) srcPath = argv[++i];
    else if (argv[i] === '--outdir' && argv[i + 1]) outDir = argv[++i];
    else {
      process.stderr.write('用法：node render.js [--src <png>] [--outdir <dir>]\n');
      process.exit(2);
    }
  }
  if (!fs.existsSync(srcPath)) {
    process.stderr.write(
      `找不到 ${srcPath}\n` +
      '先跑：qlmanage -t -s 1024 -o . moonui-logo.svg（产出白底的 moonui-logo.svg.png）\n');
    process.exit(2);
  }
  const src = img.decodePNG(fs.readFileSync(srcPath));
  const out = render(src);
  fs.mkdirSync(outDir, { recursive: true });
  const png = path.join(outDir, 'moonui.png');
  const ico = path.join(outDir, 'moonui.ico');
  fs.writeFileSync(png, img.encodePNG(out.data, out.w, out.h));
  fs.writeFileSync(ico, img.icoFromImage(out, ICO_SIZES));
  process.stdout.write(`saved ${png}\nsaved ${ico}\n`);
}

module.exports = { buildMask, render, ICO_SIZES };
if (require.main === module) main();
