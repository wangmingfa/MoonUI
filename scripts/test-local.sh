#!/usr/bin/env bash
# 本地的一条命令门禁：CI 的 core 与 core-portability 两个 job（native 清单 + wasm 清单）
# 加上真后端的类型闸门，按宿主系统分叉。ci.yml 里的 macos-backend-link 自 T6（2026-10-14）
# 起也真跑本平台那批真窗口的测试，但那要推上 remote 才发生；本机想现在跑，用这里。
#
# 为什么需要这个脚本：`moon.pkg` 只按**输出后端**（native / js / wasm）分档，没有
# 宿主系统这一维，而链接参数是分宿主的（macOS 给 clang、Windows 给 MSVC）——它们
# 已经全搬进 prebuild-link.js 按宿主吐 `link_configs`（`T59`），但 native-stub 还在
# moon.pkg 里：`backends/libui-windows` 的 adapter.c 与 `backends/libui-macos` 的
# adapter_macos.m 各自只能在自己的宿主上编过。于是仓库根的裸 `moon test` 在
# 非 Windows 宿主上碰到 libui-windows 包仍然必红。这不是回归，也不是"Core 要按
# 平台写 MoonBit 代码"——平台分叉全在 C adapter 与链接配置里：MoonBit 侧
# （`backends/libui-common` 的 ffi.mbt + backend.mbt）两个平台共用同一份，
# 那个目录里既没有 C 也没有 link。
#
# 包清单不在这里重写：调 scripts/ci-packages.sh，和 CI 两个 job 共用同一份口径。
#
# 用法：bash scripts/test-local.sh
# 脚本自己 cd 到仓库根——链接期的 /LIBPATH 与相对路径的 libui.a 都是相对当前工作目录
# 展开的。真窗口那批测试要各平台自己现编的 libui-ng 产物，缺了就明确停在这里，
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

# （2026-10-13 起两排平台壳合并成了单排 `-libui`：同一份 moon.pkg 同一份
# main.mbt，平台分叉整条链路上只剩 prebuild-link.js 里的一个 if，于是原先
# 那道"两排镜像逐字一致"的壳一致性门禁没有对象了，整段删除。）

# check 与 info 不带包路径：check 不链接、也不编 C，所以九个 native only 的包
# （backends/libui-common、backends/libui-windows、backends/libui-macos，
# 加上 examples/ 下那六份 `-libui`）在三平台都进得了闸门——这比 CI 的
# core job 还宽一格。
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

# Win32 那两份 C 在本机不进任何清单：包清单不链接它们，mac 那条路径也不编它们
# （prebuild-link.js 只在 Windows 宿主上起 cl.exe）。Homebrew 的 mingw-w64 却
# 能用交叉头文件把它们整个读一遍，于是 adapter.c 和 adapter_native.c 在 mac 上
# 也有了一道语法/类型闸门。这道闸门第一次用就抓到 `MF_RADIOCHECK`——MinGW 的
# 头文件里没有这个拼法（只有 `MFT_RADIOCHECK`，同一个值 0x200），cl 那边迟早
# 一样红。没有这个编译器就跳过，不算失败：那台 Windows 机器本来就会真编一遍。
# adapter_native.c 那条要求**零警告**（T75 的验收线），adapter.c 那条只拦 error
# ——它自己带着两条已知警告（pragma comment 与 strtoull 那个 set-but-unused），
# 立零警告的线会把旧账翻成红的。
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *)
    if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
      run x86_64-w64-mingw32-gcc -fsyntax-only -Wall \
        -I"${MOON_HOME:-$HOME/.moon}/include" backends/libui-windows/adapter.c
      run x86_64-w64-mingw32-gcc -fsyntax-only -Wall \
        -I"${MOON_HOME:-$HOME/.moon}/include" \
        backends/native-windows/adapter_native.c
    else
      echo "（跳过 adapter.c / adapter_native.c 的本机交叉预编译：没有 x86_64-w64-mingw32-gcc）"
    fi
    ;;
esac

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # libui.a 不再先查在场：prebuild 会在构建前自动现编（脚本自带 pin 缓存），
    # 编不出来时 moon 那条命令自己就红了，stderr 上有完整的构建日志。
    run moon test backends/libui-windows
    # 原生 Win32 后端的真窗口测试（§51 的 Backend #2，Windows 半，T75）：和
    # libui 那份同一批断言，底下换的是直写 Win32 的 adapter_native.c。
    run moon test backends/native-windows
    echo "真窗口的测试已过。examples/ 下那六份 -libui 不在这里跑（hello / counter /"
    echo "form / todo / file-manager / gallery，T50）：它们要真人动手、等你关窗口才退出，"
    echo "想验哪一份就手动 moon run examples/<那份>-libui。"
    ;;
  Darwin)
    # macOS 那份：同一批真窗口的断言，底下换的是 adapter_macos.m（§48-03/09~11/15）。
    # 清单里不含 backends/*，所以这一条是这里显式加跑的，和上面 Windows 那支对称。
    # libui.a 不再先查在场：prebuild 会在构建前自动现编（脚本自带 pin 缓存）。
    run moon test backends/libui-macos
    # 原生 Cocoa 后端的真窗口测试（§51 的 Backend #2，T76 起含对话框/文件面板/
    # 菜单栏/剪贴板）：和 libui 那份同一台真窗口，多弹几只模态面板（脚手架替按）。
    run moon test backends/native-macos
    echo "真窗口的测试已过。examples/ 下那六份 -libui 不在这里跑（hello / counter /"
    echo "form / todo / file-manager / gallery）：它们要真人点鼠标才退出，"
    echo "想验哪一份就手动 moon run examples/<那份>-libui。"
    ;;
  *)
    echo "真后端这次只到类型闸门：libui-ng 的 unix（GTK3）编译路径还没写，"
    echo "账记在 TODO.md。macOS 那一支已经有了，跑在 Darwin 分支里。"
    ;;
esac

echo "=== 本地门禁通过 ==="
