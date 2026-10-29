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
 *     这里 NSWindow 归本文件所有，用手写 MRR 的强引用表（moonui_native_live_windows）
 *     把它钉住（`prebuild-link.js` 调 clang 时没有 `-fobjc-arc`，实际编译口径是
 *     MRR，`T97`① 订正——本文件早先的 ARC 说法是 libui 时代留下的），销毁时摘掉、
 *     最后一份引用没了它自己 dealloc。
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
/* 默认菜单（`T129`）：init 装、terminate 拆、set_menu_bar 挪到树末尾——三处
 * 用到，定义在"菜单栏"一节里。 */
static void moonui_native_default_menus_install(void);
static void moonui_native_default_menus_remove(void);

/* `T85②` 的组合事件源（定义在本文件末尾的"输入法组合事件源"一节）：terminate
 * 松监听闭包的那一步、派发器在文本变化观察里推相位的那一步，都用到这里的声明。 */
static void moonui_native_ime_drop_closure(void);
static void moonui_native_ime_derive(NSView *control);
static NSTextView *moonui_native_ime_editor_of(NSView *control, int kind);
static BOOL moonui_native_ime_replace_keeping_compose(NSTextView *editor,
                                                     NSString *t);
static void moonui_native_ime_end_if_composing(NSView *control);
static void moonui_native_ime_flush_pending(void);

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
static void moonui_native_tray_clear(void);

/* 键盘与焦点（`T91` 移植，adapter.h 键盘段注的整套契约）：进程级键盘监听
 * （KeyDown/KeyUp 两支，主菜单认领的组合不报）加焦点反查。 */
static void moonui_native_key_drop_closure(void);
/* 触控板手势的事件源（`T100`，adapter.h 手势段）：与鼠标同一条形状，进程一份。 */
static void moonui_native_gesture_drop_closure(void);
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
- (void)dispatch:(id)sender;
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
/* 拖动期轮询的登记位置（moonui_native_pack2 打包）：最后一次报给 Core 的位置，
 * 或 Core 程序化搬窗登记的目标位置。轮询拿它判"窗外的位移要不要补报"。 */
@property(nonatomic, assign) int64_t tracked_pos;
/* 程序化搬窗后的抑制窗截止时刻（NSDate 时间间隔参考系）：窗内轮询不补报——
 * WindowServer 的提交比 setFrameOrigin 慢一拍（实测），那段时间服务器位置还是
 * 旧值，照报会把程序化搬窗回声成 Moved。 */
@property(nonatomic, assign) double move_suppress_until;
/* 拖动期的鼠标增量预测（方案 B）：标题栏拖动是窗跟鼠标 1:1，鼠标读数比
 * WindowServer 的 bounds 新（后者要等一拍提交）、比 AppKit 的 frame 缓存更
 * 新（拖动中途不同步）。拖动期位置就用"锚点 + 鼠标位移"推算，邻居才和被拖
 * 窗同一个合成帧里动。frame_anchor/mouse_anchor 是推算基准（didMove 对齐）。 */
@property(nonatomic, assign) BOOL drag_est_active;
/* 测试缝喂进来的合成拖动（moonui_native_window_drag_step）：预测原点由缝直接
 * 给，轮询不读真实鼠标、也不因松手把预测关掉。 */
@property(nonatomic, assign) BOOL drag_synth;
@property(nonatomic, assign) NSPoint drag_est_origin;
@property(nonatomic, assign) NSPoint drag_frame_anchor;
@property(nonatomic, assign) NSPoint drag_mouse_anchor;
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
 * 在这里就要引用它们——补前向声明。`server_frame` 的查询段也在文件后半，
 * windowDidMove: 对齐预测锚点时要用它（实测落位的权威值），一并前向声明。 */
static int moonui_native_drop_accepts(void);
static BOOL moonui_native_drop_perform(MoonuiWindow *win,
                                id<NSDraggingInfo> info);
static NSRect moonui_native_server_frame(MoonuiWindow *win);

/* ---- 拖动期位置轮询（live move）----
 *
 * mac 的硬约束（CocoaDev / zenn 记载，2026-10-19 探针复核）：拖标题栏时
 * `windowDidMove:` 只在**松手或停顿约半秒**才补报，且拖动中途 `NSWindow.frame`
 * 是旧值——窗由 WindowServer 移动，AppKit 的 frame 缓存不同步。所以"拖动途中
 * 要跟手"没有现成事件可用，只能自己驱动：
 *
 * - `moonuiWillMove:`（拖动开始，程序化搬窗也会发）把这只轮询定时器挂上
 *   NSRunLoopCommonModes——eventTracking 模式的拖动跟踪循环里照样转；同时给
 *   鼠标增量预测上锚（`drag_frame_anchor`/`drag_mouse_anchor`）；
 * - 每拍用**鼠标增量推算**本窗位置（方案 B）：标题栏拖动是窗跟鼠标 1:1，
 *   `[NSEvent mouseLocation]` 是实时读数（没有 WindowServer 的一帧提交延迟、
 *   也没有 AppKit frame 缓存的陈旧），锚点+鼠标位移 = 当下真在哪。相对登记
 *   位置变了就走 `moved_slot` 的既有回调链（→ push_move → live dispatch →
 *   吸附联动），一拍一跟、邻居和被拖窗同拍落定——"先发现再搬"的那 1~2 帧
 *   结构性延迟就是这么消掉的；
 * - 非拖动的外源移动（测试缝 `move_external`）不带预测，仍问 WindowServer；
 * - 左键抬起且一段时间无变化就停表，停表后零开销。
 *
 * 程序化搬窗不误报：`moonui_native_window_set_position` 会登记目标位置并开一小段
 * 抑制窗（`move_suppress_until`，盖过 WindowServer 那一拍提交延迟）。
 */
static const double MOONUI_MOVE_SUPPRESS_S = 0.15;
static const NSTimeInterval MOONUI_MOVE_POLL_S = 1.0 / 240.0;
/* 多久"没活干"才停表（按时长不按拍数，和采样率解耦）：外源移动后 WindowServer
 * 的提交要慢一拍（≈一个合成帧 16ms），第一拍读到的还是旧位置——无变化就停会把
 * 表停死在提交落地之前。原 3 拍@60Hz ≈ 50ms，提频后保持同一时长。 */
static const NSTimeInterval MOONUI_MOVE_POLL_IDLE_S = 0.05;
static NSTimer *moonui_native_move_poll_timer = nil;
static double moonui_native_move_poll_idle_since = 0.0;

static void moonui_native_move_poll_stop(void) {
  if (moonui_native_move_poll_timer != nil) {
    [moonui_native_move_poll_timer invalidate];
    moonui_native_move_poll_timer = nil;
  }
  moonui_native_move_poll_idle_since = 0.0;
}

static void moonui_native_move_poll_tick(void) {
  int changed = 0;
  int busy = 0;
  double now = [NSDate timeIntervalSinceReferenceDate];
  for (NSWindow *w in moonui_native_live_windows) {
    if (![w isKindOfClass:[MoonuiWindow class]]) {
      continue;
    }
    MoonuiWindow *win = (MoonuiWindow *)w;
    if (win.moved_slot < 0 || win.suppress_move) {
      continue;
    }
    if (win.move_suppress_until > now) {
      /* 程序化搬窗的抑制窗内按兵不动，但算"有活在途"（提交还没落地），不能
       * 计入"没活干"把表停死。 */
      busy = 1;
      continue;
    }
    if (win.drag_est_active && !win.drag_synth) {
      if (([NSEvent pressedMouseButtons] & 1) == 0) {
        /* 松手（或本来就没按——点击标题栏不拖也发 willMove）：预测退位，
         * 实测位置为准。真拖的收尾还有 windowDidMove: 补报兜底。 */
        win.drag_est_active = NO;
      } else {
        /* 锚点 + 鼠标位移 = 当下真在哪。每次从锚点推、不增量累加，没有
         * 浮点漂移；约束交给 constrainFrameRect（拖到菜单栏/Dock 边被顶住
         * 时窗不跟鼠标 1:1，和拖动循环同一套约束）。 */
        NSPoint m = [NSEvent mouseLocation];
        NSRect r = [win frame];
        r.origin = NSMakePoint(
            win.drag_frame_anchor.x + (m.x - win.drag_mouse_anchor.x),
            win.drag_frame_anchor.y + (m.y - win.drag_mouse_anchor.y));
        r = [win constrainFrameRect:r toScreen:[win screen]];
        win.drag_est_origin = r.origin;
      }
    }
    int64_t cur = moonui_native_window_position((moonui_ptr)(uintptr_t)win);
    if (cur != win.tracked_pos) {
      win.tracked_pos = cur;
      moonui_native_fire(&moonui_native_slots[win.moved_slot]);
      changed = 1;
    }
  }
  /* 左键抬起 + 一段时间无活 = 拖动结束，停表。只看"松手"不够（点击标题栏不拖
   * 也发 willMove）；只看"无变化"不够（按住暂停的拖动还没完）。 */
  if (changed || busy) {
    moonui_native_move_poll_idle_since = 0.0;
    return;
  }
  if (moonui_native_move_poll_idle_since <= 0.0) {
    moonui_native_move_poll_idle_since = now;
    return;
  }
  if (([NSEvent pressedMouseButtons] & 1) == 0 &&
      now - moonui_native_move_poll_idle_since >= MOONUI_MOVE_POLL_IDLE_S) {
    moonui_native_move_poll_stop();
  }
}

static void moonui_native_move_poll_start(void) {
  if (moonui_native_move_poll_timer != nil) {
    return;
  }
  moonui_native_move_poll_idle_since = 0.0;
  moonui_native_move_poll_timer =
      [NSTimer timerWithTimeInterval:MOONUI_MOVE_POLL_S
                            repeats:YES
                              block:^(NSTimer *t) {
                                (void)t;
                                moonui_native_move_poll_tick();
                              }];
  [[NSRunLoop mainRunLoop] addTimer:moonui_native_move_poll_timer
                            forMode:NSRunLoopCommonModes];
}

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
    self.tracked_pos = 0;
    self.move_suppress_until = 0.0;
    self.drag_est_active = NO;
    self.drag_synth = NO;
    self.drag_est_origin = NSZeroPoint;
    self.drag_frame_anchor = NSZeroPoint;
    self.drag_mouse_anchor = NSZeroPoint;
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

/* 拖动开始：给鼠标增量预测上锚 + 把拖动期位置轮询挂上。mac 拖动中途没有
 * windowDidMove:（松手/停顿才补报），跟手只能靠轮询——见 poller 段注。
 *
 * willMove 这一刻 `frame.origin` 还是移动前的落点、鼠标正按在标题栏上：之后
 * 的窗位移 == 鼠标位移（标题栏拖动 1:1），两个锚点记的就是这个基准。预测原点
 * 先给成当下落点——点击标题栏不拖的话不该凭空报移动。
 *
 * 注意这不是 NSWindowDelegate 的方法：willMove 只有通知（NSWindowWillMove-
 * Notification）、没有委托回调（didMove 两个都有），所以这条经通知中心注册
 * （moonui_native_window_new 里挂、destroy 里摘），名字也就不叫 windowWillMove:。 */
- (void)moonuiWillMove:(NSNotification *)note {
  (void)note;
  NSPoint p = [self frame].origin;
  self.drag_frame_anchor = p;
  self.drag_mouse_anchor = [NSEvent mouseLocation];
  self.drag_est_origin = p;
  self.drag_est_active = YES;
  self.drag_synth = NO;
  moonui_native_move_poll_start();
}

- (void)windowDidMove:(NSNotification *)note {
  (void)note;
  /* 预测收尾/对齐：松手退位，实测为准；停顿约半秒的中途补报（鼠标还按着）把
   * 锚点对齐到实测落位，之后的增量从这里接着推（预测误差不留到拖动结束）。
   * 合成拖动（drag_synth）的状态归缝管，这里不碰。 */
  if (!self.drag_synth && self.drag_est_active) {
    if (([NSEvent pressedMouseButtons] & 1) == 0) {
      self.drag_est_active = NO;
    } else {
      NSPoint p = moonui_native_server_frame(self).origin;
      self.drag_frame_anchor = p;
      self.drag_mouse_anchor = [NSEvent mouseLocation];
      self.drag_est_origin = p;
    }
  }
  if (!self.suppress_move && self.moved_slot >= 0) {
    /* 同步登记位置：这条一发，轮询/后续回调都以它为基准，不重复报同一位移。
     * 顺带把轮询起表兜一道——willMove 是拖动开始的主信号，这里兜"没发 willMove
     * 的那种移动"（缩放回位、Spaces 挪动等），一段时间无活再自停。 */
    self.tracked_pos = moonui_native_window_position((moonui_ptr)(uintptr_t)self);
    moonui_native_move_poll_start();
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
    /* `T129`：空菜单建好就装默认菜单（退出 ⌘Q + 编辑那组标准动作）——
     * 应用一行不写也有常用快捷键。幂等：已装过（重复 init）直接回。 */
    moonui_native_default_menus_install();
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
  /* 拖动期位置轮询先停表（进程一份的定时器，跟着收尾一起走）。 */
  moonui_native_move_poll_stop();
  /* 菜单栏的回调不占槽位表（整个进程只有一棵菜单），所以单独松一次，排在排槽
   * 之前——槽位表只看守"一控件一格"的回调，菜单那份在它自己那格里。 */
  moonui_native_menu_drop_closure();
  /* 默认菜单（`T129`）是后端自己装的两顶，跟 Core 的树无关，但留着会让
   * 下一次 init 之后的树多出两顶重复项——拆掉，init 再装。 */
  moonui_native_default_menus_remove();
  /* `T85②`：组合监听同一条形状（进程一份，不占槽位表），排在排槽之前一起松。 */
  moonui_native_ime_drop_closure();
  /* `T86`：右键事件源、文件拖入源、上下文菜单与托盘的闭包同一条形状
   * （进程一份，不占槽位表），排在排槽之前一起松。键盘同款（`T91`）。 */
  moonui_native_mouse_drop_closure();
  moonui_native_key_drop_closure();
  moonui_native_gesture_drop_closure();
  moonui_native_drop_drop_closure();
  moonui_native_ctx_drop_closure();
  moonui_native_tray_drop_closure();
  /* `T91⑥`：状态项是进程级单例，收尾要把图标从状态条上摘掉——否则多次
   * init/terminate 之后会留下幽灵图标，下一只 backend 实例的探针也会读到它。 */
  moonui_native_tray_clear();
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
    /* 漏网窗口的通知观察者先摘干净（MRC 不摘会野指针），再清强引用表。 */
    for (NSWindow *w in moonui_native_live_windows) {
      [[NSNotificationCenter defaultCenter] removeObserver:w];
    }
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
    /* 纯光标移动（没按住任何键）要窗口收了 `acceptsMouseMovedEvents` 才会由
     * WindowServer 产出来，进程级监听才看得见（`T146`）。此前从未设过，于是
     * mac 上"指针划过控件"一条 `MouseMove` 都不产，`App::hover_track` 的
     * MouseEnter/MouseLeave 只靠拖拽与离开窗口那两条偶发触发——`hover_style`
     * 与音量条百分比读数在 mac 上就等于不工作。adapter.h 鼠标段注把这一句
     * 记作"打开它是改产品行为"，现在由 Luna 的音量百分比这一格认领：打开它。 */
    [win setAcceptsMouseMovedEvents:YES];
    /* willMove 只有通知没有委托回调（见 moonuiWillMove: 的段注），拖动期轮询的
     * 起表信号在这条通知上注册。 */
    [[NSNotificationCenter defaultCenter] addObserver:win
                                             selector:@selector(moonuiWillMove:)
                                                 name:NSWindowWillMoveNotification
                                               object:win];
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
  /* willMove 通知的观察者摘掉（MRC 不摘会野指针）。 */
  [[NSNotificationCenter defaultCenter] removeObserver:win];
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

/* 把"外层左上角、屏幕物理像素、y 向下"的目标落进 NSWindow 的 frame。Cocoa 的
 * setFrameOrigin: 收的是左下角、y 向上，所以翻一次 y：用窗口所在屏的可见区高度
 * 减掉目标 y 和窗口高度。和 libui 的 darwin 版（uiWindowSetPosition）同一套。 */
static void moonui_native_apply_origin(MoonuiWindow *win, int x, int y) {
  CGFloat scale = moonui_native_window_scale((moonui_ptr)(uintptr_t)win);
  NSScreen *screen = [win screen] != nil ? [win screen] : moonui_native_primary_screen();
  NSRect visible = screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
  NSRect frame = [win frame];
  CGFloat originY = visible.origin.y + visible.size.height -
                    moonui_native_px_to_pt(y, scale) - frame.size.height;
  [win setFrameOrigin:NSMakePoint(visible.origin.x + moonui_native_px_to_pt(x, scale),
                                  originY)];
}

/* frame → pack2(x, y)：和 setter 同一套翻转，y 从"该屏可见区上边往下"量。 */
static int64_t moonui_native_pack_frame(MoonuiWindow *win, NSRect frame) {
  CGFloat scale = moonui_native_window_scale((moonui_ptr)(uintptr_t)win);
  NSScreen *screen = [win screen] != nil ? [win screen] : moonui_native_primary_screen();
  NSRect visible = screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
  return moonui_native_pack2(
      moonui_native_pt_to_px(frame.origin.x - visible.origin.x, scale),
      moonui_native_pt_to_px(visible.size.height - (frame.origin.y + frame.size.height - visible.origin.y), scale));
}

/* WindowServer 里的真实外框（AppKit 坐标）。拖标题栏时 NSWindow.frame 是旧值
 * （窗由 WindowServer 移动、AppKit 缓存不同步，2026-10-19 探针复核），实时位置
 * 只有问 WindowServer——kCGWindowBounds 是 CG 全局坐标（原点在零屏左上、y 向下），
 * 翻 y 换回 AppKit 全局：nsY = 零屏MaxY - cgY - 高。查不到（窗口还没提交）就退回
 * frame 缓存，不比它更坏。 */
static NSRect moonui_native_server_frame(MoonuiWindow *win) {
  CGRect cg;
  CFDictionaryRef bounds;
  CFArrayRef list;
  CFDictionaryRef info;
  CFNumberRef num;
  NSScreen *zero;
  int64_t n = 0;
  list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
                                    (CGWindowID)[win windowNumber]);
  if (list != NULL) {
    if (CFArrayGetCount(list) > 0) {
      info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, 0);
      num = (CFNumberRef)CFDictionaryGetValue(info, kCGWindowNumber);
      if (num != NULL) {
        CFNumberGetValue(num, kCFNumberSInt64Type, &n);
      }
      bounds = (CFDictionaryRef)CFDictionaryGetValue(info, kCGWindowBounds);
      if (n == (int64_t)(CGWindowID)[win windowNumber] && bounds != NULL &&
          CGRectMakeWithDictionaryRepresentation(bounds, &cg)) {
        zero = [[NSScreen screens] firstObject];
        if (zero != nil) {
          CGFloat c = NSMaxY([zero frame]);
          CFRelease(list);
          return NSMakeRect(cg.origin.x, c - cg.origin.y - cg.size.height,
                            cg.size.width, cg.size.height);
        }
      }
    }
    CFRelease(list);
  }
  return [win frame];
}

void moonui_native_window_set_position(moonui_ptr w, int x, int y) {
  TRACE("window_set_position");
  @autoreleasepool {
    /* suppress_move 挡掉"程序化搬窗"的回声（adapter.h 的 on_moved 契约）：Core
     * 的吸附联动（`App::follow_move`）搬邻居时调的就是这条，那不该回声成一条
     * Moved 事件——否则联动会自拖自、邻居被搬两遍。 */
    MoonuiWindow *win = (MoonuiWindow *)(uintptr_t)w;
    win.suppress_move = YES;
    moonui_native_apply_origin(win, x, y);
    win.suppress_move = NO;
    /* 登记目标位置 + 开抑制窗：WindowServer 的提交比 setFrameOrigin 慢一拍
     * （2026-10-19 探针：set 后立刻查服务器还是旧位置），这窗内轮询若照报就是
     * 把程序化搬窗回声成 Moved。窗后两边（frame 与服务器）已收敛到登记值。 */
    win.tracked_pos = moonui_native_pack_frame(win, [win frame]);
    win.move_suppress_until =
        [NSDate timeIntervalSinceReferenceDate] + MOONUI_MOVE_SUPPRESS_S;
  }
}

/* 测试缝：模拟"WindowServer 把窗挪走了、AppKit 没有通知"的外部移动——用户拖动
 * 的中途态（frame 不动、didMove 不发）。绕过 suppress_move 的回声抑制、不登记
 * 位置、不开抑制窗：后续由拖动期轮询（windowWillMove 起表）从 WindowServer 读到
 * 真实位置、走 moved_slot 的既有链路补报。只给真窗口测试用。 */
void moonui_native_window_move_external(moonui_ptr w, int x, int y) {
  TRACE("window_move_external");
  @autoreleasepool {
    MoonuiWindow *win = (MoonuiWindow *)(uintptr_t)w;
    win.suppress_move = YES;
    moonui_native_apply_origin(win, x, y);
    win.suppress_move = NO;
    /* tracked_pos 不动（外源移动，留给轮询发现）；抑制窗一并清掉——那是给
     * "自己刚搬完窗"用的，外源移动（真实拖动的中途态）不带抑制窗。 */
    win.move_suppress_until = 0.0;
    /* 真实拖动的上下文里轮询已经被 willMove 挂上；程序化 setFrameOrigin 不发
     * willMove（2026-10-19 探针实测），这里补上同一状态。 */
    moonui_native_move_poll_start();
  }
}

/* 测试缝（只给真窗口测试用）：喂一拍"合成拖动"——模拟用户拖着标题栏走到了
 * (x, y)。和 `move_external` 不同，这条走**鼠标增量预测**的路径（方案 B）：
 * 预测原点由缝直接给（不读真实鼠标、也不因松手把预测关掉），并且**同步**走
 * 一拍拖动期轮询——发现→补报→吸附联动全在 drag_step 返回前落定，测试断言
 * "邻居和被拖窗同拍"不必等定时器。x/y 口径同 set_position：物理像素。 */
void moonui_native_window_drag_step(moonui_ptr w, int x, int y) {
  TRACE("window_drag_step");
  @autoreleasepool {
    MoonuiWindow *win = (MoonuiWindow *)(uintptr_t)w;
    /* 先亮合成旗再挪窗：apply_origin 触发的 windowDidMove: 看到 drag_synth
     * 就不碰预测状态（开关/锚点归缝管）。真把窗挪到位是模拟 WindowServer 的
     * 1:1 跟手——测试对被拖窗的断言才和真实拖动同构。 */
    win.drag_synth = YES;
    win.drag_est_active = YES;
    win.suppress_move = YES;
    moonui_native_apply_origin(win, x, y);
    win.suppress_move = NO;
    win.drag_est_origin = [win frame].origin;
    win.move_suppress_until = 0.0;
    /* 同步走一拍轮询：拖动期的发现→补报→吸附联动全在这一拍里落定。 */
    moonui_native_move_poll_tick();
  }
}

int64_t moonui_native_window_position(moonui_ptr w) {
  NSRect frame;
  TRACE("window_position");
  @autoreleasepool {
    MoonuiWindow *win = (MoonuiWindow *)(uintptr_t)w;
    /* 三源择新：拖动中的鼠标增量预测是权威（和被拖窗同拍、比 WindowServer 的
     * 提交快一拍）；程序化搬窗刚落笔的抑制窗内 frame 是权威（那是 Core 自己写
     * 的目标值）；其余时候 WindowServer 是权威——外源移动时 frame 是旧值。 */
    if (win.drag_est_active) {
      frame = [win frame];
      frame.origin = win.drag_est_origin;
    } else if (win.move_suppress_until > [NSDate timeIntervalSinceReferenceDate]) {
      frame = [win frame];
    } else {
      frame = moonui_native_server_frame(win);
    }
    return moonui_native_pack_frame(win, frame);
  }
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

void moonui_native_window_set_drag_band(moonui_ptr w, int height) {
  TRACE("window_set_drag_band");
  /* mac 半是空操作：沉浸式窗的顶条由 AppKit 自己当标题栏区域放行拖拽
   * （fullSizeContentView 下 NSWindow 仍然认那一条），不需要我们报高度。
   * 留这条是为了 ABI 两侧同形——Weight 由 Core 统一下发，调用方不按平台分叉。 */
  (void)w;
  (void)height;
}

int moonui_native_window_drag_band(moonui_ptr w) {
  TRACE("window_drag_band");
  /* 与 setter 对称：mac 侧不记这条账，恒 0。 */
  (void)w;
  return 0;
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
  MoonuiWindow *win;
  TRACE("window_on_moved");
  win = (MoonuiWindow *)(uintptr_t)w;
  slot = moonui_native_take_slot((void *)(uintptr_t)w, fn, closure);
  if (slot < 0) {
    return -1;
  }
  win.moved_slot = slot;
  /* 登记当下位置：拖动期轮询的比较基准从这里起，不把"注册前就在那"当成位移。 */
  win.tracked_pos = moonui_native_window_position(w);
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

int moonui_native_quit_requested(void) {
  return moonui_native_loop_ended;
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

/* ---- 自定义绘制面（`T101`，§17 的 CustomWidget）----
 *
 * 一只空 view：它自己什么都不画——内容是 MoonBit 侧画成一张位图、present 到它的
 * layer 上的（`moonui_canvas_present_view`）。它存在的意义就三件：
 * 占住布局给的矩形、接住鼠标、当 layer 的宿主。
 *
 * `isFlipped` 打开：Core 的局部坐标是左上原点、y 向下（DrawList 的口径），
 * 让视图的坐标系与它同向，将来接悬停/拖动时不用再翻一次。
 *
 * 点击：按下并原地抬起才算一次（与 Button 的 momentaryPushIn 同一条判定），
 * 拖出去松手不算——与 AppKit 按钮的默认行为一致。这里不吞别的鼠标事件：
 * 拖动/滚轮的语义还没定（首版只到点击），宁可让它们照常往上传，也不假装
 * 已经支持了。 */
@interface MoonuiCustomView : NSView
/* 键盘焦点的 opt-in（`T102` 第十一刀）：默认 NO，由
 * moonui_native_custom_set_focusable 打开。 */
- (void)setFocusable:(BOOL)on;
@end

@implementation MoonuiCustomView {
  BOOL pressed;
  BOOL focusable;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    [self setWantsLayer:YES];
    pressed = NO;
    focusable = NO;
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)setFocusable:(BOOL)on {
  focusable = on;
}

/* 默认不抢焦点：自绘面还没有键盘语义时恒 YES 会把每块面塞进 Tab 链、还会在
 * 点击时从文本框手里抢走焦点。要键盘的面（`DataGrid`）经
 * moonui_native_custom_set_focusable 显式声明（`T102` 第十一刀）。 */
- (BOOL)acceptsFirstResponder {
  return focusable;
}

- (void)mouseDown:(NSEvent *)e {
  // 声明了要键盘的面：点一下就拿到焦点，于是后续 KeyDown 的 target 是它
  // 而不是窗口（进程级键盘监听按 firstResponder 反查归属）。
  if (focusable) {
    [[self window] makeFirstResponder:self];
  }
  pressed = YES;
  (void)e;
}

- (void)mouseUp:(NSEvent *)e {
  NSPoint p;
  if (!pressed) {
    return;
  }
  pressed = NO;
  p = [self convertPoint:[e locationInWindow] fromView:nil];
  if (!NSPointInRect(p, [self bounds])) {
    return;
  }
  if (moonui_native_dispatcher != nil) {
    [moonui_native_dispatcher dispatch:self];
  }
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
  /* `T90④`：多行的组合收尾同单行一条规矩（上屏/取消先松"结束"相位）。 */
  moonui_native_ime_end_if_composing((NSView *)self);
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
/// 已走过那段的颜色（皮肤通道的 fg，`T147②`）。只在**横排**时画：竖排的
/// fg 另有消费方（推子把手，见下），换掉会把均衡器那十根推子改样。
@property(nonatomic, strong) NSColor *fillPaint;
/// 是不是 Luna 那两条"横排自绘带"（`T147②`）：横排 **且** 两格色都给了。
/// 现算不存——朝向由 `setFrameSize:` 决定，存一份就得在每个改朝向的地方
/// 跟着改；颜色缺一格时自绘会画成黑块（槽色没有），所以两格都要求。
@property(nonatomic, readonly) BOOL selfDrawn;
/// 横排自绘时圆点的直径（`T147②`），单位点。槽高不存——它按"整高的三分之
/// 一夹在 3..10"现算，与 Windows 半 `moonui_native_slider_groove_h` 同一条。
@property(nonatomic, assign) CGFloat knobDiameter;
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

/* 横排自绘圆点的圆心（`T150`）：**系统那颗真拇指的圆心**，直接问
 * `NSSliderCell -knobRectFlipped:`——跟踪循环搬的就是这个框，圆心读它的中点
 * 就是"圆点永远在指针底下"。
 *
 * 原来这里按 `W * t` 画（两端夹半个圆点直径）。NSSlider 那把尺是拇指**左缘**
 * 走 `t * (W - knobThickness)`，两把尺只在 t = 0 / 0.5 / 1 重合，W=368 时中段
 * 最大差 10.5pt——"拖得越远圆点离指针越远"就是这条差：往左拖圆点偏左、往右拖
 * 偏右，离中心越远偏得越多。
 *
 * 为什么不按公式反算（`t * (W - kt) + kt / 2`）：AppKit 把拇指原点取整到整点，
 * 公式与真框之间有最多 0.25pt 的残差（W=368/64/193 逐千分位量过）。读框没有
 * 残差，也顺带把 `knobThickness` 在 small 控制尺寸下换成 20 这类细节一并吞掉。
 *
 * **但框只在拇指真的到位时才是"真位置"（`T157`）**：在轨道上点一下，AppKit 会把
 * 值**立刻**跳到点击处、再把拇指用约 270ms 的动画滑过去，`knobRectFlipped:` 在
 * 这整段里返回的是**动画途中**那个框。我们的重画只有 action 那一帧（之后没有任何
 * 人再标脏，见 `sliderMoved:`），照框画就等于把圆点钉在动画的中途——观感正是
 * owner 报的"点一下只走一部分，鼠标再动一下才走到点击处"（鼠标一动又是一颗
 * action，那一帧框已经落定，于是"恢复正常"）。
 *
 * 所以加一道一致性闸：框与按值算的位置相差 ≤1pt 才认框（稳态实测 ≤0.25pt，
 * 动画途中相差可以到一整个行程）。不认框时**按值画**——值在点下去那一刻就是
 * 终点，圆点于是当场落在点击处，不再追那段看不见的动画。动画收尾后两者重新
 * 吻合，自动切回读框，稳态的精确性一分不丢。
 *
 * 抽出来是为了让 `drawRect:`、探针 `slider_knob_probe` 与
 * `slider_click_probe` 用同一份取值：前一条拿它与真框对差，后一条拿它与指针
 * 对差，圆点再漂一次或再被动画带跑都会立刻红。
 *
 * 返回 YES = 有拇指框可对（`*out` 已写，可能是框也可能是按值算的位置）；
 * NO = cell 拿不到或框为空，`*out` 是按值算的兜底。 */
static BOOL moonui_native_slider_knob_cx(NSSlider *inner, CGFloat width,
                                         double t, CGFloat d, CGFloat *out) {
  NSSliderCell *cell;
  NSRect kr;
  double kt;
  CGFloat by_value;
  if (out == NULL) {
    return NO;
  }
  cell = inner != nil ? (NSSliderCell *)[inner cell] : nil;
  kt = cell != nil ? (double)[cell knobThickness] : 0.0;
  /* 按值算：拇指左缘走 `t * (W - kt)`，圆心再让半个拇指宽（与 T150 那条
   * 反算同一把尺）。kt 拿不到或比整条还宽时退回 `W * t`。 */
  if (kt > 0.0 && kt < (double)width) {
    by_value = (CGFloat)(kt / 2.0 + t * ((double)width - kt));
  } else {
    by_value = (CGFloat)((double)width * t);
  }
  if (by_value < d / 2.0) {
    by_value = d / 2.0;
  }
  if (by_value > (CGFloat)width - d / 2.0) {
    by_value = (CGFloat)width - d / 2.0;
  }
  if (cell != nil) {
    kr = [cell knobRectFlipped:YES];
    if (kr.size.width > 0.0 && NSMidX(kr) >= 0.0 &&
        NSMidX(kr) <= width + kr.size.width) {
      if ((CGFloat)fabs((double)NSMidX(kr) - (double)by_value) <= 1.0) {
        *out = NSMidX(kr);
        return YES;
      }
      /* 拇指还在动画途中：框是途中值，按值画（注释见上）。 */
      *out = by_value;
      return YES;
    }
  }
  *out = by_value;
  return NO;
}

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
/// 横排自绘的判据（`T147②`）：横排、槽色与填充色都在。缺槽色就画不出一条
/// 槽（整块底没有颜色），缺填充色就只知道"画到哪"不知道"用什么画"，两种
/// 都不该进自绘分支——退回 AppKit 那套，界面最多是原来的样子，不会是黑块。
- (BOOL)selfDrawn {
  return !self.vertical && self.groovePaint != nil && self.fillPaint != nil;
}

///|
/// 槽色（皮肤通道的 bg 走到这里）。只记颜色 + 标脏，画在下面的 drawRect 里
/// ——没有颜色时用一层很淡的白（setFrameSize 兜底），任何深色底上都读得出来。
- (void)setGrooveColor:(NSColor *)color {
  self.groovePaint = color;
  [self setNeedsDisplay:YES];
}

///|
/// 填充色（`T147②`，横排自绘的"已走过"那段）。置位即表示这条滑块要按 Luna
/// 的带子画：圆角槽 + 填充 + 圆点，系统拇指一并盖掉。
- (void)setFillColor:(NSColor *)color {
  self.fillPaint = color;
  /* 立刻重摆一次内层：`selfDrawn` 翻面会改"系统拇指要不要盖掉"，而
   * `set_widget_style` 里 `setThumbColor:` 排在前面、那一刻自绘还没开，
   * 留给它的话系统那颗大圆钮会一直画在自绘的胶囊槽上面（`T147②`）。 */
  [self updateThumb];
  [self setNeedsDisplay:YES];
}

///|
/// 画槽：竖排时居中一条 6pt 宽的圆角竖条，上下各留 6pt。横排不画（交回
/// 系统那套细轨道）。
- (void)drawRect:(NSRect)dirty {
  NSRect b;
  NSRect r;
  [super drawRect:dirty];
  b = [self bounds];
  /* 横排自绘（`T147②`）：整条槽铺满宽度、两端做成半圆（半径 = 槽高/2，
   * 就是 CSS 的胶囊形），已走过那段同形覆盖在左端，末端压一颗圆点。
   *
   * 为什么横排也得自己画：`T146` 那条带的画面是 Core 用 46 颗定宽 Panel 拼
   * 出来的方块行，Panel 的 radius 是**圆角矩形**，拼起来两端仍是直角；而且
   * Core 的重排只在 `App::step` 里跑，拖动期间 `NSSlider` 的模态跟踪循环把
   * step 堵住，圆点只能等松手才跳一次——"一段一段"的真正来源。C 这层在拖动
   * 的每一颗 mouseDragged 上同步重画，跟手是一条连续的。 */
  if (self.selfDrawn) {
    CGFloat gh;
    CGFloat cy;
    CGFloat cx;
    CGFloat filled;
    CGFloat d;
    double lo, hi, v, t;
    /* 整块先铺底（`T147②`）：底 = 所在条带的底色。与 Windows 半
     * `moonui_native_slider_paint` 第一段同一件事——那里必须铺，否则 Core 那排
     * 方块从滑块底下露出来；mac 原来靠 `alpha 0.01` 让方块透出来，现在画面
     * 改由这一层画，方块就得压掉，不然同一根条上叠两份进度。 */
    [self.groovePaint setFill];
    NSRectFill(b);
    /* 槽高与 Windows 同一条规则：整高的三分之一，夹在 3..10。 */
    gh = b.size.height / 3.0;
    if (gh < 3.0) {
      gh = 3.0;
    }
    if (gh > 10.0) {
      gh = 10.0;
    }
    r = NSMakeRect(0.0, (b.size.height - gh) / 2.0, b.size.width, gh);
    [[self.groovePaint blendedColorWithFraction:0.30
                                        ofColor:[NSColor blackColor]] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r
                                     xRadius:gh / 2.0
                                     yRadius:gh / 2.0] fill];
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
    /* 圆点圆心 = 系统那颗真拇指的圆心（`T150`，算法在
     * `moonui_native_slider_knob_cx` 里，探针 `slider_knob_probe` 拿同一份
     * 对账）。填充段跟着圆心走：两端的整段仍要满，中间那截画到圆心为止。 */
    d = self.knobDiameter > 0.0 ? self.knobDiameter : 12.0;
    if (d > b.size.height) {
      d = b.size.height;
    }
    if (moonui_native_slider_knob_cx(self.inner, b.size.width, t, d, &cx)) {
      /* 锚在真拇指上：填充画到圆心为止（拇指压在上面，接缝看不见），两端
       * 的整段仍要满——0 时不留、1 时铺满。 */
      if (t <= 0.0) {
        filled = 0.0;
      } else if (t >= 1.0) {
        filled = b.size.width;
      } else {
        filled = cx;
      }
    } else {
      filled = b.size.width * t;
    }
    if (filled > 0.0 && self.fillPaint != nil) {
      NSRect fr = NSMakeRect(0.0, r.origin.y, filled, gh);
      [self.fillPaint setFill];
      [[NSBezierPath bezierPathWithRoundedRect:fr
                                       xRadius:gh / 2.0
                                       yRadius:gh / 2.0] fill];
    }
    /* 圆点：直径 12pt（与 `ui_playbar.mbt` 的 `knob_d = 12.0` 是同一个数，
     * 两处必须一起改）。圆心 `cx` 已在上面按真拇指算好。 */
    cy = b.size.height / 2.0;
    [[self.groovePaint blendedColorWithFraction:0.88
                                        ofColor:[NSColor colorWithSRGBRed:0.949
                                                                   green:0.965
                                                                    blue:1.0
                                                                   alpha:1.0]]
        setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - d / 2.0,
                                                       cy - d / 2.0, d,
                                                       d)] fill];
    return;
  }
  if (!self.vertical || self.groovePaint == nil) {
    return;
  }
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
   * 横排自绘（`T147②`）：整颗都盖掉——系统那套细轨道 + 大圆钮会画在自绘的
   * 胶囊槽上面。没开自绘的横排滑块原样交给 AppKit，别把别人家的画没了。 */
  [self.inner setAlphaValue:((self.vertical || self.selfDrawn) ? 0.0 : 1.0)];
  if (self.thumb == nil || !self.vertical) {
    /* 横排自绘的圆点在 drawRect 里画，值一变就得重画一次——拖动期间每一颗
     * mouseDragged 都会走到这儿（`T147③` 开了连续动作）。
     *
     * 光标脏不够：整段拖动跑在 `NSSlider` 自己的模态跟踪循环里，标脏要等它
     * 把控制权交回 runloop 才落笔，那已经是松手之后——"一段一段"的另一个
     * 来源。这里直接要求本帧画完，跟手才落在每一颗 mouseDragged 上。 */
    if (self.selfDrawn) {
      [self setNeedsDisplay:YES];
      [self displayIfNeeded];
    }
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
    /* 把窗口的脏区就地画掉。两件事缺一不可，各自管一半：
     *
     * ① **事件到得了**：滑块 `Change` 走实时直达（`T149`，Core 侧
     *    `NativeBackend::push_value_change`）——入队的话整段拖动一条都派发不
     *    出去，`App::step` 被这条跟踪循环卡着；
     * ② **画得出来**：`fire` 之后兄弟视图（音量百分比那种跟着读数走的标签）
     *    已经被 `setStringValue:` 改了、也标了脏，但整段拖动跑在 `NSSlider`
     *    自己的模态跟踪循环里，循环只重画它自己——标脏要等控制权交回 runloop
     *    才落笔，那已是松手之后，观感还是"数值不实时变"。上面 `updateThumb`
     *    那颗 `displayIfNeeded` 只画宿主自己，管不到兄弟视图。
     *
     * 必须排在 fire 之后：读数是槽里那段 Core 代码改的。`-displayIfNeeded`
     * 是直调，跟 runloop 模式无关，跟踪循环里照样落笔。 */
    {
      NSView *content = [[self window] contentView];
      if (content != nil) {
        [content displayIfNeeded];
      }
    }
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
      /* 连续动作也跟着搬（`T147③`）：重建出来的这颗默认还是 NO，漏了就退回
       * "松手才跳一次"。 */
      [s setContinuous:[old isContinuous]];
    } else {
      [s setContinuous:YES];
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
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    /* `T90④`：组合相位的触发点（取样时机的理由见文件末尾的 derive）——全局只
     * 收一次，object 传 nil（每只文本视图的 textStorage 各不相同，逐只注册反而
     * 要配对注销）；handler 里再按 `-[NSTextView delegate]` 认回我们的控件，
     * 不是我们的（菜单搜索框之类）kind 白名单自己会挡掉。 */
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(textViewSelectionChanged:)
               name:NSTextViewDidChangeSelectionNotification
             object:nil];
  }
  return self;
}

/* 选择区变了（含输入法设置标记区间那一刻）：重新推一次组合相位。
 * `T90④` 之前这条推导挂在 `controlTextDidChange:` 上——实测输入法组合进行中
 * 那个回调根本不发（`setMarkedText:` 只改文本存储、不发 didChangeText），只有
 * 上屏那一下才来，而那时标记区间已经清掉，于是整条相位链一个事件都不产。 */
/* 0 延迟定时器的落点：把待定的"结束"相结掉（判定见文件末尾的 flush）。 */
- (void)flushImePending:(id)unused {
  (void)unused;
  moonui_native_ime_flush_pending();
}

- (void)textViewSelectionChanged:(NSNotification *)note {
  id view = [note object];
  id owner;
  if (![view isKindOfClass:[NSTextView class]]) {
    return;
  }
  owner = [(NSTextView *)view delegate];
  if ([owner isKindOfClass:[NSView class]]) {
    moonui_native_ime_derive((NSView *)owner);
  }
}

- (void)dispatch:(id)sender {
  int slot = moonui_native_widget_slot_of((NSView *)sender);
  /* `T128`：点出来的 action 先把键盘焦点带过来再 fire。AppKit 对按钮这类
   * action 控件**点击时不改 firstResponder**（只有文本框那类编辑控件才在
   * 点击时接管），于是焦点永远留在旧控件上——owner 那笔"切页签后焦点还在
   * 前一个 tab"就是这么来的：切页签改成原地换值（不再整树重建）后，旧按钮
   * 一直活着、焦点也就一直赖在那儿。Windows 半没有这个问题：BUTTON 创建就
   * 带 WS_TABSTOP，按下的那一刻系统替它 SetFocus。这里对齐那条语义：被点的
   * 控件收得了焦点（acceptsFirstResponder）就先 makeFirstResponder。放在
   * fire **之前**——回调若拆树重建，焦点随控件销毁自动让位，不会把一只将死
   * 的 view 立成响应者。文本框不走这条（改字走 controlTextDidChange:，
   * Enter 的 action 也只在已是响应者时才有意义），不受影响；收不了焦点的
   * 控件（自绘面没声明 focusable）acceptsFirstResponder 回 NO，原样绕开。 */
  if (slot >= 0 && [sender isKindOfClass:[NSView class]]) {
    NSView *v = (NSView *)sender;
    NSWindow *win = [v window];
    if (win != nil && [win firstResponder] != (NSResponder *)v &&
        [v acceptsFirstResponder]) {
      [win makeFirstResponder:v];
    }
  }
  if (slot >= 0) {
    moonui_native_fire(&moonui_native_slots[slot]);
  }
}

- (void)controlTextDidChange:(NSNotification *)note {
  int slot = moonui_native_widget_slot_of((NSView *)note.object);
  /* `T90④`：文本真的变了 = 这次组合收尾（上屏或取消先松"结束"相位）；
   * 组合**进行中**这个回调根本不发，别再想从这里推相位（见 derive 的注）。 */
  moonui_native_ime_end_if_composing((NSView *)note.object);
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
      case 18: {
        /* 自定义绘制面（`T101`）：空 view + layer，内容由 present 贴上来。 */
        v = [[MoonuiCustomView alloc] init];
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
 *   bezel 改为 layer 平面底（常见音乐客户端那类"平面按钮"的形状）。
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
      /* 图标契约的守卫（`T130`）：上面 setAttributedTitle: 一落地，AppKit 就把
       * imagePosition 从 NSImageOnly(1) 悄悄重置回 NSImageOverlaps(6)（真窗取证：
       * set_icon 装好 pos=1，下一次样式下发读回 pos=6，emoji 浮在 SF Symbol
       * 上面、两套字形错位叠画）。契约是"装了图就只画图"（set_icon 的注释），
       * 每次动过标题都得重申。图标前景同账：SF Symbol 是模板图，不给
       * contentTintColor 会按默认控制文字色画成深色、压在皮肤底上（lunamusic
       * 模式钮那颗暗箭头）。 */
      if ([btn image] != nil) {
        [btn setImagePosition:NSImageOnly];
        if (color != nil) {
          [btn setContentTintColor:color];
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
        /* 横排自绘的填充色（`T147②`）：fg 同时是"已走过那段"的颜色。竖排时
         * 自绘判据 `selfDrawn` 现算是假，这根色一个像素都不画——均衡器那十
         * 根推子的外观一点不变。这里不按朝向分支：`set_widget_style` 可能在
         * 布局定朝向之前就跑（建树时先推样式、后 `setFrameSize:`），那一刻
         * `vertical` 还是默认的假，"只在横排才喂"就会把进度/音量条的填充色
         * 整条漏掉。 */
        if (fg_rgb >= 0) {
          [host setFillColor:moonui_native_srgb_color(fg_rgb)];
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
    /* 图标前景立刻跟上（`T130`）：取此刻 attributed title 的前景色当 tint。
     * 样式还没下发过就没有（nil = 系统默认，与文字同档）。之后每次样式下发
     * （set_style 那处的守卫）把 tint 追上新文字色，两条合起来让"图标跟着
     * 皮肤走"与调用顺序无关。 */
    /* length 门：空标题的 attributedTitle 上 atIndex:0 直接 NSRangeException
     * （lunamusic 的模式钮就是空标题建出来的）。 */
    NSAttributedString *at = [btn attributedTitle];
    if ([at length] > 0) {
      NSColor *title_color = [at attribute:NSForegroundColorAttributeName
                                   atIndex:0
                            effectiveRange:nil];
      if (title_color != nil) {
        [btn setContentTintColor:title_color];
      }
    }
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

/* `T91⑤` 的探针：这张图真装进去了吗、像素多大。读 NSImageView.image 的各
 * rep，取宽高最大那份（多 rep 的图——比如带 @2x 的——按最大那份报，和
 * "文件里那一格的像素尺寸"是同一件事）。打包见 adapter.h。 */
int64_t moonui_native_image_probe(moonui_ptr c) {
  NSImageView *iv;
  NSImage *img;
  int64_t w = 0;
  int64_t h = 0;
  TRACE("image_probe");
  iv = (NSImageView *)(uintptr_t)c;
  if (iv == nil || moonui_native_widget_kind_of((NSView *)(uintptr_t)c) != 16) {
    return -1;
  }
  @autoreleasepool {
    img = [iv image];
    if (img == nil) {
      return 0;
    }
    for (NSImageRep *rep in [img representations]) {
      if ((int64_t)[rep pixelsWide] > w) {
        w = (int64_t)[rep pixelsWide];
      }
      if ((int64_t)[rep pixelsHigh] > h) {
        h = (int64_t)[rep pixelsHigh];
      }
    }
  }
  return (int64_t)1 | (w << 8) | (h << 32);
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
        [(NSTextField *)(uintptr_t)c setStringValue:t];
        break;
      case 2: /* TextInput */
      case 4: /* PasswordInput */
        /* 组合中要保留组合（`T90⑤`）：编辑视图在 field editor 上，这一段
         * 文本同时是输入法的落脚点，直接 setStringValue 会把它清掉。 */
        if (!moonui_native_ime_replace_keeping_compose(
                moonui_native_ime_editor_of((NSView *)(uintptr_t)c, kind), t)) {
          [(NSTextField *)(uintptr_t)c setStringValue:t];
        }
        break;
      case 1: /* Button */
      case 3: /* Checkbox */
      case 14: /* MenuRow */
        [(NSButton *)(uintptr_t)c setTitle:t];
        /* setTitle: 和 setAttributedTitle: 一样会把 imagePosition 从
         * NSImageOnly 重置成 NSImageOverlaps（`T130`，与 set_style 那处同一
         * 契约守卫）：refresh_bar 每次换图标都 set_text + set_icon 成对调用，
         * 不重申的话装好的图又被文字盖住。装图的只有 Button（set_icon 的
         * kind 门在这），Checkbox 的系统勾形走 cell 不走 image。 */
        if (kind == 1 && [(NSButton *)(uintptr_t)c image] != nil) {
          [(NSButton *)(uintptr_t)c setImagePosition:NSImageOnly];
        }
        break;
      case 10: /* MultilineEntry */
        if (!moonui_native_ime_replace_keeping_compose(
                [(MoonuiMultiline *)(uintptr_t)c textView], t)) {
          [(NSTextView *)[((MoonuiMultiline *)(uintptr_t)c) documentView]
              setString:t];
        }
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

/* 自定义绘制面的点击（`T101`）：不走 wire_action——那不是 NSControl，没有
 * target/action 可用。槽位照样记在 view 身上，事件源是 MoonuiCustomView 的
 * `mouseUp:`（按下并原地抬起才算），派发经同一个分发器（`dispatch:` 读槽位）。 */
int moonui_native_custom_on_clicked(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  NSView *v;
  int slot;
  TRACE("custom_on_clicked");
  v = (NSView *)(uintptr_t)c;
  if (v == nil) {
    return -1;
  }
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_widget_slot(v, slot);
  return 0;
}

/* 自绘面的焦点 opt-in（`T102` 第十一刀）：只对 MoonuiCustomView 生效——别的
 * 控件走自己的原生焦点语义，不归这条管，按 Core 的契约**空操作**（返回 0，
 * 不报错）。句柄为空是调用方的错，报 -1。 */
int moonui_native_custom_set_focusable(moonui_ptr c, int on) {
  MoonuiCustomView *v;
  TRACE("custom_set_focusable");
  v = (MoonuiCustomView *)(uintptr_t)c;
  if (v == nil) {
    return -1;
  }
  if (![v isKindOfClass:[MoonuiCustomView class]]) {
    return 0;
  }
  [v setFocusable:(on != 0)];
  return 0;
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
    /* 横排自绘的圆点直径（`T147②`）：12pt，与 Windows 半那颗 12 是同一个数
     * ——`ui_playbar.mbt` 的 `knob_d = 12.0` 也要一起改。 */
    host.knobDiameter = 12.0;
    [host addSubview:s];
    host.inner = s;
    host.vertical = NO;
    /* 连续动作（`T147③`）：NSSlider 默认 `isContinuous = NO`，拖动期间只在
     * **松手**时发一次 action——落点前的每一步都看不见，观感就是"一段一段
     * 地跳"。开了之后每一颗 mouseDragged 都发，填充与圆点逐帧跟手。
     * 这是所有用滑块的界面的行为改动；本框架里滑块的 action 只换读数值与
     * 写引擎参数，多发几次是幂等的（`set_volume`/`seek` 都只是赋值）。 */
    [s setContinuous:YES];
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
  /* 初始响应者落在链首。没 opt-in 的自绘面会**当场拒绝**（acceptsFirstResponder
   * 回 NO，`T102` 第十一刀），AppKit 于是沿这个环继续找第一个肯接受的——固
   * 决不必在这里另做过滤，环本身已经把"没有键盘语义的面"跳过去了。 */
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

/* ---- 默认菜单（`T129`）：应用菜单（退出 ⌘Q）+ 编辑菜单（标准动作）----
 *
 * owner 要的"mac 应用开箱即得常用快捷键"。init 时预装两组，应用一行不写也
 * 有 ⌘Q/⌘Z/⌘X/⌘C/⌘V/⌘A。两条设计决定：
 *
 * ①编辑那组用**标准 selector + 空 target**（responder 链），不走我们的
 * target-action：⌘C/⌘V 对文本框生效的唯一形状就是这条——NSTextField 借共享
 * field editor 接管键盘，firstResponder 是那只 NSTextView，copy:/paste:/
 * selectAll: 由它实现。走我们的 dispatch: 反而要另做一份"读选区/写内容"。
 * 空 target 的自动置灰也白拿：AppKit 的 validateMenuItem: 会按 firstResponder
 * 认领与否自动起用/置灰，没焦点时这些项自然灰着。
 *
 * ②与 `set_menu_bar` 的关系是**合并**而不是替换（Tauri/Electron 是替换）：
 * 应用树排在前面、默认两组挪到末尾。同一个组合两边都有时，AppKit 与认领检查
 * （moonui_native_menu_claims）都按主菜单顺序走，应用自己的项先命中——
 * 应用的语义赢，没声明的那份兜底还在。这也是 `T96` 的断言（⌘Q 归应用菜单
 * 那条 MenuSelect）不被默认「退出」咬掉的原因。
 *
 * 退出那项不走 Core 的菜单 target-action（tag 查表认不出它，Core 也没给它
 * 发过 id），自己一个小 target 直呼 moonui_native_quit——与"应用层请求退出"
 * 同一落点：只把循环标成跑完，收尾仍归 MoonBit 侧 terminate。
 *
 * dump 与 menu_click_item 都不受影响：dump 只读 moonui_native_menu_items
 * 名单里的顶（containsObject 过滤），默认两顶不在名单上。 */

@interface MoonuiDefaultQuitTarget : NSObject
- (void)quitClicked:(id)sender;
@end

@implementation MoonuiDefaultQuitTarget
- (void)quitClicked:(id)sender {
  (void)sender;
  moonui_native_quit();
}
@end

static NSMutableArray *moonui_native_default_tops = nil;
/* 退出那项的 target：进程级 +1 永不释放（与 moonui_native_menu_target 同一规矩）。 */
static MoonuiDefaultQuitTarget *moonui_native_default_quit_target_static = nil;

static NSMenuItem *moonui_native_default_std_item(NSString *title,
                                                  SEL action,
                                                  NSString *equiv,
                                                  NSUInteger mask) {
  NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                 action:action
                                          keyEquivalent:equiv]
      autorelease];
  /* target 留 nil = 走 responder 链（见上①）。 */
  [item setKeyEquivalentModifierMask:mask];
  return item;
}

static void moonui_native_default_menus_remove(void) {
  NSMenu *main_menu;
  if (moonui_native_default_tops == nil) {
    return;
  }
  main_menu = [NSApp mainMenu];
  if (main_menu != nil) {
    for (NSMenuItem *top in moonui_native_default_tops) {
      /* removeItem: 对不在菜单里的项是抛异常不是忽略，先问再摘（与
       * moonui_native_menu_clear 同一套防）。 */
      if ([main_menu indexOfItem:top] >= 0) {
        [main_menu removeItem:top];
      }
    }
  }
  [moonui_native_default_tops removeAllObjects];
}

static void moonui_native_default_menus_install(void) {
  NSMenu *main_menu;
  NSString *app_name;
  NSMenu *app_menu;
  NSMenu *edit_menu;
  NSMenuItem *top;
  NSMenuItem *quit;
  main_menu = [NSApp mainMenu];
  if (main_menu == nil) {
    return;
  }
  if (moonui_native_default_tops == nil) {
    moonui_native_default_tops = [[NSMutableArray alloc] init];
  }
  if ([moonui_native_default_tops count] > 0) {
    return; /* 已装（重复 init），幂等。 */
  }
  app_name = [[NSProcessInfo processInfo] processName];
  if (app_name == nil || [app_name length] == 0) {
    app_name = @"应用";
  }
  /* 「应用」菜单：只有退出一项。菜单名用进程名——mac 惯例第一顶是应用自己。 */
  app_menu = [[NSMenu alloc] initWithTitle:app_name];
  quit = [[[NSMenuItem alloc]
      initWithTitle:[NSString stringWithFormat:@"退出 %@", app_name]
             action:@selector(quitClicked:)
      keyEquivalent:@"q"] autorelease];
  if (moonui_native_default_quit_target_static == nil) {
    /* 进程级 +1 永不释放，与 moonui_native_menu_target 同一规矩。 */
    moonui_native_default_quit_target_static =
        [[MoonuiDefaultQuitTarget alloc] init];
  }
  [quit setTarget:moonui_native_default_quit_target_static];
  [app_menu addItem:quit];
  top = [[[NSMenuItem alloc] initWithTitle:app_name
                                    action:NULL
                             keyEquivalent:@""] autorelease];
  [top setSubmenu:app_menu];
  [app_menu release]; /* addItem: 时 submenu 被 retain，这里松自己的那份 */
  [moonui_native_default_tops addObject:top];
  /* 「编辑」菜单：标准动作全走 responder 链。重做是 ⇧⌘Z（mask 带 Shift）。 */
  edit_menu = [[NSMenu alloc] initWithTitle:@"编辑"];
  [edit_menu addItem:moonui_native_default_std_item(
                           @"撤销", @selector(undo:), @"z",
                           NSEventModifierFlagCommand)];
  [edit_menu addItem:moonui_native_default_std_item(
                           @"重做", @selector(redo:), @"Z",
                           (NSEventModifierFlagCommand |
                            NSEventModifierFlagShift))];
  [edit_menu addItem:[NSMenuItem separatorItem]];
  [edit_menu addItem:moonui_native_default_std_item(
                           @"剪切", @selector(cut:), @"x",
                           NSEventModifierFlagCommand)];
  [edit_menu addItem:moonui_native_default_std_item(
                           @"复制", @selector(copy:), @"c",
                           NSEventModifierFlagCommand)];
  [edit_menu addItem:moonui_native_default_std_item(
                           @"粘贴", @selector(paste:), @"v",
                           NSEventModifierFlagCommand)];
  [edit_menu addItem:moonui_native_default_std_item(
                           @"全选", @selector(selectAll:), @"a",
                           NSEventModifierFlagCommand)];
  top = [[[NSMenuItem alloc] initWithTitle:@"编辑"
                                    action:NULL
                             keyEquivalent:@""] autorelease];
  [top setSubmenu:edit_menu];
  [edit_menu release];
  [moonui_native_default_tops addObject:top];
  for (NSMenuItem *t in moonui_native_default_tops) {
    [main_menu addItem:t];
  }
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
    /* `T129`：默认两顶挪到树末尾（应用自己的项先被认领/命中，默认的兜底）。
     * remove 幂等（没装过就空转），装回也幂等（数组还在就原样挂）。 */
    moonui_native_default_menus_remove();
    moonui_native_default_menus_install();
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

/* 上一轮发出的组合串（按控件记）：一次 setMarkedText 会带出两轮选择区通知，
 * 第二轮的串与第一轮相同，是同一条相位的回声，靠它压掉。 */
static const void *const moonui_native_ime_last_key = &moonui_native_ime_last_key;

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

/* 组合相位从文本视图的标记串推（`NSTextView.markedRange` 已编译查证）。
 *
 * **触发点是选择区通知，不是文本变化通知**（`T90④` 真跑咬出）：输入法调
 * `-[NSTextView setMarkedText:selectedRange:replacementRange:]` 时，字符先落进
 * 文本存储、标记区间后设，中间会发两轮 NSTextStorage 编辑通知与两轮选择区通知；
 * 编辑那一轮读到的 `markedRange` 还是**上一轮**的值（首轮读到 NSNotFound），
 * 而选择区通知的最后一轮读到的是新值。所以挂在编辑/文本变化上会整段漏掉组合
 * （`controlTextDidChange:` 在组合进行中根本不发——实测），挂在选择区通知上
 * 才拿到"当下"的标记状态。
 *
 * 覆盖单行文本框（kind 2/4，编辑走共享 field editor）与多行文本域（kind 10，
 * 编辑走容器自己的 NSTextView）：`-[NSTextView delegate]` 在两种情形下都指回
 * 我们的控件/容器（field editor 的 delegate 就是被编辑的 NSTextField），派发器
 * 靠它认人，不另存映射。
 *
 * 纯打字（前后都不在组合中）不产相位事件；从无到有的切换沿先发"开始"（不带串）
 * 再发"进行"（带当下的标记串）——一次切换发两条相位，序列与 Win32 半的
 * START→COMPSTR₁ 对齐，两边的事件计数一致（`T85②`）。同一串不重复发"进行"：
 * 一次 setMarkedText 带两轮选择区通知，第二条是回声。 */
static NSTextView *moonui_native_ime_editor_of(NSView *control, int kind) {
  NSWindow *win;
  if (kind == 10) {
    /* 多行文本域的编辑视图是容器自己的 NSTextView（documentView），不走
     * field editor——`T90④` 补的那一半。 */
    return [(MoonuiMultiline *)control textView];
  }
  win = [control window];
  return win != nil ? (NSTextView *)[win fieldEditor:NO forObject:control] : nil;
}

static BOOL moonui_native_ime_same_as_last(NSView *v, NSString *s) {
  NSString *last = (NSString *)objc_getAssociatedObject(v, moonui_native_ime_last_key);
  if (last != nil && [last isEqualToString:s]) {
    return YES;
  }
  objc_setAssociatedObject(v, moonui_native_ime_last_key, s,
                           OBJC_ASSOCIATION_RETAIN);
  return NO;
}

static void moonui_native_ime_derive(NSView *control) {
  int kind = moonui_native_widget_kind_of(control);
  NSTextView *editor;
  NSRange marked;
  NSUInteger len;
  NSString *now;
  BOOL composing;
  BOOL prev;
  if (moonui_native_ime_fn == 0 ||
      (kind != 2 && kind != 4 && kind != 10)) {
    return;
  }
  editor = moonui_native_ime_editor_of(control, kind);
  if (editor == nil) {
    return;
  }
  marked = [editor markedRange];
  len = [[editor string] length];
  composing = marked.location != NSNotFound && marked.length > 0 &&
              NSMaxRange(marked) <= len;
  prev = moonui_native_ime_prev_of(control);
  if (composing == prev) {
    if (composing) {
      /* 组合中且串变了（同串的两轮通知只发一次） */
      now = [[editor string] substringWithRange:marked];
      if (!moonui_native_ime_same_as_last(control, now)) {
        moonui_native_ime_notify(control, 1, now);
      }
    }
    return;
  }
  if (composing) {
    /* 从无到有：开始 + 进行（两条相位，串跟在后一条上） */
    moonui_native_ime_notify(control, 0, nil);
    now = [[editor string] substringWithRange:marked];
    moonui_native_ime_same_as_last(control, now);
    moonui_native_ime_notify(control, 1, now);
    moonui_native_ime_mark_prev(control, YES);
  }
  /* `composing == false && prev == true` 这一格**什么都不发**：输入法替换标记串
   * 时会先 `unmarkText` 再设新的，中间那一刻标记区间是空的——照"从有到无"发
   * 结束，就会在每一步组合之间插一条假的 end（`T90④` 真跑咬出）。真正的结束
   * （上屏/取消）一定伴随文本变化，由 `controlTextDidChange:` / 多行容器的
   * `textDidChange:` 调 `moonui_native_ime_end_if_composing` 推，见那两处。 */
}

/* 当下是否在组合中（与 derive 里那套判据同一把尺）。 */
static BOOL moonui_native_ime_composing_now(NSView *control) {
  int kind = moonui_native_widget_kind_of(control);
  NSTextView *editor;
  NSRange marked;
  if (kind != 2 && kind != 4 && kind != 10) {
    return NO;
  }
  editor = moonui_native_ime_editor_of(control, kind);
  if (editor == nil) {
    return NO;
  }
  marked = [editor markedRange];
  return marked.location != NSNotFound && marked.length > 0 &&
         NSMaxRange(marked) <= [[editor string] length];
}

/* 组合中程序化改文本（`T90⑤`）：直接 `setString:` 会把标记区间一起清掉——
 * 输入法脚下的文本被整段换走，表现成 Core 收到一条 end、组合串凭空消失。
 * 这里先把标记串取出来，写新文本后再原样标回去：相位那边因为"同串去重"
 * 一条事件都不发，键盘/候选窗口那边组合与正文都还在原处。
 *
 * 没有组合、或标记区间不成立时返回 NO，调用方走老路（本来就是普通赋值）。
 * 标记串为空（`marked.length == 0`）也算没有组合：那等于输入法已经撤了，
 * 此时照常写文本、让待定那一拍把 end 补上，是对的。 */
static BOOL moonui_native_ime_replace_keeping_compose(NSTextView *editor,
                                                     NSString *t) {
  NSRange marked;
  NSUInteger len;
  NSString *compose;
  if (editor == nil) {
    return NO;
  }
  marked = [editor markedRange];
  len = [[editor string] length];
  if (marked.location == NSNotFound || marked.length == 0 ||
      NSMaxRange(marked) > len) {
    return NO;
  }
  compose = [[[editor string] substringWithRange:marked] retain];
  [editor setString:t];
  [editor setMarkedText:compose
          selectedRange:NSMakeRange([compose length], 0)
       replacementRange:NSMakeRange(NSNotFound, 0)];
  [compose release];
  return YES;
}

/* "结束"相的待定队列（`T90④`）：文本变化通知里**不能当场发结束**——输入法替换
 * 标记串时会先 unmark 再设新的，中间照样触发一次文本变化，当场发就会在每一步
 * 组合之间插一条假 end（真跑咬出）。所以这里只记一笔，等下一拍再看：那一刻若
 * 标记区间已经回来了，说明只是替换、丢掉；仍没有标记才是真的上屏或取消。
 *
 * 结算只走一次 0 延迟的 runloop 定时器，**不在同一批通知里结**：`setMarkedText:`
 * 内部先 `unmarkText`（这一步就算一次文本变化），再换文本、最后才设标记区间，
 * 同一批通知里读到的永远是"还没标回来"的中间态（`T90④` 真跑咬出：在 derive 里
 * 抢先结算会稳定地插一条假 end）。到下一拍时这一批已经跑完，标记区间在不在就是
 * 确定的事实。定时器靠 `nextEventMatchingMask:` 推进（实测取事件时会跑 0 延迟
 * 定时器），测试的 step 循环正好推它。 */
#define MOONUI_IME_PENDING_MAX 4
static NSView *moonui_native_ime_pending[MOONUI_IME_PENDING_MAX];
static int moonui_native_ime_pending_n = 0;

static void moonui_native_ime_mark_pending(NSView *control) {
  int i;
  for (i = 0; i < moonui_native_ime_pending_n; ++i) {
    if (moonui_native_ime_pending[i] == control) {
      return;
    }
  }
  if (moonui_native_ime_pending_n < MOONUI_IME_PENDING_MAX) {
    moonui_native_ime_pending[moonui_native_ime_pending_n++] = control;
  }
}

static void moonui_native_ime_flush_pending(void) {
  NSView *queue[MOONUI_IME_PENDING_MAX];
  int n = moonui_native_ime_pending_n;
  int i;
  for (i = 0; i < n; ++i) {
    queue[i] = moonui_native_ime_pending[i];
  }
  moonui_native_ime_pending_n = 0;
  for (i = 0; i < n; ++i) {
    NSView *control = queue[i];
    if (moonui_native_ime_fn == 0) {
      return;
    }
    /* 控件已销毁：指针不再可信，直接丢（不碰对象）。 */
    if (moonui_native_live_widgets == nil ||
        ![moonui_native_live_widgets containsObject:control]) {
      continue;
    }
    if (!moonui_native_ime_prev_of(control)) {
      continue;
    }
    /* 标记区间回来了 = 这次只是替换标记串，组合还在。 */
    if (moonui_native_ime_composing_now(control)) {
      continue;
    }
    moonui_native_ime_notify(control, 2, nil);
    moonui_native_ime_mark_prev(control, NO);
  }
}

/* 文本变了：记一笔待定（判定在 flush 里，理由见上面那段）。 */
static void moonui_native_ime_end_if_composing(NSView *control) {
  if (moonui_native_ime_fn == 0 || !moonui_native_ime_prev_of(control)) {
    return;
  }
  moonui_native_ime_mark_pending(control);
  [moonui_native_dispatcher performSelector:@selector(flushImePending:)
                                 withObject:nil
                                 afterDelay:0];
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
/* 同一颗事件的 hitTest owner（`T102` 第十二刀，契约在 adapter.h 鼠标段）：
 * target 在滚轮/空白上恒是窗口，owner 记真正被命中的控件。 */
static moonui_ptr moonui_native_mouse_owner_ptr = 0;
static int moonui_native_mouse_code = 0;
static int moonui_native_mouse_px = 0;
static int moonui_native_mouse_py = 0;
/* 滚动增量（逻辑像素，kind 4 才有值，其余恒 0）：换算在 C 里做完（adapter.h
 * 鼠标段注的口径），MoonBit 不许再除一次。 */
static int moonui_native_mouse_ldx = 0;
static int moonui_native_mouse_ldy = 0;
static id moonui_native_mouse_monitor = nil;
/* 合成滚轮的落点窗口（`T108`）：CGEvent 转出来的 NSEvent 没有 windowNumber，
 * AppKit 在 sendEvent: 里也不替它补，而测试进程从来没有 key window（实测
 * `[NSApp keyWindow]` 恒 nil），于是由投送侧把"这一发打给哪只窗口"登记在
 * 这里，监听在 `[e window] == nil` 那一支接住它。真事件都带 window，这一支
 * 只服务合成的滚轮。 */
static NSWindow *moonui_native_synth_wheel_win = nil;
/* 合成滚轮的**命中控件**（`T102` 第十二刀）：CGEvent 转出来的 NSEvent 没有
 * windowNumber，`locationInWindow` 于是不是投送侧请求的那个点——监听里
 * `hitTest` 打不中预期的控件，`mouse_owner` 会报 0。真事件没有这个问题。
 * 所以投送侧把算好的 owner 登记在这里，监听只在"这一发没有 window"时接住。
 * 与 `synth_wheel_win` 同一条：只服务脚手架，真事件走不到这一支。 */
static NSView *moonui_native_synth_wheel_owner = nil;
/* 指针捕获（`T102` 第十三刀，契约在 adapter.h 鼠标段）：左键在自绘面上
 * 按下时记下它，按下期间（拖拽/抬起）的 hitTest 结果不再作数，事件恒投给
 * 这块面——手指拖出面外时下面命中的是空白或别的控件，但这一串动作仍然属于
 * 那块面。左键抬起后清。
 *
 * 只对自绘面开：原生控件有自己的 tracking/mouseDown 循环，AppKit 本来就把
 * 按下与抬起的配对管住了，这里再插一杠只会把按钮的行为改掉。retain 一份是
 * 防按下期间控件被拆：引用没了指针就悬空，而这条捕获要活到抬起那一颗。 */
static NSView *moonui_native_mouse_capture = nil;

/* 换/清捕获。只在这里动 retain/release，监听那支读 `moonui_native_mouse_capture`
 * 就够了。 */
static void moonui_native_mouse_set_capture(NSView *v) {
  if (v == moonui_native_mouse_capture) {
    return;
  }
  [moonui_native_mouse_capture release];
  moonui_native_mouse_capture = [v retain];
}

static void moonui_native_mouse_drop_closure(void) {
  if (moonui_native_mouse_monitor != nil) {
    [NSEvent removeMonitor:moonui_native_mouse_monitor];
    moonui_native_mouse_monitor = nil;
  }
  if (moonui_native_mouse_closure != 0) {
    moonbit_decref(moonui_native_mouse_closure);
    moonui_native_mouse_closure = 0;
  }
  moonui_native_mouse_set_capture(nil);
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

static void moonui_native_mouse_notify(moonui_ptr target, moonui_ptr owner, int code,
                                       int px, int py, int ldx, int ldy) {
  if (moonui_native_mouse_fn == 0) {
    return;
  }
  moonui_native_mouse_target_ptr = target;
  moonui_native_mouse_owner_ptr = owner;
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
                                         /* 合成滚轮（`T108`）没有 window 归属：
                                          * CGEvent 转出来的 NSEvent 其
                                          * windowNumber 是 0，AppKit 在
                                          * sendEvent: 里也不替它补，`[NSApp
                                          * keyWindow]` 在测试进程里又恒 nil
                                          * （实测）——于是由投送侧登记的那一发
                                          * 接住。真事件都带 window，这一支只
                                          * 服务合成滚轮。 */
                                         win = moonui_native_synth_wheel_win;
                                       }
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
                                       /* 合成滚轮：见 `synth_wheel_owner` 的注释
                                        * （`T102` 第十二刀）。只在真命中为空时用，
                                        * 真事件一条都走不到。 */
                                       if (owner == nil && wheel &&
                                           [e window] == nil &&
                                           moonui_native_synth_wheel_owner != nil) {
                                         owner = moonui_native_synth_wheel_owner;
                                       }
                                       /* 指针捕获（`T102` 第十三刀）：按下那一颗
                                        * 落在自绘面上就记住它，这一串拖拽/抬起
                                        * 的收件人恒是它——拖出面外时 hitTest
                                        * 命中的是空白或别的控件，但手指还在
                                        * 那块面的拖拽里（DataGrid 的拖拽重排
                                        * 靠这个：拖出表格边界后 `MouseMove` /
                                        * `MouseUp` 照样得回来，否则重排停在
                                        * 最后一帧）。同一扇窗才接：拖到别的
                                        * 窗口上那一串不属于这块面。 */
                                       if ([e type] == NSEventTypeLeftMouseDown &&
                                           owner != nil &&
                                           [owner isKindOfClass:[MoonuiCustomView class]]) {
                                         moonui_native_mouse_set_capture(owner);
                                       } else if (moonui_native_mouse_capture != nil &&
                                                  [e window] == [moonui_native_mouse_capture window] &&
                                                  ([e type] == NSEventTypeLeftMouseDragged ||
                                                   [e type] == NSEventTypeLeftMouseUp)) {
                                         owner = moonui_native_mouse_capture;
                                       }
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
                                           target,
                                           (moonui_ptr)(uintptr_t)owner, code,
                                           moonui_native_pt_to_px(
                                               in_content.x,
                                               moonui_native_window_scale_of(win)),
                                           moonui_native_pt_to_px(
                                               [content bounds].size.height - in_content.y,
                                               moonui_native_window_scale_of(win)),
                                           ldx, ldy);
                                       /* 抬起这一颗投完就放开捕获：之后在面外
                                        * 的移动/拖拽不再属于它（没有按着的面外
                                        * 移动照旧按 hitTest 走）。放在通知之后，
                                        * 抬起那条本身还是投给面的。 */
                                       if ([e type] == NSEventTypeLeftMouseUp) {
                                         moonui_native_mouse_set_capture(nil);
                                       }
                                       return e;
                                     }];
  }
  return 0;
}

moonui_ptr moonui_native_mouse_target(void) {
  TRACE("mouse_target");
  return moonui_native_mouse_target_ptr;
}

moonui_ptr moonui_native_mouse_owner(void) {
  TRACE("mouse_owner");
  return moonui_native_mouse_owner_ptr;
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

/* ---- 触控板手势（`T100`，契约全文在 adapter.h 手势段）----
 *
 * 形状和鼠标段/键盘段一致：进程级 local monitor 一份，通知不带内容，几样
 * 当场读回（target / kind / phase / direction / value）。差别只有一处：
 * 手势量是小数，读回口子走定点（百万分之一），见 adapter.h 那段的口径。
 *
 * 监听单列一份而不并进鼠标那份，是因为 mask 与"通知里该读什么"都不一样：
 * 鼠标那份读坐标与按键位，手势这份读 magnification/rotation/phase/deltaX。
 * 并成一份会让那个 handler 再多四个分支，而两者从来没有同时到达的情况。 */

static moonui_closure_fn moonui_native_gesture_fn = 0;
static void *moonui_native_gesture_closure = 0;
static moonui_ptr moonui_native_gesture_target_ptr = 0;
static int moonui_native_gesture_kind_code = 0;
static int moonui_native_gesture_phase_code = 1;
static int moonui_native_gesture_direction_code = 0;
static int64_t moonui_native_gesture_value_micro = 0;
static id moonui_native_gesture_monitor = nil;

/* 编码口径全在 adapter.h 手势段：kind 0/1/2、phase 0..3、direction 0..3、
 * value 定点百万分之一。这里只做"存四样 + 叫回调"。 */
static void moonui_native_gesture_dispatch(moonui_ptr target, int kind, int phase,
                                           int direction, double value) {
  if (moonui_native_gesture_fn == 0) {
    return;
  }
  moonui_native_gesture_target_ptr = target;
  moonui_native_gesture_kind_code = kind;
  moonui_native_gesture_phase_code = phase;
  moonui_native_gesture_direction_code = direction;
  moonui_native_gesture_value_micro = (int64_t)llround(value * 1000000.0);
  moonui_native_gesture_fn(moonui_native_gesture_closure);
}

/* `NSEvent.rotation` 是**角度**（NSEvent.h 原话 "In degrees."），ABI 收的是
 * 弧度——换算只有这一处，产品路径（监听）与脚手架（`rotate_in_window`）共用。
 * 分开写两份就必然有一份先漂：`T100` 的断言正是挂在这个函数上。 */
static double moonui_native_rad_of_deg(double deg) {
  return deg * M_PI / 180.0;
}

/* `NSEventPhase` → adapter.h 的四档。手势事件可能带 NSEventPhaseNone
 * （系统没标相位，例如旧式输入设备），那一档按 Changed 算——"这一步的增量"
 * 是最保守的说法，不把一条来路不明的读数说成手势开始或结束。 */
static int moonui_native_gesture_phase_of(NSEventPhase ph) {
  if (ph & NSEventPhaseBegan) {
    return 0;
  }
  if (ph & NSEventPhaseEnded) {
    return 2;
  }
  if (ph & NSEventPhaseCancelled) {
    return 3;
  }
  return 1;
}

/* 事件落到哪个 target：命中那段 superview 链上第一个带 owner 记号的 view，
 * 退不到就报**窗口自己**——手势与滚轮同一条口径（adapter.h 手势段）。 */
static moonui_ptr moonui_native_gesture_target_of(NSEvent *e, NSView *content) {
  NSView *hit;
  NSView *owner;
  hit = [content hitTest:[e locationInWindow]];
  owner = moonui_native_hit_owner(hit);
  if (owner == nil) {
    return (moonui_ptr)(uintptr_t)[e window];
  }
  return (moonui_ptr)(uintptr_t)owner;
}

static void moonui_native_gesture_drop_closure(void) {
  if (moonui_native_gesture_monitor != nil) {
    [NSEvent removeMonitor:moonui_native_gesture_monitor];
    moonui_native_gesture_monitor = nil;
  }
  if (moonui_native_gesture_closure != 0) {
    moonbit_decref(moonui_native_gesture_closure);
    moonui_native_gesture_closure = 0;
  }
  moonui_native_gesture_fn = 0;
}

int moonui_native_on_gesture(moonui_closure_fn fn, void *closure) {
  TRACE("on_gesture");
  moonui_native_gesture_drop_closure();
  moonui_native_gesture_fn = fn;
  moonui_native_gesture_closure = closure;
  if (closure != 0) {
    moonbit_incref(closure);
  }
  if (moonui_native_gesture_monitor == nil) {
    /* 三个 mask 都是 D 类的"没被 AppKit 消费掉的"那几型：捏合与旋转由触控板
     * 直接产出，滑动是系统识别后发的离散事件（`NSEventTypeSwipe`）。
     *
     * 事件返回 `e`（不吞）：手势还有别的消费者（NSScrollView 的弹性滚动、
     * 视图自己的 magnifyWithEvent:），这条监听只报给 Core，不改原生行为
     * ——与鼠标段对移动/滚轮的处理同一条纪律。 */
    moonui_native_gesture_monitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskMagnify |
            NSEventMaskRotate | NSEventMaskSwipe
                                     handler:^NSEvent *(NSEvent *e) {
                                       NSWindow *win;
                                       NSView *content;
                                       NSEventType type;
                                       if (moonui_native_gesture_fn == 0) {
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
                                       type = [e type];
                                       if (type == NSEventTypeMagnify) {
                                         /* magnification 是"加在当前缩放上
                                          * 得到新缩放"的增量，原样报（不做
                                          * 1+d 的换算，那是消费方的事；
                                          * adapter.h 写的是同一句话）。 */
                                         moonui_native_gesture_dispatch(
                                             moonui_native_gesture_target_of(e, content),
                                             0,
                                             moonui_native_gesture_phase_of([e phase]),
                                             0, (double)[e magnification]);
                                       } else if (type == NSEventTypeRotate) {
                                         /* `NSEvent.rotation` 是**角度**，ABI 收
                                          * 弧度——换算走 `moonui_native_rad_of_deg`
                                          * 这一个函数（脚手架同一份），MoonBit
                                          * 不许再换一次。 */
                                         moonui_native_gesture_dispatch(
                                             moonui_native_gesture_target_of(e, content),
                                             1,
                                             moonui_native_gesture_phase_of([e phase]),
                                             0,
                                             moonui_native_rad_of_deg(
                                                 (double)[e rotation]));
                                       } else {
                                         /* 方向按 NSEvent.h 的原话：deltaX -1 是
                                          * 向右滑、+1 是向左滑；deltaY -1 是向下
                                          * 滑、+1 是向上滑。横向优先（非零的那一
                                          * 位说了算），两位都零就整条丢掉——没有
                                          * 方向的滑动不是一个可以说出口的事件。 */
                                         CGFloat dx = [e deltaX];
                                         CGFloat dy = [e deltaY];
                                         int dir;
                                         if (dx == 0 && dy == 0) {
                                           return e;
                                         }
                                         if (dx != 0) {
                                           dir = dx < 0 ? 1 : 0; /* 1 右 / 0 左 */
                                         } else {
                                           dir = dy < 0 ? 3 : 2; /* 3 下 / 2 上 */
                                         }
                                         moonui_native_gesture_dispatch(
                                             moonui_native_gesture_target_of(e, content),
                                             2, 1, dir, 0.0);
                                       }
                                       return e;
                                     }];
  }
  return 0;
}

moonui_ptr moonui_native_gesture_target(void) {
  TRACE("gesture_target");
  return moonui_native_gesture_target_ptr;
}

int moonui_native_gesture_kind(void) {
  TRACE("gesture_kind");
  return moonui_native_gesture_kind_code;
}

int moonui_native_gesture_phase(void) {
  TRACE("gesture_phase");
  return moonui_native_gesture_phase_code;
}

int moonui_native_gesture_direction(void) {
  TRACE("gesture_direction");
  return moonui_native_gesture_direction_code;
}

int64_t moonui_native_gesture_value(void) {
  TRACE("gesture_value");
  return moonui_native_gesture_value_micro;
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
/* `T96③` 的半颗账：KeyDown 被菜单认领或 Shift+Tab 吞掉时，配对的 KeyUp
 * 在这里登记、到达即吞。ch 非零 = 按字符匹配（菜单认领那支），keycode
 * 非负 = 按 keyCode 匹配（Shift+Tab 那支），吞到即清——不吞第二次。
 * 单槽设计（记案）：两颗被吞键重叠时（如 ⌘Q 还没松又按 Shift+Tab），
 * 后到的登记覆盖前者，前者的 KeyUp 会漏吞——窗口极窄且无实害（KeyUp
 * 目前没有消费者），不做队列。 */
static int moonui_native_key_swallow_pending = 0;
static unichar moonui_native_key_swallow_ch = 0;
static NSInteger moonui_native_key_swallow_keycode = -1;

static void moonui_native_key_drop_closure(void) {
  if (moonui_native_key_monitor != nil) {
    [NSEvent removeMonitor:moonui_native_key_monitor];
    moonui_native_key_monitor = nil;
  }
  /* 吞键登记一并复位：监听拆掉再装（换回调、terminate）不该残留上一
   * 段的登记，否则一颗无关的 KeyUp 会被误吞一次。 */
  moonui_native_key_swallow_pending = 0;
  moonui_native_key_swallow_ch = 0;
  moonui_native_key_swallow_keycode = -1;
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

/* adapter.h 的四位打包 → NSEventModifierFlag（`moonui_native_mods_of_flags`
 * 的逆向）。菜单认领的匹配要用它：keyEquivalentModifierMask 是旗标巨值，
 * 与四位打包直接比永远不等（`T103` 真跑咬出——⌘Q 的认领自 T91 移植以来
 * 从未匹配成功，零覆盖所以没人发现，结果就是"菜单动作 + Core KeyDown"
 * 双发，正是这条规则要防的形状）。 */
static NSUInteger moonui_native_flags_of_mods(int mods) {
  NSUInteger flags = 0;
  if ((mods & 1) != 0) {
    flags |= NSEventModifierFlagControl;
  }
  if ((mods & 2) != 0) {
    flags |= NSEventModifierFlagOption;
  }
  if ((mods & 4) != 0) {
    flags |= NSEventModifierFlagShift;
  }
  if ((mods & 8) != 0) {
    flags |= NSEventModifierFlagCommand;
  }
  return flags;
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
            [item keyEquivalentModifierMask] ==
                moonui_native_flags_of_mods((int)mods)) {
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
static BOOL moonui_native_tab_backward(NSWindow *win) {
  NSResponder *resp;
  NSView *view;
  NSView *prev;
  if (win == nil) {
    /* 与监听里那条归属同口径：事件自己的窗口是权威，keyWindow 只作兜底
     * （测试进程里窗口从没被激活成 key，`T105`）。 */
    win = [NSApp keyWindow];
  }
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
    id mon = [NSEvent
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
                                         /* `T96③`：上一颗被吞/被认领的
                                          * KeyDown 的配对 KeyUp 到了——吞
                                          * 掉即清，不漏半颗没人认领的抬起。
                                          * 字符匹配（菜单支）与 keyCode 匹配
                                          * （Shift+Tab 支）按登记时那支走。 */
                                         if (!down &&
                                             moonui_native_key_swallow_pending &&
                                             ((moonui_native_key_swallow_ch != 0 &&
                                                 key ==
                                                     moonui_native_key_swallow_ch) ||
                                               (moonui_native_key_swallow_ch == 0 &&
                                                 [e keyCode] ==
                                                     moonui_native_key_swallow_keycode))) {
                                           moonui_native_key_swallow_pending = 0;
                                           moonui_native_key_swallow_ch = 0;
                                           moonui_native_key_swallow_keycode = -1;
                                           return nil;
                                         }
                                         /* 主菜单认领的组合不报（只在按下那
                                          * 一次判；配对的 KeyUp 在上面那格
                                          * 吞掉，`T96③`——不再照报半颗没人
                                          * 认领的抬起）。 */
                                         if (down && key != 0 &&
                                             moonui_native_menu_claims(
                                                 [NSApp mainMenu], key,
                                                 (NSUInteger)mods)) {
                                           moonui_native_key_swallow_pending = 1;
                                           moonui_native_key_swallow_ch = key;
                                           moonui_native_key_swallow_keycode = -1;
                                           return e;
                                         }
                                         /* Shift+Tab：拦下退一步（`T66`）。
                                          * 挪得动就吞掉，挪不动放行走默认；
                                          * 配对的 KeyUp 同样登记吞（`T96③`）。 */
                                         if (down && (mods & 4) != 0 &&
                                             [e keyCode] == MOONUI_VK_TAB &&
                                             moonui_native_tab_backward([e window])) {
                                           moonui_native_key_swallow_pending = 1;
                                           moonui_native_key_swallow_ch = 0;
                                           moonui_native_key_swallow_keycode = MOONUI_VK_TAB;
                                           return nil;
                                         }
                                         /* 归属：焦点控件是我们的就报控件，
                                          * 否则报事件窗口（是我们的窗口时），
                                          * 都不是（别的进程的键）不报。 */
                                         /* 归属先认事件自己的窗口（事件来源是
                                          * 权威），keyWindow 只作兜底：测试
                                          * 进程里窗口从没被激活成 key，
                                          * `[NSApp keyWindow]` 常是 nil，只认
                                          * 它会让键报给"没人"，断言随机少一条
                                          * （`T105` 实测）；真实场景两者等价。 */
                                         win = [e window];
                                         if (win == nil) {
                                           win = [NSApp keyWindow];
                                         }
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
    if (mon == nil) {
      /* `T96②`：装不上要如实报 -1（adapter.h 的契约"0 = 装上了，-1 =
       * 装不上"）。恒返 0 的话 `key_installed` 置 true 从此不重试，
       * 键路静默缺席——比报错更危险。回调一并撤回，不留一份没有监听
       * 在驱动的闭包。 */
      moonui_native_key_drop_closure();
      return -1;
    }
    moonui_native_key_monitor = mon;
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

/* `T91①` 的替按（契约在 adapter.h 脚手架段）：正在追踪的那只菜单 + 下一次
 * 弹窗要认领的"ms 之后点第几项"。popUpMenuPositioningItem: 的追踪循环跑到
 * 用户选完为止，测试不先安排这一下就永远回不来。 */
static NSMenu *moonui_native_ctx_live_menu = nil;
static int moonui_native_ctx_pick_after_ms = -1;
static int moonui_native_ctx_pick_index = -1;

int moonui_native_auto_pick_context_menu(int ms, int index) {
  TRACE("auto_pick_context_menu");
  if (index < -1) {
    return -1;
  }
  moonui_native_ctx_pick_after_ms = ms < 0 ? 0 : ms;
  moonui_native_ctx_pick_index = index;
  return 0;
}

/* 装定时器：三档一起挂（追踪循环跑在 NSEventTrackingRunLoopMode，只挂默认档
 * 永远不会 fire——与 alert 那条替按同一个坑）。 */
static void moonui_native_arm_ctx_picker(NSMenu *menu) {
  NSTimer *timer;
  NSTimeInterval delay;
  NSInteger index;
  NSRunLoop *loop;
  if (menu == nil || moonui_native_ctx_pick_after_ms < 0) {
    return;
  }
  index = (NSInteger)moonui_native_ctx_pick_index;
  delay = (NSTimeInterval)moonui_native_ctx_pick_after_ms / (NSTimeInterval)1000.0;
  timer = [NSTimer timerWithTimeInterval:delay
                                repeats:NO
                                    block:^(NSTimer *fired) {
                                      NSMenu *live = moonui_native_ctx_live_menu;
                                      NSArray *items;
                                      (void)fired;
                                      if (live == nil) {
                                        return;
                                      }
                                      items = [live itemArray];
                                      if (index >= (NSInteger)0 &&
                                          index < (NSInteger)[items count] &&
                                          [[items objectAtIndex:index]
                                              isEnabled]) {
                                        /* 真选品：item 自己的 target/action
                                         * （ctx target → Core 的菜单语义），
                                         * 与鼠标选中同一条派发。 */
                                        [live performActionForItemAtIndex:index];
                                      }
                                      /* 选完/越界/点空白都结束追踪。 */
                                      [live cancelTracking];
                                    }];
  loop = [NSRunLoop currentRunLoop];
  [loop addTimer:timer forMode:NSEventTrackingRunLoopMode];
  [loop addTimer:timer forMode:NSModalPanelRunLoopMode];
  [loop addTimer:timer forMode:NSDefaultRunLoopMode];
  moonui_native_ctx_pick_after_ms = -1;
  moonui_native_ctx_pick_index = -1;
}

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
    moonui_native_ctx_live_menu = menu;
    moonui_native_arm_ctx_picker(menu);
    [menu popUpMenuPositioningItem:nil
                        atLocation:[win.contentView convertPoint:loc
                                                        fromView:nil]
                            inView:win.contentView];
    moonui_native_ctx_live_menu = nil;
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

/* 接住一次拖入的实体（`T91③` 起拆出来）：读 pasteboard → 打包 → 通知。
 * 拆出来的理由是测试替投要喂一只**真的** NSPasteboard（`simulate_file_drop`），
 * 而 `performDragOperation:` 只多一步取 pasteboard——那一步没有可以假装的
 * 语义，留着它、把下面整段共享。 */
static BOOL moonui_native_drop_take(MoonuiWindow *win, NSPasteboard *pb) {
  NSArray<NSURL *> *urls;
  NSMutableData *packed;
  int count;
  char *u8;
  moonui_ptr target;
  @autoreleasepool {
    if (moonui_native_drop_fn == 0) {
      return NO;
    }
    /* 读文件 URL 用 `readObjectsForClasses:options:` 而不是
     * `propertyListForType:NSPasteboardTypeFileURL`（`T91③` 真跑咬出）：
     * 后者在 `writeObjects:` 写出来的 pasteboard 上只给**第一条**的字符串
     * （多文件也只给第一条，形状是 NSString 不是 NSArray——老写法按数组用会
     * 当场 unrecognized selector 崩掉），而真 Finder 拖多条时给的又是数组。
     * 这一条 API 两种形状都收、还直接给 NSURL，省掉字符串→URL 的一次转换。 */
    urls = [pb readObjectsForClasses:@[ [NSURL class] ]
                             options:@{
                               NSPasteboardURLReadingFileURLsOnlyKey : @YES
                             }];
    if (urls == nil || urls.count == 0) {
      return NO;
    }
    /* 按 adapter.h 的打包布局拼二进制（i32 一律小端手工打包；用 NSMutableData
     * 不用 NSMutableString——头里的字节原样落盘，走 %c 会把 0x80 以上的字节
     * 当码位二次编码）。路径取 POSIX 形态再打包（MoonBit 侧收的是路径；
     * 转不出来——不是 file URL——那条就地丢弃）。 */
    count = 0;
    packed = [NSMutableData dataWithCapacity:16];
    for (NSURL *u in urls) {
      NSString *path = [u path];
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

static BOOL moonui_native_drop_perform(MoonuiWindow *win,
                                id<NSDraggingInfo> info) {
  return moonui_native_drop_take(win, [info draggingPasteboard]);
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

/* 把状态项从状态条上摘掉（`T91⑥` 真点击那条测试咬出）：`statusItemWithLength:`
 * 拿到的是进程级对象，terminate 不摘就会在测试进程里串到下一只 backend，真实
 * 应用里则是重复 init 时叠图标。摘完连同自己那份 retain 一起放掉。 */
static void moonui_native_tray_clear(void) {
  if (moonui_native_tray_item != nil) {
    [[NSStatusBar systemStatusBar] removeStatusItem:moonui_native_tray_item];
    [moonui_native_tray_item release];
    moonui_native_tray_item = nil;
  }
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

/* `T91⑥` 的"选中一项"替投（契约在 adapter.h 脚手架段）：`performActionForItemAtIndex:`
 * 走 item 自己的 target/action——也就是 Core 的 `bar.click` 语义，与用户点中这一项
 * 同一条路。
 *
 * **为什么不走真弹窗**：第一版是状态项按钮自己的 `performClick:`（真人点同一条路：
 * NSStatusItem 弹菜单 + 追踪循环），单跑 5 次全绿，但 `moon test` 把同一个可执行里
 * 的测试分发到多个线程（`-v` 里 "0/39 done, 0/28 running"），菜单追踪是主线程的
 * 模态循环——并行下 6 次里挂死 1 次（整批不结束）。上下文菜单那条没有这问题是因为
 * 它弹的是普通菜单（`T91①`），状态栏菜单要过系统状态栏那一层。真弹窗那半退回
 * 人手一次，这里只保留"选中派发"。
 *
 * 返回码：0 = 派发过（被禁用/分隔符不出回调）；-1 = 没有状态项或它没挂菜单；
 * -2 = index 越界；-3 = 还没初始化。 */
int moonui_native_click_tray_item(int index) {
  NSStatusItem *item;
  NSMenu *menu;
  NSArray *items;
  TRACE("click_tray_item");
  if (!moonui_native_inited) {
    return -3;
  }
  item = moonui_native_tray_item;
  if (item == nil) {
    return -1;
  }
  menu = [item menu];
  if (menu == nil) {
    return -1;
  }
  if (index < 0) {
    return -2;
  }
  items = [menu itemArray];
  if (index >= (int)[items count]) {
    return -2;
  }
  @autoreleasepool {
    /* 直接派发选中：`performActionForItemAtIndex:` 走 item 自己的 target/action
     * （Core 的 `bar.click` 语义），与用户点中这一项同一条路，只是不经过菜单
     * 弹窗。真弹窗（`performClick:` + 追踪循环）在并行测试里会挂死——moon 的
     * 测试运行器把同一个可执行里的测试分发到多线程，而菜单追踪是主线程的模态
     * 循环（`T105` 实测）。 */
    if ([[items objectAtIndex:index] isEnabled]) {
      [menu performActionForItemAtIndex:index];
    }
  }
  return 0;
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

/* `T91⑥` 的探针：托盘当下长什么样（打包见 adapter.h）。读的都是原生对象
 * 自己的状态——`button.image` 与 `menu.itemArray`，不是本文件记的名单。 */
int64_t moonui_native_tray_probe(void) {
  int64_t bits = 0;
  int64_t count = 0;
  TRACE("tray_probe");
  if (!moonui_native_inited || moonui_native_tray_item == nil) {
    return 0;
  }
  @autoreleasepool {
    bits = (int64_t)1;
    if ([moonui_native_tray_item.button image] != nil) {
      bits |= 2;
    }
    if ([moonui_native_tray_item menu] != nil) {
      bits |= 4;
      count = (int64_t)[[[moonui_native_tray_item menu] itemArray] count];
    }
  }
  return bits | (count << 8);
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

/* ---- 音频（lunamusic；adapter.h 音频段注）----
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
    /* 两遍：先收集 NSString（栈上小数组），再一次性打包。
     *
     * 收的是**绝对路径**（`T142`）：adapter.h 这条契约写的是"len 字节 UTF-8
     * 绝对路径"，而 readdir 只给 d_name。此前直接把裸文件名报上去，扫描入库
     * 的 path 于是成了 `夜曲.mp3`，播放时装歌按相对路径找——相对的是进程当前
     * 目录（`moon run` 下是仓库根），永远找不到，`start_at` 逐首重试全败后
     * `stop_all`，双击行看着就是"没反应"。 */
    NSMutableArray *names = [NSMutableArray array];
    struct dirent *entry;
    BOOL need_sep = ![p hasSuffix:@"/"];
    while ((entry = readdir(dir)) != 0) {
      const char *name = entry->d_name;
      if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        continue;
      }
      NSString *child = [NSString stringWithUTF8String:name];
      [names addObject:need_sep ? [p stringByAppendingFormat:@"/%@", child]
                               : [p stringByAppendingString:child]];
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

/* 一张帧位图贴到某只 view 的 layer 上：present（整窗）与 present_view
 * （自定义绘制面）共用的那一段。contents 赋值会 CFRetain，所以 __bridge 之后
 * 这里放掉自己的引用是安全的；bytes 布局与 begin_frame 开帧时同款
 * （RGBA 预乘、Big 端）。 */
static int moonui_canvas_present_into(MoonuiCanvas *c, NSView *v) {
  CGDataProviderRef prov;
  CGImageRef img;
  if (c == 0 || c->data == 0 || v == nil) {
    return -1;
  }
  prov = CGDataProviderCreateWithData(nil, c->data,
                                      c->row_bytes * (size_t)c->h, nil);
  if (prov == nil) {
    return -1;
  }
  img = CGImageCreate((size_t)c->w, (size_t)c->h, 8, 32, c->row_bytes, c->space,
                      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast,
                      prov, nil, false, kCGRenderingIntentDefault);
  CGDataProviderRelease(prov);
  if (img == nil) {
    return -1;
  }
  [v setWantsLayer:YES];
  v.layer.contents = (__bridge id)img;
  CGImageRelease(img);
  return 0;
}

int moonui_canvas_present(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_present");
  if (c == 0 || c->window == nil) {
    return -1;
  }
  @autoreleasepool {
    return moonui_canvas_present_into(c, [c->window contentView]);
  }
}

/* 贴到指定视图（`T101` 的自定义绘制面）：位图只属于它自己那只 NSView，不铺
 * 整窗。图层的 gravity 用 resize，位图与矩形同尺寸时等价于逐像素对齐。 */
int moonui_canvas_present_view(moonui_ptr canvas, moonui_ptr view) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  NSView *v = (NSView *)(uintptr_t)view;
  TRACE("canvas_present_view");
  if (c == 0 || v == nil) {
    return -1;
  }
  @autoreleasepool {
    return moonui_canvas_present_into(c, v);
  }
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

int moonui_canvas_stroke_arc(moonui_ptr canvas, int cx, int cy, int r,
                             int start_deg_permille, int sweep_deg_permille,
                             int64_t rgb, int width_permille) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  CGColorRef color;
  double a0, sweep;
  TRACE("canvas_stroke_arc");
  if (c == 0 || c->ctx == nil) {
    return -1;
  }
  if (r <= 0 || width_permille <= 0) {
    return -1;
  }
  if (sweep_deg_permille == 0) {
    /* 进度 0% 是正常状态，不是错误：什么都不画。 */
    return 0;
  }
  @autoreleasepool {
    /* 位图上下文在开帧时翻成 y 向下（见 begin_frame 注），本地的"角度增大 =
     * 屏幕顺时针"正是 ABI 的方向。这里不用 CGContextAddArc，按角度采样成折线
     * 再一次性 StrokePath，两个理由：①CG 的弧角度按 y **向上**定义，而这里的
     * CTM 已经翻成 y 向下——直接用它就得再翻一层（交换起止角、或把 sin 的符号
     * 反过来），翻错一次画出来的是**镜像的那一半**，命令参数对账看不出错，
     * 只有像素能说话；采样折线把角度直接定义在 y 向下的屏幕坐标系里，转换
     * 只有一次、且就写在下面的点公式里。②负扫角（逆时针）不能把负 delta
     * 交给 AddArc：它会把小于起点的终点补 2π，画出剩下那一大圈。
     * 采样只在 C 侧、一次调用内完成，DrawList 仍是 1 条命令，成本远小于
     * "每帧 72 段 Line 拼环"。角度按 y 向下定义：点 =
     * (cx + r·cosθ, cy + r·sinθ)，θ=0 指向 +x、θ 增大顺时针（向下）。 */
    a0 = (double)start_deg_permille / 1000.0 * M_PI / 180.0;
    sweep = (double)sweep_deg_permille / 1000.0 * M_PI / 180.0;
    if (sweep >= 2.0 * M_PI - 0.001) { sweep = 2.0 * M_PI; }
    else if (sweep <= -2.0 * M_PI + 0.001) { sweep = -2.0 * M_PI; }
    color = moonui_canvas_color(c->space, rgb, 255);
    CGContextSetStrokeColorWithColor(c->ctx, color);
    CGContextSetLineWidth(c->ctx, (CGFloat)width_permille / 1000.0);
    double span = fabs(sweep);
    long n = (long)(span / (M_PI / 36.0));   // 每 ~5° 一段
    if (n < 2) { n = 2; }
    if (n > 720) { n = 720; }
    double dth = sweep / (double)n;
    double th = a0;
    CGContextBeginPath(c->ctx);
    CGContextMoveToPoint(c->ctx,
                         (CGFloat)(cx + r * cos(th)),
                         (CGFloat)(cy + r * sin(th)));
    for (long i = 1; i <= n; i = i + 1) {
      th = a0 + dth * (double)i;
      CGContextAddLineToPoint(c->ctx,
                              (CGFloat)(cx + r * cos(th)),
                              (CGFloat)(cy + r * sin(th)));
    }
    CGContextStrokePath(c->ctx);
    CGColorRelease(color);
  }
  return 0;
}

int moonui_canvas_fill_polygon(moonui_ptr canvas, moonui_ptr points, int n,
                               int64_t rgb, int alpha) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  CGColorRef color;
  int32_t *raw;
  int i;
  TRACE("canvas_fill_polygon");
  if (c == 0 || c->ctx == nil || points == 0 || n < 3) {
    return -1;
  }
  raw = (int32_t *)(uintptr_t)points;
  @autoreleasepool {
    color = moonui_canvas_color(c->space, rgb, alpha);
    /* 位图上下文在开帧时已翻成 y 向下（见 begin_frame 注），顶点直接按屏幕
     * 坐标给——和 canvas_line / canvas_fill_rect 同一套坐标系，不在这里再翻
     * 一次（翻两次就是镜像）。轮廓首尾相连：最后一点自动连回第一点，闭包
     * 用 ClosePath 收口。填充规则用默认的非零环绕（even-odd 会让自交
     * 多边形挖洞，那不是"面积图"该有的样子）。 */
    CGContextBeginPath(c->ctx);
    CGContextMoveToPoint(c->ctx, (CGFloat)raw[0], (CGFloat)raw[1]);
    for (i = 1; i < n; i++) {
      CGContextAddLineToPoint(c->ctx, (CGFloat)raw[i * 2], (CGFloat)raw[i * 2 + 1]);
    }
    CGContextClosePath(c->ctx);
    CGContextSetFillColorWithColor(c->ctx, color);
    CGContextFillPath(c->ctx);
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

/* =====================================================================
 * 测试脚手架（`T103`，mac 半）——真窗测试的投递与探针
 *
 * Windows 半（adapter_native.c 的同名四条）直写 Win32 消息；mac 半走
 * AppKit 自己的通道，两边都不是"把回调调一遍"：
 *   - send_key：造一条**真 NSEvent**（KeyDown/KeyUp）交给 [NSApp sendEvent:]，
 *     于是进程内键监听、"主菜单收不收这组"的判断（`T96②③` 新改的那段
 *     状态机）、first responder 的后续处理全被真跑一遍，同步完成。
 *   - click：造一对真的按下/抬起 NSEvent，鼠标监听与控件 action 都走真路。
 *   - type_text / focus：makeFirstResponder + 共享 field editor（与真人
 *     打字同一条文本系统路径）。
 * 坐标口径统一收 MoonUI 的（客户区左上原点、y 向下、物理像素），换算成
 * AppKit 的（contentView 坐标、y 向上、pt）——与鼠标监听读出方向互逆，
 * 尺子照 `moonui_native_pt_to_px` 的逆用，不立第二把尺。
 * ===================================================================== */

/* 按标题在活窗表里找窗口；找不到 nil。Windows 的 find_window 同形。 */
static NSWindow *moonui_native_scaffold_window(const char *title, int title_len) {
  char *t;
  NSWindow *found = nil;
  NSUInteger i;
  if (title == 0 || title_len < 0) {
    return nil;
  }
  t = moonui_native_dup(title, title_len);
  if (t == 0) {
    return nil;
  }
  for (i = 0; moonui_native_live_windows != nil &&
              i < [moonui_native_live_windows count];
       ++i) {
    NSWindow *w = [moonui_native_live_windows objectAtIndex:i];
    const char *wt = [[w title] UTF8String];
    if (wt != NULL && strcmp(wt, t) == 0) {
      found = w;
      break;
    }
  }
  free(t);
  return found;
}

/* 词表名 → keyCode（`moonui_native_key_name_of_code` 的逆向）；不在词表给 NO。
 * 键码表是 HID 用途常量，几十年来稳定（HIToolbox Events.h）。 */
static BOOL moonui_native_key_code_of_name(const char *name, unsigned short *code) {
  if (strcmp(name, "Enter") == 0) {
    *code = MOONUI_VK_RETURN;
  } else if (strcmp(name, "Tab") == 0) {
    *code = MOONUI_VK_TAB;
  } else if (strcmp(name, "Escape") == 0) {
    *code = MOONUI_VK_ESCAPE;
  } else if (strcmp(name, "Backspace") == 0) {
    *code = MOONUI_VK_BACKSPACE;
  } else if (strcmp(name, "Delete") == 0) {
    *code = MOONUI_VK_FORWARD_DELETE;
  } else if (strcmp(name, "Home") == 0) {
    *code = MOONUI_VK_HOME;
  } else if (strcmp(name, "End") == 0) {
    *code = MOONUI_VK_END;
  } else if (strcmp(name, "PageUp") == 0) {
    *code = MOONUI_VK_PAGE_UP;
  } else if (strcmp(name, "PageDown") == 0) {
    *code = MOONUI_VK_PAGE_DOWN;
  } else if (strcmp(name, "Left") == 0) {
    *code = MOONUI_VK_LEFT;
  } else if (strcmp(name, "Right") == 0) {
    *code = MOONUI_VK_RIGHT;
  } else if (strcmp(name, "Down") == 0) {
    *code = MOONUI_VK_DOWN;
  } else if (strcmp(name, "Up") == 0) {
    *code = MOONUI_VK_UP;
  } else if (strcmp(name, "F1") == 0) {
    *code = MOONUI_VK_F1;
  } else if (strcmp(name, "F2") == 0) {
    *code = MOONUI_VK_F2;
  } else if (strcmp(name, "F3") == 0) {
    *code = MOONUI_VK_F3;
  } else if (strcmp(name, "F4") == 0) {
    *code = MOONUI_VK_F4;
  } else if (strcmp(name, "F5") == 0) {
    *code = MOONUI_VK_F5;
  } else if (strcmp(name, "F6") == 0) {
    *code = MOONUI_VK_F6;
  } else if (strcmp(name, "F7") == 0) {
    *code = MOONUI_VK_F7;
  } else if (strcmp(name, "F8") == 0) {
    *code = MOONUI_VK_F8;
  } else if (strcmp(name, "F9") == 0) {
    *code = MOONUI_VK_F9;
  } else if (strcmp(name, "F10") == 0) {
    *code = MOONUI_VK_F10;
  } else if (strcmp(name, "F11") == 0) {
    *code = MOONUI_VK_F11;
  } else if (strcmp(name, "F12") == 0) {
    *code = MOONUI_VK_F12;
  } else {
    return NO;
  }
  return YES;
}

int moonui_native_send_key_in_window(const char *title, int title_len,
                              const char *key, int key_len, int mods, int down) {
  char *k;
  NSWindow *win;
  NSResponder *resp;
  NSView *owner;
  NSUInteger flags;
  unsigned short code = 0;
  NSString *chars = nil;
  BOOL named;
  NSEvent *e;
  TRACE("send_key_in_window");
  k = moonui_native_dup(key, key_len);
  if (k == 0) {
    return -1;
  }
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    free(k);
    return -2;
  }
  /* 归属靠焦点而不是坐标（adapter.h 键盘段注），所以先查：焦点不在我们的
   * 控件上就报 -3——否则这颗键会算到窗口自己头上，断言成了假绿。菜单认领
   * 那条测试（⌘Q）也先把焦点落进一个输入框再发，同一个纪律。 */
  resp = [win firstResponder];
  owner = [resp isKindOfClass:[NSView class]]
              ? moonui_native_hit_owner((NSView *)resp)
              : nil;
  if (owner == nil) {
    free(k);
    return -3;
  }
  /* 真实场景的前提摆到位：用户正用着这个窗口——应用在前台、窗口是 key。
   * 监听的归属解析走 [NSApp keyWindow] firstResponder（`T103` 真跑咬出：
   * 测试环境窗口不是 key 时解析落到 [e window] 兜底报窗口，键事件全归
   * 窗口）；菜单键等价也只在应用活跃时被 AppKit 处理（⌘Q 同一前提）。 */
  if (![win isKeyWindow]) {
    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];
    [win makeKeyWindow];
  }
  /* 词表 → characters + keyCode。字母/数字走 characters（监听的名字归一化、
   * 主菜单认领匹配都读它），keyCode 给 0——词表键的 keyCode 才有消费者
   * （Shift+Tab 的回退、key_name_of_code 的查表），字母这维没人读。 */
  if (key_len == 1 &&
      ((k[0] >= 'a' && k[0] <= 'z') || (k[0] >= '0' && k[0] <= '9'))) {
    chars = [NSString stringWithFormat:@"%c", k[0]];
  } else if (key_len == 5 && strcmp(k, "Space") == 0) {
    chars = @" ";
    code = 49; /* kVK_Space */
  } else {
    named = moonui_native_key_code_of_name(k, &code);
    if (!named) {
      free(k);
      return -4;
    }
    /* 词表键给空 characters：监听的名字归一化在 keyCode 查表那半接住
     * （key_read_name 的顺序就是"字符不是字母/数字/空格就查表"）。 */
    chars = @"";
  }
  free(k);
  /* adapter.h 的四位 → NSEvent 旗标：与菜单认领共用一个逆函数，免得两把尺
   * （`moonui_native_flags_of_mods`）。 */
  flags = moonui_native_flags_of_mods(mods);
  @autoreleasepool {
    e = [NSEvent
        keyEventWithType:(down != 0 ? NSEventTypeKeyDown : NSEventTypeKeyUp)
                location:NSMakePoint(0, 0)
            modifierFlags:flags
                timestamp:[[NSProcessInfo processInfo] systemUptime]
             windowNumber:[win windowNumber]
                  context:nil
                characters:chars
       charactersIgnoringModifiers:chars
                  isARepeat:NO
                    keyCode:code];
    if (e == nil) {
      return -1;
    }
    /* 同步派发：监听、菜单认领（吞键登记，`T96③`）、first responder 全在
     * 这次调用里真跑完——测试当场就能断言，不用等下一圈。 */
    [NSApp sendEvent:e];
  }
  return 0;
}

int moonui_native_click_button_in_window(const char *title, int title_len, int x, int y) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSView *owner;
  CGFloat scale;
  CGFloat h;
  NSPoint wpt;
  TRACE("click_button_in_window");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  content = [win contentView];
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  /* MoonUI 的 (x, y)（左上原点、物理 px）→ contentView 坐标（左下原点、
   * pt）→ 窗口底座坐标（hitTest 与 locationInWindow 的口径）。坐标这一步
   * 保留：布局摆错了就命不中，与 Windows 半同一把尺。 */
  wpt = [content
      convertPoint:NSMakePoint(moonui_native_px_to_pt(x, scale), h - moonui_native_px_to_pt(y, scale))
              toView:nil];
  hit = [content hitTest:wpt];
  if (hit == nil) {
    return -3; /* 真命不中：点在窗口外 */
  }
  owner = moonui_native_hit_owner(hit);
  if (owner == nil) {
    /* 命中的是窗口自己的 contentView 那类——adapter.h 把"空白处"归这一档。 */
    return -4;
  }
  if (![owner isKindOfClass:[NSButton class]]) {
    return -4; /* 不是可点击控件（label/输入框） */
  }
  /* 点击本体走 performClick: 而不是合成鼠标事件对——本机实测（`T103`）：
   * 合成 mouseDown 经 sendEvent 进 NSButton 后按钮开进 tracking 嵌套循环，
   * 等队列里的 mouseUp，而合成事件是 sendEvent 直派、根本不在队列里——
   * 循环等不到就挂死（adapter.h 鼠标段"嵌套循环不收监听"的同一条
   * AppKit 事实）。performClick: 是 BM_CLICK 的 mac 对应物：程序化触发，
   * 但 target/action 的真路由照走，action 回流成 Click 与真人点击同路。 */
  @autoreleasepool {
    [(NSButton *)owner performClick:nil];
  }
  return 0;
}

/* `T101`：在自定义绘制面上点一下，走它自己的 mouseDown:/mouseUp:。
 *
 * 为什么不能复用 click_button_in_window：那条的命中判据要求 NSButton
 * （performClick: 是它独有的程序化入口），自定义面是裸 NSView，没有
 * target/action。这里按坐标命中 → 判 kind 18 → 造一对真 NSEvent → 依次交给
 * 那只 view 自己的 mouseDown:/mouseUp:：mouseDown: 只置一个按下旗标就返回
 * （不开 tracking 循环，所以不像按钮那样需要先排队一颗抬起），mouseUp: 复核
 * "抬起点仍在自己矩形内"再派发 Click——跑的是与真人点击同一段代码。
 *
 * 为什么不是 `[NSApp sendEvent:]`（右键那条走的路）：测试进程不是前台应用，
 * 左键首击会被 AppKit 的"激活点击"逻辑吞掉——本机真跑量到的是探针读得到
 * 像素、Click 一次都不回来（右键不受此限，所以 right_click_in_window 能直发）。
 * 那是应用激活语义，不是控件语义，不该混进这条判据。 */
int moonui_native_click_custom_in_window(const char *title, int title_len, int x,
                                         int y) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSView *owner;
  CGFloat scale;
  CGFloat h;
  NSPoint wpt;
  NSPoint in_window;
  NSEvent *down;
  NSEvent *up;
  NSTimeInterval now;
  TRACE("click_custom_in_window");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  content = [win contentView];
  if (content == nil) {
    return -2;
  }
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  /* 坐标口径同 click_button_in_window：客户区左上原点、物理 px。 */
  wpt = [content
      convertPoint:NSMakePoint(moonui_native_px_to_pt(x, scale),
                               h - moonui_native_px_to_pt(y, scale))
              toView:nil];
  hit = [content hitTest:wpt];
  if (hit == nil) {
    return -3; /* 真命不中：点在窗口外 */
  }
  owner = moonui_native_hit_owner(hit);
  if (owner == nil || moonui_native_widget_kind_of(owner) != 18) {
    return -4; /* 空白处或别的控件（kind 表见 moonui_native_widget_kind_of） */
  }
  /* 事件里的 location 是窗口底座坐标——convertPoint:toView:nil 给的就是它。 */
  in_window = wpt;
  now = [NSProcessInfo processInfo].systemUptime;
  @autoreleasepool {
    down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                              location:in_window
                         modifierFlags:0
                             timestamp:now
                          windowNumber:[win windowNumber]
                               context:nil
                           eventNumber:0
                            clickCount:1
                              pressure:1.0];
    up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                            location:in_window
                       modifierFlags:0
                           timestamp:now
                        windowNumber:[win windowNumber]
                             context:nil
                         eventNumber:0
                          clickCount:1
                            pressure:0.0];
    if (down == nil || up == nil) {
      return -1;
    }
    [(MoonuiCustomView *)owner mouseDown:down];
    [(MoonuiCustomView *)owner mouseUp:up];
  }
  return 0;
}

int moonui_native_right_click_in_window(const char *title, int title_len, int x, int y) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSPoint in_content;
  NSPoint in_window;
  CGFloat scale;
  CGFloat h;
  NSEvent *down;
  NSEvent *up;
  NSTimeInterval now;
  TRACE("right_click_in_window");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  content = [win contentView];
  if (content == nil) {
    return -2;
  }
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  in_content = NSMakePoint(moonui_native_px_to_pt(x, scale),
                           h - moonui_native_px_to_pt(y, scale));
  in_window = [content convertPoint:in_content toView:nil];
  /* 命中不到就是点在客户区外（-3）：与 click_button_in_window 同一把尺，
   * 布局摆错了这条也红。 */
  hit = [content hitTest:in_window];
  if (hit == nil) {
    return -3;
  }
  if (![win isKeyWindow]) {
    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];
    [win makeKeyWindow];
  }
  now = [[NSProcessInfo processInfo] systemUptime];
  @autoreleasepool {
    down = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown
                              location:in_window
                         modifierFlags:0
                             timestamp:now
                          windowNumber:[win windowNumber]
                               context:nil
                           eventNumber:0
                            clickCount:1
                              pressure:1.0];
    up = [NSEvent mouseEventWithType:NSEventTypeRightMouseUp
                            location:in_window
                       modifierFlags:0
                           timestamp:now
                        windowNumber:[win windowNumber]
                             context:nil
                         eventNumber:0
                          clickCount:1
                            pressure:0.0];
    if (down == nil || up == nil) {
      return -1;
    }
    /* 一对都走 sendEvent：进程级鼠标监听在本地监听的时序上同步跑掉
     * （target/位置/kind 全由原生给），之后事件照常派给命中的控件。
     * 右键在默认 NSView 上不开 tracking 循环，所以不像左键那样要先排队
     * 一颗抬起（adapter.h 这条的注记）。 */
    [NSApp sendEvent:down];
    [NSApp sendEvent:up];
  }
  return 0;
}

/* `T108`：鼠标动作通用投送的 mac 半（契约全文在 adapter.h 的
 * send_mouse_in_window 段，返回码与 Windows 那份逐字相同）。
 *
 * 这条此前只有 Windows 一份定义（`T91①` 复验时按实测订正过），卡在左键那一支
 * 的两笔 AppKit 账：①合成的 mouseDown 进 NSButton 会开 tracking 嵌套循环，等
 * 一颗**不在队列里**的抬起——`T103` 量到的挂死（click_button_in_window 那段
 * 注释）；②测试进程不是前台应用时左键首击被 AppKit 的激活点击消费掉——`T101`
 * 量到的"Click 一次都不回来"。两条各有各的解法，且都在本仓别的口子上验过：
 * ①先把配套的抬起 `postEvent:atStart:NO` 排进队列（tracking 循环从队列取那一
 * 颗）；②投之前把窗口变成 key（right_click_in_window、send_key_in_window 同款）。
 *
 * 派发仍走 `[NSApp sendEvent:]` 而不是直接调 view 的 mouseDown:：这条 ABI 的消费
 * 者是**进程级监听**（`on_mouse`），监听挂在 NSApp 的派发路径上，绕开它就一条都
 * 收不到——自定义面那种"控件回调直接发 Click"的口子（`T101`）没有这层依赖，
 * 所以那边可以直调。代价是抬起那一颗的落点跟着控件自跑与否走（adapter.h 记的
 * "抬起两边不等价"），判据按真值断言。
 *
 * **激活要等生效（`T102` 第二十二刀，2026-10-21）**：`activateIgnoringOtherApps:`
 * 只是把请求排进去，真正变成 key 要等 WindowServer 那一拍。不等到位就投，首击照样
 * 被 AppKit 当激活点击吞掉——表现是"少一条 Click / 抬起落点漂"这类不着边际的红，
 * 而且只在机器忙、前台刚切回来时冒出来。下面等到 `isKeyWindow` 为止（至多 300ms）；
 * 等不到也不拦，让投送照常发生，红在断言里而不是挂在这里。 */

/* button → 三颗事件的类型。Extra1/Extra2（button 3/4）在 AppKit 里没有对应的
 * 事件类型，造不出来就报 -1（"原生造不出事件"），不挑一个近似的类型假装投了。 */
static int moonui_native_mouse_types_of(int button, int *down, int *up,
                                        int *dragged) {
  if (button == 0) {
    *down = (int)NSEventTypeLeftMouseDown;
    *up = (int)NSEventTypeLeftMouseUp;
    *dragged = (int)NSEventTypeLeftMouseDragged;
    return 0;
  }
  if (button == 1) {
    *down = (int)NSEventTypeRightMouseDown;
    *up = (int)NSEventTypeRightMouseUp;
    *dragged = (int)NSEventTypeRightMouseDragged;
    return 0;
  }
  if (button == 2) {
    *down = (int)NSEventTypeOtherMouseDown;
    *up = (int)NSEventTypeOtherMouseUp;
    *dragged = (int)NSEventTypeOtherMouseDragged;
    return 0;
  }
  return -1;
}

/* 自然滚动那个旗标只能从事件自身读（AppKit 按系统偏好给）：猜一个方向，"反向
 * 给数"那一步就漂了——产品路径（监听）读的是同一个旗标，于是往返自逆。 */
static int moonui_native_scroll_inverted(void) {
  CGEventRef probe;
  NSEvent *pe;
  probe = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, 0, 0);
  if (probe == NULL) {
    return 0;
  }
  pe = [NSEvent eventWithCGEvent:probe];
  CFRelease(probe);
  return (pe != nil && [pe isDirectionInvertedFromDevice]) ? 1 : 0;
}

int moonui_native_send_mouse_in_window(const char *title, int title_len,
                                int kind_button, int x, int y, int dx, int dy) {
  int kind;
  int button;
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSView *owner;
  CGFloat scale;
  CGFloat h;
  NSPoint in_content;
  NSPoint in_window;
  NSTimeInterval now;
  NSInteger wnum;
  TRACE("send_mouse_in_window");
  /* 编码检查排最前，与 Windows 那份同一条：越界的 kind/button 必须"什么都没
   * 发生"（-5），滚轮两轴同时非零同理——mac 的 CGEvent 带得动两轴，但那条 ABI
   * 是两边共用的，一侧投一条另一侧投两条，测试就得去猜顺序。 */
  if (kind_button < 0 || kind_button / 8 > 4 || kind_button % 8 > 4) {
    return -5;
  }
  kind = kind_button / 8;
  button = kind_button % 8;
  if (kind == 4 && dx != 0 && dy != 0) {
    return -5;
  }
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  content = [win contentView];
  if (content == nil) {
    return -2;
  }
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  /* 坐标口径同 right_click_in_window（客户区左上原点、物理 px）。 */
  in_content = NSMakePoint(moonui_native_px_to_pt(x, scale),
                           h - moonui_native_px_to_pt(y, scale));
  in_window = [content convertPoint:in_content toView:nil];
  hit = [content hitTest:in_window];
  if (hit == nil) {
    return -3;
  }
  /* 投送侧比监听侧严一格：监听侧滚轮/移动落在空白报窗口自己（自绘后端靠坐标
   * 反查），投送侧要求真命中我们的控件——否则一侧投一侧拒，测试要去猜。 */
  owner = moonui_native_hit_owner(hit);
  if (owner == nil) {
    return -4;
  }
  wnum = [win windowNumber];
  now = [[NSProcessInfo processInfo] systemUptime];
  /* 激活前提同 right_click_in_window：非前台应用的首击会被 AppKit 当成激活
   * 点击消费掉，按下那一支因此一条事件都产不出。**激活是异步的**（`T102` 第二十二
   * 刀量到）：`activateIgnoringOtherApps:` 只是把请求排进去，真正变成 key 要等
   * WindowServer 那一拍——不等到位就投，首击照样被当作激活点击吞掉，而测试那边
   * 看到的是"少一条 Click / 抬起落点漂"这类不着边际的红。这里等到真 key 为止
   * （至多 300ms），把竞态压成确定性前提；等不到也不拦，让投送照常发生，红在
   * 断言里而不是挂在这里。 */
  if (![win isKeyWindow]) {
    NSDate *key_deadline;
    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];
    [win makeKeyWindow];
    key_deadline = [NSDate dateWithTimeIntervalSinceNow:0.3];
    while (![win isKeyWindow] && [key_deadline timeIntervalSinceNow] > 0.0) {
      @autoreleasepool {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
      }
    }
  }
  @autoreleasepool {
    if (kind == 4) {
      CGEventRef cg;
      NSEvent *e;
      int inv;
      inv = moonui_native_scroll_inverted();
      /* 反向给数：请求里的 dx/dy 是"Core 该看到的逻辑像素"，这里按同一个旗标
       * 翻成原生那一份，监听读回时再翻一次，往返自逆。单位走像素——mac 的事件
       * 带得动任意整数像素（逐行那一档的换算在监听里做，见那段注释）。 */
      cg = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2,
                                         (int32_t)(inv != 0 ? -dy : dy),
                                         (int32_t)(inv != 0 ? -dx : dx));
      if (cg == NULL) {
        return -1;
      }
      e = [NSEvent eventWithCGEvent:cg];
      CFRelease(cg);
      if (e == nil) {
        return -1;
      }
      /* 同步派发：监听在本次调用里跑完，测试当场能断言。`CGEventPost` 那条真
       * 路试过——事件进不到我们的队列（WindowServer 按位置路由，测试进程的
       * 窗口层叠时序不可控），于是退回直派。
       *
       * 代价两处，都记在这里而不是等下一个人重新发现：①合成事件没有
       * windowNumber（AppKit 不补），落点由投送侧登记的窗口给（见
       * `moonui_native_synth_wheel_win`），不是由坐标反查给——mac 侧滚轮的
       * target 恒报窗口自己，那一维本来也不参与；②事件因此不会被 NSScrollView
       * 真正消费，"滚轮真把滚动容器滚了"这一半这条脚手架证明不了（Core 侧
       * 也没有读回视口偏移的口子）。它证明的是"监听真看见这一发 + 增量换算
       * 的往返自逆"。 */
      moonui_native_synth_wheel_win = win;
      moonui_native_synth_wheel_owner = owner;
      [NSApp sendEvent:e];
      moonui_native_synth_wheel_win = nil;
      moonui_native_synth_wheel_owner = nil;
      return 0;
    }
    {
      int down_type;
      int up_type;
      int drag_type;
      if (moonui_native_mouse_types_of(button, &down_type, &up_type,
                                       &drag_type) != 0) {
        return -1;
      }
      if (kind == 2) {
        NSEvent *e;
        e = [NSEvent mouseEventWithType:(NSEventType)drag_type
                               location:in_window
                          modifierFlags:0
                              timestamp:now
                           windowNumber:wnum
                                context:nil
                            eventNumber:0
                             clickCount:0
                               pressure:0.0];
        if (e == nil) {
          return -1;
        }
        [NSApp sendEvent:e];
        return 0;
      }
      {
        NSEvent *down1;
        NSEvent *up1;
        if (kind == 1) {
          up1 = [NSEvent mouseEventWithType:(NSEventType)up_type
                                   location:in_window
                              modifierFlags:0
                                  timestamp:now
                               windowNumber:wnum
                                    context:nil
                                eventNumber:0
                                 clickCount:1
                                   pressure:0.0];
          if (up1 == nil) {
            return -1;
          }
          [NSApp sendEvent:up1];
          return 0;
        }
        down1 = [NSEvent mouseEventWithType:(NSEventType)down_type
                                   location:in_window
                              modifierFlags:0
                                  timestamp:now
                               windowNumber:wnum
                                    context:nil
                                eventNumber:0
                                 clickCount:1
                                   pressure:1.0];
        up1 = [NSEvent mouseEventWithType:(NSEventType)up_type
                                 location:in_window
                            modifierFlags:0
                                timestamp:now
                             windowNumber:wnum
                                  context:nil
                              eventNumber:0
                               clickCount:1
                                 pressure:0.0];
        if (down1 == nil || up1 == nil) {
          return -1;
        }
        /* 配套的抬起**先排进队列**：会自跑的控件（NSButton 这一类）在自己的
         * tracking 循环里从队列取那一颗，取不到就挂死。取到之后循环结束，
         * 剩下的（双击的第二对）在测试下一圈 drain 时被 NSApp 正常派发，
         * 监听照样看得到——第二次按下带 clickCount 2，报的正是 kind 3。 */
        [NSApp postEvent:up1 atStart:NO];
        if (kind == 3) {
          NSEvent *down2;
          NSEvent *up2;
          down2 = [NSEvent mouseEventWithType:(NSEventType)down_type
                                     location:in_window
                                modifierFlags:0
                                    timestamp:now
                                 windowNumber:wnum
                                      context:nil
                                  eventNumber:0
                                   clickCount:2
                                     pressure:1.0];
          up2 = [NSEvent mouseEventWithType:(NSEventType)up_type
                                   location:in_window
                              modifierFlags:0
                                  timestamp:now
                               windowNumber:wnum
                                    context:nil
                                eventNumber:0
                                 clickCount:2
                                   pressure:0.0];
          if (down2 == nil || up2 == nil) {
            return -1;
          }
          [NSApp postEvent:down2 atStart:NO];
          [NSApp postEvent:up2 atStart:NO];
        }
        [NSApp sendEvent:down1];
        return 0;
      }
    }
  }
}

int moonui_native_type_text_in_window(const char *title, int title_len, int x, int y,
                               const char *text, int text_len) {
  char *t;
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSView *owner;
  CGFloat scale;
  CGFloat h;
  NSPoint wpt;
  NSTextView *editor;
  NSString *ns;
  TRACE("type_text_in_window");
  t = moonui_native_dup(text, text_len);
  if (t == 0) {
    return -1;
  }
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    free(t);
    return -2;
  }
  content = [win contentView];
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  wpt = [content
      convertPoint:NSMakePoint(moonui_native_px_to_pt(x, scale), h - moonui_native_px_to_pt(y, scale))
              toView:nil];
  hit = [content hitTest:wpt];
  if (hit == nil) {
    free(t);
    return -3; /* 真命不中：点在窗口外 */
  }
  owner = moonui_native_hit_owner(hit);
  if (owner == nil) {
    free(t);
    return -4; /* 命中空白：adapter.h 的空白档 */
  }
  /* 单行文本框（kind 2）与密码框（kind 4）才收打字（kind 表见
   * moonui_native_widget_kind_of）；其它种类报 -4。 */
  if (moonui_native_widget_kind_of(owner) != 2 &&
      moonui_native_widget_kind_of(owner) != 4) {
    free(t);
    return -4;
  }
  if (![win makeFirstResponder:owner]) {
    free(t);
    return -5;
  }
  editor = (NSTextView *)[win fieldEditor:YES forObject:owner];
  if (editor == nil || ![editor isEditable]) {
    free(t);
    return -5;
  }
  @autoreleasepool {
    ns = [NSString stringWithUTF8String:t];
    free(t);
    if (ns == nil) {
      return -1;
    }
    /* 插入点收到文末（"往哪儿插"是测试自己定的前提）——field editor 初始
     * 是全选态，不收就整串替换（`T103` 真跑咬出：'预置' 被替换成 '世界'）。
     * 整串一次插入，文本系统真改内容、真发 controlTextDidChange:，与真人
     * 打字同一条路。replacementRange 用 notFound（沿用当下选中区）。 */
    [editor setSelectedRange:NSMakeRange([[editor string] length], 0)];
    [editor insertText:ns replacementRange:NSMakeRange(NSNotFound, 0)];
  }
  return 0;
}

int moonui_native_focus_widget_in_window(const char *title, int title_len, int x, int y) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSView *owner;
  CGFloat scale;
  CGFloat h;
  NSPoint wpt;
  NSResponder *resp;
  NSView *got;
  TRACE("focus_widget_in_window");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  content = [win contentView];
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  wpt = [content
      convertPoint:NSMakePoint(moonui_native_px_to_pt(x, scale), h - moonui_native_px_to_pt(y, scale))
              toView:nil];
  hit = [content hitTest:wpt];
  if (hit == nil) {
    return -3; /* 真命不中：点在窗口外 */
  }
  owner = moonui_native_hit_owner(hit);
  if (owner == nil) {
    /* 窗口空白处：adapter.h 明确归 -4 这一档（不是 -3）。 */
    return -4;
  }
  /* 与 send_key 同一前提：真实场景用户正用着这个窗口。激活有异步延迟，
   * 在这里（改焦点时）就摆到位，send_key 那一侧多半已是 no-op（`T103`）。 */
  if (![win isKeyWindow]) {
    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];
    [win makeKeyWindow];
  }
  if (![win makeFirstResponder:owner]) {
    return -4;
  }
  /* 判据是回读（与 moonui_focused_control 同一个反查）：firstResponder 沿
   * owner 表退回来还得是同一只——AppKit 答应了但焦点漂走的形状在这里现形。 */
  resp = [win firstResponder];
  got = [resp isKindOfClass:[NSView class]]
            ? moonui_native_hit_owner((NSView *)resp)
            : nil;
  return got == owner ? 0 : -4;
}

/* ---- 输入法组合的测试替投（`T90④`）----
 *
 * 真输入法要人在键盘上打一串拼音再选词，自动化爬起来比拖拽还难；这里替投
 * 输入法**真正调的那两个 NSTextInputClient 方法**：组合进行中是
 * `setMarkedText:selectedRange:replacementRange:`，上屏是 `insertText:`
 * replacementRange:`。二者都直接改文本存储，于是相位推导、文本变化观察、
 * 控件自身的 delegate 全都照真人那条路走——判据读的是 Core 收到的事件序列。
 *
 * 坐标口径与 click/type_text 一致（客户区左上原点、y 向下、物理像素），命中
 * 后按 kind 认编辑视图：单行/密码框是共享 field editor，多行是容器自己的
 * NSTextView（`T90④` 补的那一半）。 */

/* 命中控件并把焦点摆过去，回填编辑视图。返回码同其余脚手架：
 * 0 成功，-2 找不到窗口，-3 窗口外，-4 命中的不是文本控件，-5 拿不到编辑视图。 */
static int moonui_native_ime_scaffold_editor(const char *title, int title_len,
                                             int x, int y, NSView **out_control,
                                             NSTextView **out_editor) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSView *owner;
  CGFloat scale;
  CGFloat h;
  NSPoint wpt;
  int kind;
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  content = [win contentView];
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  wpt = [content
      convertPoint:NSMakePoint(moonui_native_px_to_pt(x, scale), h - moonui_native_px_to_pt(y, scale))
              toView:nil];
  hit = [content hitTest:wpt];
  if (hit == nil) {
    return -3;
  }
  owner = moonui_native_hit_owner(hit);
  if (owner == nil) {
    return -4;
  }
  kind = moonui_native_widget_kind_of(owner);
  if (kind != 2 && kind != 4 && kind != 10) {
    return -4;
  }
  /* 与 send_key / focus 同一前提：监听按 keyWindow 的 firstResponder 解析归属，
   * 窗口不先成 key 就白投。 */
  if (![win isKeyWindow]) {
    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];
    [win makeKeyWindow];
  }
  if (![win makeFirstResponder:owner]) {
    return -5;
  }
  *out_control = owner;
  *out_editor = moonui_native_ime_editor_of(owner, kind);
  if (*out_editor == nil) {
    return -5;
  }
  return 0;
}

/* 等价于"输入法正在组合，标记串是 text"：`setMarkedText:` 的语义就是它。 */
int moonui_native_ime_compose_in_window(const char *title, int title_len, int x,
                                        int y, const char *text, int text_len) {
  char *t;
  NSView *control = nil;
  NSTextView *editor = nil;
  int rc;
  NSString *ns;
  TRACE("ime_compose_in_window");
  t = moonui_native_dup(text, text_len);
  if (t == 0) {
    return -1;
  }
  rc = moonui_native_ime_scaffold_editor(title, title_len, x, y, &control, &editor);
  if (rc != 0) {
    free(t);
    return rc;
  }
  @autoreleasepool {
    ns = [NSString stringWithUTF8String:t];
    free(t);
    if (ns == nil) {
      return -1;
    }
    /* 插入点只在"还没在组合中"时收到文末：真人打完已有文本再组合就是这个位置；
     * 已经在组合里时**不能动选择区**——移光标会先把标记区间清掉，于是相位里多
     * 出一条不该有的"结束"（`T90④` 真跑咬出）。 */
    if ([editor markedRange].location == NSNotFound) {
      [editor setSelectedRange:NSMakeRange([[editor string] length], 0)];
    }
    [editor setMarkedText:ns
           selectedRange:NSMakeRange([ns length], 0)
        replacementRange:NSMakeRange(NSNotFound, 0)];
  }
  return 0;
}

/* 等价于"输入法上屏"：`insertText:` 把标记串换成 text 并清掉标记区间。
 * text 传空串 = 取消这次组合（标记串被删掉），相位同样收"结束"。 */
int moonui_native_ime_commit_in_window(const char *title, int title_len, int x,
                                       int y, const char *text, int text_len) {
  char *t;
  NSView *control = nil;
  NSTextView *editor = nil;
  int rc;
  NSString *ns;
  TRACE("ime_commit_in_window");
  t = moonui_native_dup(text, text_len);
  if (t == 0) {
    return -1;
  }
  rc = moonui_native_ime_scaffold_editor(title, title_len, x, y, &control, &editor);
  if (rc != 0) {
    free(t);
    return rc;
  }
  @autoreleasepool {
    ns = [NSString stringWithUTF8String:t];
    free(t);
    if (ns == nil) {
      return -1;
    }
    [editor insertText:ns replacementRange:NSMakeRange(NSNotFound, 0)];
  }
  return 0;
}

/* ---- 文件拖入的测试替投（`T91③`）----
 *
 * 真拖一次要有人在屏幕上按住鼠标把文件从 Finder 拖进来，自动化做不到；这里拆
 * 成两件能断言的事：①用**真的** NSPasteboard 装好 file URL 对象，走 destination
 * 真正用的那条打包/通知路（`moonui_native_drop_take`）——路径→UTF-8→打包→
 * MoonBit 侧 unpack 的往返全在 ②命令行的读回里；②剩下那两条"谁接这次拖拽"的
 * 事实（窗口登记了 file URL 这一档、编辑中的 field editor 会自己接走）各给一个
 * 读回。真机拖拽的"光标形状/接受动画"仍要人眼，记在 TODO。 */

static int moonui_native_drop_last_ok = 0;

int moonui_native_simulate_file_drop(const char *title, int title_len,
                              const char *paths, int paths_len) {
  NSWindow *win;
  char *all;
  NSString *joined;
  NSArray *lines;
  NSMutableArray *urls;
  NSPasteboard *pb;
  TRACE("simulate_file_drop");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  all = moonui_native_dup(paths, paths_len);
  if (all == 0) {
    return -1;
  }
  @autoreleasepool {
    joined = [NSString stringWithUTF8String:all];
    free(all);
    if (joined == nil) {
      return -1;
    }
    /* 路径以 '\n' 分隔（路径里不会出现换行，这是测试自己的编码，不是产品契约）。 */
    lines = [joined componentsSeparatedByString:@"\n"];
    urls = [NSMutableArray array];
    for (NSString *p in lines) {
      if ([p length] == 0) {
        continue;
      }
      [urls addObject:[NSURL fileURLWithPath:p]];
    }
    if ([urls count] == 0) {
      return -1;
    }
    /* 唯一名的真 pasteboard：`writeObjects:` 写进去的就是 AppKit 拖拽时
     * `propertyListForType:NSPasteboardTypeFileURL` 读到的那个形状。 */
    pb = [NSPasteboard pasteboardWithUniqueName];
    [pb clearContents];
    [pb writeObjects:urls];
    moonui_native_drop_last_ok =
        moonui_native_drop_take((MoonuiWindow *)win, pb) ? 1 : 0;
    [pb releaseGlobally];
  }
  return 0;
}

/* 探针（打包见 adapter.h）：bit0 = 监听装着（destination 接不接受的那道门）、
 * bit1 = 窗口登记了 file URL 这一档拖入类型、bit2 = 上一次替投被 take 接住了。 */
int64_t moonui_native_file_drop_probe(const char *title, int title_len) {
  NSWindow *win;
  NSArray *types;
  int64_t bits = 0;
  TRACE("file_drop_probe");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  @autoreleasepool {
    if (moonui_native_drop_fn != 0) {
      bits |= 1;
    }
    types = [[win contentView] registeredDraggedTypes];
    if (types != nil && [types containsObject:NSPasteboardTypeFileURL]) {
      bits |= 2;
    }
    if (moonui_native_drop_last_ok) {
      bits |= 4;
    }
  }
  return bits;
}

/* 拖到这个点上，谁接？（`T91③` 的"field editor 拦截边界"）
 * 1 = 命中的是编辑中的 field editor（NSTextView 自己就是拖拽 destination，
 *     拖拽递退到它这一层就停了，窗口的 destination 不会被叫）；
 * 0 = 命中的是我们的非文本控件或窗口本体（没有更深的 view 认这类拖放，递退到
 *     窗口那一层）；
 * -2 = 找不到窗口，-3 = 点在客户区外。 */
int moonui_native_drag_hit_probe(const char *title, int title_len, int x, int y) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  CGFloat scale;
  CGFloat h;
  NSPoint in_content;
  NSPoint in_window;
  TRACE("drag_hit_probe");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  content = [win contentView];
  if (content == nil) {
    return -2;
  }
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  in_content = NSMakePoint(moonui_native_px_to_pt(x, scale),
                           h - moonui_native_px_to_pt(y, scale));
  in_window = [content convertPoint:in_content toView:nil];
  hit = [content hitTest:in_window];
  if (hit == nil) {
    return -3;
  }
  if ([hit isKindOfClass:[NSTextView class]]) {
    return 1;
  }
  return 0;
}

/* 圆点跟手探针（`T150`，契约在 adapter.h）：把指针拖到滑块宽度 `permille`
 * 处（真的走一遍 `NSSliderCell` 的跟踪循环），返回**自绘圆点圆心与"指针能到
 * 的那个圆心"之差**，单位百分之一点——0 就是圆点正在指针底下。
 *
 * 为什么基准是**指针**而不是真拇指框：真拇指框就是跟踪循环的输出，拿它跟我们
 * 的画法比只能证明"两边读的是同一份"，换谁来都绿。指针是输入——用户看见的正
 * 是"圆点在不在我按着的那个点上"。旧画法（`W * t`）在这条判据下 W=368 时最大
 * 差 11.55pt，新画法 1.94pt，阈值 5pt 就把两者分得干干净净。
 *
 * 两端按"可达区间"比较：拇指走到头后圆心被自己的半宽挡住，指针还能继续往外
 * 走，那不是漂。所以期望值取 `clamp(px, kt/2, W - kt/2)`，kt 是拇指厚。
 *
 * 那 1.94pt 是 AppKit 自己的量化（它把拇指原点按半点点跳），不是画法引入的：
 * 同一个 pm 上真拇指框本来就落在那里。
 *
 * -2147483648 = 句柄不是滑块宿主或宽度为零。**两平台各一份**：Windows 半的
 * "指针能到的圆心"取通道框的中点区间（`TBM_GETCHANNELRECT`），也是条子自己
 * 算的，与我们的画法无关。 */
int64_t moonui_native_slider_knob_probe(moonui_ptr c, int permille) {
  NSView *v = (NSView *)(uintptr_t)c;
  NSSlider *s;
  NSSliderCell *cell;
  NSRect b;
  double lo, hi, t;
  CGFloat d, cx, px, kt, expect, err;
  int64_t out;
  NSPoint start;
  NSPoint at;
  TRACE("slider_knob_probe");
  if (v == nil || ![v isKindOfClass:[MoonuiNativeSliderHost class]]) {
    return (int64_t)-2147483648LL;
  }
  @autoreleasepool {
    s = [(MoonuiNativeSliderHost *)v inner];
    if (s == nil) {
      return (int64_t)-2147483648LL;
    }
    b = [s bounds];
    if (b.size.width <= 0.0 || b.size.height <= 0.0) {
      return (int64_t)-2147483648LL;
    }
    if (permille < 0) {
      permille = 0;
    }
    if (permille > 1000) {
      permille = 1000;
    }
    cell = (NSSliderCell *)[s cell];
    if (cell == nil) {
      return (int64_t)-2147483648LL;
    }
    /* 真走一遍跟踪循环：按下点必须是**拇指此刻的位置**，再连续拖到目标点。
     * 跟踪循环按"按住点与拇指中心的偏移"换算，起点随便给一个地方，第一格就
     * 会凭空偏一段（本机量过：起点取宽度中点时 W=368 差 9.2pt，取拇指中心
     * 差 0.2pt）。这条链与真鼠标完全同一份——用户按下时也正按在拇指上。 */
    px = b.size.width * (double)permille / 1000.0;
    start = NSMakePoint(NSMidX([cell knobRectFlipped:YES]),
                        b.size.height / 2.0);
    at = NSMakePoint(px, b.size.height / 2.0);
    [cell startTrackingAt:start inView:s];
    [cell continueTracking:start at:at inView:s];
    lo = [s minValue];
    hi = [s maxValue];
    t = (hi > lo) ? ([s doubleValue] - lo) / (hi - lo) : 0.0;
    if (t < 0.0) {
      t = 0.0;
    }
    if (t > 1.0) {
      t = 1.0;
    }
    d = [(MoonuiNativeSliderHost *)v knobDiameter];
    if (d <= 0.0) {
      d = 12.0;
    }
    if (d > b.size.height) {
      d = b.size.height;
    }
    if (!moonui_native_slider_knob_cx(s, b.size.width, t, d, &cx)) {
      /* 没有真拇指可锚时这个分支本身就是旧映射——如实报出它离指针多远。 */
      cx = b.size.width * t;
    }
    kt = [cell knobThickness];
    if (kt <= 0.0 || kt >= b.size.width) {
      expect = px;
    } else {
      expect = px < kt / 2.0 ? kt / 2.0
                             : (px > b.size.width - kt / 2.0
                                    ? b.size.width - kt / 2.0
                                    : px);
    }
    err = cx - expect;
    out = (int64_t)(err * 100.0 + (err >= 0.0 ? 0.5 : -0.5));
  }
  return out;
}

/* "在轨道上点一下，圆点当场落在哪儿"（`T157`，契约在 adapter.h）：按下点取
 * **指针处**（点轨道），不是拇指中心（拖动）。取值时机必须是按下之后的**第一
 * 帧**——AppKit 那段约 270ms 的拇指动画还没收尾，框仍是途中值，缺陷就在这一
 * 刻露头；推进 runloop 之后再问，动画收尾、两种画法给出的答案一样，判据就空
 * 转了。
 *
 * 起点先摆到 `from_pm` 并且**等动画落定**（30ms 一跳、连续两跳框不动为止，
 * 至多 600ms）：不摆的话量到的是上一次跳转的残余，读数是噪声。 */
int64_t moonui_native_slider_click_probe(moonui_ptr c, int from_pm, int to_pm) {
  NSView *v = (NSView *)(uintptr_t)c;
  NSSlider *s;
  NSSliderCell *cell;
  NSRect b;
  double lo, hi, t;
  CGFloat d, cx, px, kt, expect, err;
  int64_t out;
  int i;
  if (v == nil || ![v isKindOfClass:[MoonuiNativeSliderHost class]]) {
    return (int64_t)-2147483648LL;
  }
  @autoreleasepool {
    s = [(MoonuiNativeSliderHost *)v inner];
    if (s == nil) {
      return (int64_t)-2147483648LL;
    }
    b = [s bounds];
    if (b.size.width <= 0.0 || b.size.height <= 0.0) {
      return (int64_t)-2147483648LL;
    }
    if (from_pm < 0) {
      from_pm = 0;
    }
    if (from_pm > 1000) {
      from_pm = 1000;
    }
    if (to_pm < 0) {
      to_pm = 0;
    }
    if (to_pm > 1000) {
      to_pm = 1000;
    }
    cell = (NSSliderCell *)[s cell];
    if (cell == nil) {
      return (int64_t)-2147483648LL;
    }
    /* 起点就位：设值会让拇指滑过去，等它停（连续两跳同一位置）。 */
    lo = [s minValue];
    hi = [s maxValue];
    [s setDoubleValue:lo + (hi - lo) * (double)from_pm / 1000.0];
    {
      CGFloat prev = -1.0;
      int still = 0;
      for (i = 0; i < 20 && still < 2; i++) {
        CGFloat now_cx;
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
        now_cx = NSMidX([cell knobRectFlipped:YES]);
        still = (fabs((double)now_cx - (double)prev) <= 0.5) ? still + 1 : 0;
        prev = now_cx;
      }
    }
    /* 点轨道：按下点 = 指针处。**不推进 runloop**——缺陷只在动画途中露头。 */
    px = b.size.width * (double)to_pm / 1000.0;
    [cell startTrackingAt:NSMakePoint(px, b.size.height / 2.0) inView:s];
    t = (hi > lo) ? ([s doubleValue] - lo) / (hi - lo) : 0.0;
    if (t < 0.0) {
      t = 0.0;
    }
    if (t > 1.0) {
      t = 1.0;
    }
    d = [(MoonuiNativeSliderHost *)v knobDiameter];
    if (d <= 0.0) {
      d = 12.0;
    }
    if (d > b.size.height) {
      d = b.size.height;
    }
    if (!moonui_native_slider_knob_cx(s, b.size.width, t, d, &cx)) {
      cx = b.size.width * t;
    }
    kt = [cell knobThickness];
    if (kt <= 0.0 || kt >= b.size.width) {
      expect = px;
    } else {
      expect = px < kt / 2.0 ? kt / 2.0
                             : (px > b.size.width - kt / 2.0
                                    ? b.size.width - kt / 2.0
                                    : px);
    }
    err = cx - expect;
    out = (int64_t)(err * 100.0 + (err >= 0.0 ? 0.5 : -0.5));
  }
  return out;
}

/* 图标姿态读回探针（`T130`，契约在 adapter.h）：命中处 Button 的 imagePosition
 * 与"装没装图"。为什么读字段不读像素：这条缺陷的全部证据就是 AppKit 在
 * setTitle:/setAttributedTitle: 里把 imagePosition 从 NSImageOnly 悄悄重置回
 * NSImageOverlaps——字段本身是这条契约最直接的读回，像素在 mac 上没有确定
 * 入口（layer 底色由 AppKit 自己画）。 */
int64_t moonui_native_icon_pose_probe(const char *title, int title_len, int x,
                                      int y) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSPoint in_window;
  CGFloat scale;
  CGFloat h;
  NSPoint in_content;
  int64_t packed;
  TRACE("icon_pose_probe");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return 1L << 16;
  }
  content = [win contentView];
  if (content == nil) {
    return 1L << 16;
  }
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  in_content = NSMakePoint(moonui_native_px_to_pt(x, scale),
                           h - moonui_native_px_to_pt(y, scale));
  @autoreleasepool {
    NSButton *btn;
    in_window = [content convertPoint:in_content toView:nil];
    hit = [content hitTest:in_window];
    if (hit == nil) {
      return 3L << 16;
    }
    if (moonui_native_widget_kind_of(hit) != 1) { /* 仅 Button */
      return 2L << 16;
    }
    btn = (NSButton *)hit;
    packed = (int64_t)[btn imagePosition];
    if ([btn image] != nil) {
      packed |= (1L << 8);
    }
    if ([btn contentTintColor] != nil) {
      packed |= (1L << 9);
    }
  }
  return packed;
}

/* 手势替投的共用一步（`T100`，契约在 adapter.h 手势段的脚手架那节）：
 * 按坐标命中反查 target（退到第一个带 owner 记号的 view，退不到就是窗口
 * 自己——与产品路径的 `moonui_native_gesture_target_of` 同一套口径），再走
 * 产品路径同一个派发口 `moonui_native_gesture_dispatch`。
 *
 * 三支脚手架各对应 AppKit 的一个手势回调，只是把"从 NSEvent 读什么"换成
 * 参数——AppKit 没有公开入口造 gesture NSEvent（`otherEventWithType:` 不收
 * 这三个类型、`CGEvent` 也没有对应类型），所以真"捏一下"这一格只能人手走，
 * 这里验的是派发之后的那整条链。 */
static int moonui_native_gesture_scaffold(const char *title, int title_len, int x,
                                          int y, int kind, double value,
                                          int phase, int direction) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSView *owner;
  CGFloat scale;
  CGFloat h;
  NSPoint wpt;
  moonui_ptr target;
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -2;
  }
  content = [win contentView];
  if (content == nil) {
    return -2;
  }
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  /* 坐标口径同 click_button_in_window：左上原点物理 px → contentView 坐标
   * → 窗口底座坐标（hitTest 的口径）。布局摆错了就命不中，测试因此也钉住
   * "控件真在 MoonUI 以为的位置上"。 */
  wpt = [content
      convertPoint:NSMakePoint(moonui_native_px_to_pt(x, scale),
                               h - moonui_native_px_to_pt(y, scale))
              toView:nil];
  hit = [content hitTest:wpt];
  if (hit == nil) {
    return -3; /* 点在客户区外 */
  }
  owner = moonui_native_hit_owner(hit);
  target = owner != nil ? (moonui_ptr)(uintptr_t)owner
                        : (moonui_ptr)(uintptr_t)win;
  moonui_native_gesture_dispatch(target, kind, phase, direction, value);
  return 0;
}

int moonui_native_magnify_in_window(const char *title, int title_len, int x, int y,
                                    int64_t value_micro, int phase) {
  TRACE("magnify_in_window");
  /* 捏合那一支收的就是 ABI 的增量（定点百万分之一），与 `NSEvent.magnification`
   * 同一个单位——不换算。 */
  return moonui_native_gesture_scaffold(title, title_len, x, y, 0,
                                        (double)value_micro / 1000000.0, phase, 0);
}

int moonui_native_rotate_in_window(const char *title, int title_len, int x, int y,
                                   int64_t value_micro, int phase) {
  TRACE("rotate_in_window");
  /* 旋转这支收的是**角度**（定点百万分之一），与 `NSEvent.rotation` 同一个
   * 单位——换算与产品路径共用 `moonui_native_rad_of_deg`，于是"只换一次、
   * 换的方向对"这两件事被断言钉住（`T100` 的真窗测试第②段）。 */
  return moonui_native_gesture_scaffold(
      title, title_len, x, y, 1,
      moonui_native_rad_of_deg((double)value_micro / 1000000.0), phase, 0);
}

int moonui_native_swipe_in_window(const char *title, int title_len, int x, int y,
                                  int direction) {
  TRACE("swipe_in_window");
  /* 滑动是离散事件：相位恒 1（changed）、价量恒 0，见 adapter.h 手势段。 */
  return moonui_native_gesture_scaffold(title, title_len, x, y, 2, 0.0, 1,
                                        direction);
}

/* ---- 自定义绘制面的探针（`T101` 的真窗判据，adapter.h 脚手架段）----
 *
 * 为什么读 layer.contents 而不是重跑一遍绘制：`present` 之后这块面**唯一**的
 * 真话就是图层里那张 CGImage——它就是 begin_frame 的位图本身（同一个
 * CGDataProvider），读它等于读"这一帧到底画成了什么"。重跑一遍只会证明
 * "清单重放是对的"，证明不了"位图真贴到了这只 view 上"。
 *
 * 代价写明：这只证明"我们的图层里有这些像素"，不证明"合成器把它们扫到了
 * 屏幕上"（那需要真人看屏幕，与托盘真弹窗同一档）。 */
static int64_t moonui_native_cgimage_pixel(CGImageRef img, int x, int y) {
  size_t w = CGImageGetWidth(img);
  size_t h = CGImageGetHeight(img);
  uint8_t px[4] = {0, 0, 0, 0};
  CGColorSpaceRef space;
  CGContextRef ctx;
  if (x < 0 || y < 0 || (size_t)x >= w || (size_t)y >= h) {
    return -1;
  }
  space = CGColorSpaceCreateDeviceRGB();
  if (space == nil) {
    return -1;
  }
  ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, space,
                              kCGBitmapByteOrder32Big |
                                  kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (ctx == nil) {
    return -1;
  }
  /* 把目标像素挪到 1×1 上下文的 (0,0)：CG 的 y 向上、图像缓冲区第 0 行在顶，
   * 所以 y 要按 (h-1-y) 翻一次。 */
  CGContextDrawImage(ctx, CGRectMake(-(CGFloat)x, -(CGFloat)(h - 1 - (size_t)y),
                                     (CGFloat)w, (CGFloat)h),
                     img);
  CGContextRelease(ctx);
  return ((int64_t)px[0] << 24) | ((int64_t)px[1] << 16) |
         ((int64_t)px[2] << 8) | (int64_t)px[3];
}

int64_t moonui_native_custom_probe(const char *title, int title_len, int x, int y) {
  NSWindow *win;
  NSView *content;
  NSView *hit;
  NSView *owner;
  CGFloat scale;
  CGFloat h;
  NSPoint wpt;
  NSPoint lp;
  CGImageRef img;
  id contents;
  int vx;
  int vy;
  TRACE("custom_probe");
  win = moonui_native_scaffold_window(title, title_len);
  if (win == nil) {
    return -1;
  }
  content = [win contentView];
  if (content == nil) {
    return -1;
  }
  scale = moonui_native_window_scale_of(win);
  h = [content bounds].size.height;
  /* 坐标口径同 click_button_in_window：左上原点物理 px。 */
  wpt = [content
      convertPoint:NSMakePoint(moonui_native_px_to_pt(x, scale),
                               h - moonui_native_px_to_pt(y, scale))
              toView:nil];
  hit = [content hitTest:wpt];
  if (hit == nil) {
    return -2; /* 点在客户区外 */
  }
  owner = moonui_native_hit_owner(hit);
  if (owner == nil || moonui_native_widget_kind_of(owner) != 18) {
    return -2; /* 这一处不是自定义绘制面 */
  }
  contents = [[owner layer] contents];
  if (contents == nil) {
    return -3; /* 面在、但还没 present 过 */
  }
  if (CFGetTypeID((CFTypeRef)contents) != CGImageGetTypeID()) {
    return -3;
  }
  img = (CGImageRef)contents;
  /* 局部坐标（视图是 flipped 的，转换直接给"左上原点"那份）→ 位图像素。
   * 位图的像素尺寸 = 视图的点尺寸 × scale（开帧时按这个比例开的）。 */
  lp = [owner convertPoint:wpt fromView:nil];
  vx = (int)floor(lp.x * scale);
  vy = (int)floor(lp.y * scale);
  return moonui_native_cgimage_pixel(img, vx, vy);
}
