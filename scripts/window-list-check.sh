#!/usr/bin/env bash
# T242 的判据：窗口枚举的常量与几何读法真的改对了（手工闸，不进 CI）。
#
# 用法：scripts/window-list-check.sh [pid]
#   pid 缺省取 Finder（没有就取 WindowServer）。可以传任意有窗口的进程 pid。
#   MOONUI_WINDOW_LIST_SRC=<path> 可把「新版 helper」换成注入过语义退化的
#   源码，用来跑负控制；old 基线始终由仓库里的 window-list.c 生成。
#
# 两处旧缺陷（TODO `T242`）：① CGWindowListCopyWindowInfo 传的是 2
# （OnScreenAboveWindow，漏离屏窗口）而不是 All；② bounds 键拼成不存在的
# "kCGWindowBoundsX"，CFDictionaryGetValue 恒 NULL，几何恒 [0,0 0x0]。
# 只改源码不算修好——旧版那一格在 A/B 里根本不可观测，所以这里同刻编译
# 三份二进制、交替采样，把「差异」本身变成可点名的判据：
#   new      仓库里的 window-list.c（或 MOONUI_WINDOW_LIST_SRC 指定的源码）
#   old      从仓库源码注入两处旧语义生成的基线（不改仓库文件，可复现）
#   nofilter 把 layer >= 0 改成 layer > 0（layer 过滤的语义负控制）
#
# 采样纪律：窗口集合是活数据（菜单栏窗口会重建），所以 old 跑两次夹住 new，
# 先证 old 自身两次 id 集合一致，否则「红」归因不了实现。
# 三份二进制每次强制重编译、不按 mtime 复用——T242 当初那两条负控制
# 假绿就是跑旧二进制跑出来的。
#
# 为什么不进 CI：这层要真 macOS GUI 会话里**有窗口**，无窗口时本脚本
# exit 2 并点名「不可观测」，绝不 SKIP 冒充 PASS。截图工具同族，头注也
# 写明它是手工诊断工具；真窗批的等价 CI 验证是 native-macos 的真窗测试。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/window-list.c"
NEW_SRC="${MOONUI_WINDOW_LIST_SRC:-$SRC}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[window-list] 只在 macOS 上有意义（CoreGraphics），当前宿主：$(uname -s)" >&2
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  echo "[window-list] 需要 node（分析输出；只用内置模块）" >&2
  exit 2
fi
if [[ ! -f "$SRC" || ! -f "$NEW_SRC" ]]; then
  echo "[window-list] 找不到 helper 源码：$SRC / $NEW_SRC" >&2
  exit 2
fi

PID="${1:-}"
if [[ -z "$PID" ]]; then
  PID="$(pgrep -x Finder | head -1)"
fi
if [[ -z "$PID" ]]; then
  PID="$(pgrep -x WindowServer | head -1)"
fi
if [[ -z "$PID" ]]; then
  echo "[window-list] 找不到有窗口的进程（Finder / WindowServer 都没跑），判据不可观测" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp/}moonui-window-list-check.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

# 生成 old / nofilter 两份源码：改的是语义，不是符号。锚点缺失不在这里
# 悄悄退出——写成一条可点名的判据，免得「实现退回旧语义」只报一句
# 「基线生成失败」就完事（那不是判据红）。
node - "$SRC" "$WORK/old.c" "$WORK/nofilter.c" "$WORK/anchors.json" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const A = "CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID)";
const A2 = "CGWindowListCopyWindowInfo((CGWindowListOption)2, kCGNullWindowID)";
const B = "return CGRectMakeWithDictionaryRepresentation(b, out) ? 1 : 0;";
const B2 = "(void)out; return 0; /* 旧版键名拼错，几何恒 0 */";
const L = "if (layer >= 0) {";
const L2 = "if (layer > 0) {";
const missing = [];
let old = src;
if (src.includes(A)) old = old.replace(A, A2);
else missing.push("option");
if (src.includes(B)) old = old.replace(B, B2);
else missing.push("bounds");
let nofilter = src;
if (src.includes(L)) nofilter = src.replace(L, L2);
else missing.push("layer");
fs.writeFileSync(process.argv[3], old);
fs.writeFileSync(process.argv[4], nofilter);
fs.writeFileSync(process.argv[5], JSON.stringify({ missing }));
NODE
gen_rc=$?
if [[ "$gen_rc" -ne 0 ]]; then
  echo "[window-list] 生成 A/B 基线失败（rc=${gen_rc}）" >&2
  exit 2
fi

CFLAGS=(-O2 -Wall -Wextra -framework CoreGraphics -framework CoreFoundation)
for pair in "new:$NEW_SRC" "old:$WORK/old.c" "nofilter:$WORK/nofilter.c"; do
  tag="${pair%%:*}"
  path="${pair#*:}"
  if ! cc "${CFLAGS[@]}" -o "$WORK/$tag" "$path" > "$WORK/$tag.cc.log" 2>&1; then
    echo "[window-list] 编译 $tag 失败：" >&2
    cat "$WORK/$tag.cc.log" >&2
    exit 2
  fi
  if [[ -s "$WORK/$tag.cc.log" ]]; then
    echo "[window-list] 编译 $tag 有警告（按零警告口径记红）：" >&2
    cat "$WORK/$tag.cc.log" >&2
    exit 1
  fi
done

# 同刻交替采样：old / new / old，再跑一次 layer 负控制。
"$WORK/old" "$PID" 0 > "$WORK/old1.txt"
"$WORK/new" "$PID" 0 > "$WORK/new.txt"
"$WORK/old" "$PID" 0 > "$WORK/old2.txt"
"$WORK/nofilter" "$PID" 0 > "$WORK/nofilter.txt"

node - "$WORK" "$PID" "$NEW_SRC" <<'NODE'
const fs = require("fs");
const [dir, pid, newSrc] = process.argv.slice(2);
const RE = /^id=(\S+)\s+\[(-?[\d.]+),(-?[\d.]+) (-?[\d.]+)x(-?[\d.]+)\]/;
function parse(name) {
  const lines = fs.readFileSync(`${dir}/${name}.txt`, "utf8").split("\n").filter(Boolean);
  const rows = [];
  for (const line of lines) {
    const m = RE.exec(line);
    if (!m) throw new Error(`输出格式不可解析（${name}）：${line}`);
    rows.push({ id: m[1], x: +m[2], y: +m[3], w: +m[4], h: +m[5] });
  }
  return rows;
}
const old1 = parse("old1"), old2 = parse("old2"), neu = parse("new"), nf = parse("nofilter");
const anchors = JSON.parse(fs.readFileSync(`${dir}/anchors.json`, "utf8"));
let pass = 0, fail = 0;
function ck(name, ok, detail) {
  if (ok) { ++pass; console.log(`PASS ${name}`); }
  else { ++fail; console.log(`FAIL ${name}：${detail}`); }
}
const ids = rows => new Set(rows.map(r => r.id));
const subset = (a, b) => [...a].every(id => b.has(id));
const nonzero = rows => rows.filter(r => r.w > 0 && r.h > 0).length;

console.log(`[window-list] pid=${pid}  new=${newSrc}`);
console.log(`[window-list] 读数：old1=${old1.length} 行 / new=${neu.length} 行 / old2=${old2.length} 行 / nofilter=${nf.length} 行；new 几何非 0 有 ${nonzero(neu)} 行`);

ck("仓库 window-list.c 含 T242 修复锚点（All / 官方 bounds / layer 过滤）",
   anchors.missing.length === 0,
   `缺失锚点=${anchors.missing.join(",")}（实现退回旧语义，或源码重构后基线锚点失效）`);
ck("A/B 采样稳定：old 两次 id 集合一致",
   old1.length === old2.length && subset(ids(old1), ids(old2)),
   `old1=${[...ids(old1)].join(",")} old2=${[...ids(old2)].join(",")}（窗口集合是活数据，隔太久会重建）`);
ck("new 至少列出一只窗口", neu.length > 0, `new=${neu.length} 行`);
ck("new 的几何非 0（bounds 读法真生效）", nonzero(neu) > 0,
   `${nonzero(neu)} 行非 0；头三行=${JSON.stringify(neu.slice(0, 3))}`);
ck("old 基线自证：几何恒 0（旧键名取不到值）", nonzero(old1) === 0,
   `old 有 ${nonzero(old1)} 行非 0，基线不是旧行为`);
ck("new 比 old 多列出离屏窗口（option=All 真生效）", neu.length > old1.length,
   `new=${neu.length} 行，old=${old1.length} 行；没有可观测的离屏窗口时这一格不可观测`);
ck("old 的窗口 id 全在 new 里（All ⊇ OnScreenAboveWindow）", subset(ids(old1), ids(neu)),
   `缺失 id=${[...ids(old1)].filter(id => !ids(neu).has(id)).join(",")}`);
ck("layer 过滤负控制可观测：>=0 改 >0 后行数变多", nf.length > neu.length,
   `nofilter=${nf.length} 行，new=${neu.length} 行（layer=0 时不再过滤）`);

console.log(`[window-list] pass=${pass} fail=${fail}`);
process.exit(fail === 0 ? 0 : 1);
NODE
