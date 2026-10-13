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
