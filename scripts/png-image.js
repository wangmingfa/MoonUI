#!/usr/bin/env node
/* MoonUI 图标工具共用的零依赖图像层（2026-11-09）。
 *
 * 只用 Node 内置 fs / zlib / Buffer，没有 npm 依赖。这里刻意复刻 Pillow 的四个
 * 口径，判据是"与仓库里现存的 Pillow 产物逐像素一致"（见 scripts/logo-check.js）：
 *
 *   ① `ImageDraw.rounded_rectangle` / `ellipse` 的**整数中点椭圆状态机**
 *      （Pillow 10.4 src/libImaging/Draw.c 的 quarter_* / ellipse_*）。用解析圆
 *      会在圆角边界差 56 个像素，所以这里照抄状态机生成每条扫描线的 x 边界。
 *   ② `Image.resize(..., Resampling.LANCZOS)` 的定点重采样
 *      （src/libImaging/Resample.c：support=3、PRECISION_BITS=22、系数归一化后
 *      ROUND_UP 到定点、累加起点 1<<21、clip8(ss>>22)）。
 *   ③ **RGBA 预乘**：ICO 保存走 `frame.thumbnail(size, LANCZOS, reducing_gap=None)`，
 *      Pillow 在 resize 前把 RGBA 转 RGBa（预乘）、之后再转回。口径是
 *      预乘 `round(r*a/255)`、反预乘 `floor(v*255/a)`（a=0 时置 0）。
 *   ④ ICO 容器：ICONDIR + 每尺寸一条 ICONDIRENTRY + 顺序拼接的 PNG 条目
 *      （planes=0 / bpp=32，256 那格的宽高字节写 0）。
 *
 * PNG 写出统一用 filter 0（Pillow 用自适应 filter，字节不同但像素相同）；判据
 * 因此是**像素级**而不是字节级——这一点在 scripts/logo-check.js 里如实说明。
 */

'use strict';
const zlib = require('zlib');

// ---------------------------------------------------------------------------
// PNG 读写
// ---------------------------------------------------------------------------

function decodePNG(buf) {
  if (buf.toString('hex', 0, 8) !== '89504e470d0a1a0a') throw new Error('不是 PNG');
  let o = 8, w = 0, h = 0, type = 0;
  const idat = [];
  while (o < buf.length) {
    const n = buf.readUInt32BE(o);
    const t = buf.toString('ascii', o + 4, o + 8);
    const d = buf.subarray(o + 8, o + 8 + n);
    if (t === 'IHDR') { w = d.readUInt32BE(0); h = d.readUInt32BE(4); type = d[9]; }
    if (t === 'IDAT') idat.push(d);
    o += 12 + n;
  }
  const bpp = type === 6 ? 4 : type === 2 ? 3 : 0;
  if (!bpp) throw new Error('只支持 8bit RGB/RGBA PNG，收到 type=' + type);
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * bpp;
  const out = Buffer.alloc(w * h * 4);
  let p = 0;
  // filter 的 prev 必须是**上一行解码后的原始通道字节**（bpp 个/像素），
  // 不能拿 out（统一 4 通道）来当 prev，否则 RGB 图会错位。
  let prevRaw = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const f = raw[p++];
    const cur = Buffer.from(raw.subarray(p, p + stride));
    p += stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const b = prevRaw[x];
      const c = x >= bpp ? prevRaw[x - bpp] : 0;
      let v = 0;
      switch (f) {
        case 0: break;
        case 1: v = a; break;
        case 2: v = b; break;
        case 3: v = (a + b) >> 1; break;
        case 4: {
          const pp = a + b - c;
          const pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
          v = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          break;
        }
        default: throw new Error('未支持的 PNG filter ' + f);
      }
      cur[x] = (cur[x] + v) & 255;
    }
    for (let x = 0; x < w; x++) {
      const si = x * bpp, di = (y * w + x) * 4;
      out[di] = cur[si]; out[di + 1] = cur[si + 1]; out[di + 2] = cur[si + 2];
      out[di + 3] = bpp === 4 ? cur[si + 3] : 255;
    }
    prevRaw = cur;
  }
  return { w, h, data: out };
}

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 4, 'ascii');
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

/** RGBA Buffer（w*h*4）→ PNG（8bit RGBA，filter 0）。 */
function encodePNG(data, w, h) {
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0;
    data.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from('89504e470d0a1a0a', 'hex'),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 6 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---------------------------------------------------------------------------
// ICO 容器（PNG 条目）
// ---------------------------------------------------------------------------

/** entries: [{size, png}]，按 size 升序。 */
function makeIco(entries) {
  const dir = Buffer.alloc(6 + 16 * entries.length);
  dir.writeUInt16LE(0, 0); dir.writeUInt16LE(1, 2);
  dir.writeUInt16LE(entries.length, 4);
  let off = dir.length;
  const parts = [dir];
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i], o = 6 + 16 * i;
    dir[o] = dir[o + 1] = e.size >= 256 ? 0 : e.size;
    dir[o + 2] = 0; dir[o + 3] = 0;
    dir.writeUInt16LE(0, o + 4);       // planes
    dir.writeUInt16LE(32, o + 6);      // bpp
    dir.writeUInt32LE(e.png.length, o + 8);
    dir.writeUInt32LE(off, o + 12);
    off += e.png.length;
    parts.push(e.png);
  }
  return Buffer.concat(parts);
}

function readIco(buf) {
  const n = buf.readUInt16LE(4), out = [];
  for (let i = 0; i < n; i++) {
    const o = 6 + 16 * i;
    const sz = buf.readUInt32LE(o + 8), off = buf.readUInt32LE(o + 12);
    out.push({ size: buf[o] || 256, png: buf.subarray(off, off + sz) });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Pillow Draw.c：整数中点椭圆 → 逐扫描线的水平线段
// ---------------------------------------------------------------------------

function quarterInit(a, b) {
  const s = { a, b, cx: a, cy: b % 2, ex: a % 2, ey: b, a2: a * a, b2: b * b, finished: false };
  s.a2b2 = s.a2 * s.b2;
  if (a < 0 || b < 0) s.finished = true;
  return s;
}
function quarterDelta(s, x, y) {
  return Math.abs(s.a2 * y * y + s.b2 * x * x - s.a2b2);
}
function quarterNext(s) {
  if (s.finished) return null;
  const rx = s.cx, ry = s.cy;
  if (s.cx === s.ex && s.cy === s.ey) {
    s.finished = true;
  } else {
    let nx = s.cx, ny = s.cy + 2;
    let nd = quarterDelta(s, nx, ny);
    if (nx > 1) {
      let d2 = quarterDelta(s, s.cx - 2, s.cy + 2);
      if (nd > d2) { nx = s.cx - 2; ny = s.cy + 2; nd = d2; }
      d2 = quarterDelta(s, s.cx - 2, s.cy);
      if (nd > d2) { nx = s.cx - 2; ny = s.cy; }
    }
    s.cx = nx; s.cy = ny;
  }
  return [rx, ry];
}
function ellipseInit(a, b, w) {
  const st = { buf: [], leftmost: a % 2, st_o: quarterInit(a, b), st_i: null,
    pr: 0, py: 0, pl: 0, finished: false };
  const first = quarterNext(st.st_o);
  if (w < 1 || first === null) st.finished = true;
  else {
    st.pr = first[0]; st.py = first[1];
    st.st_i = quarterInit(a - 2 * (w - 1), b - 2 * (w - 1));
    st.pl = st.leftmost;
  }
  return st;
}
function ellipseNext(s) {
  if (s.buf.length === 0) {
    if (s.finished) return null;
    const y = s.py;
    let l = s.pl;
    const r = s.pr;
    let cx = 0, cy = 0, nr;
    for (;;) {
      const q = quarterNext(s.st_o);
      if (q === null) { nr = -1; break; }
      cx = q[0]; cy = q[1];
      if (cy > y) { nr = 0; break; }
    }
    if (nr === -1) s.finished = true; else { s.pr = cx; s.py = cy; }
    for (;;) {
      const q = quarterNext(s.st_i);
      if (q === null) { nr = -1; break; }
      cx = q[0]; cy = q[1];
      if (cy > y) { nr = 0; break; }
      l = cx;
    }
    s.pl = (nr === -1) ? s.leftmost : cx;
    if ((l > 0 || l < r) && y > 0) s.buf.push([l === 0 ? 2 : l, y, r]);
    if (y > 0) s.buf.push([-r, y, -l]);
    if (l > 0 || l < r) s.buf.push([l === 0 ? 2 : l, -y, r]);
    s.buf.push([-r, -y, -l]);
  }
  return s.buf.pop();
}

/** 返回 Map<y, [minX,maxX]>；size 是画布边长（hline 会裁剪到画布内）。 */
function ellipseSpans(x0, y0, x1, y1, size) {
  const a = x1 - x0, b = y1 - y0;
  const st = ellipseInit(a, b, a + b);
  const spans = new Map();
  let it;
  while ((it = ellipseNext(st)) !== null) {
    const X0 = it[0], Y = it[1], X1 = it[2];
    const yy = y0 + Math.trunc((Y + b) / 2);
    const xa = x0 + Math.trunc((X0 + a) / 2);
    const xb = x0 + Math.trunc((X1 + a) / 2);
    if (yy < 0 || yy >= size) continue;
    const lo = Math.max(0, Math.min(xa, xb));
    const hi = Math.min(size - 1, Math.max(xa, xb));
    const cur = spans.get(yy);
    if (cur) { cur[0] = Math.min(cur[0], lo); cur[1] = Math.max(cur[1], hi); }
    else spans.set(yy, [lo, hi]);
  }
  return spans;
}

/** Pillow 的 rounded_rectangle（fill=value）。返回 Uint8Array(size*size)。 */
function roundedRect(size, x0, y0, x1, y1, r, value = 1) {
  const m = new Uint8Array(size * size);
  const sp = ellipseSpans(x0, y0, x0 + 2 * r, y0 + 2 * r, size);
  const leftEdge = new Int32Array(size).fill(-1);
  for (const [y, v] of sp) leftEdge[y] = v[0];
  for (let y = y0; y <= y1; y++) {
    let lo = x0, hi = x1;
    if (y < y0 + r || y > y1 - r) {
      // 上下两半关于矩形水平中线镜像；左右两角关于矩形竖直中线镜像。
      const yy = y < y0 + r ? y : y0 + (y1 - y);
      const j = leftEdge[yy];
      if (j >= 0) { lo = j; hi = x0 + x1 - j; }
    }
    lo = Math.max(0, lo); hi = Math.min(size - 1, hi);
    if (lo <= hi) m.fill(value, y * size + lo, y * size + hi + 1);
  }
  return m;
}

// ---------------------------------------------------------------------------
// Pillow Resample.c：LANCZOS 定点重采样
// ---------------------------------------------------------------------------

const PREC = 22, SHIFT = 1 << PREC, HALF = 1 << (PREC - 1);
function sinc(x) { if (x === 0) return 1; x *= Math.PI; return Math.sin(x) / x; }
function lanczos(x) { return (-3 <= x && x < 3) ? sinc(x) * sinc(x / 3) : 0; }
function clip8(v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

function coeffs(inSize, outSize) {
  const scale = inSize / outSize;
  const fs = Math.max(scale, 1);
  const support = 3 * fs;
  const ksize = Math.ceil(support) * 2 + 1;
  const bounds = [], kk = [];
  for (let xx = 0; xx < outSize; xx++) {
    const center = (xx + 0.5) * scale;
    let xmin = Math.trunc(center - support + 0.5);
    if (xmin < 0) xmin = 0;
    let xmax = Math.trunc(center + support + 0.5);
    if (xmax > inSize) xmax = inSize;
    const n = xmax - xmin;
    const k = new Float64Array(ksize);
    let ww = 0;
    for (let x = 0; x < n; x++) {
      const w = lanczos((x + xmin - center + 0.5) / fs);
      k[x] = w; ww += w;
    }
    if (ww !== 0) for (let x = 0; x < n; x++) k[x] /= ww;
    const ki = new Int32Array(ksize);
    for (let x = 0; x < ksize; x++) {
      const v = k[x] * SHIFT;
      ki[x] = Math.trunc(v >= 0 ? v + 0.5 : v - 0.5); // C 的 ROUND_UP（远离零）
    }
    bounds.push([xmin, n]); kk.push(ki);
  }
  return { bounds, kk };
}

/** 单通道（L 模式）正方形缩小，Pillow resize LANCZOS 口径。 */
function resizeL(src, inSize, outSize) {
  const c = coeffs(inSize, outSize);
  const h = new Uint8Array(outSize * inSize);
  for (let y = 0; y < inSize; y++) {
    for (let x = 0; x < outSize; x++) {
      const [xmin, n] = c.bounds[x], k = c.kk[x];
      let s = HALF;
      for (let t = 0; t < n; t++) s += src[y * inSize + (t + xmin)] * k[t];
      h[y * outSize + x] = clip8(s >> PREC);
    }
  }
  const v = new Uint8Array(outSize * outSize);
  for (let y = 0; y < outSize; y++) {
    for (let x = 0; x < outSize; x++) {
      const [ymin, n] = c.bounds[y], k = c.kk[y];
      let s = HALF;
      for (let t = 0; t < n; t++) s += h[(t + ymin) * outSize + x] * k[t];
      v[y * outSize + x] = clip8(s >> PREC);
    }
  }
  return v;
}

/** RGBA 正方形缩小：Pillow 在 resize 前后做 RGBa 预乘/反预乘。 */
function resizeRGBA(im, outSize) {
  if (im.w !== im.h) throw new Error('只支持正方形');
  const inSize = im.w;
  const src = Buffer.from(im.data);
  for (let i = 0; i < inSize * inSize; i++) {
    const o = i * 4, a = src[o + 3];
    for (let c = 0; c < 3; c++) src[o + c] = Math.round(src[o + c] * a / 255);
  }
  const c = coeffs(inSize, outSize);
  const h = Buffer.alloc(outSize * inSize * 4);
  for (let y = 0; y < inSize; y++) {
    for (let x = 0; x < outSize; x++) {
      const [xmin, n] = c.bounds[x], k = c.kk[x];
      let s0 = HALF, s1 = HALF, s2 = HALF, s3 = HALF;
      for (let t = 0; t < n; t++) {
        const o = (y * inSize + t + xmin) * 4, kk = k[t];
        s0 += src[o] * kk; s1 += src[o + 1] * kk; s2 += src[o + 2] * kk; s3 += src[o + 3] * kk;
      }
      const o = (y * outSize + x) * 4;
      h[o] = clip8(s0 >> PREC); h[o + 1] = clip8(s1 >> PREC);
      h[o + 2] = clip8(s2 >> PREC); h[o + 3] = clip8(s3 >> PREC);
    }
  }
  const v = Buffer.alloc(outSize * outSize * 4);
  for (let y = 0; y < outSize; y++) {
    for (let x = 0; x < outSize; x++) {
      const [ymin, n] = c.bounds[y], k = c.kk[y];
      let s0 = HALF, s1 = HALF, s2 = HALF, s3 = HALF;
      for (let t = 0; t < n; t++) {
        const o = ((t + ymin) * outSize + x) * 4, kk = k[t];
        s0 += h[o] * kk; s1 += h[o + 1] * kk; s2 += h[o + 2] * kk; s3 += h[o + 3] * kk;
      }
      const o = (y * outSize + x) * 4;
      v[o] = clip8(s0 >> PREC); v[o + 1] = clip8(s1 >> PREC);
      v[o + 2] = clip8(s2 >> PREC); v[o + 3] = clip8(s3 >> PREC);
    }
  }
  for (let i = 0; i < outSize * outSize; i++) {
    const o = i * 4, a = v[o + 3];
    for (let c = 0; c < 3; c++) v[o + c] = a === 0 ? 0 : clip8(Math.floor(v[o + c] * 255 / a));
  }
  return { w: outSize, h: outSize, data: v };
}

/** 从 1024 主图生成 6 条 PNG-ICO。 */
function icoFromImage(im, sizes = [16, 32, 48, 64, 128, 256]) {
  return makeIco(sizes.map((size) => {
    const small = resizeRGBA(im, size);
    return { size, png: encodePNG(small.data, size, size) };
  }));
}

/** Python 的 round（banker's rounding，.5 取偶数）。 */
function pyRound(x) {
  const f = Math.floor(x), d = x - f;
  if (d < 0.5) return f;
  if (d > 0.5) return f + 1;
  return (f % 2 === 0) ? f : f + 1;
}

module.exports = {
  decodePNG, encodePNG, makeIco, readIco,
  ellipseSpans, roundedRect,
  resizeL, resizeRGBA, icoFromImage,
  pyRound, clip8, coeffs,
};
