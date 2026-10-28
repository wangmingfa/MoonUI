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
    echo "未知参数：$1（可用 --list RULE / --update / --update=raise）" >&2
    exit 2
    ;;
esac

RULES="kb-unrouted bare-invalidate"

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

rule_scan() {
  case "$1" in
    kb-unrouted) kb_scan ;;
    bare-invalidate) bare_scan ;;
    *)
      echo "未知规则：$1（在场的有：$RULES）" >&2
      exit 2
      ;;
  esac
}

rule_lines() {
  case "$1" in
    kb-unrouted) kb_lines ;;
    bare-invalidate) bare_lines ;;
    *) echo "未知规则：$1（在场的有：$RULES）" >&2; exit 2 ;;
  esac
}

# 例外按文件计数。为什么例外也要计数：例外是"这次先放过"的记账，不是"这条
# finding 不存在"的声明。不计数的话，给每一行都加上标记就等于把规则删了——
# 而删规则正是这套判据要挡的事。
rule_excused() {
  case "$1" in
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
      echo "✗ $r：$f 有 $n 条，基线 $b（多 $((n - b)) 条）"
      moved=1
    fi
  done < "$scan_tmp"

  total=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$scan_tmp")

  if [ "$MODE" = report ]; then
    if [ "$total" -gt "$gate" ]; then
      echo "✗ $r：合计 $total 条，门槛 $gate（多 $((total - gate)) 条）"
      echo "    逐条看：bash scripts/detlint.sh --list $r"
      fail=1
    elif [ "$total" -lt "$gate" ]; then
      echo "✗ $r：合计 $total 条，门槛 $gate —— 少了 $((gate - total)) 条"
      echo "    搬走的东西不能回来，所以基线也要降：bash scripts/detlint.sh --update"
      fail=1
    elif [ "$moved" != 0 ]; then
      echo "    合计没变但换了文件——按文件记账就是为了这个：搬家也算变化。"
      fail=1
    else
      echo "· $r：$total 条（门槛 $gate）"
    fi
  else
    echo "· $r：$total 条（原门槛 $gate）"
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
      echo "✗ $r（例外）：$exc_total 处，门槛 $exc_gate —— 加了例外，但这条 finding 还在"
      echo "    例外要理由，而且只降不升：能改掉就改掉，别拿标记当消失。"
      fail=1
    elif [ "$exc_total" -lt "$exc_gate" ]; then
      echo "✗ $r（例外）：$exc_total 处，门槛 $exc_gate —— 少了，基线也要跟着降"
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
