#!/usr/bin/env bash
# T233 第三刀的判据：Linux 的编译期分段必须配链接期段回收，且真能摇掉
# 未引用的测试入口（双宿主；手工/本地门禁 + CI 的 linux-backend-link 都跑）。
#
# 背景：compileAdapter 的 Linux 分支早就带了 -ffunction-sections /
# -fdata-sections，注释还写着「对称 mac/win 的 dead-strip」，但 link_flags
# 里一直没开 -Wl,--gc-sections —— GNU ld 默认不丢未引用段，分了等于白分，
# 产品 exe 照样链着 234 个 moonui_native_* 里没人调用的桩。
#
# 两宿主各证一半，别互相冒充：
#   macOS：ld64 的 -Wl,-dead_strip 对**真实 adapter_native_gtk.c 产物**做
#          A/B（等价机制，证「这份产物里确实有可摇掉的测试入口」）。ld64
#          按 atom 回收，不要求 -ffunction-sections，所以这一支不验「分段是
#          前提」，那一格归 GNU ld 半。
#   Linux：真 GNU ld（ELF）对合成库做 4 格 A/B（split/plain × gc/no-gc），
#          证两枚 flag 必须成对：缺链接回收或编译分段，符号都全回来。
#
# 两个宿主都跑一组「仓库接线」静态断言，把上面两层真链接证据钉到
# prebuild-link.js 上；语义负控制是临时摘掉仓库里的 -Wl,--gc-sections，
# 这组断言必须点名红（防「探针绿了，仓库其实没接上」）。
#
# 证据边界：ELF 真链接的**产品 exe 符号差集**要 CI 的 gallery-native 链接
# 给，本机 ld64 与合成探针都证不了「Ubuntu 上 --gc-sections 不破坏 GTK4 /
# MoonBit 运行时」——下一次 CI 首跑才是那条证据。无前置时不静默报绿：
# 本机 SKIP，CI 下 SKIP 一律 FAIL。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYS=""
RUN=""
MOONLIB=""
HOST="${MOONUI_HOST_OS:-$(uname -s)}"
case "$HOST" in
  Darwin|darwin|macos) PLAT=macos ;;
  Linux|linux)          PLAT=linux ;;
  *)
    echo "[gc-sections] 这道闸只服务 macOS / Linux 宿主（当前 ${HOST}）" >&2
    exit 2
    ;;
esac

skip_or_fail() {
  echo "[gc-sections] SKIP：${1}"
  echo "[gc-sections] SKIP ≠ PASS：段回收判据这一次没跑。"
  if [[ -n "${CI:-}" ]]; then
    echo "[gc-sections] CI 环境不允许 SKIP，按 FAIL 处理" >&2
    exit 1
  fi
  exit 0
}

for tool in node cc nm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    skip_or_fail "缺少 ${tool}"
  fi
done

if [[ "$PLAT" == "macos" ]]; then
  SYS="${GTK4_SYSROOT:-/tmp/gtk4-sysroot}"
  RUN="${MOONUI_CAIRO_RUNTIME:-/tmp/moonui-cairo-runtime}"
  MOONLIB="${MOON_RUNTIME_OBJ:-$HOME/.moon/lib/libmoonbitrun.o}"
  if [[ ! -f "$SYS/include/gtk-4.0/gtk/gtk.h" ]]; then
    skip_or_fail "${SYS} 下没有 GTK4 头（先跑 scripts/gtk4-sysroot-fetch.sh）"
  fi
  if [[ ! -d "$RUN" ]]; then
    skip_or_fail "${RUN} 私有运行时不在（canvas-pixel-check.sh 会拼它，把本闸放在那道之后）"
  fi
  if [[ ! -f "$MOONLIB" ]]; then
    skip_or_fail "找不到 ${MOONLIB}（MOON_RUNTIME_OBJ 可覆盖）"
  fi
else
  # Linux 半只用合成探针，不依赖 GTK4；但必须是真 GNU ld（ELF），
  # 不是别的链接器冒充。
  if ! ld --version 2>/dev/null | grep -q 'GNU ld'; then
    skip_or_fail "链接器不是 GNU ld（--gc-sections 是 GNU ld 语义）"
  fi
fi

# 临时目录交给 shell 的 trap 清：Node 里 fs.rmSync 递归删会撞 WorkBuddy
# 注入的 safe-delete 计数（同一轮里 test-local.sh 前面已删掉几十个临时文件），
# 症状是判据跑到末尾突然 rc=1。见 topics/build-gate.md。
WORK="$(mktemp -d "${TMPDIR:-/tmp/}moonui-gc-sections.XXXXXX")" || exit 1
trap 'rm -rf -- "$WORK"' EXIT

node - "$ROOT" "$PLAT" "$RUN" "$MOONLIB" "$WORK" <<'NODE'
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");
const [root, plat, run, moonlib, WORK] = process.argv.slice(2);
let pass = 0, fail = 0;
function ck(name, ok, detail) {
  if (ok) { ++pass; console.log("PASS " + name); }
  else { ++fail; console.log("FAIL " + name + "：" + detail); }
}
function sh(cmd, args, opts) {
  const r = cp.spawnSync(cmd, args, Object.assign({ encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }, opts || {}));
  return { rc: r.status, out: r.stdout || "", err: r.stderr || "" };
}
// nm 的 mach-O 符号带前导下划线，ELF 不带；只收全局代码符号。
function globalSyms(bin) {
  const r = sh("nm", [bin]);
  if (r.rc !== 0) throw new Error("nm 读不出 " + bin + "：" + r.err.slice(0, 300));
  const set = new Set();
  for (const line of r.out.split("\n")) {
    const m = / T _?(moonui_native_\w+)\s*$/.exec(line.trim());
    if (m) set.add(m[1]);
  }
  return set;
}
const KEYS = ["moonui_native_snapshot_all", "moonui_native_menu_click_item",
  "moonui_native_send_key_in_window", "moonui_native_auto_dismiss_dialog"];

// ── ① 仓库接线：三平台「编译分段 / 链接回收」必须成对 ──────────────────
const js = fs.readFileSync(path.join(root, "prebuild-link.js"), "utf8");
const linuxStart = js.indexOf('if (osName === "linux")');
const winStart = js.indexOf('"native-windows", "adapter_native.c"');
const linuxSeg = linuxStart >= 0 && winStart > linuxStart ? js.slice(linuxStart, winStart) : "";
ck("Linux link_flags 拼装里有 -Wl,--gc-sections",
   js.includes('flags = [flags, "-lm", "-Wl,--gc-sections"].filter(Boolean).join(" ")'),
   "仓库链接参数没有开段回收；-ffunction-sections 分了也白分");
ck("Linux compileAdapter 里有 -ffunction-sections / -fdata-sections",
   linuxSeg.includes('"-ffunction-sections"') && linuxSeg.includes('"-fdata-sections"'),
   "Linux 分支切不出来，或两枚编译分段 flag 被摘掉了");
// 只读常量定义，不用全文 includes：注释里也写着这些串，摘掉真正的 flag
// 之后全文搜索照样绿（语义负控制当场抓到过）。
const macFlags = (js.match(/const macosNativeLinkFlags\s*=\s*"([^"]*)"/) || [, ""])[1];
const winFlags = (js.match(/const windowsNativeLinkFlags\s*=\s*"([^"]*)"/) || [, ""])[1];
ck("mac / win 两半的对称开关仍在",
   macFlags.includes("-Wl,-dead_strip") && winFlags.includes("/OPT:REF,NOICF") && js.includes('"/Gy"'),
   "三平台成对的口径被打破，检查谁删了 dead_strip / /OPT:REF / /Gy（注释里的同名文字不算）");

// ── ② 真链接 A/B ───────────────────────────────────────────────────
try {
  if (plat === "macos") {
    // 真实 Linux adapter 产物，不是合成库。driver 只引用 time_ms。
    const drv = path.join(WORK, "drv.c");
    fs.writeFileSync(drv, "extern long long moonui_native_time_ms(void);\n" +
      "int main(void){ return moonui_native_time_ms() > 0 ? 0 : 1; }\n");
    const flagsR = sh("bash", [path.join(root, "scripts/gtk4-flags.sh"), "cflags"], { cwd: root });
    if (flagsR.rc !== 0) throw new Error("gtk4-flags.sh cflags 失败：" + flagsR.err.slice(0, 300));
    const inc = flagsR.out.trim().split("\n").filter(Boolean);
    const ver = ["-DGDK_VERSION_MIN_REQUIRED=GDK_VERSION_4_6",
      "-DGDK_VERSION_MAX_ALLOWED=GDK_VERSION_4_6",
      "-DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_72",
      "-DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_72"];
    const lib = ["-L" + run, "-lgtk-4", "-lgobject-2.0", "-lglib-2.0", "-lcairo",
      "-lpangocairo-1.0", "-lpango-1.0", "-lgdk_pixbuf-2.0", "-lgio-2.0", "-lm"];
    const obj = path.join(WORK, "adapter.o");
    const c = sh("cc", ["-c", "-o", obj,
      path.join(root, "backends/native-linux/adapter_native_gtk.c"),
      "-ffunction-sections", "-fdata-sections", ...inc, ...ver], { cwd: root });
    if (c.rc !== 0) throw new Error("真 adapter 编译失败：" + c.err.slice(0, 500));
    const bins = {};
    for (const [tag, strip] of [["strip", true], ["nostrip", false]]) {
      const bin = path.join(WORK, tag + ".exe");
      const l = sh("cc", ["-o", bin, drv, obj, ...lib, moonlib,
        "-Wl,-undefined,dynamic_lookup", ...(strip ? ["-Wl,-dead_strip"] : [])], { cwd: root });
      if (l.rc !== 0) throw new Error(tag + " 真链接失败：" + l.err.slice(0, 500));
      bins[tag] = globalSyms(bin);
    }
    const no = bins.nostrip, yes = bins.strip;
    console.log("[gc-sections] ld64 真 adapter：不回收 " + no.size +
      " 个全局符号 / 回收后 " + yes.size + " 个");
    ck("不回收时产物完整（≥200 个全局 moonui_native_ 符号）", no.size >= 200,
       "只有 " + no.size + " 个，可能编的不是整份 adapter");
    ck("不回收时四个测试入口全在（判据可观测）", KEYS.every(k => no.has(k)),
       "缺失=" + KEYS.filter(k => !no.has(k)).join(","));
    ck("回收后四个测试入口全部消失", KEYS.every(k => !yes.has(k)),
       "仍保留=" + KEYS.filter(k => yes.has(k)).join(","));
    ck("回收后产品路径 moonui_native_time_ms 仍在", yes.has("moonui_native_time_ms"),
       "被误摇掉了（这是 driver 唯一引用的函数）");
    ck("回收后符号数降到不回收的 1/10 以下", yes.size * 10 < no.size,
       "回收后 " + yes.size + " 个，不回收 " + no.size + " 个；段回收没生效");
  } else {
    // GNU ld（ELF）合成探针：4 格 A/B，证明两枚 flag 必须成对。
    const libsrc = path.join(WORK, "lib.c");
    const drv = path.join(WORK, "drv.c");
    fs.writeFileSync(libsrc, [
      "int moonui_native_init(void){return 1;}",
      ...KEYS.map((k, i) => "int " + k + "(void){return " + (i + 2) + ";}"),
    ].join("\n") + "\n");
    fs.writeFileSync(drv, "int moonui_native_init(void);\n" +
      "int main(void){return moonui_native_init()==1?0:1;}\n");
    const objs = {};
    for (const [tag, split] of [["split", true], ["plain", false]]) {
      const obj = path.join(WORK, tag + ".o");
      const c = sh("cc", ["-c", "-o", obj, libsrc,
        // PE 目标（本机用 mingw 的 GNU ld 干跑 Linux 分支）下 .pdata/.xdata
        // 的 unwind 表让每个 .text$ 段都可达，--gc-sections 一个都摇不掉；
        // ELF 没有这层，加了也无害。为了让同一份探针在两种目标下都可观测，
        // 编译期关掉 unwind 表。CI 的 ubuntu 是真 ELF，这一层用不上。
        "-fno-asynchronous-unwind-tables", "-fno-unwind-tables",
        ...(split ? ["-ffunction-sections", "-fdata-sections"] : [])]);
      if (c.rc !== 0) throw new Error(tag + " 编译失败：" + c.err.slice(0, 400));
      objs[tag] = obj;
    }
    const sets = {};
    for (const [tag, split, gc] of [
      ["split+gc", "split", true], ["split+nogc", "split", false],
      ["plain+gc", "plain", true], ["plain+nogc", "plain", false],
    ]) {
      const bin = path.join(WORK, tag.replace("+", "_") + ".exe");
      const l = sh("cc", ["-o", bin, drv, objs[split],
        ...(gc ? ["-Wl,--gc-sections"] : [])]);
      if (l.rc !== 0) throw new Error(tag + " 链接失败：" + l.err.slice(0, 400));
      sets[tag] = globalSyms(bin);
    }
    for (const [tag, s] of Object.entries(sets)) {
      console.log("[gc-sections] GNU ld " + tag + "：保留 " + [...s].join(","));
    }
    ck("split+gc：只留被引用的 init，四个测试入口全消失",
       sets["split+gc"].has("moonui_native_init") && KEYS.every(k => !sets["split+gc"].has(k)),
       "实际=" + [...sets["split+gc"]].join(","));
    ck("split+nogc：缺链接回收，符号全回来（分了也白分）",
       KEYS.every(k => sets["split+nogc"].has(k)),
       "实际=" + [...sets["split+nogc"]].join(","));
    ck("plain+gc：缺编译分段，符号全回来（--gc-sections 摇不掉整段）",
       KEYS.every(k => sets["plain+gc"].has(k)),
       "实际=" + [...sets["plain+gc"]].join(","));
    ck("plain+nogc：基线四格全在（判据可观测）",
       KEYS.every(k => sets["plain+nogc"].has(k)) && sets["plain+nogc"].has("moonui_native_init"),
       "实际=" + [...sets["plain+nogc"]].join(","));
  }
} catch (e) {
  ck("真链接 A/B 跑完", false, e.message);
}

console.log("[gc-sections] pass=" + pass + " fail=" + fail);
process.exit(fail === 0 ? 0 : 1);
NODE
rc=$?
exit "${rc}"
