#!/usr/bin/env bash
# IME 代理不得在焦点期接管进程指针（`T381`）：自绘后端输入框聚焦后，AppKit
# 不能经 IME 代理把指针夺成 I-beam。
#
# 根因（真机日志三轮收敛）：canvas 的 IME 代理是一只 alpha=0 的 NSTextView
# （adapter_native.m 的 MoonuiImeProxy），聚焦时成为 first responder。NSTextView
# 有三条 AppKit 光标入口：
#   ① `resetCursorRects`——按 text container 注册 I-beam 矩形；代理 container
#      是 1e7×1e7，矩形罩住整窗（静态入口）；
#   ② `cursorUpdate:`——鼠标移动时 AppKit 发给 first responder，按 tracking
#      area 现场 `[NSCursor IBeamCursor] set`（动态入口）；
#   ③ `mouseMoved:`——`_routeMouseMovedEvent` 按 first responder 路由，
#      `-[NSTextView mouseMoved:]` 进 `_mouseInside:` 现场 set IBeam
#      （真机栈坐实；`hitTest` 恒 nil 只挡点击穿透，挡不住事件路由）。
# 自绘后端本就在 mouse.mbt 按 hover 命中经 moonui_native_set_cursor 显式设形状，
# 修复是让代理把三条都空覆盖（不调 super）。
#
# 判据形态（行为级，不是源码文本匹配）：从真 adapter 源码里抽出 MoonuiImeProxy
# 的 @interface/@implementation 块原样编进 Objective-C 探针；swizzle 三处系统
# 调用计数：
#   - NSView 的 addCursorRect:cursor: —— 调 resetCursorRects 后的注册次数；
#   - NSCursor 的 set —— 调 cursorUpdate: 后的现场设置次数 + 是否 IBeam；
#   - NSTextView 的 mouseMoved: —— 调 mouseMoved: 后父类被调的次数（空覆盖
#     不调 super 则 0）。
# 修复态三条都必须 0；脚本自带三条负控制（各自只把其中一个方法体换成调
# super，改语义：把那条接管路径加回来），对应计数必须 >=1；任一负控制不红则
# 整道失败。
#
# 为什么 ③ 用「父类被调次数」而不是「NSCursor set 次数」：本机无显示器时
# `-[NSTextView mouseMoved:]` 的 `_mouseInside:` 内部不真正 set（探针实测
# inside=0/set=0），但那不影响判「有没有调 super」——这条判据只数父类入口被
# 进的次数，与显示器无关。
#
# 为什么不进 test-local.sh：swizzle AppKit 系统类且要真起 Cocoa，只在本机
# Xcode/clang 环境成立；与真窗截图同属手工诊断闸，不是 CI 判据。
#
# 负控制实测（2026-11-24）：修复态 ADD/SET/IBEAM/SUPER=0/0/0/0；只放 ① 回来
# ADD=1；只放 ② 回来 SET=1 IBEAM=1；只放 ③ 回来 SUPER=1。探针 A/B/C/D 同一份
# 编译参数，只换对应方法体。

set -eu
cd "$(dirname "$0")/.."

SRC="backends/native-macos/adapter_native.m"
if [ ! -f "$SRC" ]; then
  echo "找不到 $SRC" >&2
  exit 2
fi
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ime-cursor-check.sh 只在 macOS 上成立（需要 Cocoa/AppKit），当前宿主：$(uname -s)" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 按 marker 抽块，不硬编码行号（行号是脆索引）。
awk '
  /^@interface MoonuiImeProxy/ { in_iface=1 }
  in_iface { print; if (/^@end/) in_iface=0; next }
  /^@implementation MoonuiImeProxy/ { in_impl=1 }
  in_impl { print; if (/^@end/) exit }
' "$SRC" > "$tmp/ime_block.m"

if ! grep -q '^@interface MoonuiImeProxy' "$tmp/ime_block.m" || \
   ! grep -q '^@implementation MoonuiImeProxy' "$tmp/ime_block.m" || \
   ! grep -q '^@end' "$tmp/ime_block.m"; then
  echo "没能从 $SRC 抽出完整的 MoonuiImeProxy 块（marker 变了？）" >&2
  cat "$tmp/ime_block.m" >&2
  exit 1
fi
# 三条方法都必须在块里，否则负控制无从构造。
for marker in 'resetCursorRects' 'cursorUpdate:' 'mouseMoved:'; do
  if ! grep -q "$marker" "$tmp/ime_block.m"; then
    echo "抽出的块里缺 $marker，判据失效——请人工核对 $SRC" >&2
    exit 1
  fi
done

# 探针头：swizzle 三处计数 + trackingArea 桩（让 cursorUpdate: 不因合成事件无
# tracking area 而抛异常）。
cat > "$tmp/probe_head.m" <<'EOF'
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <stdio.h>
static int gAdd = 0;
static int gSet = 0;
static int gSuper = 0;
static NSCursor *gLast = nil;
static IMP gOrigMoved = NULL;
static void swAdd(NSView *self, SEL cmd, NSRect r, NSCursor *c) {
  (void)self; (void)cmd; (void)r; (void)c; gAdd++;
}
static void swSet(NSCursor *self, SEL cmd) { (void)cmd; gSet++; gLast = self; }
static NSTrackingArea *swTrack(NSEvent *self, SEL cmd) {
  (void)self; (void)cmd; return nil;
}
static void swMoved(NSTextView *self, SEL cmd, NSEvent *e) {
  gSuper++;
  if (gOrigMoved) ((void (*)(id, SEL, id))gOrigMoved)(self, cmd, e);
}
EOF
cat > "$tmp/probe_main.m" <<'EOF'
int main(void) {
  class_addMethod([NSView class], @selector(swAddRect:cursor:), (IMP)swAdd,
                  "v{_NSRect={_NSPoint=dd}{_NSSize=dd}}@");
  Method oa = class_getInstanceMethod([NSView class], @selector(addCursorRect:cursor:));
  Method ra = class_getInstanceMethod([NSView class], @selector(swAddRect:cursor:));
  method_exchangeImplementations(oa, ra);

  class_addMethod([NSCursor class], @selector(swSetHack), (IMP)swSet, "v@:");
  Method os = class_getInstanceMethod([NSCursor class], @selector(set));
  Method rs = class_getInstanceMethod([NSCursor class], @selector(swSetHack));
  method_exchangeImplementations(os, rs);

  class_addMethod([NSEvent class], @selector(swTrackHack), (IMP)swTrack, "@@:");
  Method ot = class_getInstanceMethod([NSEvent class], @selector(trackingArea));
  Method rt = class_getInstanceMethod([NSEvent class], @selector(swTrackHack));
  method_exchangeImplementations(ot, rt);

  Method mm = class_getInstanceMethod([NSTextView class], @selector(mouseMoved:));
  if (mm != NULL) {
    gOrigMoved = method_getImplementation(mm);
    class_addMethod([NSTextView class], @selector(swMovedHack), (IMP)swMoved, "v@:@");
    Method swm = class_getInstanceMethod([NSTextView class], @selector(swMovedHack));
    if (swm != NULL) method_exchangeImplementations(mm, swm);
  }

  NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,300,200)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  MoonuiImeProxy *p = [[MoonuiImeProxy alloc] initWithFrame:NSMakeRect(0,0,300,200)];
  [[win contentView] addSubview:p];
  [win makeFirstResponder:p];
  CGEventRef cg = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                          CGPointMake(250,50), kCGMouseButtonLeft);
  NSEvent *e = [NSEvent eventWithCGEvent:cg];

  gAdd = 0;
  [p resetCursorRects];
  printf("ADD=%d\n", gAdd);

  gSet = 0; gLast = nil;
  [p cursorUpdate:e];
  printf("SET=%d IBEAM=%d\n", gSet, gLast == [NSCursor IBeamCursor]);

  gSuper = 0;
  @try { [p mouseMoved:e]; }
  @catch (NSException *ex) { printf("MOVED_EXC=%s\n", [[ex reason] UTF8String]); }
  printf("SUPER=%d\n", gSuper);

  CFRelease(cg); [p release]; [win release];
  return 0;
}
EOF

probe() {
  local name="$1"
  cat "$tmp/probe_head.m" "$tmp/ime_block_${name}.m" "$tmp/probe_main.m" > "$tmp/probe_${name}.m"
  if ! cc -x objective-c -framework Cocoa -o "$tmp/probe_${name}" "$tmp/probe_${name}.m" 2>"$tmp/probe_${name}.err"; then
    echo "探针 $name 编译失败：" >&2
    cat "$tmp/probe_${name}.err" >&2
    exit 2
  fi
  "$tmp/probe_${name}"
}

# ① 真源码（修复态）：块原样
cp "$tmp/ime_block.m" "$tmp/ime_block_fixed.m"
fixed_out=$(probe fixed)
echo "修复态：$fixed_out"
add=$(printf '%s\n' "$fixed_out" | sed -n 's/^ADD=//p')
setn=$(printf '%s\n' "$fixed_out" | sed -n 's/^SET=\([0-9]*\).*/\1/p')
ibeam=$(printf '%s\n' "$fixed_out" | sed -n 's/.*IBEAM=\([0-9]*\).*/\1/p')
supern=$(printf '%s\n' "$fixed_out" | sed -n 's/^SUPER=//p')
if [ "$add" != "0" ] || [ "$setn" != "0" ] || [ "$ibeam" != "0" ] || [ "$supern" != "0" ]; then
  echo "修复态仍在接管指针（ADD/SET/IBEAM/SUPER 都应为 0）：$fixed_out" >&2
  exit 1
fi

# ② 负控制 A：只把 resetCursorRects 空体换成 [super resetCursorRects]（静态入口回来）
python3 - "$tmp/ime_block.m" "$tmp/ime_block_broken_reset.m" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = "- (void)resetCursorRects {\n}"
new = "- (void)resetCursorRects {\n  [super resetCursorRects];\n}"
assert s.count(old) == 1, f"resetCursorRects body count={s.count(old)}"
open(sys.argv[2], "w").write(s.replace(old, new))
PY
br_out=$(probe broken_reset)
echo "负控制A（resetCursorRects 调 super）：$br_out"
br_add=$(printf '%s\n' "$br_out" | sed -n 's/^ADD=//p')
if [ "$br_add" = "0" ] || [ -z "$br_add" ]; then
  echo "负控制A没红（调 super 后仍 0 次 addCursorRect）——静态判据不可观测" >&2
  exit 1
fi

# ③ 负控制 B：只把 cursorUpdate: 空体换成 [super cursorUpdate:event]（动态入口回来）
python3 - "$tmp/ime_block.m" "$tmp/ime_block_broken_update.m" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = "- (void)cursorUpdate:(NSEvent *)event {\n  (void)event;\n}"
new = "- (void)cursorUpdate:(NSEvent *)event {\n  [super cursorUpdate:event];\n}"
assert s.count(old) == 1, f"cursorUpdate body count={s.count(old)}"
open(sys.argv[2], "w").write(s.replace(old, new))
PY
bu_out=$(probe broken_update)
echo "负控制B（cursorUpdate: 调 super）：$bu_out"
bu_set=$(printf '%s\n' "$bu_out" | sed -n 's/^SET=\([0-9]*\).*/\1/p')
bu_ibeam=$(printf '%s\n' "$bu_out" | sed -n 's/.*IBEAM=\([0-9]*\).*/\1/p')
if [ "$bu_set" = "0" ] || [ -z "$bu_set" ] || [ "$bu_ibeam" != "1" ]; then
  echo "负控制B没红（调 super 后仍非 IBeam set）——动态判据不可观测" >&2
  exit 1
fi

# ④ 负控制 C：只把 mouseMoved: 空体换成 [super mouseMoved:event]（路由入口回来）
python3 - "$tmp/ime_block.m" "$tmp/ime_block_broken_moved.m" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = "- (void)mouseMoved:(NSEvent *)event {\n  (void)event;\n}"
new = "- (void)mouseMoved:(NSEvent *)event {\n  [super mouseMoved:event];\n}"
assert s.count(old) == 1, f"mouseMoved body count={s.count(old)}"
open(sys.argv[2], "w").write(s.replace(old, new))
PY
bm_out=$(probe broken_moved)
echo "负控制C（mouseMoved: 调 super）：$bm_out"
bm_super=$(printf '%s\n' "$bm_out" | sed -n 's/^SUPER=//p')
if [ "$bm_super" = "0" ] || [ -z "$bm_super" ]; then
  echo "负控制C没红（调 super 后父类仍 0 次）——路由判据不可观测" >&2
  exit 1
fi

echo "=== IME 指针接管判据通过（修复态 ADD/SET/IBEAM/SUPER=0/0/0/0；负控制A ADD=${br_add}；负控制B SET=${bu_set} IBEAM=${bu_ibeam}；负控制C SUPER=${bm_super}）==="
