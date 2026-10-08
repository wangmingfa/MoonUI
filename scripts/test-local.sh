#!/usr/bin/env bash
# 本地的一条命令门禁：CI 的两个 job（native + wasm）加上真后端的类型闸门，按宿主系统分叉。
#
# 为什么需要这个脚本：`moon.pkg` 的 `link` 只按**输出后端**（native / js / wasm）分档，
# 没有宿主系统这一维，而 `backends/libui/moon.pkg` 与 `examples/hello-native/moon.pkg`
# 里的 `/utf-8`、`/W3` 是 MSVC 的写法。macOS / Linux 上 moon 驱动的是 clang，它把
# `/` 开头的参数当文件路径，于是仓库根的裸 `moon test` 在非 Windows 上必然报
#   clang: error: no such file or directory: '/utf-8'
# 这不是回归，也不是"Core 要按平台写 MoonBit 代码"——平台分叉全在 C adapter 与链接配置里
# （`backends/libui/adapter.c` 无条件 include <windows.h>，没有平台 #ifdef）。
#
# 包清单不在这里重写：调 scripts/ci-packages.sh，和 CI 两个 job 共用同一份口径。
#
# 用法：bash scripts/test-local.sh
# 脚本自己 cd 到仓库根——链接期的 /LIBPATH 是相对当前工作目录展开的。
# Windows 上真窗口那批测试需要 scripts/build-libui.ps1 的产物，缺了就明确停在这里，
# 而不是"跳过然后照样显示全绿"。

set -eu

cd "$(dirname "$0")/.."

# 无头那一层 + FFI 探针 + 文档示例，与 CI 的 core job 一致
core=$(bash scripts/ci-packages.sh packages examples tests _doccheck)
# wasm 的口径多带 backends/：§47 第 6 条"Core 里不许出现 GUI 库名字"就靠这条证明
wasm=$(bash scripts/ci-packages.sh packages examples tests backends _doccheck)

run() {
  echo "=== $* ==="
  "$@"
}

echo "=== 宿主：$(uname -s) ==="

# check 与 info 不带包路径：check 不链接，所以 backends/libui 与 examples/hello-native
# 这两个 native only 的包在三平台都进得了闸门——这比 CI 的 core job 还宽一格。
run moon check --deny-warn

run moon test $core

# §49/§50 的五个 Demo 跑真事件循环，全在 MockBackend 上，无头
for d in hello counter form todo file-manager; do
  run moon run "examples/$d"
done

run moon check --target wasm --deny-warn $wasm
run moon test --target wasm $wasm

# CI 这里是 info → fmt --check → git diff --exit-code 三步。本地工作区本来就可能是脏的
# （做了一半的活没提交），裸 git diff --exit-code 会把自己的活误报成漂移，所以这里只比
# `moon info` 唯一会写的那类文件（`.mbti`）在它前后有没有变；格式那一步用 --check，
# 不改人的源码，失败时看到的是 moon 自己给的 file:line。
mbti_before=$(git diff HEAD -- '*.mbti' | cksum)
names_before=$(git diff --name-only HEAD -- '*.mbti')
run moon info
mbti_after=$(git diff HEAD -- '*.mbti' | cksum)
names_after=$(git diff --name-only HEAD -- '*.mbti')
if [ "$mbti_before" != "$mbti_after" ]; then
  # info 会把文件原地改回去，所以事后 diff 里可能一个名字都不剩——列表要合并前后两次
  echo "pkg.generated.mbti 和代码不一致：moon info 刚重写过它们，把下面这些跟着代码一起提交："
  printf '%s\n%s\n' "$names_before" "$names_after" | sort -u | sed '/^$/d'
  exit 1
fi

run moon fmt --check

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if [ -f third-party/libui/lib/libui.a ]; then
      run moon test backends/libui
      echo "真窗口的测试已过。examples/hello-native 不在这里跑：它要真人点鼠标才退出，"
      echo "想验它就手动 moon run examples/hello-native。"
    else
      echo "停在真后端：没有 third-party/libui/lib/libui.a（产物不入库）。"
      echo "先跑 powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-libui.ps1"
      echo "再重跑本脚本——上面那些闸门刚才已经绿过一遍了。"
      exit 1
    fi
    ;;
  *)
    echo "真后端这次只到类型闸门：libui-ng 的 unix / macOS 编译路径还没写，"
    echo "账记在 TODO.md（scripts/build-libui.sh）。"
    ;;
esac

echo "=== 本地门禁通过 ==="
