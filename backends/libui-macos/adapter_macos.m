/* MoonUI 的 libui-ng Cocoa Adapter 实现（设计文档 §5、§20；§48 第 03/09/10 步的
 * macOS 半）。
 *
 * 契约在 ../libui-common/adapter.h，Windows 那份实现是 ../libui-windows/adapter.c，两份
 * 导出同一套 moonui_* 符号，所以 ffi.mbt/backend.mbt 完全共享，平台分叉只到 C 为止（§47）。
 *
 * 和 Windows 那份的分叉，逐条列在这里，读改动时不必再重新推：
 *   - 原生对象是 ObjC 指针（NSWindow/NSView/NSControl），不是 HWND；句柄仍然只在
 *     本文件解引用，MoonBit 拿到的是 uintptr_t（§6/§7）。
 *   - **单位**：adapter.h 规定这一层只讲物理像素，而 Cocoa 整层讲点（point），
 *     libui 的 darwin 后端也是把尺寸/位置原样交给 AppKit（见 darwin/window.m 的
 *     uiWindowContentSize：只有 contentRectForFrameRect，没有任何缩放）。所以本文件
 *     是 macOS 上唯一的像素↔点换算处。§30 的"换算只有一处"仍然成立，只是分成了
 *     两段：MoonBit 的 Scale 管逻辑↔物理，本文件管物理↔点。Windows 没有后一段，
 *     因为 DPI 感知进程里的 Win32 API 本来就收物理像素。
 *   - 摆放：darwin 的 libui 只会 Auto Layout 的容器布局，ui_darwin.h 里也没有
 *     uiWindowsControlMinimumSize 的对应物，所以 §14 的绝对摆放直接调 AppKit 的
 *     setFrame:，度量直接问 intrinsicContentSize/cellSize（§18：度量属于原生层）。
 *   - 原点：Cocoa 的 view 坐标默认从左下往上，MoonUI 给的是左上，翻转在
 *     moonui_flip_y 里做；父视图声明了 isFlipped 时两边同向，翻转自动退化成恒等。
 *   - detach：Windows 得把 HWND 搬去一个自建隐藏窗口才能让它"沉默"（WM_COMMAND 是
 *     发给父窗口的）；Cocoa 的按钮走 target/action，消息本来就落在控件自己身上，
 *     所以 removeFromSuperview 就是"摘下来"，控件对象照样由 libui 持有。
 *   - 层叠与焦点：Windows 的子窗口列表同时是绘画顺序和 Tab 顺序，raise 会连带重排
 *     焦点链；Cocoa 的 subviews 数组只管绘画，焦点链是另一条 nextKeyView。attach 时
 *     打开 autorecalculatesKeyViewLoop，让 AppKit 按 subviews 顺序重算焦点链，于是
 *     "插入顺序 = Tab 顺序"这条 Windows 语义在 mac 上是被复制出来的，不是巧合。
 *   - 销毁：DestroyWindow 会连带销毁子窗口，所以 Windows 侧只要顺序对就不会漏；
 *     Cocoa 的 addSubview 对 view 是一次 retain，uiControlDestroy 只松开 libui 自己
 *     那一份引用，所以本文件必须在销毁前 removeFromSuperview，否则 view 既泄着留
 *     在窗口上。
 */
#include "../libui-common/adapter.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#import <Cocoa/Cocoa.h>

#include "ui.h"

/* 排查"死在哪一次 FFI 调用"用的开关，和 Windows 那份同一套：native 测试进程里
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

/* 控件回调的槽位表，和 Windows 那份同构：C 必须替 MoonBit 看守闭包的生命周期，
 * libui 只记函数指针 + void*，GC 看不见它，不 incref 回来的就是尸体（§47 风险 1）。
 * 一个控件一个点击回调、一个窗口两个回调（closing / resized），96 个对当前的 Demo
 * 和测试都够用；用满时注册返回 -1，MoonBit 侧变成显式错误。 */
#define MOONUI_SLOTS 96

typedef struct {
  void *owner;
  moonui_closure_fn fn;
  void *closure;
} MoonuiSlot;

static MoonuiSlot moonui_slots[MOONUI_SLOTS];
static char moonui_error[512];

/* libui 的初始化是进程级的（darwin 侧还会抢 NSApplication 单例），所以这一对是
 * 幂等的单例：重复 init 直接返回成功，没初始化过的 terminate 是空操作。
 * MoonBit 侧的 initialize()/terminate() 因此可以成对调用，不必担心同一个测试进程
 * 里跑了两条测试。 */
static int moonui_inited = 0;

/* 池的纪律，本文件唯一容易踩死人的地方。
 *
 * ObjC 的自动释放池必须按栈式顺序排干：弹出不是栈顶的那一层，runtime 立刻
 * "Invalid or prematurely-freed autorelease pool" 并 abort（实测踩过，测试进程连
 * 一条输出都留不下）。而 libui 自己就在 init 里建一层**活得比这次调用更久**的池
 * （darwin/main.m:137 的 globalPool，到 uiUninit 才排干），所以：
 *   - uiInit/uiUninit 不能用当场排干的 @autoreleasepool 包；
 *   - init 需要的池要存起来，等 uiUninit 排完自己那层之后再排；
 *   - 其余入口都安全：libui 在这里造的对象要么当场就 release，要么落进 globalPool
 *     里由它兜着，不会跨过本函数的边界。 */
static NSAutoreleasePool *moonui_init_pool = nil;

/* ---- 小工具：句柄 ---- */

/* libui 的 uiControlHandle（ui.h:143）在 darwin 上返回的就是真原生对象：
 * uiWindow 是 NSWindow，label/entry 是 NSTextField，button/checkbox 是 NSButton
 * （见 ui_darwin.h 的 uiDarwinControlDefaultHandle）。这是"绕开 libui 的容器布局、
 * 由 MoonUI 自己摆"唯一的入口。 */
static id moonui_handle(moonui_ptr c) {
  return (id)(uintptr_t)uiControlHandle((uiControl *)(uintptr_t)c);
}

static NSView *moonui_view(moonui_ptr c) {
  return (NSView *)(uintptr_t)moonui_handle(c);
}

static NSWindow *moonui_nswindow(moonui_ptr w) {
  return (NSWindow *)(uintptr_t)moonui_handle(w);
}

/* 两个 int32 打包进一个 int64：MoonBit 的 native FFI 只有单返回值。 */
static int64_t moonui_pack2(int a, int b) {
  return ((int64_t)(int32_t)a << 32) | (int64_t)(uint32_t)b;
}

/* MoonBit 的 Bytes 不保证 NUL 结尾，而 libui 收 NUL 结尾的 UTF-8，NSString 也要。
 * 复制一份是唯一不靠运气的做法，调用方负责 free。 */
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
 * 都得有一层 @autoreleasepool 接着（见下面 MOONUI 的说明）。 */
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

/* NSString → MoonBit Bytes。UTF8String 的指针由 NSString 看守，所以当场拷走；
 * 遇到非法编码（落单的代理对）它给 NULL，这里当空串处理而不是崩。 */
static moonbit_bytes_t moonui_bytes_of_ns(NSString *s) {
  const char *u;
  if (s == nil) {
    return moonbit_make_bytes(0, 0);
  }
  u = [s UTF8String];
  if (u == 0) {
    return moonbit_make_bytes(0, 0);
  }
  return moonui_bytes_of(u);
}

/* ---- 小工具：单位换算（本文件唯一的像素↔点换算）---- */

/* 缩放倍数：1 = 普通屏，2 = Retina。取不到（窗口还没上屏、老系统）时按 1 算，
 * 绝不能返回 0——它要进除法。 */
static CGFloat moonui_system_scale(void) {
  NSScreen *screen = [NSScreen mainScreen];
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

/* 控件的倍数取自它所在的窗口；还没挂进窗口时退回进程倍数，和 Windows 侧
 * "取不到父窗口就退回系统 DPI" 是同一条退路。 */
static CGFloat moonui_view_scale(NSView *v) {
  if (v == nil) {
    return moonui_system_scale();
  }
  return moonui_window_scale_of([v window]);
}

/* 物理像素 → 点。交给 AppKit 的量保持 CGFloat，不做整数化：
 * setFrame: 收小数，所以 px→pt→px 的往返在本文件是自逆的，控件矩形不会因为
 * "先取整成整点"而在回读时差 1 像素。 */
static CGFloat moonui_px_to_pt(int px, CGFloat scale) {
  return (CGFloat)px / scale;
}

/* 点 → 物理像素。这里必须落到整数（adapter.h 的打包返回就是 int32），四舍五入。 */
static int moonui_pt_to_px(CGFloat pt, CGFloat scale) {
  return (int)llround(pt * scale);
}

/* 进 libui 的那几个只收 int 的入口（窗口尺寸、窗口位置）用这个：点是整数，
 * 所以窗口级的量在最坏情况下差半个点，也就是 100% 屏差 1 像素、Retina 差 1 像素。
 * 控件矩形不走这条路，见上面。 */
static int moonui_px_to_whole_pt(int px, CGFloat scale) {
  return (int)llround((CGFloat)px / scale);
}

/* DPI：Cocoa 没有"每窗口 DPI"这个概念，倍数就是全部信息，96 是它的基准。 */
static int moonui_dpi_of_scale(CGFloat scale) {
  return (int)llround(scale * (CGFloat)96.0);
}

/* MoonUI 的 y 从父视图顶部往下量，Cocoa 默认从下往上；父视图声明 isFlipped 时本来
 * 同向，恒等返回。摆位和读数共用这一条公式，所以 from/to 只有一份。
 *
 * 代价是"它自己测不出自己"：翻折写在哪一侧都自逆。负控制实测（把它改成恒等）：
 * "控件矩形往返"那条的坐标断言一条都没红，只有文件末尾 moonui_cocoa_origin_of_widget
 * 那条**不经过这里**的原始 Cocoa 读数红了——方向只能靠它对表，见 macos_test.mbt 的
 * "原点是左上角"。改这里之前先想起那条。
 * （那次运行里其余几条也报红，是那句 assert_eq(native_live_handles(), 0) 量的进程
 * 全局表被中途 raise 的测试污染，不是方向问题；读输出只看第一条红。） */
static CGFloat moonui_flip_y(NSView *sup, CGFloat y, CGFloat height) {
  if (sup == nil || [sup isFlipped]) {
    return y;
  }
  return NSHeight([sup bounds]) - y - height;
}

/* ---- 回调槽位（与 Windows 那份同构）---- */

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

/* libui 的回调签名各带一个控件/窗口参数，这几个 trampoline 就是那条签名差异的
 * 适配器：data 还原成槽位，再按 MoonBit 的形状调用。 */
static void moonui_click_trampoline(uiButton *b, void *data) {
  (void)b;
  moonui_fire(data);
}

/* 第一个参数各自不同不是啰嗦：uiEntryOnChanged / uiCheckboxOnToggled 要的函数
 * 指针类型分别是 void(*)(uiEntry*, void*) 和 void(*)(uiCheckbox*, void*)，写成
 * 一个通用的 trampoline 就是 incompatible pointer type。sender 一律丢掉——文字
 * 和勾选态由 MoonBit 回读，见 adapter.h 那两条的约定。 */
static void moonui_text_changed_trampoline(uiEntry *e, void *data) {
  (void)e;
  moonui_fire(data);
}

static void moonui_toggled_trampoline(uiCheckbox *c, void *data) {
  (void)c;
  moonui_fire(data);
}

static void moonui_resize_trampoline(uiWindow *w, void *data) {
  (void)w;
  moonui_fire(data);
}

/* 返回 0 = 否决 libui 自己销毁窗口。darwin 侧的否决比 Windows 更彻底：
 * windowShouldClose: 无论如何都返回 NO（见 darwin/window.m:59），只有回调返回 1
 * 时 libui 才自己 uiControlDestroy。销毁顺序由 Core 决定（先内容树后窗口），
 * 所以这里固定返回 0。 */
static int moonui_closing_trampoline(uiWindow *w, void *data) {
  (void)w;
  moonui_fire(data);
  return 0;
}

/* ---- 生命周期 ---- */

int moonui_init(void) {
  uiInitOptions options;
  const char *err;
  size_t n;
  TRACE("init");
  if (moonui_inited) {
    return 0;
  }
  moonui_error[0] = '\0';
  memset(&options, 0, sizeof(options));
  /* 这层池当场不能排（见 moonui_init_pool 的说明）：uiInit 会往里再压一层
   * globalPool，当场排干本层就是把非栈顶的弹出去，runtime 直接 abort。 */
  moonui_init_pool = [[NSAutoreleasePool alloc] init];
  err = uiInit(&options);
  if (err == 0) {
    moonui_inited = 1;
    return 0;
  }
  /* libui 用返回值当错误串。darwin 的 uiFreeInitError 是空函数（main.m:157），
   * 但照样调它，别把"要不要 free"变成平台特例。 */
  n = strlen(err);
  if (n > sizeof(moonui_error) - 1u) {
    n = sizeof(moonui_error) - 1u;
  }
  memcpy(moonui_error, err, n);
  moonui_error[n] = '\0';
  uiFreeInitError(err);
  /* 失败时 libui 还没压它的 globalPool，本层池可以当场排干。 */
  [moonui_init_pool drain];
  moonui_init_pool = nil;
  return 1;
}

moonbit_bytes_t moonui_last_error(void) {
  TRACE("last_error");
  return moonui_bytes_of(moonui_error);
}

void moonui_terminate(void) {
  int i;
  TRACE("terminate");
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    moonui_release_slot(&moonui_slots[i]);
  }
  if (!moonui_inited) {
    return;
  }
  moonui_inited = 0;
  /* uiUninit 末尾跑 uiprivUninitAlloc：还漏着一块就当 bug 处理。所以走到这里之前
   * MoonBit 侧必须把所有控件和窗口销毁干净（句柄表归零），和 Windows 同一条要求。
   * 顺序是硬性的：uiUninit 先排掉它的 globalPool，本层池才成为栈顶，再排本层。 */
  uiUninit();
  [moonui_init_pool drain];
  moonui_init_pool = nil;
}

/* ---- 窗口 ---- */

moonui_ptr moonui_window_new(const char *title,
                             int title_len,
                             int width,
                             int height) {
  char *t;
  uiWindow *win;
  CGFloat scale;
  TRACE("window_new");
  t = moonui_dup(title, title_len);
  if (t == 0) {
    return 0;
  }
  scale = moonui_system_scale();
  @autoreleasepool {
    /* 宽高是客户区的点，这里进来的还是物理像素，所以先除一次倍数。窗口还没建出来，
     * 只能用主屏倍数；Core 在建完后会按窗口自己的倍数再纠正一次尺寸
     * （backend.mbt 的 create_window），和 Windows 多监视器的处理同一套。
     * 最后一个参数是有菜单位：MoonUI 的菜单栏还没接（§48-18~20），所以先无菜单。 */
    win = uiNewWindow(t, moonui_px_to_whole_pt(width, scale),
                      moonui_px_to_whole_pt(height, scale), 0);
  }
  free(t);
  return (moonui_ptr)(uintptr_t)win;
}

void moonui_window_show(moonui_ptr w) {
  TRACE("window_show");
  /* darwin 的 uiWindowShow 就是 makeKeyAndOrderFront（window.m:171）。 */
  @autoreleasepool { uiControlShow((uiControl *)(uintptr_t)w); }
}

void moonui_window_hide(moonui_ptr w) {
  TRACE("window_hide");
  @autoreleasepool { uiControlHide((uiControl *)(uintptr_t)w); }
}

void moonui_window_destroy(moonui_ptr w) {
  TRACE("window_destroy");
  /* 先松开替这个窗口看守的 closing/resized 引用。控件必须已经全部销毁
   * （Core 的顺序保证），否则窗口拆掉后 view 还留在 contentView 的 subviews 里，
   * 而它的 libui 对象已经没了。 */
  moonui_forget((void *)(uintptr_t)w, 0);
  @autoreleasepool { uiControlDestroy((uiControl *)(uintptr_t)w); }
}

void moonui_window_set_title(moonui_ptr w, const char *title, int title_len) {
  char *t;
  TRACE("window_set_title");
  t = moonui_dup(title, title_len);
  if (t == 0) {
    return;
  }
  /* 这里用 libui 的而不是 [ns setTitle:]：它的入口本来就收 UTF-8，
   * 少一次自己转码，也少一处和 libui 内部行为分叉的地方。 */
  @autoreleasepool { uiWindowSetTitle((uiWindow *)(uintptr_t)w, t); }
  free(t);
}

void moonui_window_set_content_size(moonui_ptr w, int width, int height) {
  CGFloat scale;
  TRACE("window_set_content_size");
  scale = moonui_window_scale(w);
  /* 必须走 libui 而不是直接 setContentSize:：uiWindowSetContentSize 里那句
   * suppressSizeChanged = YES 正是"程序化改尺寸不回声成 Resize 事件"的实现
   * （adapter.h 的 on_resized 契约），绕过它就会自己收到自己的事件。 */
  @autoreleasepool {
    uiWindowSetContentSize((uiWindow *)(uintptr_t)w,
                           moonui_px_to_whole_pt(width, scale),
                           moonui_px_to_whole_pt(height, scale));
  }
}

int64_t moonui_window_content_size(moonui_ptr w) {
  int width = 0;
  int height = 0;
  CGFloat scale;
  TRACE("window_content_size");
  @autoreleasepool {
    uiWindowContentSize((uiWindow *)(uintptr_t)w, &width, &height);
  }
  scale = moonui_window_scale(w);
  return moonui_pack2(moonui_pt_to_px((CGFloat)width, scale),
                      moonui_pt_to_px((CGFloat)height, scale));
}

void moonui_window_set_position(moonui_ptr w, int x, int y) {
  CGFloat scale;
  TRACE("window_set_position");
  scale = moonui_window_scale(w);
  /* uiWindowPosition 收的是"外层左上角、屏幕坐标、y 向下"，darwin 内部用
   * visibleFrame 高度翻回 Cocoa 的 y 向上（window.m:269）——和 Win32 的语义同向，
   * 所以这里只换算单位，不再翻坐标。 */
  @autoreleasepool {
    uiWindowSetPosition((uiWindow *)(uintptr_t)w,
                        moonui_px_to_whole_pt(x, scale),
                        moonui_px_to_whole_pt(y, scale));
  }
}

int64_t moonui_window_position(moonui_ptr w) {
  int x = 0;
  int y = 0;
  CGFloat scale;
  TRACE("window_position");
  @autoreleasepool { uiWindowPosition((uiWindow *)(uintptr_t)w, &x, &y); }
  scale = moonui_window_scale(w);
  return moonui_pack2(moonui_pt_to_px((CGFloat)x, scale),
                      moonui_pt_to_px((CGFloat)y, scale));
}

void moonui_window_set_resizable(moonui_ptr w, int resizable) {
  TRACE("window_set_resizable");
  @autoreleasepool {
    uiWindowSetResizeable((uiWindow *)(uintptr_t)w, resizable);
  }
}

void moonui_window_set_fullscreen(moonui_ptr w, int fullscreen) {
  TRACE("window_set_fullscreen");
  /* darwin 的实现是 toggleFullScreen:，异步且带动画——和 Windows 的"立刻改样式"
   * 不一样，事件流里要等几步才看到结果。 */
  @autoreleasepool {
    uiWindowSetFullscreen((uiWindow *)(uintptr_t)w, fullscreen);
  }
}

int moonui_window_dpi(moonui_ptr w) {
  TRACE("window_dpi");
  return moonui_dpi_of_scale(moonui_window_scale(w));
}

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
    /* mainScreen 是"当前放着主窗口的屏"，和 Win32 的 SPI_GETWORKAREA（主屏去掉
     * 任务栏）在单屏机器上是同一个东西；多屏这里先不管（TODO 里也还没挂账需求）。
     * visibleFrame 去掉菜单栏和 Dock，正是"工作区"。 */
    screen = [NSScreen mainScreen];
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

int moonui_window_on_closing(moonui_ptr w,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("window_on_closing");
  slot = moonui_take_slot((void *)(uintptr_t)w, fn, closure);
  if (slot < 0) {
    return -1;
  }
  @autoreleasepool {
    uiWindowOnClosing((uiWindow *)(uintptr_t)w, moonui_closing_trampoline,
                      &moonui_slots[slot]);
  }
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
  /* darwin 的 windowDidResize: 在 suppressSizeChanged 时才不发（window.m:68），
   * 和 adapter.h 的"程序化改尺寸不回声"对得上。 */
  @autoreleasepool {
    uiWindowOnContentSizeChanged((uiWindow *)(uintptr_t)w,
                                 moonui_resize_trampoline, &moonui_slots[slot]);
  }
  return 0;
}

/* ---- 控件 ---- */

moonui_ptr moonui_widget_new(int kind, const char *text, int text_len) {
  char *t;
  uiControl *c = 0;
  TRACE("widget_new");
  t = moonui_dup(text, text_len);
  if (t == 0) {
    return 0;
  }
  @autoreleasepool {
    switch (kind) {
      case 0:
        c = uiControl(uiNewLabel(t));
        break;
      case 1:
        c = uiControl(uiNewButton(t));
        break;
      case 2: {
        /* uiNewEntry 不收文案（libui 的输入框默认空），所以建完再填。 */
        uiEntry *e = uiNewEntry();
        if (e != 0) {
          uiEntrySetText(e, t);
        }
        c = uiControl(e);
        break;
      }
      case 3:
        c = uiControl(uiNewCheckbox(t));
        break;
      default:
        c = 0;
        break;
    }
  }
  free(t);
  return (moonui_ptr)(uintptr_t)c;
}

void moonui_widget_destroy(moonui_ptr c) {
  TRACE("widget_destroy");
  @autoreleasepool {
    NSView *v = moonui_view(c);
    /* addSubview 是一次 retain，uiControlDestroy 只松开 libui 自己那一份，所以
     * 不先摘下来就会留下一只没人管的 view：窗口还显示着它，而它的 libui 对象已经
     * 没了（下一次 uiUninit 的分配审计也把这事当成 bug）。 */
    if (v != nil) {
      [v removeFromSuperview];
    }
  }
  moonui_forget((void *)(uintptr_t)c, 0);
  @autoreleasepool { uiControlDestroy((uiControl *)(uintptr_t)c); }
}

/* 四种控件的文案在 Cocoa 里分居两个属性：NSTextField（label、entry）用
 * stringValue，NSButton（button、checkbox）用 title。Win32 那份可以全靠
 * WM_SETTEXT，因为窗口文本是同一格；这里按 view 的类分一次，等价于那个统一入口。
 * 不用 uiLabelSetText 那四个是因为手上只有 uintptr_t，先要还回 uiLabel*，
 * 而那四个 setter 做的也就是这两条 AppKit 调用。 */
void moonui_widget_set_text(moonui_ptr c, const char *text, int text_len) {
  NSString *s;
  NSView *v;
  TRACE("widget_set_text");
  @autoreleasepool {
    s = moonui_string_of(text, text_len);
    if (s == nil) {
      return;
    }
    v = moonui_view(c);
    if ([v isKindOfClass:[NSTextField class]]) {
      [(NSTextField *)v setStringValue:s];
    } else if ([v isKindOfClass:[NSButton class]]) {
      [(NSButton *)v setTitle:s];
    }
  }
}

moonbit_bytes_t moonui_widget_text(moonui_ptr c) {
  moonbit_bytes_t out;
  TRACE("widget_text");
  @autoreleasepool {
    NSView *v = moonui_view(c);
    NSString *s = nil;
    if ([v isKindOfClass:[NSTextField class]]) {
      s = [(NSTextField *)v stringValue];
    } else if ([v isKindOfClass:[NSButton class]]) {
      s = [(NSButton *)v title];
    }
    out = moonui_bytes_of_ns(s);
  }
  return out;
}

/* 勾选态。只有 Checkbox 有意义，Core 侧已经按 kind 拦住别的控件。
 * setState: 不会触发 action，所以程序化勾选不会被回声成一条 Toggle 事件。 */
void moonui_widget_set_checked(moonui_ptr c, int checked) {
  TRACE("widget_set_checked");
  @autoreleasepool {
    [(NSButton *)moonui_view(c) setState:(checked ? NSControlStateValueOn
                                                  : NSControlStateValueOff)];
  }
}

int moonui_widget_checked(moonui_ptr c) {
  NSControlStateValue state;
  TRACE("widget_checked");
  @autoreleasepool { state = [(NSButton *)moonui_view(c) state]; }
  return state == NSControlStateValueOn ? 1 : 0;
}

void moonui_widget_set_visible(moonui_ptr c, int visible) {
  TRACE("widget_set_visible");
  /* 不走 uiControlShow/Hide：libui 那两个入口是按"控件在自己的容器树里"设计的，
   * 而 §14 的控件是 MoonUI 自己挂的，libui 的 visible 记账在这里是多余的第二套
   * 状态（见 ui_darwin.h 的 visible 字段）。直接说 setHidden:。 */
  @autoreleasepool { [(NSView *)moonui_view(c) setHidden:(visible ? NO : YES)]; }
}

/* "看得见"= 没被自己藏起来，而且在一只已经上屏的窗口里。后半条是必须的：detach
 * 之后 view 没有 window，窗口只 create 没 show 时它还没上屏，这时候报 visible 就是
 * 撒谎。Win32 的 IsWindowVisible 天然把父链算进去（子窗口跟着隐藏的父亲一起不算
 * 可见），[window isVisible] 是同一条事实的另一种问法，所以两边读数一致。 */
int moonui_widget_visible(moonui_ptr c) {
  int visible;
  TRACE("widget_visible");
  @autoreleasepool {
    NSView *v = moonui_view(c);
    NSWindow *win = [v window];
    visible = (v != nil && [win isVisible] && ![v isHidden]) ? 1 : 0;
  }
  return visible;
}

void moonui_widget_set_enabled(moonui_ptr c, int enabled) {
  TRACE("widget_set_enabled");
  /* 同样绕开 libui 的 Enable/Disable 记账：它会顺带算父链（SyncEnableState），
   * 而父链在这里就是 contentView，不是 libui 的容器树。
   * setEnabled: 是 NSControl 的，label 这类不是 NSControl 的 view 收到也不影响
   * 显示，Core 侧只对可交互控件调这条。 */
  @autoreleasepool {
    NSView *v = moonui_view(c);
    if ([v isKindOfClass:[NSControl class]]) {
      [(NSControl *)v setEnabled:(enabled ? YES : NO)];
    }
  }
}

int moonui_widget_enabled(moonui_ptr c) {
  int enabled;
  TRACE("widget_enabled");
  @autoreleasepool {
    NSView *v = moonui_view(c);
    enabled = 1;
    if ([v isKindOfClass:[NSControl class]]) {
      enabled = [(NSControl *)v isEnabled] ? 1 : 0;
    }
  }
  return enabled;
}

/* 固有尺寸（§18：量由原生层做）。ui_darwin.h 里没有 minimum size 的对应物——darwin 的
 * libui 把这件事整个交给了 Auto Layout，所以我们直接问 AppKit，并且**逐维取两个读数的
 * 较大者**：
 *   - [cell cellSize]：cell 自己要多大才画得下内容，AppKit 的 sizeToFit 用的就是它；
 *   - intrinsicContentSize：Auto Layout 的固有尺寸，对三种控件**偏小**（本机实测，点）：
 *     label 81.5 对 85.3、button 72x20 对 86x32、checkbox 63x16 对 65x18。按小的那个摆，
 *     AppKit 画的时候就把最后一个字挤掉——按钮的圆角边框左右各内缩 7pt，标题在 72pt 的
 *     frame 里只拿到 48pt，而 "Click Me" 要 52pt。这条偏小的读数就是"macOS 上文案显示
 *     不全"的根因，别改回去（测试钉的是"报出去的尺寸 ≥ cell 自己要的"，见
 *     moonui_cocoa_cell_size_of_widget）。
 *   - 反过来的那一头是 entry：intrinsic(96) > cellSize(66)。那 96 是 AppKit 给可编辑框
 *     设的宽度下限，不是截字，取大者正好把它留住。
 * NSView 没实现 intrinsicContentSize 时它给 -1，取大者时自然让位给 cellSize；两个读数
 * 都没有就把那一维记 0。结果是点，按控件所在窗口的倍数换成物理像素。 */
int64_t moonui_widget_minimum_size(moonui_ptr c) {
  NSSize size;
  CGFloat scale;
  TRACE("widget_minimum_size");
  @autoreleasepool {
    NSView *v = moonui_view(c);
    size = NSMakeSize((CGFloat)-1.0, (CGFloat)-1.0);
    if ([v respondsToSelector:@selector(intrinsicContentSize)]) {
      size = [(id)v intrinsicContentSize];
    }
    if ([v respondsToSelector:@selector(cell)]) {
      id cell = [(id)v cell];
      if (cell != nil && [cell respondsToSelector:@selector(cellSize)]) {
        NSSize cell_size = [(id)cell cellSize];
        if (cell_size.width > size.width) {
          size.width = cell_size.width;
        }
        if (cell_size.height > size.height) {
          size.height = cell_size.height;
        }
      }
    }
    if (size.width < (CGFloat)0) {
      size.width = (CGFloat)0;
    }
    if (size.height < (CGFloat)0) {
      size.height = (CGFloat)0;
    }
    scale = moonui_view_scale(v);
  }
  return moonui_pack2(moonui_pt_to_px(size.width, scale),
                      moonui_pt_to_px(size.height, scale));
}

int moonui_widget_dpi(moonui_ptr c) {
  TRACE("widget_dpi");
  return moonui_dpi_of_scale(moonui_view_scale(moonui_view(c)));
}

/* 相对父视图（也就是窗口客户区）左上角的物理像素坐标；父视图是 contentView，
 * 在 Cocoa 里"客户区"就是它，没有 Win32 那种屏幕坐标→客户区坐标的第二步。 */
int64_t moonui_widget_origin(moonui_ptr c) {
  int64_t out;
  TRACE("widget_origin");
  @autoreleasepool {
    NSView *v = moonui_view(c);
    NSView *sup = [v superview];
    NSRect frame;
    CGFloat scale;
    if (sup == nil) {
      return moonui_pack2(0, 0);
    }
    frame = [v frame];
    scale = moonui_view_scale(v);
    out = moonui_pack2(
        moonui_pt_to_px(frame.origin.x, scale),
        moonui_pt_to_px(moonui_flip_y(sup, frame.origin.y, frame.size.height),
                        scale));
  }
  return out;
}

int64_t moonui_widget_size(moonui_ptr c) {
  int64_t out;
  TRACE("widget_size");
  @autoreleasepool {
    NSView *v = moonui_view(c);
    NSRect frame = [v frame];
    CGFloat scale = moonui_view_scale(v);
    out = moonui_pack2(moonui_pt_to_px(frame.size.width, scale),
                       moonui_pt_to_px(frame.size.height, scale));
  }
  return out;
}

int moonui_widget_on_clicked(moonui_ptr c,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("widget_on_clicked");
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  @autoreleasepool {
    uiButtonOnClicked((uiButton *)(uintptr_t)c, moonui_click_trampoline,
                      &moonui_slots[slot]);
  }
  return 0;
}

/* 输入框的文字变了（darwin 侧是 NSTextField 的 controlTextDidChange: → onChanged:，
 * 见 libui 的 darwin/entry.m:87-96）。槽位机制和上面那条一模一样，所以销毁路径不用
 * 再做什么：moonui_widget_destroy 里的 moonui_forget 是按 owner 松开全部槽位的。 */
int moonui_widget_on_text_changed(moonui_ptr c,
                                  moonui_closure_fn fn,
                                  void *closure) {
  int slot;
  TRACE("widget_on_text_changed");
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  @autoreleasepool {
    uiEntryOnChanged((uiEntry *)(uintptr_t)c, moonui_text_changed_trampoline,
                     &moonui_slots[slot]);
  }
  return 0;
}

/* 勾选框被点了一下（NSButton 的 action → onToggled:，libui 的 darwin/checkbox.m:37）。
 * 报的是"出事了"而不是新状态，勾选态由 MoonBit 读 moonui_widget_checked。 */
int moonui_widget_on_toggled(moonui_ptr c,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("widget_on_toggled");
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  @autoreleasepool {
    uiCheckboxOnToggled((uiCheckbox *)(uintptr_t)c, moonui_toggled_trampoline,
                        &moonui_slots[slot]);
  }
  return 0;
}

/* ---- 控件摆放（§14）----
 * 布局算在 MoonUI 这一侧，libui 的容器布局完全不参与，和 Windows 那份同一个决定。
 *
 * 控件的 view 一出生没有 superview（darwin 的控件构造函数只 alloc/init，挂进窗口是
 * SetSuperview 的事，而我们从不调它），所以"挂进窗口"就是把 view addSubview 到目标
 * 窗口的 contentView。两条不变量支持这条捷径：
 *   - 回调走 target/action，落在控件自己身上，父级是谁不影响路由；
 *   - 摆位用 translatesAutoresizingMaskIntoConstraints = YES，明确告诉 AppKit
 *     "这个 view 的 frame 由我管，别给它生成约束"。libui 自己的容器布局走的是
 *     反方向（NO + Auto Layout），我们既然不建 uiBox，就必须站到 YES 这边，
 *     否则第一次 layout 就把 setFrame: 的结果覆盖掉。
 * 销毁顺序仍然是"先 child 后 window"，由 MoonBit 侧保证。 */
void moonui_control_attach(moonui_ptr window, moonui_ptr child) {
  TRACE("control_attach");
  @autoreleasepool {
    NSWindow *win = moonui_nswindow(window);
    NSView *content = [win contentView];
    NSView *v = moonui_view(child);
    if (content == nil || v == nil || [v superview] == content) {
      return;
    }
    /* 焦点链按 subviews 顺序重算，所以这个开关要在 addSubview 之前打开。 */
    [win setAutorecalculatesKeyViewLoop:YES];
    [v removeFromSuperview];
    [v setTranslatesAutoresizingMaskIntoConstraints:YES];
    /* 挂到层叠的**底部**。这不是随手选的：Win32 那份用的是 SetWindowPos(HWND_BOTTOM)，
     * 而 Cocoa 的默认 addSubview: 是往顶部加。两条都要对齐，否则同一个"先挂后挂"
     * 在两个后端上量出来相反的 z_index，Core 的层叠就没法跨平台推。
     * relativeTo:nil 配 NSWindowBelow 的意思是"比所有兄弟都靠下"。 */
    [content addSubview:v positioned:NSWindowBelow relativeTo:nil];
  }
}

void moonui_control_set_bounds(moonui_ptr child,
                               int x,
                               int y,
                               int width,
                               int height) {
  TRACE("control_set_bounds");
  @autoreleasepool {
    NSView *v = moonui_view(child);
    NSView *sup = [v superview];
    CGFloat scale = moonui_view_scale(v);
    CGFloat w = moonui_px_to_pt(width, scale);
    CGFloat h = moonui_px_to_pt(height, scale);
    /* 层叠原样保留：setFrame: 不动 subviews 数组，所以 resize 不会把 Tab 顺序
     * 跟着布局抖一遍——和 Windows 那份不敢带 SWP_TOPMOST 是同一条理由。 */
    [v setFrame:NSMakeRect(moonui_px_to_pt(x, scale),
                           moonui_flip_y(sup, moonui_px_to_pt(y, scale), h), w,
                           h)];
  }
}

void moonui_control_detach(moonui_ptr child) {
  TRACE("control_detach");
  /* Windows 需要一个自建隐藏窗口当临时住所（消息发给父窗口，不搬走就会继续冒泡）；
   * Cocoa 只要从 subviews 里摘掉：view 由 libui 持有，对象还活着，而它既看不见、
   * 也不在窗口的事件路径上（performClick: 这类显式调用除外）。 */
  @autoreleasepool { [(NSView *)moonui_view(child) removeFromSuperview]; }
}

/* Stack 的层叠（§14、§48-15）：Core 按数组顺序把 Stack 的叶子逐个提上来，
 * 提完之后的顺序就是"后提的在最上面"，也就是数组靠后的画在上层。Cocoa 的
 * subviews 数组顺序就是绘画顺序，所以"提到所有兄弟之上"就是"提到末尾"。
 * 只动层叠不动矩形，所以这条和 set_bounds 互不干扰。
 * 和 attach 一样，这里用带 positioned: 的形式而不是裸 addSubview:，为的是和
 * Windows 那份的 HWND_TOP 写成同一种话。 */
void moonui_control_raise(moonui_ptr child) {
  TRACE("control_raise");
  @autoreleasepool {
    NSView *v = moonui_view(child);
    NSView *sup = [v superview];
    if (sup == nil) {
      return;
    }
    /* 对已在树上的 view，addSubview 是"移动"，不是重复添加。 */
    [sup addSubview:v positioned:NSWindowAbove relativeTo:nil];
  }
}

/* subviews 数组末尾 = 最上层，而 adapter.h 定的是"0 = 最上层"，所以从末尾倒数。
 * 不在任何父视图里时返回 -1，和 Windows 那份一致。 */
int moonui_control_z_index(moonui_ptr child) {
  int index;
  TRACE("control_z_index");
  @autoreleasepool {
    NSView *v = moonui_view(child);
    NSView *sup = [v superview];
    NSArray *siblings;
    NSUInteger count;
    NSUInteger position;
    if (sup == nil) {
      return -1;
    }
    siblings = [sup subviews];
    count = [siblings count];
    /* NSView 的 isEqual 就是指针相等，所以这里按身份找。 */
    position = [siblings indexOfObjectIdenticalTo:v];
    if (position == NSNotFound) {
      return -1;
    }
    index = (int)(count - 1u - position);
  }
  return index;
}

/* ---- 事件循环 ---- */

void moonui_main_steps(void) {
  TRACE("main_steps");
  /* darwin 的 uiMainSteps 会 finishLaunching（把 App 变成真正在跑的 App）并把
   * "循环在不在跑"换成一个本地标志，所以之后每一步都是我们自己驱动的。
   * 这三条循环入口都不套池：finishLaunching/sendEvent:/terminate: 都可能留下
   * 活得比本次调用更久的对象（AppKit 的事件池归它自己的循环管），当场排干就是
   * 弹非栈顶的池。libui 的 uiprivMainStep 已经给自己的那次调用套了一层平衡的池
   * （darwin/main.m:207），落在外面的对象由它的 globalPool 兜着。 */
  uiMainSteps();
}

int moonui_main_step(int wait) {
  TRACE("main_step");
  return uiMainStep(wait);
}

/* 只探测不取：dequeue:NO 之后那条消息还留在队列里，接着交给 uiMainStep 处理。
 * 为什么不拿 uiMainStep 的返回值当"队列空了"的判据：它处理了一条消息和队列本来就
 * 空着都返回 1（uiprivMainStep 只在 isRunning 为假时给 0，见 darwin/main.m:202）。 */
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

/* 等最多 ms 毫秒，看队列里有没有事件。返回 1 = 有，0 = 超时。
 * 和 Win32 的 MsgWaitForMultipleObjects 有一处实质差别：那边"新"是相对上次唤醒算的，
 * 队列里有积压时照样报超时；这里因为 dequeue:NO，积压的第一条就被当场看见，
 * 所以有活可干时永远不会报超时。这个方向的差只会让 Core 少走空路，
 * 于是保留"只当唤醒用"的用法不变，判断有没有活还是要问 messages_pending。 */
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

/* 单调时钟：mach_absolute_time 是 Mac 上的对应物（Win32 那份用 GetTickCount64）。
 * 时间基换算是常数比值，取一次存下来。 */
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
  /* darwin 的 uiQuit 里那句 [NSApp terminate:] 在 steps 模式下只把循环标成"跑完了"
   * 就结束了（实测：调用后进程照常活着，uiMainStep 从这里开始一直返回 0，之后
   * 再 init 一轮也还能跑），所以 MoonBit 侧的收尾照常用 native_terminate 走。
   * 不套池：terminate: 会走 AppKit 的终止流程，留下的对象不归本次调用管。 */
  uiQuit();
}

/* ---- 测试脚手架 ---- */

/* 标题 → 窗口。Win32 有 FindWindowW，Cocoa 没有全局按标题查的入口，
 * 所以在自己进程的窗口列表里找（[NSApp windows] 按离用户的远近排序，
 * 同名时拿到最靠前的那只，行为和 FindWindowW 一致）。
 * 前提是本进程先 uiInit 过——NSApp 在那之前还不是 libui 接管的那个单例。 */
static NSWindow *moonui_find_window(NSString *title) {
  if (title == nil) {
    return nil;
  }
  for (NSWindow *w in [NSApp windows]) {
    if ([[w title] isEqualToString:title]) {
      return w;
    }
  }
  return nil;
}

/* 按坐标命中，而不是"找窗口里第一个按钮"：这样点的确实是 MoonUI 摆过去的那个矩形，
 * 布局算错的话这里就找不到控件（返回 -3/-4），不需要产品侧再开一个 geometry getter。
 * hitTest 命不中子视图时返回父视图自己，所以"空白处"落到类名检查上、返回 -4；
 * 它也会跳过被 setHidden: 的视图，所以藏起来的控件点不到（和真鼠标一致）。
 * performClick: 让真 NSButton 自己发出 action，于是消息进的是 libui 注册的
 * onClicked:——和人手点下去完全同一条路径，不是把回调函数直接调一遍。 */
int moonui_click_button_in_window(const char *title,
                                  int title_len,
                                  int x,
                                  int y) {
  TRACE("click_button_in_window");
  @autoreleasepool {
    NSString *t = moonui_string_of(title, title_len);
    NSWindow *win;
    NSView *content;
    NSView *hit;
    NSPoint point;
    CGFloat scale;
    if (t == nil) {
      return -1;
    }
    win = moonui_find_window(t);
    if (win == nil) {
      return -2;
    }
    content = [win contentView];
    if (content == nil) {
      return -3;
    }
    scale = [win backingScaleFactor];
    if (scale <= (CGFloat)0) {
      scale = moonui_system_scale();
    }
    /* 客户区坐标（左上原点，物理像素）→ 父视图坐标（Cocoa 默认左下原点，点）。
     * 这里翻的是"点"这个坐标本身，不是矩形，所以 y 用的是翻完再不用减高度。 */
    point = NSMakePoint(moonui_px_to_pt(x, scale),
                        moonui_flip_y(content, moonui_px_to_pt(y, scale),
                                      (CGFloat)0.0));
    hit = [content hitTest:point];
    if (hit == nil) {
      return -3;
    }
    if (![hit isKindOfClass:[NSButton class]]) {
      return -4;
    }
    /* 到这里就够了：命中的是可点击的控件。checkbox 也是 NSButton，和 Win32 那份
     * 一样——那边靠窗口类名认，"Button" 同样把复选框算进去（AppKit 根本没公开
     * -[NSButtonCell buttonType] 的读取口，只有 setButtonType:，所以想细分得去问
     * 无障碍角色，为一个测试脚手架犯不着）。真正要挡住的是"命中的是 label 或
     * contentView 自己"，那条由上面的 isKindOfClass 管。 */
    [(NSButton *)hit performClick:(id)hit];
    return 0;
  }
}

/* 等价于"用户在客户区 (x, y) 处那个输入框里打出 text"。
 *
 * 契约见 adapter.h 同名声明那段（含"插入点显式放文末"和 -1..-5 阶梯）。这里只记
 * mac 自己那两个坑：
 *   - hitTest: 命中的常常是 field editor（NSTextView）而不是文本框自己，所以要往上
 *     退一层，但不许越过 content；
 *   - 真正被编辑的是那只共享 field editor，改动要交给它，不是交给文本框控件。 */
int moonui_type_text_in_window(const char *title,
                               int title_len,
                               int x,
                               int y,
                               const char *text,
                               int text_len) {
  TRACE("type_text_in_window");
  @autoreleasepool {
    NSString *t = moonui_string_of(title, title_len);
    NSString *s = moonui_string_of(text, text_len);
    NSWindow *win;
    NSView *content;
    NSView *hit;
    NSView *up;
    NSTextField *field;
    id editor;
    NSPoint point;
    CGFloat scale;
    if (t == nil || s == nil) {
      return -1;
    }
    win = moonui_find_window(t);
    if (win == nil) {
      return -2;
    }
    content = [win contentView];
    if (content == nil) {
      return -3;
    }
    scale = [win backingScaleFactor];
    if (scale <= (CGFloat)0) {
      scale = moonui_system_scale();
    }
    point = NSMakePoint(moonui_px_to_pt(x, scale),
                        moonui_flip_y(content, moonui_px_to_pt(y, scale),
                                      (CGFloat)0.0));
    hit = [content hitTest:point];
    if (hit == nil) {
      return -3;
    }
    /* 命中的往往不是文本框自己，而是它的**字段编辑器**：AppKit 把共享的 field
     * editor 装成"正在被编辑的那只控件"的子视图，而窗口一显示就把可编辑框选成了
     * 初始 first responder，编辑早就开始了。所以往上退到包住它的那只 NSTextField，
     * 但不许越过 content——标题栏里也有一只 NSTextField，它是 content 的兄弟不是
     * 祖先，越过界就会把"点在空白处"也算成命中。 */
    up = hit;
    while (up != nil && up != content && ![up isKindOfClass:[NSTextField class]]) {
      up = [up superview];
    }
    if (up == nil || up == content || ![up isKindOfClass:[NSTextField class]]) {
      return -4;
    }
    field = (NSTextField *)up;
    if (![field isEditable] || ![win makeFirstResponder:field]) {
      return -5;
    }
    /* makeFirstResponder: 之后真正的编辑者是那只共享的 field editor；问窗口要它，
     * 而不是自己造一只——真人打字改的就是这只对象的内容。 */
    editor = [win fieldEditor:NO forObject:field];
    if (editor == nil || ![editor respondsToSelector:@selector(insertText:)]) {
      return -5;
    }
    /* 插入点显式放到文末：窗口一显示时 AppKit 已经把整段选中，此时 insertText:
     * 是"替换选区"而不是"追加"。"光标在哪"本来就是测试自己定的前提，写成一条
     * 调用比让它跟着激活时序漂要好。 */
    [editor setSelectedRange:NSMakeRange([[editor string] length], 0)];
    [editor insertText:s];
    return 0;
  }
}

int moonui_request_window_close(const char *title, int title_len) {
  TRACE("request_window_close");
  @autoreleasepool {
    NSString *t = moonui_string_of(title, title_len);
    NSWindow *win;
    if (t == nil) {
      return -1;
    }
    win = moonui_find_window(t);
    if (win == nil) {
      return -2;
    }
    /* performClose: 等价于"用户点了标题栏的关闭按钮"：它同步走
     * windowShouldClose:，于是我们的 closing 回调在这次调用里就执行完了。
     * 和 Win32 那版的唯一差别是时机——那边 PostMessage 之后要等事件循环走到；
     * 返回值仍是 0（"已投递"），Core 的读法（回调之后再看队列）两边都成立。
     * 我们的回调返回 0，所以 libui 不会自己拆窗口，销毁顺序还在 Core 手里。 */
    [win performClose:(id)win];
    return 0;
  }
}

/* 按"窗口标题 + 控件文案"在本进程的窗口里找那只控件的 view，找不到给 nil。
 * 文案的读法和 moonui_widget_text 一致：NSTextField 用 stringValue，NSButton 用 title。
 * 两条测试脚手架共用它（原始 frame 读数、cell 自己要求的尺寸），参数同样是标题加文案
 * 而不是句柄，理由见下面 moonui_cocoa_origin_of_widget 那段。 */
static NSView *moonui_find_widget(NSString *title, NSString *want) {
  NSWindow *win;
  NSView *content;
  if (title == nil || want == nil) {
    return nil;
  }
  win = moonui_find_window(title);
  if (win == nil) {
    return nil;
  }
  content = [win contentView];
  for (NSView *v in [content subviews]) {
    NSString *have = nil;
    if ([v isKindOfClass:[NSTextField class]]) {
      have = [(NSTextField *)v stringValue];
    } else if ([v isKindOfClass:[NSButton class]]) {
      have = [(NSButton *)v title];
    }
    if ([have isEqualToString:want]) {
      return v;
    }
  }
  return nil;
}

/* 只给测试用：按"窗口标题 + 控件文案"找到那只控件，返回它在 Cocoa 里的**原始**
 * frame 原点 y（左下原点、从父视图底边往上量）和父视图高度，都是物理像素。
 *
 * 为什么非要有这一条：本文件对外的每一个坐标读数都经过 moonui_flip_y，而翻折写在
 * 哪一侧是量不出来的——摆位翻一次、读数再翻一次，方向写反的两次翻折在数学上仍然
 * 自逆。负控制实测过这件事：把 moonui_flip_y 改成恒等，那套测试一条都没红。要钉住
 * 方向，就得拿一个**不走那条路径**的坐标来对表，而 Cocoa 的原始 frame 正是 MoonUI
 * 语义的对照组：贴着客户区顶边的控件，它的原始 origin.y 必须接近"父视图高 - 控件高"。
 *
 * 参数是标题和文案而不是句柄：句柄表在 backends/libui-common 那一包里是私有的，而这个符号
 * 只该活在本文件里。按标题找窗口和上面两条脚手架是同一个做法，而绕开句柄也就省掉
 * 了把它申报进共享层——否则 Windows 那份 adapter 也被迫实现一个对它自己没有意义的
 * 入口（Win32 的客户区本来就是左上原点）。 */
int64_t moonui_cocoa_origin_of_widget(const char *title,
                                      int title_len,
                                      const char *text,
                                      int text_len) {
  TRACE("cocoa_origin_of_widget");
  @autoreleasepool {
    NSView *v = moonui_find_widget(moonui_string_of(title, title_len),
                                   moonui_string_of(text, text_len));
    NSWindow *win;
    NSView *content;
    CGFloat scale;
    if (v == nil) {
      return moonui_pack2(-4, -4);
    }
    win = [v window];
    content = [v superview];
    scale = [win backingScaleFactor];
    if (scale <= (CGFloat)0) {
      scale = moonui_system_scale();
    }
    return moonui_pack2(moonui_pt_to_px(NSMinY([v frame]), scale),
                        moonui_pt_to_px(NSHeight([content bounds]), scale));
  }
}

/* 只给测试用：同一只控件**自己要求**的尺寸（[cell cellSize]，物理像素），也就是
 * AppKit 的 sizeToFit 会摆出来的那一摆。
 *
 * 为什么要它：moonui_widget_minimum_size 报给 Core 的尺寸是"我们量出来的"，而"这个
 * 尺寸够不够画下这串文案"只有 AppKit 自己知道。拿 cellSize 当对照组，这条断言就不是
 * 自证的——把 moonui_widget_minimum_size 改回只取 intrinsicContentSize（它比 cellSize
 * 小，实测 label 81.5 对 85.3、button 72 对 86），这条测试立刻红。那正是当初的 bug：
 * 量出来的宽度偏小，Core 照着摆，最后一个字被 AppKit 挤掉。 */
int64_t moonui_cocoa_cell_size_of_widget(const char *title,
                                         int title_len,
                                         const char *text,
                                         int text_len) {
  TRACE("cocoa_cell_size_of_widget");
  @autoreleasepool {
    NSView *v = moonui_find_widget(moonui_string_of(title, title_len),
                                   moonui_string_of(text, text_len));
    CGFloat scale;
    id cell;
    NSSize size;
    if (v == nil || ![v respondsToSelector:@selector(cell)]) {
      return moonui_pack2(-4, -4);
    }
    cell = [(id)v cell];
    if (cell == nil || ![cell respondsToSelector:@selector(cellSize)]) {
      return moonui_pack2(-5, -5);
    }
    size = [(id)cell cellSize];
    scale = [v window] != nil ? [[v window] backingScaleFactor]
                              : moonui_system_scale();
    if (scale <= (CGFloat)0) {
      scale = moonui_system_scale();
    }
    return moonui_pack2(moonui_pt_to_px(size.width, scale),
                        moonui_pt_to_px(size.height, scale));
  }
}
