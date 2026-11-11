#!/usr/bin/env bash
# 棘轮式判据：某些"改过一次又会长回来"的写法，按文件记一个只降不升的计数。
#
# 为什么不用"禁止"而用棘轮：这几条规则今天都还差几格才归零（或者在几处结构性
# 地需要例外），一刀切禁死会逼着提交先大改一遍，而大改正是这类判据最容易被顺手
# 关掉的场合。棘轮的办法是：**多一条就红，少一条也要在同一个提交里把基线降下
# 来**（`--update`）——"迁移搬走的东西回不来"，而当前欠账不必一次还清。
#
#     bash scripts/detlint.sh                        报告；任何文件高于基线就失败
#     bash scripts/detlint.sh --list RULE            逐条印出某条规则的 file:line
#     bash scripts/detlint.sh --update               当前数记成新基线（只降不升）
#     bash scripts/detlint.sh --update=raise         允许升（拆文件/改名时用，提交说明）
#
# 计数按**文件**记，不记行号：行号一改（上面插几行注释）就整片错位，而这类误报
# 会让人去关判据。按文件记也顺带管住搬家——把一条从 A 挪到 B，两个文件都越线。
#
# 基线在 scripts/detlint.baseline，格式 `rule<TAB>file<TAB>count`。规则到 0 之后
# 仍然留一条 `rule<TAB>*<TAB>0`：这样"从 0 涨到 1"照样红。一条被**删掉**的规则
# 和一条**归零**的规则完全是两回事——前者是判据没了，后者是判据赢了。
#
# 例外写在行上：`# det-ok(规则名): 理由`，理由必填。例外自己也计数（按行数），
# 同样只降不升：把一条 finding 标成例外不等于它消失。
#
# 每条规则的注释里都写着它挡的是哪一次真事故——判据本身看不出主次，读的人得
# 知道这条红过没有、红的时候坏的是什么。
#
# 为什么规则都写成"按文件"而不是"按行号"：本仓库的 `.mbt` 文件动辄几千行，一条
# 按行记的判据每插一行注释就整片错位；按文件记的判据只关心"这个文件里还剩几条"，
# 而棘轮真正要挡的是"新写一条进来"。

set -eu

cd "$(dirname "$0")/.."

BASELINE=scripts/detlint.baseline
MODE=report
RULE=
case "${1:-}" in
  --list)
    MODE=list
    RULE=${2:?--list 需要规则名}
    ;;
  --update) MODE=update ;;
  --update=raise) MODE=update_raise ;;
  "") ;;
  *)
    echo "未知参数：${1}（可用 --list RULE / --update / --update=raise）" >&2
    exit 2
    ;;
esac

RULES="backend-platform-capability core-platform-leak core-audio-leak kb-unrouted bare-invalidate shell-native-leak"

# ---------------------------------------------------------------------------
# 规则定义。每条给出三个函数体：scan（按文件计数）、lines（逐条列）、why（说明）。
# ---------------------------------------------------------------------------

# kb-unrouted —— 碰到打包编码 `kind*8+button` 的文件必须经 `@native-abi` 走。
#
# 由来（`T144`）：`T143` 把这张判定表收进 `backends/native-abi` 之后，
# `backends/canvas-macos/mouse.mbt` 还留着一份自己的拆法。两份一旦分叉，同一串
# 整数在两个后端上变成不同的事件——而那种错只有真鼠标才看得见（`T141` 的事件
# 族就是这样漏出去的）。
#
# 判据形状：**凡引用 `native_mouse_kind_button(` 的文件，必须也引用
# `@native-abi.`**，否则这个文件里有第二份读法。不扫算术式——`i / 8`、`x % 8`
# 在颜色打包、位图分块里到处都是，按算式扫只会刷出一片误报，而误报是判据被关掉
# 的第一步。
kb_scan() {
  grep -rlF --include='*.mbt' 'native_mouse_kind_button(' packages backends examples 2>/dev/null \
    | grep -v '^backends/native-abi/' \
    | while IFS= read -r f; do
        if ! grep -qF '@native-abi.' "$f"; then
          printf '%s\t1\n' "$f"
        fi
      done
}

kb_lines() {
  kb_scan | while IFS='	' read -r f _; do
    grep -nF 'native_mouse_kind_button(' "$f" | cut -d: -f1 | while read -r n; do
      printf '%s:%s:%s\n' "$f" "$n" "$(sed -n "${n}p" "$f")"
    done
  done
}

# bare-invalidate —— Windows 适配器里绕过 `moonui_native_invalidate` 直接调
# `InvalidateRect`。
#
# 由来（`T140`）：底重画时没把压在它上面的无底标签拖进更新区，于是只有底落笔、
# 字被新底整块盖掉，而且此后不会自愈。产品路径所有失效必须走包装。
#
# 包装函数自己那两处是结构性必需的（一处是包装的底座，一处是它把标签拖进来），
# 行上或**上一行**写 `det-ok(bare-invalidate): 理由` 豁免。上一行也认是照
# still.fail 的 detlint 约定：C 里的说明性注释通常写在那一行上面而不是挤在行尾。
bare_hits() {
  grep -rlF --include='*.c' 'InvalidateRect(' backends/native-windows 2>/dev/null \
    | while IFS= read -r f; do
        awk -v F="$f" '
          /det-ok\(bare-invalidate\)[[:space:]]*:/ { prev_ok = 1; next }
          {
            if ($0 ~ /InvalidateRect[[:space:]]*\(/ && $0 !~ /moonui_native_invalidate/ && !prev_ok) {
              printf "%s:%d:%s\n", F, NR, $0
            }
            prev_ok = 0
          }
        ' "$f"
      done
}

bare_scan() {
  bare_hits | cut -d: -f1 | sort | uniq -c | awk '{print $2 "\t" $1}'
}

bare_lines() { bare_hits || true; }

# backend-platform-capability —— `Backend` trait 里**不许再有**"平台能力/媒体
# 服务"方法。基线 0：这 6 条已住在独立的 `PlatformServices` trait
# （`T231` 2026-11-08 起；`T239` 之后搬到 packages/platform-services）。
#
# 由来（架构评审 2026-11-07）：DESIGN §19 原本只列 10 个概念方法，落地成了 93 个。
# 最后六个（set_tray_icon / set_tray_menu / notify / on_media_key /
# set_global_hotkeys / set_now_playing）是 lunamusic 的应用需求推进来的，与窗口、
# 控件、绘制、事件这些 GUI 后端职责无关。代价不在"接口多六行"，而在**每个新后端
# 都得实现**——第三个真后端（Linux/GTK）要照抄整张表。`T231` 把它们拆出去之后
# `Backend` 缩到 87 个，本规则也从"棘轮钉住 6 条"变成"禁止再进 Backend"。
#
# 判据形状：只扫 packages/moonui/backend.mbt 的 trait 体（不扫 impl、不扫注释），
# 命中平台服务词根的方法名按文件计数。词根**有意留宽**（audio / media / hotkey /
# tray / notify / now_playing / battery / bluetooth / sleep），好让换个名字的同类
# 能力也撞上；真有正当理由要加，行上写 `det-ok(backend-platform-capability): 理由`，
# 并同步把理由记进 TODO.md。新平台能力应当去 `PlatformServices`，那里不受本规则
# 扫描——这是**有意的**：扫描范围窄正是"Backend 只管 GUI"这条边界。归属那一半
# （不许这些语义出现在 Core 包里）另由 `core-platform-leak` 钉着。
#
# 边界：音频播放本身是应用层 `AudioEngine`（examples/lunamusic/engine.mbt）直连
# `@native-common.native_audio_*`（shell.mbt），不经过框架任何 trait——这条规则
# 不管那条路，只钉 `Backend` 这一侧。详见 API.md §18 与 TODO.md `T237`。
cap_hits() {
  awk '
    /^pub\(open\) trait Backend[[:space:]]*\{/ { in_trait = 1; next }
    in_trait && /^\}/ { in_trait = 0; next }
    in_trait && /^[[:space:]]*fn[[:space:]]+[a-zA-Z0-9_]+/ {
      name = $0
      sub(/^[[:space:]]*fn[[:space:]]+/, "", name)
      sub(/[^a-zA-Z0-9_].*$/, "", name)
      if (name ~ /(tray|notify|notification|media|hotkey|now_playing|audio|battery|bluetooth|sleep)/) {
        printf "packages/moonui/backend.mbt:%d:%s\n", NR, name
      }
    }
  ' packages/moonui/backend.mbt
}

cap_scan() {
  cap_hits | cut -d: -f1 | sort | uniq -c | awk '{print $2 "\t" $1}'
}

cap_lines() { cap_hits || true; }

# core-platform-leak —— `packages/moonui` 里**不许再有**应用专属平台能力的语义。
#
# 由来（`T239` 2026-11-08）：`T231` 把 6 个 lunamusic 能力从 `Backend` 拆成
# `PlatformServices`，只解了「实现义务」没解「归属」——trait、MockBackend 的
# impl、App 的三条转发连同 `tray_icon` / `now_playing_log` 这类公开读数方法
# 仍住在框架包里，通用 GUI 框架的 `.mbti` 上躺着音乐播放器语义。`T239` 把它们
# 整体迁到 `packages/platform-services`，本规则负责钉住「不回来」。
#
# 判据形状：只扫 `packages/moonui/*.mbt` 的**非注释行**，命中下面那组能力名
# 词根就按文件计数。跳过注释是必要的：`backend.mbt` 的 trait 尾注要说明能力
# 住在哪个包，会提到 `PlatformServices`；那是文档，不是代码。词根刻意不含裸
# `notify`——`demo_dx.mbt` 的「启用通知」复选框叫 `set_notify` / `notify_checked`，
# 那是通用 UI 控件，不是系统通知能力；Backend trait 体里的 `notify` 由
# `backend-platform-capability` 那条管。
#
# 与 `backend-platform-capability` 的分工：那条只扫 Backend trait 体（防能力
# 回到实现义务里），这条扫整个 Core 包（防能力回到归属里）。两条基线都是 0。
leak_hits() {
  for f in packages/moonui/*.mbt; do
    awk -v F="$f" '
      /^[[:space:]]*\/\// { next }
      /PlatformServices|set_tray_icon|set_tray_menu|set_now_playing|on_media_key|set_global_hotkeys|tray_icon|tray_menu|tray_install|notify_log|now_playing|media_key_cb|hotkey_cb/ {
        printf "%s:%d:%s\n", F, NR, $0
      }
    ' "$f"
  done
}

leak_scan() {
  leak_hits | cut -d: -f1 | sort | uniq -c | awk '{print $2 "\t" $1}'
}

leak_lines() { leak_hits || true; }


# core-audio-leak —— `packages/moonui` 里**不许出现**应用音频引擎的语义。
#
# 由来（`T237` 2026-11-08）：`T231` 把 6 个平台能力从 `Backend` 拆出去、
# `T239` 把它们连同实现整体迁出 Core，音频那半却一直没定口径。取证发现
# 「换第三后端会失联」不是音频独有：`examples/lunamusic-shell` 除 27 处
# `@native-common.native_audio_*` 外还直连 7 处非音频 FFI（walk_dir /
# time_ms / worker_run / snapshot_all），`packages/moonui-app` 也 import
# `native-common`。owner 裁决 **③ 承认边界**：音频是**应用自带能力**，不在
# 框架承诺范围，由 `T235` 自担；`T239` 定的「Core 公开面不放应用专属语义」
# 继续成立，本规则负责把它钉成可执行的门禁，而不是只写一段说明。
#
# 判据形状：只扫 `packages/moonui/*.mbt` 的**非注释行**。跳过注释是必要的：
# 将来 Core 的段注可能要说明「音频住在应用层」，那是文档不是代码。词根只取
# 应用音频专属名字（`AudioEngine` / `AudioError` / `native_audio_*` 及其
# 调用面），**不含** `level` / `rate` / `duration` 这类通用词，避免误伤。
# 与 `core-platform-leak` 的分工：那条挡 6 个平台能力回灌，这条挡音频上移；
# 两条基线都是 0。真要改变裁决（把音频上移成框架 capability），得先跑
# `--update` 之外的讨论并在 TODO 里立新条目，不能靠加 `det-ok` 悄悄放行。
audio_leak_hits() {
  for f in packages/moonui/*.mbt; do
    awk -v F="$f" '
      /^[[:space:]]*\/\// { next }
      /AudioEngine|AudioError|native_audio_|set_track_gain|eq_apply|eq_band_count|prime_next|on_primed_start|output_devices|set_output_device|audio_load_error|audio_play_error/ {
        printf "%s:%d:%s\n", F, NR, $0
      }
    ' "$f"
  done
}

audio_leak_scan() {
  audio_leak_hits | cut -d: -f1 | sort | uniq -c | awk '{print $2 "\t" $1}'
}

audio_leak_lines() { audio_leak_hits || true; }

# shell-native-leak —— 共享装配壳 `examples/lunamusic-shell` 不许再直连
# `@native-common`。
#
# 由来（`T253` 2026-11-11）：`T235` 的剩余账是「应用装配层整包直连
# `@native-common`」——`shell.mbt` 33 处（音频 28 + walk_dir / time_ms×2 /
# worker_run×2 / snapshot_all）、`online_lyrics.mbt` 2 处（worker_run），
# `bench_wbtest.mbt` 借 `native_time_ms` 计时。换第三个后端时失联的是整只
# 共享壳，不只是音频。`T253` 把音频与宿主能力下沉到 `examples/lunamusic-host`，
# 壳只收 `@lunamusic.AppHost[B]` 与一只 `AudioEngine` 参数；本规则钉住「不回来」。
#
# 判据形状：`*.mbt` 的**非注释行**里出现 `@native-common`、`moon.pkg` 的
# **非注释行**里出现 `native-common`（import 串是包路径，不带 `@`），按文件
# 计数。跳过注释是必要的：壳的头注要交代这段历史。基线 0。
shell_leak_hits() {
  for f in examples/lunamusic-shell/*.mbt; do
    awk -v F="$f" '
      /^[[:space:]]*\/\// { next }
      /@native-common/ { printf "%s:%d:%s\n", F, NR, $0 }
    ' "$f"
  done
  awk '
    /^[[:space:]]*\/\// { next }
    /native-common/ { printf "%s:%d:%s\n", "examples/lunamusic-shell/moon.pkg", NR, $0 }
  ' examples/lunamusic-shell/moon.pkg
}

shell_leak_scan() {
  shell_leak_hits | cut -d: -f1 | sort | uniq -c | awk '{print $2 "\t" $1}'
}

shell_leak_lines() { shell_leak_hits || true; }

rule_scan() {
  case "$1" in
    backend-platform-capability) cap_scan ;;
    core-platform-leak) leak_scan ;;
    core-audio-leak) audio_leak_scan ;;
    kb-unrouted) kb_scan ;;
    bare-invalidate) bare_scan ;;
    shell-native-leak) shell_leak_scan ;;
    *)
      echo "未知规则：${1}（在场的有：${RULES}）" >&2
      exit 2
      ;;
  esac
}

rule_lines() {
  case "$1" in
    backend-platform-capability) cap_lines ;;
    core-platform-leak) leak_lines ;;
    core-audio-leak) audio_leak_lines ;;
    kb-unrouted) kb_lines ;;
    bare-invalidate) bare_lines ;;
    shell-native-leak) shell_leak_lines ;;
    *) echo "未知规则：${1}（在场的有：${RULES}）" >&2; exit 2 ;;
  esac
}

# 例外按文件计数。为什么例外也要计数：例外是"这次先放过"的记账，不是"这条
# finding 不存在"的声明。不计数的话，给每一行都加上标记就等于把规则删了——
# 而删规则正是这套判据要挡的事。
rule_excused() {
  case "$1" in
    backend-platform-capability)
      grep -cF 'det-ok(backend-platform-capability)' packages/moonui/backend.mbt 2>/dev/null \
        | awk '$1 > 0 { print "packages/moonui/backend.mbt" "\t" $1 }'
      ;;
    core-platform-leak)
      grep -rlF --include='*.mbt' 'det-ok(core-platform-leak)' packages/moonui 2>/dev/null \
        | while IFS= read -r f; do
            n=$(grep -cF 'det-ok(core-platform-leak)' "$f")
            printf '%s\t%s\n' "$f" "$n"
          done
      ;;
    core-audio-leak)
      grep -rlF --include='*.mbt' 'det-ok(core-audio-leak)' packages/moonui 2>/dev/null \
        | while IFS= read -r f; do
            n=$(grep -cF 'det-ok(core-audio-leak)' "$f")
            printf '%s\t%s\n' "$f" "$n"
          done
      ;;
    kb-unrouted)
      grep -rIlF --include='*.mbt' 'det-ok(kb-unrouted)' packages backends examples 2>/dev/null \
        | while IFS= read -r f; do
            n=$(grep -cF 'det-ok(kb-unrouted)' "$f")
            printf '%s\t%s\n' "$f" "$n"
          done
      ;;
    bare-invalidate)
      grep -rI --include='*.c' -F 'det-ok(bare-invalidate)' backends/native-windows 2>/dev/null \
        | cut -d: -f1 | sort | uniq -c | awk '{print $2 "\t" $1}'
      ;;
    shell-native-leak) ;; # 没有例外口：壳解耦是整包口径，逐行放行等于把规则删了
  esac
}

# ---------------------------------------------------------------------------
# 基线读写
# ---------------------------------------------------------------------------

# 某文件在基线里的门槛；没有这一条时按 0 算（新文件从零开始）。
baseline_for_file() {
  awk -F'\t' -v R="$1" -v F="$2" \
    '$1 == R && $2 == F { print $3; found = 1 } END { if (!found) print 0 }' \
    "$BASELINE" 2>/dev/null || echo 0
}

# 某规则的总门槛；`-1` = 基线里根本没有这条规则（判据被删了）。
baseline_total() {
  awk -F'\t' -v R="$1" \
    '$1 == R && $2 == "*" { print $3; found = 1 } END { if (!found) print -1 }' \
    "$BASELINE" 2>/dev/null || echo -1
}

if [ "$MODE" = list ]; then
  rule_lines "$RULE"
  exit 0
fi

scan_tmp=$(mktemp)
exc_tmp=$(mktemp)
base_tmp=$(mktemp)
trap 'rm -f "$scan_tmp" "$exc_tmp" "$base_tmp"' EXIT
: > "$base_tmp"

fail=0

for r in $RULES; do
  rule_scan "$r" > "$scan_tmp"
  gate=$(baseline_total "$r")

  if [ "$gate" = "-1" ]; then
    echo "✗ 基线里没有规则 \`$r\`——判据被删过？跑 --update 会按当前数写进去。" >&2
    fail=1
    gate=0
  fi

  moved=0
  while IFS='	' read -r f n; do
    [ -n "$f" ] || continue
    b=$(baseline_for_file "$r" "$f")
    if [ "$n" -gt "$b" ]; then
      echo "✗ ${r}：$f 有 $n 条，基线 ${b}（多 $((n - b)) 条）"
      moved=1
    fi
  done < "$scan_tmp"

  total=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$scan_tmp")

  if [ "$MODE" = report ]; then
    if [ "$total" -gt "$gate" ]; then
      echo "✗ ${r}：合计 $total 条，门槛 ${gate}（多 $((total - gate)) 条）"
      echo "    逐条看：bash scripts/detlint.sh --list $r"
      fail=1
    elif [ "$total" -lt "$gate" ]; then
      echo "✗ ${r}：合计 $total 条，门槛 $gate —— 少了 $((gate - total)) 条"
      echo "    搬走的东西不能回来，所以基线也要降：bash scripts/detlint.sh --update"
      fail=1
    elif [ "$moved" != 0 ]; then
      echo "    合计没变但换了文件——按文件记账就是为了这个：搬家也算变化。"
      fail=1
    else
      echo "· ${r}：$total 条（门槛 ${gate}）"
    fi
  else
    echo "· ${r}：$total 条（原门槛 ${gate}）"
  fi

  while IFS='	' read -r f n; do
    [ -n "$f" ] || continue
    printf '%s\t%s\t%s\n' "$r" "$f" "$n" >> "$base_tmp"
  done < "$scan_tmp"
  printf '%s\t*\t%s\n' "$r" "$total" >> "$base_tmp"

  # ---- 例外账：与 findings 分开记，各自只降不升 ----
  rule_excused "$r" > "$exc_tmp"
  exc_gate=$(awk -F'\t' -v R="$r!excused" '$1 == R && $2 == "*" { print $3; found = 1 } END { if (!found) print -1 }' "$BASELINE" 2>/dev/null || echo -1)
  [ "$exc_gate" = "-1" ] && exc_gate=0
  exc_total=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$exc_tmp")
  if [ "$MODE" = report ]; then
    if [ "$exc_total" -gt "$exc_gate" ]; then
      echo "✗ ${r}（例外）：$exc_total 处，门槛 $exc_gate —— 加了例外，但这条 finding 还在"
      echo "    例外要理由，而且只降不升：能改掉就改掉，别拿标记当消失。"
      fail=1
    elif [ "$exc_total" -lt "$exc_gate" ]; then
      echo "✗ ${r}（例外）：$exc_total 处，门槛 $exc_gate —— 少了，基线也要跟着降"
      fail=1
    fi
  fi
  while IFS='	' read -r f n; do
    [ -n "$f" ] || continue
    printf '%s\t%s\t%s\n' "$r!excused" "$f" "$n" >> "$base_tmp"
  done < "$exc_tmp"
  printf '%s\t%s\t%s\n' "$r!excused" '*' "$exc_total" >> "$base_tmp"
done

if [ "$MODE" = update ] || [ "$MODE" = update_raise ]; then
  {
    echo "# 棘轮基线（scripts/detlint.sh --update 生成，别手改）。"
    echo "# 格式：rule<TAB>file<TAB>count；file 为 * 的那一行是这条规则的总门槛。"
    echo "# 规则到 0 之后仍然留一条 * 0：判据赢了不等于判据可以删。"
    cat "$base_tmp"
  } | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 > "$BASELINE"
  echo "基线已更新：$BASELINE"
  exit 0
fi

if [ "$fail" != 0 ]; then
  echo
  echo "棘轮只降不升。确实要留：行上写 \`# det-ok(规则名): 理由\`；"
  echo "搬家/改名导致基线变化：bash scripts/detlint.sh --update 并把基线文件一起提交。"
  exit 1
fi
echo "=== 棘轮判据通过 ==="
