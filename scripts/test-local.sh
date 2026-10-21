#!/usr/bin/env bash
# 本地的一条命令门禁：CI 的 core 与 core-portability 两个 job（native 清单 + wasm 清单）
# 加上真后端的类型闸门，按宿主系统分叉。ci.yml 里的 macos-backend-link 自 T6（2026-10-14）
# 起也真跑本平台那批真窗口的测试，但那要推上 remote 才发生；本机想现在跑，用这里。
#
# 为什么需要这个脚本：`moon.pkg` 只按**输出后端**（native / js / wasm）分档，没有
# 宿主系统这一维，而链接参数是分宿主的（macOS 给 clang、Windows 给 MSVC）——它们
# 已经全搬进 prebuild-link.js 按宿主吐 `link_configs`（`T59`），但 native-stub 还在
# moon.pkg 里：`backends/native-windows` 的 adapter_native.c 只能在 Windows 宿主上
# 编过（cl）。于是仓库根的裸 `moon test` 碰到那个包仍然必红。这不是回归，也不是
# "Core 要按平台写 MoonBit 代码"——平台分叉全在 C adapter 与链接配置里：MoonBit 侧
# （`backends/native-common` 的 ffi.mbt + backend.mbt + ABI 头 adapter.h，`T82` 起从
# libui-common 移居）两个平台共用同一份，那个目录里既没有 C 也没有 link。
#
# 包清单不在这里重写：调 scripts/ci-packages.sh，和 CI 两个 job 共用同一份口径。
#
# 用法：bash scripts/test-local.sh
# 脚本自己 cd 到仓库根——链接期的 /LIBPATH 与相对路径都是相对当前工作目录展开的。
# 真窗口那批测试的平台 C 由 prebuild 现编，编不出来时明确红在这里，而不是"跳过然后
# 照样显示全绿"。

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

# `T107` 的依赖方向钉子：`packages/widgets` 只许 import Core，不许碰任何
# `backends/`。一旦某个控件 import 了具体后端，它就只能在那一个后端上活，而这套
# 控件存在的意义恰恰是"一份配方，三个后端都能画"（原生 / 自绘 / mock）。
#
# 为什么用文本检查而不是编译期：moon 的 `moon.pkg` 是唯一的依赖入口（`.mbt` 里
# 引用不到没 import 的包），所以这一行 grep 等价于"依赖图里没有这条边"，而它在
# 三平台上都能跑——换平台不动这条判据。CI 那边暂时没有这一步（推上 remote 才
# 跑），本机的这条负责在提交前咬住。
# 只看 import 行（行首可缩进的双引号路径），不看注释里的字面量——本文件的注释
# 就在讨论这条规则本身，grep 全文件会把"写着 backends/ 的那句解释"判成违规。
if grep -qE '^[[:space:]]*"[^"]*backends/' packages/widgets/moon.pkg 2>/dev/null; then
  echo "packages/widgets/moon.pkg 里出现了 backends/：本包只许 import Core（T107）"
  exit 1
fi

# check 与 info 不带包路径：check 不链接、也不编 C，所以 native only 的包
# （backends/native-common、backends/native-windows、backends/native-macos，
# 加上 examples/gallery-native）在三平台都进得了闸门——这比 CI 的 core job
# 还宽一格。
run moon check --deny-warn

run moon test $core

# §49/§50 的 Demo 跑真事件循环，全在 MockBackend 上，无头
for d in hello counter form todo file-manager gallery; do
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

# Windows 的那份 C 在本机不进任何清单：包清单不链接它，mac 那条路径也不编它
# （prebuild-link.js 只在 Windows 宿主上起 cl.exe）。Homebrew 的 mingw-w64 却
# 能用交叉头文件把它整个读一遍，于是 adapter_native.c 在 mac 上也有一道语法/
# 类型闸门。这道闸门第一次用就抓到 `MF_RADIOCHECK`——MinGW 的头文件里没有这个
# 拼法（只有 `MFT_RADIOCHECK`，同一个值 0x200），cl 那边迟早一样红。没有这个
# 编译器就跳过，不算失败：那台 Windows 机器本来就会真编一遍。这条要求**零警
# 告**（T75 的验收线）。
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *)
    if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
      run x86_64-w64-mingw32-gcc -fsyntax-only -Wall \
        -I"${MOON_HOME:-$HOME/.moon}/include" \
        backends/native-windows/adapter_native.c
    else
      echo "（跳过 adapter_native.c 的本机交叉预编译：没有 x86_64-w64-mingw32-gcc）"
    fi
    ;;
esac

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # 原生 Win32 后端的真窗口测试（§51 的 Backend #2，Windows 半，T75）：平台 C
    # 由 prebuild 在构建前自动现编（编不出来时 moon 那条命令自己就红了，stderr
    # 上有完整的构建日志）。
    run moon test backends/native-windows
    echo "真窗口的测试已过。examples/ 下的真后端画册（gallery-native）不在这里跑："
    echo "它要真人动手、等你关窗口才退出，想验就手动 moon run examples/gallery-native。"
    ;;
  Darwin)
    # 原生 Cocoa 后端的真窗口测试（§51 的 Backend #2，T76 起含对话框/文件面板/
    # 菜单栏/剪贴板）：同一台真窗口，会弹模态面板（脚手架替按）。平台 C 由
    # prebuild 在构建前自动现编。真鼠标交错会让测试假红——跑之前让 owner 停下
    # 操作（见记忆 warn-before-real-window-tests）。
    run moon test backends/native-macos
    echo "真窗口的测试已过。examples/ 下的真后端画册（gallery-native）不在这里跑："
    echo "它要真人点鼠标才退出，想验就手动 moon run examples/gallery-native。"
    ;;
  *)
    echo "真后端这次只到类型闸门：原生后端的 Linux 半还没写，账记在 TODO.md。"
    echo "macOS 那一支已经有了，跑在 Darwin 分支里。"
    ;;
esac

echo "=== 本地门禁通过 ==="
