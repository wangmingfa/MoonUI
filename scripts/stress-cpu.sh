#!/usr/bin/env bash
# 受控 CPU 负载：给真窗口测试制造"机器很忙"的环境，退出时保证一个进程都不留。
#
# 为什么需要这个脚本（2026-10-23 补）：2026-10-21 那批复现试验里，负载是这样内联起的：
#
#     for k in 1 2 3 4 5 6; do yes > /dev/null & done
#     moon test backends/native-macos
#     kill %1 %2 %3 %4 %5 %6 2>/dev/null; echo "load off"
#
# 收尾靠**作业号** `%N`，失败信息被 `2>/dev/null` 吞掉，后面还无条件 `echo "load off"`。
# 结果 10-21 21:36 起的 14 个 `yes` 一直活到 10-23 17:09（1 天 19 小时），8 核 M1 被吃到
# 606% CPU、load average 峰值 285（8 核机器正常 < 8），机器持续发烫，父进程全是 1（孤儿）。
#
# 三条脆点，本脚本各自堵死：
#   1) `%N` 只在"当前 shell 的作业表"里有意义。非交互 shell 里、放进循环里、或那条 kill
#      被管道/子 shell 包一层（`kill %1 ... | sed`）时，作业表对不上，bash 只回一句
#      "no such job"——被 2>/dev/null 吞掉，收尾看起来完全成功。
#      → 本脚本一律 kill 具体 PID，不碰作业号。
#   2) 循环里反复起停时作业号会跨轮推移，`kill %1..%4` 常常只杀掉一部分（实测 4 个只死 1 个）。
#      → 每轮用独立 PID 数组，起几个记几个。
#   3) 父 shell 被外部杀掉（agent 超时、Ctrl-C、终端关窗）时，后台子进程不跟着死，会被
#      launchd 收养（ppid=1）继续烧 CPU——这正是上面 14 个孤儿的成因（实测：kill -9 掉
#      起了 3 个 yes 的 shell，3 个 yes 全部带着 ppid=1 活下来）。
#      → trap EXIT / INT / TERM / HUP 兜底，无论从哪条路退出都收干净。
#
# 用法：
#   bash scripts/stress-cpu.sh -- <命令...>        # 负载数默认 = 核数 - 1
#   bash scripts/stress-cpu.sh 4 -- <命令...>      # 指定 4 个
#   bash scripts/stress-cpu.sh --help
#
# 例：
#   bash scripts/stress-cpu.sh -- moon test backends/native-macos
#
# 脚本只负责"有负载 + 收干净"，不判测试结果；目标命令的退出码原样透传。

set -eu

cd "$(dirname "$0")/.."

usage() {
  # 只打印文件开头那一段连续注释，遇到第一行非注释就停。写死行号会随着头部
  # 说明变长而被悄悄截断，把代码也一起打出来（第一版就是这么错的）。
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

case "${1:-}" in
  -h|--help|help) usage 0 ;;
esac

# 注意：函数名不能叫 nproc——那会遮住同名的外部命令，`command -v nproc` 找回来的
# 是函数自己，递归到爆栈（macOS 自带的 bash 3.2 上表现为直接段错误，退出码 139）。
detect_cpus() {
  if command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 4
  else
    echo 4
  fi
}

# 参数：可选的 N，然后 `--`，然后目标命令
n=""
if [ "${1:-}" != "--" ] && [ $# -gt 0 ]; then
  case "$1" in
    ''|*[!0-9]*) echo "stress-cpu: 第一个参数要么是 --，要么是正整数，收到：$1" >&2; exit 2 ;;
    *) n="$1"; shift ;;
  esac
fi
if [ "${1:-}" = "--" ]; then shift; fi
if [ $# -eq 0 ]; then
  echo "stress-cpu: 缺少要跑的命令，用 -- 分隔，例如：bash scripts/stress-cpu.sh -- moon test backends/native-macos" >&2
  exit 2
fi

ncpu=$(detect_cpus)
[ -n "$n" ] || n=$((ncpu > 1 ? ncpu - 1 : 1))

pids=()
# launched 只增不清：cleanup 收工后要把 pids 清空，但收尾复核还得拿得到"当初起了谁"。
# 复核写成"pids 空了所以没问题"就是自欺欺人——判据必须对着不变的账本查。
launched=()

cleanup() {
  local p alive
  # 先 TERM，给它们一点时间自己退
  for p in ${pids+"${pids[@]}"}; do
    kill -TERM "$p" 2>/dev/null || true
  done
  for p in ${pids+"${pids[@]}"}; do
    alive=1
    local i=0
    while [ "$i" -lt 20 ]; do
      if ! kill -0 "$p" 2>/dev/null; then alive=0; break; fi
      sleep 0.05
      i=$((i + 1))
    done
    if [ "$alive" -eq 1 ]; then
      kill -KILL "$p" 2>/dev/null || true
    fi
  done
  pids=()
}

on_signal() {
  # 前台被信号打断时，目标命令还在跑，先收它。
  if [ -n "${target_pid:-}" ]; then
    kill -TERM "$target_pid" 2>/dev/null || true
  fi
  cleanup
  # 被信号打断：128 + 信号号
  exit "$1"
}

# watchdog：唯一能覆盖 `kill -9` 的手段。SIGKILL 无法被捕获，trap 不会执行，
# 那一刻负载就成了孤儿——所以要有一个"父进程没了就自己收摊"的旁路进程。
# 它只轮询、不持有 yes，开销可以忽略。
start_watchdog() {
  local owner=$$ wd_pids="$*"
  (
    # 注意：这里刻意不 trap，跟着父进程一起被 KILL 掉才干净。
    while kill -0 "$owner" 2>/dev/null; do sleep 1; done
    # 父进程已经没了，把当时起的负载全收掉
    for p in $wd_pids; do kill -KILL "$p" 2>/dev/null || true; done
  ) &
  watchdog_pid=$!
}

stop_watchdog() {
  if [ -n "${watchdog_pid:-}" ]; then
    kill -KILL "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=""
  fi
}

trap 'cleanup; stop_watchdog' EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

baseline=$(pgrep -x yes 2>/dev/null | wc -l | tr -d ' ')

k=0
while [ "$k" -lt "$n" ]; do
  yes > /dev/null &
  pids+=("$!")
  launched+=("$!")
  k=$((k + 1))
done

echo "stress-cpu: 起了 $n 个负载（${pids[*]}），基线里已有 $baseline 个 yes" >&2

start_watchdog "${pids[@]}"

# 目标命令必须**后台 + wait**：bash 在前台跑外部命令时会把 trap 推迟到它结束
# 之后才执行，SIGTERM 打进来也不会立刻收尾（这正是 2026-10-21 那批孤儿的一个
# 同源成因）。`wait` 是内建、可被信号打断，trap 才能及时跑起来。
rc=0
"$@" &
target_pid=$!
wait "$target_pid"
rc=$?
target_pid=""

cleanup
stop_watchdog

# 复核：自己起的必须全没了。这里只报"我们起的还在不在"，不去碰基线里本来就有的。
# 对着 launched（只增不清）查，不能对着 pids（cleanup 里已清空）——后者恒为 0 长度，
# 这条判据会永远绿，等于没写。
left=0
for p in ${launched+"${launched[@]}"}; do
  kill -0 "$p" 2>/dev/null && left=$((left + 1))
done
if [ "$left" -ne 0 ]; then
  echo "stress-cpu: 收尾失败，还有 $left 个负载活着" >&2
  exit 1
fi

now_yes=$(pgrep -x yes 2>/dev/null | wc -l | tr -d ' ')
if [ "$now_yes" -gt "$baseline" ]; then
  echo "stress-cpu: 收尾后 yes 数 ${now_yes} 高于基线 ${baseline}，可能有别处泄漏，查一下：" >&2
  pgrep -lx yes >&2 || true
  exit 1
fi

echo "stress-cpu: 负载已收干净（yes 数 ${baseline} → ${now_yes}）" >&2
exit "$rc"
