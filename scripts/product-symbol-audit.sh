#!/usr/bin/env bash
# T233 第四刀的判据：产品 exe 的符号账必须**可重复地**核，不能只在提交信息里留一次
# 手工 `nm` 的读数。
#
# 背景：第一刀（mac `-Wl,-dead_strip`）、第二刀（win `/Gy` + `/OPT:REF,NOICF`）、
# 第三刀（linux `-Wl,--gc-sections`）把三平台的段回收接齐了，但落地注里的证据是
# 「某天在 `/tmp` 手工 nm 了一遍差集」——这类证据会过期：谁哪天顺手删掉一枚 flag、
# 或者把测试脚手架从 static 改成对外可见，静态串断言（第三刀那三条）照样绿，产品
# exe 里测试入口已经悄悄长回来。本脚本把那次手工读数变成每次构建后都能重跑的闸。
#
# 判三类，缺一类都不算验过：
#   ① 产品 exe 里**没有**只服务真窗测试的脚手架入口（名单见 BAN）。
#   ② 产品 exe 里**没有**未定义的 `moonui_*` / `stb_vorbis_*`——段回收把
#      「其实还被引用」的实现摇掉了的话，链接期会先红，但静态库 / 动态查找的
#      路径未必，所以再核一遍。后者自 T233 第五刀起由同一份静态库提供。
#   ③ 审计**不是空转**：名单里的名字必须仍出现在 `adapter.h`（唯一符号表）里，
#      且 exe 里真的有一批 `moonui_native_*`（含 `init`）。改名之后名单静默失效
#      是最容易发生的假绿，这一条当场点名。
#
# 为什么名单只有六个：`clipboard_text` 是**产品 API**（剪贴板读），产品真用得上，
# 它只是因为某个 exe 恰好没引用才在差集里出现；`snapshot_all` 被 lunamusic 壳的
# 离屏取证**真引用**（`shell.mbt`），第一刀判据里也如实记了「保留」。把这两个收
# 进名单就是拿「谁恰好没调用」冒充「谁不该存在」。
#
# 证据边界：本闸核的是**产物符号表**，不是行为。Windows 半的 `dumpbin /SYMBOLS`
# 差集要那台机器（T233「还欠的」①），本脚本在 Windows 宿主上直接点名退出，不冒充。
# 未定义符号在 ELF 上允许动态解析，所以 ② 只对 `moonui_*` 这个前缀收口——它们是
# 自家 adapter 提供的，不该从别处来。
#
# 前置：`nm`（binutils / Xcode CLT 自带）。用法：
#   bash scripts/product-symbol-audit.sh                     # 扫 _build 下所有 *-native/*.exe
#   bash scripts/product-symbol-audit.sh <exe> [<exe> ...]   # 只核指定的
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HDR="$ROOT/backends/native-common/adapter.h"

skip_or_fail() {
  echo "[product-symbol] SKIP：${1}"
  echo "[product-symbol] SKIP ≠ PASS：产品 exe 的符号账这一次没核。"
  if [[ -n "${CI:-}" ]]; then
    echo "[product-symbol] CI 环境不允许 SKIP，按 FAIL 处理" >&2
    exit 1
  fi
  exit 0
}

case "$(uname -s)" in
  Darwin | Linux) ;;
  *)
    # Windows 的符号账走 dumpbin，与 nm 的输出格式不是一回事；别拿 mingw 的 nm
    # 核 PE 冒充 MSVC 的链接结果。
    skip_or_fail "本闸只服务 macOS / Linux（Windows 半用 dumpbin，见 T233 还欠的①）"
    ;;
esac

command -v nm >/dev/null 2>&1 || skip_or_fail "没有 nm"
[[ -f "$HDR" ]] || { echo "[product-symbol] 缺 ${HDR}" >&2; exit 1; }

if [[ $# -gt 0 ]]; then
  EXES=("$@")
else
  EXES=()
  # 只认 examples/ 下的真后端可执行包产物（`*-native` 那批）；别的目录里的
  # exe 不是产品面，不在本条账上。
  shopt -s nullglob
  for f in "$ROOT"/_build/native/*/build/examples/*-native/*.exe; do
    EXES+=("$f")
  done
  shopt -u nullglob
fi

if [[ ${#EXES[@]} -eq 0 ]]; then
  skip_or_fail "没找到产品 exe（先 moon build --target native examples/gallery-native）"
fi

# 只服务真窗测试的入口。加名字前先问一句：产品路径会不会引用它？
#   live_windows / scaffold_window / dismiss_after_ms 是 C 侧 static（不进符号表），
#   不在名单里不是漏了——它们本来就观测不到。
BAN=(
  moonui_native_send_key_in_window
  moonui_native_menu_click_item
  moonui_native_auto_dismiss_dialog
  moonui_native_simulate_file_drop
  moonui_native_drag_hit_probe
  moonui_native_file_drop_probe
)

pass=0
fail=0
ck() {
  if [[ "$2" == "0" ]]; then
    pass=$((pass + 1)); echo "PASS ${1}"
  else
    fail=$((fail + 1)); echo "FAIL ${1}：${3}"
  fi
}

# ── ③ 名单没过期（与产物无关，先跑：它红了后面的结论都是空转）─────────────
for s in "${BAN[@]}"; do
  if grep -qw "${s}" "$HDR"; then
    ck "adapter.h 仍声明 ${s}（名单没失效）" 0 ""
  else
    ck "adapter.h 仍声明 ${s}（名单没失效）" 1 \
      "符号表里找不到它——改名或删掉之后这条禁令会静默空转，请同步名单"
  fi
done

for exe in "${EXES[@]}"; do
  name="$(basename "$exe")"
  echo "[product-symbol] 核 ${name}（${exe#${ROOT}/}）"

  if [[ ! -f "$exe" ]]; then
    ck "${name} 存在" 1 "文件不在"
    continue
  fi

  # `nm -g` 在两个宿主上都只列外部符号，输出形状一致：
  #   <addr> T <name>（mach-O 的名字带前导下划线，ELF 不带；两种都收）
  defined="$(nm -g "$exe" 2>/dev/null | awk '$2=="T"||$2=="D"||$2=="B"||$2=="R"{print $3}' | sed 's/^_//')"
  [[ -n "$defined" ]] || { ck "${name} 的符号表读得出来" 1 "nm 没吐外部定义符号"; continue; }

  total="$(printf '%s\n' "$defined" | grep -c '^moonui_native_')"
  echo "[product-symbol] ${name}：外部定义符号 $(printf '%s\n' "$defined" | wc -l | tr -d ' ') 个，其中 moonui_native_* ${total} 个"
  if grep -qx 'moonui_native_init' <<<"$defined"; then
    ck "${name} 里有 moonui_native_init（审计不是空转）" 0 ""
  else
    ck "${name} 里有 moonui_native_init（审计不是空转）" 1 \
      "连 init 都没有：这个 exe 可能不是真后端产物，或符号表被整体剥掉了"
  fi

  # ── ① 脚手架入口不许在产品 exe 里 ─────────────────────────────────────
  left=""
  for s in "${BAN[@]}"; do
    if grep -qx "$s" <<<"$defined"; then left="$left $s"; fi
  done
  if [[ -z "$left" ]]; then
    ck "${name} 不含真窗测试脚手架入口（${#BAN[@]} 个）" 0 ""
  else
    ck "${name} 不含真窗测试脚手架入口（${#BAN[@]} 个）" 1 \
      "仍链在里面:${left}——段回收没生效（mac 看 -Wl,-dead_strip，linux 看 -Wl,--gc-sections + -ffunction-sections）"
  fi

  # ── ② 没有未定义的 moonui_* / stb_vorbis_* ───────────────────────────
  # `T233` 第五刀：vendored 解码器改成独立 .o 后仍由同一份静态库提供，前缀
  # 一并收进这条；pass 数不变（每个 exe 一条），只是覆盖面扩大。
  undef="$(nm -u "$exe" 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/^_//' | grep -E '^(moonui_|stb_vorbis_)' || true)"
  if [[ -z "$undef" ]]; then
    ck "${name} 没有未定义的 moonui_* / stb_vorbis_*" 0 ""
  else
    ck "${name} 没有未定义的 moonui_* / stb_vorbis_*" 1 \
      "未定义：$(printf '%s' "$undef" | tr '\n' ' ')"
  fi
done

echo "[product-symbol] pass=${pass} fail=${fail}"
[[ $fail -eq 0 ]] || exit 1
