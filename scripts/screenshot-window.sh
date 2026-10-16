#!/usr/bin/env bash
# 窗口截图工具（T88③）：按窗口 id 截图 + 解码像素读数，批二/批四真窗批用过的
# /tmp 临时脚本固化成的产品化工具（mac 侧 `screencapture -x -l <id>` 路线已在
# T81 的 Scroll 滚动条批验证过——按窗 id 截 + 最小 PNG 解码像素断言）。
#
# 用法（三个子命令，参数化窗口 id 与输出路径）：
#   scripts/screenshot-window.sh list <pid> [layer]
#       列出某进程名下的窗口 id（CGWindowID）与几何——窗口 id 从这里取。
#       MoonUI 的窗口句柄是原生对象指针，不是 CGWindowID，所以要按 owner 进程
#       枚举一跳。layer 可选（默认 0，普通窗口层）。
#   scripts/screenshot-window.sh capture <window-id> [output]
#       按窗口 id 截图（静音、不含影子）。output 缺省落系统临时目录
#       （$TMPDIR/moonui-shot-<id>.png）——仓库里不留任何文件（AGENTS.md）。
#   scripts/screenshot-window.sh decode <png> [stride]
#       最小 PNG 解码（zlib inflate + unfilter，沿批二/批四的解码读数同款），
#       打印尺寸头 + 按步长采样的亮度矩阵（0-255）。像素断言按诊断逐次手写
#       ——亮度读数就是断言载体（批二读法：槽位亮度 ~237 + 滑块 ~171）。
#
# 为什么不接进门禁（记案）：截图断言依赖真窗交互——窗口要真的开在屏幕上、
# 真人停手操作才能截（真鼠标交错会让像素账假红，见记忆 warn-before-real-
# window-tests 的同一条理由）。它是手工诊断工具，不是 CI——真窗批的等价
# CI 验证是 backends/native-macos 的真窗口测试（T6 起真跑）。
#
# 解码半依赖 python3（macOS 自带 CLT 有）；截图半只用系统 screencapture。
# 平台：三个子命令都只在 macOS 上有意义（screencapture / CoreGraphics），
# 其它平台明确报错退出，不静默。

set -eu

usage() {
  grep '^#  ' "$0" | sed 's/^#  //'
  exit "${1:-0}"
}

need_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "screenshot-window.sh 只在 macOS 上有意义（screencapture / CoreGraphics），当前宿主：$(uname -s)" >&2
    exit 2
  fi
}

# 解码/枚举半的 python3：裸 python3 在 PATH 上被壳拦截的机器（诊断壳/沙箱）
# 落到系统自带的 /usr/bin/python3——两头都通，不在脚本里做任何安装。
resolve_py() {
  if [[ -n "${PYTHON3:-}" ]]; then
    echo "$PYTHON3"
    return
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c "pass" >/dev/null 2>&1; then
    echo "python3"
  elif [[ -x /usr/bin/python3 ]]; then
    echo "/usr/bin/python3"
  else
    echo "需要 python3（macOS CLT 自带）" >&2
    exit 2
  fi
}

tmp_base() {
  echo "${TMPDIR:-/tmp/}"
}

# list：按 owner 进程枚举窗口 id。python3 ctypes 直调 CoreGraphics 的
# CGWindowListCopyWindowInfo（C 函数，CFArray/CFDictionary 读出来），
# 不依赖任何第三方库。
cmd_list() {
  need_macos
  local pid="${1:?用法: list <pid> [layer]}"
  local layer="${2:-0}"
  local py
  py="$(resolve_py)"
  "$py" - "$pid" "$layer" <<'PY'
import ctypes, ctypes.util, sys

pid, layer = int(sys.argv[1]), int(sys.argv[2])
cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))

cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
cg.CFArrayGetCount.restype = ctypes.c_long
cg.CFArrayGetCount.argtypes = [ctypes.c_void_p]
cg.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
cg.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
cf.CFDictionaryGetValue.restype = ctypes.c_void_p
cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
cf.CFNumberGetValue.restype = ctypes.c_bool
cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFStringGetCString.restype = ctypes.c_bool
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_uint32]
cf.CFNumberGetValue.restype = ctypes.c_bool

kvoid = cf.CFStringCreateWithCString(None, b"kCGWindowNumber", 0x08000100)
kowner = cf.CFStringCreateWithCString(None, b"kCGWindowOwnerPID", 0x08000100)
klayer = cf.CFStringCreateWithCString(None, b"kCGWindowLayer", 0x08000100)
kname = cf.CFStringCreateWithCString(None, b"kCGWindowName", 0x08000100)
kbounds = cf.CFStringCreateWithCString(None, b"kCGWindowBounds", 0x08000100)


def num_of(d, key):
    v = cf.CFDictionaryGetValue(d, key)
    if not v:
        return None
    n = ctypes.c_int64(0)
    cf.CFNumberGetValue(v, 4, ctypes.byref(n))
    return n.value


def str_of(d, key):
    v = cf.CFDictionaryGetValue(d, key)
    if not v:
        return ""
    buf = ctypes.create_string_buffer(256)
    cf.CFStringGetCString(v, buf, 256, 0x08000100)
    return buf.value.decode("utf-8", "replace")


list_ref = cg.CGWindowListCopyWindowInfo(2, 0)  # 2 = all windows（含离屏）
for i in range(cg.CFArrayGetCount(list_ref)):
    d = cg.CFArrayGetValueAtIndex(list_ref, i)
    if num_of(d, kowner) != pid:
        continue
    if layer >= 0 and num_of(d, klayer) != layer:
        continue
    wid = num_of(d, kvoid)
    name = str_of(d, kname)
    bx = by = bw = bh = 0
    b = cf.CFDictionaryGetValue(d, kbounds)
    if b:
        for key, acc in (("X", "bx"), ("Y", "by"), ("Width", "bw"), ("Height", "bh")):
            kv = cf.CFStringCreateWithCString(None, ("kCGWindowBounds" + key).encode(), 0x08000100)
            v = cf.CFDictionaryGetValue(b, kv)
            if v:
                n = ctypes.c_int64(0)
                cf.CFNumberGetValue(v, 4, ctypes.byref(n))
                globals()[acc] = n.value
    print(f"id={wid}  [{bx},{by} {bw}x{bh}]  {name}")
PY
}

# capture：按窗口 id 截图。output 缺省落系统临时目录。
cmd_capture() {
  need_macos
  local wid="${1:?用法: capture <window-id> [output]}"
  local out="${2:-$(tmp_base)moonui-shot-${wid}.png}"
  mkdir -p "$(dirname "$out")"
  # -x 静音（不出快门声）、-l 按窗口 id、-o 不含窗口影子
  screencapture -x -o -l "$wid" "$out"
  echo "$out"
}

# decode：最小 PNG 解码 + 亮度采样。PNG 是 zlib 压缩的 IDAT 流，
# unfilter 五种滤波（None/Sub/Up/Average/Paeth）后按 stride 采样打印。
cmd_decode() {
  need_macos
  local png="${1:?用法: decode <png> [stride]}"
  local stride="${2:-8}"
  local py
  py="$(resolve_py)"
  "$py" - "$png" "$stride" <<'PY'
import struct, sys, zlib

png, stride = sys.argv[1], int(sys.argv[2])
data = open(png, "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n", "不是 PNG"

idat = b""
pos = 8
while pos < len(data):
    length = struct.unpack(">I", data[pos:pos + 4])[0]
    ctype = data[pos + 4:pos + 8]
    body = data[pos + 8:pos + 8 + length]
    if ctype == b"IHDR":
        w, h, depth, color = struct.unpack(">IIBB", body[:10])
        assert depth == 8 and color == 2, f"只支持 8bit RGB，遇到 depth={depth} color={color}"
    elif ctype == b"IDAT":
        idat += body
    pos += 12 + length

raw = zlib.decompress(idat)
bpp = 3  # 8bit RGB
row_len = w * bpp
pixels = bytearray(row_len * h)
prev = bytearray(row_len)
pos = 0
for y in range(h):
    filt = raw[pos]
    pos += 1
    row = bytearray(raw[pos:pos + row_len])
    pos += row_len
    if filt == 1:  # Sub
        for i in range(bpp, row_len):
            row[i] = (row[i] + row[i - bpp]) & 255
    elif filt == 2:  # Up
        for i in range(row_len):
            row[i] = (row[i] + prev[i]) & 255
    elif filt == 3:  # Average
        for i in range(row_len):
            left = row[i - bpp] if i >= bpp else 0
            row[i] = (row[i] + ((left + prev[i]) >> 1)) & 255
    elif filt == 4:  # Paeth
        for i in range(row_len):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            row[i] = (row[i] + pr) & 255
    prev = row
    pixels[y * row_len:(y + 1) * row_len] = row

print(f"W={w} H={h} stride={stride}（亮度 0-255，空格分段）")
for y in range(0, h, stride):
    cells = []
    for x in range(0, w, stride):
        i = (y * w + x) * bpp
        r, g, bl = pixels[i], pixels[i + 1], pixels[i + 2]
        cells.append(str((r * 30 + g * 59 + bl * 11) // 100))
    print(" ".join(cells))
PY
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  capture) shift; cmd_capture "$@" ;;
  decode) shift; cmd_decode "$@" ;;
  *) usage 1 ;;
esac
