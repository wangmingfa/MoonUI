/* MoonUI 的原生 Cocoa 后端（设计文档 §51 的 Backend #2，macOS 半）。
 *
 * 和 ../libui-macos/adapter_macos.m 导出同一套 moonui_native_* 符号，但**不经过
 * libui-ng**：窗口、事件循环、回调全部直写 AppKit。这是"libui-ng 只是第一个
 * Backend"（§51）的正面落地——MoonBit 侧只认这套 moonui_native_* 名字，换后端不动
 * Core。本文件只实现 FP1 需要的窗口 + 事件循环那一半；控件（Button/Label/…）
 * 在 FP2 补，补之前 MoonBit 侧对应的方法 raise Unsupported。
 *
 * 和 libui 那份的分叉，逐条列在这里：
 *   - 原生对象就是 NSWindow 本身，句柄直接是它的指针（libui 那份要经
 *     uiControlHandle 从 uiWindow 结构体里把 NSWindow 抠出来）。
 *   - 生命周期自己管：libui 那份的 NSWindow 由 libui 持有，本文件只借指针；
 *     这里 NSWindow 归本文件所有，用一张强引用表（moonui_native_live_windows）在 ARC
 *     下把它钉住，销毁时摘掉、让它自己 dealloc。
 *   - 事件循环自己泵：libui 的 uiMainStep 背后是 [NSApp nextEventMatchingMask:
 *     …] + sendEvent:，本文件把这两步直接写出来，不经过 libui 的 isRunning 标志。
 *   - 回调走 NSWindow 子类：closing 覆写 windowShouldClose:（固定返回 NO 否决，
 *     销毁顺序留给 Core），resized 走 NSWindowDelegate 的 windowDidResize:。
 *
 * 单位约定同 adapter.h：这一层只讲物理像素，Cocoa 整层讲点，本文件是 macOS 上
 * 唯一的像素↔点换算处（§30 的"换算只有一处"分两段：MoonBit 的 Scale 管逻辑↔
 * 物理，本文件管物理↔点）。
 */
#include "../native-common/adapter.h"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

/* 排查"死在哪一次 FFI 调用"用的开关，和 libui 那份同一套：native 测试进程里
 * MoonBit 的 println 是全缓冲的，异常退出时整段丢失，只有 C 侧即时 fflush 的输出
 * 留得住顺序。打开方式：`MOONUI_NATIVE_TRACE=1 moon build/test ...`——
 * prebuild-link.js 的 compileAdapter 看到这个名字的环境变量就带 -DMOONUI_TRACE
 * 编这份 adapter（adapter_native.c 的 /DMOONUI_TRACE 同一条）。 */
#ifdef MOONUI_TRACE
#include <stdio.h>
#define TRACE(name)                 \
  do {                              \
    printf("[trace] %s\n", (name)); \
    fflush(stdout);                 \
  } while (0)
#else
#define TRACE(name) ((void)0)
#endif

/* 回调槽位表，和 libui 那份同构：C 必须替 MoonBit 看守闭包的生命周期，GC 看不见
 * 它，不 incref 回来的就是尸体（§47 风险 1）。一格 24 字节，用满时注册返回 -1。
 *
 * 为什么是 512 而不是 96：**换树时新旧两棵树会同时在场**。`Window::set_content`
 * 的顺序是"先建新树、再 close_tree 旧树"，所以峰值占用 ≈ 两棵树里带回调的控件
 * 之和；每格回调只有 24 字节，512 格 = 12KB，比"一次搜索就把槽位用完"值。
 * （真现象：播放列表 13 行 × 2 个回调 + 十段 EQ + 工具条那一排，重建两次就撞上
 * 96 的上限，报「原生点击回调槽位已用满」直接 panic。） */
#define MOONUI_SLOTS 512

typedef struct {
  void *owner;
  moonui_closure_fn fn;
  void *closure;
} MoonuiSlot;

static MoonuiSlot moonui_native_slots[MOONUI_SLOTS];
static char moonui_native_error[512];

/* 进程级单例标志：重复 init 直接返回成功，没初始化过的 terminate 是空操作。 */
static int moonui_native_inited = 0;
/* 主循环已结束（moonui_native_quit 置位）。moonui_native_main_step 从这里开始返回 0。 */
static int moonui_native_loop_ended = 0;

/* 菜单栏那两段（定义在本文件末尾的"菜单栏"一节）：terminate 要先松菜单回调再排
 * 槽位表，而定义排在 terminate 后面，所以这里先声明。 */
static void moonui_native_menu_clear(void);
static void moonui_native_menu_drop_closure(void);

/* `T85②` 的组合事件源（定义在本文件末尾的"输入法组合事件源"一节）：terminate
 * 松监听闭包的那一步、派发器在文本变化观察里推相位的那一步，都用到这里的声明。 */
static void moonui_native_ime_drop_closure(void);
static void moonui_native_ime_derive(NSView *control);

/* `T86` 的四段事件源/弹出源（定义都在本文件末尾，terminate 排在它们的前面，
 * 所以这里先声明）：
 *   - 右键按下的事件源（`T86①`，进程级鼠标监听的 mac 半——adapter.h 的鼠标
 *     段注那套契约，本轮只接右键按下那一支）；
 *   - 外部文件拖入的事件源（`T86③` 第一期档案，MoonuiWindow 自己是
 *     NSDraggingDestination）；
 *   - 上下文菜单的弹出（`T86①`，弹窗闭包与勾选回显的缺席都记在段注）；
 *   - 托盘（`T86⑥`，NSStatusItem + 通知）。 */
static void moonui_native_mouse_drop_closure(void);
static void moonui_native_drop_drop_closure(void);
static void moonui_native_ctx_drop_closure(void);
static void moonui_native_tray_drop_closure(void);

/* 键盘与焦点（`T91` 移植，adapter.h 键盘段注的整套契约）：进程级键盘监听
 * （KeyDown/KeyUp 两支，主菜单认领的组合不报）加焦点反查。 */
static void moonui_native_key_drop_closure(void);
/* 上下文菜单/托盘菜单的递归换 target 在实现前就被相互调用，补前向声明
 * （同排槽位那批的规矩）；拖拽 destination 那两条用 MoonuiWindow，排在窗口
 * 子类声明之后。 */
static void moonui_native_ctx_retarget(NSMenuItem *item);
static void moonui_native_tray_retarget(NSMenuItem *item);

/* 强引用表：手写 MRR 下把活着的 NSWindow 钉住。句柄是裸指针，不另存一份
 * 强引用，窗口建出来（alloc/init 的 +1 松掉后）就没人持有。销毁时从这里
 * 摘掉，最后一份引用没了窗口自己 dealloc。这是本文件唯一"替 MoonBit
 * 看守原生对象"的地方。 */
static NSMutableArray *moonui_native_live_windows = nil;

/* 控件的强引用表（FP2）：和 moonui_native_live_windows 同一套 MRC 看守。控件建出来就
 * 进表（+1），attach 时 contentView 再 retain 一份，destroy 时从表和 superview
 * 都摘掉、最后一份引用没了它自己 dealloc。 */
static NSMutableArray *moonui_native_live_widgets = nil;

/* 控件的 kind 记号：创建时写一次、之后只读，记在 view 自己身上（关联对象，和
 * libui 那份的 moonui_native_mark_kind 同一套手法）。通用属性入口（set_value /
 * append_option / set_selected / set_text / set_checked）按它分派到具体的
 * NSView 子类。编码与 adapter.h 一致：0=Label … 13=VSeparator、14=MenuRow。
 * 存 kind+1，0 = 没有记号。 */
static const void *const moonui_native_widget_kind_key = &moonui_native_widget_kind_key;

/* 控件的回调槽位号：注册回调时记在 view 身上，action/delegate 方法读它去 fire。
 * 存 slot+1，0 = 没注册过。 */
static const void *const moonui_native_widget_slot_key = &moonui_native_widget_slot_key;

/* 控件的 owner 记号（`T86①` 起反查命中用）：adapter.h 的「键盘与焦点」段注说的
 * "建控件时反记一笔这是哪个 moonui_ptr"——本文件里 moonui_ptr 就是 NSView 指针
 * 本身，所以记号是记"这 view 是我们的"这一件事（值恒非 0 的哨兵），命中反查沿
 * superview 链退到第一个带记号的 view，报出的指针就是 moonui_ptr。存哨兵 1。
 * OBJC_ASSOCIATION_ASSIGN 不 retain：记号只在 view 活着时被读（superview 链
 * 反查的每一步都沿活对象走），销毁顺序由强引用表管。 */
static const void *const moonui_native_owner_key = &moonui_native_owner_key;

static void moonui_native_mark_widget_kind(NSView *v, int kind) {
  if (v != nil) {
    objc_setAssociatedObject(v, moonui_native_widget_kind_key,
                             (id)(uintptr_t)(kind + 1), OBJC_ASSOCIATION_ASSIGN);
  }
}

static int moonui_native_widget_kind_of(NSView *v) {
  if (v == nil) {
    return -1;
  }
  return (int)(uintptr_t)objc_getAssociatedObject(v, moonui_native_widget_kind_key) - 1;
}

static void moonui_native_set_widget_slot(NSView *v, int slot) {
  if (v != nil) {
    objc_setAssociatedObject(v, moonui_native_widget_slot_key,
                             (id)(uintptr_t)(slot + 1), OBJC_ASSOCIATION_ASSIGN);
  }
}

static int moonui_native_widget_slot_of(NSView *v) {
  if (v == nil) {
    return -1;
  }
  return (int)(uintptr_t)objc_getAssociatedObject(v, moonui_native_widget_slot_key) - 1;
}

/* 菜单行的选中态：单独记在 view 身上，不借 NSButton 的 state——momentary 型按钮
 * 的 state 点完会自己弹回 off，靠它画高亮会闪。这里存 0/1，drawRect 读它画底，
 * set_checked 写它。存 selected+1，0 = 没设过（按未选中画）。 */
static const void *const moonui_native_widget_selected_key = &moonui_native_widget_selected_key;

static void moonui_native_mark_widget_selected(NSView *v, int selected) {
  if (v != nil) {
    objc_setAssociatedObject(v, moonui_native_widget_selected_key,
                             (id)(uintptr_t)(selected + 1), OBJC_ASSOCIATION_ASSIGN);
  }
}

static int moonui_native_widget_selected_of(NSView *v) {
  uintptr_t raw;
  if (v == nil) {
    return 0;
  }
  raw = (uintptr_t)objc_getAssociatedObject(v, moonui_native_widget_selected_key);
  return raw == 0 ? 0 : (int)(raw - 1);
}

/* ---- 小工具：句柄 ---- */

static NSWindow *moonui_native_nswindow(moonui_ptr w) {
  return (NSWindow *)(uintptr_t)w;
}

/* ---- 小工具：字符串 ---- */

static int64_t moonui_native_pack2(int a, int b) {
  return ((int64_t)(int32_t)a << 32) | (int64_t)(uint32_t)b;
}

/* MoonBit 的 Bytes 不保证 NUL 结尾，NSString 要。复制一份是唯一不靠运气的做法，
 * 调用方负责 free。 */
static char *moonui_native_dup(const char *s, int len) {
  char *out;
  if (len < 0) {
    return 0;
  }
  out = (char *)malloc((size_t)len + 1u);
  if (out == 0) {
    return 0;
  }
  if (len > 0) {
    memcpy(out, s, (size_t)len);
  }
  out[len] = '\0';
  return out;
}

/* (UTF-8 指针, 字节数) → NSString。返回的是 autoreleased 的，所以每个导出函数
 * 都得有一层 @autoreleasepool 接着。 */
static NSString *moonui_native_string_of(const char *s, int len) {
  char *t = moonui_native_dup(s, len);
  NSString *out;
  if (t == 0) {
    return nil;
  }
  out = [NSString stringWithUTF8String:t];
  free(t);
  return out;
}

static moonbit_bytes_t moonui_native_bytes_of(const char *s) {
  int n = (int)strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  if (n > 0) {
    memcpy(out, s, (size_t)n);
  }
  return out;
}

/* NSString → MoonBit Bytes。UTF8String 的指针由 NSString 看守，所以当场拷走；
 * 遇到非法编码（落单的代理对）它给 NULL，这里当空串处理而不是崩。 */
static moonbit_bytes_t moonui_native_bytes_of_ns(NSString *s) {
  const char *u;
  if (s == nil) {
    return moonbit_make_bytes(0, 0);
  }
  u = [s UTF8String];
  if (u == 0) {
    return moonbit_make_bytes(0, 0);
  }
  return moonui_native_bytes_of(u);
}

/* ---- 小工具：单位换算（本文件唯一的像素↔点换算）---- */

/* 主屏（primary display）。[NSScreen mainScreen] 不是硬件主显示器——它跟着键盘
 * 焦点走（"当前拿着键盘焦点的那只窗口所在的屏"），焦点挪到副屏它就换人。
 * [NSScreen screens] 的第 0 个才是主显示器，列表还空着（太早）才退回 mainScreen。 */
static NSScreen *moonui_native_primary_screen(void) {
  /* 自带一层池：`[NSScreen screens]` 的 NSArray 是 autoreleased 的，调用方
   * （system_scale 这类裸 static）不一定有池接着。返回的 NSScreen 是 AppKit
   * 钉住的单例（screens 列表自己持有它），钉过池边界安全。 */
  @autoreleasepool {
    NSArray *screens = [NSScreen screens];
    if ([screens count] > 0) {
      return screens[0];
    }
    return [NSScreen mainScreen];
  }
}

/* 缩放倍数：1 = 普通屏，2 = Retina。取不到时按 1 算，绝不能返回 0——它要进除法。 */
static CGFloat moonui_native_system_scale(void) {
  NSScreen *screen = moonui_native_primary_screen();
  CGFloat scale = screen != nil ? [screen backingScaleFactor] : (CGFloat)1.0;
  return scale > (CGFloat)0 ? scale : (CGFloat)1.0;
}

static CGFloat moonui_native_window_scale_of(NSWindow *w) {
  CGFloat scale = w != nil ? [w backingScaleFactor] : (CGFloat)0;
  return scale > (CGFloat)0 ? scale : moonui_native_system_scale();
}

static CGFloat moonui_native_window_scale(moonui_ptr w) {
  return moonui_native_window_scale_of(moonui_native_nswindow(w));
}

/* 物理像素 → 点。交给 AppKit 的量保持 CGFloat，不做整数化：setFrame: 收小数，
 * 所以 px→pt→px 的往返在本文件是自逆的。 */
static CGFloat moonui_native_px_to_pt(int px, CGFloat scale) {
  return (CGFloat)px / scale;
}

/* 点 → 物理像素。这里必须落到整数（adapter.h 的打包返回就是 int32），四舍五入。 */
static int moonui_native_pt_to_px(CGFloat pt, CGFloat scale) {
  return (int)llround(pt * scale);
}

/* 只收 int 的入口（窗口尺寸、位置）用这个：点是整数，最坏差半个点。 */
static int moonui_native_px_to_whole_pt(int px, CGFloat scale) {
  return (int)llround((CGFloat)px / scale);
}

/* DPI：Cocoa 没有"每窗口 DPI"这个概念，倍数就是全部信息，96 是它的基准。 */
static int moonui_native_dpi_of_scale(CGFloat scale) {
  return (int)llround(scale * (CGFloat)96.0);
}

/* ---- 回调槽位（与 libui 那份同构）---- */

static void moonui_native_release_slot(MoonuiSlot *slot) {
  if (slot->closure != 0) {
    moonbit_decref(slot->closure);
    slot->closure = 0;
  }
  slot->fn = 0;
  slot->owner = 0;
}

/* 松开某个 owner 占用的槽位；fn 非空时只松匹配该回调的那一格——一个窗口有两个
 * 回调，注册 resized 不能把 closing 一起清掉。 */
static void moonui_native_forget(void *owner, moonui_closure_fn fn) {
  int i;
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    if (moonui_native_slots[i].owner == owner &&
        (fn == 0 || moonui_native_slots[i].fn == fn)) {
      moonui_native_release_slot(&moonui_native_slots[i]);
    }
  }
}

/* 装一个回调。同一个 (owner, fn) 只留最后一份，所以重复注册不会漏引用。 */
static int moonui_native_take_slot(void *owner, moonui_closure_fn fn, void *closure) {
  int i;
  moonui_native_forget(owner, fn);
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    if (moonui_native_slots[i].owner == 0) {
      moonui_native_slots[i].owner = owner;
      moonui_native_slots[i].fn = fn;
      moonui_native_slots[i].closure = closure;
      if (closure != 0) {
        moonbit_incref(closure);
      }
      return i;
    }
  }
  return -1;
}

static void moonui_native_fire(void *data) {
  MoonuiSlot *slot = (MoonuiSlot *)data;
  if (slot != 0 && slot->fn != 0) {
    slot->fn(slot->closure);
  }
}

/* ---- 回调分发器（前向声明）----
 *
 * 所有控件的 target-action 与文本 delegate 都指向这一只全局对象。它的实现
 * （@implementation）在下面的控件一节里，这里只前向声明接口和静态指针，好让
 * moonui_native_init 能建它、控件注册时能引用它。它不持有任何控件的强引用（target /
 * delegate 都是 assign 语义），所以不会把已销毁的控件钉住。 */
@interface MoonuiDispatcher : NSObject <NSTextFieldDelegate>
@end

static MoonuiDispatcher *moonui_native_dispatcher = nil;

/* ---- 窗口子类：回调的落点 ---- */

/* libui 那份的回调挂在 uiWindow 上、由 libui 分发；这里没有 libui，回调直接挂在
 * NSWindow 自己身上。closing 覆写 windowShouldClose:——固定返回 NO 否决 AppKit
 * 自己的销毁，销毁顺序留给 Core（先内容树后窗口，§12）；resized 走 NSWindowDelegate
 * 的 windowDidResize:，程序化改尺寸时用 suppress_resize 挡掉回声（adapter.h 的
 * on_resized 契约）。
 *
 * `T86③` 第一期档案：窗口自己当 NSDraggingDestination，收外部文件拖入。挂在
 * 窗口而不是 contentView 的子类上，是拖拽 destination 的"最深层视图优先"递退
 * 会退到窗口这一层（标准 AppKit 视图都不认文件 URL），标准控件不用一个一个
 * 让路。监听闭包经文件尾部的 drop 段落通知 MoonBit；perform 返回 YES 才算接住。
 * 已知边界记在段注：编辑中的文本控件上方可能被 field editor 拦住（NSTextView
 * 自己实现了拖拽 destination），真拖验证欠账挂在 `T86③` 的报告里。 */
@interface MoonuiWindow : NSWindow <NSWindowDelegate, NSDraggingDestination>
@property(nonatomic, assign) int closing_slot;
@property(nonatomic, assign) int resized_slot;
@property(nonatomic, assign) BOOL suppress_resize;
@property(nonatomic, assign) int moved_slot;
@property(nonatomic, assign) BOOL suppress_move;
/* 红绿灯的自定义落点（关闭按钮左上角相对窗口左上角，点）。`traffic_custom`
 * 关着时完全交给 AppKit 的标准位置，不碰。 */
@property(nonatomic, assign) BOOL traffic_custom;
@property(nonatomic, assign) CGFloat traffic_x;
@property(nonatomic, assign) CGFloat traffic_y;
/* 把三只系统按钮整体挪到 `traffic_x/y`。见实现处的段注：必须三只一起挪，
 * 只改关闭按钮那一只不会带动另外两只。 */
- (void)applyTrafficLightPosition;
@end

/* 拖拽 destination 的实现排在文件尾部（`T86③`），窗口子类的 @implementation
 * 在这里就要引用它们——补前向声明。 */
static int moonui_native_drop_accepts(void);
static BOOL moonui_native_drop_perform(MoonuiWindow *win,
                                id<NSDraggingInfo> info);

@implementation MoonuiWindow
- (instancetype)
    initWithContentRect:(NSRect)contentRect
              styleMask:(NSWindowStyleMask)styleMask
                backing:(NSBackingStoreType)backingStore
                  defer:(BOOL)flag {
  self = [super initWithContentRect:contentRect
                          styleMask:styleMask
                            backing:backingStore
                              defer:flag];
  if (self != nil) {
    self.closing_slot = -1;
    self.resized_slot = -1;
    self.suppress_resize = NO;
    self.moved_slot = -1;
    self.suppress_move = NO;
    self.traffic_custom = NO;
    self.traffic_x = 0.0;
    self.traffic_y = 0.0;
  }
  return self;
}

/* 红绿灯的落点：三只按钮都住在 `NSTitlebarView` 里（frame 以标题栏左下角为
 * 原点，未翻转），而调用方给的是"相对窗口左上角"。两个坐标系差一个标题栏在
 * 窗口里的位置 + 标题栏自身高度，且沉浸式下标题栏是浮在内容上的（fullSize
 * ContentView 只把窗口高缩到内容高，标题栏仍是顶上那 28pt）。这里先换算再
 * 整簇平移，别按窗口坐标直接写 frame——旧实现就是这么写的，按钮会被挪到窗
 * 外（frame.origin.y ≈ winH - 16，而标题栏坐标只有 0…28）。 */
- (void)applyTrafficLightPosition {
  if (!self.traffic_custom) {
    return;
  }
  NSButton *close = [self standardWindowButton:NSWindowCloseButton];
  if (close == nil) {
    return;
  }
  NSView *bar = [close superview];
  if (bar == nil) {
    return;
  }
  /* 标题栏在窗口里的矩形（窗口坐标系，y 向上）。 */
  NSRect barInWindow = [bar convertRect:[bar bounds] toView:nil];
  CGFloat barTopFromWindowTop = [self frame].size.height - NSMaxY(barInWindow);
  NSRect f = [close frame];
  CGFloat targetX = self.traffic_x - barInWindow.origin.x;
  CGFloat topInBar = self.traffic_y - barTopFromWindowTop;
  CGFloat targetY = [bar isFlipped] ? topInBar
                                    : [bar bounds].size.height - topInBar - f.size.height;
  CGFloat dx = targetX - f.origin.x;
  CGFloat dy = targetY - f.origin.y;
  if (dx == 0.0 && dy == 0.0) {
    return;
  }
  NSArray *buttons = [NSArray arrayWithObjects:close,
                      [self standardWindowButton:NSWindowMiniaturizeButton],
                      [self standardWindowButton:NSWindowZoomButton], nil];
  for (NSButton *btn in buttons) {
    NSRect bf = [btn frame];
    bf.origin.x += dx;
    bf.origin.y += dy;
    [btn setFrame:bf];
  }
}

/* AppKit 在换 styleMask（进出沉浸式、改可缩放）、改 `titleVisibility`
 * （实测：`NSWindowTitleHidden` 这一下会把 close 摆回 6）和改窗口 frame 时会
 * 重排标题栏按钮，把自定义落点盖回标准位置。所以这几处覆写里各补一次，让落点
 * 是"持久"的而不是"设一次就丢"。 */
- (void)setStyleMask:(NSWindowStyleMask)styleMask {
  [super setStyleMask:styleMask];
  [self applyTrafficLightPosition];
}

- (void)setTitleVisibility:(NSWindowTitleVisibility)visibility {
  [super setTitleVisibility:visibility];
  [self applyTrafficLightPosition];
}

- (void)setTitlebarAppearsTransparent:(BOOL)flag {
  [super setTitlebarAppearsTransparent:flag];
  [self applyTrafficLightPosition];
}

- (void)setFrame:(NSRect)frameRect display:(BOOL)displayFlag {
  [super setFrame:frameRect display:displayFlag];
  [self applyTrafficLightPosition];
}

- (BOOL)windowShouldClose:(id)sender {
  (void)sender;
  if (self.closing_slot >= 0) {
    moonui_native_fire(&moonui_native_slots[self.closing_slot]);
  }
  return NO;
}

- (void)windowDidResize:(NSNotification *)note {
  (void)note;
  if (!self.suppress_resize && self.resized_slot >= 0) {
    moonui_native_fire(&moonui_native_slots[self.resized_slot]);
  }
}

- (void)windowDidMove:(NSNotification *)note {
  (void)note;
  if (!self.suppress_move && self.moved_slot >= 0) {
    moonui_native_fire(&moonui_native_slots[self.moved_slot]);
  }
}

/* 每个更新周期前把自定义落点补一次。兜的是"AppKit 自己在某个时点排了一遍
 * 标题栏"——`layoutSubtreeIfNeeded` 一旦落到 theme frame 上，三只按钮就回默认
 * 位（实测：主控那次的 close.y 从 5 被摆回 6）。setStyleMask / setFrame /
 * titleVisibility 三处覆写已经盖住了常规路径，这一道是它们之外的保险；
 * `applyTrafficLightPosition` 在落点没变时直接返回，不会每拍都写一遍。 */
- (void)windowDidUpdate:(NSNotification *)note {
  (void)note;
  [self applyTrafficLightPosition];
}

/* ---- 文件拖入（`T86③`，实现见文件尾部的 drop 段落）---- */
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
  (void)info;
  return moonui_native_drop_accepts() != 0 ? NSDragOperationCopy
                                           : NSDragOperationNone;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info {
  (void)info;
  return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
  return moonui_native_drop_perform(self, info);
}
@end

/* ---- 生命周期 ---- */

int moonui_native_init(void) {
  TRACE("init");
  if (moonui_native_inited) {
    return 0;
  }
  moonui_native_error[0] = '\0';
  @autoreleasepool {
    /* 自己接管 NSApplication 单例：libui 的 uiInit 在 darwin 侧干的就是这件事，
     * 这里直接做，不经过它。activation policy 设成 Regular 让窗口能拿到焦点、
     * 出现在 Dock 里（探针里量过：不设的话 isKey 恒 0）。 */
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
    /* 没有菜单栏的 NSApplication 在第一次装菜单时会自己补一只空的，但那一步发生
     * 在 [NSApp run] 里——本后端自己泵循环、不 run，所以这里把空的主菜单先建
     * 好：moonui_native_set_menu_bar 只往 [NSApp mainMenu] 后面追加（和 libui 那份
     * 同一套形状），主菜单不存在它就只能报 -2。 */
    if ([NSApp mainMenu] == nil) {
      NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
      [NSApp setMainMenu:m];
      [m release];
    }
    if (moonui_native_live_windows == nil) {
      /* MRC：[NSMutableArray array] 是 autoreleased 的，赋给全局不会 retain，
       * 池一 drain 它就没了、全局变悬垂（terminate 时再碰就是野指针）。用
       * alloc/init 拿 +1，进程级常驻、不释放。 */
      moonui_native_live_windows = [[NSMutableArray alloc] init];
    }
    if (moonui_native_live_widgets == nil) {
      moonui_native_live_widgets = [[NSMutableArray alloc] init];
    }
    if (moonui_native_dispatcher == nil) {
      /* 进程级单例：所有控件的 target-action 与文本 delegate 都指向它。alloc/init
       * 拿 +1、永不释放（进程退出时随进程走）。它不持有任何控件的强引用，所以不会
       * 把已销毁的控件钉住。 */
      moonui_native_dispatcher = [[MoonuiDispatcher alloc] init];
    }
  }
  moonui_native_inited = 1;
  return 0;
}

moonbit_bytes_t moonui_native_last_error(void) {
  TRACE("last_error");
  return moonui_native_bytes_of(moonui_native_error);
}

void moonui_native_terminate(void) {
  int i;
  TRACE("terminate");
  /* 菜单栏的回调不占槽位表（整个进程只有一棵菜单），所以单独松一次，排在排槽
   * 之前——槽位表只看守"一控件一格"的回调，菜单那份在它自己那格里。 */
  moonui_native_menu_drop_closure();
  /* `T85②`：组合监听同一条形状（进程一份，不占槽位表），排在排槽之前一起松。 */
  moonui_native_ime_drop_closure();
  /* `T86`：右键事件源、文件拖入源、上下文菜单与托盘的闭包同一条形状
   * （进程一份，不占槽位表），排在排槽之前一起松。键盘同款（`T91`）。 */
  moonui_native_mouse_drop_closure();
  moonui_native_key_drop_closure();
  moonui_native_drop_drop_closure();
  moonui_native_ctx_drop_closure();
  moonui_native_tray_drop_closure();
  /* 先排槽位表：槽位里看守的闭包要 decref，窗口销毁（MoonBit 侧已先做）之后这里
   * 把剩下的引用松干净。强引用表最后清——窗口对象由它钉着，清掉才真正 dealloc。 */
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    moonui_native_release_slot(&moonui_native_slots[i]);
  }
  if (!moonui_native_inited) {
    return;
  }
  moonui_native_menu_clear();
  moonui_native_inited = 0;
  moonui_native_loop_ended = 0;
  @autoreleasepool {
    [moonui_native_live_windows removeAllObjects];
    /* 控件应当已经全部销毁（Core 的顺序保证）；这里清表是兜底——万一有漏网的，
     * 最后一份引用在这里松掉、它自己 dealloc。 */
    [moonui_native_live_widgets removeAllObjects];
  }
  /* 不调 [NSApp terminate:]：那是"退出进程"，而 MoonBit 侧的 terminate 只是收尾，
   * 进程要等 main 返回才退。事件循环是我们自己泵的不是 [NSApp run]，所以这里不
   * 终止 NSApp 也不影响退出。 */
}

/* ---- 窗口 ---- */

moonui_ptr moonui_native_window_new(const char *title,
                             int title_len,
                             int width,
                             int height) {
  NSString *t;
  CGFloat scale;
  int wpt;
  int hpt;
  TRACE("window_new");
  scale = moonui_native_system_scale();
  /* 宽高是客户区的点，这里进来的还是物理像素，所以先除一次倍数。窗口还没建出来，
   * 只能用主屏倍数；Core 在建完后会按窗口自己的倍数再纠正一次尺寸
   * （backend.mbt 的 create_window），和 libui 那份同一套。 */
  wpt = moonui_native_px_to_whole_pt(width, scale);
  hpt = moonui_native_px_to_whole_pt(height, scale);
  @autoreleasepool {
    t = moonui_native_string_of(title, title_len);
    MoonuiWindow *win = [[MoonuiWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, wpt, hpt)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [win setTitle:t];
    /* 自己当自己的 delegate：windowDidResize: 才落得到这里。 */
    [win setDelegate:win];
    /* `T86③`：登记文件 URL 这一档拖入类型（destination 方法在 MoonuiWindow
     * 上：没有更深的 view 认文件 URL 时拖拽递退到窗口这一层，窗口自己接住）。
     * 登记口是 contentView 的 registerForDraggedTypes:（NSWindow 没有这条，
     * registerForDraggingTypes: 是十年前就废弃的旧名）。 */
    [[win contentView] registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    [win center];
    /* addObject: 替强引用表 retain 一份（+1），本地这份 alloc/init 的 +1 在这里
     * 松掉——窗口从此只被表钉着，销毁时表摘掉、最后一份引用没了它自己 dealloc。 */
    [moonui_native_live_windows addObject:win];
    [win release];
    return (moonui_ptr)(uintptr_t)win;
  }
}

void moonui_native_window_show(moonui_ptr w) {
  TRACE("window_show");
  @autoreleasepool {
    [moonui_native_nswindow(w) makeKeyAndOrderFront:nil];
  }
}

void moonui_native_window_hide(moonui_ptr w) {
  TRACE("window_hide");
  @autoreleasepool {
    [moonui_native_nswindow(w) orderOut:nil];
  }
}

/* ---- 离屏取证（开发用，不进产品路径）----
 *
 * 让应用**自己**把窗口内容渲进位图再写成 PNG。走的是 AppKit 的视图自绘通道
 * （`bitmapImageRepForCachingDisplayInRect:` + `cacheDisplayInRect:toBitmapImageRep:`），
 * 不是 `screencapture`——后者要屏幕录制权限，沙箱/无头环境里拿到的是全黑。
 * 视图自绘不需要任何权限：内容就是这只进程自己画的那一份。
 *
 * 一张窗一个文件，文件名取窗口标题（`/` 换成 `_`，避免造出子目录）。目录不存
 * 在就先建（含中间层）。返回写成功的张数；没有窗口/目录建不出来 → 0。
 *
 * 只为「看一眼长什么样」与将来的视觉回归取证服务：调用方负责在窗口已经
 * 显示、布局已经跑过之后调它，这里不再补一次 run loop。
 *
 * 同一趟还写一份 `views.txt`：原生视图树（类名 / frame / 隐藏 / 透明度 / 是否
 * 翻转）。像素只能告诉你"看不见"，这份账才告诉你"谁把它放到了哪儿、挂没挂上
 * ——截图对不上时先看它，别靠猜。 */
static void moonui_native_dump_views(NSView *v, int depth, NSMutableString *out) {
  NSRect f = [v frame];
  NSRect b = [v bounds];
  int i;
  for (i = 0; i < depth; ++i) {
    [out appendString:@"  "];
  }
  [out appendFormat:@"%@ frame=(%.1f,%.1f %.1fx%.1f) bounds=(%.1fx%.1f)%@%@%@\n",
                    NSStringFromClass([v class]), (double)f.origin.x,
                    (double)f.origin.y, (double)f.size.width,
                    (double)f.size.height, (double)b.size.width,
                    (double)b.size.height, [v isFlipped] ? @" flipped" : @"",
                    [v isHidden] ? @" HIDDEN" : @"",
                    [v alphaValue] < 0.999 ? @" alpha" : @""];
  for (NSView *c in [v subviews]) {
    moonui_native_dump_views(c, depth + 1, out);
  }
}

int moonui_native_snapshot_all(const char *dir, int dir_len) {
  int written = 0;
  @autoreleasepool {
    NSString *d = moonui_native_string_of(dir, dir_len);
    NSMutableString *tree = [[NSMutableString alloc] init];
    [[NSFileManager defaultManager] createDirectoryAtPath:d
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    /* 只拍 MoonUI 自己建的窗：`[NSApp windows]` 里还混着 AppKit 的私家伙计
     * （菜单的 `Item-0`、Dock 图标那种 34x24 的空标题窗），它们不是这个程序
     * 的画，会给视觉对账添噪声。强引用表就是"本进程建的窗"的权威清单。 */
    for (NSWindow *w in moonui_native_live_windows) {
      NSView *v = [w contentView];
      if (v == nil) {
        continue;
      }
      NSRect b = [v bounds];
      if (b.size.width < 1.0 || b.size.height < 1.0) {
        continue;
      }
      /* 先把布局与显示账欠的补上，再顺手抄一份——不然抓到的是上一帧。 */
      [v layoutSubtreeIfNeeded];
      [v displayIfNeeded];
      /* 头行带上窗口在屏幕上的位置：这是唯一能核对"多窗默认布局/复位"的
       * 凭据——每窗的 PNG 是各自 contentView 的自绘，看不出相对位置。
       * 坐标按 MoonUI 语义（左上原点）打：Cocoa 的 frame 是左下原点，翻一次。 */
      {
        NSRect wf = [w frame];
        NSScreen *scr = [w screen];
        CGFloat top = scr ? (NSMaxY([scr frame]) - NSMaxY(wf)) : 0.0;
        [tree appendFormat:@"== %@ （contentView %.1fx%.1f） screen=(%.1f,%.1f) frame=%.1fx%.1f\n",
                           [w title], (double)b.size.width, (double)b.size.height,
                           (double)wf.origin.x, (double)top, (double)wf.size.width,
                           (double)wf.size.height];
      }
      moonui_native_dump_views(v, 0, tree);
      NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:b];
      if (rep == nil) {
        continue;
      }
      [v cacheDisplayInRect:b toBitmapImageRep:rep];
      NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                       properties:@{}];
      if (png == nil) {
        continue;
      }
      NSString *name = [w title];
      if ([name length] == 0) {
        name = @"window";
      }
      name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
      NSString *path = [d stringByAppendingPathComponent:
                              [name stringByAppendingString:@".png"]];
      if ([png writeToFile:path atomically:YES]) {
        ++written;
      }
    }
    [tree writeToFile:[d stringByAppendingPathComponent:@"views.txt"]
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    [tree release];
  }
  return written;
}

void moonui_native_window_destroy(moonui_ptr w) {
  MoonuiWindow *win;
  TRACE("window_destroy");
  win = (MoonuiWindow *)(uintptr_t)w;
  /* 先松开替这个窗口看守的 closing/resized 引用。控件必须已经全部销毁
   * （Core 的顺序保证），否则窗口拆掉后 view 还留在 contentView 的 subviews 里。 */
  moonui_native_forget((void *)(uintptr_t)w, 0);
  /* 用 orderOut: 而不是 close: 摘窗口——close: 在 MRC 下会替 AppKit 把窗口
   * release 掉（"orderOut + release"），那会多松一份引用、把窗口当场 dealloc，
   * 后面再碰就是野指针（探针里量过：close 版在最终 release 处 EXC_BAD_ACCESS，
   * orderOut 版干净退出）。orderOut: 只把窗口移出屏幕、不松引用，引用全归强引用
   * 表管。临时 retain 一份把窗口钉过池的边界，池排完再松，dealloc 落在池外。 */
  [win retain];
  @autoreleasepool {
    [win orderOut:nil];
    [moonui_native_live_windows removeObject:win];
  }
  [win release];
}

void moonui_native_window_set_title(moonui_ptr w, const char *title, int title_len) {
  NSString *t;
  TRACE("window_set_title");
  @autoreleasepool {
    t = moonui_native_string_of(title, title_len);
    [moonui_native_nswindow(w) setTitle:t];
  }
}

void moonui_native_window_set_content_size(moonui_ptr w, int width, int height) {
  CGFloat scale;
  TRACE("window_set_content_size");
  scale = moonui_native_window_scale(w);
  @autoreleasepool {
    MoonuiWindow *win = (MoonuiWindow *)(uintptr_t)w;
    /* suppress_resize 挡掉"程序化改尺寸"的回声（adapter.h 的 on_resized 契约）：
     * Core 建完窗口会立刻纠正一次尺寸，那不该变成一条 Resize 事件。 */
    win.suppress_resize = YES;
    [win setContentSize:NSMakeSize(moonui_native_px_to_pt(width, scale),
                                   moonui_native_px_to_pt(height, scale))];
    win.suppress_resize = NO;
  }
}

int64_t moonui_native_window_content_size(moonui_ptr w) {
  NSRect content;
  CGFloat scale;
  TRACE("window_content_size");
  @autoreleasepool { content = [moonui_native_nswindow(w) contentRectForFrameRect:[moonui_native_nswindow(w) frame]]; }
  scale = moonui_native_window_scale(w);
  return moonui_native_pack2(moonui_native_pt_to_px(content.size.width, scale),
                      moonui_native_pt_to_px(content.size.height, scale));
}

/* 客户区最小尺寸落成 AppKit 的 contentMinSize：这是**用户拖拽**时的钳位，拖
 * 到下限系统就顶住（Core 侧的 clamped 只管程序化改尺寸，拖拽不经过 Core）。
 * 沉浸式窗口的 contentView 铺满整窗，所以 contentMinSize 就是整窗下限，口径
 * 和 set_content_size 一致。传 0 表示清掉限制（contentMinSize 的零值本来就是
 * "没有下限"，不用再分一支）。 */
void moonui_native_window_set_min_size(moonui_ptr w, int width, int height) {
  CGFloat scale;
  TRACE("window_set_min_size");
  scale = moonui_native_window_scale(w);
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    [win setContentMinSize:NSMakeSize(moonui_native_px_to_pt(width, scale),
                                      moonui_native_px_to_pt(height, scale))];
  }
}

int64_t moonui_native_window_min_size(moonui_ptr w) {
  NSSize min;
  CGFloat scale;
  TRACE("window_min_size");
  @autoreleasepool { min = [moonui_native_nswindow(w) contentMinSize]; }
  scale = moonui_native_window_scale(w);
  return moonui_native_pack2(moonui_native_pt_to_px(min.width, scale),
                      moonui_native_pt_to_px(min.height, scale));
}

/* 当下是不是在用户拖拽改尺寸的会话里（live resize 跟踪循环中）。实时重排只认
 * 拖拽——程序化 setContentSize 不算（那条另有 suppress_resize 挡回声，且 Core 的
 * set_size 自己当场重排）。AppKit 的 inLiveResize 正是这个语义。 */
int moonui_native_window_in_live_resize(moonui_ptr w) {
  TRACE("window_in_live_resize");
  @autoreleasepool {
    return [moonui_native_nswindow(w) inLiveResize] ? 1 : 0;
  }
}

void moonui_native_window_set_position(moonui_ptr w, int x, int y) {
  CGFloat scale;
  TRACE("window_set_position");
  scale = moonui_native_window_scale(w);
  @autoreleasepool {
    /* suppress_move 挡掉"程序化搬窗"的回声（adapter.h 的 on_moved 契约）：Core
     * 的吸附联动（`App::follow_move`）搬邻居时调的就是这条，那不该回声成一条
     * Moved 事件——否则联动会自拖自、邻居被搬两遍。 */
    MoonuiWindow *win = (MoonuiWindow *)(uintptr_t)w;
    win.suppress_move = YES;
    /* 收的是"外层左上角、屏幕坐标、y 向下"。Cocoa 的 setFrameOrigin: 收的是
     * 左下角、y 向上，所以这里翻一次 y：用窗口所在屏的可见区高度减掉目标 y 和
     * 窗口高度。和 libui 的 darwin 版（window.m 的 uiWindowSetPosition）同一套。 */
    NSScreen *screen = [win screen] != nil ? [win screen] : moonui_native_primary_screen();
    NSRect visible = screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
    NSRect frame = [win frame];
    CGFloat originY = visible.origin.y + visible.size.height -
                      moonui_native_px_to_pt(y, scale) - frame.size.height;
    [win setFrameOrigin:NSMakePoint(visible.origin.x + moonui_native_px_to_pt(x, scale),
                                    originY)];
    win.suppress_move = NO;
  }
}

int64_t moonui_native_window_position(moonui_ptr w) {
  NSRect frame;
  NSRect visible;
  NSScreen *screen;
  CGFloat scale;
  TRACE("window_position");
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    frame = [win frame];
    screen = [win screen] != nil ? [win screen] : moonui_native_primary_screen();
    visible = screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
  }
  scale = moonui_native_window_scale(w);
  /* 和 setter 同一套翻转：y 从"该屏可见区上边往下"量。 */
  return moonui_native_pack2(
      moonui_native_pt_to_px(frame.origin.x - visible.origin.x, scale),
      moonui_native_pt_to_px(visible.size.height - (frame.origin.y + frame.size.height - visible.origin.y), scale));
}

void moonui_native_window_set_resizable(moonui_ptr w, int resizable) {
  TRACE("window_set_resizable");
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    if (resizable) {
      win.styleMask |= NSWindowStyleMaskResizable;
    } else {
      win.styleMask &= ~NSWindowStyleMaskResizable;
    }
  }
}

void moonui_native_window_set_fullscreen(moonui_ptr w, int fullscreen) {
  TRACE("window_set_fullscreen");
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    BOOL is_fs = (win.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (fullscreen && !is_fs) {
      [win toggleFullScreen:nil];
    } else if (!fullscreen && is_fs) {
      [win toggleFullScreen:nil];
    }
  }
}

/* ---- 窗口态（`T86②`）----
 *
 * 两条 setter 加一条读回，语义都是"只在差异上动"：miniaturize:/zoom: 是开关
 * 型动作（zoom 字面义就是 toggle），照 fullscreen 那条同一个形状先问当下态，
 * 只在真的要变时才调——程序自己重发同一条意图不该让窗口抖一下。恢复的那半
 * 各走各的恢复路径：deminiaturize: 把窗口从 Dock 请回来；zoom 位翻回去由
 * AppKit 自己记"进最大化之前是什么样"（zoom 的定义就是 toggle）。读回打包成
 * 位：bit0 = isMiniaturized、bit1 = isZoomed——"读当下态"而非推送式，持久化
 * （`T86⑦`）问一次拿一份快照。 */

void moonui_native_window_set_minimized(moonui_ptr w, int minimized) {
  TRACE("window_set_minimized");
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    if (minimized != 0 && !win.isMiniaturized) {
      [win miniaturize:nil];
    } else if (minimized == 0 && win.isMiniaturized) {
      [win deminiaturize:nil];
    }
  }
}

void moonui_native_window_set_maximized(moonui_ptr w, int maximized) {
  TRACE("window_set_maximized");
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    if (maximized != 0 && !win.isZoomed) {
      [win zoom:nil];
    } else if (maximized == 0 && win.isZoomed) {
      [win zoom:nil];
    }
  }
}

int moonui_native_window_state(moonui_ptr w) {
  int bits;
  TRACE("window_state");
  bits = 0;
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    if (win != nil) {
      if (win.isMiniaturized) {
        bits |= 1;
      }
      if (win.isZoomed) {
        bits |= 2;
      }
    }
  }
  return bits;
}

void moonui_native_window_set_titlebar_style(moonui_ptr w, int immersive) {
  TRACE("window_set_titlebar_style");
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    if (win == nil) {
      return;
    }
    if (immersive) {
      win.styleMask |= NSWindowStyleMaskFullSizeContentView;
      win.titlebarAppearsTransparent = YES;
      win.titleVisibility = NSWindowTitleHidden;
    } else {
      win.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
      win.titlebarAppearsTransparent = NO;
      win.titleVisibility = NSWindowTitleVisible;
    }
  }
}

int moonui_native_window_titlebar_style(moonui_ptr w) {
  int bits = 0;
  TRACE("window_titlebar_style");
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    if (win == nil) {
      return 0;
    }
    if (win.styleMask & NSWindowStyleMaskFullSizeContentView) {
      bits |= 1;
    }
    if (win.titlebarAppearsTransparent) {
      bits |= 2;
    }
    if (win.titleVisibility == NSWindowTitleHidden) {
      bits |= 4;
    }
  }
  return bits;
}

void moonui_native_window_set_traffic_light_position(moonui_ptr w, int x, int y) {
  CGFloat scale;
  TRACE("window_set_traffic_light_position");
  scale = moonui_native_window_scale(w);
  @autoreleasepool {
    MoonuiWindow *win = (MoonuiWindow *)moonui_native_nswindow(w);
    if (win == nil) {
      return;
    }
    /* 收的是"关闭按钮左上角相对窗口左上角"的物理像素，换算成点存下来：
     * 窗口换 styleMask / 改尺寸时 AppKit 会重排按钮，落点得能重放（见
     * applyTrafficLightPosition 的段注）。 */
    win.traffic_x = moonui_native_px_to_pt(x, scale);
    win.traffic_y = moonui_native_px_to_pt(y, scale);
    win.traffic_custom = YES;
    [win applyTrafficLightPosition];
  }
}

int64_t moonui_native_window_traffic_light_position(moonui_ptr w) {
  CGFloat scale;
  TRACE("window_traffic_light_position");
  scale = moonui_native_window_scale(w);
  @autoreleasepool {
    NSWindow *win = moonui_native_nswindow(w);
    NSButton *close = [win standardWindowButton:NSWindowCloseButton];
    if (close == nil) {
      return moonui_native_pack2(0, 0);
    }
    NSView *bar = [close superview];
    if (bar == nil) {
      return moonui_native_pack2(0, 0);
    }
    /* 与 setter 同一套换算：按钮 frame 在标题栏坐标里，先叠加标题栏在窗口里
     * 的位置，再翻成"距窗口顶上沿"。 */
    NSRect barInWindow = [bar convertRect:[bar bounds] toView:nil];
    NSRect f = [close frame];
    CGFloat topInBar = [bar isFlipped]
                           ? f.origin.y
                           : [bar bounds].size.height - f.origin.y - f.size.height;
    CGFloat x = barInWindow.origin.x + f.origin.x;
    CGFloat y = [win frame].size.height - NSMaxY(barInWindow) + topInBar;
    return moonui_native_pack2(moonui_native_pt_to_px(x, scale),
                               moonui_native_pt_to_px(y, scale));
  }
}

int moonui_native_window_dpi(moonui_ptr w) {
  TRACE("window_dpi");
  return moonui_native_dpi_of_scale(moonui_native_window_scale(w));
}

int moonui_native_window_on_closing(moonui_ptr w,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("window_on_closing");
  slot = moonui_native_take_slot((void *)(uintptr_t)w, fn, closure);
  if (slot < 0) {
    return -1;
  }
  ((MoonuiWindow *)(uintptr_t)w).closing_slot = slot;
  return 0;
}

int moonui_native_window_on_resized(moonui_ptr w,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("window_on_resized");
  slot = moonui_native_take_slot((void *)(uintptr_t)w, fn, closure);
  if (slot < 0) {
    return -1;
  }
  ((MoonuiWindow *)(uintptr_t)w).resized_slot = slot;
  return 0;
}

int moonui_native_window_on_moved(moonui_ptr w,
                          moonui_closure_fn fn,
                          void *closure) {
  int slot;
  TRACE("window_on_moved");
  slot = moonui_native_take_slot((void *)(uintptr_t)w, fn, closure);
  if (slot < 0) {
    return -1;
  }
  ((MoonuiWindow *)(uintptr_t)w).moved_slot = slot;
  return 0;
}

/* ---- 屏幕与主题 ---- */

int moonui_native_system_dpi(void) {
  TRACE("system_dpi");
  return moonui_native_dpi_of_scale(moonui_native_system_scale());
}

int64_t moonui_native_screen_work_area(void) {
  NSScreen *screen;
  NSRect visible;
  CGFloat scale;
  TRACE("screen_work_area");
  @autoreleasepool {
    screen = moonui_native_primary_screen();
    if (screen == nil) {
      return moonui_native_pack2(0, 0);
    }
    visible = [screen visibleFrame];
    scale = [screen backingScaleFactor];
  }
  if (scale <= (CGFloat)0) {
    scale = moonui_native_system_scale();
  }
  return moonui_native_pack2(moonui_native_pt_to_px(visible.size.width, scale),
                      moonui_native_pt_to_px(visible.size.height, scale));
}

/* 这只窗口当下在哪块屏。没上屏（screen 为 nil，比如刚建好还没 show）退回主屏。 */
static NSRect moonui_native_window_screen_visible(moonui_ptr w) {
  NSWindow *win;
  NSScreen *screen;
  win = moonui_native_nswindow(w);
  screen = win != nil ? [win screen] : nil;
  if (screen == nil) {
    screen = moonui_native_primary_screen();
  }
  return screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
}

int64_t moonui_native_window_screen_origin(moonui_ptr w) {
  NSRect visible;
  CGFloat scale;
  TRACE("window_screen_origin");
  @autoreleasepool { visible = moonui_native_window_screen_visible(w); }
  scale = moonui_native_window_scale(w);
  /* y 恒 0：这个坐标空间的原点就是该屏可见区左上角（和 libui 的 darwin 版同一
   * 口径）。x 不是 0：那只屏在主屏右边时 visibleFrame.origin.x 就是非零的 Cocoa x。 */
  return moonui_native_pack2(moonui_native_pt_to_px(visible.origin.x, scale), 0);
}

int64_t moonui_native_window_screen_size(moonui_ptr w) {
  NSRect visible;
  CGFloat scale;
  TRACE("window_screen_size");
  @autoreleasepool { visible = moonui_native_window_screen_visible(w); }
  if (visible.size.width <= (CGFloat)0 || visible.size.height <= (CGFloat)0) {
    return moonui_native_screen_work_area();
  }
  scale = moonui_native_window_scale(w);
  return moonui_native_pack2(moonui_native_pt_to_px(visible.size.width, scale),
                      moonui_native_pt_to_px(visible.size.height, scale));
}

int moonui_native_host_platform(void) {
  /* 血统不是运行时事实，是这个二进制的事实：1 = macOS（见 adapter.h 段注）。 */
  return 1;
}

int moonui_native_system_theme(void) {
  int dark;
  TRACE("system_theme");
  dark = 0;
  @autoreleasepool {
    NSAppearance *eff;
    NSString *name;
    /* 深色那几支的名字里都含 "Dark"（DarkAqua、VibrantDark 及高对比度那两支），
     * 浅色的都不含（Aqua、VibrantLight），所以按子串判。NSApp 还没建出来时 name
     * 是 nil，落回浅色。 */
    eff = [NSApp effectiveAppearance];
    name = [eff name];
    if (name != nil && [name rangeOfString:@"Dark"].location != NSNotFound) {
      dark = 1;
    }
  }
  return dark;
}

/* ---- 进程级偏好读数（T87②/③）----
 * 两条都是 NSWorkspace 的可访问性 BOOL 读口（AppKit 的属性，读当下偏好）：
 * concrete API 名 clang -fsyntax-only 查证过（2026-10-15，批二三个旧名被咬的
 * 前科），属性没查证前不许写。读不到当 0（偏好关）：属性返回 NO 与"读不到"
 * 在这条 ABI 上是同一个语义（偏好关），没有失败形态可报。 */
/* 减少动态效果（T87③）：accessibilityDisplayShouldReduceMotion，系统偏好
 * "减弱动态效果"开着时为 YES——动画的退场闸门（MoonBit 侧 pump 读它）。 */
int moonui_native_prefers_reduced_motion(void) {
  int on;
  TRACE("prefers_reduced_motion");
  on = 0;
  @autoreleasepool {
    if ([[NSWorkspace sharedWorkspace]
            accessibilityDisplayShouldReduceMotion] != NO) {
      on = 1;
    }
  }
  return on;
}

/* 增强对比度（T87②）：accessibilityDisplayShouldIncreaseContrast，系统偏好
 * "增强对比度"开着时为 YES。首版只做读口；消费点（主题读数档）第二版接。 */
int moonui_native_prefers_high_contrast(void) {
  int on;
  TRACE("prefers_high_contrast");
  on = 0;
  @autoreleasepool {
    if ([[NSWorkspace sharedWorkspace]
            accessibilityDisplayShouldIncreaseContrast] != NO) {
      on = 1;
    }
  }
  return on;
}

/* ---- 事件循环 ---- */

void moonui_native_main_steps(void) {
  TRACE("main_steps");
  /* finishLaunching 把 App 变成真正在跑的 App（建主菜单、激活）。libui 的
   * uiMainSteps 在 darwin 侧干的就是这件事，这里直接做。 */
  @autoreleasepool {
    [NSApp finishLaunching];
  }
}

int moonui_native_main_step(int wait) {
  (void)wait;
  TRACE("main_step");
  if (moonui_native_loop_ended) {
    return 0;
  }
  @autoreleasepool {
    /* 泵一条事件：dequeue:YES 取出来、sendEvent: 分发。untilDate 用 distantPast
     * 表示"不等待"——有没有活可干由 MoonBit 侧先问 messages_pending，这里只负责
     * 把那条已知的消息处理掉。 */
    NSEvent *ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                     untilDate:[NSDate distantPast]
                                        inMode:NSDefaultRunLoopMode
                                       dequeue:YES];
    if (ev != nil) {
      [NSApp sendEvent:ev];
    }
  }
  return 1;
}

/* 只探测不取：dequeue:NO 之后那条消息还留在队列里，接着交给 main_step 处理。 */
int moonui_native_messages_pending(void) {
  int pending;
  TRACE("messages_pending");
  @autoreleasepool {
    pending = ([NSApp nextEventMatchingMask:NSEventMaskAny
                                  untilDate:[NSDate distantPast]
                                     inMode:NSDefaultRunLoopMode
                                    dequeue:NO] != nil)
                ? 1
                : 0;
  }
  return pending;
}

/* 等最多 ms 毫秒，看队列里有没有事件。返回 1 = 有，0 = 超时。 */
int moonui_native_wait_messages(int ms) {
  int got;
  TRACE("wait_messages");
  @autoreleasepool {
    NSDate *until = ms <= 0 ? [NSDate distantPast]
                            : [NSDate dateWithTimeIntervalSinceNow:
                                  (NSTimeInterval)ms / (NSTimeInterval)1000.0];
    got = ([NSApp nextEventMatchingMask:NSEventMaskAny
                              untilDate:until
                                 inMode:NSDefaultRunLoopMode
                                dequeue:NO] != nil)
            ? 1
            : 0;
  }
  return got;
}

/* 单调时钟：mach_absolute_time 是 Mac 上的对应物。时间基换算是常数比值，取一次
 * 存下来。 */
int64_t moonui_native_time_ms(void) {
  static mach_timebase_info_data_t base = {0, 0};
  uint64_t ticks;
  if (base.denom == 0) {
    mach_timebase_info(&base);
  }
  ticks = mach_absolute_time();
  if (base.denom == 0 || base.numer == 0) {
    return (int64_t)(ticks / 1000000ull);
  }
  return (int64_t)(ticks * (uint64_t)base.numer / (uint64_t)base.denom /
                   1000000ull);
}

void moonui_native_quit(void) {
  TRACE("quit");
  /* 只把循环标成"跑完了"，不真的退出进程：MoonBit 侧的收尾照常用 native_terminate
   * 走，进程等 main 返回才退。和 libui 的 steps 模式同一套语义。 */
  moonui_native_loop_ended = 1;
}

/* =====================================================================
 * 控件（FP2）：直写 AppKit 的 NSButton / NSTextField / NSSlider / …
 *
 * 和 libui 那份的分叉：libui 的控件是 uiControl 结构体、由 libui 持有并布局；
 * 这里的控件就是 NSView 本身，句柄直接是它的指针，生命周期归本文件的强引用表
 * （moonui_native_live_widgets）管，布局由 Core 算好绝对矩形、经 moonui_native_control_set_bounds
 * 摆进窗口的 contentView（§14：叶子控件的原生父级都是窗口）。
 *
 * 回调走两条路：
 *   - target-action（按钮/滑块/步进/下拉/日期）：view 的 target 指向全局的
 *     moonui_native_dispatcher，action 是 dispatch:，dispatcher 读 view 身上的槽位号去 fire。
 *   - delegate（文本框/多行文本）：view 的 delegate 指向 dispatcher（或容器自己），
 *     文本变化时读槽位号 fire。delegate 是 assign 语义、不 retain，所以没有
 *     NSNotificationCenter 那种"观察者还指着已释放对象"的 MRC 隐患。
 * ===================================================================== */

/* ---- 扁平可点文本行（§51 画册左栏）----
 *
 * 无边框、左对齐的按钮，选中态（state on）时自己画一块圆角高亮底——这就是
 * macOS 设置那种"一行一项、选中高亮"的菜单感。高亮用系统的
 * selectedContentBackgroundColor（浅色下是强调色），不硬编码颜色。
 *
 * 内边距（§51 的 MenuRow padding，CSS 语义）：加 padding 即背景长大——测量
 * 账（固有 = 文字 + insets）归 Core 的 `to_layout_spec` 一处记，这里只管画：
 * 高亮铺在按钮自己的 bounds 里，bounds 长大它自动长大；文字由自定义 cell 把
 * 标题框按 insets 往内缩一截再交给父类（缩进的框之外的截断、Dark Mode、无
 * 障碍文本模式都还是 cell 的活）。值由 moonui_native_widget_set_insets 写入（物理
 * 像素按控件 dpi 换成点），四个分量打包在一个 NSRect 里传：origin.x = start、
 * origin.y = top、size.width = end、size.height = bottom。 */
@interface MoonuiMenuRow : NSButton
- (NSRect)padding;
- (void)storePadding:(NSRect)p;
@end

@interface MoonuiMenuRowCell : NSButtonCell
@end

@implementation MoonuiMenuRow {
  NSRect padding; /* 见上：四边打包在一个 NSRect 里，零值 = 没设过 */
}
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    [self setCell:[[MoonuiMenuRowCell alloc] init]];
    [self setBordered:NO];
    [self setButtonType:NSButtonTypeMomentaryChange];
    [self setAlignment:NSTextAlignmentLeft];
    [self setLineBreakMode:NSLineBreakByTruncatingTail];
  }
  return self;
}

- (NSRect)padding {
  return padding;
}

- (void)storePadding:(NSRect)p {
  padding = p;
}

- (void)drawRect:(NSRect)dirtyRect {
  if (moonui_native_widget_selected_of(self)) {
    /* 左缘贴齐文字：文本左对齐、从按钮左缘起，高亮左缘也贴左缘（不内缩），
     * 否则整块蓝底会比文字偏右一截。右缘留 4pt、上下各 2pt 的呼吸空间。 */
    NSRect b = self.bounds;
    NSRect r = NSMakeRect(b.origin.x, b.origin.y + 2.0,
                          b.size.width - 4.0, b.size.height - 4.0);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:5.0 yRadius:5.0];
    [[NSColor selectedContentBackgroundColor] set];
    [p fill];
  }
  [super drawRect:dirtyRect];
}
@end

@implementation MoonuiMenuRowCell
/* 文字缩进是 padding 仅剩的绘制语义（高亮在上面 drawRect 里已铺满 bounds）：
 * 把标题框往内缩一截再交给父类画，不重写标题本身的任何绘制细节。 */
- (NSRect)drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)controlView {
  NSRect r = frame;
  if ([controlView isKindOfClass:[MoonuiMenuRow class]]) {
    NSRect pad = [(MoonuiMenuRow *)controlView padding];
    r = NSMakeRect(frame.origin.x + pad.origin.x,
                   frame.origin.y + pad.origin.y,
                   frame.size.width - pad.origin.x - pad.size.width,
                   frame.size.height - pad.origin.y - pad.size.height);
  }
  return [super drawTitle:title withFrame:r inView:controlView];
}
@end

/* ---- 单选组（§13 的 RadioButtons）----
 *
 * MoonUI 的 RadioButtons 是"一个原生控件 = 一组互斥选项"，而 AppKit 的单选组是
 * N 只独立的 NSButton。所以这里用一个容器 NSView 当句柄：append_option 往里加一只
 * 单选按钮，set_selected 决定哪只 on，点任意一只都 fire 容器身上的槽位。容器被
 * Core 摆进窗口后，layout 把里面的按钮纵向排开。 */
@interface MoonuiRadioGroup : NSView
@property(nonatomic, strong) NSMutableArray *buttons;
@end

@implementation MoonuiRadioGroup
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    self.buttons = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)layout {
  [super layout];
  CGFloat y = self.bounds.size.height;
  for (NSButton *b in self.buttons) {
    [b sizeToFit];
    NSRect f = b.frame;
    f.origin = NSMakePoint(0.0, y - f.size.height);
    b.frame = f;
    y -= f.size.height + 2.0;
  }
}

- (void)radioClicked:(NSButton *)sender {
  for (NSButton *b in self.buttons) {
    [b setState:(b == sender ? NSControlStateValueOn : NSControlStateValueOff)];
  }
  int slot = moonui_native_widget_slot_of(self);
  if (slot >= 0) {
    moonui_native_fire(&moonui_native_slots[slot]);
  }
}
@end

/* ---- 多行文本域（§13 的 MultilineEntry）----
 *
 * 句柄是 NSScrollView（Core 摆的是它的可见矩形），里面装一只 NSTextView。
 * 文本读写走 documentView；文本变化走 textDidChange:（本类是 text view 的
 * delegate），fire 容器身上的槽位。 */
@interface MoonuiMultiline : NSScrollView <NSTextViewDelegate>
@property(nonatomic, strong) NSTextView *textView;
@end

@implementation MoonuiMultiline
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    [self setBorderType:NSBezelBorder];
    [self setHasVerticalScroller:YES];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:self.bounds];
    [tv setMinSize:NSMakeSize(0, 0)];
    [tv setMaxSize:NSMakeSize(100000, 100000)];
    [tv setVerticallyResizable:YES];
    [tv setHorizontallyResizable:NO];
    [tv setAutoresizingMask:NSViewWidthSizable];
    [tv setDelegate:self];
    /* MRC 下 setDocumentView: 不 retain，text view 的 +1 归本容器的 strong 属性
     * 管（容器 dealloc 时松掉），否则它只被 alloc 钉着、永不释放。 */
    self.textView = tv;
    [self setDocumentView:tv];
  }
  return self;
}

- (void)textDidChange:(NSNotification *)note {
  (void)note;
  int slot = moonui_native_widget_slot_of(self);
  if (slot >= 0) {
    moonui_native_fire(&moonui_native_slots[slot]);
  }
}
@end

/* ---- 滚动视口（T74）----
 *
 * 句柄是 MoonuiNativeScroll（NSScrollView 子类），Core 摆的是它的可见矩形；文档区
 * 是翻转的 MoonuiNativeScrollDoc（y 向下，和 Core 的文档区坐标同向），子控件由
 * moonui_native_container_attach 挂进文档区。MRC 下 setDocumentView: 不 retain，
 * 文档区的 +1 归容器的 strong 属性管（和上面 Multiline 的 text view 同一套账）。
 * 滚动条用系统原生 NSScroller（样式随系统"显示滚动条"偏好：总是显示则常驻、
 * 自动则滚动时出现），不自绘。 */
@interface MoonuiNativeScrollDoc : NSView
@end

@implementation MoonuiNativeScrollDoc
- (BOOL)isFlipped {
  return YES;
}
@end

@interface MoonuiNativeScroll : NSScrollView
@property(nonatomic, strong) MoonuiNativeScrollDoc *doc;
@end

@implementation MoonuiNativeScroll
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    [self setBorderType:NSNoBorder];
    [self setHasVerticalScroller:NO];
    [self setHasHorizontalScroller:NO];
    MoonuiNativeScrollDoc *doc = [[MoonuiNativeScrollDoc alloc] init];
    self.doc = doc;
    [self setDocumentView:doc];
    [doc release];
  }
  return self;
}
@end

/* ---- 滑块宿主：竖推子的落点 ----
 *
 * NSSlider 的朝向在 init 里定死（`initWithFrame:` 按"高 > 宽"判竖排），之后
 * 再 `setFrame:` / `setFrameSize:` 一律改不回来——真机探针量过：横向 init
 * 出来的 NSSlider 拉成 22x140 仍报 `isVertical = 0`，拇指照旧横着走。而 Core
 * 手里的句柄是建控件那一刻给出去的指针、换不了（换成新建的那颗，之后每一次
 * set_value / on_changed 都打在野指针上）。
 *
 * 所以句柄给这只极薄的宿主，真滑块住它里面：宿主一被摆成"高 > 宽"，就按新
 * 朝向重建一颗滑块，并把范围/当前值/启用态/回调槽位原样搬过去。对 Core 来说
 * 一切照旧——句柄不变、事件回调不变、值/范围/样式仍走那几条 FFI。
 *
 * 顺带解决另一种退化：NSSlider 的 fittingSize 与子类无关，宿主直接转给里面
 * 那颗（固有高度归原生层，§18）。
 *
 * 局限：`-isVertical` 只在创建时判一次，所以"先横后竖"的宿主会重新造颗滑块
 * （代价是一次 alloc，换来的是拖动方向正确）。 */
@interface MoonuiNativeSliderHost : NSView
@property(nonatomic, strong) NSSlider *inner;
/// 竖排推子那条滑槽的颜色。槽画在 `drawRect:` 里——父视图先画、子视图后画，
/// 所以它天然垫在把手与滑块下面，不用跟 z 序较劲（两个兄弟视图的 z 序在
/// layer-backed 树上试过 `positioned:` 那套，实测不听话，槽会把把手切成两半）。
@property(nonatomic, strong) NSColor *groovePaint;
/// 竖排推子的把手。系统拇指在 26pt 宽的竖槽里又大又圆，像音量旋钮；竖排
/// 时把它盖掉、用这块扁方块，内侧滑块只剩拖动这一个职责。
@property(nonatomic, strong) NSView *thumb;
@property(nonatomic, assign) BOOL vertical;
- (void)setGrooveColor:(NSColor *)color;
- (void)setThumbColor:(NSColor *)color;
- (void)updateThumb;
@end

static void moonui_native_slider_sync_inner(MoonuiNativeSliderHost *h,
                                            NSSlider *s);

@implementation MoonuiNativeSliderHost
- (NSView *)hitTest:(NSPoint)p {
  /* 宿主自己不接鼠标（空视图也没有可拖的东西），一律递给里面的滑块。 */
  NSView *v = [super hitTest:p];
  return v == self ? nil : v;
}

- (NSSize)fittingSize {
  NSSlider *s = self.inner;
  return s != nil ? [s fittingSize] : [super fittingSize];
}

///|
/// 槽色（皮肤通道的 bg 走到这里）。只记颜色 + 标脏，画在下面的 drawRect 里
/// ——没有颜色时用一层很淡的白（setFrameSize 兜底），任何深色底上都读得出来。
- (void)setGrooveColor:(NSColor *)color {
  self.groovePaint = color;
  [self setNeedsDisplay:YES];
}

///|
/// 画槽：竖排时居中一条 6pt 宽的圆角竖条，上下各留 6pt。横排不画（交回
/// 系统那套细轨道）。
- (void)drawRect:(NSRect)dirty {
  NSRect b;
  NSRect r;
  [super drawRect:dirty];
  if (!self.vertical || self.groovePaint == nil) {
    return;
  }
  b = [self bounds];
  r = NSMakeRect((b.size.width - 6.0) / 2.0, 6.0, 6.0,
                 b.size.height > 12.0 ? b.size.height - 12.0 : b.size.height);
  [self.groovePaint setFill];
  [[NSBezierPath bezierPathWithRoundedRect:r xRadius:3.0 yRadius:3.0] fill];
}

///|
/// 把手色（皮肤通道的 fg 走到这里）。第一次调用顺手把把手建出来。
- (void)setThumbColor:(NSColor *)color {
  if (self.thumb == nil) {
    NSView *t = [[NSView alloc] initWithFrame:NSZeroRect];
    [t setWantsLayer:YES];
    [t layer].cornerRadius = 1.5;
    [t layer].borderWidth = 1.0;
    [t layer].borderColor =
        [NSColor colorWithSRGBRed:0.0 green:0.0 blue:0.0 alpha:0.55].CGColor;
    [self addSubview:t];
    self.thumb = t;
    [t release];
  }
  [self.thumb layer].backgroundColor = color.CGColor;
  [self updateThumb];
}

///|
/// 按内层滑块当前值摆把手（竖排：值大在上；横排：值大在右）。同时决定
/// 内层滑块要不要露出来——竖排时它只剩拖动职责，画面归自绘的槽与把手。
- (void)updateThumb {
  NSRect b = [self bounds];
  double lo, hi, v, t;
  CGFloat tw = 18.0;
  CGFloat th = 10.0;
  if (self.inner == nil) {
    return;
  }
  if (self.thumb != nil) {
    self.thumb.hidden = !self.vertical;
  }
  /* 竖排：系统的拇指太大，盖掉它（alpha 0 的视图照样吃鼠标，拖动不受影响）。
   * 横排：原样交给 AppKit，别把别人家的滑块画没了。 */
  [self.inner setAlphaValue:(self.vertical ? 0.0 : 1.0)];
  if (self.thumb == nil || !self.vertical) {
    return;
  }
  lo = [self.inner minValue];
  hi = [self.inner maxValue];
  v = [self.inner doubleValue];
  t = (hi > lo) ? (v - lo) / (hi - lo) : 0.0;
  if (t < 0.0) {
    t = 0.0;
  }
  if (t > 1.0) {
    t = 1.0;
  }
  CGFloat span = b.size.height - th;
  if (span < 0.0) {
    span = 0.0;
  }
  self.thumb.frame = NSMakeRect((b.size.width - tw) / 2.0, t * span, tw, th);
}

///|
/// 拖动：先让把手跟手，再把事件转给分发器（槽位仍按内层滑块反查）。
- (void)sliderMoved:(id)sender {
  int slot;
  [self updateThumb];
  slot = moonui_native_widget_slot_of((NSView *)sender);
  if (slot >= 0) {
    moonui_native_fire(&moonui_native_slots[slot]);
  }
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  NSRect b = [self bounds];
  if (b.size.width < 1.0 || b.size.height < 1.0) {
    return;
  }
  BOOL want_vertical = (b.size.height > b.size.width);
  if (self.inner == nil || want_vertical != self.vertical) {
    NSSlider *old = self.inner;
    /* initWithFrame: 就是判朝向的那一步——宽高按当前框给，句柄仍是宿主。 */
    NSSlider *s = [[NSSlider alloc] initWithFrame:b];
    if (old != nil) {
      [s setMinValue:[old minValue]];
      [s setMaxValue:[old maxValue]];
      [s setDoubleValue:[old doubleValue]];
      [s setEnabled:[old isEnabled]];
      [s setTarget:[old target]];
      [s setAction:[old action]];
    }
    /* 竖排推子一律用 small 控制尺寸：横排那颗大圆钮（24pt）在 26pt 宽的
     * 竖槽里会胖得盖住整条槽，small 的拇指才像"推子"。 */
    [s setControlSize:(want_vertical ? NSControlSizeSmall : NSControlSizeRegular)];
    [s setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    moonui_native_slider_sync_inner(self, s);
    [self addSubview:s];
    [old removeFromSuperview];
    self.inner = s;
    self.vertical = want_vertical;
    [s release];
  } else {
    [self.inner setFrame:b];
  }
  /* 槽在 drawRect 里画，这里只要标脏。默认色用一层很淡的白：没有皮肤色
   * 的时候，任何深色底上都读得出来。 */
  if (self.groovePaint == nil) {
    self.groovePaint = [NSColor colorWithSRGBRed:1.0
                                           green:1.0
                                            blue:1.0
                                           alpha:0.14];
  }
  [self setNeedsDisplay:YES];
  [self updateThumb];
}
@end

/* 把宿主的 kind 记号与回调槽位抄到里面那颗滑块上：分发器是从 sender（也就是
 * 这颗滑块）反查槽位的，槽位只记在宿主身上就永远 fire 不出来。 */
static void moonui_native_slider_sync_inner(MoonuiNativeSliderHost *h,
                                            NSSlider *s) {
  int slot;
  if (s == nil) {
    return;
  }
  moonui_native_mark_widget_kind((NSView *)s, 6);
  slot = moonui_native_widget_slot_of((NSView *)h);
  if (slot >= 0) {
    moonui_native_set_widget_slot((NSView *)s, slot);
  }
}

/* 句柄 → 真滑块。两条路都认：宿主（现在）与裸 NSSlider（老账/直接调用的测试）。 */
static NSSlider *moonui_native_slider_inner(moonui_ptr c) {
  NSView *v = (NSView *)(uintptr_t)c;
  if ([v isKindOfClass:[MoonuiNativeSliderHost class]]) {
    return [(MoonuiNativeSliderHost *)v inner];
  }
  return (NSSlider *)v;
}

/* ---- 回调分发器的实现 ----
 *
 * 接口与静态指针在文件前部（moonui_native_init 之前）已声明；这里只补实现。全局一只，
 * 替所有控件接 target-action 与文本 delegate。它不持有任何控件的强引用
 * （target/delegate 都是 assign），所以不会把已销毁的控件钉住。 */
@implementation MoonuiDispatcher
- (void)dispatch:(id)sender {
  int slot = moonui_native_widget_slot_of((NSView *)sender);
  if (slot >= 0) {
    moonui_native_fire(&moonui_native_slots[slot]);
  }
}

- (void)controlTextDidChange:(NSNotification *)note {
  int slot = moonui_native_widget_slot_of((NSView *)note.object);
  if (slot >= 0) {
    moonui_native_fire(&moonui_native_slots[slot]);
  }
  /* `T85②`：组合相位从 field editor 的标记串推（起始/进行/结束的推导与序列
   * 对齐见本文件末尾的 derive）。派发器只收单行文本框；多行组合的相位欠账
   * 挂在 T85② 的 Windows 真跑账里一并记。 */
  moonui_native_ime_derive((NSView *)note.object);
}
@end

/* 建一只控件的公共尾巴：打 kind 记号、进强引用表、松掉本地引用。返回 view 指针。
 * 调用方传进来的 v 是 alloc/init 出来的（+1），这里 addObject 再 +1、release -1，
 * 净剩表里那一份——和窗口同一套 MRC 看守。 */
static NSView *moonui_native_finish_widget(NSView *v, int kind) {
  if (v == nil) {
    return nil;
  }
  moonui_native_mark_widget_kind(v, kind);
  /* owner 记号（`T86①` 起命中反查用）：一次写下、之后只读，与 kind 记号同一套
   * 手法（adapter.h 的"反记一笔这是哪个 moonui_ptr"——本文件里指针就是 view）。 */
  objc_setAssociatedObject(v, moonui_native_owner_key, (id)(uintptr_t)1,
                           OBJC_ASSOCIATION_ASSIGN);
  @autoreleasepool {
    [moonui_native_live_widgets addObject:v];
  }
  [v release];
  return v;
}

/* ---- 构造 ---- */

moonui_ptr moonui_native_widget_new(int kind, const char *text, int text_len) {
  NSString *t;
  NSView *v = nil;
  TRACE("widget_new");
  @autoreleasepool {
    t = moonui_native_string_of(text, text_len);
    switch (kind) {
      case 0: {
        /* Label：只读、无边框、不画底的文本框。 */
        NSTextField *label = [[NSTextField alloc] init];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setBordered:NO];
        [label setDrawsBackground:NO];
        [label setStringValue:t];
        v = label;
        break;
      }
      case 1: {
        NSButton *btn = [[NSButton alloc] init];
        [btn setButtonType:NSButtonTypeMomentaryPushIn];
        [btn setBezelStyle:NSBezelStyleRounded];
        [btn setTitle:t];
        v = btn;
        break;
      }
      case 2: {
        NSTextField *field = [[NSTextField alloc] init];
        [field setEditable:YES];
        [field setSelectable:YES];
        [field setBordered:YES];
        [field setBezelStyle:NSTextFieldSquareBezel];
        [field setStringValue:t];
        v = field;
        break;
      }
      case 3: {
        NSButton *cb = [[NSButton alloc] init];
        [cb setButtonType:NSButtonTypeSwitch];
        [cb setTitle:t];
        v = cb;
        break;
      }
      case 4: {
        NSSecureTextField *field = [[NSSecureTextField alloc] init];
        [field setStringValue:t];
        v = field;
        break;
      }
      case 5:
      case 13: {
        /* 分隔线：NSBox 的 separator 型，横竖由 Core 给的矩形决定（宽>高=横）。
         * separator 型自己画那条线，不需要再设 border（setBorderType: 已废弃）。 */
        NSBox *box = [[NSBox alloc] init];
        [box setBoxType:NSBoxSeparator];
        v = box;
        break;
      }
      case 14: {
        /* 扁平可点文本行（§51 画册左栏）。 */
        MoonuiMenuRow *row = [[MoonuiMenuRow alloc] init];
        [row setTitle:t];
        v = row;
        break;
      }
      case 15: {
        /* 滚动视口（T74）：句柄是 NSScrollView，滚动行程由
         * moonui_native_scroll_set_content 后续给出。 */
        v = [[MoonuiNativeScroll alloc] init];
        break;
      }
      case 16: {
        /* 图像（`T86⑤`）：绘制归原生 Image view（开工决策记在 TODO `T86⑤`）。
         * editable=NO：它不是文本框，拖进来的文件 URL 不进它的图像源。 */
        NSImageView *iv = [[NSImageView alloc] init];
        [iv setEditable:NO];
        [iv setImageScaling:NSImageScaleProportionallyUpOrDown];
        v = iv;
        break;
      }
      case 17: {
        /* 自绘面板（皮肤账的载体）：纯背景 view，背景/圆角由
         * moonui_native_widget_set_style 推给 layer。 */
        NSView *panel = [[NSView alloc] init];
        [panel setWantsLayer:YES];
        v = panel;
        break;
      }
      default:
        v = nil;
        break;
    }
  }
  v = moonui_native_finish_widget(v, kind);
  return (moonui_ptr)(uintptr_t)v;
}

/* 0xRRGGBB → sRGB 的 NSColor。
 *
 * 为什么不是 `colorWithCalibratedRed:`（这里原来用的那支）：calibrated 是
 * **generic RGB**（gamma 1.8），画进 sRGB 位图 / 屏幕上时系统会做一次色彩
 * 空间换算，每个通道都被抬亮十几个百分点。皮肤里写 0x4A85BA 的脸面蓝，量
 * 出来是 (105,151,194)；写 0x1F4468 的顶条，量出来是 (51,86,120)——整片界面
 * 看上去发灰发白，跟"这套配色本来该有的浓度"对不上（真窗取证量出来的账）。
 * sRGB 那支不做换算：写多少，屏上就是多少。 */
static NSColor *moonui_native_srgb_color(int64_t rgb) {
  return [NSColor colorWithSRGBRed:(CGFloat)((rgb >> 16) & 0xFF) / 255.0
                             green:(CGFloat)((rgb >> 8) & 0xFF) / 255.0
                              blue:(CGFloat)(rgb & 0xFF) / 255.0
                             alpha:1.0];
}

/* 样式下发（adapter.h 的皮肤通道）。三处定点消费（§32 的豁免只破这三处）：
 * - Panel：layer 背景色 + 圆角
 * - Label（NSTextField）：文字色 + 字体（字号/字重）
 * - Button（NSButton）：文字色/字体走 attributed title；设了背景色时取系统
 *   bezel 改为 layer 平面底（网易云那类"平面按钮"的形状）。
 * 其余 kind 静默忽略。mac 的 NSView 在 layer-backed 下改 backgroundColor
 * 即时生效；字体变化影响固有尺寸，widget_intrinsic_size 问的是真控件，
 * 测量自动跟上（§18）。 */
int moonui_native_widget_set_style(moonui_ptr c,
                                   int64_t bg_rgb,
                                   int64_t fg_rgb,
                                   int radius_permille,
                                   int font_permille,
                                   int weight) {
  NSView *v;
  int kind;
  TRACE("widget_set_style");
  v = (NSView *)(uintptr_t)c;
  if (v == nil) {
    return -1;
  }
  /* kind_of 已经把"存 kind+1、读回原值"的换算做掉了（内部那行 -1），这里
   * 直接拿——再减一次会把 Button(1) 错读成 Label(0)，给 NSButton 发
   * setTextColor: 直接 NSException。 */
  kind = moonui_native_widget_kind_of(v);
  if (kind == 17) {
    @autoreleasepool {
      if (bg_rgb >= 0) {
        [v layer].backgroundColor = moonui_native_srgb_color(bg_rgb).CGColor;
      }
      if (radius_permille >= 0) {
        [v layer].cornerRadius = (CGFloat)radius_permille / 1000.0;
      }
    }
    return 0;
  }
  if (kind == 0) {
    /* Label：NSTextField。颜色/字体直接改，固有尺寸随真控件变。 */
    @autoreleasepool {
      NSTextField *label = (NSTextField *)v;
      NSFont *font = [label font];
      if (font_permille >= 0) {
        CGFloat size = (CGFloat)font_permille / 1000.0;
        if (weight == 2) {
          font = [NSFont boldSystemFontOfSize:size];
        } else {
          /* Medium 一档 AppKit 没有直接 API，退 Regular——字重通道只兑现
           * Regular/Bold 两档（与 mock 的 is_bold 判据同一把尺）。 */
          font = [NSFont systemFontOfSize:size];
        }
        [label setFont:font];
      }
      if (fg_rgb >= 0) {
        [label setTextColor:moonui_native_srgb_color(fg_rgb)];
      }
    }
    return 0;
  }
  if (kind == 1) {
    /* Button：文字色/字体走 attributed title；背景/圆角只在显式给过时吃
     * （Core 的 App::dispatch 那侧管着"与主题底同值 = 继承"的闸门——到这的
     * bg_rgb/fg_rgb 已经是显式值或 -1）。摘 bezel 画 layer 平面底。 */
    @autoreleasepool {
      NSButton *btn = (NSButton *)v;
      NSString *title = [btn title];
      NSFont *font = [btn font];
      NSColor *color = nil;
      if (fg_rgb >= 0) {
        color = moonui_native_srgb_color(fg_rgb);
      }
      if (font_permille >= 0) {
        CGFloat size = (CGFloat)font_permille / 1000.0;
        if (weight == 2) {
          font = [NSFont boldSystemFontOfSize:size];
        } else {
          font = [NSFont systemFontOfSize:size];
        }
      }
      if (color != nil || font_permille >= 0) {
        if (color == nil) {
          color = [NSColor controlTextColor];
        }
        NSDictionary *attrs = @{
          NSFontAttributeName: font,
          NSForegroundColorAttributeName: color,
        };
        [btn setAttributedTitle:[[NSAttributedString alloc]
            initWithString:title attributes:attrs]];
      }
      if (bg_rgb >= 0) {
        [btn setWantsLayer:YES];
        [btn layer].backgroundColor = moonui_native_srgb_color(bg_rgb).CGColor;
        [btn setBordered:NO];
        if (radius_permille >= 0) {
          [btn layer].cornerRadius = (CGFloat)radius_permille / 1000.0;
        }
      }
    }
    return 0;
  }
  if (kind == 6) {
    /* Slider：这里的 bg 不是"控件底色"，而是**滑槽**色、fg 是**把手**色。
     * 竖排推子的槽与把手都由宿主自绘（系统轨道失焦会淡到看不见、系统拇指
     * 又大又圆，见 MoonuiNativeSliderHost）；横排两样都不画，交回 AppKit。 */
    @autoreleasepool {
      if ([v isKindOfClass:[MoonuiNativeSliderHost class]]) {
        MoonuiNativeSliderHost *host = (MoonuiNativeSliderHost *)v;
        if (bg_rgb >= 0) {
          [host setGrooveColor:moonui_native_srgb_color(bg_rgb)];
        }
        if (fg_rgb >= 0) {
          [host setThumbColor:moonui_native_srgb_color(fg_rgb)];
        }
      }
    }
    return 0;
  }
  return 0;
}

/* 图标（皮肤账的按钮段）：SF Symbols 按名取图，摘 bezel 只剩图。
 * 取不到（老系统/名字不认识）返回 -1，调用方保持文本外观。 */
int moonui_native_widget_set_icon(moonui_ptr c, const char *name, int name_len) {
  NSView *v;
  NSButton *btn;
  NSImage *img;
  NSString *sym;
  TRACE("widget_set_icon");
  v = (NSView *)(uintptr_t)c;
  if (v == nil) {
    return -1;
  }
  if (moonui_native_widget_kind_of(v) != 1) { /* 仅 Button */
    return -2;
  }
  sym = [[NSString alloc] initWithBytes:name length:(NSUInteger)name_len
                               encoding:NSUTF8StringEncoding];
  if (sym == nil) {
    return -1;
  }
  /* SF Symbols 是 macOS 11 起的 API（NSImage 那侧的入口是
   * imageWithSystemSymbolName:accessibilityDescription:——UIKit 的
   * imageWithSystemName: 在 AppKit 上不存在，写错选择子是真窗上的
   * NSException），老系统上缺席——图标是装饰性事实，缺席就保持文本
   * 外观（皮肤通道的契约），不挡流程。 */
  if (@available(macOS 11.0, *)) {
    img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
  } else {
    img = nil;
  }
  if (img == nil) {
    return -1;
  }
  @autoreleasepool {
    btn = (NSButton *)v;
    [btn setWantsLayer:YES];
    [btn setBordered:NO];
    [btn setImage:img];
    [btn setImagePosition:NSImageOnly];
    [btn setImageScaling:NSImageScaleProportionallyDown];
  }
  return 0;
}

void moonui_native_widget_destroy(moonui_ptr c) {
  NSView *v;
  TRACE("widget_destroy");
  v = (NSView *)(uintptr_t)c;
  /* 先松开替这个控件看守的回调引用，再从 superview 和强引用表都摘掉——MRC 下
   * addSubview 不 retain，表是唯一的 owner，摘掉最后一份引用它自己 dealloc。 */
  moonui_native_forget((void *)(uintptr_t)c, 0);
  @autoreleasepool {
    [v removeFromSuperview];
    [moonui_native_live_widgets removeObject:v];
  }
}

/* ---- 图像源（`T86⑤`，解码归平台——开工决策记在 TODO `T86⑤`）----
 *
 * 解码走 NSImage 的两条 initWith（文件/数据）：mac 半就是二十行（挂账时量过的
 * 那笔账），MoonBit 侧零解码、平台侧零自绘。装进去的整源替换：后一次覆盖前
 * 一次（NSImageView 自己持有 image， setImage 就是替换）。返回码：0 = 装上了；
 * -1 = 解码失败（路径不存在 / 数据不是平台认得的编码格式，§33 调用方错）；
 * -2 = 句柄不指图像控件（kind 记号不是 16）。 */

static int moonui_native_image_set(NSImageView *iv, NSImage *img) {
  if (img == nil) {
    return -1;
  }
  @autoreleasepool {
    [iv setImage:img];
    [img release];
  }
  return 0;
}

int moonui_native_image_set_path(moonui_ptr c, const char *path, int path_len) {
  NSImageView *iv;
  NSString *file;
  NSImage *img;
  TRACE("image_set_path");
  iv = (NSImageView *)(uintptr_t)c;
  if (iv == nil || moonui_native_widget_kind_of((NSView *)(uintptr_t)c) != 16) {
    return -2;
  }
  @autoreleasepool {
    file = moonui_native_string_of(path, path_len);
    img = [[NSImage alloc] initWithContentsOfFile:file];
    return moonui_native_image_set(iv, img);
  }
}

int moonui_native_image_set_data(moonui_ptr c, const char *data, int data_len) {
  NSImageView *iv;
  NSImage *img;
  TRACE("image_set_data");
  iv = (NSImageView *)(uintptr_t)c;
  if (iv == nil || moonui_native_widget_kind_of((NSView *)(uintptr_t)c) != 16) {
    return -2;
  }
  if (data == 0 || data_len <= 0) {
    return -1;
  }
  @autoreleasepool {
    img = [[NSImage alloc] initWithData:[NSData dataWithBytes:(const void *)data
                                                       length:(NSUInteger)data_len]];
    return moonui_native_image_set(iv, img);
  }
}

/* ---- 文本 ---- */

void moonui_native_widget_set_text(moonui_ptr c, const char *text, int text_len) {
  NSString *t;
  int kind;
  TRACE("widget_set_text");
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    t = moonui_native_string_of(text, text_len);
    switch (kind) {
      case 0: /* Label */
      case 2: /* TextInput */
      case 4: /* PasswordInput */
        [(NSTextField *)(uintptr_t)c setStringValue:t];
        break;
      case 1: /* Button */
      case 3: /* Checkbox */
      case 14: /* MenuRow */
        [(NSButton *)(uintptr_t)c setTitle:t];
        break;
      case 10: /* MultilineEntry */
        [(NSTextView *)[((MoonuiMultiline *)(uintptr_t)c) documentView] setString:t];
        break;
      default:
        break;
    }
  }
}

moonbit_bytes_t moonui_native_widget_text(moonui_ptr c) {
  NSString *s;
  int kind;
  TRACE("widget_text");
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    switch (kind) {
      case 0:
      case 2:
      case 4:
        s = [(NSTextField *)(uintptr_t)c stringValue];
        break;
      case 1:
      case 3:
      case 14:
        s = [(NSButton *)(uintptr_t)c title];
        break;
      case 10:
        s = [(NSTextView *)[((MoonuiMultiline *)(uintptr_t)c) documentView] string];
        break;
      default:
        s = @"";
        break;
    }
  }
  return moonui_native_bytes_of([s UTF8String]);
}

/* ---- 勾选态（Checkbox 与 MenuRow 共用）----
 *
 * Checkbox 走 NSButton 的 state（系统画勾选框）；MenuRow 走关联对象里的选中态
 * （自己画高亮底，见 MoonuiMenuRow.drawRect）。两条路都经 set_checked/checked
 * 这对入口，Core 不感知差别。 */

void moonui_native_widget_set_checked(moonui_ptr c, int checked) {
  NSView *v;
  int kind;
  TRACE("widget_set_checked");
  v = (NSView *)(uintptr_t)c;
  kind = moonui_native_widget_kind_of(v);
  @autoreleasepool {
    if (kind == 14) { /* MenuRow */
      moonui_native_mark_widget_selected(v, checked);
      [v setNeedsDisplay:YES];
    } else { /* Checkbox（其余 kind 不该走到这，Core 已挡） */
      NSButton *b = (NSButton *)v;
      [b setState:(checked ? NSControlStateValueOn : NSControlStateValueOff)];
      [b setNeedsDisplay:YES];
    }
  }
}

int moonui_native_widget_checked(moonui_ptr c) {
  NSView *v;
  int kind;
  int on;
  TRACE("widget_checked");
  v = (NSView *)(uintptr_t)c;
  kind = moonui_native_widget_kind_of(v);
  @autoreleasepool {
    if (kind == 14) { /* MenuRow */
      on = moonui_native_widget_selected_of(v);
    } else { /* Checkbox */
      on = [(NSButton *)v state] == NSControlStateValueOn ? 1 : 0;
    }
  }
  return on;
}

/* ---- 可见 / 可用 ---- */

void moonui_native_widget_set_visible(moonui_ptr c, int visible) {
  TRACE("widget_set_visible");
  @autoreleasepool { [(NSView *)(uintptr_t)c setHidden:(visible ? NO : YES)]; }
}

int moonui_native_widget_visible(moonui_ptr c) {
  int visible;
  TRACE("widget_visible");
  @autoreleasepool { visible = ![(NSView *)(uintptr_t)c isHidden]; }
  return visible;
}

void moonui_native_widget_set_enabled(moonui_ptr c, int enabled) {
  NSView *v;
  TRACE("widget_set_enabled");
  v = (NSView *)(uintptr_t)c;
  @autoreleasepool {
    /* setEnabled: 是 NSControl 的方法，不是 NSView 的——分隔线（NSBox）、单选组
     * 容器、多行文本容器都不是 control，对它们设 enabled 没有意义，跳过。
     * 滑块宿主同理不是 control：它的"可不可拖"在里面的 NSSlider 上。 */
    if ([v isKindOfClass:[MoonuiNativeSliderHost class]]) {
      [[(MoonuiNativeSliderHost *)v inner] setEnabled:(enabled ? YES : NO)];
    } else if ([v isKindOfClass:[NSControl class]]) {
      [(NSControl *)v setEnabled:(enabled ? YES : NO)];
    }
  }
}

int moonui_native_widget_enabled(moonui_ptr c) {
  NSView *v;
  int enabled;
  TRACE("widget_enabled");
  v = (NSView *)(uintptr_t)c;
  @autoreleasepool {
    if ([v isKindOfClass:[MoonuiNativeSliderHost class]]) {
      enabled = [[(MoonuiNativeSliderHost *)v inner] isEnabled];
    } else {
      enabled = [v isKindOfClass:[NSControl class]] ? [(NSControl *)v isEnabled] : 1;
    }
  }
  return enabled;
}

/* ---- 不透明度（T84 动画通道）----
 * §32 豁免在这里破的正是这一条：NSView 自带 alphaValue，逐帧 set 便宜。
 * 收千分比整数（FFI 只有整数，MoonBit 侧换算），出界夹紧。样式那份
 * （颜色/圆角/字体）照旧不读——除 opacity 外豁免不动。 */
void moonui_native_widget_set_opacity(moonui_ptr c, int opacity) {
  NSView *v;
  TRACE("widget_set_opacity");
  if (opacity < 0) {
    opacity = 0;
  }
  if (opacity > 1000) {
    opacity = 1000;
  }
  v = (NSView *)(uintptr_t)c;
  @autoreleasepool { [v setAlphaValue:(opacity / 1000.0)]; }
}

/* ---- 度量与摆放 ---- */

/* 固有尺寸：原生控件自己的 fittingSize（字体度量属于原生层，§18）。
 *
 * 退化名单上不止三类：NSSlider / NSProgressIndicator 的 fittingSize 宽是
 * 0~4pt、MoonuiRadioGroup 是 0×0，而**输入框家族**（TextInput /
 * PasswordInput / Spinbox / ComboBox / MultilineEntry）空内容时宽也只有
 * 2pt（bezel 的边）——照报会把输入框摆成一条 2px 的竖缝。Windows 半对
 * 这些给的是固定/按子项算的固有尺寸（adapter_native.c 的 minimum_size
 * 同表：输入框家族 107 DLU、Slider 107 DLU、Progress 237 DLU、Radio 按
 * 最宽一行×行数），mac 半这里补上同款形状：Slider/Progress/输入框家族给
 * 固定宽（高仍走 fittingSize，那维是对的），RadioButtons 按子按钮算（与
 * MoonuiRadioGroup 的 layout 同账——sizeToFit 后纵向叠、2pt 缝）。 */
int64_t moonui_native_widget_minimum_size(moonui_ptr c) {
  NSView *v;
  NSView *content;
  NSSize fit;
  CGFloat scale;
  int kind;
  TRACE("widget_minimum_size");
  v = (NSView *)(uintptr_t)c;
  @autoreleasepool {
    [v layoutSubtreeIfNeeded];
    fit = [v fittingSize];
    content = [v superview];
  }
  scale = content != nil ? moonui_native_window_scale_of([content window]) : moonui_native_system_scale();
  kind = moonui_native_widget_kind_of(v);
  if (kind == 6 || kind == 8) { /* Slider / Progress：宽退化，给固定宽（高走 fittingSize） */
    return moonui_native_pack2(moonui_native_pt_to_px(120.0, scale),
                          moonui_native_pt_to_px(fit.height, scale));
  }
  if (kind == 2 || kind == 4 || kind == 7 || kind == 9 || kind == 10) {
    /* 输入框家族（TextInput / PasswordInput / Spinbox / ComboBox /
     * MultilineEntry）：空的 NSTextField fittingSize 宽只有 2pt（bezel 的
     * 边），照报会把输入框摆成一条 2px 的竖缝。与 Windows 半同表（那边给
     * 107 DLU 固定宽）——固定 120pt，高走 fittingSize。 */
    return moonui_native_pack2(moonui_native_pt_to_px(120.0, scale),
                          moonui_native_pt_to_px(fit.height, scale));
  }
  if (kind == 11) { /* RadioButtons：0×0，按子按钮算（与 layout 同账） */
    MoonuiRadioGroup *g = (MoonuiRadioGroup *)(uintptr_t)c;
    CGFloat w = 0.0;
    CGFloat h = 0.0;
    NSUInteger i;
    @autoreleasepool {
      for (i = 0; i < g.buttons.count; i++) {
        NSSize bs = [g.buttons[i] fittingSize]; /* 不 sizeToFit：measure 期不改子按钮 frame */
        if (bs.width > w) {
          w = bs.width;
        }
        h += bs.height;
      }
      if (g.buttons.count > 0) {
        h += 2.0 * (g.buttons.count - 1);
      }
    }
    return moonui_native_pack2(moonui_native_pt_to_px(w, scale),
                          moonui_native_pt_to_px(h, scale));
  }
  return moonui_native_pack2(moonui_native_pt_to_px(fit.width, scale),
                      moonui_native_pt_to_px(fit.height, scale));
}

int moonui_native_widget_dpi(moonui_ptr c) {
  NSView *v;
  NSWindow *win;
  CGFloat scale;
  TRACE("widget_dpi");
  v = (NSView *)(uintptr_t)c;
  win = [v window];
  scale = win != nil ? moonui_native_window_scale_of(win) : moonui_native_system_scale();
  return moonui_native_dpi_of_scale(scale);
}

/* ---- 内边距（§51 的 MenuRow padding）----
 *
 * 只对 MenuRow 有意义（Core 已挡；Padding 容器没有原生对象，走不到这）。
 * 物理像素按控件 dpi 换成点再存，口径同 moonui_native_control_set_bounds。测量侧
 * （固有 = 文字 + insets）归 Core，这里只存给绘制读（见 MoonuiMenuRow 的
 * padding 与 MoonuiMenuRowCell 的 drawTitle）。 */

void moonui_native_widget_set_insets(moonui_ptr c, int top, int end, int bottom, int start) {
  NSView *v;
  CGFloat scale;
  TRACE("widget_set_insets");
  v = (NSView *)(uintptr_t)c;
  if (moonui_native_widget_kind_of(v) != 14) { /* MenuRow */
    return;
  }
  scale = moonui_native_widget_dpi(c) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  @autoreleasepool {
    NSRect p = NSMakeRect(moonui_native_px_to_pt(start, scale), moonui_native_px_to_pt(top, scale),
                          moonui_native_px_to_pt(end, scale), moonui_native_px_to_pt(bottom, scale));
    [(MoonuiMenuRow *)v storePadding:p];
    [v setNeedsDisplay:YES];
  }
}

/* 相对父窗口客户区的左上角，物理像素（y 向下）。 */
int64_t moonui_native_widget_origin(moonui_ptr c) {
  NSView *v;
  NSView *content;
  NSPoint o;
  NSRect f;
  CGFloat scale;
  TRACE("widget_origin");
  v = (NSView *)(uintptr_t)c;
  @autoreleasepool {
    content = [v superview];
    f = [v frame];
    o = [v convertPoint:NSMakePoint(0, 0) toView:content];
  }
  scale = moonui_native_widget_dpi(c) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  if (content == nil) {
    return moonui_native_pack2(0, 0);
  }
  /* 父级翻转（T74 滚动文档区）时坐标系已经 y 向下，直接读；否则翻回 y 向上。 */
  if ([content isFlipped]) {
    return moonui_native_pack2(moonui_native_pt_to_px(o.x, scale), moonui_native_pt_to_px(o.y, scale));
  }
  return moonui_native_pack2(
      moonui_native_pt_to_px(o.x, scale),
      moonui_native_pt_to_px([content bounds].size.height - o.y - f.size.height, scale));
}

int64_t moonui_native_widget_size(moonui_ptr c) {
  NSRect f;
  CGFloat scale;
  TRACE("widget_size");
  @autoreleasepool { f = [(NSView *)(uintptr_t)c frame]; }
  scale = moonui_native_widget_dpi(c) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  return moonui_native_pack2(moonui_native_pt_to_px(f.size.width, scale),
                      moonui_native_pt_to_px(f.size.height, scale));
}

/* ---- 回调注册 ---- */

/* target-action 那条路：按钮/滑块/步进/下拉/日期都走它。 */
static int moonui_native_wire_action(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  NSView *v;
  int slot;
  v = (NSView *)(uintptr_t)c;
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_widget_slot(v, slot);
  @autoreleasepool {
    [(NSControl *)v setTarget:moonui_native_dispatcher];
    [(NSControl *)v setAction:@selector(dispatch:)];
  }
  return 0;
}

int moonui_native_widget_on_clicked(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("widget_on_clicked");
  return moonui_native_wire_action(c, fn, closure);
}

int moonui_native_widget_on_toggled(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("widget_on_toggled");
  return moonui_native_wire_action(c, fn, closure);
}

/* 文本 delegate 那条路：单行文本框走它（delegate 是 assign，无 MRC 隐患）。 */
int moonui_native_widget_on_text_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  NSView *v;
  int slot;
  v = (NSView *)(uintptr_t)c;
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_widget_slot(v, slot);
  @autoreleasepool {
    [(NSTextField *)v setDelegate:moonui_native_dispatcher];
  }
  return 0;
}

int moonui_native_slider_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  NSView *v;
  NSSlider *s;
  int slot;
  TRACE("slider_on_changed");
  /* 不走 wire_action：那是按"句柄本身就是 NSControl"写的，而滑块的句柄是宿主
   * （普通 NSView），对宿主 setTarget: 会当场认不出选择器。target/action 要落在
   * 里面那颗滑块上，槽位仍记在宿主（句柄）身上，再抄到内层给分发器反查。 */
  v = (NSView *)(uintptr_t)c;
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_widget_slot(v, slot);
  @autoreleasepool {
    s = moonui_native_slider_inner(c);
    if ([v isKindOfClass:[MoonuiNativeSliderHost class]]) {
      moonui_native_slider_sync_inner((MoonuiNativeSliderHost *)v, s);
      /* 竖排推子的把手是自绘的，拖动时要先跟手：target 落在宿主上，宿主
       * 更新把手位置后再把事件转给分发器。 */
      [s setTarget:v];
      [s setAction:@selector(sliderMoved:)];
      [(MoonuiNativeSliderHost *)v updateThumb];
    } else {
      moonui_native_mark_widget_kind((NSView *)s, 6);
      [s setTarget:moonui_native_dispatcher];
      [s setAction:@selector(dispatch:)];
    }
  }
  return 0;
}

int moonui_native_spinbox_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("spinbox_on_changed");
  return moonui_native_wire_action(c, fn, closure);
}

int moonui_native_combobox_on_selected(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("combobox_on_selected");
  return moonui_native_wire_action(c, fn, closure);
}

int moonui_native_datepicker_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("datepicker_on_changed");
  return moonui_native_wire_action(c, fn, closure);
}

/* 单选组：槽位记在容器上，radioClicked: 读它 fire（按钮在 append_option 里建）。 */
int moonui_native_radio_on_selected(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  int slot;
  TRACE("radio_on_selected");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_widget_slot((NSView *)(uintptr_t)c, slot);
  return 0;
}

/* 多行文本：槽位记在容器上，textDidChange: 读它 fire（delegate 在 init 里就设好）。 */
int moonui_native_multiline_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  int slot;
  TRACE("multiline_on_changed");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_widget_slot((NSView *)(uintptr_t)c, slot);
  return 0;
}

/* ---- 扩展控件的构造 ---- */

moonui_ptr moonui_native_slider_new(int min, int max) {
  MoonuiNativeSliderHost *host;
  NSSlider *s;
  TRACE("slider_new");
  @autoreleasepool {
    /* 句柄是宿主，里面那颗滑块等第一次 setFrameSize: 时按框的朝向再建
     * （见 MoonuiNativeSliderHost）。这里先给一颗横向的，好让创建后、
     * 还没摆过框的那一小段也能读值/设范围。 */
    s = [[NSSlider alloc] initWithFrame:NSMakeRect(0.0, 0.0, 140.0, 22.0)];
    [s setMinValue:(double)min];
    [s setMaxValue:(double)max];
    [s setIntValue:min];
    host = [[MoonuiNativeSliderHost alloc] init];
    [host addSubview:s];
    host.inner = s;
    host.vertical = NO;
    [s release];
  }
  return (moonui_ptr)(uintptr_t)moonui_native_finish_widget(host, 6);
}

void moonui_native_slider_set_range(moonui_ptr c, int min, int max) {
  TRACE("slider_set_range");
  @autoreleasepool {
    NSSlider *s = moonui_native_slider_inner(c);
    [s setMinValue:(double)min];
    [s setMaxValue:(double)max];
  }
}

moonui_ptr moonui_native_spinbox_new(int min, int max) {
  NSStepper *s;
  TRACE("spinbox_new");
  @autoreleasepool {
    s = [[NSStepper alloc] init];
    [s setMinValue:(double)min];
    [s setMaxValue:(double)max];
    [s setIncrement:1.0];
    [s setIntValue:min];
  }
  return (moonui_ptr)(uintptr_t)moonui_native_finish_widget(s, 7);
}

moonui_ptr moonui_native_progress_new(void) {
  NSProgressIndicator *p;
  TRACE("progress_new");
  @autoreleasepool {
    p = [[NSProgressIndicator alloc] init];
    [p setStyle:NSProgressIndicatorStyleBar];
    [p setMinValue:0.0];
    [p setMaxValue:100.0];
    [p setDoubleValue:0.0];
  }
  return (moonui_ptr)(uintptr_t)moonui_native_finish_widget(p, 8);
}

moonui_ptr moonui_native_combobox_new(void) {
  NSPopUpButton *cb;
  TRACE("combobox_new");
  @autoreleasepool {
    cb = [[NSPopUpButton alloc] init];
    [cb setPullsDown:NO];
  }
  return (moonui_ptr)(uintptr_t)moonui_native_finish_widget(cb, 9);
}

moonui_ptr moonui_native_radio_new(void) {
  MoonuiRadioGroup *g;
  TRACE("radio_new");
  @autoreleasepool { g = [[MoonuiRadioGroup alloc] init]; }
  return (moonui_ptr)(uintptr_t)moonui_native_finish_widget(g, 11);
}

moonui_ptr moonui_native_multiline_new(void) {
  MoonuiMultiline *m;
  TRACE("multiline_new");
  @autoreleasepool { m = [[MoonuiMultiline alloc] init]; }
  return (moonui_ptr)(uintptr_t)moonui_native_finish_widget(m, 10);
}

moonui_ptr moonui_native_datepicker_new(void) {
  NSDatePicker *dp;
  TRACE("datepicker_new");
  @autoreleasepool {
    dp = [[NSDatePicker alloc] init];
    /* 现代 API：外观用 datePickerStyle（TextFieldAndStepper = 旧"文本+时间"那支），
     * 显示哪些字段用 datePickerElements 的位组合。旧 NSDatePickerModeTextAndTime /
     * NSYearMonthDay…DatePickerElement 那套常量已废弃。 */
    [dp setDatePickerStyle:NSDatePickerStyleTextFieldAndStepper];
    [dp setDatePickerElements:NSDatePickerElementFlagYearMonthDay |
                              NSDatePickerElementFlagHourMinuteSecond];
  }
  return (moonui_ptr)(uintptr_t)moonui_native_finish_widget(dp, 12);
}

/* 日期时间文本约定 "YYYY-MM-DD HH:MM:SS"（§13）。 */
static NSDateFormatter *moonui_native_date_formatter(void) {
  static NSDateFormatter *fmt = nil;
  if (fmt == nil) {
    fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
  }
  return fmt;
}

int moonui_native_datepicker_set_text(moonui_ptr c, const char *text, int text_len) {
  NSString *t;
  NSDate *d;
  TRACE("datepicker_set_text");
  @autoreleasepool {
    t = moonui_native_string_of(text, text_len);
    d = [moonui_native_date_formatter() dateFromString:t];
    if (d == nil) {
      return -1;
    }
    [(NSDatePicker *)(uintptr_t)c setDateValue:d];
  }
  return 0;
}

moonbit_bytes_t moonui_native_datepicker_text(moonui_ptr c) {
  NSString *s;
  TRACE("datepicker_text");
  @autoreleasepool {
    s = [moonui_native_date_formatter()
        stringFromDate:[(NSDatePicker *)(uintptr_t)c dateValue]];
  }
  return moonui_native_bytes_of([s UTF8String]);
}

/* ---- 通用属性入口：按创建时记下的 kind 分派 ---- */

void moonui_native_widget_set_value(moonui_ptr c, int v) {
  int kind;
  TRACE("widget_set_value");
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    switch (kind) {
      case 6: /* Slider（句柄可能是宿主，取里面那颗）*/
        [moonui_native_slider_inner(c) setDoubleValue:(double)v];
        if ([(NSView *)(uintptr_t)c
                isKindOfClass:[MoonuiNativeSliderHost class]]) {
          [(MoonuiNativeSliderHost *)(uintptr_t)c updateThumb];
        }
        break;
      case 7: /* Spinbox */
        [(NSStepper *)(uintptr_t)c setIntValue:v];
        break;
      case 8: /* Progress */
        if (v < 0) {
          NSProgressIndicator *p = (NSProgressIndicator *)(uintptr_t)c;
          [p setIndeterminate:YES];
          [p startAnimation:nil];
        } else {
          NSProgressIndicator *p = (NSProgressIndicator *)(uintptr_t)c;
          [p setIndeterminate:NO];
          [p stopAnimation:nil];
          [p setDoubleValue:(double)v];
        }
        break;
      default:
        break;
    }
  }
}

int moonui_native_widget_value(moonui_ptr c) {
  int kind;
  int val;
  TRACE("widget_value");
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    switch (kind) {
      case 6:
        val = (int)[moonui_native_slider_inner(c) doubleValue];
        break;
      case 7:
        val = [(NSStepper *)(uintptr_t)c intValue];
        break;
      case 8:
        val = (int)[(NSProgressIndicator *)(uintptr_t)c doubleValue];
        break;
      default:
        val = 0;
        break;
    }
  }
  return val;
}

void moonui_native_widget_append_option(moonui_ptr c, const char *text, int text_len) {
  NSString *t;
  int kind;
  TRACE("widget_append_option");
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    t = moonui_native_string_of(text, text_len);
    switch (kind) {
      case 9: /* ComboBox */
        [(NSPopUpButton *)(uintptr_t)c addItemWithTitle:t];
        break;
      case 11: { /* RadioButtons：往容器里加一只单选按钮 */
        MoonuiRadioGroup *g = (MoonuiRadioGroup *)(uintptr_t)c;
        NSButton *rb = [[NSButton alloc] init];
        [rb setButtonType:NSButtonTypeRadio];
        [rb setTitle:t];
        [rb setTarget:g];
        [rb setAction:@selector(radioClicked:)];
        [g.buttons addObject:rb];
        [g addSubview:rb];
        [rb release];
        [g setNeedsLayout:YES];
        break;
      }
      default:
        break;
    }
  }
}

void moonui_native_widget_set_selected(moonui_ptr c, int index) {
  int kind;
  TRACE("widget_set_selected");
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    switch (kind) {
      case 9: /* ComboBox */
        [(NSPopUpButton *)(uintptr_t)c selectItemAtIndex:index];
        break;
      case 11: { /* RadioButtons */
        MoonuiRadioGroup *g = (MoonuiRadioGroup *)(uintptr_t)c;
        int i;
        for (i = 0; i < (int)[g.buttons count]; ++i) {
          NSButton *b = g.buttons[i];
          [b setState:(i == index ? NSControlStateValueOn : NSControlStateValueOff)];
        }
        break;
      }
      default:
        break;
    }
  }
}

int moonui_native_widget_selected(moonui_ptr c) {
  int kind;
  int idx;
  TRACE("widget_selected");
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    switch (kind) {
      case 9:
        idx = (int)[(NSPopUpButton *)(uintptr_t)c indexOfSelectedItem];
        break;
      case 11: {
        MoonuiRadioGroup *g = (MoonuiRadioGroup *)(uintptr_t)c;
        int i;
        idx = -1;
        for (i = 0; i < (int)[g.buttons count]; ++i) {
          if ([g.buttons[i] state] == NSControlStateValueOn) {
            idx = i;
            break;
          }
        }
        break;
      }
      default:
        idx = -1;
        break;
    }
  }
  return idx;
}

/* ---- 挂接与摆放（§14：叶子控件的原生父级都是窗口）---- */

void moonui_native_control_attach(moonui_ptr w, moonui_ptr child) {
  NSView *content;
  TRACE("control_attach");
  @autoreleasepool {
    content = [moonui_native_nswindow(w) contentView];
    [content addSubview:(NSView *)(uintptr_t)child];
  }
}

void moonui_native_container_attach(moonui_ptr container, moonui_ptr child) {
  NSView *c;
  TRACE("container_attach");
  c = (NSView *)(uintptr_t)container;
  @autoreleasepool {
    /* 滚动视口：child 挂进文档区。坐标在 Core 侧已平移成文档区坐标
     * （原点 = 视口左上角），文档区是翻转视图，set_bounds 走它的同向分支。 */
    if ([c isKindOfClass:[NSScrollView class]]) {
      [[(NSScrollView *)c documentView] addSubview:(NSView *)(uintptr_t)child];
    } else {
      [c addSubview:(NSView *)(uintptr_t)child];
    }
  }
}

void moonui_native_scroll_set_content(moonui_ptr scroll, int axis, int width,
                               int height) {
  NSScrollView *s;
  NSView *doc;
  CGFloat scale;
  TRACE("scroll_set_content");
  s = (NSScrollView *)(uintptr_t)scroll;
  scale = moonui_native_widget_dpi(scroll) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  @autoreleasepool {
    doc = [s documentView];
    if (doc == nil) {
      return;
    }
    /* 文档区尺寸 = 滚动行程：主轴取内容全长，交叉轴跟视口同宽即可。
     * origin 保持 (0,0)，滚动就是 NSScrollView 在搬文档区的可视原点。 */
    [doc setFrameSize:NSMakeSize(moonui_native_px_to_pt(width, scale),
                                 moonui_native_px_to_pt(height, scale))];
    [s setHasVerticalScroller:(axis == 0)];
    [s setHasHorizontalScroller:(axis == 1)];
  }
}

void moonui_native_control_set_bounds(moonui_ptr child, int x, int y, int width, int height) {
  NSView *v;
  NSView *content;
  NSWindow *win;
  NSView *ref;
  BOOL is_content_view;
  CGFloat scale;
  TRACE("control_set_bounds");
  v = (NSView *)(uintptr_t)child;
  @autoreleasepool {
    content = [v superview];
    win = [content window];
    is_content_view = (content != nil && win != nil && content == [win contentView]);
  }
  /* 摆放对账开关（开发用）：`MOONUI_BOUNDS_TRACE=1` 时每次 set_bounds 打一行
   * 「进参 → 落到的 frame」，连父级类名与翻转一起打。截图上有东西看不见、
   * 布局账（dump_layout）却明明有坐标时，用它定位是换算错了还是父级换了。 */
  {
    static int bounds_trace = -1;
    if (bounds_trace < 0) {
      const char *e = getenv("MOONUI_BOUNDS_TRACE");
      bounds_trace = (e != NULL && e[0] == '1') ? 1 : 0;
    }
    if (bounds_trace) {
      NSRect pf = content != nil ? [content frame] : NSZeroRect;
      printf("[bounds] %s in=(%d,%d %dx%d) parent=%s flipped=%d "
             "pframe=(%.1f,%.1f %.1fx%.1f)\n",
             class_getName(object_getClass(v)), x, y, width, height,
             content != nil ? class_getName(object_getClass(content)) : "(nil)",
             content != nil ? (int)[content isFlipped] : -1, (double)pf.origin.x,
             (double)pf.origin.y, (double)pf.size.width, (double)pf.size.height);
      fflush(stdout);
    }
  }
  scale = moonui_native_widget_dpi(child) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  if (content == nil) {
    return;
  }
  @autoreleasepool {
    NSRect out;
    /* 收的是**物理像素**，坐标系是「Core 那个参照系、左上角为原点、y 向下」。
     *
     * 参照系不是"直接父级"，而是**最近的那个认领容器**（T74）：Core 推
     * `set_bounds` 时只减掉最近一层 Scroll 的文档原点（`push_bounds_displayed`
     * 的 `enclosing_scroll_origin`），没有 Scroll 就是客户区坐标。Panel 虽然
     * 认领了子树的挂接，却没参与坐标平移——所以挂在面板里、面板又挂在滚动
     * 文档区里的字，拿到的是**文档区坐标**，不是客户区坐标。早先这里写死
     * 「父级非翻转 = 客户区坐标」，把滚动区里的面板子控件按客户区换算，全被
     * 推到面板框外裁掉（真窗现象：一行行纯色带，一个字都没有；布局账里
     * 坐标明明是对的）。
     *
     * 所以先沿父链找到这个参照视图：滚动文档区（翻转、y 向下）或客户区
     * （不翻转、y 向上，要先翻一次 y）。把矩形摆进参照视图自己的坐标系，
     * 再 `convertRect:fromView:` 换到直接父级——翻转与否交给 AppKit 算。 */
    CGFloat xpt = moonui_native_px_to_pt(x, scale);
    CGFloat ypt = moonui_native_px_to_pt(y, scale);
    CGFloat wpt = moonui_native_px_to_pt(width, scale);
    CGFloat hpt = moonui_native_px_to_pt(height, scale);
    NSView *cv = win != nil ? [win contentView] : nil;
    ref = nil;
    for (NSView *a = content; a != nil; a = [a superview]) {
      if ([a isKindOfClass:[MoonuiNativeScrollDoc class]]) {
        ref = a;
        break;
      }
      if (cv != nil && a == cv) {
        ref = a;
        break;
      }
    }
    if (ref == nil) {
      /* 父链上既没有客户区也没有文档区：无从换算，按老办法就地翻一次。 */
      CGFloat cy = [content isFlipped] ? ypt
                                       : [content bounds].size.height - ypt - hpt;
      out = NSMakeRect(xpt, cy, wpt, hpt);
    } else {
      /* 文档区是翻转视图（y 向下），进参可以直接用；客户区不翻转，先把
       * 「左上角 y 向下」换成它自己的「左下角 y 向上」。 */
      CGFloat ref_h = [ref bounds].size.height;
      NSRect in_ref = [ref isFlipped] ? NSMakeRect(xpt, ypt, wpt, hpt)
                                      : NSMakeRect(xpt, ref_h - ypt - hpt, wpt, hpt);
      out = (ref == content) ? in_ref
                             : [content convertRect:in_ref fromView:ref];
    }
    if (getenv("MOONUI_BOUNDS_TRACE") != NULL) {
      printf("[out  ] %s frame=(%.1f,%.1f %.1fx%.1f) ref=%s%s\n",
             class_getName(object_getClass(v)), (double)out.origin.x,
             (double)out.origin.y, (double)out.size.width, (double)out.size.height,
             ref != nil ? class_getName(object_getClass(ref)) : "(nil)",
             is_content_view ? " (直接父级=客户区)" : "");
      fflush(stdout);
    }
    [v setFrame:out];
  }
}

void moonui_native_control_detach(moonui_ptr child) {
  TRACE("control_detach");
  @autoreleasepool { [(NSView *)(uintptr_t)child removeFromSuperview]; }
}

void moonui_native_control_raise(moonui_ptr child) {
  NSView *v;
  NSView *sup;
  TRACE("control_raise");
  v = (NSView *)(uintptr_t)child;
  @autoreleasepool {
    sup = [v superview];
    if (sup != nil) {
      [sup addSubview:v positioned:NSWindowAbove relativeTo:nil];
    }
  }
}

int moonui_native_control_z_index(moonui_ptr child) {
  NSView *v;
  NSView *sup;
  int idx;
  TRACE("control_z_index");
  v = (NSView *)(uintptr_t)child;
  @autoreleasepool {
    sup = [v superview];
    if (sup == nil) {
      return -1;
    }
    idx = (int)[[sup subviews] indexOfObject:v];
  }
  return idx;
}

/* 焦点链（`T29`，和 libui 那份同一套语义）：ids 是空格分隔的十进制 owner 指针
 * ——MoonBit 的 FFI 过不来数组，序列化成文本（菜单树同一招）。每次推的是整份，
 * 直接替换；空串 = 这只窗口交还给 AppKit 自算（autorecalc YES）。
 *
 * 和 libui 那份的唯一差别：这里的句柄就是 NSView 指针本身（libui 那份要经
 * moonui_native_view 从 uiControl 里把 NSView 抠出来），所以解析出 owner 后直接强转。
 * 返回码口径与 libui 一致：0 = 接好，-1 = 窗口句柄不真，-2 = 链里有 owner 换不出
 * view（整份丢弃，不半推），-3 = 文本解析失败或内存不够。
 *
 * 关键一步是关掉 autorecalculatesKeyViewLoop：AppKit 默认每次 addSubview 都按
 * subviews 顺序把 nextKeyView 重算一遍，不关掉的话 Core 声明的链会被 z-order
 * 覆盖（`T29` 要的正是"焦点链和 z-order 解耦"）。Core 的 set_content 先挂完全部
 * 叶子才推链，后到的 NO 总是赢家。 */
int moonui_native_set_focus_chain(moonui_ptr window, const char *ids, int ids_len) {
  NSWindow *win;
  moonui_ptr *chain = 0;
  NSView **views;
  int len = 0;
  int i;
  const char *p = ids;
  const char *end = ids + ids_len;
  char *stop;
  TRACE("set_focus_chain");
  win = moonui_native_nswindow(window);
  if (win == nil) {
    return -1;
  }
  /* 两遍走：先数 token 数，再照原样填。strtoull 前进的位数就是 stop - p，0 表示
   * 一个数都没啃下来，那就是坏编码。 */
  while (p < end) {
    while (p < end && (*p == ' ' || *p == '\t')) {
      ++p;
    }
    if (p >= end) {
      break;
    }
    /* 返回值只用于把 stop 推进；数字合法性由 stop 的落点判。 */
    strtoull(p, &stop, 10);
    if (stop == p || (const char *)stop > end) {
      return -3;
    }
    ++len;
    p = stop;
  }
  if (len == 0) {
    /* 空链 = 交还自算：YES 一开 AppKit 立刻按 subviews 重算，旧环被整个覆盖。 */
    [win setAutorecalculatesKeyViewLoop:YES];
    return 0;
  }
  chain = (moonui_ptr *)malloc(sizeof(moonui_ptr) * (size_t)len);
  views = (NSView **)malloc(sizeof(NSView *) * (size_t)len);
  if (chain == 0 || views == 0) {
    free(chain);
    free(views);
    return -3;
  }
  p = ids;
  for (i = 0; i < len; ++i) {
    while (*p == ' ' || *p == '\t') {
      ++p;
    }
    chain[i] = (moonui_ptr)strtoull(p, &stop, 10);
    p = stop;
    views[i] = (NSView *)(uintptr_t)chain[i];
    if (views[i] == nil) {
      free(chain);
      free(views);
      return -2;
    }
  }
  [win setAutorecalculatesKeyViewLoop:NO];
  for (i = 0; i < len; ++i) {
    [views[i] setNextKeyView:views[(i + 1) % len]];
  }
  [win setInitialFirstResponder:views[0]];
  free(chain);
  free(views);
  return 0;
}

/* ---- 无障碍语义（T41）---- */

int moonui_native_set_widget_accessibility(moonui_ptr c,
                                    int role,
                                    const char *label,
                                    int label_len,
                                    const char *desc,
                                    int desc_len,
                                    int state) {
  NSView *v;
  NSString *l;
  NSString *d;
  TRACE("set_widget_accessibility");
  v = (NSView *)(uintptr_t)c;
  /* role 是 ABI 里的参数（Windows 半用它填 MSAA 注记），mac 的无障碍走
   * label/help 文本那一对，role 本身没有对应物——显式咽下。 */
  (void)role;
  @autoreleasepool {
    l = moonui_native_string_of(label, label_len);
    d = moonui_native_string_of(desc, desc_len);
    if (l != nil && [l length] > 0) {
      [v setAccessibilityLabel:l];
    }
    if (d != nil && [d length] > 0) {
      [v setAccessibilityHelp:d];
    }
    /* state 位包：bit0 = visible、bit1 = enabled、bits2-3 = checked。
     * visible/enabled 已经由 set_visible/set_enabled 落到原生层，这里不重复设；
     * checked 对 NSButton 走 state，其余控件没有对应物，跳过。 */
    if ((state & 0xC) != 0 &&
        (moonui_native_widget_kind_of(v) == 3 || moonui_native_widget_kind_of(v) == 14)) {
      [(NSButton *)v setState:((state & 0xC) == 0x8 ? NSControlStateValueOn
                                                    : NSControlStateValueOff)];
    }
  }
  return 0;
}

/* ---- 剪贴板（§23 / §48-19）----
 *
 * 直写 NSPasteboard，不经过任何中间层。契约（读路径没有错误码、"现在没有文本"
 * 和"暂时打不开"是同一个回答）在 adapter.h 的剪贴板段；实现和
 * ../libui-macos/adapter_macos.m 那份逐行相同——这一段没有 libui 可借，两个后端
 * 落到同一组 AppKit 调用本来就是 §47 的预期形状。 */

moonbit_bytes_t moonui_native_clipboard_text(void) {
  moonbit_bytes_t out;
  TRACE("clipboard_text");
  @autoreleasepool {
    /* 没有文本类型时 stringForType: 给 nil，moonui_native_bytes_of_ns 因此给空 bytes，
     * MoonBit 侧就是 None——和"剪贴板空着"同一个回答，与契约一致。 */
    NSString *s = [[NSPasteboard generalPasteboard]
        stringForType:NSPasteboardTypeString];
    out = moonui_native_bytes_of_ns(s);
  }
  return out;
}

int moonui_native_clipboard_set_text(const char *text, int text_len) {
  int rc = 0;
  TRACE("clipboard_set_text");
  @autoreleasepool {
    NSString *s = moonui_native_string_of(text, text_len);
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    if (s == nil) {
      return -2;
    }
    /* clearContents 返回 NO = 这只 pasteboard 现在不归我们（别的进程正开着它），
     * 正是契约里的 -1。 */
    if (![pb clearContents]) {
      return -1;
    }
    if (![pb setString:s forType:NSPasteboardTypeString]) {
      return -2;
    }
  }
  return rc;
}

/* ---- 对话框（§24 / §48-18）----
 *
 * 契约见 adapter.h 的对话框段：-1/-2 两个失败码分别是什么、"取消返回 false"的
 * 归一化在哪一层做。实现与 ../libui-macos/adapter_macos.m 逐行相同。
 *
 * NSAlert 自己会跑一层 modal 循环（runModal），所以这一段和本文件的事件循环是
 * **两层分开的循环**：对话框阻塞期间 MoonBit 一行都跑不到，poll_event 也不会
 * 推进主循环。这正是 §24 要的形状（confirm 当场给答案），也是为什么只能从
 * handler 里调用它。 */

/* 正在被 modal 循环展示的那只面板。只在那次 runModal 期间非空，所有权从 alloc 那行
 * 到 release 那行之间归本文件。定时器的块里不许捕获 ObjC 指针（本文件按 MRR 编，没有
 * -fobjc-arc，块捕获的指针不会被 retain），所以它读的是这个静态量而不是捕获。 */
static NSAlert *moonui_native_open_alert = nil;

/* "用户在 ms 毫秒之后按下第 index 个按钮"。装它的入口在下面测试脚手架那节
 * （moonui_native_auto_dismiss_dialog），认领它的就是这里：下一个对话框建好面板时取走并清零。 */
static int moonui_native_dismiss_after_ms = -1;
static int moonui_native_dismiss_index = -1;

static void moonui_native_arm_dismissor(void) {
  NSRunLoop *loop;
  NSTimer *timer;
  NSInteger index;
  NSInteger count;
  NSTimeInterval delay;
  if (moonui_native_dismiss_after_ms < 0 || moonui_native_open_alert == nil) {
    return;
  }
  count = (NSInteger)[[moonui_native_open_alert buttons] count];
  if (count <= (NSInteger)0) {
    return;
  }
  index = (NSInteger)moonui_native_dismiss_index;
  /* index 超出这只面板的按钮数时退到最后一只（"否"或"确定"），和 Windows 那份
   * moonui_native_start_dismissor 同一个兜底：写错的脚手架要红在断言上，不要挂住整轮
   * 测试——什么都按不下就是永不返回。 */
  if (index < (NSInteger)0 || index >= count) {
    index = count - (NSInteger)1;
  }
  delay = (NSTimeInterval)moonui_native_dismiss_after_ms / (NSTimeInterval)1000.0;
  timer = [NSTimer timerWithTimeInterval:delay
                                repeats:NO
                                    block:^(NSTimer *fired) { (void)fired;
                                      NSAlert *alert = moonui_native_open_alert;
                                      NSArray *buttons;
                                      if (alert == nil) {
                                        return;
                                      }
                                      buttons = [alert buttons];
                                      if (index >= (NSInteger)[buttons count]) {
                                        return;
                                      }
                                      /* 真按钮的 performClick:：走的是 NSAlert 自己那套
                                       * "按钮被按 → 结束 modal session 并报回它的
                                       * alertReturn"，于是 runModal 的返回值是原生对话框
                                       * 给的答案，不是这里编出来的。 */
                                      [[buttons objectAtIndex:index]
                                          performClick:nil];
                                    }];
  /* runModal 的循环跑在 NSModalPanelRunLoopMode，只挂默认档的定时器在模态期间永远不会
   * fire（这段最容易写错的地方就是这一行）。另外两档一起挂：调用方有可能已经在别的
   * mode 里等。 */
  loop = [NSRunLoop currentRunLoop];
  [loop addTimer:timer forMode:NSModalPanelRunLoopMode];
  [loop addTimer:timer forMode:NSEventTrackingRunLoopMode];
  [loop addTimer:timer forMode:NSDefaultRunLoopMode];
  moonui_native_dismiss_after_ms = -1;
  moonui_native_dismiss_index = -1;
}

/* 两只面板共用的一段：文案进 messageText / informativeText，按需加按钮，modal 跑一场。
 * 返回 -1 = 文案不是合法 UTF-8；否则是 runModal 的返回值（一定 >= 0）。 */
static NSInteger moonui_native_show_alert(const char *title,
                                   int title_len,
                                   const char *text,
                                   int text_len,
                                   BOOL is_confirm) {
  @autoreleasepool {
    NSString *t = moonui_native_string_of(title, title_len);
    NSString *s = moonui_native_string_of(text, text_len);
    NSAlert *alert;
    NSInteger clicked;
    if (t == nil || s == nil) {
      return -1;
    }
    alert = [[NSAlert alloc] init];
    [alert setMessageText:t];
    [alert setInformativeText:s];
    /* 按钮文字归后端：契约只分"确定"和"是/否"两种形态，没给标题留参数。Windows 那份
     * 把这两个形态交给系统本地化（MB_OK / MB_YESNO），而 AppKit 没有公开的"本地化的
     * 是否按钮对"，所以这里写死中文——本仓库的 Demo 和文案都是中文的。 */
    if (is_confirm) {
      [alert addButtonWithTitle:@"是"];
      [alert addButtonWithTitle:@"否"];
    } else {
      [alert addButtonWithTitle:@"好"];
    }
    /* NSAlert 的按钮数组要到展示时才落实，而脚手架要点的正是数组里那只真 NSButton，
     * 所以先 layout 一次把它坐实。 */
    [alert layout];
    moonui_native_open_alert = alert;
    moonui_native_arm_dismissor();
    clicked = [alert runModal];
    moonui_native_open_alert = nil;
    [alert release];
    return clicked;
  }
}

int moonui_native_dialog_message(const char *title,
                          int title_len,
                          const char *text,
                          int text_len) {
  NSInteger clicked;
  TRACE("dialog_message");
  clicked = moonui_native_show_alert(title, title_len, text, text_len, NO);
  if (clicked < (NSInteger)0) {
    return (int)clicked;
  }
  /* 只有一只按钮，"按了确定"和"面板被关掉"对调用方是同一件事：§24 的 message 返回
   * Unit，这个区别没有地方放。 */
  return 0;
}

int moonui_native_dialog_confirm(const char *title,
                          int title_len,
                          const char *text,
                          int text_len) {
  NSInteger clicked;
  TRACE("dialog_confirm");
  clicked = moonui_native_show_alert(title, title_len, text, text_len, YES);
  if (clicked < (NSInteger)0) {
    return (int)clicked;
  }
  /* NSAlertFirstButtonReturn = 加按钮时排第一的那只，也就是"是"。其余一律算"没同意"
   * （含"否"和被关掉），对上 §24 的"取消返回 false"。 */
  return clicked == NSAlertFirstButtonReturn ? 1 : 0;
}

/* ---- 文件对话框（§24 / §48-18）----
 *
 * 契约见 adapter.h 的文件对话框段：返回码、路径为什么拆成 getter 取走。和
 * ../libui-macos/adapter_macos.m 那份逐行相同——包括 macOS 15.6 上"替按 OK
 * 做不到"那条 XPC 限制（面板跑在 com.apple.appsdk.xpc.openAndSavePanelService
 * 里，客户端的 ok: 是个桩，证据链记在 libui 那份的
 * moonui_native_auto_answer_file_dialog 注释和 TODO 的 T21 行）。
 *
 * 和上一段（NSAlert）同一个形状：面板自己跑一层 modal 循环（runModal），阻塞期间
 * MoonBit 一行都跑不到。测试脚手架只能替用户按"取消"；"接受"那条分支留着，走的是
 * 真实用户的产品路径。 */

/* 三种形态。open 和 folder 都建 NSOpenPanel（canChooseFiles / canChooseDirectories
 * 切形态），save 建 NSSavePanel。 */
#define MOONUI_FILE_OPEN 0
#define MOONUI_FILE_SAVE 1
#define MOONUI_FILE_FOLDER 2

/* 正在被 modal 循环展示的那只面板；只在那次 runModal 期间非空，所有权从
 * [NSOpenPanel openPanel] / [NSSavePanel savePanel] 到 runModal 返回之间归 AppKit
 * （两条都是 autoreleased，本文件不 release）。和 moonui_native_open_alert 同一个理由不放进
 * 块的捕获：本文件按 MRR 编，块捕获的 ObjC 指针不会被 retain。save 是 open 的父类，
 * 所以静态量按父类收。 */
static NSSavePanel *moonui_native_open_panel = nil;

/* 面板结果的落点：到 moonui_native_file_dialog_path 取走（或下一次面板打开）之前归本文件
 * 所有。取消 / 失败时是 NULL，getter 因此给空 bytes。 */
static char *moonui_native_file_result = 0;

/* "ms 毫秒之后替下一个文件面板按取消"。装它的入口在下面测试脚手架那节
 * （moonui_native_auto_answer_file_dialog），认领它的是 moonui_native_arm_file_answer：下一个文件
 * 面板打开时取用，runModal 返回后清场。macOS 15.6 上只有"取消"这一种答案可以替，
 * 所以没有 accept / path 两个静态量。 */
static int moonui_native_file_answer_after_ms = -1;

/* 每开一只面板加一。两只定时器（主答 + 兜底取消）都带着自己那一代的号，醒来先对号
 * ——不对号说明这个面板的 modal 早结束了，什么都不许做。不这么写的话，上一次面板
 * 留下的兜底定时器会在下一次面板的 modal 里醒来把它取消掉：上一轮脚手架按了这一轮
 * 的按钮，是最难查的那种红。 */
static int64_t moonui_native_file_panel_serial = 0;

static void moonui_native_file_clear_answer(void) {
  moonui_native_file_answer_after_ms = -1;
}

/* 把装好的那发"用户怎么答"挂进 runloop。面板建好之后、runModal 之前调用（位置同
 * moonui_native_arm_dismissor）。没装就是空操作。
 *
 * 两只定时器：
 *   - 主答（ms 之后）：cancel:——runModal 当场拿 0（取消）回来。macOS 15.6 上没有
 *     "替用户按 OK"的路。
 *   - 兜底（ms + 500）：主答那步要是没能结束 modal，到点再取消一次，让调用当场拿
 *     "取消"回来。测试因此红在它自己的断言上，而不是整轮挂住。
 *
 * 两个块都读当时的静态量、不捕获面板指针；对号 + 面板非空两个守卫合起来保证"读的
 * 时候这根指针还活着"：runModal 一返回 moonui_native_open_panel 就清空。 */
static void moonui_native_arm_file_answer(void) {
  NSRunLoop *loop;
  NSTimer *timer;
  NSTimer *backup;
  NSTimeInterval delay;
  NSTimeInterval backup_delay;
  int64_t serial;
  if (moonui_native_file_answer_after_ms < 0 || moonui_native_open_panel == nil) {
    return;
  }
  serial = moonui_native_file_panel_serial;
  delay = (NSTimeInterval)moonui_native_file_answer_after_ms / (NSTimeInterval)1000.0;
  backup_delay = delay + (NSTimeInterval)0.5;
  timer = [NSTimer timerWithTimeInterval:delay
                                 repeats:NO
                                     block:^(NSTimer *fired) { (void)fired;
    @autoreleasepool {
      NSSavePanel *panel = moonui_native_open_panel;
      if (panel == nil || serial != moonui_native_file_panel_serial) {
        return;
      }
      [panel cancel:panel];
    }
  }];
  backup = [NSTimer timerWithTimeInterval:backup_delay
                                  repeats:NO
                                     block:^(NSTimer *fired) { (void)fired;
    if (serial == moonui_native_file_panel_serial && moonui_native_open_panel != nil) {
      [moonui_native_open_panel cancel:moonui_native_open_panel];
    }
  }];
  /* 和 moonui_native_arm_dismissor 同一行注释：runModal 的循环跑在 NSModalPanelRunLoopMode，
   * 只挂默认档的定时器在模态期间永远不会 fire。另外两档一起挂。 */
  loop = [NSRunLoop currentRunLoop];
  [loop addTimer:timer forMode:NSModalPanelRunLoopMode];
  [loop addTimer:timer forMode:NSEventTrackingRunLoopMode];
  [loop addTimer:timer forMode:NSDefaultRunLoopMode];
  [loop addTimer:backup forMode:NSModalPanelRunLoopMode];
  [loop addTimer:backup forMode:NSEventTrackingRunLoopMode];
  [loop addTimer:backup forMode:NSDefaultRunLoopMode];
}

/* 三种面板共用的一段：建面板、跑一场 modal、把结果存进 moonui_native_file_result。
 * 返回码见 adapter.h（1 = 选了，0 = 取消，-1 = 文案编码失败，-2 = 面板失败）。 */
static int moonui_native_run_file_panel(const char *title,
                                 int title_len,
                                 const char *default_name,
                                 int default_name_len,
                                 int mode) {
  @autoreleasepool {
    NSString *t = moonui_native_string_of(title, title_len);
    NSString *d = nil;
    NSSavePanel *panel;
    NSInteger clicked;
    if (t == nil) {
      return -1;
    }
    if (default_name != 0) {
      d = moonui_native_string_of(default_name, default_name_len);
      if (d == nil) {
        return -1;
      }
    }
    if (mode == MOONUI_FILE_SAVE) {
      panel = [NSSavePanel savePanel];
    } else {
      NSOpenPanel *o = [NSOpenPanel openPanel];
      [o setCanChooseFiles:mode == MOONUI_FILE_OPEN];
      [o setCanChooseDirectories:mode == MOONUI_FILE_FOLDER];
      [o setResolvesAliases:NO];
      [o setAllowsMultipleSelection:NO];
      panel = o;
    }
    [panel setTitle:t];
    if (d != nil) {
      [panel setNameFieldStringValue:d];
    }
    moonui_native_open_panel = panel;
    moonui_native_file_panel_serial += 1;
    /* 结果取走语义的另一半：每开一次面板，上一次的还没取走的就作废。 */
    free(moonui_native_file_result);
    moonui_native_file_result = 0;
    moonui_native_arm_file_answer();
    clicked = [panel runModal];
    moonui_native_open_panel = nil;
    /* 这一发"用户怎么答"已经兑现（或随面板一起作废），清场。 */
    moonui_native_file_clear_answer();
    if (clicked == NSModalResponseCancel) {
      return 0;
    }
    if (clicked != NSModalResponseOK) {
      return -2;
    }
    {
      NSURL *u = [panel URL];
      NSString *p = u != nil ? [u path] : nil;
      const char *c = p != nil ? [p UTF8String] : 0;
      if (c == 0) {
        return -2;
      }
      moonui_native_file_result = moonui_native_dup(c, (int)strlen(c));
      if (moonui_native_file_result == 0) {
        return -2;
      }
    }
    return 1;
  }
}

int moonui_native_open_file(const char *title, int title_len) {
  TRACE("open_file");
  return moonui_native_run_file_panel(title, title_len, 0, 0, MOONUI_FILE_OPEN);
}

int moonui_native_save_file(const char *title,
                     int title_len,
                     const char *default_name,
                     int default_name_len) {
  TRACE("save_file");
  return moonui_native_run_file_panel(title, title_len, default_name, default_name_len,
                               MOONUI_FILE_SAVE);
}

int moonui_native_select_folder(const char *title, int title_len) {
  TRACE("select_folder");
  return moonui_native_run_file_panel(title, title_len, 0, 0, MOONUI_FILE_FOLDER);
}

/* 取走结果：返回值是当场拷进 MoonBit 堆的一份（GC 回收，那边不用 free），内部指针
 * 顺带清空。没结果时给空 bytes。 */
moonbit_bytes_t moonui_native_file_dialog_path(void) {
  moonbit_bytes_t out;
  TRACE("file_dialog_path");
  if (moonui_native_file_result == 0) {
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_native_bytes_of(moonui_native_file_result);
  free(moonui_native_file_result);
  moonui_native_file_result = 0;
  return out;
}

/* ---- 菜单栏（§25 / §48-20）----
 *
 * 和 libui 那份（../libui-macos/adapter_macos.m 同名一节）同一个结论：菜单自己搭
 * NSMenu，不经过任何"便利层"。mac 这一份的形状：
 *   - moonui_native_init 已把一只空的主菜单装进 [NSApp mainMenu]（见上面的 init），这里只往
 *     后追加。追加了哪几项记在 `moonui_native_menu_items` 里，清场、查 id、dump 都按这份名单
 *     走——不数"索引 1 往后"，那种算术靠的是别人的顺序。
 *   - 可点项的 target 是全局一个对象，Core 的 id 挂在 `item.tag` 上随 action 回来，
 *     所以不需要另建一张 id → 记录的表。分隔线的 tag 也是 0，查 id 时必须连 action
 *     一起认，否则 0 号项会被分隔线冒充。
 *   - Check 和 Radio 在 mac 的原生外观里是同一个东西（都显示一个勾），原生项里没有
 *     "我是 radio"这回事。dump 要分得开 c/r，所以装的时候把 role 存在
 *     `representedObject` 上——那也是项自己的状态，读它和读 title 同级。
 *   - 拆旧的一律排在"新树整个建好"之后：建的途中出任何岔子就返回 -1，屏幕上还是上一棵。
 */

/* 点击回调是进程全局的一份，不占 moonui_native_slots 那张表：整个进程只有一棵菜单栏，
 * 而那张表是按"一个控件一格"设计的，硬塞进去反而要替它记 owner。
 * closure 照样要 incref——AppKit 只存函数指针，GC 看不见它。 */
static moonui_closure_id_fn moonui_native_menu_fn = 0;
static void *moonui_native_menu_closure = 0;
static NSMutableArray *moonui_native_menu_items = nil;

@interface MoonuiNativeMenuTarget : NSObject
- (void)moonuiMenuItemClicked:(NSMenuItem *)item;
@end

@implementation MoonuiNativeMenuTarget
- (void)moonuiMenuItemClicked:(NSMenuItem *)item {
  if (moonui_native_menu_fn != 0 && moonui_native_menu_closure != 0) {
    moonui_native_menu_fn(moonui_native_menu_closure, (int)[item tag]);
  }
}
@end

/* +1 一直持到进程退出，符合本文件"进程级对象手工管、其余交给池"的规矩。 */
static MoonuiNativeMenuTarget *moonui_native_menu_target = nil;

/* 松开菜单栏持有的那份 MoonBit 闭包。整个进程只有一棵菜单，所以这一格不在
 * moonui_native_slots 那张表里，terminate 和"换一次回调"都走这里。 */
static void moonui_native_menu_drop_closure(void) {
  if (moonui_native_menu_closure != 0) {
    moonbit_decref(moonui_native_menu_closure);
    moonui_native_menu_closure = 0;
  }
  moonui_native_menu_fn = 0;
}

/* ---- 打包树的读游标（布局见 adapter.h）---- */

typedef struct {
  const unsigned char *p;
  int len;
  int pos;
  int bad;
} MoonuiTree;

static int moonui_native_tree_u8(MoonuiTree *t) {
  if (t->bad || t->pos + 1 > t->len) {
    t->bad = 1;
    return 0;
  }
  return (int)t->p[t->pos++];
}

/* 小端 i32。读满四个字节才动 pos，越界的那一步整体作废（bad 一旦为真就不再翻案）。 */
static int moonui_native_tree_i32(MoonuiTree *t) {
  int i;
  int v = 0;
  if (t->bad || t->pos + 4 > t->len) {
    t->bad = 1;
    return 0;
  }
  for (i = 0; i < 4; ++i) {
    v |= ((int)t->p[t->pos + i]) << (8 * i);
  }
  t->pos += 4;
  return v;
}

/* i32 长度 + UTF-8 内容 → NSString。不是合法 UTF-8 也算读坏：树是 MoonBit
 * `@utf8.encode` 出来的，坏字节只可能是布局对不上，那正是 -1 要报的东西。 */
static NSString *moonui_native_tree_str(MoonuiTree *t) {
  int n;
  NSString *s;
  if (t->bad) {
    return nil;
  }
  n = moonui_native_tree_i32(t);
  if (t->bad || n < 0 || t->pos + n > t->len) {
    t->bad = 1;
    return nil;
  }
  s = [[[NSString alloc] initWithBytes:(const void *)(t->p + t->pos)
                                length:(NSUInteger)n
                              encoding:NSUTF8StringEncoding] autorelease];
  t->pos += n;
  if (s == nil) {
    t->bad = 1;
  }
  return s;
}

/* Core 的键名 → AppKit 的 keyEquivalent。给 nil 就是"这个键在菜单项上没有对应形态"：
 * 功能键和方向键都落在 0xF700 那一族字符里，菜单项收不下，按 adapter.h 的约定整个不显示。
 * 词表用 Core 那一套（event.mbt 的 "Enter"/"a"），不在这里另立第二个名字空间。 */
static NSString *moonui_native_menu_key_equiv(const char *key) {
  unsigned char c;
  if (key == 0 || key[0] == '\0') {
    return nil;
  }
  if (key[1] == '\0') {
    c = (unsigned char)key[0];
    if (c == ' ') {
      return @" ";
    }
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9')) {
      /* 字母一律收成小写：大写 keyEquivalent 在 AppKit 里隐含 Shift，而这里的 Shift
         由修饰键位自己表示，两套混着写会让读回来的组合和装进去的不是一回事。 */
      return [NSString stringWithFormat:@"%C",
                                      (unichar)tolower((int)c)];
    }
    return nil;
  }
  if (strcmp(key, "Space") == 0) {
    return @" ";
  }
  if (strcmp(key, "Enter") == 0 || strcmp(key, "Return") == 0) {
    return [NSString stringWithFormat:@"%C", (unichar)0x0D];
  }
  if (strcmp(key, "Tab") == 0) {
    return [NSString stringWithFormat:@"%C", (unichar)0x09];
  }
  if (strcmp(key, "Escape") == 0 || strcmp(key, "Esc") == 0) {
    return [NSString stringWithFormat:@"%C", (unichar)0x1B];
  }
  if (strcmp(key, "Backspace") == 0) {
    return [NSString stringWithFormat:@"%C", (unichar)0x7F];
  }
  return nil;
}

/* 修饰键位 → AppKit 的 modifier mask。照字面映射，不做"mac 上把 Ctrl 当 Cmd 用"
 * 那种替换（理由见 adapter.h：显示和派发必须同源）。 */
static unsigned int moonui_native_menu_mods_flag(int mods) {
  unsigned int flags = 0;
  if (mods & 1) {
    flags |= NSEventModifierFlagControl;
  }
  if (mods & 2) {
    flags |= NSEventModifierFlagOption;
  }
  if (mods & 4) {
    flags |= NSEventModifierFlagShift;
  }
  if (mods & 8) {
    flags |= NSEventModifierFlagCommand;
  }
  return flags;
}

static NSMenu *moonui_native_menu_new(NSString *title) {
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:title] autorelease];
  /* autoenablesItems=NO：默认那套"没有 target 就自己置灰"是 AppKit 的推理，而 §25 的
   * 置灰由 Core 说了算。关掉它，isEnabled 读回来的才是 MoonUI 写进去的那个值。 */
  [menu setAutoenablesItems:NO];
  return menu;
}

/* 读 kind 0 剩下的字段（kind 字节由调用方读过）。 */
static NSMenuItem *moonui_native_menu_read_item(MoonuiTree *t) {
  NSString *label;
  int item_id;
  int role;
  int checked;
  int enabled;
  int has_sc;
  int mods;
  NSString *key;
  NSString *equiv;
  NSMenuItem *item;
  label = moonui_native_tree_str(t);
  item_id = moonui_native_tree_i32(t);
  role = moonui_native_tree_u8(t);
  checked = moonui_native_tree_u8(t);
  enabled = moonui_native_tree_u8(t);
  has_sc = moonui_native_tree_u8(t);
  mods = 0;
  equiv = nil;
  if (has_sc != 0) {
    mods = moonui_native_tree_u8(t);
    key = moonui_native_tree_str(t);
    if (!t->bad) {
      equiv = moonui_native_menu_key_equiv([key UTF8String]);
    }
  }
  if (t->bad || (role != 0 && role != 1 && role != 2)) {
    return nil;
  }
  item = [[[NSMenuItem alloc] initWithTitle:label
                                     action:NULL
                              keyEquivalent:@""] autorelease];
  [item setTag:(NSInteger)item_id];
  [item setTarget:moonui_native_menu_target];
  [item setAction:@selector(moonuiMenuItemClicked:)];
  [item setEnabled:(enabled != 0)];
  [item setState:(checked != 0) ? NSControlStateValueOn
                                : NSControlStateValueOff];
  /* role 存进 representedObject：Check 和 Radio 的原生外观相同，dump 要分得开只能靠这项
   * 自己带着。它确实是"项自己的状态"，不是另开的一张表。 */
  [item setRepresentedObject:[NSNumber numberWithInt:role]];
  if (equiv != nil) {
    [item setKeyEquivalent:equiv];
    [item setKeyEquivalentModifierMask:moonui_native_menu_mods_flag(mods)];
  }
  return item;
}

/* 往 menu 里填 count 个条目；Submenu 那一支自己递归。任何一步读坏就返回 0，
 * 调用方把整棵作废（不留"半棵树"）。 */
static int moonui_native_menu_fill(NSMenu *menu, MoonuiTree *t, int count) {
  int i;
  for (i = 0; i < count; ++i) {
    int kind = moonui_native_tree_u8(t);
    NSMenuItem *item = nil;
    if (t->bad) {
      return 0;
    }
    if (kind == 0) {
      item = moonui_native_menu_read_item(t);
      if (item == nil) {
        return 0;
      }
    } else if (kind == 1) {
      item = [NSMenuItem separatorItem];
    } else if (kind == 2) {
      NSString *sub = moonui_native_tree_str(t);
      int sub_count = moonui_native_tree_i32(t);
      NSMenu *sub_menu;
      if (t->bad || sub_count < 0) {
        return 0;
      }
      sub_menu = moonui_native_menu_new(sub);
      if (!moonui_native_menu_fill(sub_menu, t, sub_count)) {
        return 0;
      }
      /* 子菜单的挂法：主菜单里放一只不带 action 的项，它的 submenu 才是那一条。
       * 于是"能点的项都有 action"这条不变量成立，查 id 时不会被子菜单标题冒充。 */
      item = [[[NSMenuItem alloc] initWithTitle:sub
                                         action:NULL
                                  keyEquivalent:@""] autorelease];
      [item setSubmenu:sub_menu];
    } else {
      return 0;
    }
    [menu addItem:item];
  }
  return 1;
}

/* 把上一次装的整棵从主菜单摘掉。按自己记的名单摘，不数索引。
 *
 * `removeItem:` 对"本来不在这棵菜单里"的项是抛 NSInternalInconsistencyException 而不是
 * 忽略，所以这里先问主菜单有没有这一项。名单和主菜单对不上只可能是我们自己记错了，
 * 而记错的代价不该是宿主进程当场点死——摘不掉的那一项会在快照里少一顶、让测试红在
 * 断言上。 */
static void moonui_native_menu_clear(void) {
  NSMenu *main_menu;
  if (moonui_native_menu_items == nil) {
    return;
  }
  main_menu = [NSApp mainMenu];
  if (main_menu != nil) {
    for (NSMenuItem *item in moonui_native_menu_items) {
      if ([main_menu indexOfItem:item] >= 0) {
        [main_menu removeItem:item];
      }
    }
  }
  [moonui_native_menu_items removeAllObjects];
}

int moonui_native_set_menu_bar(const char *tree,
                        int tree_len,
                        moonui_closure_id_fn fn,
                        void *closure) {
  NSMenu *main_menu;
  MoonuiTree t;
  NSMutableArray *built;
  int version;
  int count;
  int i;
  TRACE("set_menu_bar");
  if (!moonui_native_inited) {
    return -2;
  }
  @autoreleasepool {
    main_menu = [NSApp mainMenu];
    if (main_menu == nil) {
      return -2;
    }
    /* 最短的合法树是 version(1 字节) + count(i32)，空的也行：那就是"把菜单拆掉"。 */
    if (tree == 0 || tree_len < 5) {
      return -1;
    }
    t.p = (const unsigned char *)tree;
    t.len = tree_len;
    t.pos = 0;
    t.bad = 0;
    version = moonui_native_tree_u8(&t);
    count = moonui_native_tree_i32(&t);
    if (t.bad || version != 1 || count < 0) {
      return -1;
    }
    if (moonui_native_menu_target == nil) {
      moonui_native_menu_target = [[MoonuiNativeMenuTarget alloc] init];
    }
    if (moonui_native_menu_items == nil) {
      moonui_native_menu_items = [[NSMutableArray alloc] init];
    }
    built = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (i = 0; i < count; ++i) {
      NSString *label = moonui_native_tree_str(&t);
      int node_count = moonui_native_tree_i32(&t);
      NSMenu *menu;
      NSMenuItem *top;
      if (t.bad || node_count < 0) {
        return -1;
      }
      menu = moonui_native_menu_new(label);
      if (!moonui_native_menu_fill(menu, &t, node_count)) {
        return -1;
      }
      top = [[[NSMenuItem alloc] initWithTitle:label
                                        action:NULL
                                 keyEquivalent:@""] autorelease];
      [top setSubmenu:menu];
      [built addObject:top];
    }
    /* 整棵新树已经建好了，从这里开始才真的动屏幕上那棵。 */
    moonui_native_menu_clear();
    for (NSMenuItem *top in built) {
      [main_menu addItem:top];
      [moonui_native_menu_items addObject:top];
    }
    moonui_native_menu_drop_closure();
    moonui_native_menu_fn = fn;
    if (closure != 0) {
      moonbit_incref(closure);
      moonui_native_menu_closure = closure;
    }
  }
  return 0;
}

/* 只有"带我们那个 action 的项"算可点项，所以分隔线（tag 默认 0）和子菜单标题
 * （action 为 NULL）都冒充不了 0 号项。 */
static NSMenuItem *moonui_native_menu_find_in(NSMenu *menu, int id) {
  for (NSMenuItem *item in [menu itemArray]) {
    NSMenuItem *hit;
    NSMenu *sub = [item submenu];
    if ([item action] == @selector(moonuiMenuItemClicked:) &&
        (int)[item tag] == id) {
      return item;
    }
    if (sub != nil) {
      hit = moonui_native_menu_find_in(sub, id);
      if (hit != nil) {
        return hit;
      }
    }
  }
  return nil;
}

static NSMenuItem *moonui_native_menu_find_id(int id) {
  if (moonui_native_menu_items == nil) {
    return nil;
  }
  for (NSMenuItem *top in moonui_native_menu_items) {
    NSMenuItem *hit = moonui_native_menu_find_in([top submenu], id);
    if (hit != nil) {
      return hit;
    }
  }
  return nil;
}

int moonui_native_menu_item_set_checked(int id, int checked) {
  TRACE("menu_item_set_checked");
  @autoreleasepool {
    NSMenuItem *item = moonui_native_menu_find_id(id);
    if (item == nil) {
      return -1;
    }
    [item setState:(checked != 0) ? NSControlStateValueOn
                                  : NSControlStateValueOff];
  }
  return 0;
}

/* ---- 应用图标（§26）----
 *
 * 只喂 NSApp（[NSApp setApplicationIconImage:]）：Dock、Cmd-Tab、窗口代理图标
 * （标题栏左上角）都从它来。参数按 adapter.h 的约定是不带扩展名的 stem，这里补
 * ".png"——把扩展名留在 C 侧补齐，两个平台才能共用同一行 MoonBit 调用。
 * 文件读不出来是调用方的路径错，按 §33 报 -1；NSApp 还没初始化报 -2。
 *
 * **留白归一化**：macOS 的图标网格（Big Sur 起）是 1024 画布 + 824 主体，四周
 * 各留 100（主体占 80.5%）。这个留白不是美术口味，是系统口径：Dock/Cmd-Tab 把
 * 图标当整块画布摆，凡四边贴满的图（设计师按 256/512 出的满幅 PNG）都会比邻居
 * 大一圈。所以这里不把用户的图原样喂进去，而是先量内容的 alpha 包围盒，再把
 * 内容按 824/1024 重排到一张透明画布上：
 *   - 内容已经留够白（≥7% 边距，主体 ≤86%）的图**不动**——重复补白会越缩越小；
 *   - 满幅图补到 80.5%，画布取「内容像素 / 0.805」，内容本身不重采样（256 的图
 *     还是 256 个像素，只是四周多了透明边）；
 *   - 内容超过 824 的（1024 满幅那种）落到 1024 画布、缩到 824。
 * 结果比例记在 moonui_native_app_icon_content_permille 里，测试拿它当判据。
 */
static int moonui_native_app_icon_installed = 0;
static int moonui_native_app_icon_content_value = -1;

/* 图标主体占画布的比例（Apple 的 824/1024）。 */
#define MOONUI_ICON_BODY_RATIO 0.8047
/* 已经留够白的判据：主体 ≤ 这个比例就不动它（留白 ≥ 7%）。 */
#define MOONUI_ICON_SKIP_RATIO 0.86
/* 归一化后的画布上限（Apple 的最大画布）。 */
#define MOONUI_ICON_CANVAS_MAX 1024
/* 内容超过这个大小时落到最大画布、缩到主体框。 */
#define MOONUI_ICON_BODY_MAX 824.0

/* 取第一张位图表示（PNG 读进来就是 NSBitmapImageRep）。 */
static NSBitmapImageRep *moonui_native_icon_rep(NSImage *img) {
  NSBitmapImageRep *rep = nil;
  for (NSImageRep *r in [img representations]) {
    if ([r isKindOfClass:[NSBitmapImageRep class]]) {
      rep = (NSBitmapImageRep *)r;
      break;
    }
  }
  return rep;
}

/* 内容的 alpha 包围盒（左上原点，像素）。有 alpha 的图按 alpha>8 判"有内容"；
 * 没有 alpha 的图（24 位 PNG）整幅都算内容。找不到位图返回 0。 */
static int moonui_native_icon_content_box(NSImage *img,
                                         int *bx,
                                         int *by,
                                         int *bw,
                                         int *bh) {
  NSBitmapImageRep *rep = moonui_native_icon_rep(img);
  if (rep == nil) {
    return 0;
  }
  NSInteger pw = [rep pixelsWide];
  NSInteger ph = [rep pixelsHigh];
  if (pw <= 0 || ph <= 0) {
    return 0;
  }
  if (![rep hasAlpha]) {
    *bx = 0;
    *by = 0;
    *bw = (int)pw;
    *bh = (int)ph;
    return 1;
  }
  unsigned char *data = [rep bitmapData];
  NSInteger spp = [rep samplesPerPixel];
  NSInteger bpr = [rep bytesPerRow];
  if (data == NULL || spp < 2 || bpr <= 0) {
    return 0;
  }
  BOOL alpha_first =
      ([rep bitmapFormat] & NSBitmapFormatAlphaFirst) != 0;
  NSInteger ai = alpha_first ? 0 : (spp - 1);
  int minx = (int)pw;
  int miny = (int)ph;
  int maxx = -1;
  int maxy = -1;
  for (NSInteger y = 0; y < ph; y++) {
    const unsigned char *row = data + y * bpr;
    for (NSInteger x = 0; x < pw; x++) {
      if (row[x * spp + ai] > 8) {
        if ((int)x < minx) {
          minx = (int)x;
        }
        if ((int)x > maxx) {
          maxx = (int)x;
        }
        if ((int)y < miny) {
          miny = (int)y;
        }
        if ((int)y > maxy) {
          maxy = (int)y;
        }
      }
    }
  }
  if (maxx < minx || maxy < miny) {
    return 0; /* 整张全透明：没有内容可排，原样交给系统 */
  }
  *bx = minx;
  *by = miny;
  *bw = maxx - minx + 1;
  *bh = maxy - miny + 1;
  return 1;
}

/* 把内容按 macOS 图标网格重排到透明画布上。不需要改就返回 nil（调用方用原图）。
 * 成功时 *content_permille 写入内容占画布的千分比。 */
static NSImage *moonui_native_icon_fitted(NSImage *src, int *content_permille) {
  int bx = 0;
  int by = 0;
  int bw = 0;
  int bh = 0;
  if (!moonui_native_icon_content_box(src, &bx, &by, &bw, &bh)) {
    return nil;
  }
  NSBitmapImageRep *rep = moonui_native_icon_rep(src);
  if (rep == nil) {
    return nil;
  }
  int pw = (int)[rep pixelsWide];
  int ph = (int)[rep pixelsHigh];
  int canvas_src = pw > ph ? pw : ph;
  double ratio = (double)(bw > bh ? bw : bh) / (double)canvas_src;
  if (ratio <= MOONUI_ICON_SKIP_RATIO) {
    *content_permille = (int)lround(ratio * 1000.0);
    return nil; /* 已经留够白，不动 */
  }
  int content_max = bw > bh ? bw : bh;
  NSInteger canvas = 0;
  if ((double)content_max <= MOONUI_ICON_BODY_MAX) {
    /* 内容不重采样：画布放大到「内容 / 0.805」，只是四周多出透明边 */
    canvas = (NSInteger)lround((double)content_max / MOONUI_ICON_BODY_RATIO);
  } else {
    canvas = MOONUI_ICON_CANVAS_MAX;
  }
  if (canvas < 64) {
    canvas = 64;
  }
  NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)canvas,
                                                         (CGFloat)canvas)];
  if (out == nil) {
    return nil;
  }
  NSBitmapImageRep *out_rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL
                    pixelsWide:canvas
                    pixelsHigh:canvas
                 bitsPerSample:8
               samplesPerPixel:4
                      hasAlpha:YES
                      isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace
                   bytesPerRow:0
                  bitsPerPixel:0];
  if (out_rep == nil) {
    [out release];
    return nil;
  }
  [out addRepresentation:out_rep];
  [out_rep release];
  NSGraphicsContext *ctx = [NSGraphicsContext
      graphicsContextWithBitmapImageRep:out_rep];
  if (ctx == nil) {
    [out release];
    return nil;
  }
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:ctx];
  NSRectFillUsingOperation(NSMakeRect(0, 0, canvas, canvas),
                           NSCompositingOperationClear);
  /* 源的内容矩形：位图坐标（左上原点）→ 图像坐标（左下原点），像素 →
   * 点——NSImage 的点尺寸与像素尺寸在我这份资产里是 1:1，但别把这个当契约。 */
  CGFloat sx = [src size].width / (CGFloat)pw;
  CGFloat sy = [src size].height / (CGFloat)ph;
  NSRect from = NSMakeRect((CGFloat)bx * sx,
                           (CGFloat)(ph - (by + bh)) * sy,
                           (CGFloat)bw * sx,
                           (CGFloat)bh * sy);
  double body = (double)canvas * MOONUI_ICON_BODY_RATIO;
  double scale = body / (double)content_max;
  double dw = (double)bw * scale;
  double dh = (double)bh * scale;
  NSRect dst = NSMakeRect(((double)canvas - dw) / 2.0,
                          ((double)canvas - dh) / 2.0,
                          dw,
                          dh);
  [src drawInRect:dst
         fromRect:from
        operation:NSCompositingOperationSourceOver
         fraction:1.0
   respectFlipped:NO
            hints:@{
              NSImageHintInterpolation : @(NSImageInterpolationHigh)
            }];
  [NSGraphicsContext restoreGraphicsState];
  *content_permille = (int)lround(MOONUI_ICON_BODY_RATIO * 1000.0);
  return out;
}

int moonui_native_set_app_icon(const char *name, int name_len) {
  TRACE("set_app_icon");
  if (NSApp == nil) {
    return -2;
  }
  @autoreleasepool {
    NSString *png = [moonui_native_string_of(name, name_len)
                     stringByAppendingString:@".png"];
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:png];
    if (img == nil) {
      return -1;
    }
    int permille = 0;
    NSImage *fitted = moonui_native_icon_fitted(img, &permille);
    if (fitted != nil) {
      [NSApp setApplicationIconImage:fitted];
      [fitted release];
    } else {
      [NSApp setApplicationIconImage:img];
    }
    [img release];
    moonui_native_app_icon_content_value = permille;
    moonui_native_app_icon_installed = 1;
  }
  return 0;
}

int moonui_native_app_icon_present(void) {
  return moonui_native_app_icon_installed;
}

/* 最后一次装上的图标里，内容占画布的千分比（805 = 已按 Apple 网格留白；
 * 1000 = 满幅）。-1 = 还没装过。测试拿它证明留白真的生效。 */
int moonui_native_app_icon_content_permille(void) {
  return moonui_native_app_icon_content_value;
}

/* ---- 测试脚手架（adapter.h 的那一节）----
 * 三个入口都只装一个数，不落进 runloop 等待：面板还没建，此时没有定时器可挂。 */

/* 装好"ms 毫秒之后按下下一个对话框的第 index 个按钮"，认领与真正按下的过程在上面
 * 的 moonui_native_arm_dismissor。契约（为什么必须有这条、为什么越界要当场报回去）在
 * adapter.h 的测试脚手架那段。 */
int moonui_native_auto_dismiss_dialog(int ms, int index) {
  TRACE("auto_dismiss_dialog");
  if (index < 0 || index > 1) {
    return -1;
  }
  moonui_native_dismiss_after_ms = ms < 0 ? 0 : ms;
  moonui_native_dismiss_index = index;
  return 0;
}

/* 装好"ms 毫秒之后替下一个文件面板按取消"。macOS 15.6 起"替用户按接受"做不到，
 * 这里当场报 -2，证据链在 ../libui-macos/adapter_macos.m 的同名函数注释和 TODO 的
 * T21 行：面板跑在系统 XPC 服务里（com.apple.appkit.xpc.openAndSavePanelService），
 * 客户端这侧 [panel ok:] 是个桩，抛 NSGenericException。真人在真 App 里按 OK 的
 * 产品路径不受影响，死的只是"自动化替按"这一条。 */
int moonui_native_auto_answer_file_dialog(int ms,
                                   const char *path,
                                   int path_len,
                                   int accept) {
  TRACE("auto_answer_file_dialog");
  if (accept != 0) {
    /* 校验在改状态之前做完：报错的这一发不许留下半装好的状态。 */
    if (path == 0 || path_len <= 0) {
      return -1;
    }
    return -2;
  }
  moonui_native_file_answer_after_ms = ms < 0 ? 0 : ms;
  return 0;
}

/* dump 里的组合一栏：读的是 item 自己的 keyEquivalent 和 modifier mask，也就是
 * "Core 给的组合到底落到了菜单项上没有"。修饰键按 C/A/S/M 的固定顺序，一个都没有时写
 * "-"（那是 Core 声明了裸键组合）；键名还原成 Core 的词表（event.mbt 的 "Enter"/"a"）。
 * 格式和 Windows 那一份必须逐字符一致，见 adapter.h。 */
static void moonui_native_menu_dump_combo(NSMenuItem *item, NSMutableString *out) {
  NSString *k = [item keyEquivalent];
  unsigned int flags = (unsigned int)[item keyEquivalentModifierMask];
  NSMutableString *mods = [NSMutableString string];
  unichar c;
  if (k == nil || [k length] == 0) {
    [out appendString:@"."];
    return;
  }
  if ((flags & NSEventModifierFlagControl) != 0) {
    [mods appendString:@"C"];
  }
  if ((flags & NSEventModifierFlagOption) != 0) {
    [mods appendString:@"A"];
  }
  if ((flags & NSEventModifierFlagShift) != 0) {
    [mods appendString:@"S"];
  }
  if ((flags & NSEventModifierFlagCommand) != 0) {
    [mods appendString:@"M"];
  }
  if ([mods length] == 0) {
    [mods appendString:@"-"];
  }
  [out appendString:mods];
  c = [k characterAtIndex:0];
  switch (c) {
    case ' ':
      [out appendString:@"Space"];
      break;
    case 0x09:
      [out appendString:@"Tab"];
      break;
    case 0x0D:
      [out appendString:@"Enter"];
      break;
    case 0x1B:
      [out appendString:@"Escape"];
      break;
    case 0x7F:
      [out appendString:@"Backspace"];
      break;
    default:
      [out appendFormat:@"%C", (unichar)tolower((int)c)];
      break;
  }
}

static void moonui_native_menu_dump_nodes(NSMenu *menu, NSMutableString *out);

static void moonui_native_menu_dump_node(NSMenuItem *item, NSMutableString *out) {
  NSNumber *role;
  if ([item isSeparatorItem]) {
    [out appendString:@"-"];
    return;
  }
  if ([item submenu] != nil) {
    [out appendFormat:@"+%@{", [item title]];
    moonui_native_menu_dump_nodes([item submenu], out);
    [out appendString:@"}"];
    return;
  }
  /* 三种形状之外就是"这棵不是我们装的"：跳过它，让测试的字符串断言红在那里，
   * 而不是在这里编一个假的条目。 */
  if ([item action] != @selector(moonuiMenuItemClicked:)) {
    return;
  }
  role = [item representedObject];
  [out appendFormat:@"#%d:", (int)[item tag]];
  if (role == nil || [role intValue] == 0) {
    [out appendString:@"n."];
  } else if ([role intValue] == 1) {
    [out appendString:[item state] == NSControlStateValueOn ? @"c+" : @"c-"];
  } else {
    [out appendString:[item state] == NSControlStateValueOn ? @"r+" : @"r-"];
  }
  [out appendString:[item isEnabled] ? @"e" : @"d"];
  [out appendFormat:@":%@:", [item title]];
  moonui_native_menu_dump_combo(item, out);
}

static void moonui_native_menu_dump_nodes(NSMenu *menu, NSMutableString *out) {
  NSArray *items = [menu itemArray];
  NSUInteger i;
  for (i = 0; i < [items count]; ++i) {
    if (i > 0) {
      [out appendString:@","];
    }
    moonui_native_menu_dump_node([items objectAtIndex:i], out);
  }
}

/* 只给测试用：把当下这棵原生菜单截成一根文本（格式在 adapter.h）。
 *
 * 遍历的是 `[NSApp mainMenu]` 而不是自己记的那份名单：名单是我们抄的，抄得像但没真正
 * 挂上主菜单，读名单的 dump 会照样绿。属于我们的那几顶用 `containsObject:` 认出来，
 * 于是既不数索引（那靠的是别人的顺序），也不会把别的什么对象挂进来的菜单读进来。 */
moonbit_bytes_t moonui_native_menu_dump(void) {
  TRACE("menu_dump");
  @autoreleasepool {
    NSMutableString *out = [NSMutableString string];
    NSMenu *main_menu = [NSApp mainMenu];
    NSUInteger i;
    int first = 1;
    if (main_menu == nil || moonui_native_menu_items == nil) {
      return moonbit_make_bytes(0, 0);
    }
    NSArray *tops = [main_menu itemArray];
    for (i = 0; i < [tops count]; ++i) {
      NSMenuItem *top = [tops objectAtIndex:i];
      if (![moonui_native_menu_items containsObject:top]) {
        continue;
      }
      if (!first) {
        [out appendString:@";"];
      }
      first = 0;
      [out appendFormat:@"%@{", [top title]];
      moonui_native_menu_dump_nodes([top submenu], out);
      [out appendString:@"}"];
    }
    if ([out length] == 0) {
      return moonbit_make_bytes(0, 0);
    }
    return moonui_native_bytes_of_ns(out);
  }
}

/* 只给测试用：等价于"用户在原生菜单里点了 id 这一项"。查 id 和派发都走原生对象自己
 * （按 tag 找、`performActionForItemAtIndex:` 派发），不是把 MoonBit 的回调直接调一遍
 * ——于是 tag 带回来的 id、target 那层桥、Core 的 MenuSelect 路由全被跑过。
 * 禁用那一支在这里先拦：`performActionForItemAtIndex:` 自己会尊重 isEnabled 而什么都不
 * 做，那就成了"什么也没发生但报 0"，而 adapter.h 要求两边报同一套码。 */
int moonui_native_menu_click_item(int id) {
  TRACE("menu_click_item");
  @autoreleasepool {
    NSMenuItem *item = moonui_native_menu_find_id(id);
    NSMenu *menu;
    NSInteger index;
    if (item == nil) {
      return -1;
    }
    menu = [item menu];
    index = menu == nil ? -1 : [menu indexOfItem:item];
    if (index < 0) {
      return -1;
    }
    if (![item isEnabled]) {
      return -2;
    }
    [menu performActionForItemAtIndex:index];
  }
  return 0;
}

/* ---- worker 与跨线程投递（`T85①`，adapter.h 的 worker 段注）----
 *
 * worker 是平台线程（pthread_create 一小段；为什么不是 MoonBit 侧一条、引用
 * 回收为什么统一在接收侧，都记在 adapter.h 的段注里）。一次投递一次线程，
 * 生命周期归 worker 自己：线程函数返回即退场，spawn 侧 detach 不 join——契约
 * 是 work 必须返回。共享状态只有"没有"：没有挂起表、没有取消口，两支闭包的
 * 引用都在 spawn 侧 incref、在各自的执行点回收（work 那份由 worker 回收、
 * land 那份由主队列的落地 block 回收），跨界递增递减的形状由 pthread 探针
 * 钉过（tests/ffi 的同形测试）。 */

typedef struct {
  moonui_closure_fn work_call;
  void *work_closure;
  moonui_closure_fn land_call;
  void *land_closure;
} MoonuiWorkerParams;

/* worker 线程入口：跑 work 闭包、回收它自己那份，然后把落地投回主队列。落地
 * block 捕的是指针副本，主队列运行它的时候 UI 线程执行 land 闭包——落地动作
 * 是 MoonBit 侧的 app.post（排队、下一圈且排在事件前），不在泵的回调栈里碰树。 */
static void *moonui_worker_main(void *arg) {
  MoonuiWorkerParams *p = (MoonuiWorkerParams *)arg;
  moonui_closure_fn land_call;
  void *land_closure;
  p->work_call(p->work_closure);
  moonbit_decref(p->work_closure);
  land_call = p->land_call;
  land_closure = p->land_closure;
  free(p);
  dispatch_async(dispatch_get_main_queue(), ^{
    land_call(land_closure);
    moonbit_decref(land_closure);
  });
  return 0;
}

int moonui_native_worker_run(moonui_closure_fn work_call, void *work_closure,
                             moonui_closure_fn land_call, void *land_closure) {
  pthread_t thread;
  MoonuiWorkerParams *p;
  TRACE("worker_run");
  if (work_call == 0 || work_closure == 0 || land_call == 0 || land_closure == 0) {
    return -1;
  }
  /* 两支闭包都由这条机制看守（AppKit/GCD 只存函数指针，GC 看不见它们）：
   * incref 在 spawn 前拿住，各自的执行点回收。起跑失败的每一步都把引用退干净。 */
  moonbit_incref(work_closure);
  moonbit_incref(land_closure);
  p = (MoonuiWorkerParams *)malloc(sizeof(MoonuiWorkerParams));
  if (p == 0) {
    moonbit_decref(work_closure);
    moonbit_decref(land_closure);
    return -1;
  }
  p->work_call = work_call;
  p->work_closure = work_closure;
  p->land_call = land_call;
  p->land_closure = land_closure;
  if (pthread_create(&thread, 0, moonui_worker_main, p) != 0) {
    moonbit_decref(work_closure);
    moonbit_decref(land_closure);
    free(p);
    return -1;
  }
  pthread_detach(thread);
  return 0;
}

/* ---- 输入法组合事件源（`T85②`，adapter.h 的 IME 段注）----
 *
 * 组合监听是进程全局的一份，与菜单回调同一套形状（不占槽位表）：terminate 和
 * "换一次回调"都走 drop。相位快照照 §48-16 的约定：写好在调闭包之前、闭包返回
 * 之后没人再动，一次通知配一次读。 */

static moonui_closure_fn moonui_native_ime_fn = 0;
static void *moonui_native_ime_closure = 0;

/* target 是正在组合的那只我们的 view（0 = 反查不到），phase 见 adapter.h 编码，
 * text 是组合串的 UTF-8（起始/结束为空串）。 */
static NSView *moonui_native_ime_target_view = nil;
static int moonui_native_ime_phase_now = 0;
static char *moonui_native_ime_text_bytes = 0;

/* 组合中的前态：单独记在控件身上（关联对象，与 kind 记号同一套手法）——两个框
 * 先后组合时各记各的，不借进程级一份。存 1 = 在组合中、2 = 不在，0 = 没记过
 * （按不在算，第一条标记串照常发"开始"）。 */
static const void *const moonui_native_ime_prev_key = &moonui_native_ime_prev_key;

static void moonui_native_ime_mark_prev(NSView *v, BOOL composing) {
  objc_setAssociatedObject(v, moonui_native_ime_prev_key,
                           (id)(uintptr_t)(composing ? 1 : 2),
                           OBJC_ASSOCIATION_ASSIGN);
}

static BOOL moonui_native_ime_prev_of(NSView *v) {
  uintptr_t raw;
  if (v == nil) {
    return NO;
  }
  raw = (uintptr_t)objc_getAssociatedObject(v, moonui_native_ime_prev_key);
  return raw == 1;
}

static void moonui_native_ime_drop_closure(void) {
  if (moonui_native_ime_closure != 0) {
    moonbit_decref(moonui_native_ime_closure);
    moonui_native_ime_closure = 0;
  }
  moonui_native_ime_fn = 0;
}

int moonui_native_on_ime(moonui_closure_fn fn, void *closure) {
  TRACE("on_ime");
  moonui_native_ime_drop_closure();
  moonui_native_ime_fn = fn;
  moonui_native_ime_closure = closure;
  if (closure != 0) {
    moonbit_incref(closure);
  }
  return 0;
}

moonui_ptr moonui_native_ime_target(void) {
  TRACE("ime_target");
  return (moonui_ptr)(uintptr_t)moonui_native_ime_target_view;
}

int moonui_native_ime_phase(void) {
  TRACE("ime_phase");
  return moonui_native_ime_phase_now;
}

moonbit_bytes_t moonui_native_ime_text(void) {
  TRACE("ime_text");
  if (moonui_native_ime_text_bytes == 0) {
    return moonbit_make_bytes(0, 0);
  }
  return moonui_native_bytes_of(moonui_native_ime_text_bytes);
}

/* 写相位快照再调监听。text 传 nil = 这条相位不带组合串（起始/结束；对齐
 * Win32 半的 START/END）。快照里的 UTF-8 是 strdup 下来的，下一条快照覆盖前
 * 没人动它。 */
static void moonui_native_ime_notify(NSView *target, int phase, NSString *text) {
  const char *u;
  if (moonui_native_ime_fn == 0) {
    return;
  }
  moonui_native_ime_target_view = target;
  moonui_native_ime_phase_now = phase;
  free(moonui_native_ime_text_bytes);
  moonui_native_ime_text_bytes = 0;
  u = text != nil ? [text UTF8String] : 0;
  moonui_native_ime_text_bytes = moonui_native_dup(u != 0 ? u : "", u != 0 ? (int)strlen(u) : 0);
  moonui_native_ime_fn(moonui_native_ime_closure);
}

/* 组合相位从 field editor 的标记串推（NSTextView.markedRange 与
 * -[NSWindow fieldEditor:forObject:] 已编译查证）。派发器只收单行文本框
 * （kind 2/4）；纯打字（前后都不在组合中）不产相位事件；从无到有的切换沿先发
 * "开始"（不带串）再发"进行"（带当下的标记串）——一次 AppKit 通知发两条相位，
 * 序列与 Win32 半的 START→COMPSTR₁ 对齐，两边的事件计数一致（`T85②`）。 */
static void moonui_native_ime_derive(NSView *control) {
  int kind = moonui_native_widget_kind_of(control);
  NSWindow *win;
  NSTextView *editor;
  NSRange marked;
  BOOL composing;
  BOOL prev;
  if (moonui_native_ime_fn == 0 || (kind != 2 && kind != 4)) {
    return;
  }
  win = [control window];
  if (win == nil) {
    return;
  }
  editor = (NSTextView *)[win fieldEditor:NO forObject:control];
  marked = editor != nil ? [editor markedRange] : NSMakeRange(NSNotFound, 0);
  composing = marked.location != NSNotFound && marked.length > 0;
  prev = moonui_native_ime_prev_of(control);
  if (composing == prev) {
    if (composing) {
      /* 组合中且串变了 */
      moonui_native_ime_notify(control, 1,
                               [[editor string] substringWithRange:marked]);
    }
    moonui_native_ime_mark_prev(control, composing);
    return;
  }
  if (composing) {
    /* 从无到有：开始 + 进行（两条相位，串跟在后一条上） */
    moonui_native_ime_notify(control, 0, nil);
    moonui_native_ime_notify(control, 1,
                             [[editor string] substringWithRange:marked]);
  } else {
    /* 从有到无：上屏或取消（结束不带串，上屏全文随既有文本变化通道走） */
    moonui_native_ime_notify(control, 2, nil);
  }
  moonui_native_ime_mark_prev(control, composing);
}

/* =====================================================================
 * `T86` 的四段（右键事件源、上下文菜单、文件拖入、托盘与通知）
 *
 * 四段的共同形状：进程级一份闭包（不占槽位表，与菜单栏/组合监听同一套）、
 * "通知不带内容，读口当场取"。闭包都由本侧 incref 看守、terminate 松开。
 * ===================================================================== */

/* ---- 右键按下的事件源（`T86①`，进程级鼠标监听的 mac 半）----
 *
 * 契约在 adapter.h 的「鼠标与滚动」段注（`T39` 那批立的形状）：监听进程一份、
 * kind/button/pos 当场读回。本轮 mac 半只接**右键按下**那一支（`T86①` 的判据
 * 是右键事件的命中路由）——左键按下的既有消费者是控件回调发的 Click，其余
 * kind（抬起/拖动/双击/滚轮）沿 libui 那份的形状移植时再接，缺席记在 `T86①`
 * 的报告里。监听用本地事件监听（进程内，不动前台归属，键盘那半同一条理由）。
 *
 * 命中反查两步：hitTest 从 contentView 退到最深 view，再沿 superview 链退到
 * 第一个带 owner 记号的（finish_widget 打的），报出的指针就是 moonui_ptr
 * （本文件里指针就是 view 本身）。MoonBit 侧拿指针扫存活控件认句柄。
 * pos 的口径照 adapter.h：命中窗口客户区左上角为原点、y 向下、物理像素——
 * locationInWindow 是窗口坐标（y 向上），先换进 contentView 坐标再翻 y。 */

static moonui_closure_fn moonui_native_mouse_fn = 0;
static void *moonui_native_mouse_closure = 0;
static moonui_ptr moonui_native_mouse_target_ptr = 0;
static int moonui_native_mouse_code = 0;
static int moonui_native_mouse_px = 0;
static int moonui_native_mouse_py = 0;
/* 滚动增量（逻辑像素，kind 4 才有值，其余恒 0）：换算在 C 里做完（adapter.h
 * 鼠标段注的口径），MoonBit 不许再除一次。 */
static int moonui_native_mouse_ldx = 0;
static int moonui_native_mouse_ldy = 0;
static id moonui_native_mouse_monitor = nil;

static void moonui_native_mouse_drop_closure(void) {
  if (moonui_native_mouse_monitor != nil) {
    [NSEvent removeMonitor:moonui_native_mouse_monitor];
    moonui_native_mouse_monitor = nil;
  }
  if (moonui_native_mouse_closure != 0) {
    moonbit_decref(moonui_native_mouse_closure);
    moonui_native_mouse_closure = 0;
  }
  moonui_native_mouse_fn = 0;
}

/* superview 链上第一个带 owner 记号的 view；没有就 nil。 */
static NSView *moonui_native_hit_owner(NSView *hit) {
  NSView *v;
  for (v = hit; v != nil; v = [v superview]) {
    if (objc_getAssociatedObject(v, moonui_native_owner_key) != nil) {
      return v;
    }
  }
  return nil;
}

static void moonui_native_mouse_notify(moonui_ptr target, int code, int px, int py,
                                       int ldx, int ldy) {
  if (moonui_native_mouse_fn == 0) {
    return;
  }
  moonui_native_mouse_target_ptr = target;
  moonui_native_mouse_code = code;
  moonui_native_mouse_px = px;
  moonui_native_mouse_py = py;
  moonui_native_mouse_ldx = ldx;
  moonui_native_mouse_ldy = ldy;
  moonui_native_mouse_fn(moonui_native_mouse_closure);
}

int moonui_native_on_mouse(moonui_closure_fn fn, void *closure) {
  TRACE("on_mouse");
  /* 重复调用只换回调，监听还是那一份（adapter.h 的契约）。 */
  moonui_native_mouse_drop_closure();
  moonui_native_mouse_fn = fn;
  moonui_native_mouse_closure = closure;
  if (closure != 0) {
    moonbit_incref(closure);
  }
  if (moonui_native_mouse_monitor == nil) {
    /* 右键按下（`T86①` 右键菜单的消费者）+ 移动/拖拽（悬停通道，kind 2）
     * + 左键按下/抬起（§52 分期③：自绘后端的命中测试靠它们——自绘控件没有
     * 原生对象，空白即整窗，所以左键这两颗在空白处也报窗口自己；原生后端
     * 的 MoonBit 闭包对这两个编码不翻译，行为不变）+ 滚轮（kind 4，T98①）
     * + 中键按下/抬起（button 2，T98①）+ 左键双击（clickCount>=2，kind 3，
     * T98①）。滚轮/中键/双击在空白处也报窗口自己——自绘后端的命中测试靠
     * 坐标反查，空白即整窗；原生后端的闭包对这三类编码不翻译（滚轮归
     * NSScrollView 自己、中键/双击无原生消费者），行为不变。右键按下在空白
     * 照旧丢（右键菜单只认控件）。
     *
     * 离开窗口从 kind 3 挪到 kind 5（T98①）：adapter.h 的词表把 kind 3 留给
     * 双击（Windows 的 WM_*BUTTONDBLCLK 一直报 kind 3），mac 原来拿 kind 3 当
     * "cursor 离开窗口"是悬停通道那批的临时占位——现在双击要进这条 ABI，kind 3
     * 让出来，离开挪到词表外的 kind 5。两个 MoonBit 闭包（原生 backend.mbt、
     * 自绘 mouse.mbt）的"移动/离开"判定同步从 `== 3` 改成 `== 5`。 */
    moonui_native_mouse_monitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown |
            NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
            NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
            NSEventMaskMouseExited | NSEventMaskScrollWheel |
            NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp
                                     handler:^NSEvent *(NSEvent *e) {
                                       NSWindow *win;
                                       NSView *content;
                                       NSView *hit;
                                       NSView *owner;
                                       NSPoint loc;
                                       NSPoint in_content;
                                       moonui_ptr target;
                                       int code;
                                       int moved;
                                       int left_press;
                                       int wheel;
                                       int other_press;
                                       int ldx = 0;
                                       int ldy = 0;
                                       if (moonui_native_mouse_fn == 0) {
                                         return e;
                                       }
                                       win = [e window];
                                       if (win == nil) {
                                         return e;
                                       }
                                       content = [win contentView];
                                       if (content == nil) {
                                         return e;
                                       }
                                       moved = ([e type] == NSEventTypeMouseMoved) ||
                                           ([e type] == NSEventTypeLeftMouseDragged) ||
                                           ([e type] == NSEventTypeMouseExited);
                                       /* 左键按下/抬起（§52 分期③：自绘后端的命中
                                        * 测试靠它们——自绘控件没有原生对象，空白
                                        * 即整窗）。原生后端的监听闭包对这两个编码
                                        * 不翻译，行为不变。 */
                                       left_press =
                                           ([e type] == NSEventTypeLeftMouseDown) ||
                                           ([e type] == NSEventTypeLeftMouseUp);
                                       wheel = ([e type] == NSEventTypeScrollWheel);
                                       other_press =
                                           ([e type] == NSEventTypeOtherMouseDown) ||
                                           ([e type] == NSEventTypeOtherMouseUp);
                                       /* 滚轮增量（逻辑像素，kind 4 才有值）：换算在 C
                                        * 里做完（adapter.h 鼠标段注的口径），MoonBit 不
                                        * 许再除一次。hasPreciseScrollingDeltas 时
                                        * scrollingDeltaX/Y 已经是点；逐行滚轮（旗标 0）
                                        * 读回的是行数，乘 CGEventSourceGetPixelsPerLine
                                        * 才换成点（本机实测 10.0，别写死）。方向按
                                        * isDirectionInvertedFromDevice 取反——AppKit 已
                                        * 照系统"自然滚动"偏好翻过一次，这里读旗标不猜。 */
                                       if (wheel) {
                                         CGFloat dx = [e scrollingDeltaX];
                                         CGFloat dy = [e scrollingDeltaY];
                                         if ([e hasPreciseScrollingDeltas]) {
                                           ldx = (int)llround(dx);
                                           ldy = (int)llround(dy);
                                         } else {
                                           CGFloat ppl =
                                               CGEventSourceGetPixelsPerLine(NULL);
                                           ldx = (int)llround(dx * ppl);
                                           ldy = (int)llround(dy * ppl);
                                         }
                                         if ([e isDirectionInvertedFromDevice]) {
                                           ldx = -ldx;
                                           ldy = -ldy;
                                         }
                                       }
                                       hit = [content hitTest:[e locationInWindow]];
                                       owner = moonui_native_hit_owner(hit);
                                       /* 滚轮恒报窗口自己（2026-10-18）：
                                        * 滚轮是**整窗手势**——应用侧要的是"在窗口
                                        * 上滚一下调音量"这类，而控件级消费者在原生
                                        * 后端上不存在（NSScrollView 自己吃掉滚动）。
                                        * 报控件还会让自绘半找不到窗口（它按 ptr 反查
                                        * 窗口，命中控件时 wi<0 整条丢）——报窗口后
                                        * 自绘半再按坐标命中改写回控件，两半都通。 */
                                       if (owner == nil || wheel) {
                                         if (!moved && !left_press && !wheel &&
                                             !other_press) {
                                           /* 空白处不产事件：target 只认我们的控件
                                            * （adapter.h 鼠标段注的契约）。 */
                                           return e;
                                         }
                                         /* 移动/离开/左键/滚轮/中键落在空白：报窗口自己 */
                                         target = (moonui_ptr)(uintptr_t)win;
                                       } else {
                                         target = (moonui_ptr)(uintptr_t)owner;
                                       }
                                       if ([e type] == NSEventTypeMouseExited) {
                                         code = 5 * 8; /* kind 5 离开窗口（T98① 从 3 挪来） */
                                       } else if (wheel) {
                                         code = 4 * 8; /* kind 4 滚轮、button 位无意义恒 0 */
                                       } else if (moved) {
                                         code = 2 * 8; /* kind 2 移动 */
                                       } else if ([e type] == NSEventTypeLeftMouseDown) {
                                         /* 第二次按下只产 kind 3（双击），不再产 kind 0
                                          * （adapter.h 鼠标段注的契约，与 Windows 的
                                          * WM_LBUTTONDBLCLK 取代第二颗 DOWN 同一条）。 */
                                         if ([e clickCount] >= 2) {
                                           code = 3 * 8 + 0; /* kind 3 双击、button 0 左键 */
                                         } else {
                                           code = 0 * 8 + 0; /* kind 0 按下、button 0 左键 */
                                         }
                                       } else if ([e type] == NSEventTypeLeftMouseUp) {
                                         code = 1 * 8 + 0; /* kind 1 抬起、button 0 左键 */
                                       } else if ([e type] == NSEventTypeOtherMouseDown) {
                                         code = 0 * 8 + 2; /* kind 0 按下、button 2 中键 */
                                       } else if ([e type] == NSEventTypeOtherMouseUp) {
                                         code = 1 * 8 + 2; /* kind 1 抬起、button 2 中键 */
                                       } else {
                                         code = 0 * 8 + 1; /* kind 0 按下、button 1 右键 */
                                       }
                                       loc = [e locationInWindow];
                                       in_content = [content convertPoint:loc
                                                                 fromView:nil];
                                       moonui_native_mouse_notify(
                                           target, code,
                                           moonui_native_pt_to_px(
                                               in_content.x,
                                               moonui_native_window_scale_of(win)),
                                           moonui_native_pt_to_px(
                                               [content bounds].size.height - in_content.y,
                                               moonui_native_window_scale_of(win)),
                                           ldx, ldy);
                                       return e;
                                     }];
  }
  return 0;
}

moonui_ptr moonui_native_mouse_target(void) {
  TRACE("mouse_target");
  return moonui_native_mouse_target_ptr;
}

int moonui_native_mouse_kind_button(void) {
  TRACE("mouse_kind_button");
  return moonui_native_mouse_code;
}

int64_t moonui_native_mouse_pos(void) {
  TRACE("mouse_pos");
  return moonui_native_pack2(moonui_native_mouse_px, moonui_native_mouse_py);
}

int64_t moonui_native_mouse_delta(void) {
  TRACE("mouse_delta");
  return moonui_native_pack2(moonui_native_mouse_ldx, moonui_native_mouse_ldy);
}

/* ---- 键盘与焦点（§10 的 KeyDown/KeyUp、§26 的快捷键、§32 的 focused；`T91`）----
 *
 * 契约全文在 adapter.h 的键盘段注（词表、修饰键位、主菜单认领、焦点反查"问而不
 * 报"），这里是 mac 半。和鼠标段同一条形状：进程级 local monitor 一份，通知不带
 * 内容，四样当场读回（target / is_down / modifiers / name）。归属反查按键盘的
 * 规矩走焦点而不是走坐标——当下 firstResponder（可能是文本框的 field editor，
 * `moonui_native_hit_owner` 会把它退到包住它的那只文本框，和鼠标的命中反查同
 * 一张 owner 表）。 */

static moonui_closure_fn moonui_native_key_fn = 0;
static void *moonui_native_key_closure = 0;
static moonui_ptr moonui_native_key_target_ptr = 0;
static int moonui_native_key_down = 0;
static int moonui_native_key_mods = 0;
static char moonui_native_key_snapshot_name[16] = "";
static id moonui_native_key_monitor = nil;

static void moonui_native_key_drop_closure(void) {
  if (moonui_native_key_monitor != nil) {
    [NSEvent removeMonitor:moonui_native_key_monitor];
    moonui_native_key_monitor = nil;
  }
  if (moonui_native_key_closure != 0) {
    moonbit_decref(moonui_native_key_closure);
    moonui_native_key_closure = 0;
  }
  moonui_native_key_fn = 0;
}

/* 键码表只列"名字不等于字符自己"的那些键（词表见 adapter.h 键盘段注）。数字
 * 直接写死 Carbon 的虚拟键码，不引 <Carbon/Carbon.h>——那份头会把整个
 * HIToolbox 拖进来，我们只要这二十几个数。Insert 没有 mac 的键，表里没有它。 */
enum {
  MOONUI_VK_RETURN = 0x24,       /* Enter */
  MOONUI_VK_TAB = 0x30,
  MOONUI_VK_ESCAPE = 0x35,
  MOONUI_VK_BACKSPACE = 0x33,
  MOONUI_VK_FORWARD_DELETE = 0x75, /* Delete */
  MOONUI_VK_HOME = 0x73,
  MOONUI_VK_END = 0x77,
  MOONUI_VK_PAGE_UP = 0x74,
  MOONUI_VK_PAGE_DOWN = 0x79,
  MOONUI_VK_LEFT = 0x7B,
  MOONUI_VK_RIGHT = 0x7C,
  MOONUI_VK_DOWN = 0x7D,
  MOONUI_VK_UP = 0x7E,
  MOONUI_VK_F1 = 0x7A,
  MOONUI_VK_F2 = 0x78,
  MOONUI_VK_F3 = 0x63,
  MOONUI_VK_F4 = 0x76,
  MOONUI_VK_F5 = 0x60,
  MOONUI_VK_F6 = 0x61,
  MOONUI_VK_F7 = 0x62,
  MOONUI_VK_F8 = 0x64,
  MOONUI_VK_F9 = 0x65,
  MOONUI_VK_F10 = 0x6D,
  MOONUI_VK_F11 = 0x67,
  MOONUI_VK_F12 = 0x6F,
};

/* 键码 → 词表名；不在表里给 NULL。 */
static const char *moonui_native_key_name_of_code(unsigned short code) {
  switch (code) {
    case MOONUI_VK_RETURN: return "Enter";
    case MOONUI_VK_TAB: return "Tab";
    case MOONUI_VK_ESCAPE: return "Escape";
    case MOONUI_VK_BACKSPACE: return "Backspace";
    case MOONUI_VK_FORWARD_DELETE: return "Delete";
    case MOONUI_VK_HOME: return "Home";
    case MOONUI_VK_END: return "End";
    case MOONUI_VK_PAGE_UP: return "PageUp";
    case MOONUI_VK_PAGE_DOWN: return "PageDown";
    case MOONUI_VK_LEFT: return "Left";
    case MOONUI_VK_RIGHT: return "Right";
    case MOONUI_VK_DOWN: return "Down";
    case MOONUI_VK_UP: return "Up";
    case MOONUI_VK_F1: return "F1";
    case MOONUI_VK_F2: return "F2";
    case MOONUI_VK_F3: return "F3";
    case MOONUI_VK_F4: return "F4";
    case MOONUI_VK_F5: return "F5";
    case MOONUI_VK_F6: return "F6";
    case MOONUI_VK_F7: return "F7";
    case MOONUI_VK_F8: return "F8";
    case MOONUI_VK_F9: return "F9";
    case MOONUI_VK_F10: return "F10";
    case MOONUI_VK_F11: return "F11";
    case MOONUI_VK_F12: return "F12";
    default: return NULL;
  }
}

/* 把这颗键的名字写进 out（最长 "Backspace"，16 字节缓冲绰绰有余）。词表以外
 * 留空串，MoonBit 据此丢掉这颗键——宁可不产事件，也不产一个 Core 匹配不到的
 * 名字。修饰键自己不在词表里，所以按 ⌘ 本身不产事件，只改修饰键那四位。
 * 归一化在 adapter.h 钉死：字母/数字取 charactersIgnoringModifiers 的第一个
 * 码元并折小写（Shift 走修饰键位，不把字母变大写），空格给 "Space"，其余查
 * 键码表。 */
static void moonui_native_key_read_name(NSEvent *e, char *out) {
  NSString *chars;
  const char *name;
  out[0] = '\0';
  @autoreleasepool {
    chars = [e charactersIgnoringModifiers];
    if (chars != nil && [chars length] > 0) {
      unichar u = [chars characterAtIndex:0];
      if ((u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z') ||
          (u >= '0' && u <= '9')) {
        if (u >= 'A' && u <= 'Z') {
          u = (unichar)(u + ('a' - 'A'));
        }
        out[0] = (char)u;
        out[1] = '\0';
        return;
      }
      if (u == ' ') {
        out[0] = 'S';
        out[1] = 'p';
        out[2] = 'a';
        out[3] = 'c';
        out[4] = 'e';
        out[5] = '\0';
        return;
      }
    }
    name = moonui_native_key_name_of_code([e keyCode]);
    if (name != NULL) {
      size_t i;
      for (i = 0; name[i] != '\0' && i < 15; ++i) {
        out[i] = name[i];
      }
      out[i] = '\0';
    }
  }
}

/* NSEvent 修饰键位 → adapter.h 的四位打包：bit0 ctrl（Control）、bit1 alt
 * （Option）、bit2 shift、bit3 meta（Command——物理 ⌘ 在 Core 记 meta，`ctrl`
 * 留给物理 Ctrl，Shortcut 两侧按同一张表）。 */
static int moonui_native_mods_of_flags(NSUInteger flags) {
  int mods = 0;
  if ((flags & NSEventModifierFlagControl) != 0) {
    mods |= 1;
  }
  if ((flags & NSEventModifierFlagOption) != 0) {
    mods |= 2;
  }
  if ((flags & NSEventModifierFlagShift) != 0) {
    mods |= 4;
  }
  if ((flags & NSEventModifierFlagCommand) != 0) {
    mods |= 8;
  }
  return mods;
}

/* 这只窗口是不是我们的（在强引用表里）。键归属的窗口半走这张表。 */
static moonui_ptr moonui_native_window_owner_of(NSWindow *win) {
  if (win == nil || moonui_native_live_windows == nil) {
    return 0;
  }
  for (NSUInteger i = 0; i < [moonui_native_live_windows count]; ++i) {
    NSWindow *ours = [moonui_native_live_windows objectAtIndex:i];
    if (ours == win) {
      return (moonui_ptr)(uintptr_t)win;
    }
  }
  return 0;
}

/* 主菜单认领（adapter.h 的 mac 规则）：装了 keyEquivalent 之后 AppKit 自己
 * 派发这组键，于是同一个 ⌘Q 既有菜单动作、又有 Core 的 KeyDown 匹配，处理
 * 函数跑两遍。这里按 keyEquivalent + keyEquivalentModifierMask 精确匹配整棵
 * 树（含子菜单、含禁用项——收不收是 AppKit 的事，我们只判断形状），收了就
 * 不产 KeyDown/KeyUp，让 MenuSelect 那条路走。 */
static BOOL moonui_native_menu_claims(NSMenu *menu, unichar key, NSUInteger mods) {
  if (menu == nil) {
    return NO;
  }
  @autoreleasepool {
    for (NSMenuItem *item in [menu itemArray]) {
      NSString *eq = [item keyEquivalent];
      if ([eq length] == 1) {
        unichar k = [eq characterAtIndex:0];
        if (k >= 'A' && k <= 'Z') {
          k = (unichar)(k + ('a' - 'A'));
        }
        if (k == key &&
            (NSUInteger)[item keyEquivalentModifierMask] == mods) {
          return YES;
        }
      }
      if ([item hasSubmenu] &&
          moonui_native_menu_claims([item submenu], key, mods)) {
        return YES;
      }
    }
  }
  return NO;
}

/* Shift+Tab 回退一步（`T66` 的 mac 半）：原生 AppKit 的 Shift+Tab 焦点回退
 * 在我们这套"控件 owner 表 + nextKeyView 环"上不可靠（field editor 占着
 * firstResponder 时它认不出环上的位置），所以在监听里拦下、按环退一步、
 * 吞掉事件。forward 的 Tab 不拦——nextKeyView 环是 set_focus_chain 摆好的，
 * AppKit 自己走得通。退成功返回 YES（调用方吞事件），退不动返回 NO（放行
 * 走默认）。 */
static BOOL moonui_native_tab_backward(void) {
  NSWindow *win = [NSApp keyWindow];
  NSResponder *resp;
  NSView *view;
  NSView *prev;
  if (win == nil) {
    return NO;
  }
  resp = [win firstResponder];
  if (resp == nil || ![resp isKindOfClass:[NSView class]]) {
    return NO;
  }
  /* field editor 是共享 NSTextView，先退到包住它的那只我们的控件。 */
  view = moonui_native_hit_owner((NSView *)resp);
  if (view == nil) {
    return NO;
  }
  /* previousValidKeyView 而不是 previousKeyView：焦点环里混着能收下焦点
   * 但视觉上毫无表示的 view（可选中的 label 之类），literal prev 落在它们
   * 身上时 makeFirstResponder 成功、事件被吞、用户却什么都看不到——表现为
   * "要按两下才退回来"。valid 一档把不可聚焦的环成员跳过去，与前进方向
   * （nextValidKeyView）对称。 */
  prev = [view previousValidKeyView];
  if (prev == nil || prev == view) {
    return NO;
  }
  return [win makeFirstResponder:prev];
}

/* 一颗键的记账与通知：词表外的键（修饰键自己、输入法、媒体键）不产事件——
 * 宁可不报，也不产一个 Core 匹配不到的名字。 */
static void moonui_native_key_notify(
    moonui_ptr target, int down, int mods, NSEvent *e) {
  if (moonui_native_key_fn == 0) {
    return;
  }
  moonui_native_key_read_name(e, moonui_native_key_snapshot_name);
  if (moonui_native_key_snapshot_name[0] == '\0') {
    return;
  }
  moonui_native_key_target_ptr = target;
  moonui_native_key_down = down;
  moonui_native_key_mods = mods;
  moonui_native_key_fn(moonui_native_key_closure);
}

int moonui_native_on_key(moonui_closure_fn fn, void *closure) {
  TRACE("on_key");
  /* 重复调用只换回调，监听还是那一份（adapter.h 的契约）。 */
  moonui_native_key_drop_closure();
  moonui_native_key_fn = fn;
  moonui_native_key_closure = closure;
  if (closure != 0) {
    moonbit_incref(closure);
  }
  if (moonui_native_key_monitor == nil) {
    moonui_native_key_monitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown |
                                                 NSEventMaskKeyUp
                                     handler:^NSEvent *(NSEvent *e) {
                                       NSWindow *win;
                                       NSResponder *resp;
                                       moonui_ptr target;
                                       int down;
                                       int mods;
                                       if (moonui_native_key_fn == 0) {
                                         return e;
                                       }
                                       @autoreleasepool {
                                         down = [e type] == NSEventTypeKeyDown
                                                    ? 1
                                                    : 0;
                                         mods = moonui_native_mods_of_flags(
                                             [e modifierFlags]);
                                         NSString *chars =
                                             [e charactersIgnoringModifiers];
                                         unichar key = (chars != nil &&
                                                           [chars length] > 0)
                                                          ? [chars
                                                                characterAtIndex:
                                                                    0]
                                                          : 0;
                                         if (key >= 'A' && key <= 'Z') {
                                           key = (unichar)(key +
                                                           ('a' - 'A'));
                                         }
                                         /* 主菜单认领的组合不报（只在按下那
                                          * 一次判；抬起照报会多出半颗没人
                                          * 认领的 KeyUp）。 */
                                         if (down && key != 0 &&
                                             moonui_native_menu_claims(
                                                 [NSApp mainMenu], key,
                                                 (NSUInteger)mods)) {
                                           return e;
                                         }
                                         /* Shift+Tab：拦下退一步（`T66`）。
                                          * 挪得动就吞掉，挪不动放行走默认。 */
                                         if (down && (mods & 4) != 0 &&
                                             [e keyCode] == MOONUI_VK_TAB &&
                                             moonui_native_tab_backward()) {
                                           return nil;
                                         }
                                         /* 归属：焦点控件是我们的就报控件，
                                          * 否则报事件窗口（是我们的窗口时），
                                          * 都不是（别的进程的键）不报。 */
                                         win = [NSApp keyWindow];
                                         resp = win != nil
                                                    ? [win firstResponder]
                                                    : nil;
                                         target = 0;
                                         if (resp != nil &&
                                             [resp isKindOfClass:
                                                  [NSView class]]) {
                                           NSView *owner =
                                               moonui_native_hit_owner(
                                                   (NSView *)resp);
                                           if (owner != nil) {
                                             target = (moonui_ptr)(uintptr_t)
                                                 owner;
                                           }
                                         }
                                         if (target == 0) {
                                           target = moonui_native_window_owner_of(
                                               [e window]);
                                         }
                                         if (target != 0) {
                                           moonui_native_key_notify(
                                               target, down, mods, e);
                                         }
                                       }
                                       return e;
                                     }];
  }
  return 0;
}

moonui_ptr moonui_native_key_target(void) {
  TRACE("key_target");
  return moonui_native_key_target_ptr;
}

int moonui_native_key_is_down(void) {
  TRACE("key_is_down");
  return moonui_native_key_down;
}

int moonui_native_key_modifiers(void) {
  TRACE("key_modifiers");
  return moonui_native_key_mods;
}

moonbit_bytes_t moonui_native_key_name(void) {
  TRACE("key_name");
  return moonui_native_bytes_of(moonui_native_key_snapshot_name);
}

moonui_ptr moonui_native_focused_control(moonui_ptr w) {
  NSWindow *win;
  NSResponder *resp;
  NSView *owner;
  TRACE("focused_control");
  win = moonui_native_nswindow(w);
  if (win == nil) {
    return 0;
  }
  @autoreleasepool {
    resp = [win firstResponder];
    if (resp == nil || ![resp isKindOfClass:[NSView class]]) {
      return 0;
    }
    owner = moonui_native_hit_owner((NSView *)resp);
    if (owner == nil) {
      return 0;
    }
    return (moonui_ptr)(uintptr_t)owner;
  }
}

/* ---- 上下文菜单（`T86①`）----
 *
 * 弹窗沿菜单栏那套底座：树是 `moonui_set_menu_bar` 同一份打包（读游标与填充
 * 共用），建出来的 NSMenu 用 `popUpMenuPositioningItem:` 弹在鼠标当下的位置
 * ——这条调用同步阻塞到用户选完或点空白，选中的解析发生在嵌套循环内（落地
 * 注记）。点击回调是进程一份的独立槽位（不与菜单栏共那份 moonui_native_menu_fn，
 * 各弹各的菜单不该互相换回调）。勾选态点击后不回推：弹窗是一次性的，下一次
 * 装树照 Core 的新快照画（段注记在 adapter.h）。
 *
 * 返回码：0 = 弹过（用户选了或点了空白关掉）；-1 = 树不合法；-2 = 没有可以
 * 弹菜单的窗口（连 keyWindow 都没有时弹不出去）。 */

static moonui_closure_id_fn moonui_native_ctx_fn = 0;
static void *moonui_native_ctx_closure = 0;

@interface MoonuiNativeCtxTarget : NSObject
- (void)moonuiCtxClicked:(NSMenuItem *)item;
@end

@implementation MoonuiNativeCtxTarget
- (void)moonuiCtxClicked:(NSMenuItem *)item {
  if (moonui_native_ctx_fn != 0 && moonui_native_ctx_closure != 0) {
    moonui_native_ctx_fn(moonui_native_ctx_closure, (int)[item tag]);
  }
}
@end

/* +1 一直持到进程退出，与菜单栏的 target 同一套规矩。 */
static MoonuiNativeCtxTarget *moonui_native_ctx_target = nil;

static void moonui_native_ctx_drop_closure(void) {
  if (moonui_native_ctx_closure != 0) {
    moonbit_decref(moonui_native_ctx_closure);
    moonui_native_ctx_closure = 0;
  }
  moonui_native_ctx_fn = 0;
}

int moonui_native_show_context_menu(const char *tree,
                             int tree_len,
                             moonui_closure_id_fn fn,
                             void *closure) {
  MoonuiTree t;
  NSMenu *menu;
  NSWindow *win;
  NSPoint loc;
  TRACE("show_context_menu");
  if (!moonui_native_inited) {
    return -2;
  }
  /* 最短的合法树是 version(1 字节) + count(i32)。 */
  if (tree == 0 || tree_len < 5) {
    return -1;
  }
  @autoreleasepool {
    win = [NSApp keyWindow] != nil
              ? [NSApp keyWindow]
              : (moonui_native_live_windows != nil &&
                         moonui_native_live_windows.count > 0
                     ? (NSWindow *)moonui_native_live_windows[0]
                     : nil);
    if (win == nil) {
      return -2;
    }
    t.p = (const unsigned char *)tree;
    t.len = tree_len;
    t.pos = 0;
    t.bad = 0;
    if (moonui_native_tree_u8(&t) != 1 || moonui_native_tree_i32(&t) < 1 ||
        t.bad) {
      return -1;
    }
    menu = moonui_native_menu_new(moonui_native_tree_str(&t));
    if (t.bad ||
        !moonui_native_menu_fill(menu, &t, moonui_native_tree_i32(&t)) || t.bad) {
      return -1;
    }
    if (moonui_native_ctx_target == nil) {
      moonui_native_ctx_target = [[MoonuiNativeCtxTarget alloc] init];
    }
    /* 可点项的 target 全部换成上下文菜单自己的那份回调：建好的树里各 item 的
     * target 是菜单栏那份，逐个换掉（分隔线没有 action，不用换）。 */
    for (NSMenuItem *item in [menu itemArray]) {
      moonui_native_ctx_retarget(item);
    }
    moonui_native_ctx_drop_closure();
    moonui_native_ctx_fn = fn;
    if (closure != 0) {
      moonbit_incref(closure);
      moonui_native_ctx_closure = closure;
    }
    /* 弹在鼠标当下的位置：locationInWindow 已是按下那一刻的位置，右键弹菜单
     * 的标准位置就是它（AppKit 自己换窗口坐标）。 */
    loc = [win mouseLocationOutsideOfEventStream];
    [menu popUpMenuPositioningItem:nil
                        atLocation:[win.contentView convertPoint:loc
                                                        fromView:nil]
                            inView:win.contentView];
  }
  return 0;
}

/* 上下文菜单的可点项全部指向 ctx target（分隔线与子菜单标题没有 action，
 * 不用换；子菜单里的递归换）。 */
static void moonui_native_ctx_retarget(NSMenuItem *item) {
  NSMenu *sub = [item submenu];
  if ([item action] == @selector(moonuiMenuItemClicked:)) {
    [item setTarget:moonui_native_ctx_target];
    [item setAction:@selector(moonuiCtxClicked:)];
  }
  if (sub != nil) {
    for (NSMenuItem *sub_item in [sub itemArray]) {
      moonui_native_ctx_retarget(sub_item);
    }
  }
}

/* ---- 文件拖入（`T86③` 第一期档案，mac 半）----
 *
 * destination 方法在 MoonuiWindow 上（见窗口子类那段）：窗口自己接外部文件
 * URL 的拖入，perform 里读 pasteboard 的文件 URL 数组、打包成
 * `i32 count, count × (i32 字节数, UTF-8)` 一段 bytes、然后通知 MoonBit——
 * 通知不带内容，target/paths 由读口当场取（adapter.h 的共同形状）。
 * 接受那一档只在"本地监听装上了"才亮（没监听的进程接了也白接）。 */

static moonui_closure_fn moonui_native_drop_fn = 0;
static void *moonui_native_drop_closure = 0;
static moonui_ptr moonui_native_drop_target_ptr = 0;
static char *moonui_native_drop_paths_bytes = 0;
static int moonui_native_drop_paths_len = 0;

static void moonui_native_drop_drop_closure(void) {
  if (moonui_native_drop_closure != 0) {
    moonbit_decref(moonui_native_drop_closure);
    moonui_native_drop_closure = 0;
  }
  moonui_native_drop_fn = 0;
}

static int moonui_native_drop_accepts(void) {
  return moonui_native_drop_fn != 0 ? 1 : 0;
}

static void moonui_native_drop_notify(moonui_ptr target, char *bytes, int len) {
  if (moonui_native_drop_fn == 0) {
    return;
  }
  moonui_native_drop_target_ptr = target;
  free(moonui_native_drop_paths_bytes);
  moonui_native_drop_paths_bytes = bytes;
  moonui_native_drop_paths_len = len;
  moonui_native_drop_fn(moonui_native_drop_closure);
}

static BOOL moonui_native_drop_perform(MoonuiWindow *win,
                                id<NSDraggingInfo> info) {
  NSArray *urls;
  NSMutableData *packed;
  int count;
  char *u8;
  moonui_ptr target;
  @autoreleasepool {
    if (moonui_native_drop_fn == 0) {
      return NO;
    }
    urls = [[info draggingPasteboard]
        propertyListForType:NSPasteboardTypeFileURL];
    if (urls == nil || urls.count == 0) {
      return NO;
    }
    /* 按 adapter.h 的打包布局拼二进制（i32 一律小端手工打包；用 NSMutableData
     * 不用 NSMutableString——头里的字节原样落盘，走 %c 会把 0x80 以上的字节
     * 当码位二次编码）。pasteboard 给的是 file URL 字符串，转 POSIX 路径再打
     * 包（MoonBit 侧收的是路径；转不出来——不是 file URL——那条就地丢弃）。 */
    count = 0;
    packed = [NSMutableData dataWithCapacity:16];
    for (NSString *url_string in urls) {
      NSURL *u = [NSURL URLWithString:url_string];
      NSString *path = u != nil ? [u path] : nil;
      NSData *u8data = path != nil ? [path dataUsingEncoding:NSUTF8StringEncoding] : nil;
      if (u8data == nil) {
        continue;
      }
      ++count;
      {
        int n = (int)u8data.length;
        unsigned char head[4];
        head[0] = (unsigned char)(n & 0xFF);
        head[1] = (unsigned char)((n >> 8) & 0xFF);
        head[2] = (unsigned char)((n >> 16) & 0xFF);
        head[3] = (unsigned char)((n >> 24) & 0xFF);
        [packed appendBytes:head length:4];
        [packed appendData:u8data];
      }
    }
    if (count == 0) {
      return NO;
    }
    {
      unsigned char head[4];
      NSMutableData *out;
      head[0] = (unsigned char)(count & 0xFF);
      head[1] = (unsigned char)((count >> 8) & 0xFF);
      head[2] = (unsigned char)((count >> 16) & 0xFF);
      head[3] = (unsigned char)((count >> 24) & 0xFF);
      out = [NSMutableData dataWithCapacity:(NSUInteger)(packed.length + 4)];
      [out appendBytes:head length:4];
      [out appendData:packed];
      packed = out;
    }
    u8 = moonui_native_dup((const char *)packed.bytes, (int)packed.length);
    target = (moonui_ptr)(uintptr_t)win;
    moonui_native_drop_notify(target, u8, (int)packed.length);
  }
  return YES;
}

moonui_ptr moonui_native_file_drop_target(void) {
  TRACE("file_drop_target");
  return moonui_native_drop_target_ptr;
}

/* 打包布局的读回：一段字节原样交给 MoonBit（unpack 在那边），快照在下一条
 * 通知覆盖前没人再动（与组合串同一条契约）。 */
moonbit_bytes_t moonui_native_file_drop_paths(void) {
  int n;
  moonbit_bytes_t out;
  TRACE("file_drop_paths");
  if (moonui_native_drop_paths_bytes == 0) {
    return moonbit_make_bytes(0, 0);
  }
  n = moonui_native_drop_paths_len;
  out = moonbit_make_bytes(n, 0);
  if (n > 0) {
    memcpy(out, moonui_native_drop_paths_bytes, (size_t)n);
  }
  return out;
}

int moonui_native_on_file_drop(moonui_closure_fn fn, void *closure) {
  TRACE("on_file_drop");
  moonui_native_drop_drop_closure();
  moonui_native_drop_fn = fn;
  moonui_native_drop_closure = closure;
  if (closure != 0) {
    moonbit_incref(closure);
  }
  return 0;
}

/* ---- 托盘（`T86⑥`）----
 *
 * NSStatusItem 由 NSStatusBar 发（进程级单例：一个应用一只，重复装图标就是
 * 换图）。图标参数沿 `moonui_set_app_icon` 的 stem 约定，这里补 ".png" 读进
 * 来画在状态条上；菜单沿菜单栏那套打包树建 NSMenu 挂上去——AppKit 自己在
 * 点击时弹它、弹的过程同步阻塞，选中的解析因此也在追踪循环内（同上下文
 * 菜单）。可点项指向托盘自己的回调槽位（独立于菜单栏与上下文菜单那两份）。
 * 返回码：0 = 装上了；-1 = 图标读不出来 / 树不合法；-2 = 还没初始化。 */

static moonui_closure_id_fn moonui_native_tray_fn = 0;
static void *moonui_native_tray_closure = 0;
static NSStatusItem *moonui_native_tray_item = nil;

@interface MoonuiNativeTrayTarget : NSObject
- (void)moonuiTrayClicked:(NSMenuItem *)item;
@end

@implementation MoonuiNativeTrayTarget
- (void)moonuiTrayClicked:(NSMenuItem *)item {
  if (moonui_native_tray_fn != 0 && moonui_native_tray_closure != 0) {
    moonui_native_tray_fn(moonui_native_tray_closure, (int)[item tag]);
  }
}
@end

/* +1 一直持到进程退出。 */
static MoonuiNativeTrayTarget *moonui_native_tray_target = nil;

static void moonui_native_tray_drop_closure(void) {
  if (moonui_native_tray_closure != 0) {
    moonbit_decref(moonui_native_tray_closure);
    moonui_native_tray_closure = 0;
  }
  moonui_native_tray_fn = 0;
}

/* 托盘菜单的可点项全部指向托盘 target（与上下文菜单同一套递归换法）。 */
static void moonui_native_tray_retarget(NSMenuItem *item) {
  NSMenu *sub = [item submenu];
  if ([item action] == @selector(moonuiMenuItemClicked:)) {
    [item setTarget:moonui_native_tray_target];
    [item setAction:@selector(moonuiTrayClicked:)];
  }
  if (sub != nil) {
    for (NSMenuItem *sub_item in [sub itemArray]) {
      moonui_native_tray_retarget(sub_item);
    }
  }
}

int moonui_native_tray_set_icon(const char *name, int name_len) {
  NSImage *img;
  TRACE("tray_set_icon");
  if (!moonui_native_inited) {
    return -2;
  }
  if (name == 0 || name_len <= 0) {
    return -1;
  }
  @autoreleasepool {
    if (moonui_native_tray_item == nil) {
      moonui_native_tray_item =
          [[NSStatusBar systemStatusBar] statusItemWithLength:
                             NSVariableStatusItemLength];
      [moonui_native_tray_item retain];
    }
    img = [[NSImage alloc] initWithContentsOfFile:
               [moonui_native_string_of(name, name_len) stringByAppendingString:@".png"]];
    if (img == nil) {
      return -1;
    }
    [img setSize:NSMakeSize(18.0, 18.0)];
    [moonui_native_tray_item.button setImage:img];
    [img release];
  }
  return 0;
}

int moonui_native_tray_set_menu(const char *tree,
                         int tree_len,
                         moonui_closure_id_fn fn,
                         void *closure) {
  MoonuiTree t;
  NSMenu *menu;
  TRACE("tray_set_menu");
  if (!moonui_native_inited) {
    return -2;
  }
  if (tree == 0 || tree_len < 5) {
    return -1;
  }
  @autoreleasepool {
    if (moonui_native_tray_item == nil) {
      /* 图标还没装就先装菜单：托盘的 NSStatusItem 在这里起（空图标的菜单
       * 托盘也该在），图标随后由 tray_set_icon 补。 */
      moonui_native_tray_item =
          [[NSStatusBar systemStatusBar] statusItemWithLength:
                             NSVariableStatusItemLength];
      [moonui_native_tray_item retain];
    }
    t.p = (const unsigned char *)tree;
    t.len = tree_len;
    t.pos = 0;
    t.bad = 0;
    if (moonui_native_tree_u8(&t) != 1 || moonui_native_tree_i32(&t) < 1 ||
        t.bad) {
      return -1;
    }
    menu = moonui_native_menu_new(moonui_native_tree_str(&t));
    if (t.bad ||
        !moonui_native_menu_fill(menu, &t, moonui_native_tree_i32(&t)) || t.bad) {
      return -1;
    }
    if (moonui_native_tray_target == nil) {
      moonui_native_tray_target = [[MoonuiNativeTrayTarget alloc] init];
    }
    for (NSMenuItem *item in [menu itemArray]) {
      moonui_native_tray_retarget(item);
    }
    moonui_native_tray_drop_closure();
    moonui_native_tray_fn = fn;
    if (closure != 0) {
      moonbit_incref(closure);
      moonui_native_tray_closure = closure;
    }
    [moonui_native_tray_item setMenu:menu];
  }
  return 0;
}

/* ---- 系统通知（`T86⑥`）----
 *
 * 走现代的 UNUserNotificationCenter（NSUserNotification 自 10.14 起已废弃，
 * 查证记在 `T86⑥` 的报告里）。通知中心只对打进 bundle 的应用有连接：无
 * bundle 的进程（CLI、测试二进制）问 bundleIdentifier 就返回 -3，不做无把握
 * 的投递。授权是异步请求（第一版不等待、不挂回调动作——点击动作欠账）；请求
 * 发过后 add 那一发照投，未授权的那次失败由 completion 吞掉（投递是异步的，
 * 返回码只表达"投递请求交出去了"）。返回码：0 = 交出去了；-1 = 文案不是
 * 合法 UTF-8；-2 = 还没初始化；-3 = 无 bundle。 */

static int moonui_native_notify_seq = 0;

int moonui_native_notify(const char *title, int title_len,
                  const char *body, int body_len) {
  TRACE("notify");
  if (!moonui_native_inited) {
    return -2;
  }
  @autoreleasepool {
    NSBundle *bundle = [NSBundle mainBundle];
    if (bundle == nil || bundle.bundleIdentifier == nil) {
      return -3;
    }
    if (title == 0 || body == 0) {
      return -1;
    }
    if (@available(macOS 10.14, *)) {
      UNUserNotificationCenter *center =
          [UNUserNotificationCenter currentNotificationCenter];
      UNMutableNotificationContent *content =
          [UNMutableNotificationContent new];
      UNNotificationRequest *req;
      NSString *t = moonui_native_string_of(title, title_len);
      NSString *s = moonui_native_string_of(body, body_len);
      content.title = t;
      content.body = s;
      req = [UNNotificationRequest requestWithIdentifier:
                [NSString stringWithFormat:@"moonui.notify.%d",
                                           moonui_native_notify_seq++]
                                        content:content
                                trigger:nil];
      [center requestAuthorizationWithOptions:
                  UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                completionHandler:^(BOOL granted, NSError *err) {
                                  (void)granted;
                                  (void)err;
                                }];
      [center addNotificationRequest:req
              withCompletionHandler:^(NSError *err) {
                (void)err;
              }];
      return 0;
    }
    return -3;
  }
}

/* ---- 音频（cloudmusic；adapter.h 音频段注）----
 *
 * mac 半在 2026-10-18 从 AVAudioPlayer 换成 **AVAudioEngine**。换的理由是千千
 * 静听那两块招牌零件——10 段均衡器与频谱可视化——都得挂在音频链路上：
 * AVAudioPlayer 是一端到端的黑盒，既没有 EQ 也没有逐帧数据，之前那两块只能
 * 画假的（柱高写死在 MoonBit 侧）。
 *
 * 图：AVAudioPlayerNode → AVAudioUnitEQ(10 段参量) → mainMixerNode → 输出。
 * 混音器输出上装一条 1024 点 tap，vDSP 做实数 FFT，按对数分成 16 段能量，
 * `audio_level(band)` 回读 0..1000（没有在播就每读衰减一次，做出回落）。
 *
 * 位置账：AVAudioPlayerNode 没有 currentTime，位置 = 起点(base_ms) + 已渲染
 * 帧数/采样率。暂停与 seek 都是"停掉 → 重新 schedule 段 → 播"，位置账只有这
 * 一条来源，不会出现 pause 之后计时漂移。
 *
 * 播完回调：scheduleSegment 的 completion 只在**真的播完**时该被认（请求的是
 * DataPlayedBack）。stop 也会让回调进一次，所以用 schedule 令牌（每次重排 +1）
 * 把旧的那次作废——否则 seek 会被误判成"播完了"而跳下一首。
 *
 * 闭包纪律照 worker（T85①）：set 时 incref、换/撤时 decref，回调投回主队列
 * 执行——落地动作是 MoonBit 侧的 app.post，不在原生栈里碰树。
 */

#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>

#define MOONUI_AE_BANDS 16
#define MOONUI_AE_FFT_N 1024
#define MOONUI_AE_FFT_LOG2 10

static AVAudioEngine *moonui_ae = 0;
static AVAudioPlayerNode *moonui_ae_node = 0;
static AVAudioUnitEQ *moonui_ae_eq = 0;
static AVAudioFile *moonui_ae_file = 0;
static double moonui_ae_rate = 44100.0;
static int64_t moonui_ae_frames = 0;
static int64_t moonui_ae_duration_ms = -1;
static int64_t moonui_ae_base_ms = 0;
static int64_t moonui_ae_start_sample = 0;
static int64_t moonui_ae_token = 0;
static int moonui_ae_playing = 0;
static int moonui_ae_loaded = 0;
static int moonui_ae_volume = 1000;
static int moonui_ae_tap = 0;
/* 均衡器：10 段，增益单位 milli-dB（-12000..12000 = ±12dB），默认平直、默认开 */
static int moonui_ae_eq_gain[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
static int moonui_ae_eq_on = 1;
static const double moonui_ae_eq_freq[10] = {60, 170, 310, 600, 1000,
                                             3000, 6000, 12000, 14000, 16000};
/* 频谱：16 段能量（0..1），音频线程写、UI 线程读——浮点读写不咬人，不另加锁 */
static float moonui_ae_level[MOONUI_AE_BANDS];
static FFTSetup moonui_ae_fft = 0;
static float moonui_ae_in[MOONUI_AE_FFT_N];
static float moonui_ae_win[MOONUI_AE_FFT_N];
static float moonui_ae_re[MOONUI_AE_FFT_N / 2];
static float moonui_ae_im[MOONUI_AE_FFT_N / 2];

static moonui_closure_fn moonui_audio_finished_fn = 0;
static void *moonui_audio_finished_closure = 0;

/*|
 * 频谱分析（音频线程）：汉宁窗 + 实数 FFT → 16 段对数分桶 → dB → 0..1。
 * 每段的回落做成"取新值与上次 0.85 倍的较大者"，看着像真的在跳。
 */
static void moonui_ae_fft_init(void) {
  int i;
  if (moonui_ae_fft != 0) {
    return;
  }
  moonui_ae_fft = vDSP_create_fftsetup(MOONUI_AE_FFT_LOG2, kFFTRadix2);
  for (i = 0; i < MOONUI_AE_FFT_N; i++) {
    moonui_ae_win[i] = (float)(0.5 *
                               (1.0 -
                                cos(2.0 * 3.14159265358979323846 * (double)i /
                                    (double)(MOONUI_AE_FFT_N - 1))));
  }
}

static void moonui_ae_analyse(AVAudioPCMBuffer *buf) {
  DSPSplitComplex sc;
  AVAudioFormat *fmt;
  UInt32 chs;
  UInt32 stride;
  float *ch0;
  double bin_hz;
  uint32_t n;
  int i;
  int b;
  if (moonui_ae_fft == 0) {
    return;
  }
  n = (uint32_t)[buf frameLength];
  if (n < MOONUI_AE_FFT_N) {
    return;
  }
  fmt = [buf format];
  chs = [fmt channelCount];
  stride = [fmt isInterleaved] ? chs : 1;
  if (chs == 0) {
    stride = 1;
  }
  ch0 = [buf floatChannelData][0];
  if (ch0 == 0) {
    return;
  }
  for (i = 0; i < MOONUI_AE_FFT_N; i++) {
    moonui_ae_in[i] = ch0[i * stride] * moonui_ae_win[i];
  }
  sc.realp = moonui_ae_re;
  sc.imagp = moonui_ae_im;
  vDSP_ctoz((const DSPComplex *)moonui_ae_in, 2, &sc, 1, MOONUI_AE_FFT_N / 2);
  vDSP_fft_zrip(moonui_ae_fft, &sc, 1, MOONUI_AE_FFT_LOG2,
                kFFTDirection_Forward);
  bin_hz = moonui_ae_rate / (double)MOONUI_AE_FFT_N;
  for (b = 0; b < MOONUI_AE_BANDS; b++) {
    double f_lo = 60.0 * pow(14000.0 / 60.0, (double)b / (double)MOONUI_AE_BANDS);
    double f_hi = 60.0 *
                  pow(14000.0 / 60.0, (double)(b + 1) / (double)MOONUI_AE_BANDS);
    int lo = (int)(f_lo / bin_hz);
    int hi = (int)(f_hi / bin_hz);
    double acc = 0.0;
    double mag;
    double db;
    double lvl;
    float next;
    int cnt = 0;
    int k;
    if (lo < 1) {
      lo = 1;
    }
    if (hi <= lo) {
      hi = lo + 1;
    }
    if (hi > MOONUI_AE_FFT_N / 2 - 1) {
      hi = MOONUI_AE_FFT_N / 2 - 1;
    }
    for (k = lo; k < hi; k++) {
      float re = moonui_ae_re[k];
      float im = moonui_ae_im[k];
      acc += (double)re * (double)re + (double)im * (double)im;
      cnt++;
    }
    mag = cnt > 0 ? sqrt(acc / (double)cnt) : 0.0;
    db = 20.0 * log10(mag + 1e-9);
    lvl = (db + 60.0) / 60.0; /* -60dB..0dB → 0..1 */
    if (lvl < 0.0) {
      lvl = 0.0;
    }
    if (lvl > 1.0) {
      lvl = 1.0;
    }
    next = (float)lvl;
    if (moonui_ae_level[b] * 0.85f > next) {
      next = moonui_ae_level[b] * 0.85f;
    }
    moonui_ae_level[b] = next;
  }
}

/*|
 * 建图（惰性）：AVAudioPlayerNode → EQ → mixer → 输出。没有文件时先用 44.1k
 * 立体声接上，load 时按文件的 processingFormat 重接一遍。
 */
static int moonui_ae_ensure(void) {
  AVAudioFormat *fmt;
  int i;
  if (moonui_ae != 0) {
    return 0;
  }
  moonui_ae_fft_init();
  moonui_ae = [[AVAudioEngine alloc] init];
  moonui_ae_node = [[AVAudioPlayerNode alloc] init];
  moonui_ae_eq = [[AVAudioUnitEQ alloc] initWithNumberOfBands:10];
  [moonui_ae attachNode:moonui_ae_node];
  [moonui_ae attachNode:moonui_ae_eq];
  for (i = 0; i < 10; i++) {
    AVAudioUnitEQFilterParameters *band = [[moonui_ae_eq bands] objectAtIndex:i];
    [band setFilterType:AVAudioUnitEQFilterTypeParametric];
    [band setFrequency:(float)moonui_ae_eq_freq[i]];
    [band setBandwidth:1.0f];
    [band setGain:(float)moonui_ae_eq_gain[i] / 1000.0f];
    [band setBypass:NO];
  }
  [moonui_ae_eq setGlobalGain:0.0f];
  [moonui_ae_eq setBypass:moonui_ae_eq_on ? NO : YES];
  fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                      channels:2];
  [moonui_ae connect:moonui_ae_node to:moonui_ae_eq format:fmt];
  [moonui_ae connect:moonui_ae_eq to:[moonui_ae mainMixerNode] format:fmt];
  [[moonui_ae mainMixerNode] setOutputVolume:(float)moonui_ae_volume / 1000.0f];
  return 0;
}

/*|
 * 起引擎（含 tap 只装一次）。连图之后才能起，起不来返回 -3。
 */
static int moonui_ae_start(void) {
  NSError *err = 0;
  if (moonui_ae == 0) {
    return -1;
  }
  if ([moonui_ae isRunning]) {
    return 0;
  }
  if (![moonui_ae startAndReturnError:&err]) {
    return -3;
  }
  if (!moonui_ae_tap) {
    AVAudioFormat *of = [[moonui_ae mainMixerNode] outputFormatForBus:0];
    [[moonui_ae mainMixerNode]
        installTapOnBus:0
             bufferSize:MOONUI_AE_FFT_N
                 format:of
                  block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
                    (void)when;
                    moonui_ae_analyse(buf);
                  }];
    moonui_ae_tap = 1;
  }
  return 0;
}

/*|
 * 重排一段：from_ms 起播（play=0 只排不播＝暂停/seek 后的待播态）。
 * 令牌 +1 把上一次的播完回调作废。
 */
static int moonui_ae_schedule(int64_t from_ms, int play) {
  int64_t my;
  AVAudioFramePosition start;
  AVAudioFrameCount count;
  NSError *err = 0;
  if (moonui_ae_loaded == 0 || moonui_ae_file == 0) {
    return -1;
  }
  if (from_ms < 0) {
    from_ms = 0;
  }
  if (moonui_ae_duration_ms > 0 && from_ms > moonui_ae_duration_ms) {
    from_ms = moonui_ae_duration_ms;
  }
  my = ++moonui_ae_token;
  [moonui_ae_node stop];
  moonui_ae_playing = 0;
  start = (AVAudioFramePosition)((double)from_ms / 1000.0 * moonui_ae_rate);
  if (start < 0) {
    start = 0;
  }
  count = (AVAudioFrameCount)(moonui_ae_frames - start);
  moonui_ae_base_ms = from_ms;
  if (count <= 0) {
    /* 已经到尾：按"播完"报一次（换曲/停机的落地在 MoonBit 侧） */
    if (moonui_audio_finished_fn != 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (moonui_ae_token == my && moonui_audio_finished_fn != 0) {
          moonui_audio_finished_fn(moonui_audio_finished_closure);
        }
      });
    }
    return 0;
  }
  if (play) {
    if (moonui_ae_start() != 0) {
      return -3;
    }
  }
  [moonui_ae_node
      scheduleSegment:moonui_ae_file
        startingFrame:start
           frameCount:count
               atTime:nil
  completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
       completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
         (void)type;
         if (moonui_ae_token != my) {
           return; /* 中途暂停/seek/换歌：这次不算播完 */
         }
         moonui_ae_playing = 0;
         moonui_ae_base_ms = moonui_ae_duration_ms;
         if (moonui_audio_finished_fn != 0) {
           dispatch_async(dispatch_get_main_queue(), ^{
             if (moonui_ae_token == my && moonui_audio_finished_fn != 0) {
               moonui_audio_finished_fn(moonui_audio_finished_closure);
             }
           });
         }
       }];
  if (play) {
    AVAudioTime *pt;
    [moonui_ae_node play];
    pt = [moonui_ae_node playerTimeForNodeTime:[moonui_ae_node lastRenderTime]];
    moonui_ae_start_sample = pt != nil ? (int64_t)[pt sampleTime] : 0;
    moonui_ae_playing = 1;
  }
  (void)err;
  return 0;
}

int moonui_native_audio_load(const char *path, int len) {
  TRACE("audio_load");
  if (path == 0 || len <= 0) {
    return -1;
  }
  @autoreleasepool {
    NSString *p = moonui_native_string_of(path, len);
    NSURL *url = [NSURL fileURLWithPath:p];
    NSError *err = 0;
    AVAudioFile *f;
    if (url == 0) {
      return -2;
    }
    f = [[AVAudioFile alloc] initForReading:url error:&err];
    if (f == nil) {
      return -2;
    }
    if (moonui_ae_ensure() != 0) {
      [f release];
      return -3;
    }
    /* 换歌：停掉旧的、作废旧回调、按新文件的格式重接图 */
    moonui_ae_token++;
    [moonui_ae_node stop];
    moonui_ae_playing = 0;
    if ([moonui_ae isRunning]) {
      [moonui_ae stop]; /* 改图前先停：running 时重连各版本表现不一 */
    }
    [moonui_ae_file release];
    moonui_ae_file = f;
    moonui_ae_rate = [[f processingFormat] sampleRate];
    moonui_ae_frames = (int64_t)[f length];
    moonui_ae_duration_ms =
        moonui_ae_rate > 0.0
            ? (int64_t)((double)moonui_ae_frames / moonui_ae_rate * 1000.0)
            : -1;
    moonui_ae_base_ms = 0;
    moonui_ae_loaded = 1;
    [moonui_ae disconnectNodeInput:moonui_ae_eq];
    [moonui_ae disconnectNodeInput:[moonui_ae mainMixerNode]];
    [moonui_ae connect:moonui_ae_node
                    to:moonui_ae_eq
                format:[f processingFormat]];
    [moonui_ae connect:moonui_ae_eq
                    to:[moonui_ae mainMixerNode]
                format:[f processingFormat]];
    return 0;
  }
}

int moonui_native_audio_play(void) {
  TRACE("audio_play");
  if (moonui_ae_loaded == 0) {
    return -1;
  }
  if (moonui_ae_playing) {
    return 0; /* 已经在播：幂等（AVAudioPlayerNode 不接受二次 play） */
  }
  return moonui_ae_schedule(moonui_ae_base_ms, 1);
}

int moonui_native_audio_pause(void) {
  int64_t pos;
  TRACE("audio_pause");
  if (moonui_ae_loaded == 0 || moonui_ae_playing == 0) {
    return 0; /* 没在播的 pause 是幂等的 */
  }
  pos = moonui_native_audio_position_ms();
  moonui_ae_token++;
  [moonui_ae_node stop];
  moonui_ae_playing = 0;
  moonui_ae_base_ms = pos > 0 ? pos : 0;
  return 0;
}

int moonui_native_audio_stop(void) {
  TRACE("audio_stop");
  if (moonui_ae_loaded == 0) {
    return 0; /* 没装歌的 stop 是幂等的：目标状态（无歌）已达成 */
  }
  moonui_ae_token++;
  [moonui_ae_node stop];
  moonui_ae_playing = 0;
  [moonui_ae_file release];
  moonui_ae_file = 0;
  moonui_ae_loaded = 0;
  moonui_ae_frames = 0;
  moonui_ae_duration_ms = -1;
  moonui_ae_base_ms = 0;
  for (int i = 0; i < MOONUI_AE_BANDS; i++) {
    moonui_ae_level[i] = 0.0f;
  }
  return 0;
}

int64_t moonui_native_audio_position_ms(void) {
  int64_t pos;
  AVAudioTime *pt;
  int64_t now;
  if (moonui_ae_loaded == 0) {
    return -1;
  }
  if (moonui_ae_playing == 0) {
    return moonui_ae_base_ms;
  }
  pt = [moonui_ae_node playerTimeForNodeTime:[moonui_ae_node lastRenderTime]];
  now = pt != nil ? (int64_t)[pt sampleTime] : moonui_ae_start_sample;
  pos = moonui_ae_base_ms +
        (int64_t)((double)(now - moonui_ae_start_sample) / moonui_ae_rate *
                  1000.0);
  if (pos < 0) {
    pos = 0;
  }
  if (moonui_ae_duration_ms > 0 && pos > moonui_ae_duration_ms) {
    pos = moonui_ae_duration_ms;
  }
  return pos;
}

int64_t moonui_native_audio_duration_ms(void) {
  return moonui_ae_duration_ms;
}

int moonui_native_audio_seek_ms(int64_t ms) {
  if (moonui_ae_loaded == 0) {
    return -1;
  }
  /* 播着就接着播，停着就只挪位置（C-08 行为表：seek 不改播放状态） */
  return moonui_ae_schedule(ms, moonui_ae_playing);
}

int moonui_native_audio_set_volume(int permille) {
  if (permille < 0) {
    permille = 0;
  }
  if (permille > 1000) {
    permille = 1000;
  }
  moonui_ae_volume = permille;
  if (moonui_ae == 0) {
    return 0; /* 还没建图：记住，建图时套用 */
  }
  [[moonui_ae mainMixerNode] setOutputVolume:(float)permille / 1000.0f];
  return 0;
}

int moonui_native_audio_is_playing(void) {
  return moonui_ae_playing ? 1 : 0;
}

int moonui_native_audio_on_finished(moonui_closure_fn fn, void *closure) {
  TRACE("audio_on_finished");
  if (moonui_audio_finished_closure != 0) {
    moonbit_decref(moonui_audio_finished_closure);
  }
  if (fn == 0) {
    moonui_audio_finished_fn = 0;
    moonui_audio_finished_closure = 0;
    return 0;
  }
  if (closure != 0) {
    moonbit_incref(closure);
  }
  moonui_audio_finished_fn = fn;
  moonui_audio_finished_closure = closure;
  return 0;
}

int moonui_native_audio_clear_on_finished(void) {
  return moonui_native_audio_on_finished(0, 0);
}

/*|
 * 频谱读数（0..1000）。没在播时每读一次衰减 15%——条子自然落回去，而不是
 * 卡在最后一帧的高度上。
 */
int moonui_native_audio_level(int band) {
  if (band < 0 || band >= MOONUI_AE_BANDS) {
    return 0;
  }
  if (moonui_ae_playing == 0) {
    moonui_ae_level[band] = moonui_ae_level[band] * 0.85f;
    if (moonui_ae_level[band] < 0.001f) {
      moonui_ae_level[band] = 0.0f;
    }
  }
  return (int)(moonui_ae_level[band] * 1000.0f + 0.5f);
}

int moonui_native_audio_eq_band_count(void) {
  return 10;
}

int moonui_native_audio_eq_set_band(int band, int gain_mdb) {
  if (band < 0 || band >= 10) {
    return -1;
  }
  if (gain_mdb < -12000) {
    gain_mdb = -12000;
  }
  if (gain_mdb > 12000) {
    gain_mdb = 12000;
  }
  moonui_ae_eq_gain[band] = gain_mdb;
  if (moonui_ae == 0) {
    return 0; /* 还没建图：记住，建图时套用 */
  }
  [[[moonui_ae_eq bands] objectAtIndex:band]
      setGain:(float)gain_mdb / 1000.0f];
  return 0;
}

int moonui_native_audio_eq_band_gain(int band) {
  if (band < 0 || band >= 10) {
    return 0;
  }
  return moonui_ae_eq_gain[band];
}

int moonui_native_audio_eq_set_enabled(int on) {
  moonui_ae_eq_on = on ? 1 : 0;
  if (moonui_ae == 0) {
    return 0;
  }
  [moonui_ae_eq setBypass:moonui_ae_eq_on ? NO : YES];
  return 0;
}

int moonui_native_audio_eq_enabled(void) {
  return moonui_ae_eq_on;
}

/* 探针：Common 键空间里逐项找 title/artist/album/artwork，AVAsset 打不开就
 * 整包退回 NULL（调用方退回文件名，C-10 风险 4）。打包布局见 adapter.h。 */
moonui_ptr moonui_native_audio_probe(const char *path, int len) {
  TRACE("audio_probe");
  if (path == 0 || len <= 0) {
    return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
  }
  @autoreleasepool {
    NSString *p = moonui_native_string_of(path, len);
    NSURL *url = [NSURL fileURLWithPath:p];
    if (url == 0) {
      return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
    }
    AVAsset *asset = [AVAsset assetWithURL:url];
    if (asset == 0) {
      return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
    }
    NSString *title = 0;
    NSString *artist = 0;
    NSString *album = 0;
    NSData *cover = 0;
    for (AVMetadataItem *item in [asset metadata]) {
      if (![item.keySpace isEqualToString:AVMetadataKeySpaceCommon]) {
        continue;
      }
      if ([item.key isEqual:(id)AVMetadataCommonKeyTitle]) {
        title = [item stringValue];
      } else if ([item.key isEqual:(id)AVMetadataCommonKeyArtist]) {
        artist = [item stringValue];
      } else if ([item.key isEqual:(id)AVMetadataCommonKeyAlbumName]) {
        album = [item stringValue];
      } else if ([item.key isEqual:(id)AVMetadataCommonKeyArtwork]) {
        cover = [item dataValue];
      }
    }
    int64_t dur = (int64_t)(CMTimeGetSeconds([asset duration]) * 1000.0);
    if (dur < 0) {
      dur = -1;
    }
    const char *t = title != 0 ? [title UTF8String] : "";
    const char *a = artist != 0 ? [artist UTF8String] : "";
    const char *al = album != 0 ? [album UTF8String] : "";
    int tlen = title != 0 ? (int)strlen(t) : 0;
    int alen = artist != 0 ? (int)strlen(a) : 0;
    int allen = album != 0 ? (int)strlen(al) : 0;
    int clen = cover != 0 ? (int)[cover length] : 0;
    size_t total = 4 + (size_t)tlen + 4 + (size_t)alen + 4 + (size_t)allen + 8 +
                   4 + (size_t)clen;
    if (total > INT32_MAX) {
      return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
    }
    uint8_t *buf = (uint8_t *)malloc(total);
    if (buf == 0) {
      return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
    }
    size_t off = 0;
    int32_t w;
    w = (int32_t)tlen;
    memcpy(buf + off, &w, 4);
    off += 4;
    memcpy(buf + off, t, (size_t)tlen);
    off += (size_t)tlen;
    w = (int32_t)alen;
    memcpy(buf + off, &w, 4);
    off += 4;
    memcpy(buf + off, a, (size_t)alen);
    off += (size_t)alen;
    w = (int32_t)allen;
    memcpy(buf + off, &w, 4);
    off += 4;
    memcpy(buf + off, al, (size_t)allen);
    off += (size_t)allen;
    memcpy(buf + off, &dur, 8);
    off += 8;
    w = (int32_t)clen;
    memcpy(buf + off, &w, 4);
    off += 4;
    if (cover != 0) {
      memcpy(buf + off, [cover bytes], (size_t)clen);
      off += (size_t)clen;
    }
    moonbit_bytes_t out = moonbit_make_bytes((int)total, 0);
    memcpy(out, buf, total);
    free(buf);
    return (moonui_ptr)out;
  }
}

/* ---- 目录行走（adapter.h 的行走段注）----
 * 直写 readdir。dirent 的 d_name 偏移因平台而异（macOS 21 / Linux 19），
 * 这正是"读不了 struct 布局"的理由——只在 C 里碰它，MoonBit 侧拿打包字节。
 */

#include <dirent.h>

moonui_ptr moonui_native_walk_dir(const char *path, int len) {
  TRACE("walk_dir");
  if (path == 0 || len <= 0) {
    return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
  }
  @autoreleasepool {
    NSString *p = moonui_native_string_of(path, len);
    DIR *dir = opendir(p.fileSystemRepresentation);
    if (dir == 0) {
      return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
    }
    /* 两遍：先收集 NSString（栈上小数组），再一次性打包 */
    NSMutableArray *names = [NSMutableArray array];
    struct dirent *entry;
    while ((entry = readdir(dir)) != 0) {
      const char *name = entry->d_name;
      if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        continue;
      }
      [names addObject:[NSString stringWithUTF8String:name]];
    }
    closedir(dir);
    size_t total = 4;
    for (NSString *n in names) {
      total += 4 + (size_t)[n lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    }
    if (total > INT32_MAX) {
      return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
    }
    uint8_t *buf = (uint8_t *)malloc(total);
    if (buf == 0) {
      return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出；NULL 会让 MoonBit 侧解引用空指针闪退 */
    }
    size_t off = 0;
    int32_t count = (int32_t)[names count];
    memcpy(buf + off, &count, 4);
    off += 4;
    for (NSString *n in names) {
      const char *u = [n UTF8String];
      int32_t nlen = u != 0 ? (int32_t)strlen(u) : 0;
      memcpy(buf + off, &nlen, 4);
      off += 4;
      if (nlen > 0) {
        memcpy(buf + off, u, (size_t)nlen);
        off += (size_t)nlen;
      }
    }
    moonbit_bytes_t out = moonbit_make_bytes((int)total, 0);
    memcpy(out, buf, total);
    free(buf);
    return (moonui_ptr)out;
  }
}

/* ---- 画布（§52，自绘后端的绘制通道；第一期离屏位图帧）----
 *
 * 上下文 = 一张 RGBA 位图（PremultipliedLast，8bit/通道）+ CG 状态栈。
 * begin_frame 开帧（换新位图），end_frame 第一期是幂等收口——位图就是帧，
 * 上屏的 attach 在 canvas-macos 后端那一批再进 ABI（52.5 分期②）。
 * 坐标物理像素、颜色 0xRRGGBB 打包、permille=值×1000，口径见 adapter.h。
 * 文本走 AppKit（NSFont/NSAttributedString）：度量与绘制共用同一份
 * attributes，保证"量出来的就是画出来的"；draw 侧临时把 CGContext 包成
 * NSGraphicsContext，画完还回去（MRC：包出来的 context 不 retain 底层，
 * 显式 setCurrentContext/restoreState 成对）。 */

typedef struct {
  CGContextRef ctx;
  CGColorSpaceRef space;
  void *data;
  size_t row_bytes;
  int w;
  int h;
  /* 分期②的上屏账：attach 记下目标窗口，present 把帧贴到它的
   * contentView 的 layer 上。不 retain——窗口的生命周期归
   * moonui_native_window_destroy，先拆窗后毁画布是调用方的顺序账。 */
  NSWindow *window;
} MoonuiCanvas;

static NSFont *moonui_canvas_font(int font_permille, int weight) {
  CGFloat size = (CGFloat)font_permille / 1000.0;
  if (weight == 2) {
    return [NSFont boldSystemFontOfSize:size];
  }
  return [NSFont systemFontOfSize:size];
}

/* 0xRRGGBB + alpha(0..255) → CGColorRef（调用方 release）。颜色必须用
 * **位图同一份** deviceRGB 色空间造——用 genericRGB 的话颜色管理会按显示器
 * profile 把 "纯红"换算成 deviceRGB 的 (255,38,0)（探针实测），同空间才逐位
 * 确定（§30 的口径：像素账要可断言）。alpha 走独立参数（T98② 毛玻璃）：
 * 位图本就是 RGBA 预乘，只是第一期没透明色需求才恒 1。 */
static CGColorRef moonui_canvas_color(CGColorSpaceRef space, int64_t rgb,
                                      int alpha) {
  CGFloat a = (CGFloat)alpha / 255.0;
  if (a < 0.0) {
    a = 0.0;
  }
  if (a > 1.0) {
    a = 1.0;
  }
  CGFloat comps[4] = {
      (CGFloat)((rgb >> 16) & 0xFF) / 255.0,
      (CGFloat)((rgb >> 8) & 0xFF) / 255.0,
      (CGFloat)(rgb & 0xFF) / 255.0,
      a,
  };
  return CGColorCreate(space, comps);
}

static MoonuiCanvas *moonui_canvas_of(moonui_ptr p) {
  if (p == 0) {
    return nil;
  }
  return (MoonuiCanvas *)(uintptr_t)p;
}

moonui_ptr moonui_canvas_create(void) {
  MoonuiCanvas *c;
  TRACE("canvas_create");
  c = (MoonuiCanvas *)calloc(1, sizeof(MoonuiCanvas));
  if (c == 0) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)c;
}

int moonui_canvas_destroy(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_destroy");
  if (c == 0) {
    return -1;
  }
  if (c->ctx != nil) {
    CGContextRelease(c->ctx);
  }
  if (c->space != nil) {
    CGColorSpaceRelease(c->space);
  }
  if (c->data != 0) {
    free(c->data);
  }
  free(c);
  return 0;
}

int moonui_canvas_begin_frame(moonui_ptr canvas, int w, int h) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_begin_frame");
  if (c == 0 || w <= 0 || h <= 0) {
    return -1;
  }
  if (c->ctx != nil) {
    CGContextRelease(c->ctx);
    free(c->data);
    c->ctx = nil;
    c->data = 0;
  }
  c->space = CGColorSpaceCreateDeviceRGB();
  c->w = w;
  c->h = h;
  c->row_bytes = (size_t)w * 4;
  c->data = calloc((size_t)w * (size_t)h, 4);
  if (c->data == 0) {
    return -1;
  }
  c->ctx = CGBitmapContextCreate(
      c->data, (size_t)w, (size_t)h, 8, c->row_bytes,
      c->space,
      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
  if (c->ctx == nil) {
    free(c->data);
    c->data = 0;
    return -1;
  }
  /* 画布坐标约定 = UI 惯用的左上原点、y 向下（adapter.h 段注的物理像素
   * 口径按 UI 直觉给）；CG 的原生坐标是左下原点，位图缓冲第 0 行却是
   * 顶部——不翻的话画在 CG-y=30 的东西落在缓冲第 (h-30) 行，read_pixel
   * 对不上账。翻 CTM 一次，所有绘制 API 与 read_pixel 就同一把尺。 */
  CGContextTranslateCTM(c->ctx, 0, (CGFloat)h);
  CGContextScaleCTM(c->ctx, 1, -1);
  return 0;
}

int moonui_canvas_end_frame(moonui_ptr canvas) {
  TRACE("canvas_end_frame");
  if (moonui_canvas_of(canvas) == 0) {
    return -1;
  }
  /* 第一期：位图就是帧，end_frame 只做存在性收口。 */
  return 0;
}

int moonui_canvas_attach_window(moonui_ptr canvas, moonui_ptr window) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  NSWindow *win = (NSWindow *)(uintptr_t)window;
  TRACE("canvas_attach_window");
  if (c == 0 || win == nil) {
    return -1;
  }
  @autoreleasepool {
    NSView *v = [win contentView];
    if (v == nil) {
      return -1;
    }
    /* 贴图走 layer.contents：把 contentView 转成 layer-backed（一次性，
     * 重复设无害）。这里不碰绘制——位图到 layer 的搬运全在 present。 */
    [v setWantsLayer:YES];
    c->window = win;
  }
  return 0;
}

int moonui_canvas_present(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_present");
  if (c == 0 || c->data == 0 || c->window == nil) {
    return -1;
  }
  @autoreleasepool {
    /* 帧位图 → CGImage → layer.contents。contents 赋值会 CFRetain，
     * 所以 __bridge 之后这里放掉自己的引用是安全的。bytes 布局与
     * begin_frame 开帧时同款（RGBA 预乘、Big 端）。 */
    CGDataProviderRef prov = CGDataProviderCreateWithData(
        nil, c->data, c->row_bytes * (size_t)c->h, nil);
    if (prov == nil) {
      return -1;
    }
    CGImageRef img = CGImageCreate(
        (size_t)c->w, (size_t)c->h, 8, 32, c->row_bytes, c->space,
        kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast, prov, nil,
        false, kCGRenderingIntentDefault);
    CGDataProviderRelease(prov);
    if (img == nil) {
      return -1;
    }
    NSView *v = [c->window contentView];
    if (v == nil) {
      CGImageRelease(img);
      return -1;
    }
    v.layer.contents = (__bridge id)img;
    CGImageRelease(img);
  }
  return 0;
}

int moonui_canvas_save(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_save");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  CGContextSaveGState(c->ctx);
  return 0;
}

int moonui_canvas_restore(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_restore");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  CGContextRestoreGState(c->ctx);
  return 0;
}

int moonui_canvas_clip_rect(moonui_ptr canvas, int x, int y, int w, int h) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_clip_rect");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  CGContextClipToRect(c->ctx, CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h));
  return 0;
}

int moonui_canvas_translate(moonui_ptr canvas, int dx, int dy) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_translate");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  CGContextTranslateCTM(c->ctx, (CGFloat)dx, (CGFloat)dy);
  return 0;
}

/* 圆角矩形路径（MRC 手画：CGPath 没有公开的圆角构造，AddArc 四角拼）。
 * radius=半宽的正圆走 CGPathAddEllipseInRect 整圆分支——四段弧拼的接点
 * 留 1px 抗锯齿缝（2026-10-17 探针实测后修，见下方注释）。 */
static void moonui_canvas_rounded_path(CGContextRef ctx, int x, int y, int w,
                                       int h, double radius) {
  double r = radius;
  if (r < 0) {
    r = 0;
  }
  if (r > (double)w / 2.0) {
    r = (double)w / 2.0;
  }
  if (r > (double)h / 2.0) {
    r = (double)h / 2.0;
  }
  if (r < 0.5) {
    CGContextAddRect(ctx, CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h));
    return;
  }
  /* 正圆（radius=半宽，滑条拇指就是它）走整圆一条路径：四段弧拼的路径
   * 在接点处留 1px 抗锯齿缝（2026-10-17 探针实测，测试曾绕开采样），
   * CGPathAddEllipseInRect 一次画没有接点。 */
  if (r >= (double)w / 2.0 - 0.001 && r >= (double)h / 2.0 - 0.001) {
    CGContextAddEllipseInRect(
        ctx, CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h));
    return;
  }
  CGContextMoveToPoint(ctx, (CGFloat)(x + r), (CGFloat)y);
  CGContextAddLineToPoint(ctx, (CGFloat)(x + w - r), (CGFloat)y);
  CGContextAddArcToPoint(ctx, (CGFloat)(x + w), (CGFloat)y, (CGFloat)(x + w),
                         (CGFloat)(y + r), (CGFloat)r);
  CGContextAddLineToPoint(ctx, (CGFloat)(x + w), (CGFloat)(y + h - r));
  CGContextAddArcToPoint(ctx, (CGFloat)(x + w), (CGFloat)(y + h),
                         (CGFloat)(x + w - r), (CGFloat)(y + h), (CGFloat)r);
  CGContextAddLineToPoint(ctx, (CGFloat)(x + r), (CGFloat)(y + h));
  CGContextAddArcToPoint(ctx, (CGFloat)x, (CGFloat)(y + h), (CGFloat)x,
                         (CGFloat)(y + h - r), (CGFloat)r);
  CGContextAddLineToPoint(ctx, (CGFloat)x, (CGFloat)(y + r));
  CGContextAddArcToPoint(ctx, (CGFloat)x, (CGFloat)y, (CGFloat)(x + r),
                         (CGFloat)y, (CGFloat)r);
  CGContextClosePath(ctx);
}

int moonui_canvas_fill_rect(moonui_ptr canvas, int x, int y, int w, int h,
                            int radius_permille, int64_t rgb, int alpha) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  CGColorRef color;
  TRACE("canvas_fill_rect");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  @autoreleasepool {
    color = moonui_canvas_color(c->space, rgb, alpha);
    CGContextSetFillColorWithColor(c->ctx, color);
    moonui_canvas_rounded_path(c->ctx, x, y, w, h,
                               (double)radius_permille / 1000.0);
    CGContextDrawPath(c->ctx, kCGPathFill);
    CGColorRelease(color);
  }
  return 0;
}

/* 区域模糊（T98② 毛玻璃的"毛"）：对位图缓冲里 (x,y,w,h) 那块做原地高斯近似
 * 模糊——三次盒式模糊（running-sum，O(W·H) 与半径无关）≈ 高斯，半径取
 * radius_permille/1000 的物理像素。直接读写 c->data（RGBA 预乘、行主序、
 * 顶行在前，与 read_pixel 同一把尺），不碰 CGContext——模糊的是"栏后面
 * 已经画上去的内容"，不是栏自己。越界钳到缓冲内；半径 0 是恒等（不模糊）。
 * 半透明像素按预乘值混，与位图口径一致。 */
int moonui_canvas_blur_region(moonui_ptr canvas, int x, int y, int w, int h,
                              int radius_permille) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  uint8_t *src;
  uint8_t *dst;
  int r;
  int win;
  int i;
  int j;
  int k;
  int x0;
  int x1;
  int y0;
  int y1;
  int W;
  int H;
  TRACE("canvas_blur_region");
  if (c == 0 || c->data == 0 || w <= 0 || h <= 0) {
    return -1;
  }
  r = (int)(radius_permille / 1000.0);
  if (r < 0) {
    r = 0;
  }
  if (r == 0) {
    return 0;
  }
  /* 区域钳到缓冲内（栏贴边时 x/y 可能为 0，w/h 可能越界）。 */
  x0 = x;
  y0 = y;
  x1 = x + w;
  y1 = y + h;
  if (x0 < 0) {
    x0 = 0;
  }
  if (y0 < 0) {
    y0 = 0;
  }
  if (x1 > c->w) {
    x1 = c->w;
  }
  if (y1 > c->h) {
    y1 = c->h;
  }
  if (x1 <= x0 || y1 <= y0) {
    return 0;
  }
  W = x1 - x0;
  H = y1 - y0;
  win = 2 * r + 1;
  src = (uint8_t *)calloc((size_t)W * (size_t)H * 4, 1);
  dst = (uint8_t *)calloc((size_t)W * (size_t)H * 4, 1);
  if (src == 0 || dst == 0) {
    free(src);
    free(dst);
    return -1;
  }
  /* 三次盒式模糊：src→dst→src→dst，最后结果落在 dst。 */
  for (k = 0; k < 3; k++) {
    uint8_t *in = (k % 2 == 0) ? src : dst;
    uint8_t *out = (k % 2 == 0) ? dst : src;
    /* 水平 pass：每行 running-sum。 */
    for (j = 0; j < H; j++) {
      int64_t sr = 0;
      int64_t sg = 0;
      int64_t sb = 0;
      int64_t sa = 0;
      for (i = 0; i < W; i++) {
        int li = i - r;
        int ri = i + r;
        if (li < 0) {
          li = 0;
        }
        if (ri >= W) {
          ri = W - 1;
        }
        sr += in[(size_t)(j * W + ri) * 4 + 0];
        sg += in[(size_t)(j * W + ri) * 4 + 1];
        sb += in[(size_t)(j * W + ri) * 4 + 2];
        sa += in[(size_t)(j * W + ri) * 4 + 3];
        if (i - win >= 0) {
          int li2 = i - win;
          if (li2 < 0) {
            li2 = 0;
          }
          sr -= in[(size_t)(j * W + li2) * 4 + 0];
          sg -= in[(size_t)(j * W + li2) * 4 + 1];
          sb -= in[(size_t)(j * W + li2) * 4 + 2];
          sa -= in[(size_t)(j * W + li2) * 4 + 3];
        }
        out[(size_t)(j * W + i) * 4 + 0] = (uint8_t)(sr / win);
        out[(size_t)(j * W + i) * 4 + 1] = (uint8_t)(sg / win);
        out[(size_t)(j * W + i) * 4 + 2] = (uint8_t)(sb / win);
        out[(size_t)(j * W + i) * 4 + 3] = (uint8_t)(sa / win);
      }
    }
    /* 垂直 pass：每列 running-sum。 */
    for (i = 0; i < W; i++) {
      int64_t sr = 0;
      int64_t sg = 0;
      int64_t sb = 0;
      int64_t sa = 0;
      for (j = 0; j < H; j++) {
        int lj = j - r;
        int rj = j + r;
        if (lj < 0) {
          lj = 0;
        }
        if (rj >= H) {
          rj = H - 1;
        }
        sr += out[(size_t)(rj * W + i) * 4 + 0];
        sg += out[(size_t)(rj * W + i) * 4 + 1];
        sb += out[(size_t)(rj * W + i) * 4 + 2];
        sa += out[(size_t)(rj * W + i) * 4 + 3];
        if (j - win >= 0) {
          int lj2 = j - win;
          if (lj2 < 0) {
            lj2 = 0;
          }
          sr -= out[(size_t)(lj2 * W + i) * 4 + 0];
          sg -= out[(size_t)(lj2 * W + i) * 4 + 1];
          sb -= out[(size_t)(lj2 * W + i) * 4 + 2];
          sa -= out[(size_t)(lj2 * W + i) * 4 + 3];
        }
        in[(size_t)(j * W + i) * 4 + 0] = (uint8_t)(sr / win);
        in[(size_t)(j * W + i) * 4 + 1] = (uint8_t)(sg / win);
        in[(size_t)(j * W + i) * 4 + 2] = (uint8_t)(sb / win);
        in[(size_t)(j * W + i) * 4 + 3] = (uint8_t)(sa / win);
      }
    }
  }
  /* 结果在 dst，写回缓冲。 */
  for (j = 0; j < H; j++) {
    uint8_t *row = (uint8_t *)c->data + (size_t)(y0 + j) * c->row_bytes +
                   (size_t)x0 * 4;
    for (i = 0; i < W; i++) {
      row[(size_t)i * 4 + 0] = dst[(size_t)(j * W + i) * 4 + 0];
      row[(size_t)i * 4 + 1] = dst[(size_t)(j * W + i) * 4 + 1];
      row[(size_t)i * 4 + 2] = dst[(size_t)(j * W + i) * 4 + 2];
      row[(size_t)i * 4 + 3] = dst[(size_t)(j * W + i) * 4 + 3];
    }
  }
  free(src);
  free(dst);
  return 0;
}

int moonui_canvas_stroke_rect(moonui_ptr canvas, int x, int y, int w, int h,
                              int radius_permille, int64_t rgb,
                              int width_permille) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  CGColorRef color;
  TRACE("canvas_stroke_rect");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  @autoreleasepool {
    color = moonui_canvas_color(c->space, rgb, 255);
    CGContextSetStrokeColorWithColor(c->ctx, color);
    CGContextSetLineWidth(c->ctx, (CGFloat)width_permille / 1000.0);
    moonui_canvas_rounded_path(c->ctx, x, y, w, h,
                               (double)radius_permille / 1000.0);
    CGContextDrawPath(c->ctx, kCGPathStroke);
    CGColorRelease(color);
  }
  return 0;
}

int moonui_canvas_fill_linear(moonui_ptr canvas, int x, int y, int w, int h,
                              moonui_ptr stops, int n) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  int64_t *raw;
  CGFloat *comps;
  CGFloat *positions;
  CGColorSpaceRef space;
  CGGradientRef grad;
  int i;
  TRACE("canvas_fill_linear");
  if (c == 0 || c->ctx == nil || stops == 0 || n < 2) {
    return -1;
  }
  raw = (int64_t *)(uintptr_t)stops;
  @autoreleasepool {
    comps = (CGFloat *)calloc((size_t)n * 4, sizeof(CGFloat));
    positions = (CGFloat *)calloc((size_t)n, sizeof(CGFloat));
    if (comps == 0 || positions == 0) {
      free(comps);
      free(positions);
      return -1;
    }
    for (i = 0; i < n; i++) {
      int64_t pos = raw[i * 2];
      int64_t rgb = raw[i * 2 + 1];
      double p = (double)pos / 1000.0;
      if (p < 0) {
        p = 0;
      }
      if (p > 1) {
        p = 1;
      }
      positions[i] = (CGFloat)p;
      comps[i * 4 + 0] = (CGFloat)((rgb >> 16) & 0xFF) / 255.0;
      comps[i * 4 + 1] = (CGFloat)((rgb >> 8) & 0xFF) / 255.0;
      comps[i * 4 + 2] = (CGFloat)(rgb & 0xFF) / 255.0;
      comps[i * 4 + 3] = 1.0;
    }
    space = CGColorSpaceCreateDeviceRGB();
    grad = CGGradientCreateWithColorComponents(space, comps, positions, (size_t)n);
    CGColorSpaceRelease(space);
    if (grad == nil) {
      free(comps);
      free(positions);
      return -1;
    }
    CGContextSaveGState(c->ctx);
    CGContextClipToRect(c->ctx,
                        CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h));
    /* 垂直从上到下（adapter.h 段注的口径）。 */
    CGContextDrawLinearGradient(c->ctx, grad, CGPointMake((CGFloat)x, (CGFloat)y),
                                CGPointMake((CGFloat)x, (CGFloat)(y + h)), 0);
    CGContextRestoreGState(c->ctx);
    CGGradientRelease(grad);
    free(comps);
    free(positions);
  }
  return 0;
}

int moonui_canvas_shadow(moonui_ptr canvas, int dx, int dy,
                         int blur_permille, int64_t rgb) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  CGColorRef color;
  TRACE("canvas_shadow");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  @autoreleasepool {
    if (blur_permille <= 0) {
      /* 清零口：显式关掉投影（adapter.h 段注的状态语义）。 */
      CGContextSetShadowWithColor(c->ctx, CGSizeZero, 0, nil);
      return 0;
    }
    color = moonui_canvas_color(c->space, rgb, 255);
    CGContextSetShadowWithColor(c->ctx,
                                CGSizeMake((CGFloat)dx, (CGFloat)dy),
                                (CGFloat)blur_permille / 1000.0, color);
    CGColorRelease(color);
  }
  return 0;
}

int moonui_canvas_line(moonui_ptr canvas, int x0, int y0, int x1, int y1,
                       int64_t rgb, int width_permille) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  CGColorRef color;
  TRACE("canvas_line");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  @autoreleasepool {
    color = moonui_canvas_color(c->space, rgb, 255);
    CGContextSetStrokeColorWithColor(c->ctx, color);
    CGContextSetLineWidth(c->ctx, (CGFloat)width_permille / 1000.0);
    CGContextMoveToPoint(c->ctx, (CGFloat)x0, (CGFloat)y0);
    CGContextAddLineToPoint(c->ctx, (CGFloat)x1, (CGFloat)y1);
    CGContextStrokePath(c->ctx);
    CGColorRelease(color);
  }
  return 0;
}

/* 度量与绘制共用的 attrs（MRC：返回的 dict 是 autoreleased，配池用）。 */
static NSDictionary *moonui_canvas_text_attrs(int font_permille, int weight,
                                              int64_t rgb, BOOL with_color) {
  NSFont *font = moonui_canvas_font(font_permille, weight);
  if (with_color) {
    NSColor *color = moonui_native_srgb_color(rgb);
    return @{
      NSFontAttributeName: font,
      NSForegroundColorAttributeName: color,
    };
  }
  return @{ NSFontAttributeName: font };
}

int64_t moonui_canvas_measure_text(const char *utf8, int len,
                                   int font_permille, int weight) {
  NSString *s;
  NSAttributedString *as;
  NSSize sz;
  TRACE("canvas_measure_text");
  if (utf8 == 0 || len <= 0) {
    return -1;
  }
  @autoreleasepool {
    s = [[NSString alloc] initWithBytes:utf8 length:(NSUInteger)len
                               encoding:NSUTF8StringEncoding];
    if (s == nil) {
      return -1;
    }
    as = [[NSAttributedString alloc] initWithString:s
                                         attributes:moonui_canvas_text_attrs(
                                             font_permille, weight, 0, NO)];
    sz = [as size];
    return ((int64_t)(NSInteger)(sz.width + 0.5) << 32) |
           (int64_t)(NSInteger)(sz.height + 0.5);
  }
}

int moonui_canvas_draw_text(moonui_ptr canvas, const char *utf8, int len,
                            int x, int y, int font_permille, int weight,
                            int64_t rgb) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  NSString *s;
  NSAttributedString *as;
  NSGraphicsContext *ns_ctx;
  NSGraphicsContext *prev;
  TRACE("canvas_draw_text");
  if (c == 0 || c->ctx == nil || utf8 == 0 || len <= 0) {
    return -1;
  }
  @autoreleasepool {
    s = [[NSString alloc] initWithBytes:utf8 length:(NSUInteger)len
                               encoding:NSUTF8StringEncoding];
    if (s == nil) {
      return -1;
    }
    as = [[NSAttributedString alloc] initWithString:s
                                         attributes:moonui_canvas_text_attrs(
                                             font_permille, weight, rgb, YES)];
    ns_ctx = [NSGraphicsContext graphicsContextWithCGContext:c->ctx flipped:YES];
    if (ns_ctx == nil) {
      return -1;
    }
    prev = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:ns_ctx];
    [as drawWithRect:NSMakeRect((CGFloat)x, (CGFloat)y, (CGFloat)c->w, (CGFloat)c->h)
             options:NSStringDrawingUsesLineFragmentOrigin];
    [NSGraphicsContext setCurrentContext:prev];
  }
  return 0;
}

int moonui_canvas_draw_image(moonui_ptr canvas, const char *bytes, int len,
                             int x, int y, int w, int h) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  NSData *data;
  NSImage *img;
  NSGraphicsContext *ns_ctx;
  NSGraphicsContext *prev;
  TRACE("canvas_draw_image");
  if (c == 0 || c->ctx == nil || bytes == 0 || len <= 0 || w <= 0 || h <= 0) {
    return -1;
  }
  @autoreleasepool {
    data = [NSData dataWithBytes:bytes length:(NSUInteger)len];
    img = [[NSImage alloc] initWithData:data];
    if (img == nil) {
      return -1;
    }
    ns_ctx = [NSGraphicsContext graphicsContextWithCGContext:c->ctx flipped:YES];
    if (ns_ctx == nil) {
      return -1;
    }
    prev = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:ns_ctx];
    [img drawInRect:NSMakeRect((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h)
           fromRect:NSZeroRect
          operation:NSCompositingOperationSourceOver
           fraction:1.0
     respectFlipped:NO
              hints:nil];
    [NSGraphicsContext setCurrentContext:prev];
  }
  return 0;
}

int64_t moonui_canvas_read_pixel(moonui_ptr canvas, int x, int y) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  const uint8_t *px;
  uint8_t r;
  uint8_t g;
  uint8_t b;
  uint8_t a;
  TRACE("canvas_read_pixel");
  if (c == 0 || c->ctx == nil || c->data == 0) {
    return -1;
  }
  if (x < 0 || y < 0 || x >= c->w || y >= c->h) {
    return -1;
  }
  px = (const uint8_t *)c->data + (size_t)y * c->row_bytes + (size_t)x * 4;
  r = px[0];
  g = px[1];
  b = px[2];
  a = px[3];
  if (a == 0) {
    return -1;
  }
  /* 预乘展开：不透明像素（a=255）逐位精确，半透明按 a 归一。 */
  return ((int64_t)((r * 255) / a) << 16) | ((int64_t)((g * 255) / a) << 8) |
         (int64_t)((b * 255) / a);
}
