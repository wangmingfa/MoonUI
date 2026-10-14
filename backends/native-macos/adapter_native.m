/* MoonUI 的原生 Cocoa 后端（设计文档 §51 的 Backend #2，macOS 半）。
 *
 * 和 ../libui-macos/adapter_macos.m 导出同一套 moonui_* 符号，但**不经过
 * libui-ng**：窗口、事件循环、回调全部直写 AppKit。这是"libui-ng 只是第一个
 * Backend"（§51）的正面落地——MoonBit 侧只认这套 moonui_* 名字，换后端不动
 * Core。本文件只实现 FP1 需要的窗口 + 事件循环那一半；控件（Button/Label/…）
 * 在 FP2 补，补之前 MoonBit 侧对应的方法 raise Unsupported。
 *
 * 和 libui 那份的分叉，逐条列在这里：
 *   - 原生对象就是 NSWindow 本身，句柄直接是它的指针（libui 那份要经
 *     uiControlHandle 从 uiWindow 结构体里把 NSWindow 抠出来）。
 *   - 生命周期自己管：libui 那份的 NSWindow 由 libui 持有，本文件只借指针；
 *     这里 NSWindow 归本文件所有，用一张强引用表（moonui_live_windows）在 ARC
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
#include "../libui-common/adapter.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

/* 排查"死在哪一次 FFI 调用"用的开关，和 libui 那份同一套：native 测试进程里
 * MoonBit 的 println 是全缓冲的，异常退出时整段丢失，只有 C 侧即时 fflush 的输出
 * 留得住顺序。打开方式是在本包 moon.pkg 里加 stub-cc-flags: "-DMOONUI_TRACE"。 */
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
 * 它，不 incref 回来的就是尸体（§47 风险 1）。一个窗口两个回调（closing /
 * resized），96 个对当前的 Demo 和测试都够用；用满时注册返回 -1。 */
#define MOONUI_SLOTS 96

typedef struct {
  void *owner;
  moonui_closure_fn fn;
  void *closure;
} MoonuiSlot;

static MoonuiSlot moonui_slots[MOONUI_SLOTS];
static char moonui_error[512];

/* 进程级单例标志：重复 init 直接返回成功，没初始化过的 terminate 是空操作。 */
static int moonui_inited = 0;
/* 主循环已结束（moonui_quit 置位）。moonui_main_step 从这里开始返回 0。 */
static int moonui_loop_ended = 0;

/* 强引用表：ARC 下把活着的 NSWindow 钉住。句柄是裸指针，ARC 不认它，不另存一份
 * 强引用，窗口建出来当场就被释放。销毁时从这里摘掉，最后一份引用没了窗口自己
 * dealloc。这是本文件唯一"替 MoonBit 看守原生对象"的地方。 */
static NSMutableArray *moonui_live_windows = nil;

/* 控件的强引用表（FP2）：和 moonui_live_windows 同一套 MRC 看守。控件建出来就
 * 进表（+1），attach 时 contentView 再 retain 一份，destroy 时从表和 superview
 * 都摘掉、最后一份引用没了它自己 dealloc。 */
static NSMutableArray *moonui_live_widgets = nil;

/* 控件的 kind 记号：创建时写一次、之后只读，记在 view 自己身上（关联对象，和
 * libui 那份的 moonui_mark_kind 同一套手法）。通用属性入口（set_value /
 * append_option / set_selected / set_text / set_checked）按它分派到具体的
 * NSView 子类。编码与 adapter.h 一致：0=Label … 13=VSeparator、14=MenuRow。
 * 存 kind+1，0 = 没有记号。 */
static const void *const moonui_widget_kind_key = &moonui_widget_kind_key;

/* 控件的回调槽位号：注册回调时记在 view 身上，action/delegate 方法读它去 fire。
 * 存 slot+1，0 = 没注册过。 */
static const void *const moonui_widget_slot_key = &moonui_widget_slot_key;

static void moonui_mark_widget_kind(NSView *v, int kind) {
  if (v != nil) {
    objc_setAssociatedObject(v, moonui_widget_kind_key,
                             (id)(uintptr_t)(kind + 1), OBJC_ASSOCIATION_ASSIGN);
  }
}

static int moonui_widget_kind_of(NSView *v) {
  if (v == nil) {
    return -1;
  }
  return (int)(uintptr_t)objc_getAssociatedObject(v, moonui_widget_kind_key) - 1;
}

static void moonui_set_widget_slot(NSView *v, int slot) {
  if (v != nil) {
    objc_setAssociatedObject(v, moonui_widget_slot_key,
                             (id)(uintptr_t)(slot + 1), OBJC_ASSOCIATION_ASSIGN);
  }
}

static int moonui_widget_slot_of(NSView *v) {
  if (v == nil) {
    return -1;
  }
  return (int)(uintptr_t)objc_getAssociatedObject(v, moonui_widget_slot_key) - 1;
}

/* 菜单行的选中态：单独记在 view 身上，不借 NSButton 的 state——momentary 型按钮
 * 的 state 点完会自己弹回 off，靠它画高亮会闪。这里存 0/1，drawRect 读它画底，
 * set_checked 写它。存 selected+1，0 = 没设过（按未选中画）。 */
static const void *const moonui_widget_selected_key = &moonui_widget_selected_key;

static void moonui_mark_widget_selected(NSView *v, int selected) {
  if (v != nil) {
    objc_setAssociatedObject(v, moonui_widget_selected_key,
                             (id)(uintptr_t)(selected + 1), OBJC_ASSOCIATION_ASSIGN);
  }
}

static int moonui_widget_selected_of(NSView *v) {
  uintptr_t raw;
  if (v == nil) {
    return 0;
  }
  raw = (uintptr_t)objc_getAssociatedObject(v, moonui_widget_selected_key);
  return raw == 0 ? 0 : (int)(raw - 1);
}

/* ---- 小工具：句柄 ---- */

static NSWindow *moonui_nswindow(moonui_ptr w) {
  return (NSWindow *)(uintptr_t)w;
}

/* ---- 小工具：字符串 ---- */

static int64_t moonui_pack2(int a, int b) {
  return ((int64_t)(int32_t)a << 32) | (int64_t)(uint32_t)b;
}

/* MoonBit 的 Bytes 不保证 NUL 结尾，NSString 要。复制一份是唯一不靠运气的做法，
 * 调用方负责 free。 */
static char *moonui_dup(const char *s, int len) {
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
static NSString *moonui_string_of(const char *s, int len) {
  char *t = moonui_dup(s, len);
  NSString *out;
  if (t == 0) {
    return nil;
  }
  out = [NSString stringWithUTF8String:t];
  free(t);
  return out;
}

static moonbit_bytes_t moonui_bytes_of(const char *s) {
  int n = (int)strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  if (n > 0) {
    memcpy(out, s, (size_t)n);
  }
  return out;
}

/* ---- 小工具：单位换算（本文件唯一的像素↔点换算）---- */

/* 主屏（primary display）。[NSScreen mainScreen] 不是硬件主显示器——它跟着键盘
 * 焦点走（"当前拿着键盘焦点的那只窗口所在的屏"），焦点挪到副屏它就换人。
 * [NSScreen screens] 的第 0 个才是主显示器，列表还空着（太早）才退回 mainScreen。 */
static NSScreen *moonui_primary_screen(void) {
  NSArray *screens = [NSScreen screens];
  if ([screens count] > 0) {
    return screens[0];
  }
  return [NSScreen mainScreen];
}

/* 缩放倍数：1 = 普通屏，2 = Retina。取不到时按 1 算，绝不能返回 0——它要进除法。 */
static CGFloat moonui_system_scale(void) {
  NSScreen *screen = moonui_primary_screen();
  CGFloat scale = screen != nil ? [screen backingScaleFactor] : (CGFloat)1.0;
  return scale > (CGFloat)0 ? scale : (CGFloat)1.0;
}

static CGFloat moonui_window_scale_of(NSWindow *w) {
  CGFloat scale = w != nil ? [w backingScaleFactor] : (CGFloat)0;
  return scale > (CGFloat)0 ? scale : moonui_system_scale();
}

static CGFloat moonui_window_scale(moonui_ptr w) {
  return moonui_window_scale_of(moonui_nswindow(w));
}

/* 物理像素 → 点。交给 AppKit 的量保持 CGFloat，不做整数化：setFrame: 收小数，
 * 所以 px→pt→px 的往返在本文件是自逆的。 */
static CGFloat moonui_px_to_pt(int px, CGFloat scale) {
  return (CGFloat)px / scale;
}

/* 点 → 物理像素。这里必须落到整数（adapter.h 的打包返回就是 int32），四舍五入。 */
static int moonui_pt_to_px(CGFloat pt, CGFloat scale) {
  return (int)llround(pt * scale);
}

/* 只收 int 的入口（窗口尺寸、位置）用这个：点是整数，最坏差半个点。 */
static int moonui_px_to_whole_pt(int px, CGFloat scale) {
  return (int)llround((CGFloat)px / scale);
}

/* DPI：Cocoa 没有"每窗口 DPI"这个概念，倍数就是全部信息，96 是它的基准。 */
static int moonui_dpi_of_scale(CGFloat scale) {
  return (int)llround(scale * (CGFloat)96.0);
}

/* ---- 回调槽位（与 libui 那份同构）---- */

static void moonui_release_slot(MoonuiSlot *slot) {
  if (slot->closure != 0) {
    moonbit_decref(slot->closure);
    slot->closure = 0;
  }
  slot->fn = 0;
  slot->owner = 0;
}

/* 松开某个 owner 占用的槽位；fn 非空时只松匹配该回调的那一格——一个窗口有两个
 * 回调，注册 resized 不能把 closing 一起清掉。 */
static void moonui_forget(void *owner, moonui_closure_fn fn) {
  int i;
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    if (moonui_slots[i].owner == owner &&
        (fn == 0 || moonui_slots[i].fn == fn)) {
      moonui_release_slot(&moonui_slots[i]);
    }
  }
}

/* 装一个回调。同一个 (owner, fn) 只留最后一份，所以重复注册不会漏引用。 */
static int moonui_take_slot(void *owner, moonui_closure_fn fn, void *closure) {
  int i;
  moonui_forget(owner, fn);
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    if (moonui_slots[i].owner == 0) {
      moonui_slots[i].owner = owner;
      moonui_slots[i].fn = fn;
      moonui_slots[i].closure = closure;
      if (closure != 0) {
        moonbit_incref(closure);
      }
      return i;
    }
  }
  return -1;
}

static void moonui_fire(void *data) {
  MoonuiSlot *slot = (MoonuiSlot *)data;
  if (slot != 0 && slot->fn != 0) {
    slot->fn(slot->closure);
  }
}

/* ---- 回调分发器（前向声明）----
 *
 * 所有控件的 target-action 与文本 delegate 都指向这一只全局对象。它的实现
 * （@implementation）在下面的控件一节里，这里只前向声明接口和静态指针，好让
 * moonui_init 能建它、控件注册时能引用它。它不持有任何控件的强引用（target /
 * delegate 都是 assign 语义），所以不会把已销毁的控件钉住。 */
@interface MoonuiDispatcher : NSObject <NSTextFieldDelegate>
@end

static MoonuiDispatcher *moonui_dispatcher = nil;

/* ---- 窗口子类：回调的落点 ---- */

/* libui 那份的回调挂在 uiWindow 上、由 libui 分发；这里没有 libui，回调直接挂在
 * NSWindow 自己身上。closing 覆写 windowShouldClose:——固定返回 NO 否决 AppKit
 * 自己的销毁，销毁顺序留给 Core（先内容树后窗口，§12）；resized 走 NSWindowDelegate
 * 的 windowDidResize:，程序化改尺寸时用 suppress_resize 挡掉回声（adapter.h 的
 * on_resized 契约）。 */
@interface MoonuiWindow : NSWindow <NSWindowDelegate>
@property(nonatomic, assign) int closing_slot;
@property(nonatomic, assign) int resized_slot;
@property(nonatomic, assign) BOOL suppress_resize;
@end

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
  }
  return self;
}

- (BOOL)windowShouldClose:(id)sender {
  (void)sender;
  if (self.closing_slot >= 0) {
    moonui_fire(&moonui_slots[self.closing_slot]);
  }
  return NO;
}

- (void)windowDidResize:(NSNotification *)note {
  (void)note;
  if (!self.suppress_resize && self.resized_slot >= 0) {
    moonui_fire(&moonui_slots[self.resized_slot]);
  }
}
@end

/* ---- 生命周期 ---- */

int moonui_init(void) {
  TRACE("init");
  if (moonui_inited) {
    return 0;
  }
  moonui_error[0] = '\0';
  @autoreleasepool {
    /* 自己接管 NSApplication 单例：libui 的 uiInit 在 darwin 侧干的就是这件事，
     * 这里直接做，不经过它。activation policy 设成 Regular 让窗口能拿到焦点、
     * 出现在 Dock 里（探针里量过：不设的话 isKey 恒 0）。 */
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
    if (moonui_live_windows == nil) {
      /* MRC：[NSMutableArray array] 是 autoreleased 的，赋给全局不会 retain，
       * 池一 drain 它就没了、全局变悬垂（terminate 时再碰就是野指针）。用
       * alloc/init 拿 +1，进程级常驻、不释放。 */
      moonui_live_windows = [[NSMutableArray alloc] init];
    }
    if (moonui_live_widgets == nil) {
      moonui_live_widgets = [[NSMutableArray alloc] init];
    }
    if (moonui_dispatcher == nil) {
      /* 进程级单例：所有控件的 target-action 与文本 delegate 都指向它。alloc/init
       * 拿 +1、永不释放（进程退出时随进程走）。它不持有任何控件的强引用，所以不会
       * 把已销毁的控件钉住。 */
      moonui_dispatcher = [[MoonuiDispatcher alloc] init];
    }
  }
  moonui_inited = 1;
  return 0;
}

moonbit_bytes_t moonui_last_error(void) {
  TRACE("last_error");
  return moonui_bytes_of(moonui_error);
}

void moonui_terminate(void) {
  int i;
  TRACE("terminate");
  /* 先排槽位表：槽位里看守的闭包要 decref，窗口销毁（MoonBit 侧已先做）之后这里
   * 把剩下的引用松干净。强引用表最后清——窗口对象由它钉着，清掉才真正 dealloc。 */
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    moonui_release_slot(&moonui_slots[i]);
  }
  if (!moonui_inited) {
    return;
  }
  moonui_inited = 0;
  moonui_loop_ended = 0;
  @autoreleasepool {
    [moonui_live_windows removeAllObjects];
    /* 控件应当已经全部销毁（Core 的顺序保证）；这里清表是兜底——万一有漏网的，
     * 最后一份引用在这里松掉、它自己 dealloc。 */
    [moonui_live_widgets removeAllObjects];
  }
  /* 不调 [NSApp terminate:]：那是"退出进程"，而 MoonBit 侧的 terminate 只是收尾，
   * 进程要等 main 返回才退。事件循环是我们自己泵的不是 [NSApp run]，所以这里不
   * 终止 NSApp 也不影响退出。 */
}

/* ---- 窗口 ---- */

moonui_ptr moonui_window_new(const char *title,
                             int title_len,
                             int width,
                             int height) {
  NSString *t;
  CGFloat scale;
  int wpt;
  int hpt;
  TRACE("window_new");
  t = moonui_string_of(title, title_len);
  scale = moonui_system_scale();
  /* 宽高是客户区的点，这里进来的还是物理像素，所以先除一次倍数。窗口还没建出来，
   * 只能用主屏倍数；Core 在建完后会按窗口自己的倍数再纠正一次尺寸
   * （backend.mbt 的 create_window），和 libui 那份同一套。 */
  wpt = moonui_px_to_whole_pt(width, scale);
  hpt = moonui_px_to_whole_pt(height, scale);
  @autoreleasepool {
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
    [win center];
    /* addObject: 替强引用表 retain 一份（+1），本地这份 alloc/init 的 +1 在这里
     * 松掉——窗口从此只被表钉着，销毁时表摘掉、最后一份引用没了它自己 dealloc。 */
    [moonui_live_windows addObject:win];
    [win release];
    return (moonui_ptr)(uintptr_t)win;
  }
}

void moonui_window_show(moonui_ptr w) {
  TRACE("window_show");
  @autoreleasepool {
    [moonui_nswindow(w) makeKeyAndOrderFront:nil];
  }
}

void moonui_window_hide(moonui_ptr w) {
  TRACE("window_hide");
  @autoreleasepool {
    [moonui_nswindow(w) orderOut:nil];
  }
}

void moonui_window_destroy(moonui_ptr w) {
  MoonuiWindow *win;
  TRACE("window_destroy");
  win = (MoonuiWindow *)(uintptr_t)w;
  /* 先松开替这个窗口看守的 closing/resized 引用。控件必须已经全部销毁
   * （Core 的顺序保证），否则窗口拆掉后 view 还留在 contentView 的 subviews 里。 */
  moonui_forget((void *)(uintptr_t)w, 0);
  /* 用 orderOut: 而不是 close: 摘窗口——close: 在 MRC 下会替 AppKit 把窗口
   * release 掉（"orderOut + release"），那会多松一份引用、把窗口当场 dealloc，
   * 后面再碰就是野指针（探针里量过：close 版在最终 release 处 EXC_BAD_ACCESS，
   * orderOut 版干净退出）。orderOut: 只把窗口移出屏幕、不松引用，引用全归强引用
   * 表管。临时 retain 一份把窗口钉过池的边界，池排完再松，dealloc 落在池外。 */
  [win retain];
  @autoreleasepool {
    [win orderOut:nil];
    [moonui_live_windows removeObject:win];
  }
  [win release];
}

void moonui_window_set_title(moonui_ptr w, const char *title, int title_len) {
  NSString *t;
  TRACE("window_set_title");
  t = moonui_string_of(title, title_len);
  @autoreleasepool {
    [moonui_nswindow(w) setTitle:t];
  }
}

void moonui_window_set_content_size(moonui_ptr w, int width, int height) {
  CGFloat scale;
  TRACE("window_set_content_size");
  scale = moonui_window_scale(w);
  @autoreleasepool {
    MoonuiWindow *win = (MoonuiWindow *)(uintptr_t)w;
    /* suppress_resize 挡掉"程序化改尺寸"的回声（adapter.h 的 on_resized 契约）：
     * Core 建完窗口会立刻纠正一次尺寸，那不该变成一条 Resize 事件。 */
    win.suppress_resize = YES;
    [win setContentSize:NSMakeSize(moonui_px_to_pt(width, scale),
                                   moonui_px_to_pt(height, scale))];
    win.suppress_resize = NO;
  }
}

int64_t moonui_window_content_size(moonui_ptr w) {
  NSRect content;
  CGFloat scale;
  TRACE("window_content_size");
  @autoreleasepool { content = [moonui_nswindow(w) contentRectForFrameRect:[moonui_nswindow(w) frame]]; }
  scale = moonui_window_scale(w);
  return moonui_pack2(moonui_pt_to_px(content.size.width, scale),
                      moonui_pt_to_px(content.size.height, scale));
}

void moonui_window_set_position(moonui_ptr w, int x, int y) {
  CGFloat scale;
  TRACE("window_set_position");
  scale = moonui_window_scale(w);
  @autoreleasepool {
    /* 收的是"外层左上角、屏幕坐标、y 向下"。Cocoa 的 setFrameOrigin: 收的是
     * 左下角、y 向上，所以这里翻一次 y：用窗口所在屏的可见区高度减掉目标 y 和
     * 窗口高度。和 libui 的 darwin 版（window.m 的 uiWindowSetPosition）同一套。 */
    NSWindow *win = moonui_nswindow(w);
    NSScreen *screen = [win screen] != nil ? [win screen] : moonui_primary_screen();
    NSRect visible = screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
    NSRect frame = [win frame];
    CGFloat originY = visible.origin.y + visible.size.height -
                      moonui_px_to_pt(y, scale) - frame.size.height;
    [win setFrameOrigin:NSMakePoint(visible.origin.x + moonui_px_to_pt(x, scale),
                                    originY)];
  }
}

int64_t moonui_window_position(moonui_ptr w) {
  NSRect frame;
  NSRect visible;
  NSScreen *screen;
  CGFloat scale;
  TRACE("window_position");
  @autoreleasepool {
    NSWindow *win = moonui_nswindow(w);
    frame = [win frame];
    screen = [win screen] != nil ? [win screen] : moonui_primary_screen();
    visible = screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
  }
  scale = moonui_window_scale(w);
  /* 和 setter 同一套翻转：y 从"该屏可见区上边往下"量。 */
  return moonui_pack2(
      moonui_pt_to_px(frame.origin.x - visible.origin.x, scale),
      moonui_pt_to_px(visible.size.height - (frame.origin.y + frame.size.height - visible.origin.y), scale));
}

void moonui_window_set_resizable(moonui_ptr w, int resizable) {
  TRACE("window_set_resizable");
  @autoreleasepool {
    NSWindow *win = moonui_nswindow(w);
    if (resizable) {
      win.styleMask |= NSWindowStyleMaskResizable;
    } else {
      win.styleMask &= ~NSWindowStyleMaskResizable;
    }
  }
}

void moonui_window_set_fullscreen(moonui_ptr w, int fullscreen) {
  TRACE("window_set_fullscreen");
  @autoreleasepool {
    NSWindow *win = moonui_nswindow(w);
    BOOL is_fs = (win.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (fullscreen && !is_fs) {
      [win toggleFullScreen:nil];
    } else if (!fullscreen && is_fs) {
      [win toggleFullScreen:nil];
    }
  }
}

void moonui_window_set_titlebar_style(moonui_ptr w, int immersive) {
  TRACE("window_set_titlebar_style");
  @autoreleasepool {
    NSWindow *win = moonui_nswindow(w);
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

int moonui_window_titlebar_style(moonui_ptr w) {
  int bits = 0;
  TRACE("window_titlebar_style");
  @autoreleasepool {
    NSWindow *win = moonui_nswindow(w);
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

void moonui_window_set_traffic_light_position(moonui_ptr w, int x, int y) {
  CGFloat scale;
  TRACE("window_set_traffic_light_position");
  scale = moonui_window_scale(w);
  @autoreleasepool {
    NSWindow *win = moonui_nswindow(w);
    NSButton *close = [win standardWindowButton:NSWindowCloseButton];
    if (close == nil) {
      return;
    }
    /* 收的是"关闭按钮左上角相对窗口左上角"的物理像素。Cocoa 里按钮的 frame 在
     * 窗口坐标系（y 向上），翻一次 y。AppKit 会按这只按钮的位置把另外两只相对
     * 摆好，所以只挪关闭按钮就够。 */
    NSRect f = close.frame;
    CGFloat winH = [win frame].size.height;
    f.origin = NSMakePoint(moonui_px_to_pt(x, scale),
                           winH - moonui_px_to_pt(y, scale) - f.size.height);
    close.frame = f;
  }
}

int64_t moonui_window_traffic_light_position(moonui_ptr w) {
  CGFloat scale;
  TRACE("window_traffic_light_position");
  scale = moonui_window_scale(w);
  @autoreleasepool {
    NSWindow *win = moonui_nswindow(w);
    NSButton *close = [win standardWindowButton:NSWindowCloseButton];
    if (close == nil) {
      return moonui_pack2(0, 0);
    }
    NSRect f = close.frame;
    CGFloat winH = [win frame].size.height;
    return moonui_pack2(moonui_pt_to_px(f.origin.x, scale),
                        moonui_pt_to_px(winH - f.origin.y - f.size.height, scale));
  }
}

int moonui_window_dpi(moonui_ptr w) {
  TRACE("window_dpi");
  return moonui_dpi_of_scale(moonui_window_scale(w));
}

int moonui_window_on_closing(moonui_ptr w,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("window_on_closing");
  slot = moonui_take_slot((void *)(uintptr_t)w, fn, closure);
  if (slot < 0) {
    return -1;
  }
  ((MoonuiWindow *)(uintptr_t)w).closing_slot = slot;
  return 0;
}

int moonui_window_on_resized(moonui_ptr w,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("window_on_resized");
  slot = moonui_take_slot((void *)(uintptr_t)w, fn, closure);
  if (slot < 0) {
    return -1;
  }
  ((MoonuiWindow *)(uintptr_t)w).resized_slot = slot;
  return 0;
}

/* ---- 屏幕与主题 ---- */

int moonui_system_dpi(void) {
  TRACE("system_dpi");
  return moonui_dpi_of_scale(moonui_system_scale());
}

int64_t moonui_screen_work_area(void) {
  NSScreen *screen;
  NSRect visible;
  CGFloat scale;
  TRACE("screen_work_area");
  @autoreleasepool {
    screen = moonui_primary_screen();
    if (screen == nil) {
      return moonui_pack2(0, 0);
    }
    visible = [screen visibleFrame];
    scale = [screen backingScaleFactor];
  }
  if (scale <= (CGFloat)0) {
    scale = moonui_system_scale();
  }
  return moonui_pack2(moonui_pt_to_px(visible.size.width, scale),
                      moonui_pt_to_px(visible.size.height, scale));
}

/* 这只窗口当下在哪块屏。没上屏（screen 为 nil，比如刚建好还没 show）退回主屏。 */
static NSRect moonui_window_screen_visible(moonui_ptr w) {
  NSWindow *win;
  NSScreen *screen;
  win = moonui_nswindow(w);
  screen = win != nil ? [win screen] : nil;
  if (screen == nil) {
    screen = moonui_primary_screen();
  }
  return screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
}

int64_t moonui_window_screen_origin(moonui_ptr w) {
  NSRect visible;
  CGFloat scale;
  TRACE("window_screen_origin");
  @autoreleasepool { visible = moonui_window_screen_visible(w); }
  scale = moonui_window_scale(w);
  /* y 恒 0：这个坐标空间的原点就是该屏可见区左上角（和 libui 的 darwin 版同一
   * 口径）。x 不是 0：那只屏在主屏右边时 visibleFrame.origin.x 就是非零的 Cocoa x。 */
  return moonui_pack2(moonui_pt_to_px(visible.origin.x, scale), 0);
}

int64_t moonui_window_screen_size(moonui_ptr w) {
  NSRect visible;
  CGFloat scale;
  TRACE("window_screen_size");
  @autoreleasepool { visible = moonui_window_screen_visible(w); }
  if (visible.size.width <= (CGFloat)0 || visible.size.height <= (CGFloat)0) {
    return moonui_screen_work_area();
  }
  scale = moonui_window_scale(w);
  return moonui_pack2(moonui_pt_to_px(visible.size.width, scale),
                      moonui_pt_to_px(visible.size.height, scale));
}

int moonui_system_theme(void) {
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

/* ---- 事件循环 ---- */

void moonui_main_steps(void) {
  TRACE("main_steps");
  /* finishLaunching 把 App 变成真正在跑的 App（建主菜单、激活）。libui 的
   * uiMainSteps 在 darwin 侧干的就是这件事，这里直接做。 */
  @autoreleasepool {
    [NSApp finishLaunching];
  }
}

int moonui_main_step(int wait) {
  (void)wait;
  TRACE("main_step");
  if (moonui_loop_ended) {
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
int moonui_messages_pending(void) {
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
int moonui_wait_messages(int ms) {
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
int64_t moonui_time_ms(void) {
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

void moonui_quit(void) {
  TRACE("quit");
  /* 只把循环标成"跑完了"，不真的退出进程：MoonBit 侧的收尾照常用 native_terminate
   * 走，进程等 main 返回才退。和 libui 的 steps 模式同一套语义。 */
  moonui_loop_ended = 1;
}

/* =====================================================================
 * 控件（FP2）：直写 AppKit 的 NSButton / NSTextField / NSSlider / …
 *
 * 和 libui 那份的分叉：libui 的控件是 uiControl 结构体、由 libui 持有并布局；
 * 这里的控件就是 NSView 本身，句柄直接是它的指针，生命周期归本文件的强引用表
 * （moonui_live_widgets）管，布局由 Core 算好绝对矩形、经 moonui_control_set_bounds
 * 摆进窗口的 contentView（§14：叶子控件的原生父级都是窗口）。
 *
 * 回调走两条路：
 *   - target-action（按钮/滑块/步进/下拉/日期）：view 的 target 指向全局的
 *     moonui_dispatcher，action 是 dispatch:，dispatcher 读 view 身上的槽位号去 fire。
 *   - delegate（文本框/多行文本）：view 的 delegate 指向 dispatcher（或容器自己），
 *     文本变化时读槽位号 fire。delegate 是 assign 语义、不 retain，所以没有
 *     NSNotificationCenter 那种"观察者还指着已释放对象"的 MRC 隐患。
 * ===================================================================== */

/* ---- 扁平可点文本行（§51 画册左栏）----
 *
 * 无边框、左对齐的按钮，选中态（state on）时自己画一块圆角高亮底——这就是
 * macOS 设置那种"一行一项、选中高亮"的菜单感。高亮用系统的
 * selectedContentBackgroundColor（浅色下是强调色），不硬编码颜色。 */
@interface MoonuiMenuRow : NSButton
@end

@implementation MoonuiMenuRow
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    [self setBordered:NO];
    [self setButtonType:NSButtonTypeMomentaryChange];
    [self setAlignment:NSTextAlignmentLeft];
    [self setLineBreakMode:NSLineBreakByTruncatingTail];
  }
  return self;
}

- (void)drawRect:(NSRect)dirtyRect {
  if (moonui_widget_selected_of(self)) {
    NSRect r = NSInsetRect(self.bounds, 4.0, 2.0);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:5.0 yRadius:5.0];
    [[NSColor selectedContentBackgroundColor] set];
    [p fill];
  }
  [super drawRect:dirtyRect];
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
  int slot = moonui_widget_slot_of(self);
  if (slot >= 0) {
    moonui_fire(&moonui_slots[slot]);
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
  int slot = moonui_widget_slot_of(self);
  if (slot >= 0) {
    moonui_fire(&moonui_slots[slot]);
  }
}
@end

/* ---- 回调分发器的实现 ----
 *
 * 接口与静态指针在文件前部（moonui_init 之前）已声明；这里只补实现。全局一只，
 * 替所有控件接 target-action 与文本 delegate。它不持有任何控件的强引用
 * （target/delegate 都是 assign），所以不会把已销毁的控件钉住。 */
@implementation MoonuiDispatcher
- (void)dispatch:(id)sender {
  int slot = moonui_widget_slot_of((NSView *)sender);
  if (slot >= 0) {
    moonui_fire(&moonui_slots[slot]);
  }
}

- (void)controlTextDidChange:(NSNotification *)note {
  int slot = moonui_widget_slot_of((NSView *)note.object);
  if (slot >= 0) {
    moonui_fire(&moonui_slots[slot]);
  }
}
@end

/* 建一只控件的公共尾巴：打 kind 记号、进强引用表、松掉本地引用。返回 view 指针。
 * 调用方传进来的 v 是 alloc/init 出来的（+1），这里 addObject 再 +1、release -1，
 * 净剩表里那一份——和窗口同一套 MRC 看守。 */
static NSView *moonui_finish_widget(NSView *v, int kind) {
  if (v == nil) {
    return nil;
  }
  moonui_mark_widget_kind(v, kind);
  @autoreleasepool {
    [moonui_live_widgets addObject:v];
  }
  [v release];
  return v;
}

/* ---- 构造 ---- */

moonui_ptr moonui_widget_new(int kind, const char *text, int text_len) {
  NSString *t;
  NSView *v = nil;
  TRACE("widget_new");
  t = moonui_string_of(text, text_len);
  @autoreleasepool {
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
      default:
        v = nil;
        break;
    }
  }
  v = moonui_finish_widget(v, kind);
  return (moonui_ptr)(uintptr_t)v;
}

void moonui_widget_destroy(moonui_ptr c) {
  NSView *v;
  TRACE("widget_destroy");
  v = (NSView *)(uintptr_t)c;
  /* 先松开替这个控件看守的回调引用，再从 superview 和强引用表都摘掉——MRC 下
   * addSubview 不 retain，表是唯一的 owner，摘掉最后一份引用它自己 dealloc。 */
  moonui_forget((void *)(uintptr_t)c, 0);
  @autoreleasepool {
    [v removeFromSuperview];
    [moonui_live_widgets removeObject:v];
  }
}

/* ---- 文本 ---- */

void moonui_widget_set_text(moonui_ptr c, const char *text, int text_len) {
  NSString *t;
  int kind;
  TRACE("widget_set_text");
  t = moonui_string_of(text, text_len);
  kind = moonui_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
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

moonbit_bytes_t moonui_widget_text(moonui_ptr c) {
  NSString *s;
  int kind;
  TRACE("widget_text");
  kind = moonui_widget_kind_of((NSView *)(uintptr_t)c);
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
  return moonui_bytes_of([s UTF8String]);
}

/* ---- 勾选态（Checkbox 与 MenuRow 共用）----
 *
 * Checkbox 走 NSButton 的 state（系统画勾选框）；MenuRow 走关联对象里的选中态
 * （自己画高亮底，见 MoonuiMenuRow.drawRect）。两条路都经 set_checked/checked
 * 这对入口，Core 不感知差别。 */

void moonui_widget_set_checked(moonui_ptr c, int checked) {
  NSView *v;
  int kind;
  TRACE("widget_set_checked");
  v = (NSView *)(uintptr_t)c;
  kind = moonui_widget_kind_of(v);
  @autoreleasepool {
    if (kind == 14) { /* MenuRow */
      moonui_mark_widget_selected(v, checked);
      [v setNeedsDisplay:YES];
    } else { /* Checkbox（其余 kind 不该走到这，Core 已挡） */
      NSButton *b = (NSButton *)v;
      [b setState:(checked ? NSControlStateValueOn : NSControlStateValueOff)];
      [b setNeedsDisplay:YES];
    }
  }
}

int moonui_widget_checked(moonui_ptr c) {
  NSView *v;
  int kind;
  int on;
  TRACE("widget_checked");
  v = (NSView *)(uintptr_t)c;
  kind = moonui_widget_kind_of(v);
  @autoreleasepool {
    if (kind == 14) { /* MenuRow */
      on = moonui_widget_selected_of(v);
    } else { /* Checkbox */
      on = [(NSButton *)v state] == NSControlStateValueOn ? 1 : 0;
    }
  }
  return on;
}

/* ---- 可见 / 可用 ---- */

void moonui_widget_set_visible(moonui_ptr c, int visible) {
  TRACE("widget_set_visible");
  @autoreleasepool { [(NSView *)(uintptr_t)c setHidden:(visible ? NO : YES)]; }
}

int moonui_widget_visible(moonui_ptr c) {
  int visible;
  TRACE("widget_visible");
  @autoreleasepool { visible = ![(NSView *)(uintptr_t)c isHidden]; }
  return visible;
}

void moonui_widget_set_enabled(moonui_ptr c, int enabled) {
  NSView *v;
  TRACE("widget_set_enabled");
  v = (NSView *)(uintptr_t)c;
  @autoreleasepool {
    /* setEnabled: 是 NSControl 的方法，不是 NSView 的——分隔线（NSBox）、单选组
     * 容器、多行文本容器都不是 control，对它们设 enabled 没有意义，跳过。 */
    if ([v isKindOfClass:[NSControl class]]) {
      [(NSControl *)v setEnabled:(enabled ? YES : NO)];
    }
  }
}

int moonui_widget_enabled(moonui_ptr c) {
  NSView *v;
  int enabled;
  TRACE("widget_enabled");
  v = (NSView *)(uintptr_t)c;
  @autoreleasepool {
    enabled = [v isKindOfClass:[NSControl class]] ? [(NSControl *)v isEnabled] : 1;
  }
  return enabled;
}

/* ---- 度量与摆放 ---- */

/* 固有尺寸：原生控件自己的 fittingSize（字体度量属于原生层，§18）。 */
int64_t moonui_widget_minimum_size(moonui_ptr c) {
  NSView *v;
  NSView *content;
  NSSize fit;
  CGFloat scale;
  TRACE("widget_minimum_size");
  v = (NSView *)(uintptr_t)c;
  @autoreleasepool {
    [v layoutSubtreeIfNeeded];
    fit = [v fittingSize];
    content = [v superview];
  }
  scale = content != nil ? moonui_window_scale_of([content window]) : moonui_system_scale();
  return moonui_pack2(moonui_pt_to_px(fit.width, scale),
                      moonui_pt_to_px(fit.height, scale));
}

int moonui_widget_dpi(moonui_ptr c) {
  NSView *v;
  NSWindow *win;
  CGFloat scale;
  TRACE("widget_dpi");
  v = (NSView *)(uintptr_t)c;
  win = [v window];
  scale = win != nil ? moonui_window_scale_of(win) : moonui_system_scale();
  return moonui_dpi_of_scale(scale);
}

/* 相对父窗口客户区的左上角，物理像素（y 向下）。 */
int64_t moonui_widget_origin(moonui_ptr c) {
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
  scale = moonui_widget_dpi(c) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  if (content == nil) {
    return moonui_pack2(0, 0);
  }
  return moonui_pack2(
      moonui_pt_to_px(o.x, scale),
      moonui_pt_to_px([content bounds].size.height - o.y - f.size.height, scale));
}

int64_t moonui_widget_size(moonui_ptr c) {
  NSRect f;
  CGFloat scale;
  TRACE("widget_size");
  @autoreleasepool { f = [(NSView *)(uintptr_t)c frame]; }
  scale = moonui_widget_dpi(c) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  return moonui_pack2(moonui_pt_to_px(f.size.width, scale),
                      moonui_pt_to_px(f.size.height, scale));
}

/* ---- 回调注册 ---- */

/* target-action 那条路：按钮/滑块/步进/下拉/日期都走它。 */
static int moonui_wire_action(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  NSView *v;
  int slot;
  v = (NSView *)(uintptr_t)c;
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_set_widget_slot(v, slot);
  @autoreleasepool {
    [(NSControl *)v setTarget:moonui_dispatcher];
    [(NSControl *)v setAction:@selector(dispatch:)];
  }
  return 0;
}

int moonui_widget_on_clicked(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("widget_on_clicked");
  return moonui_wire_action(c, fn, closure);
}

int moonui_widget_on_toggled(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("widget_on_toggled");
  return moonui_wire_action(c, fn, closure);
}

/* 文本 delegate 那条路：单行文本框走它（delegate 是 assign，无 MRC 隐患）。 */
int moonui_widget_on_text_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  NSView *v;
  int slot;
  v = (NSView *)(uintptr_t)c;
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_set_widget_slot(v, slot);
  @autoreleasepool {
    [(NSTextField *)v setDelegate:moonui_dispatcher];
  }
  return 0;
}

int moonui_slider_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("slider_on_changed");
  return moonui_wire_action(c, fn, closure);
}

int moonui_spinbox_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("spinbox_on_changed");
  return moonui_wire_action(c, fn, closure);
}

int moonui_combobox_on_selected(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("combobox_on_selected");
  return moonui_wire_action(c, fn, closure);
}

int moonui_datepicker_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  TRACE("datepicker_on_changed");
  return moonui_wire_action(c, fn, closure);
}

/* 单选组：槽位记在容器上，radioClicked: 读它 fire（按钮在 append_option 里建）。 */
int moonui_radio_on_selected(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  int slot;
  TRACE("radio_on_selected");
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_set_widget_slot((NSView *)(uintptr_t)c, slot);
  return 0;
}

/* 多行文本：槽位记在容器上，textDidChange: 读它 fire（delegate 在 init 里就设好）。 */
int moonui_multiline_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  int slot;
  TRACE("multiline_on_changed");
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_set_widget_slot((NSView *)(uintptr_t)c, slot);
  return 0;
}

/* ---- 扩展控件的构造 ---- */

moonui_ptr moonui_slider_new(int min, int max) {
  NSSlider *s;
  TRACE("slider_new");
  @autoreleasepool {
    s = [[NSSlider alloc] init];
    [s setMinValue:(double)min];
    [s setMaxValue:(double)max];
    [s setIntValue:min];
  }
  return (moonui_ptr)(uintptr_t)moonui_finish_widget(s, 6);
}

void moonui_slider_set_range(moonui_ptr c, int min, int max) {
  TRACE("slider_set_range");
  @autoreleasepool {
    NSSlider *s = (NSSlider *)(uintptr_t)c;
    [s setMinValue:(double)min];
    [s setMaxValue:(double)max];
  }
}

moonui_ptr moonui_spinbox_new(int min, int max) {
  NSStepper *s;
  TRACE("spinbox_new");
  @autoreleasepool {
    s = [[NSStepper alloc] init];
    [s setMinValue:(double)min];
    [s setMaxValue:(double)max];
    [s setIncrement:1.0];
    [s setIntValue:min];
  }
  return (moonui_ptr)(uintptr_t)moonui_finish_widget(s, 7);
}

moonui_ptr moonui_progress_new(void) {
  NSProgressIndicator *p;
  TRACE("progress_new");
  @autoreleasepool {
    p = [[NSProgressIndicator alloc] init];
    [p setStyle:NSProgressIndicatorStyleBar];
    [p setMinValue:0.0];
    [p setMaxValue:100.0];
    [p setDoubleValue:0.0];
  }
  return (moonui_ptr)(uintptr_t)moonui_finish_widget(p, 8);
}

moonui_ptr moonui_combobox_new(void) {
  NSPopUpButton *cb;
  TRACE("combobox_new");
  @autoreleasepool {
    cb = [[NSPopUpButton alloc] init];
    [cb setPullsDown:NO];
  }
  return (moonui_ptr)(uintptr_t)moonui_finish_widget(cb, 9);
}

moonui_ptr moonui_radio_new(void) {
  MoonuiRadioGroup *g;
  TRACE("radio_new");
  @autoreleasepool { g = [[MoonuiRadioGroup alloc] init]; }
  return (moonui_ptr)(uintptr_t)moonui_finish_widget(g, 11);
}

moonui_ptr moonui_multiline_new(void) {
  MoonuiMultiline *m;
  TRACE("multiline_new");
  @autoreleasepool { m = [[MoonuiMultiline alloc] init]; }
  return (moonui_ptr)(uintptr_t)moonui_finish_widget(m, 10);
}

moonui_ptr moonui_datepicker_new(void) {
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
  return (moonui_ptr)(uintptr_t)moonui_finish_widget(dp, 12);
}

/* 日期时间文本约定 "YYYY-MM-DD HH:MM:SS"（§13）。 */
static NSDateFormatter *moonui_date_formatter(void) {
  static NSDateFormatter *fmt = nil;
  if (fmt == nil) {
    fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
  }
  return fmt;
}

int moonui_datepicker_set_text(moonui_ptr c, const char *text, int text_len) {
  NSString *t;
  NSDate *d;
  TRACE("datepicker_set_text");
  t = moonui_string_of(text, text_len);
  @autoreleasepool {
    d = [moonui_date_formatter() dateFromString:t];
    if (d == nil) {
      return -1;
    }
    [(NSDatePicker *)(uintptr_t)c setDateValue:d];
  }
  return 0;
}

moonbit_bytes_t moonui_datepicker_text(moonui_ptr c) {
  NSString *s;
  TRACE("datepicker_text");
  @autoreleasepool {
    s = [moonui_date_formatter()
        stringFromDate:[(NSDatePicker *)(uintptr_t)c dateValue]];
  }
  return moonui_bytes_of([s UTF8String]);
}

/* ---- 通用属性入口：按创建时记下的 kind 分派 ---- */

void moonui_widget_set_value(moonui_ptr c, int v) {
  int kind;
  TRACE("widget_set_value");
  kind = moonui_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    switch (kind) {
      case 6: /* Slider */
        [(NSSlider *)(uintptr_t)c setDoubleValue:(double)v];
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

int moonui_widget_value(moonui_ptr c) {
  int kind;
  int val;
  TRACE("widget_value");
  kind = moonui_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
    switch (kind) {
      case 6:
        val = (int)[(NSSlider *)(uintptr_t)c doubleValue];
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

void moonui_widget_append_option(moonui_ptr c, const char *text, int text_len) {
  NSString *t;
  int kind;
  TRACE("widget_append_option");
  t = moonui_string_of(text, text_len);
  kind = moonui_widget_kind_of((NSView *)(uintptr_t)c);
  @autoreleasepool {
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

void moonui_widget_set_selected(moonui_ptr c, int index) {
  int kind;
  TRACE("widget_set_selected");
  kind = moonui_widget_kind_of((NSView *)(uintptr_t)c);
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

int moonui_widget_selected(moonui_ptr c) {
  int kind;
  int idx;
  TRACE("widget_selected");
  kind = moonui_widget_kind_of((NSView *)(uintptr_t)c);
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

void moonui_control_attach(moonui_ptr w, moonui_ptr child) {
  NSView *content;
  TRACE("control_attach");
  @autoreleasepool {
    content = [moonui_nswindow(w) contentView];
    [content addSubview:(NSView *)(uintptr_t)child];
  }
}

void moonui_control_set_bounds(moonui_ptr child, int x, int y, int width, int height) {
  NSView *v;
  NSView *content;
  CGFloat scale;
  TRACE("control_set_bounds");
  v = (NSView *)(uintptr_t)child;
  @autoreleasepool {
    content = [v superview];
  }
  scale = moonui_widget_dpi(child) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  if (content == nil) {
    return;
  }
  @autoreleasepool {
    /* 收的是"客户区左上角、y 向下"的物理像素。contentView 默认不翻转（y 向上），
     * 所以翻一次 y：用客户区高度减掉目标 y 和控件高度。 */
    CGFloat xpt = moonui_px_to_pt(x, scale);
    CGFloat ypt = moonui_px_to_pt(y, scale);
    CGFloat wpt = moonui_px_to_pt(width, scale);
    CGFloat hpt = moonui_px_to_pt(height, scale);
    CGFloat cy = [content bounds].size.height - ypt - hpt;
    [v setFrame:NSMakeRect(xpt, cy, wpt, hpt)];
  }
}

void moonui_control_detach(moonui_ptr child) {
  TRACE("control_detach");
  @autoreleasepool { [(NSView *)(uintptr_t)child removeFromSuperview]; }
}

void moonui_control_raise(moonui_ptr child) {
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

int moonui_control_z_index(moonui_ptr child) {
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
 * moonui_view 从 uiControl 里把 NSView 抠出来），所以解析出 owner 后直接强转。
 * 返回码口径与 libui 一致：0 = 接好，-1 = 窗口句柄不真，-2 = 链里有 owner 换不出
 * view（整份丢弃，不半推），-3 = 文本解析失败或内存不够。
 *
 * 关键一步是关掉 autorecalculatesKeyViewLoop：AppKit 默认每次 addSubview 都按
 * subviews 顺序把 nextKeyView 重算一遍，不关掉的话 Core 声明的链会被 z-order
 * 覆盖（`T29` 要的正是"焦点链和 z-order 解耦"）。Core 的 set_content 先挂完全部
 * 叶子才推链，后到的 NO 总是赢家。 */
int moonui_set_focus_chain(moonui_ptr window, const char *ids, int ids_len) {
  NSWindow *win;
  moonui_ptr *chain = 0;
  NSView **views;
  int len = 0;
  int i;
  const char *p = ids;
  const char *end = ids + ids_len;
  char *stop;
  TRACE("set_focus_chain");
  win = moonui_nswindow(window);
  if (win == nil) {
    return -1;
  }
  /* 两遍走：先数 token 数，再照原样填。strtoull 前进的位数就是 stop - p，0 表示
   * 一个数都没啃下来，那就是坏编码。 */
  while (p < end) {
    unsigned long long v;
    while (p < end && (*p == ' ' || *p == '\t')) {
      ++p;
    }
    if (p >= end) {
      break;
    }
    v = strtoull(p, &stop, 10);
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

int moonui_set_widget_accessibility(moonui_ptr c,
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
  l = moonui_string_of(label, label_len);
  d = moonui_string_of(desc, desc_len);
  @autoreleasepool {
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
        (moonui_widget_kind_of(v) == 3 || moonui_widget_kind_of(v) == 14)) {
      [(NSButton *)v setState:((state & 0xC) == 0x8 ? NSControlStateValueOn
                                                    : NSControlStateValueOff)];
    }
  }
  return 0;
}
