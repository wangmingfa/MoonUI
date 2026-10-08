#!/usr/bin/env bash
# 编 MoonUI 真后端（§20，§48-03）在 macOS 上需要的 libui-ng 静态库。
# Windows 那条是 scripts/build-libui.ps1，这份是它的 macOS 对偶；两边 pin 同一个提交。
#
# 为什么不用 meson：libui-ng 只有 meson 工程，但 darwin 这条路径上它没有**配置期**
# 依赖——darwin/meson.build:56-62 只要 -lobjc 和 Foundation/AppKit 两个 framework，
# clang 直接就有；上游给 darwin 加的编译参数也只有 meson.build:72-78 那两条
# （-mmacosx-version-min=10.8 与 -arch）。所以这里把那两个文件的源清单直接交给
# clang，再 libtool 打静态包，产物和 meson 那条等价，而本机不用装 meson/ninja。
# （unix 那条真的需要 meson + pkg-config + GTK3，账还在 TODO.md。）
#
# 源清单按 common/meson.build 和 darwin/meson.build 用通配取，唯一排除的是
# OLD_table.c / OLD_table.m：上游两份 meson.build 都没列它们，而且它们编不过
# （引用了 ui.h 里已经不存在的 uiTableColumn）。
#
# 为什么静态：同 build-libui.ps1:8-9——可执行文件自带全部 UI 代码，moon test /
# moon run 不需要再管运行时查找。为什么 release：-O2，不带 libui 的调试断言。
#
# 用法（仓库根或任意目录都行，脚本自己 cd 到根）：
#   bash scripts/build-libui.sh          已有且 pin 匹配就跳过
#   bash scripts/build-libui.sh -f       无视缓存重编

set -eu

Pin='43ba1ef553c8993a43a67f1ce6e35983a2660d8c'
Remote='https://github.com/libui-ng/libui-ng.git'

cd "$(dirname "$0")/.."
TpDir=third-party/libui
SrcDir=$TpDir/src
ObjDir=$TpDir/build-macos
LibDir=$TpDir/lib
StampFile=$LibDir/pinned-commit.txt
HeaderDir=backends/libui-macos

Force=0
[ "${1:-}" = "-f" ] && Force=1

fail() { echo "! $*" >&2; exit 1; }
step() { echo "==> $*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  fail '本脚本只编 macOS（Cocoa）后端；unix 要 meson + pkg-config + GTK3，那条还没写（见 TODO.md）'
fi
command -v clang >/dev/null 2>&1 || fail '找不到 clang（装 Xcode 或 xcode-select --install）'

Arch=$(uname -m)
LibFile=$LibDir/libui.a
if [ $Force -eq 0 ] && [ -f $LibFile ] && [ -f $StampFile ] &&
   [ "$(cat "$StampFile")" = "$Pin" ]; then
  echo "已经是 $Pin 的产物，跳过（-f 可强制重编）"
  echo "lib: $LibFile"
  exit 0
fi

mkdir -p $TpDir $LibDir

# 源码：只取这一个提交，浅 fetch，不留历史。
if [ ! -d $SrcDir/.git ]; then
  step 'git init'
  git init -q $SrcDir
  git -C $SrcDir remote add origin $Remote
fi
step "git fetch $Pin"
git -C $SrcDir fetch --depth 1 origin $Pin -q
step 'git checkout'
git -C $SrcDir checkout -q --detach FETCH_HEAD
Head=$(git -C $SrcDir rev-parse HEAD)
[ "$Head" = "$Pin" ] || fail "检出的提交是 $Head，不是 pin 的 $Pin"

rm -rf $ObjDir
mkdir -p $ObjDir/common $ObjDir/darwin

# 与上游 meson.build 的 darwin 分支逐条对齐；-w 是因为新 SDK 上 libui 的
# Cocoa 代码几乎每个文件都有 deprecation 警告，留着只会把真错误淹掉。
Cflags=(
  -c -O2 -w -std=c99
  -D_UI_STATIC -Dlibui_EXPORTS
  -mmacosx-version-min=10.8 -arch "$Arch"
  -I"$SrcDir" -I"$SrcDir/common" -I"$SrcDir/darwin"
)

compile_one() { # 源文件 → 对象文件；同名不同扩展的 common/*.c 与 darwin/*.m
  local f=$1 d base o               # 必须分目录放，否则 5 对文件互相覆盖
  d=$(basename "$(dirname "$f")")
  base=$(basename "$f")
  o=$ObjDir/$d/${base%.*}.o
  if clang "${Cflags[@]}" "$f" -o "$o" 2>"$ObjDir/$d-$base.log"; then
    :
  else
    echo "FAIL $d/$base" >&2
    head -5 "$ObjDir/$d-$base.log" >&2
  fi
}

{ ls "$SrcDir"/common/*.c; ls "$SrcDir"/darwin/*.m; } | grep -v '/OLD_table\.' >"$ObjDir/sources.txt"
Total=$(wc -l <"$ObjDir/sources.txt" | tr -d ' ')
step "clang 编译 $Total 个源文件（$Arch，并行）"
Built=0
N=0
while read -r f; do
  compile_one "$f" &
  N=$((N + 1))
  if [ $((N % 8)) -eq 0 ]; then wait; fi
done <"$ObjDir/sources.txt"
wait
Built=$(find "$ObjDir/common" "$ObjDir/darwin" -name '*.o' | wc -l | tr -d ' ')
[ "$Built" = "$Total" ] || fail "只编出 $Built/$Total 个对象，看 $ObjDir/*.log"

step 'libtool 打静态库'
mkdir -p $LibDir
xcrun libtool -static -o $LibFile.tmp "$ObjDir"/common/*.o "$ObjDir"/darwin/*.o
mv $LibFile.tmp $LibFile

# adapter_macos.m 包含的是包目录里那两份头（native-stub 只编译同目录的 C 文件），
# 所以每次构建都从 pin 的检出里原样覆盖：git diff 于是一次不漏地暴露 ABI 变化。
# ui_darwin.h 是 libui 的内部声明头，给的是 uiControlHandle 之外拿不到的一切；
# 它没有 uiWindowsControlMinimumSize 的对应物（darwin 走 Auto Layout），
# 所以控件的固有尺寸由 adapter_macos.m 直接问 AppKit（§18）。
step '拷头文件'
mkdir -p $HeaderDir
cp "$SrcDir/ui.h" $HeaderDir/ui.h
cp "$SrcDir/ui_darwin.h" $HeaderDir/ui_darwin.h

printf '%s\n' "$Pin" >$StampFile
Size=$(( $(wc -c <"$LibFile") / 1024 ))
echo "OK: $LibFile（${Size} KB，pin $Pin，$Arch）"
echo "下一步：moon test backends/libui-macos   # 路径相对当前目录，不是模块名"
