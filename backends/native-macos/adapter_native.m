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

/* 强引用表：ARC 下把活着的 NSWindow 钉住。句柄是裸指针，ARC 不认它，不另存一份
 * 强引用，窗口建出来当场就被释放。销毁时从这里摘掉，最后一份引用没了窗口自己
 * dealloc。这是本文件唯一"替 MoonBit 看守原生对象"的地方。 */
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
  NSArray *screens = [NSScreen screens];
  if ([screens count] > 0) {
    return screens[0];
  }
  return [NSScreen mainScreen];
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
  t = moonui_native_string_of(title, title_len);
  scale = moonui_native_system_scale();
  /* 宽高是客户区的点，这里进来的还是物理像素，所以先除一次倍数。窗口还没建出来，
   * 只能用主屏倍数；Core 在建完后会按窗口自己的倍数再纠正一次尺寸
   * （backend.mbt 的 create_window），和 libui 那份同一套。 */
  wpt = moonui_native_px_to_whole_pt(width, scale);
  hpt = moonui_native_px_to_whole_pt(height, scale);
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
  t = moonui_native_string_of(title, title_len);
  @autoreleasepool {
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

void moonui_native_window_set_position(moonui_ptr w, int x, int y) {
  CGFloat scale;
  TRACE("window_set_position");
  scale = moonui_native_window_scale(w);
  @autoreleasepool {
    /* 收的是"外层左上角、屏幕坐标、y 向下"。Cocoa 的 setFrameOrigin: 收的是
     * 左下角、y 向上，所以这里翻一次 y：用窗口所在屏的可见区高度减掉目标 y 和
     * 窗口高度。和 libui 的 darwin 版（window.m 的 uiWindowSetPosition）同一套。 */
    NSWindow *win = moonui_native_nswindow(w);
    NSScreen *screen = [win screen] != nil ? [win screen] : moonui_native_primary_screen();
    NSRect visible = screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
    NSRect frame = [win frame];
    CGFloat originY = visible.origin.y + visible.size.height -
                      moonui_native_px_to_pt(y, scale) - frame.size.height;
    [win setFrameOrigin:NSMakePoint(visible.origin.x + moonui_native_px_to_pt(x, scale),
                                    originY)];
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
    NSWindow *win = moonui_native_nswindow(w);
    NSButton *close = [win standardWindowButton:NSWindowCloseButton];
    if (close == nil) {
      return;
    }
    /* 收的是"关闭按钮左上角相对窗口左上角"的物理像素。Cocoa 里按钮的 frame 在
     * 窗口坐标系（y 向上），翻一次 y。AppKit 会按这只按钮的位置把另外两只相对
     * 摆好，所以只挪关闭按钮就够。 */
    NSRect f = close.frame;
    CGFloat winH = [win frame].size.height;
    f.origin = NSMakePoint(moonui_native_px_to_pt(x, scale),
                           winH - moonui_native_px_to_pt(y, scale) - f.size.height);
    close.frame = f;
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
    NSRect f = close.frame;
    CGFloat winH = [win frame].size.height;
    return moonui_native_pack2(moonui_native_pt_to_px(f.origin.x, scale),
                        moonui_native_pt_to_px(winH - f.origin.y - f.size.height, scale));
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
  t = moonui_native_string_of(text, text_len);
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
      case 15: {
        /* 滚动视口（T74）：句柄是 NSScrollView，滚动行程由
         * moonui_native_scroll_set_content 后续给出。 */
        v = [[MoonuiNativeScroll alloc] init];
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

/* ---- 文本 ---- */

void moonui_native_widget_set_text(moonui_ptr c, const char *text, int text_len) {
  NSString *t;
  int kind;
  TRACE("widget_set_text");
  t = moonui_native_string_of(text, text_len);
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
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
     * 容器、多行文本容器都不是 control，对它们设 enabled 没有意义，跳过。 */
    if ([v isKindOfClass:[NSControl class]]) {
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
    enabled = [v isKindOfClass:[NSControl class]] ? [(NSControl *)v isEnabled] : 1;
  }
  return enabled;
}

/* ---- 度量与摆放 ---- */

/* 固有尺寸：原生控件自己的 fittingSize（字体度量属于原生层，§18）。 */
int64_t moonui_native_widget_minimum_size(moonui_ptr c) {
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
  scale = content != nil ? moonui_native_window_scale_of([content window]) : moonui_native_system_scale();
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
  TRACE("slider_on_changed");
  return moonui_native_wire_action(c, fn, closure);
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
  NSSlider *s;
  TRACE("slider_new");
  @autoreleasepool {
    s = [[NSSlider alloc] init];
    [s setMinValue:(double)min];
    [s setMaxValue:(double)max];
    [s setIntValue:min];
  }
  return (moonui_ptr)(uintptr_t)moonui_native_finish_widget(s, 6);
}

void moonui_native_slider_set_range(moonui_ptr c, int min, int max) {
  TRACE("slider_set_range");
  @autoreleasepool {
    NSSlider *s = (NSSlider *)(uintptr_t)c;
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
  t = moonui_native_string_of(text, text_len);
  @autoreleasepool {
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

int moonui_native_widget_value(moonui_ptr c) {
  int kind;
  int val;
  TRACE("widget_value");
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
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

void moonui_native_widget_append_option(moonui_ptr c, const char *text, int text_len) {
  NSString *t;
  int kind;
  TRACE("widget_append_option");
  t = moonui_native_string_of(text, text_len);
  kind = moonui_native_widget_kind_of((NSView *)(uintptr_t)c);
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
  CGFloat scale;
  TRACE("control_set_bounds");
  v = (NSView *)(uintptr_t)child;
  @autoreleasepool {
    content = [v superview];
  }
  scale = moonui_native_widget_dpi(child) / 96.0;
  if (scale <= 0) {
    scale = 1.0;
  }
  if (content == nil) {
    return;
  }
  @autoreleasepool {
    /* 收的是"客户区左上角、y 向下"的物理像素。contentView 默认不翻转（y 向上），
     * 所以翻一次 y：用客户区高度减掉目标 y 和控件高度。父级是翻转视图
     * （T74 滚动文档区）时坐标系已经 y 向下，直接用。 */
    CGFloat xpt = moonui_native_px_to_pt(x, scale);
    CGFloat ypt = moonui_native_px_to_pt(y, scale);
    CGFloat wpt = moonui_native_px_to_pt(width, scale);
    CGFloat hpt = moonui_native_px_to_pt(height, scale);
    CGFloat cy = [content isFlipped] ? ypt
                                     : [content bounds].size.height - ypt - hpt;
    [v setFrame:NSMakeRect(xpt, cy, wpt, hpt)];
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
  l = moonui_native_string_of(label, label_len);
  d = moonui_native_string_of(desc, desc_len);
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
                                    block:^(NSTimer *fired) {
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
                                     block:^(NSTimer *fired) {
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
                                     block:^(NSTimer *fired) {
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
 */
static int moonui_native_app_icon_installed = 0;

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
    [NSApp setApplicationIconImage:img];
    [img release];
    moonui_native_app_icon_installed = 1;
  }
  return 0;
}

int moonui_native_app_icon_present(void) {
  return moonui_native_app_icon_installed;
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
