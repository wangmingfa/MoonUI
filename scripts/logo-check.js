#!/usr/bin/env node
/* 图标工具迁移的 A/B 判据（2026-11-09，零依赖）。
 *
 * 用 `node scripts/gen-native-linux-gtk.js` 那条链之外的**独立真值**：仓库里
 * 现存的 4 个 Pillow 产物（moonui.png / moonui.ico / luna.png / luna.ico）。
 * 期望值不是新脚本自己写的那份账，所以改坏实现会真变红。
 *
 * 证据边界（如实写清，别拿它去证别的东西）：
 *   - 本机 Pillow 未安装、`qlmanage` 在沙箱里报 sandbox initialization failed，
 *     所以 **render.js 的端到端重渲（读 qlmanage 白底中间图 → 出 PNG）验不了**。
 *     能验的是：① 4x 掩码与现存 moonui.png 的 alpha 逐像素一致；② 反解公式
 *     用一张**手工构造**的白底合成图对拍独立期望值；③ ICO 由现存 moonui.png
 *     缩放打包后与现存 moonui.ico 逐像素对拍。
 *   - PNG/ICO 的**字节**不会与 Pillow 产物相同（Pillow 用自适应 filter，这里
 *     统一 filter 0），判据是**像素级**。
 *   - ICO 的重采样在极少数半透明边缘像素上还差 ±1~6（Pillow 的 RGBa 反预乘
 *     舍入细节），逐条打印 diff 与阈值，不假装 100% 一致。
 *
 * 用法：node scripts/logo-check.js
 */

'use strict';
const fs = require('fs');
const path = require('path');
const img = require('./png-image.js');
const luna = require('../assets/logo/luna_draw.js');
const render = require('../assets/logo/render.js');

const ROOT = path.dirname(__dirname);
const LOGO = path.join(ROOT, 'assets', 'logo');
const SIZES = [16, 32, 48, 64, 128, 256];
// 每条目允许的像素字节差与最大通道差（实测最大 28 字节 / 6，见下面逐条打印）。
const MAX_DIFF_BYTES = 32;
const MAX_CHANNEL_DELTA = 8;

let fails = 0;
function bad(name, msg) { fails++; console.log(`FAIL  ${name}\n      ${msg}`); }
function pass(name, msg) { console.log(`PASS  ${name}${msg ? ' — ' + msg : ''}`); }
function diff(a, b) {
  let n = 0, max = 0;
  for (let i = 0; i < a.length; i++) {
    const d = Math.abs(a[i] - b[i]);
    if (d) { n++; if (d > max) max = d; }
  }
  return { n, max };
}
function rgbaEqual(name, got, want) {
  const d = diff(got.data, want.data);
  if (d.n) bad(name, `逐像素差 ${d.n}/${got.data.length} 字节，最大 ${d.max}`);
  else pass(name, `${got.w}x${got.h} 逐像素一致`);
}
function icoEqual(name, gotBuf, wantBuf) {
  const got = img.readIco(gotBuf), want = img.readIco(wantBuf);
  if (got.length !== want.length) { bad(name, `条目数 ${got.length} != ${want.length}`); return; }
  let worst = 0, worstMax = 0;
  for (let i = 0; i < want.length; i++) {
    if (got[i].size !== want[i].size) { bad(name, `第 ${i} 条尺寸 ${got[i].size} != ${want[i].size}`); return; }
    if (got[i].png.toString('hex', 0, 8) !== '89504e470d0a1a0a') {
      bad(name, `第 ${i} 条不是 PNG 条目`); return;
    }
    const a = img.decodePNG(got[i].png), b = img.decodePNG(want[i].png);
    const d = diff(a.data, b.data);
    worst = Math.max(worst, d.n); worstMax = Math.max(worstMax, d.max);
    if (d.n > MAX_DIFF_BYTES || d.max > MAX_CHANNEL_DELTA) {
      bad(name, `${want[i].size}x${want[i].size} 差 ${d.n} 字节 / 最大 ${d.max}，超阈值`);
      return;
    }
  }
  pass(name, `6 条 PNG 条目，最大 ${worst} 字节 / 通道差 ${worstMax}`);
}
function icoStructure(name, buf) {
  if (buf.readUInt16LE(0) !== 0 || buf.readUInt16LE(2) !== 1) { bad(name, 'ICONDIR 头不对'); return; }
  const n = buf.readUInt16LE(4);
  if (n !== SIZES.length) { bad(name, `条目数 ${n} != ${SIZES.length}`); return; }
  let off = 6 + 16 * n;
  const sizes = [];
  for (let i = 0; i < n; i++) {
    const o = 6 + 16 * i;
    const sz = buf.readUInt32LE(o + 8);
    sizes.push(buf[o] || 256);
    if (buf.readUInt16LE(o + 4) !== 0 || buf.readUInt16LE(o + 6) !== 32) {
      bad(name, `第 ${i} 条 planes/bpp 不是 0/32`); return;
    }
    if (buf.readUInt32LE(o + 12) !== off) { bad(name, `第 ${i} 条 offset 不接在上一条后面`); return; }
    if (buf.toString('hex', off, off + 8) !== '89504e470d0a1a0a') {
      bad(name, `第 ${i} 条 offset 处不是 PNG`); return;
    }
    off += sz;
  }
  if (JSON.stringify(sizes) !== JSON.stringify(SIZES)) { bad(name, '尺寸序列不对：' + sizes); return; }
  if (off !== buf.length) { bad(name, `目录算出的总长 ${off} != 文件长度 ${buf.length}`); return; }
  pass(name, `${n} 条、${sizes.join('/')}、PNG 条目、planes=0/bpp=32`);
}

function main() {
  // ---- ① luna 主图：自绘 1024 与现存 Pillow 产物逐像素一致 ----
  const lunaPng = img.decodePNG(fs.readFileSync(path.join(LOGO, 'luna.png')));
  const drawn = luna.draw();
  rgbaEqual('luna.png 自绘 1024 主图', drawn, lunaPng);

  // ---- ② 两张 ICO：由主图重采样打包，与现存 Pillow 产物对拍 ----
  const lunaIco = img.icoFromImage(drawn, SIZES);
  icoStructure('luna.ico 容器结构', lunaIco);
  icoEqual('luna.ico 六条像素', lunaIco, fs.readFileSync(path.join(LOGO, 'luna.ico')));

  const moonuiPng = img.decodePNG(fs.readFileSync(path.join(LOGO, 'moonui.png')));
  const moonuiIco = img.icoFromImage(moonuiPng, SIZES);
  icoStructure('moonui.ico 容器结构', moonuiIco);
  icoEqual('moonui.ico 六条像素', moonuiIco, fs.readFileSync(path.join(LOGO, 'moonui.ico')));

  // ---- ③ 4x 超采样掩码与现存 moonui.png 的 alpha 逐像素一致 ----
  const mask = render.buildMask();
  const gotAlpha = Buffer.alloc(1024 * 1024);
  for (let i = 0; i < 1024 * 1024; i++) gotAlpha[i] = mask[i] < 12 ? 0 : mask[i];
  const wantAlpha = Buffer.alloc(1024 * 1024);
  for (let i = 0; i < 1024 * 1024; i++) wantAlpha[i] = moonuiPng.data[i * 4 + 3];
  const dm = diff(gotAlpha, wantAlpha);
  if (dm.n) bad('4x 掩码 vs moonui.png alpha', `差 ${dm.n} 字节，最大 ${dm.max}`);
  else pass('4x 掩码 vs moonui.png alpha', '1048576 像素逐像素一致');

  // ---- ④ 白底反解公式：手工构造合成图，对拍独立期望值 ----
  // observed = pyRound(C*af + 255*(1-af))；反解应回到 C。合成那一步的整数
  // 舍入 e（|e|<=0.5）在反解时会被除以 af 放大，所以**独立**按数值分析给
  // 容差 ceil(0.5/af)+1（不是从实现里读出来的），低 alpha 的残边自然放宽。
  // a=255 那片没有反解，要求精确一致。
  const C = [96, 148, 200];
  const synthetic = Buffer.alloc(1024 * 1024 * 4);
  for (let i = 0; i < 1024 * 1024; i++) {
    const o = i * 4;
    const a = gotAlpha[i];
    const af = a / 255;
    for (let c = 0; c < 3; c++) {
      synthetic[o + c] = Math.max(0, Math.min(255,
        img.pyRound(C[c] * af + 255 * (1 - af))));
    }
    synthetic[o + 3] = 255;
  }
  const out = render.render({ w: 1024, h: 1024, data: synthetic }, mask);
  let badPx = 0, worstExample = '';
  for (let i = 0; i < 1024 * 1024; i++) {
    const o = i * 4, a = gotAlpha[i], af = a / 255;
    if (a === 0) {
      if (out.data[o] || out.data[o + 1] || out.data[o + 2] || out.data[o + 3]) {
        badPx++; if (!worstExample) worstExample = `i=${i} a=${a} 应全 0`;
      }
      continue;
    }
    if (out.data[o + 3] !== a) {
      badPx++; if (!worstExample) worstExample = `i=${i} alpha ${out.data[o + 3]} != ${a}`; continue;
    }
    const tol = a === 255 ? 0 : Math.ceil(0.5 / af) + 1;
    for (let c = 0; c < 3; c++) {
      const d = Math.abs(out.data[o + c] - C[c]);
      if (d > tol) {
        badPx++;
        if (!worstExample) worstExample = `i=${i} a=${a} c${c}: ${out.data[o + c]} vs ${C[c]}（容差 ${tol}）`;
        break;
      }
    }
  }
  if (badPx) bad('白底反解公式', `${badPx} 像素超容差；首个 ${worstExample}`);
  else pass('白底反解公式', '合成白底图反解回原色（a=255 精确，其余按 1/af 放大舍入容差）');

  // ---- ⑤ PNG 编解码自洽（合成图往返） ----
  const enc = img.encodePNG(synthetic, 1024, 1024);
  const dec = img.decodePNG(enc);
  rgbaEqual('encodePNG/decodePNG 往返', dec, { w: 1024, h: 1024, data: synthetic });

  console.log(`[logo-check] ${fails === 0 ? 'OK' : 'FAIL'}：${fails} 条红`);
  process.exit(fails === 0 ? 0 : 1);
}

main();
