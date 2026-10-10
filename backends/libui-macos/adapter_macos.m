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

#include <ctype.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

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

/* 原生对象 → "它是我们的哪个对象"的反查。键盘事件的归属和焦点都靠它，形状见
 * adapter.h 的「键盘与焦点」那段：只在建对象时打一次，C 侧不另开活对象表。
 *
 * 记在原生对象自己身上（mac 用关联对象，Windows 用 SetPropW）而不是查表，为的是
 * 不需要配对清理——原生对象销毁时这一格跟着没，也就不可能"C 侧那张表漏了一格"。
 * OBJC_ASSOCIATION_ASSIGN 是必须的而不是省事：view/NSWindow 由 libui 持有，多一次
 * retain 只会让它活得比自己的 uiControl 更久；存进去的又是一个整数不是 id，所以
 * 连"释放时要不要发消息"都没有。 */
static const void *const moonui_owner_key = &moonui_owner_key;

static void moonui_mark_owner(id native_obj, moonui_ptr owner) {
  if (native_obj != nil) {
    objc_setAssociatedObject(native_obj, moonui_owner_key,
                             (id)(uintptr_t)owner, OBJC_ASSOCIATION_ASSIGN);
  }
}

static moonui_ptr moonui_owner_of(id native_obj) {
  if (native_obj == nil) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)objc_getAssociatedObject(native_obj,
                                                         moonui_owner_key);
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

/* 菜单栏的两条收尾动作，定义在下面「菜单栏」那一段里：terminate 必须在 uiUninit
 * 之前把主菜单上自己追加的那几项摘掉（那时 NSApp 还管着主菜单），所以在这里先声明。 */
static void moonui_menu_clear(void);
static void moonui_menu_drop_closure(void);

/* 键盘监听的收尾也是同一个道理，定义在下面「键盘与焦点」那一段：它得在 uiUninit
 * 之前摘，更得在槽位表排干之前摘——监听那块闭包手里拿的是槽位指针，先排槽就等于
 * 让一个还挂着的监听去碰空槽（下一颗键来的时候本次 terminate 早结束了）。 */
static void moonui_key_drop_monitor(void);

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
  /* 键盘监听第一个摘，就在槽位表被排干之前：那块闭包里拿的是槽位指针，先排槽就是
   * 让一个还挂着的监听去碰空槽（见上面 moonui_key_drop_monitor 那条声明）。 */
  moonui_key_drop_monitor();
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    moonui_release_slot(&moonui_slots[i]);
  }
  /* 菜单栏的回调不占那张槽位表（整个进程只有一棵菜单），所以单独松一次。
   * 摘项要在 uiUninit 之前：那时 [NSApp mainMenu] 还在，摘完 libui 的审计也
   * 不会把我们建的 NSMenu 当成它的泄漏（uiprivUninitMenus 只清自己那几个类的对象，
   * darwin/menu.m:362）。target 和那份空名单留着不松——它们是进程级的几个字节，
   * 而重新 init 之后还要用， releasing 反而要管"下次 install 再 alloc"。 */
  moonui_menu_drop_closure();
  if (!moonui_inited) {
    return;
  }
  moonui_menu_clear();
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
     * 最后一个参数是有菜单位：darwin 那份实现从来没读过它（`uiNewWindow` 里没有
     * `hasMenubar` 这一维，窗口上本来就没有菜单位可留），§25 的菜单栏是进程级的
     * `[NSApp mainMenu]`，装它和建窗口的先后顺序无关——两个平台在这参数上不一样，
     * Windows 那边它真有含义，见 adapter.c 的 moonui_window_new。 */
    win = uiNewWindow(t, moonui_px_to_whole_pt(width, scale),
                      moonui_px_to_whole_pt(height, scale), 0);
  }
  free(t);
  /* 反记一笔"这只 NSWindow 是我们的哪个对象"：按键归属、焦点回读都从这条起
   * （见上面 moonui_mark_owner）。打标记的是 Handle 里那只真的 NSWindow，不是
   * uiWindow 那个结构体指针——后者是 libui 的 C 结构，不是 objc 对象，
   * setAssociatedObject 认它就把进程打停了。win 为 0 时整段跳过。 */
  if (win != 0) {
    moonui_mark_owner(moonui_nswindow((moonui_ptr)(uintptr_t)win),
                      (moonui_ptr)(uintptr_t)win);
  }
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
     * 任务栏）在单屏机器上是同一个东西；多屏的账挂在 TODO 的 `T42`（这台机器就挂着
     * 两块屏，副屏那块 scale 是 1.0，拿主屏的读数换算必错）。
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

/* 这只窗口当下在哪块屏。没上屏（screen 为 nil，比如刚建好还没 show）退回主屏，
 * 与 adapter.h 那条兜底说明一致：报主屏的数比报 0 尺寸更像"还没定位"，而
 * LogicalRect::center 拿到 0 尺寸会把窗口堆到左上角，症状会被读成"居中错了"。 */
static NSRect moonui_window_screen_visible(moonui_ptr w) {
  NSWindow *win;
  NSScreen *screen;
  win = moonui_nswindow(w);
  screen = win != nil ? [win screen] : nil;
  if (screen == nil) {
    screen = [NSScreen mainScreen];
  }
  return screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
}

int64_t moonui_window_screen_origin(moonui_ptr w) {
  NSRect visible;
  CGFloat scale;
  TRACE("window_screen_origin");
  @autoreleasepool { visible = moonui_window_screen_visible(w); }
  /* 倍数一律取**这只窗口**的 backingScaleFactor，和 MoonBit 侧 window_work_area
   * 除的那个数同一个（scale_of_window）。用屏的倍数会在"窗口刚跨屏、AppKit 还没
   * 把窗口的倍数挪过去"时和摆位那条入口差一截，读回来的矩形就摆不回同一块屏。 */
  scale = moonui_window_scale(w);
  /* y 恒 0：libui 的 darwin 版把窗口 y 翻成"从窗口当下所在那块屏的可见区上边往下"
   * （darwin/window.m 的 uiWindowPosition 用的是 [[w->window screen] visibleFrame]
   * 的 height + origin.y），所以这个坐标空间的原点本来就是该屏可见区左上角。
   * x 不是 0：那只屏在主屏右边时 visibleFrame.origin.x 就是一个非零的 Cocoa x，
   * 而 uiWindowSetPosition 收的 x 也是同一个 Cocoa x，两边同空间才摆得回去。 */
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
    /* 深色那几支的名字里都含 "Dark"（DarkAqua、VibrantDark，以及高对比度的那两支），
     * 浅色的都不含（Aqua、VibrantLight），所以按子串判。
     * 为什么不用 bestMatchFromAppearanceNames:options:：这台 15.6 上 effectiveAppearance
     * 返回的是 NSCompositeAppearance，对它发那一发是 unrecognized selector，当场抛
     * NSInvalidArgumentException（实测），响应选择子查询直接给 0。
     * NSApp 还没建出来（没调过 moonui_init）时 name 是 nil，落回浅色。 */
    eff = [NSApp effectiveAppearance];
    name = [eff name];
    if (name != nil && [name rangeOfString:@"Dark"].location != NSNotFound) {
      dark = 1;
    }
  }
  return dark;
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
  /* 和窗口那一处同一条：把"这只 view 是我们的哪个控件"记在 view 自己身上，
   * 而不是记在 uiControl 那个结构体指针上（objc 不认后者）。kind 不认识时 c 是 0，
   * 整段跳过，返回值也照旧是 0。 */
  if (c != 0) {
    moonui_mark_owner(moonui_view((moonui_ptr)(uintptr_t)c),
                      (moonui_ptr)(uintptr_t)c);
  }
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

/* ---- 剪贴板 ----
 * libui 的 darwin 后端没有剪贴板，所以这里直接问 AppKit（契约见 adapter.h）。
 * 两只 pasteboard 的区别用不上：generalPasteboard 是"用户按 Cmd-C 那个"，
 * 也就是 §23 要的那只。不声明 owner——声明了就把内容绑在本进程上，本文件里的
 * 写入应当在调用方之后还留在系统里。 */

moonbit_bytes_t moonui_clipboard_text(void) {
  moonbit_bytes_t out;
  TRACE("clipboard_text");
  @autoreleasepool {
    /* 没有文本类型时 stringForType: 给 nil，moonui_bytes_of_ns 因此给空 bytes，
     * MoonBit 侧就是 None——和"剪贴板空着"同一个回答，与契约一致。 */
    NSString *s = [[NSPasteboard generalPasteboard]
        stringForType:NSPasteboardTypeString];
    out = moonui_bytes_of_ns(s);
  }
  return out;
}

int moonui_clipboard_set_text(const char *text, int text_len) {
  int rc = 0;
  TRACE("clipboard_set_text");
  @autoreleasepool {
    NSString *s = moonui_string_of(text, text_len);
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
 * 契约见 adapter.h 的对话框那段：为什么不走 libui 的 uiMsgBox（它把用户的选择吞
 * 在返回值缺失里）、为什么不带窗口句柄、-1/-2 两个失败码分别是什么。
 *
 * NSAlert 自己会跑一层 modal 循环（runModal），所以这一段和事件循环那段是**两层
 * 分开的循环**：对话框阻塞期间 MoonBit 一行都跑不到，poll_event 也不会推进主循环。
 * 这正是 §24 要的形状（confirm 当场给答案），也是为什么只能从 handler 里调用它。 */

/* 正在被 modal 循环展示的那只面板。只在那次 runModal 期间非空，所有权从 alloc 那行
 * 到 release 那行之间归本文件。定时器的块里不许捕获 ObjC 指针（本文件按 MRR 编，没有
 * -fobjc-arc，块捕获的指针不会被 retain），所以它读的是这个静态量而不是捕获。 */
static NSAlert *moonui_open_alert = nil;

/* "用户在 ms 毫秒之后按下第 index 个按钮"。装它的入口在下面测试脚手架那节
 * （moonui_auto_dismiss_dialog），认领它的就是这里：下一个对话框建好面板时取走并清零。 */
static int moonui_dismiss_after_ms = -1;
static int moonui_dismiss_index = -1;

static void moonui_arm_dismissor(void) {
  NSRunLoop *loop;
  NSTimer *timer;
  NSInteger index;
  NSInteger count;
  NSTimeInterval delay;
  if (moonui_dismiss_after_ms < 0 || moonui_open_alert == nil) {
    return;
  }
  count = (NSInteger)[[moonui_open_alert buttons] count];
  if (count <= (NSInteger)0) {
    return;
  }
  index = (NSInteger)moonui_dismiss_index;
  /* index 超出这只面板的按钮数时退到最后一只（"否"或"确定"），和 Windows 那份
   * moonui_start_dismissor 同一个兜底：写错的脚手架要红在断言上，不要挂住整轮
   * 测试——什么都按不下就是永不返回。 */
  if (index < (NSInteger)0 || index >= count) {
    index = count - (NSInteger)1;
  }
  delay = (NSTimeInterval)moonui_dismiss_after_ms / (NSTimeInterval)1000.0;
  timer = [NSTimer timerWithTimeInterval:delay
                                repeats:NO
                                    block:^(NSTimer *fired) {
                                      NSAlert *alert = moonui_open_alert;
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
  moonui_dismiss_after_ms = -1;
  moonui_dismiss_index = -1;
}

/* 两只面板共用的一段：文案进 messageText / informativeText（libui 的 darwin 那半也是
 * 这个分法），按需加按钮，modal 跑一场。
 * 返回 -1 = 文案不是合法 UTF-8；否则是 runModal 的返回值（一定 >= 0）。 */
static NSInteger moonui_show_alert(const char *title,
                                   int title_len,
                                   const char *text,
                                   int text_len,
                                   BOOL is_confirm) {
  @autoreleasepool {
    NSString *t = moonui_string_of(title, title_len);
    NSString *s = moonui_string_of(text, text_len);
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
    moonui_open_alert = alert;
    moonui_arm_dismissor();
    clicked = [alert runModal];
    moonui_open_alert = nil;
    [alert release];
    return clicked;
  }
}

int moonui_dialog_message(const char *title,
                          int title_len,
                          const char *text,
                          int text_len) {
  NSInteger clicked;
  TRACE("dialog_message");
  clicked = moonui_show_alert(title, title_len, text, text_len, NO);
  if (clicked < (NSInteger)0) {
    return (int)clicked;
  }
  /* 只有一只按钮，"按了确定"和"面板被关掉"对调用方是同一件事：§24 的 message 返回
   * Unit，这个区别没有地方放。 */
  return 0;
}

int moonui_dialog_confirm(const char *title,
                          int title_len,
                          const char *text,
                          int text_len) {
  NSInteger clicked;
  TRACE("dialog_confirm");
  clicked = moonui_show_alert(title, title_len, text, text_len, YES);
  if (clicked < (NSInteger)0) {
    return (int)clicked;
  }
  /* NSAlertFirstButtonReturn = 加按钮时排第一的那只，也就是"是"。其余一律算"没同意"
   * （含"否"和被关掉），对上 §24 的"取消返回 false"。 */
  return clicked == NSAlertFirstButtonReturn ? 1 : 0;
}

/* ---- 文件对话框（§24 / §48-18）----
 * 契约见 adapter.h 的文件对话框那段：为什么不走 libui 的 uiOpenFile / uiSaveFile
 * （取消和失败在那边是同一个 NULL）、返回码、路径为什么拆成 getter 取走。
 *
 * 和上一段（NSAlert）同一个形状：面板自己跑一层 modal 循环（runModal），阻塞期间
 * MoonBit 一行都跑不到。测试脚手架只能替用户按"取消"（原因在
 * moonui_auto_answer_file_dialog）；"接受"那条分支留着，走的是真实用户的产品路径。 */

/* 三种形态。open 和 folder 都建 NSOpenPanel（canChooseFiles / canChooseDirectories
 * 切形态），save 建 NSSavePanel。 */
#define MOONUI_FILE_OPEN 0
#define MOONUI_FILE_SAVE 1
#define MOONUI_FILE_FOLDER 2

/* 正在被 modal 循环展示的那只面板；只在那次 runModal 期间非空，所有权从
 * [NSOpenPanel openPanel] / [NSSavePanel savePanel] 到 runModal 返回之间归 AppKit
 * （两条都是 autoreleased，本文件不 release）。和 moonui_open_alert 同一个理由不放进
 * 块的捕获：本文件按 MRR 编，块捕获的 ObjC 指针不会被 retain。save 是 open 的父类，
 * 所以静态量按父类收。 */
static NSSavePanel *moonui_open_panel = nil;

/* 面板结果的落点：到 moonui_file_dialog_path 取走（或下一次面板打开）之前归本文件
 * 所有。取消 / 失败时是 NULL，getter 因此给空 bytes。 */
static char *moonui_file_result = 0;

/* "ms 毫秒之后替下一个文件面板按取消"。装它的入口在下面测试脚手架那节
 * （moonui_auto_answer_file_dialog），认领它的是 moonui_arm_file_answer：下一个文件
 * 面板打开时取用，runModal 返回后清场。macOS 15.6 上只有"取消"这一种答案可以替，
 * 所以没有 accept / path 两个静态量——原因和证据记在 moonui_auto_answer_file_dialog。 */
static int moonui_file_answer_after_ms = -1;

/* 每开一只面板加一。两只定时器（主答 + 兜底取消）都带着自己那一代的号，醒来先对号
 * ——不对号说明这个面板的 modal 早结束了，什么都不许做。不这么写的话，上一次面板
 * 留下的兜底定时器会在下一次面板的 modal 里醒来把它取消掉：上一轮脚手架按了这一轮
 * 的按钮，是最难查的那种红。 */
static int64_t moonui_file_panel_serial = 0;

static void moonui_file_clear_answer(void) {
  moonui_file_answer_after_ms = -1;
}

/* 把装好的那发"用户怎么答"挂进 runloop。面板建好之后、runModal 之前调用（位置同
 * moonui_arm_dismissor）。没装就是空操作。
 *
 * 两只定时器：
 *   - 主答（ms 之后）：cancel:——runModal 当场拿 0（取消）回来。macOS 15.6 上没有
 *     "替用户按 OK"的路，原因和证据记在 moonui_auto_answer_file_dialog 那段。
 *   - 兜底（ms + 500）：主答那步要是没能结束 modal，到点再取消一次，让调用当场拿
 *     "取消"回来。测试因此红在它自己的断言上，而不是整轮挂住。
 *
 * 两个块都读当时的静态量、不捕获面板指针；对号 + 面板非空两个守卫合起来保证"读的
 * 时候这根指针还活着"：runModal 一返回 moonui_open_panel 就清空。 */
static void moonui_arm_file_answer(void) {
  NSRunLoop *loop;
  NSTimer *timer;
  NSTimer *backup;
  NSTimeInterval delay;
  NSTimeInterval backup_delay;
  int64_t serial;
  if (moonui_file_answer_after_ms < 0 || moonui_open_panel == nil) {
    return;
  }
  serial = moonui_file_panel_serial;
  delay = (NSTimeInterval)moonui_file_answer_after_ms / (NSTimeInterval)1000.0;
  backup_delay = delay + (NSTimeInterval)0.5;
  timer = [NSTimer timerWithTimeInterval:delay
                                 repeats:NO
                                     block:^(NSTimer *fired) {
    @autoreleasepool {
      NSSavePanel *panel = moonui_open_panel;
      if (panel == nil || serial != moonui_file_panel_serial) {
        return;
      }
      [panel cancel:panel];
    }
  }];
  backup = [NSTimer timerWithTimeInterval:backup_delay
                                  repeats:NO
                                      block:^(NSTimer *fired) {
    if (serial == moonui_file_panel_serial && moonui_open_panel != nil) {
      [moonui_open_panel cancel:moonui_open_panel];
    }
  }];
  /* 和 moonui_arm_dismissor 同一行注释：runModal 的循环跑在 NSModalPanelRunLoopMode，
   * 只挂默认档的定时器在模态期间永远不会 fire。另外两档一起挂。 */
  loop = [NSRunLoop currentRunLoop];
  [loop addTimer:timer forMode:NSModalPanelRunLoopMode];
  [loop addTimer:timer forMode:NSEventTrackingRunLoopMode];
  [loop addTimer:timer forMode:NSDefaultRunLoopMode];
  [loop addTimer:backup forMode:NSModalPanelRunLoopMode];
  [loop addTimer:backup forMode:NSEventTrackingRunLoopMode];
  [loop addTimer:backup forMode:NSDefaultRunLoopMode];
}

/* 三种面板共用的一段：建面板、跑一场 modal、把结果存进 moonui_file_result。
 * 返回码见 adapter.h（1 = 选了，0 = 取消，-1 = 文案编码失败，-2 = 面板失败）。
 * 面板形状对齐 libui 的 darwin/stddialogs.m（那里也是 autoreleased 的面板 + 显式
 * 关掉 alias 解析和多重选择）。 */
static int moonui_run_file_panel(const char *title,
                                 int title_len,
                                 const char *default_name,
                                 int default_name_len,
                                 int mode) {
  @autoreleasepool {
    NSString *t = moonui_string_of(title, title_len);
    NSString *d = nil;
    NSSavePanel *panel;
    NSInteger clicked;
    if (t == nil) {
      return -1;
    }
    if (default_name != 0) {
      d = moonui_string_of(default_name, default_name_len);
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
    moonui_open_panel = panel;
    moonui_file_panel_serial += 1;
    /* 结果取走语义的另一半：每开一次面板，上一次的还没取走的就作废。 */
    free(moonui_file_result);
    moonui_file_result = 0;
    moonui_arm_file_answer();
    clicked = [panel runModal];
    moonui_open_panel = nil;
    /* 这一发"用户怎么答"已经兑现（或随面板一起作废），清场。 */
    moonui_file_clear_answer();
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
      moonui_file_result = moonui_dup(c, (int)strlen(c));
      if (moonui_file_result == 0) {
        return -2;
      }
    }
    return 1;
  }
}

int moonui_open_file(const char *title, int title_len) {
  TRACE("open_file");
  return moonui_run_file_panel(title, title_len, 0, 0, MOONUI_FILE_OPEN);
}

int moonui_save_file(const char *title,
                     int title_len,
                     const char *default_name,
                     int default_name_len) {
  TRACE("save_file");
  return moonui_run_file_panel(title, title_len, default_name, default_name_len,
                               MOONUI_FILE_SAVE);
}

int moonui_select_folder(const char *title, int title_len) {
  TRACE("select_folder");
  return moonui_run_file_panel(title, title_len, 0, 0, MOONUI_FILE_FOLDER);
}

/* 取走结果：返回值是当场拷进 MoonBit 堆的一份（GC 回收，那边不用 free），内部指针
 * 顺带清空。没结果时给空 bytes。 */
moonbit_bytes_t moonui_file_dialog_path(void) {
  moonbit_bytes_t out;
  TRACE("file_dialog_path");
  if (moonui_file_result == 0) {
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_bytes_of(moonui_file_result);
  free(moonui_file_result);
  moonui_file_result = 0;
  return out;
}

/* ---- 菜单栏（§25 / §48-20）----
 * 为什么是这里自己搭 NSMenu 而不是 libui 的菜单 API，理由全在 adapter.h（一句话版：
 * darwin 在建过窗口之后装菜单会当场终止进程，而它的 setChecked 连入参都不看）。
 * mac 这一侧的实现形状记在这里：
 *   - `uiInit` 一定已经把应用菜单装进 `[NSApp mainMenu]`（darwin/main.m:128），我们只往
 *     后追加。追加了哪几项记在 `moonui_menu_items` 里，清场、查 id、dump 都按这份名单走
 *     ——不数"索引 1 往后"，那种算术靠的是别人的顺序。
 *   - 可点项的 target 是全局一个对象，Core 的 id 挂在 `item.tag` 上随 action 回来，
 *     所以不需要另建一张 id → 记录的表。分隔线的 tag 也是 0，查 id 时必须连 action
 *     一起认，否则 0 号项会被分隔线冒充。
 *   - Check 和 Radio 在 mac 的原生外观里是同一个东西（都是显示一个勾，AppKit 的圆点
 *     只给同一 action 的分组，而互斥是 Core 算的），原生项里没有"我是 radio"这回事。
 *     dump 要分得开 c/r，所以装的时候把 role 存在 `representedObject` 上——那也是项
 *     自己的状态，读它和读 title 同级。
 *   - 拆旧的一律排在"新树整个建好"之后：建的途中出任何岔子就返回 -1，屏幕上还是上一棵
 *     （adapter.h 的"装了一半比装不上难查"）。
 */

/* 点击回调是进程全局的一份，不占 moonui_slots 那张表：整个进程只有一棵菜单栏，
 * 而那张表是按"一个控件一格"设计的，硬塞进去反而要替它记 owner。
 * closure 照样要 incref——libui/AppKit 只存函数指针，GC 看不见它。 */
static moonui_closure_id_fn moonui_menu_fn = 0;
static void *moonui_menu_closure = 0;
static NSMutableArray *moonui_menu_items = nil;

@interface MoonuiMenuTarget : NSObject
- (void)moonuiMenuItemClicked:(NSMenuItem *)item;
@end

@implementation MoonuiMenuTarget
- (void)moonuiMenuItemClicked:(NSMenuItem *)item {
  if (moonui_menu_fn != 0 && moonui_menu_closure != 0) {
    moonui_menu_fn(moonui_menu_closure, (int)[item tag]);
  }
}
@end

/* +1 一直持到 moonui_terminate，符合本文件"进程级对象手工管、其余交给池"的规矩。 */
static MoonuiMenuTarget *moonui_menu_target = nil;

/* ---- 打包树的读游标（布局见 adapter.h）---- */

typedef struct {
  const unsigned char *p;
  int len;
  int pos;
  int bad;
} MoonuiTree;

static int moonui_tree_u8(MoonuiTree *t) {
  if (t->bad || t->pos + 1 > t->len) {
    t->bad = 1;
    return 0;
  }
  return (int)t->p[t->pos++];
}

/* 小端 i32。读满四个字节才动 pos，越界的那一步整体作废（bad 一旦为真就不再翻案）。 */
static int moonui_tree_i32(MoonuiTree *t) {
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
static NSString *moonui_tree_str(MoonuiTree *t) {
  int n;
  NSString *s;
  if (t->bad) {
    return nil;
  }
  n = moonui_tree_i32(t);
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
 * 功能键和方向键都落在 0xF700 那一族字符里，菜单项收不下，按 adapter.h 的约定整个不显示，
 * 而不是显示一个按下去没反应的组合。词表用 Core 那一套（event.mbt 的 "Enter"/"a"），
 * 不在这里另立第二个名字空间。 */
static NSString *moonui_menu_key_equiv(const char *key) {
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
static unsigned int moonui_menu_mods_flag(int mods) {
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

static NSMenu *moonui_menu_new(NSString *title) {
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:title] autorelease];
  /* autoenablesItems=NO：默认那套"没有 target 就自己置灰"是 AppKit 的推理，而 §25 的
   * 置灰由 Core 说了算。关掉它，isEnabled 读回来的才是 MoonUI 写进去的那个值。 */
  [menu setAutoenablesItems:NO];
  return menu;
}

/* 读 kind 0 剩下的字段（kind 字节由调用方读过）。 */
static NSMenuItem *moonui_menu_read_item(MoonuiTree *t) {
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
  label = moonui_tree_str(t);
  item_id = moonui_tree_i32(t);
  role = moonui_tree_u8(t);
  checked = moonui_tree_u8(t);
  enabled = moonui_tree_u8(t);
  has_sc = moonui_tree_u8(t);
  mods = 0;
  equiv = nil;
  if (has_sc != 0) {
    mods = moonui_tree_u8(t);
    key = moonui_tree_str(t);
    if (!t->bad) {
      equiv = moonui_menu_key_equiv([key UTF8String]);
    }
  }
  if (t->bad || (role != 0 && role != 1 && role != 2)) {
    return nil;
  }
  item = [[[NSMenuItem alloc] initWithTitle:label
                                     action:NULL
                              keyEquivalent:@""] autorelease];
  [item setTag:(NSInteger)item_id];
  [item setTarget:moonui_menu_target];
  [item setAction:@selector(moonuiMenuItemClicked:)];
  [item setEnabled:(enabled != 0)];
  [item setState:(checked != 0) ? NSControlStateValueOn
                                : NSControlStateValueOff];
  /* role 存进 representedObject：Check 和 Radio 的原生外观相同，dump 要分得开只能靠这项
   * 自己带着。它确实是"项自己的状态"，不是另开的一张表。 */
  [item setRepresentedObject:[NSNumber numberWithInt:role]];
  if (equiv != nil) {
    [item setKeyEquivalent:equiv];
    [item setKeyEquivalentModifierMask:moonui_menu_mods_flag(mods)];
  }
  return item;
}

/* 往 menu 里填 count 个条目；Submenu 那一支自己递归。任何一步读坏就返回 0，
 * 调用方把整棵作废（不留"半棵树"）。 */
static int moonui_menu_fill(NSMenu *menu, MoonuiTree *t, int count) {
  int i;
  for (i = 0; i < count; ++i) {
    int kind = moonui_tree_u8(t);
    NSMenuItem *item = nil;
    if (t->bad) {
      return 0;
    }
    if (kind == 0) {
      item = moonui_menu_read_item(t);
      if (item == nil) {
        return 0;
      }
    } else if (kind == 1) {
      item = [NSMenuItem separatorItem];
    } else if (kind == 2) {
      NSString *sub = moonui_tree_str(t);
      int sub_count = moonui_tree_i32(t);
      NSMenu *sub_menu;
      if (t->bad || sub_count < 0) {
        return 0;
      }
      sub_menu = moonui_menu_new(sub);
      if (!moonui_menu_fill(sub_menu, t, sub_count)) {
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
 * 忽略（实测：'Item to be removed is not in the menu in the first place'），所以这里先问
 * 主菜单有没有这一项。名单和主菜单对不上只可能是我们自己记错了，而记错的代价不该是
 * 宿主进程当场点死——摘不掉的那一项会在快照里少一顶、让测试红在断言上。 */
static void moonui_menu_clear(void) {
  NSMenu *main_menu;
  if (moonui_menu_items == nil) {
    return;
  }
  main_menu = [NSApp mainMenu];
  if (main_menu != nil) {
    for (NSMenuItem *item in moonui_menu_items) {
      if ([main_menu indexOfItem:item] >= 0) {
        [main_menu removeItem:item];
      }
    }
  }
  [moonui_menu_items removeAllObjects];
}

int moonui_set_menu_bar(const char *tree,
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
  if (!moonui_inited) {
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
    version = moonui_tree_u8(&t);
    count = moonui_tree_i32(&t);
    if (t.bad || version != 1 || count < 0) {
      return -1;
    }
    if (moonui_menu_target == nil) {
      moonui_menu_target = [[MoonuiMenuTarget alloc] init];
    }
    if (moonui_menu_items == nil) {
      moonui_menu_items = [[NSMutableArray alloc] init];
    }
    built = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (i = 0; i < count; ++i) {
      NSString *label = moonui_tree_str(&t);
      int node_count = moonui_tree_i32(&t);
      NSMenu *menu;
      NSMenuItem *top;
      if (t.bad || node_count < 0) {
        return -1;
      }
      menu = moonui_menu_new(label);
      if (!moonui_menu_fill(menu, &t, node_count)) {
        return -1;
      }
      top = [[[NSMenuItem alloc] initWithTitle:label
                                        action:NULL
                                 keyEquivalent:@""] autorelease];
      [top setSubmenu:menu];
      [built addObject:top];
    }
    /* 整棵新树已经建好了，从这里开始才真的动屏幕上那棵。 */
    moonui_menu_clear();
    for (NSMenuItem *top in built) {
      [main_menu addItem:top];
      [moonui_menu_items addObject:top];
    }
    moonui_menu_drop_closure();
    moonui_menu_fn = fn;
    if (closure != 0) {
      moonbit_incref(closure);
      moonui_menu_closure = closure;
    }
  }
  return 0;
}

/* 松开菜单栏持有的那份 MoonBit 闭包。整个进程只有一棵菜单，所以这一格不在
 * moonui_slots 那张表里，terminate 和"换一次回调"都走这里。 */
static void moonui_menu_drop_closure(void) {
  if (moonui_menu_closure != 0) {
    moonbit_decref(moonui_menu_closure);
    moonui_menu_closure = 0;
  }
  moonui_menu_fn = 0;
}

/* 只有"带我们那个 action 的项"算可点项，所以分隔线（tag 默认 0）和子菜单标题
 * （action 为 NULL）都冒充不了 0 号项。 */
static NSMenuItem *moonui_menu_find_in(NSMenu *menu, int id) {
  for (NSMenuItem *item in [menu itemArray]) {
    NSMenuItem *hit;
    NSMenu *sub = [item submenu];
    if ([item action] == @selector(moonuiMenuItemClicked:) &&
        (int)[item tag] == id) {
      return item;
    }
    if (sub != nil) {
      hit = moonui_menu_find_in(sub, id);
      if (hit != nil) {
        return hit;
      }
    }
  }
  return nil;
}

static NSMenuItem *moonui_menu_find_id(int id) {
  if (moonui_menu_items == nil) {
    return nil;
  }
  for (NSMenuItem *top in moonui_menu_items) {
    NSMenuItem *hit = moonui_menu_find_in([top submenu], id);
    if (hit != nil) {
      return hit;
    }
  }
  return nil;
}

int moonui_menu_item_set_checked(int id, int checked) {
  TRACE("menu_item_set_checked");
  @autoreleasepool {
    NSMenuItem *item = moonui_menu_find_id(id);
    if (item == nil) {
      return -1;
    }
    [item setState:(checked != 0) ? NSControlStateValueOn
                                  : NSControlStateValueOff];
  }
  return 0;
}

/* ---- 键盘与焦点（§10 的 KeyDown/KeyUp、§26 的快捷键、§32 的 focused）----
 *
 * 形状和契约（进程一份监听、通知不带内容、归属靠反查标记、键名词表、菜单认领规则）
 * 都写在 ../libui-common/adapter.h 的「键盘与焦点」那一节，这里只记 mac 这一份怎么落地：
 *   - 监听用 addLocalMonitorForEventsMatchingMask:（local 而不是 global）：只在本进程
 *     是前台 App 时收键，那正是 §10"用户在这个 App 里按键"的意思，也不需要全局监听
 *     要申请的辅助功能授权。
 *   - 归属两问就够，不需要"当前焦点控件"这种全局缓存：事件自己带窗口
 *     （NSEvent.window），窗口自己带 firstResponder。
 *   - 特殊键的键名读 keyCode 而不是读那串 0xF700 的私有码元：码元要另抄一份 AppKit
 *     的常量表，而 keyCode 是物理键位、Carbon 定死的（见下面那张表的说明）。
 *   - 自动重复不滤：AppKit 把重复也做成一颗颗真的 KeyDown，Windows 那边的
 *     WM_KEYDOWN 本来就这么来，两侧一致。
 */

/* 键名词表在 mac 这边的两张落地表。
 *
 * keyCode 那一列是 Carbon 的 kVK_*（HIToolbox/Events.h）：为几条常量把整个 Carbon 链进
 * 来不值，libui 自己在 darwin/areaevents.m:5 做了同一个决定、抄了同一张数（可以拿它对
 * 表），而 AppKit 也保证 -[NSEvent keyCode] 用的就是这套码（同那段说明）。
 * scalar 那一列是 AppKit 给这些键预留的私有码元（NSEvent.h:556 起那一族，回车/Tab/Esc/
 * 退格用控制字符），只有合成脚手架用得到——它靠这一列造出一条形状和真键盘一样的事件。 */
typedef struct {
  const char *name;
  unsigned short code;
  unichar scalar;
} MoonuiSpecialKey;

static const MoonuiSpecialKey moonui_special_keys[] = {
    {"Enter", 0x24, '\r'},                   /* kVK_Return */
    {"Tab", 0x30, '\t'},                     /* kVK_Tab */
    {"Escape", 0x35, 0x1B},                  /* kVK_Escape */
    {"Backspace", 0x33, 0x7F},               /* kVK_Delete：Mac 的 delete 键就是退格 */
    {"Delete", 0x75, NSDeleteFunctionKey},   /* kVK_ForwardDelete */
    {"Home", 0x73, NSHomeFunctionKey},
    {"End", 0x77, NSEndFunctionKey},
    {"PageUp", 0x74, NSPageUpFunctionKey},
    {"PageDown", 0x79, NSPageDownFunctionKey},
    {"Left", 0x7B, NSLeftArrowFunctionKey},
    {"Right", 0x7C, NSRightArrowFunctionKey},
    {"Down", 0x7D, NSDownArrowFunctionKey},
    {"Up", 0x7E, NSUpArrowFunctionKey},
    {"F1", 0x7A, NSF1FunctionKey},
    {"F2", 0x78, NSF2FunctionKey},
    {"F3", 0x63, NSF3FunctionKey},
    {"F4", 0x76, NSF4FunctionKey},
    {"F5", 0x60, NSF5FunctionKey},
    {"F6", 0x61, NSF6FunctionKey},
    {"F7", 0x62, NSF7FunctionKey},
    {"F8", 0x64, NSF8FunctionKey},
    {"F9", 0x65, NSF9FunctionKey},
    {"F10", 0x6D, NSF10FunctionKey},
    {"F11", 0x67, NSF11FunctionKey},
    {"F12", 0x6F, NSF12FunctionKey},
};

/* 字母、数字、空格在 US 布局里的物理键位，只给合成脚手架用。键名不查这张表——那条走
 * 的是事件自己给的字符（见 moonui_key_read_name），所以换键盘布局时名字跟着字符走，
 * 和 Core 里 Shortcut("s") 的实际含义一致。 */
static const struct {
  char ch;
  unsigned short code;
} moonui_printable_keys[] = {
    {'a', 0x00}, {'b', 0x0B}, {'c', 0x08}, {'d', 0x02}, {'e', 0x0E},
    {'f', 0x03}, {'g', 0x05}, {'h', 0x04}, {'i', 0x22}, {'j', 0x26},
    {'k', 0x28}, {'l', 0x25}, {'m', 0x2E}, {'n', 0x2D}, {'o', 0x1F},
    {'p', 0x23}, {'q', 0x0C}, {'r', 0x0F}, {'s', 0x01}, {'t', 0x11},
    {'u', 0x20}, {'v', 0x09}, {'w', 0x0D}, {'x', 0x07}, {'y', 0x10},
    {'z', 0x06}, {'0', 0x1D}, {'1', 0x12}, {'2', 0x13}, {'3', 0x14},
    {'4', 0x15}, {'5', 0x17}, {'6', 0x16}, {'7', 0x1A}, {'8', 0x1C},
    {'9', 0x19}, {' ', 0x31},                /* kVK_Space */
};

#define MOONUI_N(a) (sizeof(a) / sizeof((a)[0]))

/* 那一份监听。addLocalMonitorForEventsMatchingMask: 给的 token 必须留着才能
 * removeMonitor:，所以按 Create 规则存静态变量（本文件是 MRC：alloc 出来的东西
 * 自己管，token 是 autoreleased 的，这里 retain 一份）。 */
static id moonui_key_monitor = nil;

/* 槽位表按 owner 清闭包，而这份监听不属于任何窗口或控件，所以 owner 用一个自己的
 * 地址当哨兵：全进程唯一，永远不会和某个 uiControl* 撞上。 */
static char moonui_key_slot_owner;
static int moonui_key_slot = -1;

/* 一颗键的快照：通知只说"有颗键出事了"，内容全部由 MoonBit 当场读回去（§48-16）。
 * 写它的时机在调闭包之前，闭包返回之后没人再动，所以一次通知配一次读、中间插不进
 * 第二颗键。target 为 0 表示这颗键不属于我们任何窗口/控件。 */
static moonui_ptr moonui_key_target_ptr = 0;
static int moonui_key_down = 0;
static int moonui_key_mods = 0;
static char moonui_key_snapshot_name[32];

/* NSEventModifierFlags → 那四位（bit0 ctrl、bit1 alt、bit2 shift、bit3 meta）。
 * meta 就是 Command：§25 里"显示与派发同源"的规矩同样管这里，Core 的 Shortcut 在
 * mac 上 meta 指的必须是 ⌘。 */
static int moonui_mods_of(NSUInteger flags) {
  int mods = 0;
  if (flags & NSEventModifierFlagControl) {
    mods |= 1;
  }
  if (flags & NSEventModifierFlagOption) {
    mods |= 2;
  }
  if (flags & NSEventModifierFlagShift) {
    mods |= 4;
  }
  if (flags & NSEventModifierFlagCommand) {
    mods |= 8;
  }
  return mods;
}

/* 这颗键的原始码元：charactersIgnoringModifiers 的第一个码元，字母一律折成小写（Shift
 * 走修饰位，不让它把字母变大写，否则同一个组合会读出两个键名）。修饰键自己按出 0。 */
static unichar moonui_key_scalar(NSEvent *ev) {
  NSString *s = [ev charactersIgnoringModifiers];
  unichar c;
  if (s == nil || [s length] == 0) {
    return 0;
  }
  c = [s characterAtIndex:0];
  if (c >= 'A' && c <= 'Z') {
    c = (unichar)(c + (unichar)('a' - 'A'));
  }
  return c;
}

/* keyCode → 词表里的特殊键行。0 = 表里没有（修饰键自己、媒体键、词表外的键）。 */
static const MoonuiSpecialKey *moonui_key_row_of_code(unsigned short code) {
  size_t i;
  for (i = 0; i < MOONUI_N(moonui_special_keys); ++i) {
    if (moonui_special_keys[i].code == code) {
      return &moonui_special_keys[i];
    }
  }
  return 0;
}

/* 词表里的名字 → (keyCode, 事件字符)，只给合成脚手架用。0 = 不在词表里，脚手架据此报
 * -4，绝不"随便按一颗"——按错键的测试是一条假绿。单字符名一律按字符处理（字母折成
 * 小写），所以调用方写 "S" 和 "s" 是同一颗键。 */
static int moonui_key_lookup(const char *name, unsigned short *code_out,
                             unichar *scalar_out) {
  size_t i;
  if (name == 0 || name[0] == '\0') {
    return 0;
  }
  if (name[1] == '\0') {
    char c = (char)tolower((int)(unsigned char)name[0]);
    for (i = 0; i < MOONUI_N(moonui_printable_keys); ++i) {
      if (moonui_printable_keys[i].ch == c) {
        *code_out = moonui_printable_keys[i].code;
        *scalar_out = (unichar)c;
        return 1;
      }
    }
    return 0;
  }
  for (i = 0; i < MOONUI_N(moonui_special_keys); ++i) {
    if (strcmp(moonui_special_keys[i].name, name) == 0) {
      *code_out = moonui_special_keys[i].code;
      *scalar_out = moonui_special_keys[i].scalar;
      return 1;
    }
  }
  return 0;
}

/* 把这颗键的名字写进 out（最长 "Backspace"，缓冲 32 绰绰有余）。两条来源见本节开头：
 * 能打字的键问事件的字符，其余查 keyCode。词表以外留空串，MoonBit 据此丢掉这颗键——
 * 宁可不产事件，也不产一个 Core 匹配不到的名字。 */
static void moonui_key_read_name(NSEvent *ev, char *out) {
  unichar c = moonui_key_scalar(ev);
  const MoonuiSpecialKey *row;
  out[0] = '\0';
  if (c == ' ') {
    strcpy(out, "Space");
    return;
  }
  if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
    out[0] = (char)c;
    out[1] = '\0';
    return;
  }
  row = moonui_key_row_of_code([ev keyCode]);
  if (row != 0) {
    strcpy(out, row->name);
  }
}

/* 焦点落在哪个"我们的对象"上，找不到就报 0（不报窗口自己，理由见 adapter.h：
 * moonui_focused_control 只认控件，窗口级的那一档归 KeyDown 的归属判断管）。
 *
 * 三档，按优先级：
 *   1. firstResponder 自己就是我们打过标记的 view——按钮、勾选框走这一档。
 *   2. 正在被编辑的是那只共享 field editor（见 moonui_type_text_in_window 同一段
 *      说明）：它不是我们的控件，而 AppKit 换 firstResponder 时把被编辑的控件塞进
 *      它的 delegate，所以从 delegate 拿。
 *   3. 往上退父视图：libui 把控件包在中间层里时（uiBox 那类）第一个打过标记的祖先
 *      才是我们要的那个。
 *
 * 为什么不是"顺着 nextResponder 一路问"：那样窗口自己也在这条链上，而 NSWindow 不是
 * NSView，对它发 superview 是不认的选择器；链上还会走到 NSApp，把别的窗口的焦点
 * 当成这只窗口的。所以这里只在 win 以下活动，到窗口就停。 */
static moonui_ptr moonui_responder_owner(NSWindow *win) {
  NSView *v;
  moonui_ptr owner;
  id r;
  if (win == nil) {
    return 0;
  }
  r = [win firstResponder];
  if (r == nil || r == (id)win) {
    return 0;
  }
  owner = moonui_owner_of(r);
  if (owner != 0) {
    return owner;
  }
  if ([r respondsToSelector:@selector(delegate)]) {
    owner = moonui_owner_of([r delegate]);
    if (owner != 0) {
      return owner;
    }
  }
  if (![r isKindOfClass:[NSView class]]) {
    return 0;
  }
  for (v = (NSView *)r; v != nil && (id)v != (id)win; v = [v superview]) {
    owner = moonui_owner_of(v);
    if (owner != 0) {
      return owner;
    }
  }
  return 0;
}

/* 这颗键该算给谁：焦点在我们控件上时是那个控件，否则算事件所在窗口自己（焦点在窗口、
 * 在 libui 的辅助 view 上都算"键给了这只窗口"）；窗口都不是我们的（例如别的进程）报
 * 0，MoonBit 据此丢弃。 */
static moonui_ptr moonui_key_owner_of_event(NSEvent *ev) {
  NSWindow *win = [ev window];
  moonui_ptr owner;
  if (win == nil) {
    return 0;
  }
  owner = moonui_responder_owner(win);
  if (owner != 0) {
    return owner;
  }
  return moonui_owner_of((id)win);
}

/* 主菜单收不收这一组键？规则见 adapter.h：装了 keyEquivalent 的项 AppKit 自己就派发，
 * 监听要是照样报一颗 KeyDown，同一个 ⌘Q 的处理函数就跑两遍。判据是"字符加修饰位精确
 * 对得上"，范围含子菜单、也含禁用项——收不收是 AppKit 的事，我们只判断形状对得上。
 *
 * 这里不猜 AppKit 到底认领哪些组合（没有 Command 的 ⌃S 它收不收，SDK 头文件不写），
 * 认领范围由两条真窗口测试各自量：一条钉 ⌘Q 只响一次且是 MenuSelect，一条钉 ⌃S 只响
 * 一次且是 KeyDown。
 *
 * 修饰位要求精确相等而不是"包含"：装了 ⌘Q 时按 ⌘⇧Q，AppKit 找的是另一项（⌘⇧Q），
 * 我们不该把 ⌘Q 的动作算到它头上。 */
static int moonui_menu_claims_in(NSMenu *menu, unichar c, NSUInteger flags) {
  NSMenuItem *item;
  if (menu == nil || c == 0) {
    return 0;
  }
  for (item in [menu itemArray]) {
    NSMenu *sub = [item submenu];
    NSString *eq;
    if (sub != nil) {
      if (moonui_menu_claims_in(sub, c, flags)) {
        return 1;
      }
      continue;
    }
    eq = [item keyEquivalent];
    if ([eq length] != 1) {
      continue;
    }
    if ([eq characterAtIndex:0] == c &&
        (NSUInteger)[item keyEquivalentModifierMask] == flags) {
      return 1;
    }
  }
  return 0;
}

static int moonui_menu_claims(unichar c, NSUInteger flags) {
  return moonui_menu_claims_in([NSApp mainMenu], c, flags);
}

int moonui_on_key(moonui_closure_fn fn, void *closure) {
  int slot;
  TRACE("on_key");
  slot = moonui_take_slot((void *)&moonui_key_slot_owner, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_key_slot = slot;
  /* 监听整个进程只挂一份：重复调用到这里就换掉了槽位里的闭包，token 原样留着。 */
  if (moonui_key_monitor != nil) {
    return 0;
  }
  @autoreleasepool {
    id token = [NSEvent
        addLocalMonitorForEventsMatchingMask:
            (NSEventMaskKeyDown | NSEventMaskKeyUp)
                                    handler:^NSEvent *(NSEvent *event) {
                                      moonui_ptr target;
                                      NSUInteger flags;
                                      unichar scalar;
                                      if (event.type != NSEventTypeKeyDown &&
                                          event.type != NSEventTypeKeyUp) {
                                        return event;
                                      }
                                      target = moonui_key_owner_of_event(event);
                                      if (target == 0) {
                                        return event;
                                      }
                                      /* 设备相关的位（左右键、caps lock 那几位）不参与
                                       * 比较：菜单项存的 mask 里从来没有它们。 */
                                      flags = [event modifierFlags] &
                                              NSEventModifierFlagDeviceIndependentFlagsMask;
                                      scalar = moonui_key_scalar(event);
                                      /* 主菜单收下了就一个 KeyDown 都不报。抬起的那颗要
                                       * 一起压掉，否则 Core 收到一条没有配对的 KeyUp。 */
                                      if (moonui_menu_claims(scalar, flags)) {
                                        return event;
                                      }
                                      moonui_key_target_ptr = target;
                                      moonui_key_down =
                                          (event.type == NSEventTypeKeyDown);
                                      moonui_key_mods = moonui_mods_of(flags);
                                      moonui_key_read_name(
                                          event, moonui_key_snapshot_name);
                                      moonui_fire(&moonui_slots[moonui_key_slot]);
                                      /* 事件原样放行是前提：Core 只是想知道"有颗键出事了"，
                                       * 控件自己该打的字还得打——field editor 收的就是这
                                       * 同一颗事件。返回值改成 nil 就是"吞掉按键"，输入框
                                       * 立刻打不出字，而测试照绿（真窗口测试钉不住打字，
                                       * 只有 examples 里人眼看得见）。 */
                                      return event;
                                    }];
    moonui_key_monitor = [token retain];
  }
  /* token 拿到不到都可能（理论上只在内存不够时）。没挂上就把刚占的槽位还掉，让
   * MoonBit 侧报成显式错误而不是"监听永远不会响"。 */
  if (moonui_key_monitor == nil) {
    moonui_forget((void *)&moonui_key_slot_owner, fn);
    moonui_key_slot = -1;
    return -1;
  }
  return 0;
}

/* terminate 的第一件事（见上面那条声明）。摘掉之后再没有回调会跑，槽位才可以排干。 */
static void moonui_key_drop_monitor(void) {
  if (moonui_key_monitor != nil) {
    [NSEvent removeMonitor:moonui_key_monitor];
    [moonui_key_monitor release];
    moonui_key_monitor = nil;
  }
  moonui_key_slot = -1;
}

moonui_ptr moonui_key_target(void) {
  TRACE("key_target");
  return moonui_key_target_ptr;
}

int moonui_key_is_down(void) {
  TRACE("key_is_down");
  return moonui_key_down;
}

int moonui_key_modifiers(void) {
  TRACE("key_modifiers");
  return moonui_key_mods;
}

moonbit_bytes_t moonui_key_name(void) {
  TRACE("key_name");
  return moonui_bytes_of(moonui_key_snapshot_name);
}

moonui_ptr moonui_focused_control(moonui_ptr w) {
  TRACE("focused_control");
  /* 没有控件拿着焦点时报 0：焦点在窗口自己、在 libui 的辅助 view、或者那个原生对象
   * 我们没记过。这里读的是那只窗口自己的 firstResponder，不是"整个应用在听键盘的那只
   * 窗口"（那是 [NSApp keyWindow]），理由见 adapter.h 那条声明。 */
  return moonui_responder_owner(moonui_nswindow(w));
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

/* 客户区坐标（左上原点、物理像素）→ 命中的原生 view，下面两条新脚手架共用。返回 0
 * 时两个出参都有值；负数就是各自契约里的 -1..-3（编码失败 / 没有这只窗口 / 命不中
 * 任何 view）。换算和上面那两条一样，只是不重复写第三遍——那两条有既有测试钉着，
 * 不为了这次改动去动它们。 */
static int moonui_hit_of(NSString *t, int x, int y, NSWindow **win_out,
                         NSView **hit_out) {
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
  point = NSMakePoint(moonui_px_to_pt(x, scale),
                      moonui_flip_y(content, moonui_px_to_pt(y, scale),
                                    (CGFloat)0.0));
  hit = [content hitTest:point];
  if (hit == nil) {
    return -3;
  }
  *win_out = win;
  *hit_out = hit;
  return 0;
}

/* 等价于"用户把焦点挪到客户区 (x, y) 处那个控件上"。契约见 adapter.h 同名声明那段。
 *
 * 往上退到"我们的控件"这一步和 type_text 那条同形，但判据换成了那笔反查标记而不是
 * 类名：这里要问的是"这是不是一个 MoonUI 控件"，而 label 也是 NSTextField——按类名分
 * 会把 label 和输入框算成同一种东西。
 *
 * 为什么最后还要用 moonui_responder_owner 回读一次，而不是信 makeFirstResponder: 的
 * 返回值（本机实测）：给一只拿不了焦点的控件（label、按钮、勾选框在 full keyboard
 * access 关掉时都是这一档）时它报"改了"，而 firstResponder 其实落在了窗口自己头上。
 * 只信返回值的话脚手架报 0、焦点表却读到空，调用方以为焦点真的挪走了。所以这里的
 * "0 = 焦点已给出去"用的是和 moonui_focused_control 同一个判据：给不成就是 -4，和
 * Windows 的禁用控件同一档（adapter.h 原来给 mac 留的 -5 因此没有对象，删了）。 */
int moonui_focus_widget_in_window(const char *title,
                                  int title_len,
                                  int x,
                                  int y) {
  TRACE("focus_widget_in_window");
  @autoreleasepool {
    NSString *t = moonui_string_of(title, title_len);
    NSWindow *win;
    NSView *hit;
    NSView *up;
    moonui_ptr want;
    int code = moonui_hit_of(t, x, y, &win, &hit);
    if (code != 0) {
      return code;
    }
    up = hit;
    while (up != nil && up != [win contentView] && moonui_owner_of(up) == 0) {
      up = [up superview];
    }
    if (up == nil || up == [win contentView] || moonui_owner_of(up) == 0) {
      return -4;
    }
    want = moonui_owner_of(up);
    /* 编辑框这里交出去的是文本框自己，AppKit 会自己换成 field editor（见 type_text
     * 那段），所以回读不是拿 firstResponder 和 up 比指针，而是走同一条退到"我们的
     * 控件"的判断——两边看到的还是同一个控件。 */
    if (![win makeFirstResponder:up] || moonui_responder_owner(win) != want) {
      return -4;
    }
    return 0;
  }
}

/* 等价于"用户在键盘上按了（或抬起了）一颗键"，落点是当下有焦点的那个控件。
 *
 * 造的是一条**真 NSEvent** 交给 [NSApp sendEvent:]。本机一次性实测（探针写在仓库外的
 * /tmp，跑完即删，结论抄在这里）：sendEvent: 会同步跑 local monitor、会在派发之前做
 * 主菜单的 keyEquivalent 判断、被认领的组合它自己就把事件消费掉了（那次 -keyDown:
 * 根本没发生，而 ⌃S 这种没装进菜单的会走到 view）。所以这一条把"监听→快照→回调"和
 * moonui_menu_claims 那条规则都真跑了一遍，返回 0 时回调确实已经跑过。
 *
 * 看起来更真的另一条路（postEvent: 然后交给事件循环取）在这台机器上不可用：没激活的
 * 进程里 nextEventMatchingMask:distantPast 取不到刚 post 的那颗，要等下一圈才连同上一颗
 * 一起冲出来——落点跟着激活时序漂，和上面"这里没有量 Tab 方向的脚手架"同一条理由。
 *
 * 归属靠焦点而不是坐标，所以调用方要先用上一条把焦点放好；没放好时这颗键会算到窗口
 * 自己头上，那条断言就成了假绿，所以这里先查、查不到直接报 -3。 */
int moonui_send_key_in_window(const char *title,
                              int title_len,
                              const char *key,
                              int key_len,
                              int mods,
                              int down) {
  TRACE("send_key_in_window");
  @autoreleasepool {
    NSString *t = moonui_string_of(title, title_len);
    char *k;
    NSWindow *win;
    unsigned short code;
    unichar scalar;
    NSString *chars;
    NSEvent *ev;
    if (t == nil) {
      return -1;
    }
    k = moonui_dup(key, key_len);
    if (k == 0) {
      return -1;
    }
    if (!moonui_key_lookup(k, &code, &scalar)) {
      free(k);
      return -4;
    }
    free(k);
    win = moonui_find_window(t);
    if (win == nil) {
      return -2;
    }
    if (moonui_responder_owner(win) == 0) {
      return -3;
    }
    chars = [NSString stringWithCharacters:&scalar length:1];
    ev = [NSEvent
        keyEventWithType:(down != 0 ? NSEventTypeKeyDown : NSEventTypeKeyUp)
                location:NSZeroPoint
           modifierFlags:moonui_menu_mods_flag(mods)
               timestamp:0
            windowNumber:(NSInteger)[win windowNumber]
                 context:nil
              characters:chars
     charactersIgnoringModifiers:chars
                     isARepeat:NO
                       keyCode:code];
    /* AppKit 造不出来（这个词表内的键它不接受）也按 -4 报：调用方要的是"这颗键没生效"，
     * 而不是分得清是哪一步拦下的。 */
    if (ev == nil) {
      return -4;
    }
    [NSApp sendEvent:ev];
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

/* 装好"ms 毫秒之后按下下一个对话框的第 index 个按钮"，认领与真正按下的过程在上面
 * 的 moonui_arm_dismissor。契约（为什么必须有这条、为什么越界要当场报回去）在
 * adapter.h 的测试脚手架那段。
 * 这一发不落进 runloop 里等待，只是记两个数：面板还没建，此时没有定时器可挂。 */
int moonui_auto_dismiss_dialog(int ms, int index) {
  TRACE("auto_dismiss_dialog");
  if (index < 0 || index > 1) {
    return -1;
  }
  moonui_dismiss_after_ms = ms < 0 ? 0 : ms;
  moonui_dismiss_index = index;
  return 0;
}

/* 装好"ms 毫秒之后替下一个文件面板按取消"。契约（为什么必须有这条、为什么空 path
 * 的接受要当场报回去）在 adapter.h 的测试脚手架那段；认领与按下的过程在上面文件
 * 对话框那节的 moonui_arm_file_answer。
 * 和上一条一样，这一发不落进 runloop 里等待，只是记一个数：面板还没建。
 *
 * macOS 15.6 起"替用户按接受"做不到，这里当场报 -2，证据是 2026-10-09 一串带看门狗
 * 的探针（/private/tmp 的 moonui-t21-panel-probe5..16，结论抄在 TODO 的 T21 那行）：
 * 面板跑在系统 XPC 服务里（com.apple.appkit.xpc.openAndSavePanelService），放行 OK
 * 的那段代码长在服务进程里，客户端这侧 [panel ok:] 是个桩——AppKit 自己的日志
 * "-[NSSavePanel ok:] : not implemented"，抛 NSGenericException，随后弹的报警框是
 * "The open file operation failed to connect to the open and save panel service."；
 * 换 sheet 形态、打包成 .app、经 LaunchServices 启动、杀掉旧服务重开都还是转；合成
 * 按键到不了服务进程；stopModalWithCode: / endSheet:returnCode: 能把 modal 结束但
 * [panel URL] 是 nil——选中的东西只活在服务里，只有服务自己结束会话才送得回客户端。
 * 也就是说：真人在真 App 里按 OK 的产品路径不受影响，死的只有"自动化替按"这一条，
 * 所以"选了 → Some(path)"由 Windows 真跑钉（TODO 的 T44），mac 这条测试只钉取消。 */
int moonui_auto_answer_file_dialog(int ms,
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
  moonui_file_answer_after_ms = ms < 0 ? 0 : ms;
  return 0;
}

/* dump 里的组合一栏：读的是 item 自己的 keyEquivalent 和 modifier mask，也就是
 * "Core 给的组合到底落到了菜单项上没有"。修饰键按 C/A/S/M 的固定顺序，一个都没有时写
 * "-"（那是 Core 声明了裸键组合）；键名还原成 Core 的词表（event.mbt 的 "Enter"/"a"）。
 * 格式和 Windows 那一份必须逐字符一致，见 adapter.h。 */
static void moonui_menu_dump_combo(NSMenuItem *item, NSMutableString *out) {
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

static void moonui_menu_dump_nodes(NSMenu *menu, NSMutableString *out);

static void moonui_menu_dump_node(NSMenuItem *item, NSMutableString *out) {
  NSNumber *role;
  if ([item isSeparatorItem]) {
    [out appendString:@"-"];
    return;
  }
  if ([item submenu] != nil) {
    [out appendFormat:@"+%@{", [item title]];
    moonui_menu_dump_nodes([item submenu], out);
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
  moonui_menu_dump_combo(item, out);
}

static void moonui_menu_dump_nodes(NSMenu *menu, NSMutableString *out) {
  NSArray *items = [menu itemArray];
  NSUInteger i;
  for (i = 0; i < [items count]; ++i) {
    if (i > 0) {
      [out appendString:@","];
    }
    moonui_menu_dump_node([items objectAtIndex:i], out);
  }
}

/* 只给测试用：把当下这棵原生菜单截成一根文本（格式在 adapter.h）。
 * 为什么是一根文本而不是五个 getter：要验的是整棵树的形状，逐个问既放不下子菜单的
 * 嵌套，也要两份 C 各维护五条形状相同的入口。
 *
 * 遍历的是 `[NSApp mainMenu]` 而不是自己记的那份名单：名单是我们抄的，抄得像但没真正
 * 挂上主菜单，读名单的 dump 会照样绿。属于我们的那几顶用 `containsObject:` 认出来，
 * 于是既不数索引（那靠的是别人的顺序），也不会把 uiInit 建的应用菜单读进来。 */
moonbit_bytes_t moonui_menu_dump(void) {
  TRACE("menu_dump");
  @autoreleasepool {
    NSMutableString *out = [NSMutableString string];
    NSMenu *main_menu = [NSApp mainMenu];
    NSUInteger i;
    int first = 1;
    if (main_menu == nil || moonui_menu_items == nil) {
      return moonbit_make_bytes(0, 0);
    }
    NSArray *tops = [main_menu itemArray];
    for (i = 0; i < [tops count]; ++i) {
      NSMenuItem *top = [tops objectAtIndex:i];
      if (![moonui_menu_items containsObject:top]) {
        continue;
      }
      if (!first) {
        [out appendString:@";"];
      }
      first = 0;
      [out appendFormat:@"%@{", [top title]];
      moonui_menu_dump_nodes([top submenu], out);
      [out appendString:@"}"];
    }
    if ([out length] == 0) {
      return moonbit_make_bytes(0, 0);
    }
    return moonui_bytes_of_ns(out);
  }
}

/* 只给测试用：等价于"用户在原生菜单里点了 id 这一项"。查 id 和派发都走原生对象自己
 * （按 tag 找、`performActionForItemAtIndex:` 派发），不是把 MoonBit 的回调直接调一遍
 * ——于是 tag 带回来的 id、target 那层桥、Core 的 MenuSelect 路由全被跑过。
 * 禁用那一支在这里先拦：`performActionForItemAtIndex:` 自己会尊重 isEnabled 而什么都不
 * 做，那就成了"什么也没发生但报 0"，而 adapter.h 要求两边报同一套码。 */
int moonui_menu_click_item(int id) {
  TRACE("menu_click_item");
  @autoreleasepool {
    NSMenuItem *item = moonui_menu_find_id(id);
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

/* 只给测试用：给本进程设一次外观覆盖。mode 0 = 取消覆盖（回到跟随系统），
 * 1 = 强制 DarkAqua，2 = 强制 Aqua。
 *
 * 为什么两个方向都要：moonui_system_theme 读的是 NSApp.effectiveAppearance，而"如实
 * 读数"和"恒报某一个值"只有在和桌面设置不同的那一刻才分得开。这台机器的桌面当下是
 * 浅色（`defaults read -g AppleInterfaceStyle` 直接报"键不存在"），所以只设深色那一发
 * 就只能验出"恒报浅色"；换一台桌面的深色机器上，同一句断言就变成自证。两个方向各钉
 * 一句，恒报 Light 恒红在其中一句、恒报 Dark 恒红在另一句，跟测试跑在哪台机器上、
 * 桌面设的什么无关。
 * 只动 NSApp.appearance：不改系统设置、不落盘，用完清掉。申报在本文件而不是
 * adapter.h：Windows 没有同类的进程级覆盖，让那边为一个测试入口去实现一个假符号
 * 不划算；形状和另外两条 moonui_cocoa_* 探针一样。 */
void moonui_cocoa_set_appearance_override(int mode) {
  TRACE("cocoa_set_appearance_override");
  @autoreleasepool {
    NSAppearance *a;
    a = mode == 1 ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
                  : (mode == 2 ? [NSAppearance appearanceNamed:
                                      NSAppearanceNameAqua]
                                : nil);
    [NSApp setAppearance:a];
  }
}
