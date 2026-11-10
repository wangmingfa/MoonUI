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
# 宿主判定认 MOON_HOST_OS（moon 透传 / 干跑另一条分支），否则 uname -s；认不出来
# 显式红（T234，见下面守卫①）。
# 真窗口那批测试的平台 C 由 prebuild 现编，编不出来时明确红在这里，而不是"跳过然后
# 照样显示全绿"。

set -eu

# `T234` 第四刀 · 守卫②：从脚本自身路径推导仓库根，不依赖调用者 cwd（这样在
# /tmp 下用绝对路径调本脚本也能跑）；缺 moon.mod / adapter.h 时点名退出，别让
# 后面的相对路径静默落空。
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
if [ ! -f "$REPO/moon.mod" ] || [ ! -f "$REPO/backends/native-common/adapter.h" ]; then
  echo "找不到仓库根（T234）：$REPO 下缺 moon.mod 或 backends/native-common/adapter.h。"
  exit 1
fi

# `T234` 第四刀 · 守卫①：宿主判定只有一个口，与仓库根 prebuild-link.js 同口径
# ——MOON_HOST_OS（moon 透传，或人为干跑另一条分支）优先，uname -s 兜底。认不
# 出来就显式红：原来三个 case 都不匹配时脚本会径直走到末尾报"本地门禁通过"，
# 一次都没验过。导出 MOON_HOST_OS 让下游 moon / prebuild 看到同一个判定结果。
case "${MOON_HOST_OS:-}" in
  macos | darwin) HOST_OS=macos ;;
  windows | win32 | MINGW* | MSYS* | CYGWIN* | Windows_NT) HOST_OS=windows ;;
  linux) HOST_OS=linux ;;
  "")
    case "$(uname -s)" in
      Darwin) HOST_OS=macos ;;
      MINGW* | MSYS* | CYGWIN* | Windows_NT) HOST_OS=windows ;;
      Linux) HOST_OS=linux ;;
      *) HOST_OS=unknown ;;
    esac
    ;;
  *) HOST_OS=unknown ;;
esac
if [ "$HOST_OS" = unknown ]; then
  echo "不认识的宿主（T234）：MOON_HOST_OS='${MOON_HOST_OS:-}'，uname -s='$(uname -s)'。"
  echo "  只支持 macos / windows / linux；干跑另一条分支时把 MOON_HOST_OS 设成这三者之一。"
  exit 1
fi
export MOON_HOST_OS="$HOST_OS"
echo "=== 宿主：${HOST_OS}（MOON_HOST_OS='${MOON_HOST_OS}'，uname -s='$(uname -s)'）==="

# 无头那一层 + FFI 探针 + 文档示例，与 CI 的 core job 一致
core=$(bash scripts/ci-packages.sh packages examples tests _doccheck)
# wasm 的口径多带 backends/：§47 第 6 条"Core 里不许出现 GUI 库名字"就靠这条证明
wasm=$(bash scripts/ci-packages.sh packages examples tests backends _doccheck)

run() {
  echo "=== $* ==="
  "$@"
}

# 先清 _build，再让下面每一条结果可信（AGENTS.md / T157）：moon 不把平台 C
# adapter（backends/*/adapter_native.[cm]）算成 native 测试目标的输入，改过 .m
# 之后 `moon test` 会照样执行上次链接好的测试二进制并报绿。负控制实测：同一处
# 破坏性改动，不带 clean 绿、带 clean 红。以前这一步靠人记得先敲，现在收进
# 脚本——本脚本是"全量门禁"，本来就该从头来。
#
# `T234` 第一刀：prebuild-link.js 由 node 执行——PATH 里没有 node 时它根本
# 不会被调起，moon 只在链接期报一堆"缺符号"，真因被盖住。所以前置检查必须
# 放在**任何 moon 命令之前**（包括本脚本开头的 `moon clean`）。
if ! command -v node >/dev/null 2>&1; then
  echo "找不到 node：仓库根 prebuild-link.js 由 node 执行，缺了它 native 构建会在链接期报一堆缺符号（T234）。"
  echo "  请装 Node.js 22（本机与四个 CI job 钉的同一档），或把 node 加进 PATH 后重跑。"
  exit 1
fi
echo "=== node: $(node --version) ==="

# `moon clean` 只删本仓库的 _build，不动 ~/.moon 下的全局缓存；从零跑一遍在
# 8 核 M1 上约 50s。清完由 prebuild-link.js 按宿主现编 C，后面的 test / run
# 会自己把产物补回来。
run moon clean

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
#
# 棘轮判据（T144）：几类"改过又长回来"的写法按文件记一个只降不升的计数。
# 放在 check 之前——它秒级跑完，而 check 要几十秒；顺序上先红的先报。
# 规则与基线都在脚本和 scripts/detlint.baseline 里，由来写在每条规则的注释上。
run bash scripts/detlint.sh

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

# 图标工具（2026-11-09 从 Python/Pillow 全量迁成 Node，零 npm 依赖）：与仓库里
# 现存的 Pillow 产物做**像素级** A/B（主图逐像素一致、ICO 六条逐条打印差异），
# 另验 4x 掩码、白底反解公式与 PNG 编解码往返。放在宿主分叉之前——这一层只读
# 仓库里的二进制资产与 Node，不碰任何平台 API，三平台都该绿。
run node scripts/logo-check.js

# Windows 的那份 C 在本机不进任何清单：包清单不链接它，mac 那条路径也不编它
# （prebuild-link.js 只在 Windows 宿主上起 cl.exe）。Homebrew 的 mingw-w64 却
# 能用交叉头文件把它整个读一遍，于是 adapter_native.c 在 mac 上也有一道语法/
# 类型闸门。这道闸门第一次用就抓到 `MF_RADIOCHECK`——MinGW 的头文件里没有这个
# 拼法（只有 `MFT_RADIOCHECK`，同一个值 0x200），cl 那边迟早一样红。没有这个
# 编译器就跳过，不算失败：那台 Windows 机器本来就会真编一遍。这条要求**零警
# 告**（T75 的验收线）。
#
# 零警告必须靠 `-Werror` 才成立（T204，2026-10-30）：此前只有 `-Wall`，警告
# 照打、rc 照旧 0，于是 `moonui_native_simulate_file_drop` 里 `baadb63` 重构
# 遗留的死变量 `char *blob;` 静默潜伏了两个多月，"零警告"这四个字没人守。
case "$HOST_OS" in
  windows) ;;
  *)
    if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
      run x86_64-w64-mingw32-gcc -fsyntax-only -Wall -Werror \
        -I"${MOON_HOME:-$HOME/.moon}/include" \
        backends/native-windows/adapter_native.c
      # `T189` 的 C 垫片也要过这道闸：它在 Windows 半走 `_wfopen` 一族，
      # 那是本机链接不了的符号，只有 MinGW 的头能证"这批符号真存在、签名对"。
      run x86_64-w64-mingw32-gcc -fsyntax-only -Wall -Werror \
        packages/moonui/fs_utf8.c
    else
      echo "（跳过 adapter_native.c 与 fs_utf8.c 的本机交叉预编译：没有 x86_64-w64-mingw32-gcc）"
    fi
    ;;
esac

# ABI 符号交叉核对（`T145`）：上面那道只证明"语法通得过去"，证明不了"声明的东西
# 真的被这个平台定义了"。三个平台包里 MoonBit 声明只有一份、C 分平台写，两边一
# 脱节就只有真链接才暴露——而 Windows 半的真链接只在这台 Windows 上发生。
#
# 实测坐实这道缺口（2026-10-28，负控制）：把 `moonui_native_window_new` 在
# adapter_native.c 里的**定义**改名，`-fsyntax-only -Wall` rc=0、
# `moon check --target native backends/native-windows` rc=0（它不编 C）、
# `scripts/detlint.sh` rc=0——mac 上一条门禁都不红。`scripts/abi-symbols.sh`
# 对同一次改动立刻吐出那一个名字。
#
# 工具链缺席按跳过处理（与上面 mingw 那道同一套约定：那台真机器会自己编一遍），
# 但跳过会**明说**"一份都没核（不是通过）"——干净的"通过"会被读成两份都核过了。
run bash scripts/abi-symbols.sh

case "$HOST_OS" in
  windows)
    # 原生 Win32 后端的真窗口测试（§51 的 Backend #2，Windows 半，T75）：平台 C
    # 由 prebuild 在构建前自动现编（编不出来时 moon 那条命令自己就红了，stderr
    # 上有完整的构建日志）。
    run moon test backends/native-windows
    echo "真窗口的测试已过。examples/ 下的真后端画册（gallery-native）不在这里跑："
    echo "它要真人动手、等你关窗口才退出，想验就手动 moon run examples/gallery-native。"
    ;;
  macos)
    # 原生 Cocoa 后端的真窗口测试（§51 的 Backend #2，T76 起含对话框/文件面板/
    # 菜单栏/剪贴板）：同一台真窗口，会弹模态面板（脚手架替按）。平台 C 由
    # prebuild 在构建前自动现编。真鼠标交错会让测试假红——跑之前让 owner 停下
    # 操作（见记忆 warn-before-real-window-tests）。
    # GTK4 适配器（T235 P3/P4）四道闸，从弱到强：
    # ① mock 头语法 + ② 纯逻辑判据（键名词表 / pack2 / 修饰键位 / 鼠标钮号，真跑
    #    真断言）——这两道不需要 GTK4；
    # ③ **真 GTK4 头**编译（scripts/gtk4-sysroot-check.sh）。有私有 sysroot 才跑，
    #    没有就打印 SKIP（不是通过）。③ 才是能抓"API 名字写错"的那道：P3 第一跑
    #    就抓出 5 处 GTK3 遗留。
    # ④ **真链接 + 真跑**的像素判据（scripts/canvas-pixel-check.sh，T235 P4）：
    #    把 cairo / pango / gdk-pixbuf 拼成私有可运行运行时，直接链发布的那份
    #    `adapter_native_gtk.c`，对 24 条画布 ABI 逐个摸像素。①②③ 都只能证"自洽"
    #    （mock 头自己写的语义 / 头里名字对得上），证不了"画出来是对的颜色、在对
    #    的位置"——那需要一次真正的光栅化。cairo 在 mac 与 Linux 是同一份软件光栅器，
    #    所以这道闸的结论对两平台都成立（文字度量跨平台不保证一致，判据只验"量得
    #    出、画得上"，见该脚本头注）。
    # 真窗上屏（GtkDrawingArea 的 draw func 真被 GTK 调起）仍只在 Linux 真机
    # （CI linux-backend-link）。
    # 还有第四道：P9 的**外部真实输入**闸（scripts/gtk-xinput-check.sh），
    # 它要 X11 的 XTEST，macOS 上根本跑不了，所以不在这里 run——只在 Linux
    # 分支与 CI 的 linux-backend-link 里接（第五道是 T233 段回收闸，下面会 run）。
    # 别把本机这几道全绿读成它也过了。
    # T233 第三刀的段回收闸（scripts/linux-gc-sections-check.sh）：
    # 编译期分段与链接期回收必须成对；macOS 分支用 ld64 对真实 Linux adapter
    # 产物做 A/B（等价机制），放在 canvas 之后复用它拼好的私有 GTK4 运行时。
    # 放在真窗测试之前：这几道本机可跑的都秒级，先红的先报。
    run bash scripts/mock-gtk-check.sh
    run bash scripts/gtk4-sysroot-check.sh
    run bash scripts/canvas-pixel-check.sh
    run bash scripts/linux-gc-sections-check.sh

    run moon test backends/native-macos
    echo "真窗口的测试已过。examples/ 下的真后端画册（gallery-native）不在这里跑："
    echo "它要真人点鼠标才退出，想验就手动 moon run examples/gallery-native。"
    ;;
  linux)
    # Linux 宿主：P9 的**外部真实输入**闸是唯一非要 XTEST 不可的一层，本地
    # 也能跑（没有 DISPLAY 时脚本自己 xvfb-run 重入）。缺 xdotool / 纯 Wayland
    # 时点名 SKIP，CI 环境下 SKIP 一律按 FAIL 处理。
    run bash scripts/gtk-xinput-check.sh
    # T233 第三刀：段回收闸。真 GNU ld 的 4 格 A/B + 仓库接线静态断言，
    # 不需要显示所以不包 xvfb；CI 下缺件 SKIP 一律 FAIL。
    run bash scripts/linux-gc-sections-check.sh
    echo "GTK4 后端的三道常规闸（mock 389 项 / 真头两档 / canvas 65 条）在 CI 的"
    echo "linux-backend-link job 里逐步跑，本机想全量验就依次跑那三份脚本；"
    echo "账记在 TODO.md T235（P0~P8 已落地、CI 三轮修红已收敛、P9 补外部输入）。"
    ;;
esac

echo "=== 本地门禁通过 ==="
