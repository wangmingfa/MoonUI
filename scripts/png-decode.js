#!/usr/bin/env node
"use strict";
/*
 * screenshot-window.sh 的 `decode <png> [stride]` 子命令。
 *
 * 从旧版 Python heredoc 逐行搬过来：zlib.decompress → inflateSync，
 * bytearray → Buffer，五种 PNG unfilter（None/Sub/Up/Average/Paeth）与亮度
 * 采样公式完全不动。只用 Node 内置模块，零第三方依赖。
 *
 * 与旧版一样只支持 8bit RGB（color=2）：screencapture -x -o -l 的产物是这个
 * 格式。别顺手扩展成 RGBA——那会改语义，A/B 对拍就失去基线了。
 */
const fs = require("fs");
const zlib = require("zlib");

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function main(argv) {
  const png = argv[0];
  const stride = argv[1] === undefined ? 8 : Number(argv[1]);
  if (png === undefined) throw new Error("用法: png-decode.js <png> [stride]");
  if (!Number.isInteger(stride) || stride <= 0) {
    throw new Error("stride 必须是正整数");
  }

  const data = fs.readFileSync(png);
  if (data.length < 8 || !data.subarray(0, 8).equals(PNG_MAGIC)) {
    throw new Error("不是 PNG");
  }

  let w = 0, h = 0, depth = 0, color = 0;
  const idats = [];
  let pos = 8;
  while (pos < data.length) {
    const length = data.readUInt32BE(pos);
    const ctype = data.toString("ascii", pos + 4, pos + 8);
    const body = data.subarray(pos + 8, pos + 8 + length);
    if (ctype === "IHDR") {
      w = body.readUInt32BE(0);
      h = body.readUInt32BE(4);
      depth = body[8];
      color = body[9];
      if (depth !== 8 || color !== 2) {
        throw new Error(`只支持 8bit RGB，遇到 depth=${depth} color=${color}`);
      }
    } else if (ctype === "IDAT") {
      idats.push(body);
    }
    pos += 12 + length;
  }

  const raw = zlib.inflateSync(Buffer.concat(idats));
  const bpp = 3;
  const rowLen = w * bpp;
  const pixels = Buffer.alloc(rowLen * h);
  let prev = Buffer.alloc(rowLen);
  let p = 0;
  for (let y = 0; y < h; y++) {
    const filt = raw[p++];
    const row = Buffer.from(raw.subarray(p, p + rowLen)); // 必须拷贝：下面要原地改
    p += rowLen;
    for (let i = 0; i < rowLen; i++) {
      const a = i >= bpp ? row[i - bpp] : 0;
      const b = prev[i];
      const c = i >= bpp ? prev[i - bpp] : 0;
      let pred = 0;
      if (filt === 1) {            // Sub
        pred = a;
      } else if (filt === 2) {     // Up
        pred = b;
      } else if (filt === 3) {     // Average
        pred = (a + b) >> 1;
      } else if (filt === 4) {     // Paeth
        const pp = a + b - c;
        const pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
        pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      }
      // 旧版没有 else 分支：未知滤波时不 unfilter，等价于 pred = 0。
      row[i] = (row[i] + pred) & 255;
    }
    row.copy(pixels, y * rowLen);
    prev = row;
  }

  console.log(`W=${w} H=${h} stride=${stride}（亮度 0-255，空格分段）`);
  for (let y = 0; y < h; y += stride) {
    const cells = [];
    for (let x = 0; x < w; x += stride) {
      const i = (y * w + x) * bpp;
      const r = pixels[i], g = pixels[i + 1], bl = pixels[i + 2];
      cells.push(String(Math.floor((r * 30 + g * 59 + bl * 11) / 100)));
    }
    console.log(cells.join(" "));
  }
}

main(process.argv.slice(2));
