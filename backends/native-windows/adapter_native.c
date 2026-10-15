/* 原生 Win32 C Adapter（§51 的 Backend #2，Windows 半）。
 *
 * 这份实现**不经过 libui-ng**：窗口、控件、事件循环全部直写 Win32，
 * 与 ../libui-windows/adapter.c 导出同一套 moonui_native_* ABI（契约在
 * ../libui-common/adapter.h），所以共享的 MoonBit 层
 * （../native-common 的 ffi.mbt + backend.mbt）一个字都不用改，换后端只换链接
 * 那一档（§47"分叉只到 C 为止"）。和 mac 那份
 * （../native-macos/adapter_native.m）一对：那边直写 Cocoa，这边直写 Win32。
 *
 * 与 adapter.c（libui 那份）的分叉清单，按文件顺序：
 *   1. 句柄就是 HWND 本身。adapter.c 里 moonui_ptr 是 uiControl*，要经
 *      uiControlHandle 换一手；这里 moonui_native_hwnd 是恒等映射，
 *      T74 那张 moonui_native_scrolls 集合（scroll-vs-uiControl 的分叉判据）整张删掉。
 *   2. moonui_native_init 不再调 uiInit：InitCommonControlsEx（manifest 那条 pragma
 *      原样保留，Common Controls v6 全靠它），注册顶层窗口类
 *      L"MoonuiWndClass" 和单选组容器类 L"MoonuiContainerClass"。park 窗口
 *      兼任隐藏消息窗口（T75 设计定案）。
 *   3. 自己的顶层窗口过程替换 libui 的 windowWndProc + runWM_COMMAND 路由：
 *      WM_CLOSE 只报 closing 槽、返回 0 否决（销毁留给 Core）；WM_SIZE 报
 *      resized 槽；WM_COMMAND 按 lParam 分流——lParam!=0 是控件通知
 *      （BN_CLICKED / EN_CHANGE / CBN_SELCHANGE），lParam==0 且 HIWORD==0
 *      是菜单命令（id >= 0x4000 基址）；WM_HSCROLL（lParam 是 trackbar）报
 *      slider；WM_NOTIFY 的 DTN_DATETIMECHANGE 报 datepicker。菜单不需要
 *      adapter.c 那层子类化——窗口过程本来就是我们的。
 *   4. 回调登记不再走 libui 的 On* + trampoline，改成"槽位号记在 HWND 属性表
 *      上"（moonui.slot.* 那组 prop），窗口过程按事件类型读对应的 prop 再
 *      fire。程序赋值不回声（EN_CHANGE 抑制）照 libui 的 inhibitChanged 做：
 *      赋值前后立 / 清 moonui.inhibit 这一位 prop，WM_COMMAND 那侧看到就吞掉。
 *   5. Spinbox 是 edit + 附着的 updown 兄弟（UDS_SETBUDDYINT|UDS_ALIGNRIGHT），
 *      句柄取 edit；updown 记在 edit 的属性表上，重挂 / 销毁 / 摆放都要跟着走。
 *   6. 全屏用 WINDOWPLACEMENT 存 / 还（去 WS_OVERLAPPEDWINDOW、SetWindowPos
 *      到监视器 rcMonitor），状态记在逐窗口登记表里（和菜单 / 图标 / 焦点链
 *      同一张表）。
 *   7. 事件循环照 mac 原生那份：moonui_native_quit 只立 loop_ended 标志，不
 *      PostQuitMessage——终止语义由 MoonBit 侧收尾，进程不在这里退。
 *
 * 能逐段平移的（DPI、主题、剪贴板、对话框、文件面板、菜单树、图标、
 * 键盘 / 鼠标钩子、测试脚手架）全部照 adapter.c 原样搬运，只把
 * moonui_native_hwnd 的换算改成恒等、把注释里 libui 的行号引用改成本文件的对应节。
 *
 * `#if defined(_WIN32)` 是防线不是必需品，理由与 adapter.c 同一条：本文件
 * 只属于 Windows，本机实测在 mac 上点名编译时得到空 TU 而不是撞 windows.h。
 */
#if defined(_WIN32)
#include "../libui-common/adapter.h"

#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include <windows.h>

/* 文件面板那半要用 IFileDialog（§24 / §48-18）：COM 初始化与 CLSID/IID 来自
 * objbase.h，对话框接口来自 shobjidl.h。链接清单里 ole32.lib / uuid.lib
 * 由 prebuild-link.js 的 windowsNativeLinkFlags 给（moon.pkg 里没有链接段）。 */
#include <objbase.h>
#include <shobjidl.h>

/* 无障碍那半要 MSAA 的属性标注（§32 / T41）：角色/状态是 IAccPropServices 的
 * PROPID_ACC_* 那组 GUID。不先包 <initguid.h> 就展开成 extern 引用，而
 * Windows SDK 10.0.22000 的 oleacc.lib 并不出这几个符号（adapter.c 的 T60
 * 量出来的五个 LNK2001）。这里照抄：initguid 让本翻译单元自己定义。 */
#include <initguid.h>
#include <oleacc.h>
#include <oleauto.h>

/* 直写 Win32 的控件：TRACKBAR_CLASSW / UPDOWN_CLASSW / PROGRESS_CLASSW /
 * DATETIMEPICK_CLASSW / InitCommonControlsEx 都在 commctrl.h。libui 那份是
 * 从 ui_windows.h 间接带进来的，这里自己包。 */
#include <commctrl.h>

/* DatePicker 的文字通道翻 SYSTEMTIME，格式化用 sscanf/snprintf。 */
#include <stdio.h>

/* libui 的 Windows 后端把 manifest（Common Controls v6 + DPI 感知）编在 DLL
 * 里；我们链的是裸 CRT + 系统库，manifest 必须自己声明。少了它，
 * InitCommonControlsEx 只拿到旧版控件（trackbar / updown 直接建不出来）。
 * cl.exe 才认这条 pragma：MinGW 的 gcc 不认识它，见一个报一个 -Wunknown-pragmas
 * （本文件在 mac 上要过 mingw 语法门禁），所以用 _MSC_VER 圈起来——真正的
 * Windows 构建走的就是 cl.exe。 */
#ifdef _MSC_VER
#pragma comment(linker,                                                      \
                "\"/manifestdependency:type='Win32'                         \
name='Microsoft.Windows.Common-Controls' version='6.0.0.0'                  \
processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")
#endif

/* 排查"死在哪一次 FFI 调用"用的开关（和 adapter.c 同一条）：打开方式是
 * prebuild-link.js 的 compileNativeAdapter 给 cl.exe 多带一条 /DMOONUI_TRACE。 */
#ifdef MOONUI_TRACE
#include <stdio.h>
#define TRACE(name)                  \
  do {                               \
    printf("[trace] %s\n", (name));  \
    fflush(stdout);                  \
  } while (0)
#else
#define TRACE(name) ((void)0)
#endif

/* 控件回调的槽位表。C 必须替 MoonBit 看守闭包的生命周期：Win32 只记函数指针
 * + void*，GC 看不见它，不 incref 回来的就是尸体（§47 风险 1）。
 * 一个控件一个回调、一个窗口两个回调（closing / resized），96 个对当前
 * 的 Demo 和测试都很够用；用满时注册返回 -1，MoonBit 侧变成显式错误。 */
#define MOONUI_SLOTS 96

typedef struct {
  void *owner;
  moonui_closure_fn fn;
  void *closure;
} MoonuiSlot;

static MoonuiSlot moonui_native_slots[MOONUI_SLOTS];
static char moonui_native_error[512];

/* 初始化是进程级单例（窗口类注册一次、park 一只），所以当单例看守：初始化
 * 幂等，未初始化时退出也是空操作。MoonBit 侧的 initialize()/terminate()
 * 因此可以成对调用，不必担心同一个测试进程里跑了两条测试。 */
static int moonui_native_inited = 0;

/* attach 时给控件 HWND 分配的 ID 计数器，见 moonui_native_control_attach 的注释。 */
static int moonui_native_next_control_id = 0;

/* detach 之后控件的临时住所，兼任隐藏消息窗口（init 里建、terminate 里拆）。
 * 必须是自建的隐藏窗口：WM_COMMAND 是发给父窗口的，挂在这里就等于消息进
 * 不了任何真窗口的过程，摘下来的控件因此是"沉默"的。 */
static HWND moonui_native_park = 0;

/* 主循环已结束（moonui_native_quit 置位）。moonui_native_main_step 从这里开始返回 0，
 * 照抄 mac 原生那份的形状：不走 PostQuitMessage，进程不在这层退出。 */
static int moonui_native_loop_ended = 0;

/* 菜单栏那一整块写在文件后面（§25），窗口那几条要在建好之后把活窗口登记上、
 * 按当下这棵树挂菜单位，这里先给一组前置声明。命令 id 的基址与那份全局点击
 * 回调也在这里声明：顶层窗口过程的 WM_COMMAND 要用。 */
#define MOONUI_MENU_ID_BASE 0x4000
static int moonui_native_menu_wanted(void);
static void moonui_native_menu_register(HWND hwnd);
static void moonui_native_icon_apply(HWND hwnd);
static void moonui_native_menu_unregister(HWND hwnd);
static void moonui_native_menu_clear_all(void);
static moonui_closure_id_fn moonui_native_menu_fn;
static void *moonui_native_menu_closure;
static void moonui_native_dispatch_command(HWND ctrl, int code);
static void moonui_native_radio_relayout(HWND container);
static void moonui_native_spinbox_place_updown(HWND edit);
static int moonui_native_spinbox_value(HWND edit);
/* 前台门命名空间化（2026-10-15）之前，这几条 ABI 的声明一直搭共享头
 * ../libui-common/adapter.h 的顺风车（旧名 moonui_X 同名）——头里声明的管旧名、
 * 定义换新名后，凡"调用点在定义之前"的都落进 C89 隐式声明（int f()），mingw
 * -fsyntax-only -Wall 撞出三条：datepicker_text（先调后定 + 返回 moonbit_bytes_t
 * 非零兼容，还外加 conflicting types）、system_dpi、datepicker_set_text。逐条
 * 按头里的签名补前向声明；其余 ABI 调用点恰好都在定义之后，不用补。 */
moonbit_bytes_t moonui_native_datepicker_text(moonui_ptr c);
int moonui_native_system_dpi(void);
int moonui_native_datepicker_set_text(moonui_ptr c, const char *text, int text_len);

/* ---- 逐窗口登记表 ----
 *
 * Win32 的菜单位、图标、全屏前置状态、焦点链全是**逐窗口**的，这里一张定长表
 * 登记"当下活着的顶层窗口"（moonui_native_window_new 登记、destroy 摘掉，64 只对
 * Demo 和测试都远够用；表满了窗口照建，只是没有菜单 / 全屏那些逐窗口的待遇）。
 * adapter.c 的同款表还抄了一份 libui 的窗口过程指针——这边窗口过程本来就是我
 * 们的，那一格没了。 */
#define MOONUI_MENU_WINDOWS 64

typedef struct {
  HWND hwnd;
  HMENU bar;
  /* 装上菜单后"客户区被挤掉的那一行"补不补、怎么补，全靠 menu_apply 现量
   * （见菜单栏那一节的注释）。 */
  int menu_pad;
  /* Core 声明的焦点链（`T29` 声明、`T66` 接上）：空格分隔的十进制 owner 指针
   * 进来，存成一只窗口一份。0 = 没声明过，Tab 走 Windows 默认（z-order 序）。 */
  moonui_ptr *focus_chain;
  int focus_chain_len;
  /* 全屏的进出状态（§12）：进入时存下 WINDOWPLACEMENT 和原风格，退出原样
   * 还原。fullscreen = 0 表示不在全屏。 */
  int fullscreen;
  LONG fs_style;
  WINDOWPLACEMENT fs_prev;
} MoonuiWindowMenu;

static MoonuiWindowMenu moonui_native_win_menu[MOONUI_MENU_WINDOWS];

static MoonuiWindowMenu *moonui_native_menu_entry_of(HWND hwnd) {
  int i;
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_native_win_menu[i].hwnd == hwnd) {
      return &moonui_native_win_menu[i];
    }
  }
  return 0;
}

static MoonuiWindowMenu *moonui_native_menu_free_slot(void) {
  int i;
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_native_win_menu[i].hwnd == 0) {
      return &moonui_native_win_menu[i];
    }
  }
  return 0;
}

/* 键盘 / 鼠标钩子（§32 / §48-16/17）写在文件后面，但 terminate 第一件事
 * 就是摘掉那两只钩子——摘晚了槽位排干之后还会来回调。 */
static void moonui_native_key_drop_hook(void);
static void moonui_native_mouse_drop_hook(void);

/* ---- 句柄与记号 ---- */

/* 本后端的核心约定：moonui_ptr 就是 HWND 的整数值（§51 Windows 半定案）。
 * 于是"原生对象 → moonui_ptr"是恒等，owner/kind/回调槽全部记在 HWND 自己的
 * 属性表上——属性跟着 HWND 一起没，不需要配对清理，也不会有第二张活对象表
 * （那份账在 MoonBit 的 HandleTable 里，两处记就一定分叉）。 */
static HWND moonui_native_hwnd(moonui_ptr c) { return (HWND)(uintptr_t)c; }

static const WCHAR moonui_native_owner_prop[] = L"moonui.owner";

static void moonui_native_mark_owner(HWND hwnd, moonui_ptr owner) {
  if (hwnd == 0 || owner == 0) {
    return;
  }
  SetPropW(hwnd, moonui_native_owner_prop, (HANDLE)(uintptr_t)owner);
}

static moonui_ptr moonui_native_owner_of(HWND hwnd) {
  if (hwnd == 0) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)GetPropW(hwnd, moonui_native_owner_prop);
}

/* ---- kind 记号（§13 的 0.2 批扩展控件）----
 *
 * 控件的种类创建时写一次、之后只读。用途只有一个：通用属性入口
 * （moonui_native_widget_set_value / append_option / set_selected / set_text）按它
 * 分派。这不是第二套活对象表：Core 的 WidgetKind 是唯一事实来源，这里只是
 * 它的一份只读副本，且"哪种控件有哪种属性"由 Core 在 widget.mbt 按 kind
 * 拦在前头。
 *
 * 编码与 adapter.h 的 kind 一致：0=Label … 5=Separator、6=Slider、7=Spinbox、
 * 8=Progress、9=ComboBox、10=MultilineEntry、11=RadioButtons、12=DatePicker、
 * 13=VSeparator、14=MenuRow、15=Scroll。存 kind+1，0 就还是"没有记号"。 */
static const WCHAR moonui_native_kind_prop[] = L"moonui.kind";

static void moonui_native_mark_kind(HWND hwnd, int kind) {
  if (hwnd != 0) {
    SetPropW(hwnd, moonui_native_kind_prop, (HANDLE)(uintptr_t)(kind + 1));
  }
}

static int moonui_native_kind_of_hwnd(HWND hwnd) {
  HANDLE v;
  if (hwnd == 0) {
    return -1;
  }
  v = GetPropW(hwnd, moonui_native_kind_prop);
  if (v == 0) {
    return -1;
  }
  return (int)(uintptr_t)v - 1;
}

static int moonui_native_kind_of(moonui_ptr c) {
  return moonui_native_kind_of_hwnd(moonui_native_hwnd(c));
}

/* 创建控件的公共尾巴：打 owner 与 kind 两个记号。返回非 0 表示成功。 */
static int moonui_native_finish_new(HWND hwnd, int kind) {
  if (hwnd == 0) {
    return 0;
  }
  moonui_native_mark_owner(hwnd, (moonui_ptr)(uintptr_t)hwnd);
  moonui_native_mark_kind(hwnd, kind);
  return 1;
}

/* ---- 回调槽位的 prop 记号 ----
 *
 * adapter.c 靠 libui 的 On* 各带一个 trampoline 区分"哪一格槽位对应哪种
 * 事件"；这里窗口过程是我们自己的，登记时把槽位号写进 HWND 的属性表、
 * 事件来了按 prop 名取出来 fire，一个类别一个 prop 名。prop 存槽位号+1，
 * 0 = 没登记过。 */
static const WCHAR moonui_native_slot_click_prop[] = L"moonui.slot.click";
static const WCHAR moonui_native_slot_text_prop[] = L"moonui.slot.text";
static const WCHAR moonui_native_slot_toggled_prop[] = L"moonui.slot.toggled";
static const WCHAR moonui_native_slot_changed_prop[] = L"moonui.slot.changed";
static const WCHAR moonui_native_slot_closing_prop[] = L"moonui.slot.closing";
static const WCHAR moonui_native_slot_resized_prop[] = L"moonui.slot.resized";

/* 程序赋值的回声抑制（对应 libui 各控件自己的 inhibitChanged）：置位期间
 * 到来的 EN_CHANGE / DTN_DATETIMECHANGE 一律吞掉。 */
static const WCHAR moonui_native_inhibit_prop[] = L"moonui.inhibit";

/* spinbox 的 updown 兄弟（见 moonui_native_spinbox_new 那节）。 */
static const WCHAR moonui_native_updown_prop[] = L"moonui.updown";

/* 单选组的子按钮名单（见 moonui_native_radio_new 那节）。 */
static const WCHAR moonui_native_radiokids_prop[] = L"moonui.radiokids";

static void moonui_native_set_slot_prop(HWND hwnd, const WCHAR *prop, int slot) {
  if (hwnd != 0) {
    SetPropW(hwnd, prop, (HANDLE)(uintptr_t)(slot + 1));
  }
}

/* 按 prop 名 fire 一格槽位。读回的 prop 可能指向一格已被 moonui_native_forget
 * 松开的槽（登记方销毁时才清 prop，正常顺序下不会，这里仍然查一遍 fn），
 * 查不到就什么都不做——"没有回调"和"回调还没装"是同一件事。 */
static void moonui_native_fire_slot_prop(HWND hwnd, const WCHAR *prop) {
  HANDLE v = GetPropW(hwnd, prop);
  MoonuiSlot *slot;
  if (v == 0) {
    return;
  }
  slot = &moonui_native_slots[(int)(uintptr_t)v - 1];
  if (slot->fn != 0) {
    slot->fn(slot->closure);
  }
}

static void moonui_native_inhibit(HWND hwnd) {
  SetPropW(hwnd, moonui_native_inhibit_prop, (HANDLE)1);
}

static void moonui_native_uninhibit(HWND hwnd) {
  RemovePropW(hwnd, moonui_native_inhibit_prop);
}

static int moonui_native_inhibited(HWND hwnd) {
  return GetPropW(hwnd, moonui_native_inhibit_prop) != 0;
}

static HWND moonui_native_updown_of(HWND edit) {
  if (edit == 0) {
    return 0;
  }
  return (HWND)(uintptr_t)GetPropW(edit, moonui_native_updown_prop);
}

/* 销毁 / 重挂前把 HWND 上所有 moonui 的 prop 摘干净：属性表本来就是 HWND 的
 * 一部分，DestroyWindow 会替我们清，但 spinbox 的 updown 是兄弟窗口、
 * 单选组的名单是堆上的结构，这两个必须在这里显式处理。 */
static void moonui_native_unmark_all(HWND hwnd) {
  HWND updown = moonui_native_updown_of(hwnd);
  HANDLE kids = GetPropW(hwnd, moonui_native_radiokids_prop);
  RemovePropW(hwnd, moonui_native_owner_prop);
  RemovePropW(hwnd, moonui_native_kind_prop);
  RemovePropW(hwnd, moonui_native_slot_click_prop);
  RemovePropW(hwnd, moonui_native_slot_text_prop);
  RemovePropW(hwnd, moonui_native_slot_toggled_prop);
  RemovePropW(hwnd, moonui_native_slot_changed_prop);
  RemovePropW(hwnd, moonui_native_slot_closing_prop);
  RemovePropW(hwnd, moonui_native_slot_resized_prop);
  RemovePropW(hwnd, moonui_native_inhibit_prop);
  RemovePropW(hwnd, moonui_native_updown_prop);
  RemovePropW(hwnd, moonui_native_radiokids_prop);
  if (updown != 0) {
    DestroyWindow(updown);
  }
  if (kids != 0) {
    free((void *)(uintptr_t)kids);
  }
}

/* ---- 小工具 ---- */

/* 两个 int32 打包进一个 int64：MoonBit 的 native FFI 只有单返回值。 */
static int64_t moonui_native_pack2(int a, int b) {
  return ((int64_t)(int32_t)a << 32) | (int64_t)(uint32_t)b;
}

/* MoonBit 的 Bytes 不保证 NUL 结尾，而 Win32 全收 UTF-16。复制一份转码是
 * 唯一不靠运气的做法，调用方负责 free。 */
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

static LPWSTR moonui_native_utf16_of(const char *s, int len) {
  LPWSTR out;
  int needed;
  if (s == 0 || len < 0) {
    return 0;
  }
  /* 空串单独走一发：cbMultiByte=0 在 MultiByteToWideChar 那里不是"零个字符"，
   * 而是"自己数到终止符"，而 MoonBit 的 Bytes 不保证 NUL 结尾，于是读过界。
   * 剪贴板那条踩过（TODO 的 `T19`），这里同一个坑同一个修法。 */
  if (len == 0) {
    out = (LPWSTR)malloc(sizeof(WCHAR));
    if (out == 0) {
      return 0;
    }
    out[0] = L'\0';
    return out;
  }
  needed = MultiByteToWideChar(CP_UTF8, 0, s, len, 0, 0);
  out = (LPWSTR)malloc(((size_t)needed + 1u) * sizeof(WCHAR));
  if (out == 0) {
    return 0;
  }
  if (needed > 0) {
    MultiByteToWideChar(CP_UTF8, 0, s, len, out, needed);
  }
  out[needed] = L'\0';
  return out;
}

static char *moonui_native_utf8_of(LPCWSTR w) {
  char *out;
  int needed;
  if (w == 0) {
    return 0;
  }
  needed = WideCharToMultiByte(CP_UTF8, 0, w, -1, 0, 0, 0, 0);
  if (needed <= 0) {
    return 0;
  }
  out = (char *)malloc((size_t)needed);
  if (out == 0) {
    return 0;
  }
  WideCharToMultiByte(CP_UTF8, 0, w, -1, out, needed, 0, 0);
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

/* 多行文本的换行契约（adapter.h）：进出 MoonBit 一律 LF，进出 Win32 的
 * EDIT 一律 CRLF。两条都是新开一块而不是原地改——长度只会涨，原地写要
 * 边界小心，不值得。 */
static LPWSTR moonui_native_lf_to_crlf(LPCWSTR w) {
  int n = 0;
  int crlf = 0;
  int i;
  LPWSTR out;
  if (w == 0) {
    return 0;
  }
  for (i = 0; w[i] != L'\0'; ++i) {
    if (w[i] == L'\n') {
      ++crlf;
    }
    ++n;
  }
  out = (LPWSTR)malloc(((size_t)n + (size_t)crlf + 1u) * sizeof(WCHAR));
  if (out == 0) {
    return 0;
  }
  {
    int o = 0;
    for (i = 0; w[i] != L'\0'; ++i) {
      if (w[i] == L'\n') {
        out[o++] = L'\r';
      }
      out[o++] = w[i];
    }
    out[o] = L'\0';
  }
  return out;
}

static LPWSTR moonui_native_crlf_to_lf(LPCWSTR w) {
  int n = 0;
  int i;
  LPWSTR out;
  if (w == 0) {
    return 0;
  }
  for (i = 0; w[i] != L'\0'; ++i) {
    if (w[i] == L'\r' && w[i + 1] == L'\n') {
      continue;
    }
    ++n;
  }
  out = (LPWSTR)malloc(((size_t)n + 1u) * sizeof(WCHAR));
  if (out == 0) {
    return 0;
  }
  {
    int o = 0;
    for (i = 0; w[i] != L'\0'; ++i) {
      if (w[i] == L'\r' && w[i + 1] == L'\n') {
        continue;
      }
      out[o++] = w[i];
    }
    out[o] = L'\0';
  }
  return out;
}

/* ---- 回调槽位 ---- */

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

/* ---- 度量：消息字体的 DLU 基准（照 libui 的 sizing.cpp 那套算法）----
 *
 * Win32 控件的"标准尺寸"全部以对话框单位（DLU）给出，DLU 又定义在系统
 * 消息字体上：SPI_GETNONCLIENTMETRICS 的 lfMessageFont 就是资源对话框、
 * 菜单、提示条用的那一套字。BaseX 用 52 个大小写字母的宽度取平均
 * （(cx/26+1)/2），BaseY 用 tmHeight——这是 Windows 自己 dialog base unit
 * 的算法，libui 也照它来，两个后端的 intrinsic 尺寸因此同一副口径。
 *
 * 每次现算不去缓存：度量入口只在 MoonBit 侧 minimum_size 那条链上被调，
 * 频率是布局节奏，CreateFontIndirectW + GetTextMetrics 一发的开销看不见。 */
static void moonui_native_sizing_base(HWND hwnd, int *base_x, int *base_y) {
  NONCLIENTMETRICSW ncm;
  HDC dc;
  HFONT font;
  HFONT old;
  TEXTMETRICW tm;
  int cx = 4;
  int cy = 8;
  (void)hwnd;
  memset(&ncm, 0, sizeof(ncm));
  ncm.cbSize = (DWORD)sizeof(ncm);
  if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, (DWORD)sizeof(ncm), &ncm,
                            0) != 0) {
    font = CreateFontIndirectW(&ncm.lfMessageFont);
    if (font != 0) {
      dc = GetDC(0);
      if (dc != 0) {
        old = (HFONT)SelectObject(dc, font);
        if (GetTextMetricsW(dc, &tm) != 0 && tm.tmHeight > 0) {
          SIZE size;
          static const WCHAR alphabet[] =
              L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
          if (GetTextExtentPoint32W(dc, alphabet, 52, &size) != 0 &&
              size.cx > 0) {
            cx = (size.cx / 26 + 1) / 2;
            cy = (int)tm.tmHeight;
          }
        }
        SelectObject(dc, old);
        ReleaseDC(0, dc);
      }
      DeleteObject(font);
    }
  }
  /* 三个兜底：拿不到消息字体（哪些精简系统）时退回 SM_CYMENU 再退回 96 基准
   * 的 4/8——这两个数就是"1 DLU = 1/4 字宽、1/8 字高"在默认字体下的值。 */
  if (cx <= 0) {
    cx = GetSystemMetrics(SM_CYMENU) > 0 ? 4 : 4;
  }
  if (cy <= 0) {
    cy = GetSystemMetrics(SM_CYMENU);
  }
  if (cy <= 0) {
    cy = 8;
  }
  *base_x = cx;
  *base_y = cy;
}

/* DLU → 物理像素。libui 的换算是 x 轴除 4、y 轴除 8（MulDiv 截断）。 */
static int moonui_native_dlu_x(HWND hwnd, int dlux) {
  int bx;
  int by;
  moonui_native_sizing_base(hwnd, &bx, &by);
  return MulDiv(dlux, bx, 4);
}

static int moonui_native_dlu_y(HWND hwnd, int dluy) {
  int bx;
  int by;
  moonui_native_sizing_base(hwnd, &bx, &by);
  return MulDiv(dluy, by, 8);
}

/* 一段文字在消息字体下的尺寸（物理像素）。标签 / 按钮的 intrinsic 宽度都从
 * 这里来——GetTextExtentPoint32 必须先 SelectObject 进 DC 才问得到。 */
static void moonui_native_text_extent(LPCWSTR w, int *out_w, int *out_h) {
  NONCLIENTMETRICSW ncm;
  HDC dc;
  HFONT font;
  HFONT old;
  SIZE size = {0, 0};
  int len = w == 0 ? 0 : lstrlenW(w);
  if (w == 0 || len == 0) {
    *out_w = 0;
    *out_h = 0;
    return;
  }
  memset(&ncm, 0, sizeof(ncm));
  ncm.cbSize = (DWORD)sizeof(ncm);
  if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, (DWORD)sizeof(ncm), &ncm,
                            0) != 0) {
    font = CreateFontIndirectW(&ncm.lfMessageFont);
    if (font != 0) {
      dc = GetDC(0);
      if (dc != 0) {
        old = (HFONT)SelectObject(dc, font);
        if (GetTextExtentPoint32W(dc, w, len, &size) == 0) {
          size.cx = 0;
          size.cy = 0;
        }
        SelectObject(dc, old);
        ReleaseDC(0, dc);
      }
      DeleteObject(font);
    }
  }
  *out_w = (int)size.cx;
  *out_h = (int)size.cy;
}

/* ---- DPI ---- */

/* 静态库不带 manifest 里的 DPI 感知声明，必须在建任何窗口之前用运行时方式设。
 * 取不到函数（老系统）就放弃，让系统按默认虚拟化，不影响后续流程。 */
static void moonui_native_ensure_dpi_aware(void) {
  HMODULE user32 = GetModuleHandleW(L"user32");
  BOOL(WINAPI *set_context)(HANDLE);
  if (user32 == 0) {
    return;
  }
  set_context = (BOOL(WINAPI *)(HANDLE))GetProcAddress(
      user32, "SetProcessDpiAwarenessContext");
  if (set_context != 0) {
    /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 */
    set_context((HANDLE)-4);
  }
}

/* GetDpiForWindow 是 Win10 1607 才有的，所以按名字取：直接静态导入会让
 * 二进制在老系统上连加载都加载不了。取不到退回 DC 的系统 DPI，再退回
 * 归一化用的基准 96。返回 0 是不可能的——0 会让 MoonBit 侧的除法变成
 * 无穷大。 */
static int moonui_native_dpi_of(HWND hwnd) {
  HMODULE user32 = GetModuleHandleW(L"user32");
  UINT(WINAPI *get_for_window)(HWND);
  if (user32 != 0) {
    get_for_window =
        (UINT(WINAPI *)(HWND))GetProcAddress(user32, "GetDpiForWindow");
    if (get_for_window != 0) {
      UINT dpi = get_for_window(hwnd);
      if (dpi != 0) {
        return (int)dpi;
      }
    }
  }
  return moonui_native_system_dpi();
}

int moonui_native_system_dpi(void) {
  HDC dc = GetDC(0);
  int dpi = 96;
  if (dc != 0) {
    dpi = GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(0, dc);
  }
  if (dpi <= 0) {
    return 96;
  }
  return dpi;
}

int moonui_native_window_dpi(moonui_ptr w) { return moonui_native_dpi_of(moonui_native_hwnd(w)); }

int moonui_native_widget_dpi(moonui_ptr c) {
  HWND parent = GetParent(moonui_native_hwnd(c));
  if (parent == 0) {
    return moonui_native_system_dpi();
  }
  return moonui_native_dpi_of(parent);
}

int64_t moonui_native_screen_work_area(void) {
  /* SPI_GETWORKAREA 按定义只有主屏，所以这条只服务"进程级屏幕尺寸"
   * （Core 的 `App::screen_size()`）；按窗口的读数走下面那两条
   * `moonui_native_window_screen_*`（`T42`）。 */
  RECT r;
  if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &r, 0) == 0) {
    return moonui_native_pack2(GetSystemMetrics(SM_CXSCREEN),
                        GetSystemMetrics(SM_CYSCREEN));
  }
  return moonui_native_pack2(r.right - r.left, r.bottom - r.top);
}

/* 这只窗口当下所在那块屏的工作区，虚拟屏幕绝对坐标、物理像素（T42）。
 * SPI_GETWORKAREA 按定义只有主屏，所以副屏上的窗口拿它的数必然错。
 * MONITOR_DEFAULTTONEAREST 不是省事：窗口跨在两块屏的交界上时系统给的是重叠最多
 * 的那块，而 flags 为 0 时窗口不在任何监视器上（还没上屏、被挪到虚拟屏幕的空洞）会
 * 返回 NULL。nearest 让这条入口在"还没定位"时也有一个可报的矩形。 */
static int moonui_native_window_work_rect(moonui_ptr w, RECT *out) {
  MONITORINFO mi;
  HMONITOR mon;
  mon = MonitorFromWindow(moonui_native_hwnd(w), MONITOR_DEFAULTTONEAREST);
  if (mon == 0) {
    return 0;
  }
  mi.cbSize = sizeof(MONITORINFO);
  if (GetMonitorInfoW(mon, &mi) == 0) {
    return 0;
  }
  *out = mi.rcWork;
  return 1;
}

int64_t moonui_native_window_screen_origin(moonui_ptr w) {
  RECT r;
  RECT main_r;
  TRACE("window_screen_origin");
  if (moonui_native_window_work_rect(w, &r)) {
    return moonui_native_pack2(r.left, r.top);
  }
  /* 兜底：退回主屏的工作区原点（通常就是 0,0），理由写在 adapter.h——报主屏的数
   * 比报一个 0 尺寸更像"还没定位"，而 0 尺寸会让 LogicalRect::center 把窗口堆到
   * 左上角，症状会被读成"居中算错了"。 */
  if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &main_r, 0) != 0) {
    return moonui_native_pack2(main_r.left, main_r.top);
  }
  return moonui_native_pack2(0, 0);
}

int64_t moonui_native_window_screen_size(moonui_ptr w) {
  RECT r;
  TRACE("window_screen_size");
  if (!moonui_native_window_work_rect(w, &r)) {
    return moonui_native_screen_work_area();
  }
  return moonui_native_pack2(r.right - r.left, r.bottom - r.top);
}

int moonui_native_system_theme(void) {
  HKEY key;
  DWORD type;
  DWORD value;
  DWORD size;
  int dark;

  /* 深色模式在 Win32 上没有查询 API，能读的就是这个注册表值——它是"应用用浅色
   * 吗"，0 才是深色。键、值、类型任何一个对不上都落回 0（浅色）：Windows 7
   * 没有这个值，而这里没有错误可报（ABI 那条入口的说明）。用
   * RegOpenKeyExW/RegQueryValueExW 而不是 RegGetValueW，因为后者要
   * _WIN32_WINNT >= 0x0601，本文件不声明那个宏。advapi32.lib 在
   * windowsNativeLinkFlags 里（这条入口是第一个用到它的）。 */
  dark = 0;
  value = 1;
  size = sizeof(value);
  if (RegOpenKeyExW(HKEY_CURRENT_USER,
                    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes"
                    L"\\Personalize",
                    0, KEY_READ, &key) == ERROR_SUCCESS) {
    type = 0;
    if (RegQueryValueExW(key, L"AppsUseLightTheme", 0, &type, (LPBYTE)&value,
                         &size) == ERROR_SUCCESS &&
        type == REG_DWORD && size == sizeof(value) && value == 0) {
      dark = 1;
    }
    RegCloseKey(key);
  }
  return dark;
}

/* ---- 生命周期：窗口类 + 初始化 ---- */

static const WCHAR moonui_native_wnd_class_name[] = L"MoonuiWndClass";
static const WCHAR moonui_native_container_class_name[] = L"MoonuiContainerClass";

/* 顶层窗口的过程。libui 那份由 windowWndProc + handleParentMessages +
 * runWM_COMMAND 三层协作，这里的对应物全部内联在一只过程里（分叉清单第 3 条）：
 *   WM_CLOSE   → 报 closing 槽，返回 0 否决默认销毁——销毁顺序由 Core 决定
 *                （先内容树后窗口），默认行为是先拆窗口再返回，Core 会在拆掉的
 *                内容树上读到没的对象。
 *   WM_SIZE    → 报 resized 槽；Core 之后自己回读尺寸，所以程序性改尺寸
 *                （set_content_size / 菜单补偿）同样会冒一条 resize 事件，
 *                mac 原生那份没有抑制层，两侧语义因此一致。
 *   WM_COMMAND → lParam!=0 走控件通知；lParam==0 且 HIWORD==0 是菜单命令。
 *   WM_HSCROLL → lParam 是 trackbar 的，报 slider 的 changed。
 *   WM_NOTIFY  → DTN_DATETIMECHANGE 报 datepicker 的 changed。
 * 其余（含 park 窗口收到的任何消息）交给 DefWindowProcW。 */
static LRESULT CALLBACK moonui_native_wndproc(HWND hwnd, UINT msg, WPARAM wp,
                                       LPARAM lp) {
  if (msg == WM_CLOSE) {
    moonui_native_fire_slot_prop(hwnd, moonui_native_slot_closing_prop);
    return 0;
  }
  if (msg == WM_SIZE) {
    moonui_native_fire_slot_prop(hwnd, moonui_native_slot_resized_prop);
    return 0;
  }
  if (msg == WM_COMMAND) {
    if (lp != 0) {
      moonui_native_dispatch_command((HWND)(uintptr_t)lp, HIWORD(wp));
      return 0;
    }
    if (HIWORD(wp) == 0) {
      int id = (int)LOWORD(wp) - MOONUI_MENU_ID_BASE;
      if (id >= 0) {
        if (moonui_native_menu_fn != 0 && moonui_native_menu_closure != 0) {
          moonui_native_menu_fn(moonui_native_menu_closure, id);
        }
        return 0;
      }
    }
    /* IDOK / IDCANCEL（0/1）这类基址之下的命令不归我们：控件 ID 从 1000 起
     * （moonui_native_control_attach），菜单从 0x4000 起，其余交给默认处理。 */
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_HSCROLL) {
    HWND tb = (HWND)(uintptr_t)lp;
    if (tb != 0 && moonui_native_kind_of_hwnd(tb) == 6) {
      moonui_native_fire_slot_prop(tb, moonui_native_slot_changed_prop);
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_NOTIFY) {
    NMHDR *nm = (NMHDR *)(uintptr_t)lp;
    if (nm != 0 && nm->code == DTN_DATETIMECHANGE &&
        moonui_native_kind_of_hwnd(nm->hwndFrom) == 12) {
      if (!moonui_native_inhibited(nm->hwndFrom)) {
        moonui_native_fire_slot_prop(nm->hwndFrom, moonui_native_slot_changed_prop);
      }
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_DESTROY) {
    /* 正常路径 Core 先调 moonui_native_window_destroy（那边先 unregister 再
     * DestroyWindow），这里只是"窗口被别人拆了"的兜底，把登记位空出来。 */
    moonui_native_menu_unregister(hwnd);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

/* 单选组容器的过程：子按钮的 WM_COMMAND 转发给父窗口（顶层窗口过程里的
 * moonui_native_dispatch_command 只认打过 kind 记号的句柄，子按钮没打、容器打了），
 * WM_SIZE 时把子按钮按"一行一只"重排（append_option 之后也走这里）。 */
static LRESULT CALLBACK moonui_native_container_proc(HWND hwnd, UINT msg, WPARAM wp,
                                              LPARAM lp) {
  if (msg == WM_SIZE) {
    moonui_native_radio_relayout(hwnd);
    return 0;
  }
  if (msg == WM_COMMAND || msg == WM_HSCROLL || msg == WM_VSCROLL ||
      msg == WM_NOTIFY) {
    HWND parent = GetParent(hwnd);
    if (parent != 0) {
      SendMessageW(parent, msg, wp, lp);
    }
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

int moonui_native_init(void) {
  INITCOMMONCONTROLSEX icc;
  WNDCLASSW wc;
  HINSTANCE inst = GetModuleHandleW(0);
  TRACE("init");
  if (moonui_native_inited) {
    return 0;
  }
  moonui_native_error[0] = '\0';
  moonui_native_loop_ended = 0;
  moonui_native_ensure_dpi_aware();
  /* Common Controls v6：TRACKBAR_CLASSW / UPDOWN_CLASSW / PROGRESS_CLASSW /
   * DATETIMEPICK_CLASSW 全是公共控件，不先 InitCommonControlsEx 就建不出
   * 来（manifest 那条 pragma 管的是"v6 版本"这一半）。 */
  memset(&icc, 0, sizeof(icc));
  icc.dwSize = sizeof(icc);
  icc.dwICC = ICC_WIN95_CLASSES;
  InitCommonControlsEx(&icc);
  /* 顶层窗口类。style=0（不需要 CS_HREDRAW/CS_VSCROLL——重画由控件自己管），
   * 背景给系统按钮面色，图标先给默认的（set_app_icon 之后再逐窗口换）。 */
  memset(&wc, 0, sizeof(wc));
  wc.lpszClassName = moonui_native_wnd_class_name;
  wc.lpfnWndProc = moonui_native_wndproc;
  wc.hInstance = inst;
  wc.hIcon = LoadIconW(0, (LPCWSTR)IDI_APPLICATION);
  wc.hCursor = LoadCursorW(0, (LPCWSTR)IDC_ARROW);
  wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
  if (RegisterClassW(&wc) == 0) {
    snprintf(moonui_native_error, sizeof(moonui_native_error),
             "RegisterClassW(MoonuiWndClass) failed: %lu", GetLastError());
    return 1;
  }
  /* 单选组的容器类。背景给 NULL：透出窗口自己的底色，别在圆点行后面糊一块
   * 按钮面。 */
  memset(&wc, 0, sizeof(wc));
  wc.lpszClassName = moonui_native_container_class_name;
  wc.lpfnWndProc = moonui_native_container_proc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorW(0, (LPCWSTR)IDC_ARROW);
  if (RegisterClassW(&wc) == 0) {
    snprintf(moonui_native_error, sizeof(moonui_native_error),
             "RegisterClassW(MoonuiContainerClass) failed: %lu",
             GetLastError());
    return 1;
  }
  /* park：隐藏的顶层窗口，detach 的控件寄放在它名下；WM_COMMAND 发到它这里
   * 就等于进了黑洞（它名下的控件没有任何回调 prop），"沉默"由此保证。 */
  moonui_native_park = CreateWindowExW(0, moonui_native_wnd_class_name, L"moonui-park",
                                WS_POPUP, -32000, -32000, 0, 0, 0, 0, inst, 0);
  if (moonui_native_park == 0) {
    UnregisterClassW(moonui_native_container_class_name, inst);
    UnregisterClassW(moonui_native_wnd_class_name, inst);
    snprintf(moonui_native_error, sizeof(moonui_native_error),
             "CreateWindowW(park) failed: %lu", GetLastError());
    return 1;
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
  /* 第一件事是摘钩子：槽位一排干，钩子里那句 fire 就会调到已经没了的闭包上
   * （和 mac 那份 removeMonitor 同一条理由）。 */
  moonui_native_key_drop_hook();
  moonui_native_mouse_drop_hook();
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    moonui_native_release_slot(&moonui_native_slots[i]);
  }
  /* 菜单栏不在这张槽位表里、也不归句柄表管（它是逐窗口的原生对象 + 进程全局的
   * 一份回调和一份树的副本），所以收尾要单独走一遍：拆每只窗口挂的那棵、free
   * 掉那棵树。漏了这一步的话下一跑的快照读回来的是上一跑的树。 */
  moonui_native_menu_clear_all();
  if (moonui_native_park != 0) {
    DestroyWindow(moonui_native_park);
    moonui_native_park = 0;
  }
  if (!moonui_native_inited) {
    return;
  }
  moonui_native_inited = 0;
  moonui_native_loop_ended = 0;
  UnregisterClassW(moonui_native_container_class_name, GetModuleHandleW(0));
  UnregisterClassW(moonui_native_wnd_class_name, GetModuleHandleW(0));
}

/* ---- 窗口 ---- */

/* 客户区 → 外框：AdjustWindowRectEx 要的是当下这条窗口的风格与扩展风格，
 * 菜单位那一位按"此刻挂没挂着菜单"取（GetMenu），换树前后的补偿全靠它对。 */
static void moonui_native_outer_size(HWND hwnd,
                              int width,
                              int height,
                              int *out_w,
                              int *out_h) {
  RECT r;
  r.left = 0;
  r.top = 0;
  r.right = width;
  r.bottom = height;
  AdjustWindowRectEx(&r, GetWindowLongW(hwnd, GWL_STYLE), GetMenu(hwnd) != 0,
                     GetWindowLongW(hwnd, GWL_EXSTYLE));
  *out_w = r.right - r.left;
  *out_h = r.bottom - r.top;
}

/* 按客户区尺寸摆窗口：只动宽高，位置与 z-order 原样。 */
static void moonui_native_set_client_size(HWND hwnd, int width, int height) {
  int ow;
  int oh;
  moonui_native_outer_size(hwnd, width, height, &ow, &oh);
  SetWindowPos(hwnd, 0, 0, 0, ow, oh,
               SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOZORDER);
}

moonui_ptr moonui_native_window_new(const char *title,
                             int title_len,
                             int width,
                             int height) {
  LPWSTR t;
  HWND hwnd;
  RECT r;
  int has_bar;
  TRACE("window_new");
  t = moonui_native_utf16_of(title, title_len);
  if (t == 0) {
    return 0;
  }
  /* 客户区尺寸换外框尺寸：这一步在 CreateWindow 之前只能按"标准顶层窗口
   * 风格"估——风格是固定的 WS_OVERLAPPEDWINDOW，菜单位看当下有没有一棵非空
   * 的树等着挂（§25 的菜单是运行时才装的，Win32 的菜单位影响客户区）。 */
  r.left = 0;
  r.top = 0;
  r.right = width;
  r.bottom = height;
  has_bar = moonui_native_menu_wanted();
  AdjustWindowRectEx(&r, WS_OVERLAPPEDWINDOW, has_bar, 0);
  hwnd = CreateWindowExW(0, moonui_native_wnd_class_name, t, WS_OVERLAPPEDWINDOW,
                         CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left,
                         r.bottom - r.top, 0, 0, GetModuleHandleW(0), 0);
  free(t);
  if (hwnd == 0) {
    return 0;
  }
  /* owner 记号指向自己（句柄恒等约定），登记进菜单 / 图标那张逐窗口表。 */
  moonui_native_mark_owner(hwnd, (moonui_ptr)(uintptr_t)hwnd);
  moonui_native_menu_register(hwnd);
  moonui_native_icon_apply(hwnd); /* 之前 set_app_icon 存下的图标，新窗口也要带（§26） */
  return (moonui_ptr)(uintptr_t)hwnd;
}

void moonui_native_window_show(moonui_ptr w) {
  TRACE("window_show");
  ShowWindow(moonui_native_hwnd(w), SW_SHOW);
}

void moonui_native_window_hide(moonui_ptr w) {
  TRACE("window_hide");
  ShowWindow(moonui_native_hwnd(w), SW_HIDE);
}

void moonui_native_window_destroy(moonui_ptr w) {
  HWND hwnd = moonui_native_hwnd(w);
  TRACE("window_destroy");
  /* 控件是自己挂在窗口 HWND 下的，Win32 不会替它回收闭包，所以窗口拆之前
   * 必须把替它看守的 closing/resized 引用松开；否则回调槽里留着的是一个
   * 已经失效的 owner，之后任何一次按 owner 查找都可能命中它。
   * 菜单那一头同理：先空出登记位、拆掉我们那棵 HMENU，再销毁窗口——反过来的
   * 话销毁途中的消息就落在一个登记项已经作废的过程里。 */
  moonui_native_menu_unregister(hwnd);
  moonui_native_forget((void *)(uintptr_t)w, 0);
  RemovePropW(hwnd, moonui_native_slot_closing_prop);
  RemovePropW(hwnd, moonui_native_slot_resized_prop);
  DestroyWindow(hwnd);
}

void moonui_native_window_set_title(moonui_ptr w, const char *title, int title_len) {
  LPWSTR t = moonui_native_utf16_of(title, title_len);
  TRACE("window_set_title");
  if (t == 0) {
    return;
  }
  SetWindowTextW(moonui_native_hwnd(w), t);
  free(t);
}

void moonui_native_window_set_content_size(moonui_ptr w, int width, int height) {
  TRACE("window_set_content_size");
  /* AdjustWindowRectEx 每次都现量当下挂着的菜单行，所以菜单补偿不需要单独算。 */
  moonui_native_set_client_size(moonui_native_hwnd(w), width, height);
}

int64_t moonui_native_window_content_size(moonui_ptr w) {
  RECT r;
  TRACE("window_content_size");
  GetClientRect(moonui_native_hwnd(w), &r);
  return moonui_native_pack2(r.right - r.left, r.bottom - r.top);
}

void moonui_native_window_set_position(moonui_ptr w, int x, int y) {
  TRACE("window_set_position");
  SetWindowPos(moonui_native_hwnd(w), 0, x, y, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER);
}

int64_t moonui_native_window_position(moonui_ptr w) {
  RECT r;
  TRACE("window_position");
  if (GetWindowRect(moonui_native_hwnd(w), &r) == 0) {
    return moonui_native_pack2(0, 0);
  }
  return moonui_native_pack2(r.left, r.top);
}

void moonui_native_window_set_resizable(moonui_ptr w, int resizable) {
  HWND hwnd = moonui_native_hwnd(w);
  LONG style;
  TRACE("window_set_resizable");
  style = GetWindowLongW(hwnd, GWL_STYLE);
  if (resizable) {
    style |= WS_THICKFRAME;
  } else {
    style &= ~WS_THICKFRAME;
  }
  SetWindowLongW(hwnd, GWL_STYLE, style);
  /* 框架变了要让系统重算非客户区，不然新风格要到下一次 resize 才看得出来。 */
  SetWindowPos(hwnd, 0, 0, 0, 0, 0,
               SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_FRAMECHANGED);
}

void moonui_native_window_set_fullscreen(moonui_ptr w, int fullscreen) {
  HWND hwnd = moonui_native_hwnd(w);
  LONG style;
  MONITORINFO mi;
  MoonuiWindowMenu *e;
  TRACE("window_set_fullscreen");
  e = moonui_native_menu_entry_of(hwnd);
  if (e == 0) {
    return;
  }
  if (fullscreen) {
    if (e->fullscreen) {
      return;
    }
    e->fullscreen = 1;
    /* 先把当前位置和尺寸整份存下（含 show 状态），再摘掉标题栏 / 边框那一组
     * 风格，把窗口铺满它当下所在那块屏的工作矩形。退出时用 SetWindowPlacement
     * 原样还原——比只存 RECT 多还原了最大化 / 还原态这一档。 */
    memset(&e->fs_prev, 0, sizeof(e->fs_prev));
    e->fs_prev.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(hwnd, &e->fs_prev);
    style = GetWindowLongW(hwnd, GWL_STYLE);
    e->fs_style = style;
    SetWindowLongW(hwnd, GWL_STYLE,
                   (style | WS_POPUP) & ~WS_OVERLAPPEDWINDOW);
    mi.cbSize = sizeof(MONITORINFO);
    if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                        &mi) != 0) {
      SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                   mi.rcMonitor.right - mi.rcMonitor.left,
                   mi.rcMonitor.bottom - mi.rcMonitor.top,
                   SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }
  } else {
    if (!e->fullscreen) {
      return;
    }
    e->fullscreen = 0;
    SetWindowLongW(hwnd, GWL_STYLE, e->fs_style);
    SetWindowPlacement(hwnd, &e->fs_prev);
    SetWindowPos(hwnd, 0, 0, 0, 0, 0,
                 SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_FRAMECHANGED);
  }
}

void moonui_native_window_set_titlebar_style(moonui_ptr w, int immersive) {
  TRACE("window_set_titlebar_style");
  /* Windows 没有红绿灯，"沉浸式"（内容铺满、红绿灯浮在内容上）在这侧没有对应物。
   * 留这条空操作是为了跨平台 API 一致——调用方不用按平台分叉。immersive 参数
   * 故意不用，避免 unused 警告。 */
  (void)w;
  (void)immersive;
}

int moonui_native_window_titlebar_style(moonui_ptr w) {
  TRACE("window_titlebar_style");
  /* Windows 没有红绿灯，读回恒 0（和 setter 的空操作对称）。 */
  (void)w;
  return 0;
}

void moonui_native_window_set_traffic_light_position(moonui_ptr w, int x, int y) {
  TRACE("window_set_traffic_light_position");
  /* Windows 没有红绿灯可挪，空操作保跨平台 API 一致。 */
  (void)w;
  (void)x;
  (void)y;
}

int64_t moonui_native_window_traffic_light_position(moonui_ptr w) {
  TRACE("window_traffic_light_position");
  /* 没设过就是 (0,0)——和 mac 侧"关闭按钮没找到"的兜底对称。 */
  (void)w;
  return moonui_native_pack2(0, 0);
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
  moonui_native_set_slot_prop(moonui_native_hwnd(w), moonui_native_slot_closing_prop, slot);
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
  moonui_native_set_slot_prop(moonui_native_hwnd(w), moonui_native_slot_resized_prop, slot);
  return 0;
}

/* ---- 控件 ---- */

/* 控件出生的公共路径：全部寄放在 park 名下（moonui_native_control_attach 时再搬进真
 * 窗口），统一 WS_CHILD|WS_VISIBLE。返回的 HWND 由调用方打记号。 */
static HWND moonui_native_create_control(DWORD exstyle,
                                  LPCWSTR cls,
                                  LPCWSTR text,
                                  DWORD style) {
  TRACE("widget_create");
  if (moonui_native_park == 0) {
    return 0;
  }
  return CreateWindowExW(exstyle, cls, text, WS_CHILD | WS_VISIBLE | style, 0,
                         0, 0, 0, moonui_native_park, 0, GetModuleHandleW(0), 0);
}

/* T74 的滚动视口没有对应的标准控件：这里先落一只剪裁容器——WS_CLIPCHILDREN
 * 让摆进去的子控件被容器矩形裁掉，子控件挂进去（SetParent）后坐标自动变成
 * 容器客户区坐标。真滚动（滚动条 + 滚动行程）照 adapter.c 的挂账仍在路上。 */
static LRESULT CALLBACK moonui_native_scroll_proc(HWND hwnd, UINT msg, WPARAM wp,
                                           LPARAM lp) {
  if (msg == WM_COMMAND || msg == WM_HSCROLL || msg == WM_VSCROLL ||
      msg == WM_NOTIFY) {
    HWND parent = GetParent(hwnd);
    if (parent != 0) {
      SendMessageW(parent, msg, wp, lp);
    }
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

moonui_ptr moonui_native_widget_new(int kind, const char *text, int text_len) {
  LPWSTR t;
  HWND hwnd = 0;
  TRACE("widget_new");
  t = moonui_native_utf16_of(text, text_len);
  if (t == 0) {
    return 0;
  }
  switch (kind) {
    case 0:
      /* SS_LEFTNOWORDWRAP|SS_NOPREFIX 照 libui 的 label.cpp：单行、不把 & 当
       * 助记符（文案里的 & 原样显示）。 */
      hwnd = moonui_native_create_control(0, L"static", t,
                                   SS_LEFTNOWORDWRAP | SS_NOPREFIX);
      break;
    case 1:
      hwnd = moonui_native_create_control(0, L"button", t, BS_PUSHBUTTON | WS_TABSTOP);
      break;
    case 2:
      hwnd = moonui_native_create_control(WS_EX_CLIENTEDGE, L"edit", t,
                                   ES_AUTOHSCROLL | ES_LEFT | ES_NOHIDESEL |
                                       WS_TABSTOP);
      break;
    case 3:
      /* BS_CHECKBOX 而不是 BS_AUTOCHECKBOX：勾选态由我们自己在 BN_CLICKED 里
       * 翻（见 moonui_native_dispatch_command），和 libui 同形——回调只报"出事了"，
       * 新状态由 MoonBit 回读。 */
      hwnd = moonui_native_create_control(0, L"button", t, BS_CHECKBOX | WS_TABSTOP);
      break;
    case 4:
      hwnd = moonui_native_create_control(WS_EX_CLIENTEDGE, L"edit", t,
                                   ES_AUTOHSCROLL | ES_LEFT | ES_NOHIDESEL |
                                       ES_PASSWORD | WS_TABSTOP);
      break;
    case 5:
      hwnd = moonui_native_create_control(0, L"static", L"", SS_ETCHEDHORZ);
      break;
    case 13:
      hwnd = moonui_native_create_control(0, L"static", L"", SS_ETCHEDVERT);
      break;
    case 14:
      /* 扁平可点文本行（§51 画册左栏）：先落一只标准按钮——Win32 的按钮没有
       * "去边框左对齐"的现成入口，菜单感在原生 Cocoa 后端上才做足。样式是
       * BS_CHECKBOX | BS_PUSHLIKE：看起来仍是一只按钮，但选中态走 BM_SETCHECK
       * / BM_GETCHECK 往返（画册左栏的选中高亮靠它，纯 BS_PUSHBUTTON 上那对
       * 入口是空操作）。BS_CHECKBOX 不带 AUTO，点了不自己翻——dispatch_command
       * 只对 kind 3 代翻，这里的 checked 全由 Core 在换页时推。 */
      hwnd = moonui_native_create_control(0, L"button", t,
                                   BS_CHECKBOX | BS_PUSHLIKE | WS_TABSTOP);
      break;
    case 15: {
      /* 剪裁容器：STATIC 换上转发用的窗口过程（adapter.c 同款），只换
       * GWLP_WNDPROC、不动类注册。 */
      HWND clip;
      clip = CreateWindowExW(0, L"STATIC", L"",
                             WS_CHILD | WS_CLIPCHILDREN | WS_VISIBLE, 0, 0, 0,
                             0, moonui_native_park, 0, GetModuleHandleW(0), 0);
      if (clip != 0) {
        SetWindowLongPtrW(clip, GWLP_WNDPROC, (LONG_PTR)moonui_native_scroll_proc);
      }
      hwnd = clip;
      break;
    }
    default:
      break;
  }
  free(t);
  if (hwnd == 0 || !moonui_native_finish_new(hwnd, kind)) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)hwnd;
}

/* ---- 扩展控件（§13 的 0.2 批）：七个专属构造入口 ----
 * Slider / Spinbox 的范围只能在构造时给，所以这两个走 moonui_native_widget_new 之外；
 * 其余五个本可以走 kind 通道，但"带专属 C 入口的控件就有专属构造函数"这条规矩
 * 两个后端都守着，七个都单独建。创建成功一律过 moonui_native_finish_new。 */

/* 单选组的子按钮名单（malloc 在堆上、DestroyWindow 不会替我们清，配套的
 * moonui_native_unmark_all / moonui_native_widget_destroy 负责 free）。 */
typedef struct {
  HWND *kids;
  int len;
  int cap;
} MoonuiRadioKids;

moonui_ptr moonui_native_slider_new(int min, int max) {
  HWND hwnd;
  int lo = min;
  int hi = max;
  TRACE("slider_new");
  if (lo > hi) {
    lo = max;
    hi = min;
  }
  hwnd = moonui_native_create_control(0, TRACKBAR_CLASSW, L"",
                               TBS_HORZ | TBS_TOOLTIPS | TBS_TRANSPARENTBKGND |
                                   WS_TABSTOP);
  if (hwnd == 0) {
    return 0;
  }
  SendMessageW(hwnd, TBM_SETRANGEMIN, FALSE, (LPARAM)lo);
  SendMessageW(hwnd, TBM_SETRANGEMAX, TRUE, (LPARAM)hi);
  SendMessageW(hwnd, TBM_SETPOS, FALSE, (LPARAM)lo);
  if (!moonui_native_finish_new(hwnd, 6)) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)hwnd;
}

moonui_ptr moonui_native_spinbox_new(int min, int max) {
  HWND edit;
  HWND updown;
  int lo = min;
  int hi = max;
  TRACE("spinbox_new");
  if (lo > hi) {
    lo = max;
    hi = min;
  }
  /* 句柄取 edit：updown 是它的兄弟（不是父子），记在 edit 的属性表上，
   * 重挂 / 销毁 / 摆放都跟着 edit 走。UDS_SETBUDDYINT 让 updown 自己写
   * edit 的文字，EN_CHANGE 因此是它俩共同的回声通道——inhibit 那一位
   * prop 由 set_value / 构造期置清。updown 不给 WS_TABSTOP：Tab 键不该
   * 停在箭头上（libui 同款）。 */
  edit = moonui_native_create_control(WS_EX_CLIENTEDGE, L"edit", L"",
                               ES_AUTOHSCROLL | ES_LEFT | ES_NOHIDESEL |
                                   WS_TABSTOP);
  if (edit == 0) {
    return 0;
  }
  updown = CreateWindowExW(0, UPDOWN_CLASSW, L"",
                           WS_CHILD | WS_VISIBLE | UDS_ALIGNRIGHT |
                               UDS_ARROWKEYS | UDS_HOTTRACK |
                               UDS_NOTHOUSANDS | UDS_SETBUDDYINT,
                           0, 0, 0, 0, moonui_native_park, 0, GetModuleHandleW(0), 0);
  if (updown == 0) {
    DestroyWindow(edit);
    return 0;
  }
  SetPropW(edit, moonui_native_updown_prop, (HANDLE)(uintptr_t)updown);
  SendMessageW(updown, UDM_SETBUDDY, (WPARAM)edit, 0);
  SendMessageW(updown, UDM_SETRANGE32, (WPARAM)lo, (LPARAM)hi);
  moonui_native_inhibit(edit);
  SendMessageW(updown, UDM_SETPOS32, 0, (LPARAM)lo);
  moonui_native_uninhibit(edit);
  if (!moonui_native_finish_new(edit, 7)) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)edit;
}

moonui_ptr moonui_native_progress_new(void) {
  HWND hwnd;
  TRACE("progress_new");
  hwnd = moonui_native_create_control(0, PROGRESS_CLASSW, L"", PBS_SMOOTH);
  if (!moonui_native_finish_new(hwnd, 8)) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)hwnd;
}

moonui_ptr moonui_native_combobox_new(void) {
  HWND hwnd;
  TRACE("combobox_new");
  /* CBS_DROPDOWNLIST：只许从列表里选，不许打字（adapter.h 的语义）。
   * Common Controls v6 之下不用管下拉框的高度——系统按字体自己算。 */
  hwnd = moonui_native_create_control(WS_EX_CLIENTEDGE, L"combobox", L"",
                               CBS_DROPDOWNLIST | WS_TABSTOP);
  if (!moonui_native_finish_new(hwnd, 9)) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)hwnd;
}

moonui_ptr moonui_native_multiline_new(void) {
  HWND hwnd;
  TRACE("multiline_new");
  hwnd = moonui_native_create_control(WS_EX_CLIENTEDGE, L"edit", L"",
                               ES_AUTOVSCROLL | ES_LEFT | ES_MULTILINE |
                                   ES_NOHIDESEL | ES_WANTRETURN |
                                   WS_TABSTOP | WS_VSCROLL);
  if (!moonui_native_finish_new(hwnd, 10)) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)hwnd;
}

moonui_ptr moonui_native_radio_new(void) {
  HWND hwnd;
  MoonuiRadioKids *kids;
  TRACE("radio_new");
  /* 自建容器类：背景透明，子按钮一只一行。kind 记在容器上；子按钮是
   * BS_AUTORADIOBUTTON，第一只带 WS_GROUP|WS_TABSTOP，互斥由控件自己管。 */
  hwnd = CreateWindowExW(0, moonui_native_container_class_name, L"",
                         WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, moonui_native_park, 0,
                         GetModuleHandleW(0), 0);
  if (hwnd == 0) {
    return 0;
  }
  kids = (MoonuiRadioKids *)malloc(sizeof(MoonuiRadioKids));
  if (kids == 0) {
    DestroyWindow(hwnd);
    return 0;
  }
  kids->kids = 0;
  kids->len = 0;
  kids->cap = 0;
  SetPropW(hwnd, moonui_native_radiokids_prop, (HANDLE)(uintptr_t)kids);
  if (!moonui_native_finish_new(hwnd, 11)) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)hwnd;
}

moonui_ptr moonui_native_datepicker_new(void) {
  HWND hwnd;
  TRACE("datepicker_new");
  hwnd = moonui_native_create_control(WS_EX_CLIENTEDGE, DATETIMEPICK_CLASSW, L"",
                               DTS_SHORTDATEFORMAT | WS_TABSTOP);
  if (!moonui_native_finish_new(hwnd, 12)) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)hwnd;
}

void moonui_native_widget_destroy(moonui_ptr c) {
  HWND hwnd = moonui_native_hwnd(c);
  TRACE("widget_destroy");
  moonui_native_forget((void *)(uintptr_t)c, 0);
  moonui_native_unmark_all(hwnd); /* 顺带销毁 spinbox 的 updown、free 单选组的名单 */
  DestroyWindow(hwnd);
}

/* ---- 单选组的子按钮与重排 ---- */

static MoonuiRadioKids *moonui_native_radiokids_of(HWND container) {
  HANDLE v = GetPropW(container, moonui_native_radiokids_prop);
  if (v == 0) {
    return 0;
  }
  return (MoonuiRadioKids *)(uintptr_t)v;
}

/* 一行一只按容器宽度重排。子按钮的创建顺序就是枚举顺序（不做 z-order 操作），
 * 所以 kids 数组的下标就是 Core 看到的 option 下标。 */
static void moonui_native_radio_relayout(HWND container) {
  MoonuiRadioKids *kids = moonui_native_radiokids_of(container);
  RECT rc;
  int row;
  int i;
  if (kids == 0 || kids->len == 0) {
    return;
  }
  GetClientRect(container, &rc);
  row = moonui_native_dlu_y(container, 10);
  if (row <= 0) {
    row = 16;
  }
  for (i = 0; i < kids->len; ++i) {
    MoveWindow(kids->kids[i], rc.left, rc.top + i * row,
               rc.right - rc.left, row, TRUE);
  }
}

/* ---- 控件通知的统一分派（顶层窗口过程调进来）---- */

static void moonui_native_dispatch_command(HWND ctrl, int code) {
  int kind = moonui_native_kind_of_hwnd(ctrl);
  if (kind == 3 && code == BN_CLICKED) {
    /* 勾选框：BS_CHECKBOX 不自己翻状态，这里代翻（libui 的 checkbox.cpp 同形），
     * 新值由 MoonBit 回读 moonui_native_widget_checked。 */
    SendMessageW(ctrl, BM_SETCHECK,
                 SendMessageW(ctrl, BM_GETCHECK, 0, 0) == BST_CHECKED
                     ? BST_UNCHECKED
                     : BST_CHECKED,
                 0);
    moonui_native_fire_slot_prop(ctrl, moonui_native_slot_toggled_prop);
    return;
  }
  if (kind == 1 || kind == 14) {
    if (code == BN_CLICKED) {
      moonui_native_fire_slot_prop(ctrl, moonui_native_slot_click_prop);
    }
    return;
  }
  if (kind == 2 || kind == 4) {
    if (code == EN_CHANGE && !moonui_native_inhibited(ctrl)) {
      moonui_native_fire_slot_prop(ctrl, moonui_native_slot_text_prop);
    }
    return;
  }
  if (kind == 7) {
    if (code == EN_CHANGE && !moonui_native_inhibited(ctrl)) {
      /* updown 写回 / 用户打字都从 EN_CHANGE 过来。裸 "-" 是负数的中间态，
       * updown 自己不收，这里同样放它过去不算一次变化（libui 同款）。 */
      WCHAR buf[32];
      buf[0] = L'\0';
      GetWindowTextW(ctrl, buf, 32);
      if (lstrcmpW(buf, L"-") != 0) {
        moonui_native_spinbox_value(ctrl); /* 越界时封顶并写回（libui 的 value()） */
        moonui_native_fire_slot_prop(ctrl, moonui_native_slot_changed_prop);
      }
    }
    return;
  }
  if (kind == 9) {
    if (code == CBN_SELCHANGE) {
      moonui_native_fire_slot_prop(ctrl, moonui_native_slot_changed_prop);
    }
    return;
  }
  if (kind == 10) {
    if (code == EN_CHANGE && !moonui_native_inhibited(ctrl)) {
      moonui_native_fire_slot_prop(ctrl, moonui_native_slot_changed_prop);
    }
    return;
  }
  if (kind == 11) {
    /* 单选组的子按钮：通知发自子按钮，kind 记在容器上。第一只带 WS_GROUP，
     * BS_AUTORADIOBUTTON 的互斥由控件自己完成，这里只报"选中变了"。 */
    if (code == BN_CLICKED) {
      HWND container = GetParent(ctrl);
      if (container != 0) {
        moonui_native_fire_slot_prop(container, moonui_native_slot_changed_prop);
      }
    }
    return;
  }
  /* 剩下的是 Label / Separator / Scroll / DatePicker / Slider：它们的
   * 通知不走 WM_COMMAND（或不该有），静默忽略比猜测安全。 */
}

/* ---- 控件的通用属性 ---- */

void moonui_native_widget_set_text(moonui_ptr c, const char *text, int text_len) {
  HWND hwnd = moonui_native_hwnd(c);
  LPWSTR w;
  int kind = moonui_native_kind_of(c);
  TRACE("widget_set_text");
  w = moonui_native_utf16_of(text, text_len);
  if (w == 0) {
    return;
  }
  if (kind == 10 || kind == 2 || kind == 4) {
    /* 多行文本框的换行契约是 LF（adapter.h），EDIT 要 CRLF；三类 EDIT 的
     * SetWindowTextW 都会发 EN_CHANGE，先立 inhibit 再清。 */
    LPWSTR cooked = kind == 10 ? moonui_native_lf_to_crlf(w) : w;
    moonui_native_inhibit(hwnd);
    SetWindowTextW(hwnd, cooked);
    moonui_native_uninhibit(hwnd);
    if (cooked != w) {
      free(cooked);
    }
    free(w);
    return;
  }
  if (kind == 12) {
    moonui_native_datepicker_set_text(c, text, text_len);
    free(w);
    return;
  }
  SetWindowTextW(hwnd, w);
  free(w);
}

moonbit_bytes_t moonui_native_widget_text(moonui_ptr c) {
  HWND hwnd = moonui_native_hwnd(c);
  int n;
  WCHAR *wbuf;
  WCHAR *cooked;
  char *ubuf;
  moonbit_bytes_t out;
  int kind = moonui_native_kind_of(c);
  TRACE("widget_text");
  if (kind == 12) {
    return moonui_native_datepicker_text(c);
  }
  n = GetWindowTextLengthW(hwnd);
  if (n < 0) {
    n = 0;
  }
  wbuf = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
  if (wbuf == 0) {
    return moonbit_make_bytes(0, 0);
  }
  wbuf[0] = L'\0';
  /* GetWindowTextW 会把拷出的长度返回，截断到给定容量，多给的 1 格兜 NUL。 */
  GetWindowTextW(hwnd, wbuf, n + 1);
  if (kind == 10) {
    cooked = moonui_native_crlf_to_lf(wbuf);
    free(wbuf);
    if (cooked == 0) {
      return moonbit_make_bytes(0, 0);
    }
    ubuf = moonui_native_utf8_of(cooked);
    free(cooked);
  } else {
    ubuf = moonui_native_utf8_of(wbuf);
    free(wbuf);
  }
  if (ubuf == 0) {
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_native_bytes_of(ubuf);
  free(ubuf);
  return out;
}

void moonui_native_widget_set_checked(moonui_ptr c, int checked) {
  TRACE("widget_set_checked");
  SendMessageW(moonui_native_hwnd(c), BM_SETCHECK,
               (WPARAM)(checked ? BST_CHECKED : BST_UNCHECKED), 0);
}

/* ---- 内边距（§51 的 MenuRow padding）----
 *
 * 测量账归 Core（固有 = 文字 + insets，矩形自然长大），Win32 标准按钮充满
 * 矩形即背景长大；文字缩进的绘制语义按 T77 的标准按钮形状先不消费——
 * 同 libui 半的豁免，写在实现里不是隐藏行为。 */

void moonui_native_widget_set_insets(moonui_ptr c, int top, int end, int bottom, int start) {
  TRACE("widget_set_insets");
  (void)c;
  (void)top;
  (void)end;
  (void)bottom;
  (void)start;
}

int moonui_native_widget_checked(moonui_ptr c) {
  TRACE("widget_checked");
  return SendMessageW(moonui_native_hwnd(c), BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0;
}

void moonui_native_widget_set_visible(moonui_ptr c, int visible) {
  HWND hwnd = moonui_native_hwnd(c);
  HWND updown = moonui_native_updown_of(hwnd);
  TRACE("widget_set_visible");
  ShowWindow(hwnd, visible ? SW_SHOW : SW_HIDE);
  if (updown != 0) {
    /* spinbox 的 updown 是兄弟，不跟着 edit 一起藏就会一个人剩在窗口上。 */
    ShowWindow(updown, visible ? SW_SHOW : SW_HIDE);
  }
}

int moonui_native_widget_visible(moonui_ptr c) {
  TRACE("widget_visible");
  return IsWindowVisible(moonui_native_hwnd(c)) ? 1 : 0;
}

void moonui_native_widget_set_enabled(moonui_ptr c, int enabled) {
  HWND hwnd = moonui_native_hwnd(c);
  HWND updown = moonui_native_updown_of(hwnd);
  TRACE("widget_set_enabled");
  EnableWindow(hwnd, enabled ? TRUE : FALSE);
  if (updown != 0) {
    EnableWindow(updown, enabled ? TRUE : FALSE);
  }
}

int moonui_native_widget_enabled(moonui_ptr c) {
  TRACE("widget_enabled");
  return IsWindowEnabled(moonui_native_hwnd(c)) ? 1 : 0;
}

/* 回调登记：槽位照 adapter.c 那套 take_slot，区别只在"把槽位号记到哪个
 * HWND 的哪个 prop 上"。 */
int moonui_native_widget_on_clicked(moonui_ptr c,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("widget_on_clicked");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_click_prop, slot);
  return 0;
}

int moonui_native_widget_on_text_changed(moonui_ptr c,
                                  moonui_closure_fn fn,
                                  void *closure) {
  int slot;
  TRACE("widget_on_text_changed");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_text_prop, slot);
  return 0;
}

int moonui_native_widget_on_toggled(moonui_ptr c,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("widget_on_toggled");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_toggled_prop, slot);
  return 0;
}

int moonui_native_slider_on_changed(moonui_ptr c, moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("slider_on_changed");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_changed_prop, slot);
  return 0;
}

int moonui_native_spinbox_on_changed(moonui_ptr c, moonui_closure_fn fn,
                              void *closure) {
  int slot;
  TRACE("spinbox_on_changed");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_changed_prop, slot);
  return 0;
}

int moonui_native_combobox_on_selected(moonui_ptr c, moonui_closure_fn fn,
                                void *closure) {
  int slot;
  TRACE("combobox_on_selected");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_changed_prop, slot);
  return 0;
}

int moonui_native_radio_on_selected(moonui_ptr c, moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("radio_on_selected");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_changed_prop, slot);
  return 0;
}

int moonui_native_multiline_on_changed(moonui_ptr c, moonui_closure_fn fn,
                                void *closure) {
  int slot;
  TRACE("multiline_on_changed");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_changed_prop, slot);
  return 0;
}

int moonui_native_datepicker_on_changed(moonui_ptr c, moonui_closure_fn fn,
                                 void *closure) {
  int slot;
  TRACE("datepicker_on_changed");
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(c), moonui_native_slot_changed_prop, slot);
  return 0;
}

/* ---- 通用值入口：按 kind 分派（记号的用途见 moonui_native_mark_kind 那段）----
 * 合法性（哪种控件有哪种属性）由 Core 在 widget.mbt 拦在前头，这里 kind 对不上
 * 就是 ABI 被绕过了，静默忽略比猜测安全。 */

static int moonui_native_progress_is_marquee(HWND hwnd) {
  return (GetWindowLongW(hwnd, GWL_STYLE) & PBS_MARQUEE) != 0;
}

void moonui_native_widget_set_value(moonui_ptr c, int v) {
  HWND hwnd = moonui_native_hwnd(c);
  int kind = moonui_native_kind_of(c);
  TRACE("widget_set_value");
  switch (kind) {
    case 6:
      /* TBM_SETPOS 不发通知（发通知的是 TBM_SETPOSNOTIFY），程序赋值天然
       * 不回声。 */
      SendMessageW(hwnd, TBM_SETPOS, TRUE, (LPARAM)v);
      break;
    case 7: {
      /* UDM_SETPOS32 写回 edit 文字会发 EN_CHANGE——先立 inhibit。 */
      HWND updown = moonui_native_updown_of(hwnd);
      if (updown != 0) {
        moonui_native_inhibit(hwnd);
        SendMessageW(updown, UDM_SETPOS32, 0, (LPARAM)v);
        moonui_native_uninhibit(hwnd);
      }
      break;
    }
    case 8: {
      /* -1 = 不定进度（走 marquee）。0..100 的定值：Vista 起进度条对"增大"
       * 有强制动画，先设 value+1 再落回 value 才是瞬时跳变；100 特殊处理
       * （100+1 越界，range 借 101 一跳）。整段照 libui 的 progressbar.cpp。 */
      if (v == -1) {
        if (!moonui_native_progress_is_marquee(hwnd)) {
          SetWindowLongW(hwnd, GWL_STYLE,
                         GetWindowLongW(hwnd, GWL_STYLE) | PBS_MARQUEE);
          SendMessageW(hwnd, PBM_SETMARQUEE, (WPARAM)TRUE, 0);
        }
        break;
      }
      if (v < 0) {
        v = 0;
      }
      if (v > 100) {
        v = 100;
      }
      if (moonui_native_progress_is_marquee(hwnd)) {
        SendMessageW(hwnd, PBM_SETMARQUEE, (WPARAM)FALSE, 0);
        SetWindowLongW(hwnd, GWL_STYLE,
                       GetWindowLongW(hwnd, GWL_STYLE) & ~PBS_MARQUEE);
      }
      if (v == 100) {
        SendMessageW(hwnd, PBM_SETRANGE32, 0, 101);
        SendMessageW(hwnd, PBM_SETPOS, 101, 0);
        SendMessageW(hwnd, PBM_SETPOS, 100, 0);
        SendMessageW(hwnd, PBM_SETRANGE32, 0, 100);
      } else {
        SendMessageW(hwnd, PBM_SETPOS, (WPARAM)(v + 1), 0);
        SendMessageW(hwnd, PBM_SETPOS, (WPARAM)v, 0);
      }
      break;
    }
    default:
      break;
  }
}

int moonui_native_widget_value(moonui_ptr c) {
  HWND hwnd = moonui_native_hwnd(c);
  int kind = moonui_native_kind_of(c);
  TRACE("widget_value");
  switch (kind) {
    case 6:
      return (int)SendMessageW(hwnd, TBM_GETPOS, 0, 0);
    case 7:
      return moonui_native_spinbox_value(hwnd);
    case 8:
      if (moonui_native_progress_is_marquee(hwnd)) {
        return -1;
      }
      return (int)SendMessageW(hwnd, PBM_GETPOS, 0, 0);
    default:
      return 0;
  }
}

void moonui_native_slider_set_range(moonui_ptr c, int min, int max) {
  HWND hwnd = moonui_native_hwnd(c);
  LONG pos;
  TRACE("slider_set_range");
  if (moonui_native_kind_of(c) != 6) {
    return;
  }
  if (min > max) {
    int t = min;
    min = max;
    max = t;
  }
  /* 先改范围再把当前值夹回去：TBM_SETRANGE 不带 notify，改范围本身不回声。 */
  SendMessageW(hwnd, TBM_SETRANGEMIN, FALSE, (LPARAM)min);
  SendMessageW(hwnd, TBM_SETRANGEMAX, FALSE, (LPARAM)max);
  pos = (LONG)SendMessageW(hwnd, TBM_GETPOS, 0, 0);
  if (pos < min) {
    pos = min;
  }
  if (pos > max) {
    pos = max;
  }
  SendMessageW(hwnd, TBM_SETPOS, FALSE, (LPARAM)pos);
}

/* spinbox 的读数带封顶写回（libui 的 value()）：UDM_GETPOS32 顺手把越界值
 * 拉回范围内，拉回的那一下会写 edit、发 EN_CHANGE，所以也要 inhibit。 */
static int moonui_native_spinbox_value(HWND edit) {
  HWND updown = moonui_native_updown_of(edit);
  BOOL capped = FALSE;
  LRESULT v;
  if (updown == 0) {
    return 0;
  }
  v = SendMessageW(updown, UDM_GETPOS32, 0, (LPARAM)&capped);
  if (capped) {
    moonui_native_inhibit(edit);
    SendMessageW(updown, UDM_SETPOS32, 0, v);
    moonui_native_uninhibit(edit);
  }
  return (int)v;
}

void moonui_native_widget_append_option(moonui_ptr c, const char *text, int text_len) {
  HWND hwnd = moonui_native_hwnd(c);
  LPWSTR w;
  int kind = moonui_native_kind_of(c);
  TRACE("widget_append_option");
  w = moonui_native_utf16_of(text, text_len);
  if (w == 0) {
    return;
  }
  if (kind == 9) {
    SendMessageW(hwnd, CB_ADDSTRING, 0, (LPARAM)w);
  } else if (kind == 11) {
    MoonuiRadioKids *kids = moonui_native_radiokids_of(hwnd);
    if (kids != 0) {
      HWND child = CreateWindowExW(
          0, L"button", w,
          WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON |
              (kids->len == 0 ? WS_GROUP | WS_TABSTOP : 0),
          0, 0, 0, 0, hwnd, 0, GetModuleHandleW(0), 0);
      if (child != 0) {
        if (kids->len == kids->cap) {
          int cap = kids->cap == 0 ? 8 : kids->cap * 2;
          HWND *next =
              (HWND *)realloc(kids->kids, sizeof(HWND) * (size_t)cap);
          if (next == 0) {
            DestroyWindow(child);
            free(w);
            return;
          }
          kids->kids = next;
          kids->cap = cap;
        }
        kids->kids[kids->len++] = child;
        moonui_native_radio_relayout(hwnd);
      }
    }
  }
  free(w);
}

void moonui_native_widget_set_selected(moonui_ptr c, int index) {
  HWND hwnd = moonui_native_hwnd(c);
  int kind = moonui_native_kind_of(c);
  TRACE("widget_set_selected");
  if (kind == 9) {
    SendMessageW(hwnd, CB_SETCURSEL, (WPARAM)index, 0);
  } else if (kind == 11) {
    MoonuiRadioKids *kids = moonui_native_radiokids_of(hwnd);
    int i;
    if (kids == 0 || index < 0 || index >= kids->len) {
      return;
    }
    /* 整组重写而不是只翻两只：BS_AUTORADIOBUTTON 的互斥是"点"出来的，程序
     * 选中要自己保证组内只有一个勾。 */
    for (i = 0; i < kids->len; ++i) {
      SendMessageW(kids->kids[i], BM_SETCHECK,
                   (WPARAM)(i == index ? BST_CHECKED : BST_UNCHECKED), 0);
    }
  }
}

int moonui_native_widget_selected(moonui_ptr c) {
  HWND hwnd = moonui_native_hwnd(c);
  int kind = moonui_native_kind_of(c);
  TRACE("widget_selected");
  if (kind == 9) {
    LRESULT r = SendMessageW(hwnd, CB_GETCURSEL, 0, 0);
    return r == CB_ERR ? -1 : (int)r;
  }
  if (kind == 11) {
    MoonuiRadioKids *kids = moonui_native_radiokids_of(hwnd);
    int i;
    if (kids == 0) {
      return -1;
    }
    for (i = 0; i < kids->len; ++i) {
      if (SendMessageW(kids->kids[i], BM_GETCHECK, 0, 0) == BST_CHECKED) {
        return i;
      }
    }
  }
  return -1;
}

/* ---- DatePicker 的文字通道 ----
 * 约定格式 "YYYY-MM-DD HH:MM:SS"（与 mac 同一份契约，adapter.h 注释是权威）。
 * DATETIMEPICK 的窗口文本是按用户区域设置排的显示文本，不是这份约定，所以
 * 读和写都绕开窗口文本、直接翻 SYSTEMTIME。返回 0 = 已收下，-1 = 格式不对，
 * -2 = 记号对不上。 */
int moonui_native_datepicker_set_text(moonui_ptr c, const char *text, int text_len) {
  char *t;
  int filled;
  int y;
  int mo;
  int d;
  int h;
  int mi;
  int s;
  SYSTEMTIME st;
  TRACE("datepicker_set_text");
  t = moonui_native_dup(text, text_len);
  if (t == 0) {
    return -1;
  }
  filled = sscanf(t, "%4d-%2d-%2d %2d:%2d:%2d", &y, &mo, &d, &h, &mi, &s);
  free(t);
  if (filled != 6) {
    return -1;
  }
  if (moonui_native_kind_of(c) != 12) {
    return -2;
  }
  memset(&st, 0, sizeof(st));
  st.wYear = (WORD)y;
  st.wMonth = (WORD)mo;
  st.wDay = (WORD)d;
  st.wHour = (WORD)h;
  st.wMinute = (WORD)mi;
  st.wSecond = (WORD)s;
  /* DTM_SETSYSTEMTIME 不发 DTN_DATETIMECHANGE（那是用户交互的通知），这里
   * 立 inhibit 只是保险：万一哪个系统版本发，也别回声成用户操作。 */
  moonui_native_inhibit(moonui_native_hwnd(c));
  SendMessageW(moonui_native_hwnd(c), DTM_SETSYSTEMTIME, GDT_VALID, (LPARAM)&st);
  moonui_native_uninhibit(moonui_native_hwnd(c));
  return 0;
}

moonbit_bytes_t moonui_native_datepicker_text(moonui_ptr c) {
  SYSTEMTIME st;
  char buf[32];
  TRACE("datepicker_text");
  if (moonui_native_kind_of(c) != 12) {
    return moonbit_make_bytes(0, 0);
  }
  if (SendMessageW(moonui_native_hwnd(c), DTM_GETSYSTEMTIME, 0, (LPARAM)&st) !=
      GDT_VALID) {
    return moonbit_make_bytes(0, 0);
  }
  snprintf(buf, sizeof(buf), "%04d-%02d-%02d %02d:%02d:%02d",
           (int)st.wYear, (int)st.wMonth, (int)st.wDay, (int)st.wHour,
           (int)st.wMinute, (int)st.wSecond);
  return moonui_native_bytes_of(buf);
}

/* ---- 固有尺寸（§18 "字体度量属于原生层"）----
 *
 * libui 那份把这件事交给 uiWindowsControlMinimumSize，这里没有 libui，算法照抄
 * （各控件 .cpp 里的 MinimumSize + sizing.cpp 的 DLU 换算），数值口径因此和
 * libui 那个后端同一副。DLU 的基准（BaseX = 52 字母宽取平均、BaseY = tmHeight、
 * x 除 4 / y 除 8）在 moonui_native_sizing_base 那一节。
 *
 * 常数全部来自 libui 对 Microsoft 那张 sizing 表的取舍（各 .cpp 顶上的 #define）：
 * entry 107×14、slider 107×15、progress 237×8、combobox 107×14、
 * checkbox/radio 的盒子到文字 12 DLU、行高 10 DLU、separator 细轴 1 DLU、
 * label 高 8 DLU。文字宽度用消息字体现量（libui 的 uiWindowsWindowTextWidth）。 */

/* 一段窗口文本在消息字体下的最大行宽（多行按行拆开取最大，libui 的 text.cpp 同款；
 * 这里控件文本都是单行，多行的那条路留给 Label 里带 \n 的极端用法）。 */
static int moonui_native_window_text_width(HWND hwnd) {
  int n;
  WCHAR *buf;
  int w;
  int h;
  int out = 0;
  n = GetWindowTextLengthW(hwnd);
  if (n <= 0) {
    return 0;
  }
  buf = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
  if (buf == 0) {
    return 0;
  }
  buf[0] = L'\0';
  GetWindowTextW(hwnd, buf, n + 1);
  moonui_native_text_extent(buf, &w, &h);
  out = w;
  free(buf);
  return out;
}

int64_t moonui_native_widget_minimum_size(moonui_ptr c) {
  HWND hwnd = moonui_native_hwnd(c);
  int kind = moonui_native_kind_of(c);
  int w = 0;
  int h = 0;
  SIZE size;
  TRACE("widget_minimum_size");
  switch (kind) {
    case 0: /* Label：文字宽 × 8 DLU 高（libui 的 label.cpp） */
      w = moonui_native_window_text_width(hwnd);
      h = moonui_native_dlu_y(hwnd, 8);
      break;
    case 1:
    case 14: /* Button / MenuRow：BCM_GETIDEALSIZE，拿不到退文字宽 + 2×SM_CXEDGE，
              * 高 14 DLU（libui 的 button.cpp）。 */
      size.cx = 0;
      size.cy = 0;
      if (SendMessageW(hwnd, BCM_GETIDEALSIZE, 0, (LPARAM)&size) != FALSE &&
          size.cx > 0) {
        w = (int)size.cx;
        h = (int)size.cy;
      } else {
        w = moonui_native_window_text_width(hwnd) + 2 * GetSystemMetrics(SM_CXEDGE);
        h = moonui_native_dlu_y(hwnd, 14);
      }
      break;
    case 2:
    case 4:
    case 7:
    case 9:
    case 10: /* 输入框家族：107×14 DLU（entry / combobox / multiline 同表） */
      w = moonui_native_dlu_x(hwnd, 107);
      h = moonui_native_dlu_y(hwnd, 14);
      break;
    case 3: /* Checkbox：盒子到文字 12 DLU + 文字宽，高 10 DLU */
      w = moonui_native_dlu_x(hwnd, 12) + moonui_native_window_text_width(hwnd);
      h = moonui_native_dlu_y(hwnd, 10);
      break;
    case 5: /* HSeparator：宽不管、高 1 DLU */
      h = moonui_native_dlu_y(hwnd, 1);
      break;
    case 6: /* Slider：107×15 DLU */
      w = moonui_native_dlu_x(hwnd, 107);
      h = moonui_native_dlu_y(hwnd, 15);
      break;
    case 8: /* Progress：237×8 DLU */
      w = moonui_native_dlu_x(hwnd, 237);
      h = moonui_native_dlu_y(hwnd, 8);
      break;
    case 11: { /* RadioButtons：12 DLU + 最宽一行，高 10 DLU × 行数 */
      MoonuiRadioKids *kids = moonui_native_radiokids_of(hwnd);
      int maxwid = 0;
      int i;
      if (kids == 0 || kids->len == 0) {
        break;
      }
      for (i = 0; i < kids->len; ++i) {
        int wid = moonui_native_window_text_width(kids->kids[i]);
        if (maxwid < wid) {
          maxwid = wid;
        }
      }
      w = moonui_native_dlu_x(hwnd, 12) + maxwid;
      h = moonui_native_dlu_y(hwnd, 10) * kids->len;
      break;
    }
    case 12: /* DatePicker：DTM_GETIDEALSIZE 的宽 × 14 DLU 高 */
      size.cx = 0;
      size.cy = 0;
      SendMessageW(hwnd, DTM_GETIDEALSIZE, 0, (LPARAM)&size);
      w = (int)size.cx;
      h = moonui_native_dlu_y(hwnd, 14);
      break;
    case 13: /* VSeparator：宽 1 DLU、高不管 */
      w = moonui_native_dlu_x(hwnd, 1);
      break;
    default: /* Scroll（15）：由内容决定，视口自己不占 */
      break;
  }
  return moonui_native_pack2(w, h);
}

int64_t moonui_native_widget_origin(moonui_ptr c) {
  HWND hwnd = moonui_native_hwnd(c);
  HWND parent = GetParent(hwnd);
  RECT r;
  POINT p;
  TRACE("widget_origin");
  if (parent == 0 || GetWindowRect(hwnd, &r) == 0) {
    return moonui_native_pack2(0, 0);
  }
  p.x = r.left;
  p.y = r.top;
  /* 屏幕坐标 -> 父窗口客户区坐标，正好和 moonui_native_control_set_bounds 收的那套一致 */
  ScreenToClient(parent, &p);
  return moonui_native_pack2((int)p.x, (int)p.y);
}

int64_t moonui_native_widget_size(moonui_ptr c) {
  RECT r;
  TRACE("widget_size");
  if (GetWindowRect(moonui_native_hwnd(c), &r) == 0) {
    return moonui_native_pack2(0, 0);
  }
  return moonui_native_pack2(r.right - r.left, r.bottom - r.top);
}

/* ---- 控件摆放（§14）----
 * 布局算在 MoonUI 这一侧。控件一出生寄放在 park 名下（moonui_native_create_control），
 * "挂进窗口"就是 SetParent 搬进目标窗口的客户区。WM_COMMAND 是发给父窗口的，
 * 顶层窗口过程是我们自己的，搬进去之后点击照样回来。Tab 顺序跟 z-order 走，
 * 所以每个新控件插到 z-order 末尾，插入顺序就是 Tab 顺序。 */
void moonui_native_control_attach(moonui_ptr window, moonui_ptr child) {
  HWND parent = moonui_native_hwnd(window);
  HWND hwnd = moonui_native_hwnd(child);
  HWND updown;
  TRACE("control_attach");
  if (GetParent(hwnd) == parent) {
    return;
  }
  if (SetParent(hwnd, parent) == 0) {
    return;
  }
  if ((LONG_PTR)GetWindowLongPtrW(hwnd, GWLP_ID) == 0) {
    /* ID 只要在本窗口内互不相同；起点避开 IDOK/IDCANCEL（1/2）。 */
    SetWindowLongPtrW(hwnd, GWLP_ID, (LONG_PTR)(1000 + moonui_native_next_control_id));
    moonui_native_next_control_id += 1;
  }
  /* spinbox 的 updown 是兄弟：edit 搬家它跟着搬，不然一条控件两扇窗。 */
  updown = moonui_native_updown_of(hwnd);
  if (updown != 0 && GetParent(updown) != parent) {
    SetParent(updown, parent);
  }
  SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOMOVE);
  moonui_native_spinbox_place_updown(hwnd);
}

void moonui_native_container_attach(moonui_ptr container, moonui_ptr child) {
  HWND hwnd;
  TRACE("container_attach");
  /* 唯一的合法容器是 kind 15 的剪裁视口；别的句柄进来不动，不猜。 */
  if (moonui_native_kind_of(container) != 15) {
    return;
  }
  hwnd = moonui_native_hwnd(child);
  if (GetParent(hwnd) == moonui_native_hwnd(container)) {
    return;
  }
  /* 子控件搬进剪裁容器：子窗口坐标本来就是父客户区坐标，Core 侧已按视口
   * 平移过的矩形直接生效；WS_CLIPCHILDREN 负责裁掉视口外的部分。 */
  SetParent(hwnd, moonui_native_hwnd(container));
}

void moonui_native_scroll_set_content(moonui_ptr scroll,
                               int axis,
                               int width,
                               int height) {
  /* 真滚动（滚动条 + 滚动行程）仍在挂账（adapter.c 同一条），这里只把口径占住：
   * kind 15 目前是纯剪裁容器，行程由 Core 自己的偏移记账。 */
  (void)scroll;
  (void)axis;
  (void)width;
  (void)height;
  TRACE("scroll_set_content");
}

void moonui_native_control_set_bounds(moonui_ptr child,
                               int x,
                               int y,
                               int width,
                               int height) {
  TRACE("control_set_bounds");
  /* z-order 原样保留：否则每次 resize 都会把控件重新排一遍，
   * Tab 顺序跟着布局抖动。 */
  SetWindowPos(moonui_native_hwnd(child), 0, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOZORDER);
  /* spinbox 的 updown 不在布局树里，edit 挪到哪儿它跟到哪儿。 */
  moonui_native_spinbox_place_updown(moonui_native_hwnd(child));
}

void moonui_native_control_detach(moonui_ptr child) {
  HWND hwnd = moonui_native_hwnd(child);
  HWND updown;
  TRACE("control_detach");
  if (moonui_native_park == 0) {
    return;
  }
  updown = moonui_native_updown_of(hwnd);
  if (SetParent(hwnd, moonui_native_park) == 0) {
    return;
  }
  if (updown != 0) {
    SetParent(updown, moonui_native_park);
  }
  /* ID 清零 = 回到"还没挂进任何窗口"的状态，重新 attach 时按新末尾插入 */
  SetWindowLongPtrW(hwnd, GWLP_ID, 0);
  SetWindowPos(hwnd, 0, 0, 0, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER);
}

/* Stack 的层叠（§14、§48-15）。Core 按数组顺序把 Stack 的叶子逐个提上来，
 * 提完之后的顺序就是"后提的在最上面"，也就是数组靠后的画在上层。
 * 只提不动矩形，所以这条和 set_bounds 互不干扰。 */
void moonui_native_control_raise(moonui_ptr child) {
  TRACE("control_raise");
  SetWindowPos(moonui_native_hwnd(child), HWND_TOP, 0, 0, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOMOVE);
}

/* 往上数 GW_HWNDPREV 的步数就是"从顶层数第几个"，和 EnumChildWindows 的返回
 * 顺序同向。所以这条既能当断言用，也顺手回答了"HWND_TOP 到底提到哪去了"。 */
int moonui_native_control_z_index(moonui_ptr child) {
  HWND hwnd;
  int index = 0;
  TRACE("control_z_index");
  hwnd = moonui_native_hwnd(child);
  if (GetParent(hwnd) == 0) {
    return -1;
  }
  hwnd = GetWindow(hwnd, GW_HWNDPREV);
  while (hwnd != 0) {
    ++index;
    hwnd = GetWindow(hwnd, GW_HWNDPREV);
  }
  return index;
}

/* spinbox 的 updown 摆位：libui 的 recreateUpDown（每次重排把 updown 拆掉重建，
 * windows/spinbox.cpp）太重，这里只挪——UDS_ALIGNRIGHT 只负责水平贴右，垂直方向
 * 自己对齐 edit 的顶边，宽度用 SM_CXVSCROLL（系统箭头那格的标准宽）。 */
static void moonui_native_spinbox_place_updown(HWND edit) {
  HWND updown = moonui_native_updown_of(edit);
  RECT r;
  if (updown == 0 || GetParent(edit) != GetParent(updown)) {
    return;
  }
  if (GetWindowRect(edit, &r) == 0) {
    return;
  }
  {
    int w = GetSystemMetrics(SM_CXVSCROLL);
    MapWindowPoints(0, GetParent(edit), (POINT *)&r, 2);
    SetWindowPos(updown, 0, r.right - w, r.top, w, r.bottom - r.top,
                 SWP_NOACTIVATE | SWP_NOZORDER);
  }
}

/* ---- 无障碍语义下发（§32 / T41）----
 * Core 在每次重排里随样式把语义一并推下来（apply_styles：先样式后语义）。
 * Win32 的走法是 MSAA 注记：控件是真实 HWND，读屏器（讲述人 / NVDA）通过
 * IAccessible 拿属性，而 IAccessible 的默认实现就是几个标准控件消息——名字是
 * WM_GETTEXT、状态是 WM_GETSTATELONG，都在 Core 推语义之前就有值。这里用
 * IAccPropServices::SetHwndProp(Str) 把 Core 算好的值**覆盖**上去：Annotation 只
 * 改"对外朗读什么"，不碰控件自己的窗口文本/使能状态，所以和 moonui_native_widget_set_text /
 * set_enabled 各管各的，不会互相踩。
 * State 刻意**不**注记（`T58` 真跑定案）：Core 推下来的 visible / enabled /
 * checked 三项本来就是从原生层现读的（`Widget::visible()` / `enabled()` /
 * `checked()`），而 MSAA 的标准代理对真实 HWND 恰好动态算这三个位（WS_VISIBLE /
 * WS_DISABLED / BM_GETCHECK）。SetHwndProp 覆盖 state 是拿一份快照换掉活读数：
 * 第一轮语义在窗口 show 之前推，INVISIBLE 位就此定格；用户点一下复选框，勾选位
 * 也不再跟随。读屏器要的正是代理那份活值。
 * 返回 0 = 已收下，-1 = 编码失败，-2 = 句柄不指窗口，-3 = COM/MSAA 拿不到。 */
static int moonui_native_acc_role_of(int role) {
  switch (role) {
    case 0: return ROLE_SYSTEM_STATICTEXT; /* Text */
    case 1: return ROLE_SYSTEM_PUSHBUTTON; /* Button */
    case 2: return ROLE_SYSTEM_CHECKBUTTON; /* CheckBox */
    case 3: return ROLE_SYSTEM_TEXT;        /* TextBox */
    case 4: return ROLE_SYSTEM_GROUPING;    /* Group */
    case 5: return ROLE_SYSTEM_LIST;        /* List */
    case 6: return ROLE_SYSTEM_LISTITEM;    /* ListItem */
    case 8: return ROLE_SYSTEM_SLIDER;      /* SliderRole */
    case 9: return ROLE_SYSTEM_PROGRESSBAR; /* ProgressRole */
    default: return ROLE_SYSTEM_WINDOW;     /* Window（§20 接上后才有可信 State） */
  }
}

int moonui_native_set_widget_accessibility(moonui_ptr c, int role,
                                    const char *label, int label_len,
                                    const char *desc, int desc_len,
                                    int state) {
  IAccPropServices *aps = 0;
  LPWSTR wlabel, wdesc;
  VARIANT v;
  HRESULT hr;
  HWND hwnd;
  (void)state; /* 见上面：state 走标准代理的活值，不用注记覆盖 */
  TRACE("set_widget_accessibility");
  hwnd = moonui_native_hwnd(c);
  if (hwnd == 0) {
    return -2;
  }
  wlabel = moonui_native_utf16_of(label, label_len);
  wdesc = moonui_native_utf16_of(desc, desc_len);
  if (wlabel == 0 || wdesc == 0) {
    free(wlabel);
    free(wdesc);
    return -1;
  }
  /* 套间初始化与文件面板同一条策略：S_FALSE（已初始化）照走，不配对
   * CoUninitialize——初始化是进程存活期的事。 */
  hr = CoInitializeEx(0, COINIT_APARTMENTTHREADED);
  if (hr != S_OK && hr != S_FALSE) {
    free(wlabel);
    free(wdesc);
    return -3;
  }
  hr = CoCreateInstance(&CLSID_AccPropServices, 0, CLSCTX_INPROC_SERVER,
                        &IID_IAccPropServices, (void **)&aps);
  if (hr != S_OK || aps == 0) {
    free(wlabel);
    free(wdesc);
    return -3;
  }
  aps->lpVtbl->SetHwndPropStr(aps, hwnd, (DWORD)OBJID_CLIENT, CHILDID_SELF,
                              PROPID_ACC_NAME, wlabel);
  aps->lpVtbl->SetHwndPropStr(aps, hwnd, (DWORD)OBJID_CLIENT, CHILDID_SELF,
                              PROPID_ACC_DESCRIPTION, wdesc);
  VariantInit(&v);
  v.vt = VT_I4;
  v.lVal = moonui_native_acc_role_of(role);
  aps->lpVtbl->SetHwndProp(aps, hwnd, (DWORD)OBJID_CLIENT, CHILDID_SELF,
                           PROPID_ACC_ROLE, v);
  aps->lpVtbl->Release(aps);
  free(wlabel);
  free(wdesc);
  return 0;
}

/* ---- 剪贴板（§23 / §48-19）----
 * 直打 Win32（契约见 adapter.h）：选 CF_UNICODETEXT 而不是 CF_TEXT——CF_TEXT 绑
 * 当前 ANSI 代码页，非 ASCII 文案（中文）在代码页转换里会丢字，UTF-16 没有这个
 * 问题，MoonBit 侧的 UTF-8 在这里就地转码。 */

/* OpenClipboard 是全系统一把锁：剪贴板监听器（云剪贴板、输入法的候选同步之类）会在
 * 每次剪贴板变动之后紧跟着开一次，撞上就是 ERROR_ACCESS_DENIED。真机实测这种撞锁是
 * 瞬态的，所以这里带一次有界重试（10 次 × 10ms）——失败仍然照契约报 -1，只是不再把
 * "隔壁进程刚看了一眼"当成"剪贴板坏了"。 */
static int moonui_native_clipboard_open(void) {
  int i;
  for (i = 0; i < 10; ++i) {
    if (OpenClipboard(NULL)) {
      return 1;
    }
    Sleep(10);
  }
  return 0;
}

moonbit_bytes_t moonui_native_clipboard_text(void) {
  moonbit_bytes_t out = moonbit_make_bytes(0, 0);
  HANDLE h;
  LPWSTR w;
  char *u;
  TRACE("clipboard_text");
  /* 这一问不需要 OpenClipboard：非文本内容（图片之类）在这里就报"没有"，
   * 于是 None 和"打不开剪贴板"给同一个回答，符合契约里对读路径的说明。 */
  if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    return out;
  }
  if (!moonui_native_clipboard_open()) {
    return out;
  }
  h = GetClipboardData(CF_UNICODETEXT);
  if (h != NULL) {
    w = (LPWSTR)GlobalLock(h);
    if (w != 0) {
      u = moonui_native_utf8_of(w);
      if (u != 0) {
        out = moonui_native_bytes_of(u);
        free(u);
      }
      GlobalUnlock(h);
    }
  }
  CloseClipboard();
  return out;
}

int moonui_native_clipboard_set_text(const char *text, int text_len) {
  LPWSTR w;
  SIZE_T bytes;
  HGLOBAL g;
  LPWSTR p;
  TRACE("clipboard_set_text");
  /* 空文案单独走：MoonBit 的 Bytes 不保证 NUL 结尾，而 cbMultiByte=0 那一形是
   * "按终止符自己数长度"，交给它一个零长块就是越界读。 */
  if (text_len == 0) {
    w = (LPWSTR)malloc(sizeof(WCHAR));
    if (w == 0) {
      return -2;
    }
    w[0] = L'\0';
  } else {
    w = moonui_native_utf16_of(text, text_len);
    if (w == 0) {
      return -2;
    }
  }
  /* CF_UNICODETEXT 要求块里带结尾的那个 L'\0'，GlobalSize 就是它。 */
  bytes = ((size_t)lstrlenW(w) + 1u) * sizeof(WCHAR);
  if (!moonui_native_clipboard_open()) {
    free(w);
    return -1;
  }
  if (!EmptyClipboard()) {
    free(w);
    CloseClipboard();
    return -2;
  }
  g = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (g == 0) {
    free(w);
    CloseClipboard();
    return -2;
  }
  p = (LPWSTR)GlobalLock(g);
  if (p == 0) {
    GlobalFree(g);
    free(w);
    CloseClipboard();
    return -2;
  }
  memcpy(p, w, bytes);
  GlobalUnlock(g);
  free(w);
  /* 交出去之后就再不能 GlobalFree：成功时所有权归剪贴板，失败时才由我们回收。 */
  if (SetClipboardData(CF_UNICODETEXT, g) == NULL) {
    GlobalFree(g);
    CloseClipboard();
    return -2;
  }
  CloseClipboard();
  return 0;
}

/* ---- 对话框（§24 / §48-18）----
 * 契约见 adapter.h 的对话框那段：为什么不带窗口句柄、-1/-2 两个失败码分别是什么。
 *
 * MessageBoxW 在自己的调用里跑一层任务模态循环（MB_TASKMODAL：调用线程此后只在
 * 那个对话框的消息循环里，和 mac 的 NSAlert runModal 同层），所以它必须从 handler
 * 里调用，且期间 MoonBit 一行都跑不到。 */

/* 测试脚手架装的那发"用户会在 ms 毫秒后按第 index 个按钮"，认领者是本文件下面
 * moonui_native_start_dismissor（在 MessageBoxW 之前认领，因为调用一阻塞就没机会了）。 */
static int moonui_native_dismiss_after_ms = -1;
static int moonui_native_dismiss_index = -1;

/* MessageBoxW 建出来的对话框用的是系统预定义类 "#32770"（对话框类没有别的名字），
 * 所以要找回它只能按类名找，窗口标题是我们传进去的那串，用来在同类的窗口里认它。 */
#define MOONUI_DIALOG_CLASS L"#32770"

/* 找对话框和等它收摊各自的预算。这两个数只影响"脚手架坏掉之后多久变成红"，
 * 不影响走绿的那条路。 */
#define MOONUI_DISMISS_LOOK_MS 4000
#define MOONUI_DISMISS_POLL_MS 25

typedef struct {
  WCHAR *caption; /* 自己拷的一份，由本结构负责 free */
  WORD id;        /* 要点的那只按钮的控件 ID */
  DWORD delay_ms;
} MoonuiDismiss;

/* 等这只对话框消失；返回"有没有等到"。 */
static int moonui_native_dialog_gone(HWND dialog) {
  int waited;
  for (waited = 0; waited < MOONUI_DISMISS_LOOK_MS && IsWindow(dialog);
       waited += MOONUI_DISMISS_POLL_MS) {
    Sleep(MOONUI_DISMISS_POLL_MS);
  }
  return !IsWindow(dialog);
}

static DWORD WINAPI moonui_native_dismiss_worker(LPVOID raw) {
  MoonuiDismiss *d = (MoonuiDismiss *)raw;
  HWND dialog = 0;
  int waited;
  Sleep(d->delay_ms);
  /* 先按类名加标题找，再退到只按类名：本进程的对话框只有这一只，退那一档是为了
   * 标题在某些系统版本上被截字或加省略号时还能认出来。 */
  for (waited = 0; dialog == 0 && waited < MOONUI_DISMISS_LOOK_MS;
       waited += MOONUI_DISMISS_POLL_MS) {
    dialog = FindWindowExW(0, 0, MOONUI_DIALOG_CLASS, d->caption);
    if (dialog == 0) {
      Sleep(MOONUI_DISMISS_POLL_MS);
    }
  }
  if (dialog == 0) {
    dialog = FindWindowExW(0, 0, MOONUI_DIALOG_CLASS, 0);
  }
  if (dialog != 0) {
    /* BM_CLICK 让按钮自己发出 WM_COMMAND/BN_CLICKED，对话框因此以那个控件 ID 收摊
     * ——答案是 MessageBox 自己给的，不是这里编的（和 mac 的 performClick: 同一个
     * 理由，也和 moonui_native_click_button_in_window 同一个理由）。 */
    SendDlgItemMessageW(dialog, d->id, BM_CLICK, 0, 0);
    /* 两级兜底。按下没生效时，WM_CLOSE 和 ESC 都会让 MessageBox 以 IDCANCEL 结束，
     * 于是调用方拿到"否"、断言红在那里。留着这段是因为脚手架坏掉的代价不该是
     * 一整轮挂住的测试。 */
    if (!moonui_native_dialog_gone(dialog)) {
      PostMessageW(dialog, WM_CLOSE, 0, 0);
      if (!moonui_native_dialog_gone(dialog)) {
        PostMessageW(dialog, WM_KEYDOWN, VK_ESCAPE, 0);
      }
    }
  }
  free(d->caption);
  free(d);
  return 0;
}

/* 认领装好的那发，并在 MessageBoxW 阻塞之前把线程起好。没装就是空操作（产品路径
 * 永远不装）。index 越界时退到本对话框的最后一只按钮（"否"或"确定"）——理由同上：
 * 写错的脚手架要红在断言上，不要挂住整轮。 */
static void moonui_native_start_dismissor(const WORD *ids, int count, LPCWSTR caption) {
  MoonuiDismiss *d;
  HANDLE thread;
  DWORD tid;
  int index;
  int n;
  if (moonui_native_dismiss_after_ms < 0 || count <= 0 || caption == 0) {
    return;
  }
  index = moonui_native_dismiss_index;
  d = (MoonuiDismiss *)malloc(sizeof(*d));
  if (d == 0) {
    return;
  }
  for (n = 0; caption[n] != L'\0'; ++n) {
  }
  d->caption = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
  if (d->caption == 0) {
    free(d);
    return;
  }
  for (n = 0; caption[n] != L'\0'; ++n) {
    d->caption[n] = caption[n];
  }
  d->caption[n] = L'\0';
  if (index < 0 || index >= count) {
    index = count - 1;
  }
  d->id = ids[index];
  d->delay_ms = (DWORD)(moonui_native_dismiss_after_ms < 0 ? 0 : moonui_native_dismiss_after_ms);
  /* 认领即失效：这一发只属于当前这个对话框，不许漏给下一个。 */
  moonui_native_dismiss_after_ms = -1;
  moonui_native_dismiss_index = -1;
  thread = CreateThread(0, 0, moonui_native_dismiss_worker, d, 0, &tid);
  if (thread == 0) {
    free(d->caption);
    free(d);
    return;
  }
  /* 主线程不能 join：它马上要进模态循环，而这一发的按钮点击正是要发给那个循环。
     CloseHandle 只关掉本线程自己的句柄，线程对象在它跑完之前都还在。 */
  CloseHandle(thread);
}

int moonui_native_dialog_message(const char *title,
                          int title_len,
                          const char *text,
                          int text_len) {
  static const WORD ids[1] = {IDOK};
  LPWSTR t = moonui_native_utf16_of(title, title_len);
  LPWSTR s = moonui_native_utf16_of(text, text_len);
  int rc;
  TRACE("dialog_message");
  if (t == 0 || s == 0) {
    free(t);
    free(s);
    return -1;
  }
  moonui_native_start_dismissor(ids, 1, t);
  rc = (int)MessageBoxW(0, s, t, MB_OK | MB_TASKMODAL);
  free(t);
  free(s);
  if (rc == 0) {
    return -2; /* MessageBox 没建起来（最后一个参数是内存不足之类） */
  }
  /* 只有一只按钮，"按了确定"和"被关掉"对调用方是同一件事：§24 的 message 返回
   * Unit，这个区别没有地方放。 */
  return 0;
}

int moonui_native_dialog_confirm(const char *title,
                          int title_len,
                          const char *text,
                          int text_len) {
  static const WORD ids[2] = {IDYES, IDNO};
  LPWSTR t = moonui_native_utf16_of(title, title_len);
  LPWSTR s = moonui_native_utf16_of(text, text_len);
  int rc;
  TRACE("dialog_confirm");
  if (t == 0 || s == 0) {
    free(t);
    free(s);
    return -1;
  }
  moonui_native_start_dismissor(ids, 2, t);
  rc = (int)MessageBoxW(0, s, t, MB_YESNO | MB_TASKMODAL);
  free(t);
  free(s);
  if (rc == 0) {
    return -2;
  }
  /* IDYES 才是"是"。IDNO、被 ESC 或关闭按钮掉的 IDCANCEL 一律算"没同意"，
   * 对上 §24 的"取消返回 false"。 */
  return rc == IDYES ? 1 : 0;
}

/* ---- 文件面板（§24 / §48-18）----
 * 契约在 adapter.h 的文件对话框那段：返回码表、结果取走语义。
 *
 * 与 mac 那份有一处结构性差别：IFileDialog 在本进程自己的模态循环里跑（macOS
 * 15.6 的面板在 XPC 服务进程里），所以测试脚手架能替用户真的按下"打开 / 保存 /
 * 选择文件夹"——按下去的是真按键，路径由面板自己的提交路径给出（见下面
 * moonui_native_file_answer_worker）。 */

/* 测试脚手架装的那发"用户会在 ms 毫秒后对下一个面板按接受 / 取消，且面板停在
 * path 上"。认领者是下面的 moonui_native_claim_file_answer（Show 之前认领，因为 Show
 * 一进模态循环主线程就没机会了）；装它的入口 moonui_native_auto_answer_file_dialog 在
 * 测试脚手架那段。 */
static int moonui_native_file_answer_after_ms = -1;
static int moonui_native_file_answer_accept = 0;
static WCHAR *moonui_native_file_answer_path = 0;

/* 面板结果的落点：到 moonui_native_file_dialog_path 取走（或下一次面板打开）之前归本
 * 文件所有。取走语义和 mac 那份逐字一致，免得两边各理解一次。 */
static char *moonui_native_file_result = 0;

/* 三种形态共用一段实现，取值和 mac 的 MOONUI_FILE_* 同一张表。 */
#define MOONUI_FILE_OPEN 0
#define MOONUI_FILE_SAVE 1
#define MOONUI_FILE_FOLDER 2

typedef struct {
  WCHAR *caption; /* 自己拷的一份，由本结构负责 free */
  int accept;     /* 1 = 按下接受，0 = 关掉（取消） */
  DWORD delay_ms;
} MoonuiFileAnswer;

/* 到点按下按钮的线程，和上面 moonui_native_dismiss_worker 的结构逐句对应（找对话框、
 * 真按键、逐级兜底），差别只在"按什么"：接受是回车 / IDOK，取消是关闭 / ESC。 */
static DWORD WINAPI moonui_native_file_answer_worker(LPVOID raw) {
  MoonuiFileAnswer *a = (MoonuiFileAnswer *)raw;
  HWND dialog = 0;
  int waited;
  Sleep(a->delay_ms);
  /* 文件对话框也是系统预定义对话框类 "#32770"，标题是 SetTitle 的那串；找不到时
   * 退到只按类名，这一档和 moonui_native_dismiss_worker 同一个理由。 */
  for (waited = 0; dialog == 0 && waited < MOONUI_DISMISS_LOOK_MS;
       waited += MOONUI_DISMISS_POLL_MS) {
    dialog = FindWindowExW(0, 0, MOONUI_DIALOG_CLASS, a->caption);
    if (dialog == 0) {
      Sleep(MOONUI_DISMISS_POLL_MS);
    }
  }
  if (dialog == 0) {
    dialog = FindWindowExW(0, 0, MOONUI_DIALOG_CLASS, 0);
  }
  if (dialog != 0) {
    if (a->accept) {
      /* 第一级投一条"按下回车"：它落在 Show 自己的模态循环里，由对话框的按键
       * 翻译变成"按下默认钮"，也就是真人敲回车那条提交路径——不赌 OK 钮是顶层
       * 对话框的直接子窗口（IFileDialog 的界面是 DirectUI 画的，按钮通常不是
       * 子窗口，SendDlgItemMessage 因此排在第二级）。投递而不是发送：按键翻译
       * 发生在消息循环里，SendMessage 绕过了它。 */
      PostMessageW(dialog, WM_KEYDOWN, VK_RETURN, 1);
      if (!moonui_native_dialog_gone(dialog)) {
        /* 第二级是老式对话框形态的 OK 钮（控件 ID 固定是 IDOK）。BM_CLICK 让
         * 按钮自己发 BN_CLICKED，面板的提交路径因此真跑一遍——回来的路径是
         * 面板兑的，不是这里编的。 */
        SendDlgItemMessageW(dialog, IDOK, BM_CLICK, 0, 0);
        if (!moonui_native_dialog_gone(dialog)) {
          PostMessageW(dialog, WM_CLOSE, 0, 0);
          if (!moonui_native_dialog_gone(dialog)) {
            PostMessageW(dialog, WM_KEYDOWN, VK_ESCAPE, 0);
          }
        }
      }
    } else {
      /* 取消是关掉对话框：WM_CLOSE 让 Show 以 ERROR_CANCELLED 回来，和真人按
       * "取消"同一条路。 */
      PostMessageW(dialog, WM_CLOSE, 0, 0);
      if (!moonui_native_dialog_gone(dialog)) {
        PostMessageW(dialog, WM_KEYDOWN, VK_ESCAPE, 0);
      }
    }
    /* 兜底那一串只影响"脚手架坏掉之后多久变成红"：每一级要么让面板以某个答案
     * 收摊（绿的各归断言），要么交给下一级；连最后一级的 WM_CLOSE / ESC 都不起
     * 作用时才会挂住——那时取消路径也一起坏了，不是接受特有的风险。 */
  }
  free(a->caption);
  free(a);
  return 0;
}

/* 认领装好的那发（如果有）：先把面板导航到装好的路径，再把替按的线程起好，
 * 两个动作都赶在 Show 之前。没装就是空操作（产品路径永远不装），认领即失效——
 * 这一发只属于当前这个面板，不许漏给下一个，和 mac 的 moonui_native_arm_file_answer
 * 同一个时点。 */
static void moonui_native_claim_file_answer(IFileDialog *dialog, LPCWSTR caption) {
  MoonuiFileAnswer *a;
  HANDLE thread;
  DWORD tid;
  WCHAR *path;
  int accept;
  DWORD after;
  int n;
  if (moonui_native_file_answer_after_ms < 0) {
    return;
  }
  accept = moonui_native_file_answer_accept;
  path = moonui_native_file_answer_path;
  after = (DWORD)moonui_native_file_answer_after_ms;
  moonui_native_file_answer_after_ms = -1;
  moonui_native_file_answer_accept = 0;
  moonui_native_file_answer_path = 0;
  if (path != 0) {
    /* 全路径形态（adapter.h 的脚手架契约）：open / save 是把"要选的文件"写进
     * 文件名栏，folder 是把"要选的文件夹"写进去。写进去之后是否真被选中，由
     * 面板自己的提交路径决定。 */
    dialog->lpVtbl->SetFileName(dialog, path);
    free(path);
  }
  a = (MoonuiFileAnswer *)malloc(sizeof(*a));
  if (a == 0) {
    return;
  }
  for (n = 0; caption[n] != L'\0'; ++n) {
  }
  a->caption = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
  if (a->caption == 0) {
    free(a);
    return;
  }
  for (n = 0; caption[n] != L'\0'; ++n) {
    a->caption[n] = caption[n];
  }
  a->caption[n] = L'\0';
  a->accept = accept;
  a->delay_ms = after;
  thread = CreateThread(0, 0, moonui_native_file_answer_worker, a, 0, &tid);
  if (thread == 0) {
    free(a->caption);
    free(a);
    return;
  }
  /* 和 moonui_native_start_dismissor 同一行注释：主线程马上要进模态循环，不能 join；
   * CloseHandle 只关掉本线程自己的句柄，线程对象在它跑完之前都还在。 */
  CloseHandle(thread);
}

/* 三种形态共用的一段：建 COM 对话框、设选项、跑 Show 的模态循环、把结果存进
 * moonui_native_file_result。 */
static int moonui_native_run_file_panel(const char *title,
                                 int title_len,
                                 const char *default_name,
                                 int default_name_len,
                                 int mode) {
  LPWSTR t;
  LPWSTR d = 0;
  IFileDialog *dialog = 0;
  FILEOPENDIALOGOPTIONS opts;
  HRESULT hr;
  int rc;
  t = moonui_native_utf16_of(title, title_len);
  if (t == 0) {
    return -1;
  }
  if (default_name != 0) {
    d = moonui_native_utf16_of(default_name, default_name_len);
    if (d == 0) {
      free(t);
      return -1;
    }
  }
  /* IFileDialog 是 apartment 对象、Show 要求 STA，所以先把本线程放回单线程套间：
   * S_FALSE = 已经初始化过（同模式），照走；RPC_E_CHANGED_MODE = 别处已经按 MTA
   * 初始化了，那种局面 Show 不支持，如实报 -2。初始化是进程存活期的事，这里不
   * 配对 CoUninitialize（测试进程和 Demo 都不在意那点引用计数）。 */
  hr = CoInitializeEx(0, COINIT_APARTMENTTHREADED);
  if (hr != S_OK && hr != S_FALSE) {
    free(t);
    free(d);
    return -2;
  }
  hr = CoCreateInstance(mode == MOONUI_FILE_SAVE ? &CLSID_FileSaveDialog
                                                 : &CLSID_FileOpenDialog,
                        0, CLSCTX_INPROC_SERVER, &IID_IFileDialog,
                        (void **)&dialog);
  if (hr != S_OK || dialog == 0) {
    free(t);
    free(d);
    return -2;
  }
  if (dialog->lpVtbl->GetOptions(dialog, &opts) != S_OK) {
    opts = 0;
  }
  /* FOS_FORCEFILESYSTEM 是拿到文件系统路径的前提（不然 GetResult 可能是库里的
   * 虚拟项，SIGDN_FILESYSPATH 会失败）；FOS_PATHMUSTEXIST 三种形态都成立。 */
  opts |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
  if (mode == MOONUI_FILE_OPEN) {
    opts |= FOS_FILEMUSTEXIST;
  }
  if (mode == MOONUI_FILE_FOLDER) {
    opts |= FOS_PICKFOLDERS;
  }
  dialog->lpVtbl->SetOptions(dialog, opts);
  dialog->lpVtbl->SetTitle(dialog, t);
  if (d != 0) {
    dialog->lpVtbl->SetFileName(dialog, d);
  }
  /* 结果取走语义的另一半：每开一次面板，上一次的还没取走的就作废。 */
  free(moonui_native_file_result);
  moonui_native_file_result = 0;
  moonui_native_claim_file_answer(dialog, t);
  hr = dialog->lpVtbl->Show(dialog, 0);
  rc = -2;
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    rc = 0;
  } else if (hr == S_OK) {
    /* S_OK = 用户按了接受、提交路径已经跑完，取它兑出来的路径。 */
    IShellItem *item = 0;
    if (dialog->lpVtbl->GetResult(dialog, &item) == S_OK && item != 0) {
      LPWSTR p = 0;
      if (item->lpVtbl->GetDisplayName(item, SIGDN_FILESYSPATH, &p) == S_OK &&
          p != 0) {
        char *u = moonui_native_utf8_of(p);
        if (u != 0) {
          moonui_native_file_result = moonui_native_dup(u, (int)strlen(u));
          free(u);
        }
        CoTaskMemFree(p);
      }
      item->lpVtbl->Release(item);
    }
    /* 选了东西但路径没拿到：属于"面板状态不对"，同 mac 归 -2。 */
    if (moonui_native_file_result != 0) {
      rc = 1;
    }
  }
  dialog->lpVtbl->Release(dialog);
  free(t);
  free(d);
  return rc;
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

/* 取走结果：返回值是当场拷进 MoonBit 堆的一份（GC 回收，那边不用 free），内部
 * 指针顺带清空。没结果时给空 bytes。和 mac 那份逐字一致。 */
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
 * 直写 HMENU，不走任何 GUI 库（本后端没有 libui 可绕）。形状：
 *   - 菜单位是**逐窗口**的（SetMenu 本来就是逐窗口的），所以"装一棵"= 给当下每只
 *     活窗口各建一棵 HMENU，并把树本身留下，之后新建的窗口照着再建一棵。活窗口
 *     记在 moonui_native_win_menu 这张定长表里：moonui_native_window_new 登记、
 *     moonui_native_window_destroy 摘掉。表满了只是"这只窗口没有菜单位"，窗口本身照建
 *     （64 只对 Demo 和测试都远够用）。
 *   - 命令 id = Core 的 id + MOONUI_MENU_ID_BASE。基址避开控件那批（attach 时发
 *     1000+，见 moonui_native_control_attach）。WM_COMMAND 只带 16 位 id，所以越界在装
 *     之前就当场报 -1，不许留到点击时变成"消息发出去了、回调没跑"。
 *   - 顶层窗口过程本来就是我们的（分叉清单第 3 条），不需要 adapter.c 那层
 *     GWLP_WNDPROC 子类化——命中基址的菜单命令在 moonui_native_wndproc 里就地截下。
 *   - role（Normal/Check/Radio）存在条目的 dwItemData 上。状态位里的 MF_CHECKED
 *     分不清 Check 和 Radio（没勾的 Check 项两个位都没有），而快照要分得开 c/r。
 *   - 装完把菜单位挤掉的客户区高度还给 Core：行高不抄 SM_CYMENU（不同 DPI、
 *     不同菜单字体下它不等于实际行高），而是量出来的。补偿走我们自己的
 *     moonui_native_set_client_size——它用 AdjustWindowRectEx 现量"当下挂着的菜单"，
 *     补那一行本来就是它的职责，不像 libui 那侧还得外加 menu_pad。 */

/* 当下这棵树的原样副本（布局见 adapter.h），新建窗口照着它再建一棵 HMENU；
 * moonui_native_menu_top_count 是装的时候试建那棵数出来的顶层数，0 = 没有菜单位。 */
static char *moonui_native_menu_tree = 0;
static int moonui_native_menu_tree_len = 0;
static int moonui_native_menu_top_count = 0;

/* ---- 打包树的读游标（布局见 adapter.h，和 mac 那一份逐字段同形）---- */

typedef struct {
  const unsigned char *p;
  int len;
  int pos;
  int bad;
} MoonuiTree;

static void moonui_native_tree_init(MoonuiTree *t, const char *bytes, int len) {
  t->p = (const unsigned char *)bytes;
  t->len = len;
  t->pos = 0;
  t->bad = 0;
}

static int moonui_native_tree_u8(MoonuiTree *t) {
  if (t->bad || t->pos + 1 > t->len) {
    t->bad = 1;
    return 0;
  }
  return (int)t->p[t->pos++];
}

/* 小端 i32。四个字节齐了才动 pos，越界的那一步整体作废（bad 一旦为真就不再翻案）。 */
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

/* i32 长度 + UTF-8 → UTF-16（malloc，调用方 free）。转不出来也算读坏：树是 MoonBit
 * `@utf8.encode` 出来的，坏字节只可能是布局和 adapter.h 对不上，那正是 -1 要报的东西。 */
static LPWSTR moonui_native_tree_wstr(MoonuiTree *t) {
  int n;
  LPWSTR w;
  if (t->bad) {
    return 0;
  }
  n = moonui_native_tree_i32(t);
  if (t->bad || n < 0 || t->pos + n > t->len) {
    t->bad = 1;
    return 0;
  }
  w = moonui_native_utf16_of((const char *)(t->p + t->pos), n);
  t->pos += n;
  if (w == 0) {
    t->bad = 1;
  }
  return w;
}

/* ---- 建 HMENU ---- */

/* 组合的显示文本拼在标题后面、用 \t 隔开：Win32 的菜本来就把自己那行里的 \t 之后右对齐
 * 排在同一行，所以不需要 owner-draw。不建 accelerator table——§26 的派发在 Core 的事件
 * 循环里，不在 Win32 的加速键表里（adapter.h）。
 * 拼法和 Core 的 `Shortcut::label()` 同一套：修饰键固定顺序 Ctrl→Alt→Shift→Meta，meta
 * 写中性词 "Meta"，键名从树里原样带过来（词表就是 Core 那套，这里不另立第二个）。
 * 键名为空时整个尾巴不拼——那是 Core 给了一个没有键的组合，mac 那边同样的组合也落不到
 * keyEquivalent 上，两边因此在快照里都读回 "."。 */
static LPWSTR moonui_native_menu_item_text(LPCWSTR label, int has_sc, int mods,
                                    LPCWSTR key) {
  static const WCHAR *names[4] = {L"Ctrl+", L"Alt+", L"Shift+", L"Meta+"};
  int with_tail;
  size_t need;
  int i;
  LPWSTR out;
  WCHAR *p;
  with_tail = (has_sc != 0 && key != 0 && key[0] != L'\0') ? 1 : 0;
  need = (size_t)lstrlenW(label) + 1u;
  if (with_tail) {
    need += 1u; /* \t */
    for (i = 0; i < 4; ++i) {
      if (mods & (1 << i)) {
        need += (size_t)lstrlenW(names[i]);
      }
    }
    need += (size_t)lstrlenW(key);
  }
  out = (LPWSTR)malloc(need * sizeof(WCHAR));
  if (out == 0) {
    return 0;
  }
  p = out;
  lstrcpyW(p, label);
  p += lstrlenW(label);
  if (with_tail) {
    *p++ = L'\t';
    for (i = 0; i < 4; ++i) {
      if (mods & (1 << i)) {
        lstrcpyW(p, names[i]);
        p += lstrlenW(names[i]);
      }
    }
    lstrcpyW(p, key);
    p += lstrlenW(key);
  }
  *p = L'\0';
  return out;
}

/* 读 kind 0 剩下的字段并挂到 menu 末尾（kind 字节由调用方读过）。 */
static int moonui_native_menu_append_item(HMENU menu, MoonuiTree *t) {
  LPWSTR label;
  LPWSTR key = 0;
  LPWSTR text;
  int item_id;
  int role;
  int checked;
  int enabled;
  int has_sc;
  int mods = 0;
  int ok;
  MENUITEMINFOW mi;
  label = moonui_native_tree_wstr(t);
  item_id = moonui_native_tree_i32(t);
  role = moonui_native_tree_u8(t);
  checked = moonui_native_tree_u8(t);
  enabled = moonui_native_tree_u8(t);
  has_sc = moonui_native_tree_u8(t);
  if (has_sc != 0) {
    mods = moonui_native_tree_u8(t);
    key = moonui_native_tree_wstr(t);
  }
  if (t->bad || (role != 0 && role != 1 && role != 2)) {
    free(label);
    free(key);
    return 0;
  }
  /* id 加基址之后要装得进 WM_COMMAND 的低 16 位。装之前就当场判掉，否则这一项挂得上、
   * 点下去却对不上号。 */
  if (item_id < 0 || item_id > 0xFFFF - MOONUI_MENU_ID_BASE) {
    free(label);
    free(key);
    return 0;
  }
  text = moonui_native_menu_item_text(label, has_sc, mods, key);
  free(label);
  free(key);
  if (text == 0) {
    t->bad = 1;
    return 0;
  }
  ZeroMemory(&mi, sizeof(mi));
  mi.cbSize = sizeof(mi);
  mi.fMask = MIIM_FTYPE | MIIM_STRING | MIIM_ID | MIIM_STATE | MIIM_DATA;
  mi.fType = MF_STRING;
  if (role == 2) {
    /* 圆点而不是勾。它是**类型**位不是状态位，所以下面推勾选态时必须把 fType 一起写回，
     * 不然勾还在、圆点没了。 */
    mi.fType |= MFT_RADIOCHECK;
  }
  mi.fState = (enabled != 0 ? MF_ENABLED : MF_GRAYED) |
              (checked != 0 ? MF_CHECKED : MF_UNCHECKED);
  mi.wID = (UINT)(item_id + MOONUI_MENU_ID_BASE);
  mi.dwTypeData = text;
  mi.cch = (UINT)lstrlenW(text);
  mi.dwItemData = (ULONG_PTR)role;
  /* (UINT)-1 配 fByPosition=TRUE 就是追加到末尾，和 AppendMenuW 同一条路，只是这一发
   * 能把 id、状态、role、文案一次带上。 */
  ok = InsertMenuItemW(menu, (UINT)-1, TRUE, &mi) != 0;
  free(text);
  if (!ok) {
    t->bad = 1;
  }
  return ok;
}

/* 往 menu 里填 count 个条目；Submenu 那一支自己递归。任何一步读坏就返回 0，调用方把
 * 整棵作废（不留"半棵树"）。半途失败时这一层已经挂上去的条目不用逐个摘：顶层
 * DestroyMenu 会连带把整棵连同子菜单一起销毁。 */
static int moonui_native_menu_fill(HMENU menu, MoonuiTree *t, int count) {
  int i;
  for (i = 0; i < count; ++i) {
    int kind = moonui_native_tree_u8(t);
    if (t->bad) {
      return 0;
    }
    if (kind == 0) {
      if (!moonui_native_menu_append_item(menu, t)) {
        return 0;
      }
    } else if (kind == 1) {
      if (AppendMenuW(menu, MF_SEPARATOR, 0, 0) == 0) {
        t->bad = 1;
        return 0;
      }
    } else if (kind == 2) {
      LPWSTR label = moonui_native_tree_wstr(t);
      int sub_count = moonui_native_tree_i32(t);
      HMENU sub;
      if (t->bad || sub_count < 0) {
        free(label);
        return 0;
      }
      sub = CreatePopupMenu();
      if (sub == 0) {
        free(label);
        t->bad = 1;
        return 0;
      }
      if (!moonui_native_menu_fill(sub, t, sub_count)) {
        free(label);
        DestroyMenu(sub);
        return 0;
      }
      /* 子菜单挂在父条目上就是 MF_POPUP + 句柄当值。 */
      if (AppendMenuW(menu, MF_POPUP | MF_STRING, (UINT_PTR)sub, label) == 0) {
        free(label);
        DestroyMenu(sub);
        t->bad = 1;
        return 0;
      }
      free(label);
    } else {
      /* 未知 kind：树和 adapter.h 的布局对不上，报 -1 */
      return 0;
    }
  }
  return 1;
}

/* 从游标当前位置建整棵（version + 顶层数 + 每顶一条子菜单）。返回 0 就是没建起来；
 * 是不是"树不合法"要看 t->bad——只有分配失败才不置 bad。 */
static HMENU moonui_native_menu_build(MoonuiTree *t) {
  HMENU bar;
  int count;
  int i;
  bar = CreateMenu();
  if (bar == 0) {
    return 0;
  }
  if (moonui_native_tree_u8(t) != 1) {
    DestroyMenu(bar);
    return 0;
  }
  count = moonui_native_tree_i32(t);
  if (t->bad || count < 0) {
    DestroyMenu(bar);
    return 0;
  }
  for (i = 0; i < count; ++i) {
    LPWSTR label = moonui_native_tree_wstr(t);
    int node_count = moonui_native_tree_i32(t);
    HMENU sub;
    if (t->bad || node_count < 0) {
      free(label);
      DestroyMenu(bar);
      return 0;
    }
    sub = CreatePopupMenu();
    if (sub == 0) {
      free(label);
      DestroyMenu(bar);
      return 0;
    }
    if (!moonui_native_menu_fill(sub, t, node_count)) {
      free(label);
      DestroyMenu(sub);
      DestroyMenu(bar);
      return 0;
    }
    if (AppendMenuW(bar, MF_POPUP | MF_STRING, (UINT_PTR)sub, label) == 0) {
      free(label);
      DestroyMenu(sub);
      DestroyMenu(bar);
      t->bad = 1;
      return 0;
    }
    free(label);
  }
  return bar;
}

/* ---- 逐窗口：登记、挂上、摘掉 ---- */

/* 给一只窗口换上 bar（0 = 摘掉），并把菜单位挤掉的客户区高度还给 Core。
 *
 * 行高不抄 SM_CYMENU：摘掉量一次、挂上再量一次，两次之间唯一的变量就是"挂着没
 * 挂着"，差值才是这一行真正占掉多少。补偿走 moonui_native_set_client_size：它用
 * AdjustWindowRectEx 现量"当下挂着的菜单"（此刻已经挂上），外框自然把这一行
 * 算进去——这就是 adapter.c 那套 menu_pad 手工账在这里不需要的原因。挂上之后
 * 要是 SetMenu 没成功，量出来的高度和原来一样，补偿也不做，而快照读回来的是
 * 系统当下真正挂着的那棵——失败会红在断言上，不会变成一处悄悄偏矮的布局。 */
static void moonui_native_menu_apply(MoonuiWindowMenu *e, HMENU bar, int restore) {
  RECT c0;
  RECT c_yes;
  HMENU prev;
  int width;
  int height;
  GetClientRect(e->hwnd, &c0);
  width = c0.right - c0.left;
  height = c0.bottom - c0.top;
  prev = GetMenu(e->hwnd);
  SetMenu(e->hwnd, 0);
  if (prev != 0 && prev != bar) {
    DestroyMenu(prev);
  }
  if (bar != 0) {
    SetMenu(e->hwnd, bar);
  }
  e->bar = bar;
  GetClientRect(e->hwnd, &c_yes);
  e->menu_pad = (height) - (c_yes.bottom - c_yes.top);
  /* 两个方向都要补：挂上客户区矮一行、拆掉又长回来（行 3044 那段注释只写了
   * 匂上那半）。判据还是"客户区真变了"——SetMenu 没成功时量不出差，自然不补。 */
  if (restore && (c_yes.bottom - c_yes.top) != height) {
    moonui_native_set_client_size(e->hwnd, width, height);
  }
}

/* 照存下来的那棵树给这只窗口现建一棵挂上；没装过菜单、或者装的是空的一棵 → 摘掉。 */
static void moonui_native_menu_refresh(MoonuiWindowMenu *e, int restore) {
  HMENU bar = 0;
  if (moonui_native_menu_tree != 0 && moonui_native_menu_top_count > 0) {
    MoonuiTree t;
    moonui_native_tree_init(&t, moonui_native_menu_tree, moonui_native_menu_tree_len);
    bar = moonui_native_menu_build(&t);
    if (bar == 0) {
      /* 同一份字节第二次读坏，只可能是我们自己把副本写坏了。这一只窗口就不挂菜单，
       * 不把半棵树端上去。 */
      return;
    }
  }
  moonui_native_menu_apply(e, bar, restore);
}

static int moonui_native_menu_wanted(void) {
  return moonui_native_menu_tree != 0 && moonui_native_menu_top_count > 0;
}

/* 登记一只新建的顶层窗口。菜单 / 图标 / 全屏 / 焦点链的逐窗口待遇全从这张表起步；
 * 表满了这只窗口就只当普通窗口用（moonui_native_window_new 已经建好了它）。 */
static void moonui_native_menu_register(HWND hwnd) {
  MoonuiWindowMenu *e = moonui_native_menu_free_slot();
  if (e == 0) {
    return;
  }
  e->hwnd = hwnd;
  e->bar = 0;
  e->menu_pad = 0;
  e->focus_chain = 0;
  e->focus_chain_len = 0;
  e->fullscreen = 0;
  e->fs_style = 0;
  memset(&e->fs_prev, 0, sizeof(e->fs_prev));
  /* 建窗时就已经有树等着 → 外框在 moonui_native_window_new 里把菜单位算进去了（这里
   * refresh 量不出差、不补偿）；事后才装的那一支由 apply 现量现补。 */
  moonui_native_menu_refresh(e, 0); /* 建窗登记：外框已把菜单位算进去了，不补 */
}

static void moonui_native_menu_unregister(HWND hwnd) {
  MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
  if (e == 0) {
    return;
  }
  if (e->bar != 0) {
    SetMenu(hwnd, 0);
    DestroyMenu(e->bar);
  }
  e->hwnd = 0;
  e->bar = 0;
  e->menu_pad = 0;
  e->fullscreen = 0;
  e->fs_style = 0;
  free(e->focus_chain);
  e->focus_chain = 0;
  e->focus_chain_len = 0;
}

static void moonui_native_menu_drop_closure(void) {
  if (moonui_native_menu_closure != 0) {
    moonbit_decref(moonui_native_menu_closure);
    moonui_native_menu_closure = 0;
  }
  moonui_native_menu_fn = 0;
}

static void moonui_native_menu_clear_all(void) {
  int i;
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_native_win_menu[i].hwnd != 0) {
      moonui_native_menu_unregister(moonui_native_win_menu[i].hwnd);
    }
  }
  free(moonui_native_menu_tree);
  moonui_native_menu_tree = 0;
  moonui_native_menu_tree_len = 0;
  moonui_native_menu_top_count = 0;
  moonui_native_menu_drop_closure();
}

/* ---- 两条对外入口 ---- */

int moonui_native_set_menu_bar(const char *tree,
                        int tree_len,
                        moonui_closure_id_fn fn,
                        void *closure) {
  MoonuiTree t;
  HMENU probe;
  char *copy;
  int i;
  TRACE("set_menu_bar");
  if (!moonui_native_inited) {
    return -2;
  }
  /* 最短的合法树是 version(1 字节) + count(i32)，空的也行：那就是"把菜单拆掉"。 */
  if (tree == 0 || tree_len < 5) {
    return -1;
  }
  /* 先照布局试建一棵，只为验证读得动（每窗口那一棵在下面按副本现建）。试建不过就原样
   * 退回：旧的菜单、旧的那份树、旧的回调都一动不动（adapter.h 的"装了一半比装不上难
   * 查"）。这条 -1 从 MoonBit 走不到——序列化器每次都产一棵合法的树，所以它是给
   * "布局和 adapter.h 对不上"这种我们自己的 bug 留的。 */
  moonui_native_tree_init(&t, tree, tree_len);
  probe = moonui_native_menu_build(&t);
  if (probe == 0 || t.bad) {
    if (probe != 0) {
      DestroyMenu(probe);
    }
    return -1;
  }
  copy = (char *)malloc((size_t)tree_len);
  if (copy == 0) {
    DestroyMenu(probe);
    return -1;
  }
  memcpy(copy, tree, (size_t)tree_len);
  free(moonui_native_menu_tree);
  moonui_native_menu_tree = copy;
  moonui_native_menu_tree_len = tree_len;
  moonui_native_menu_top_count = GetMenuItemCount(probe);
  DestroyMenu(probe);
  moonui_native_menu_drop_closure();
  moonui_native_menu_fn = fn;
  if (closure != 0) {
    moonbit_incref(closure);
    moonui_native_menu_closure = closure;
  }
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_native_win_menu[i].hwnd != 0) {
      moonui_native_menu_refresh(&moonui_native_win_menu[i], 1); /* 换树：客户区被吃掉的那一行要还 */
    }
  }
  return 0;
}

/* ---- 应用图标（§26）----
 *
 * mac 那一份只喂 NSApp 就完了；Win32 没有"进程级图标"这个概念，任务栏/Dock 取的
 * 是窗口的 ICON_BIG/ICON_SMALL。所以这里的形状是"全局存一份 HICON + 当场推给
 * 每只活窗口 + 之后新建的窗口在建窗时补挂"（moonui_native_window_new 里 register 之后
 * 那一行）。窗口登记表复用菜单那张（每只窗口 register/unregister 各一次），不
 * 另开活窗口表——那份账 HandleTable 已经有了。
 *
 * 参数是不带扩展名的 stem（adapter.h）：LoadImageW 只认 .ico，所以这里补 ".ico"
 * （LR_LOADFROMFILE 不做 PNG 转换）；PNG 那一份留给 mac。两个尺寸都从 ICO 里
 * 取：ICON_BIG 用 SM_CXICON（标题栏/Alt-Tab），ICON_SMALL 用 SM_CXSMICON
 * （标题栏左上角那个小的）。多次调用是允许的：旧的 HICON 先 DestroyIcon 再换，
 * 已经推下去的不追——下一次刷新时反正换新的。 */
static HICON moonui_native_app_icon_big = 0;
static HICON moonui_native_app_icon_small = 0;
static int moonui_native_app_icon_installed = 0;

static void moonui_native_icon_apply(HWND hwnd) {
  if (hwnd == 0 || moonui_native_app_icon_big == 0) {
    return;
  }
  SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)moonui_native_app_icon_big);
  SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)moonui_native_app_icon_small);
}

int moonui_native_set_app_icon(const char *name, int name_len) {
  LPWSTR stem;
  size_t n;
  LPWSTR path;
  HICON icon_big;
  HICON icon_small;
  int cx_big;
  int cx_small;
  int i;
  TRACE("set_app_icon");
  if (!moonui_native_inited) {
    return -2;
  }
  if (name == 0 || name_len <= 0) {
    return -1;
  }
  stem = moonui_native_utf16_of(name, name_len);
  if (stem == 0) {
    return -1;
  }
  n = wcslen(stem);
  path = (LPWSTR)malloc((n + 5u) * sizeof(WCHAR)); /* ".ico" + L'\0' */
  if (path == 0) {
    free(stem);
    return -1;
  }
  wcscpy(path, stem);
  wcscat(path, L".ico");
  free(stem);
  cx_big = GetSystemMetrics(SM_CXICON);
  cx_small = GetSystemMetrics(SM_CXSMICON);
  icon_big = (HICON)LoadImageW(NULL, path, IMAGE_ICON, cx_big, cx_big,
                               LR_LOADFROMFILE);
  icon_small = (HICON)LoadImageW(NULL, path, IMAGE_ICON, cx_small, cx_small,
                                 LR_LOADFROMFILE);
  free(path);
  if (icon_big == 0) {
    return -1; /* 文件读不出来：路径不对，或它不是合法的 ICO（§33 的调用方错） */
  }
  if (icon_small == 0) {
    icon_small = icon_big; /* ICO 里没有小尺寸那一格时退回大图，系统自己缩 */
  }
  if (moonui_native_app_icon_big != 0 && moonui_native_app_icon_big != icon_big) {
    DestroyIcon(moonui_native_app_icon_big);
  }
  if (moonui_native_app_icon_small != 0 && moonui_native_app_icon_small != icon_big &&
      moonui_native_app_icon_small != icon_small) {
    DestroyIcon(moonui_native_app_icon_small);
  }
  moonui_native_app_icon_big = icon_big;
  moonui_native_app_icon_small = icon_small;
  moonui_native_app_icon_installed = 1;
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_native_win_menu[i].hwnd != 0) {
      moonui_native_icon_apply(moonui_native_win_menu[i].hwnd);
    }
  }
  return 0;
}

int moonui_native_app_icon_present(void) {
  return moonui_native_app_icon_installed;
}

/* 测试探针：按标题找回那只窗口，看它的 WM_SETICON 图标是不是我们装的那只。
 * 比对的是指针相等（WM_GETICON 读回 WM_SETICON 存进去的 HICON 原值），所以
 * 类图标的兜底（moonui_native_wnd_class_name 有默认图标）不会误报——没装过
 * （moonui_native_app_icon_big 还是 0）恒返回 0，装了但没推到这只窗口（WM_GETICON 回
 * NULL 或是类图标）也是 0。moonui_native_find_window 定义在测试脚手架那一节（后面）。 */
static HWND moonui_native_find_window(const char *title, int title_len);
int moonui_native_window_icon_installed(const char *title, int title_len) {
  HWND win;
  HICON got_big;
  HICON got_small;
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  if (moonui_native_app_icon_big == 0) {
    return 0;
  }
  got_big = (HICON)SendMessageW(win, WM_GETICON, ICON_BIG, 0);
  got_small = (HICON)SendMessageW(win, WM_GETICON, ICON_SMALL, 0);
  if (got_big == moonui_native_app_icon_big ||
      (moonui_native_app_icon_small != 0 &&
       got_small == moonui_native_app_icon_small)) {
    return 1;
  }
  return 0;
}

/* 按命令 id 在这一层（含它的子菜单）里找条目，命中时带回它所在的那一层和两个位。
 * 顶层那几项是按位置挂的子菜单（MF_POPUP），所以"按 id 查"要逐顶取子句柄再往里查；
 * 分隔线的 wID 是 0，永远撞不上 0x4000 起步的那批。 */
typedef struct {
  HMENU menu;
  UINT ftype;
  UINT fstate;
} MoonuiMenuHit;

static int moonui_native_menu_find_in(HMENU menu, UINT wID, MoonuiMenuHit *out) {
  int i;
  int n = GetMenuItemCount(menu);
  for (i = 0; i < n; ++i) {
    MENUITEMINFOW mi;
    ZeroMemory(&mi, sizeof(mi));
    mi.cbSize = sizeof(mi);
    mi.fMask = MIIM_ID | MIIM_SUBMENU | MIIM_FTYPE | MIIM_STATE;
    if (GetMenuItemInfoW(menu, (UINT)i, TRUE, &mi) == 0) {
      continue;
    }
    if (mi.hSubMenu != 0) {
      if (moonui_native_menu_find_in(mi.hSubMenu, wID, out)) {
        return 1;
      }
      continue;
    }
    if (mi.wID != wID) {
      continue;
    }
    out->menu = menu;
    out->ftype = mi.fType;
    out->fstate = mi.fState;
    return 1;
  }
  return 0;
}

/* 置灰、禁用的读数：Windows 把"禁用"报在两个位上（我们写 MF_GRAYED，读回来常是
 * MF_GRAYED|MF_DISABLED），所以两个都认。 */
static int moonui_native_menu_is_grayed(UINT ftype, UINT fstate) {
  return ((ftype | fstate) & (MF_GRAYED | MF_DISABLED)) != 0;
}

/* 把勾选态推给**当下每一只**窗口挂的那棵：§25 是一棵逻辑菜单，Win32 却是逐窗口的，
 * 只推"最后开的那只"就会留下两扇窗显示不同的勾选。
 * 一条都没找到才报 -1（没装过菜单，或者装的树里没有这一项）。 */
int moonui_native_menu_item_set_checked(int id, int checked) {
  MoonuiMenuHit hit;
  MENUITEMINFOW mi;
  UINT wID;
  int i;
  int hits = 0;
  TRACE("menu_item_set_checked");
  if (id < 0 || id > 0xFFFF - MOONUI_MENU_ID_BASE) {
    return -1;
  }
  wID = (UINT)(id + MOONUI_MENU_ID_BASE);
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    HWND hwnd = moonui_native_win_menu[i].hwnd;
    HMENU bar;
    if (hwnd == 0 || !IsWindow(hwnd)) {
      continue;
    }
    bar = GetMenu(hwnd);
    if (bar == 0) {
      continue;
    }
    if (!moonui_native_menu_find_in(bar, wID, &hit)) {
      continue;
    }
    /* 状态整份重写：SetMenuItemInfo 的 fState 只认 MF_GRAYED/MF_CHECKED 这一组，把读到的
     * MF_DISABLED 原样写回去会被它当成非法值，所以禁用一律重写成 MF_GRAYED。fType 也得
     * 一起写——MFT_RADIOCHECK 是类型位，漏了它圆点就变成勾。
     * 禁用项照样改：置灰的菜单项下次启用时勾还得看得见（adapter.h）。 */
    ZeroMemory(&mi, sizeof(mi));
    mi.cbSize = sizeof(mi);
    mi.fMask = MIIM_FTYPE | MIIM_STATE;
    mi.fType = hit.ftype;
    mi.fState =
        (moonui_native_menu_is_grayed(hit.ftype, hit.fstate) ? MF_GRAYED : MF_ENABLED) |
        (checked != 0 ? MF_CHECKED : MF_UNCHECKED);
    if (SetMenuItemInfoW(hit.menu, wID, FALSE, &mi) != 0) {
      ++hits;
    }
  }
  return hits > 0 ? 0 : -1;
}

/* ---- 菜单快照（格式和"为什么两边逐字符一致"都在 adapter.h）---- */

/* 读哪一只窗口：倒着找最后一只还活着、且系统里真挂着菜单的登记窗口（测试总是用最后开
 * 的那一只）。判据用 GetMenu 而不是自己记的 e->bar——这根快照要钉的正是"真的
 * 挂上了"：只抄自己那份名单的话，SetMenu 整段删掉也照样绿。
 * 没有活窗口就什么都读不出来，报空（mac 那边主菜单是进程全局的，没有这一条）。 */
static HWND moonui_native_menu_target_window(void) {
  int i;
  for (i = MOONUI_MENU_WINDOWS - 1; i >= 0; --i) {
    HWND hwnd = moonui_native_win_menu[i].hwnd;
    if (hwnd != 0 && IsWindow(hwnd) && GetMenu(hwnd) != 0) {
      return hwnd;
    }
  }
  return 0;
}

/* dump 的文本累加器：累加的是 UTF-8，而菜单条目的文案是 UTF-16，所以每段现转现拼。
 * 分配失败只把 bad 立起来、最后报空字符串——一根读不通的快照让测试红在断言上，
 * 不许在这里编一个看起来对的条目。 */
typedef struct {
  char *p;
  int len;
  int cap;
  int bad;
} MoonuiDump;

static void moonui_native_dump_reserve(MoonuiDump *d, int need) {
  int cap;
  char *np;
  if (d->bad || d->len + need + 1 <= d->cap) {
    return;
  }
  cap = d->cap == 0 ? 256 : d->cap;
  while (d->len + need + 1 > cap) {
    cap *= 2;
  }
  np = (char *)realloc(d->p, (size_t)cap);
  if (np == 0) {
    d->bad = 1;
    return;
  }
  d->p = np;
  d->cap = cap;
}

static void moonui_native_dump_putc(MoonuiDump *d, char c) {
  moonui_native_dump_reserve(d, 1);
  if (d->bad) {
    return;
  }
  d->p[d->len++] = c;
  d->p[d->len] = '\0';
}

static void moonui_native_dump_puts(MoonuiDump *d, const char *s) {
  int n = (int)strlen(s);
  moonui_native_dump_reserve(d, n);
  if (d->bad) {
    return;
  }
  memcpy(d->p + d->len, s, (size_t)n);
  d->len += n;
  d->p[d->len] = '\0';
}

static void moonui_native_dump_putwn(MoonuiDump *d, LPCWSTR w, int n) {
  int needed;
  if (d->bad || w == 0 || n <= 0) {
    return;
  }
  needed = WideCharToMultiByte(CP_UTF8, 0, w, n, 0, 0, 0, 0);
  if (needed <= 0) {
    d->bad = 1;
    return;
  }
  moonui_native_dump_reserve(d, needed);
  if (d->bad) {
    return;
  }
  WideCharToMultiByte(CP_UTF8, 0, w, n, d->p + d->len, needed, 0, 0);
  d->len += needed;
  d->p[d->len] = '\0';
}

static void moonui_native_dump_putw(MoonuiDump *d, LPCWSTR w) {
  moonui_native_dump_putwn(d, w, w == 0 ? 0 : lstrlenW(w));
}

static void moonui_native_dump_puti(MoonuiDump *d, int v) {
  char buf[16];
  int i = 0;
  unsigned int u;
  if (v < 0) {
    moonui_native_dump_putc(d, '-');
    u = (unsigned int)(-(v + 1)) + 1u;
  } else {
    u = (unsigned int)v;
  }
  do {
    buf[i++] = (char)('0' + (int)(u % 10u));
    u /= 10u;
  } while (u != 0);
  while (i > 0) {
    moonui_native_dump_putc(d, buf[--i]);
  }
}

/* 这一段是不是四个修饰键名之一（按我们写进去的那种大小写比）。 */
static int moonui_native_dump_mod_bit(LPCWSTR s, int n) {
  static const WCHAR *names[4] = {L"Ctrl", L"Alt", L"Shift", L"Meta"};
  static const int lens[4] = {4, 3, 5, 4};
  int i;
  int j;
  for (i = 0; i < 4; ++i) {
    if (lens[i] != n) {
      continue;
    }
    j = 0;
    while (j < n && s[j] == names[i][j]) {
      ++j;
    }
    if (j == n) {
      return i;
    }
  }
  return -1;
}

/* <sc> 那一栏：把标题里 \t 之后那段拆回来（拼法见上面 moonui_native_menu_item_text）。读的是
 * 原生项自己的文案，所以它证明的是"组合真的落到了菜单项上"。没有 \t 就是 "."。
 * 功能键 mac 落不下去、这边落得下去，于是同一个 `Shortcut::new("F5")` mac 报 "."、这里
 * 报 "-F5"（adapter.h 明写的分叉，测试因此只用两边都认的组合）。
 * 单个字母收小写，和 mac 那一份对齐：那边读的是 keyEquivalent，字母本来就存着小写。 */
static void moonui_native_dump_combo(MoonuiDump *d, LPCWSTR text) {
  LPCWSTR tail = text;
  LPCWSTR key = 0;
  int mods = 0;
  int i;
  const char *letters = "CASM";
  if (text == 0) {
    moonui_native_dump_puts(d, ".");
    return;
  }
  while (*tail != L'\0' && *tail != L'\t') {
    ++tail;
  }
  if (*tail == L'\0') {
    moonui_native_dump_puts(d, ".");
    return;
  }
  ++tail;
  while (*tail != L'\0' && key == 0) {
    LPCWSTR plus = tail;
    int n;
    int bit;
    while (*plus != L'\0' && *plus != L'+') {
      ++plus;
    }
    n = (int)(plus - tail);
    bit = moonui_native_dump_mod_bit(tail, n);
    if (bit < 0) {
      /* 对不上修饰键名的那一段，连同它后面的整串就是键名（Core 的键名里没有 '+'）。 */
      key = tail;
      break;
    }
    mods |= 1 << bit;
    if (*plus == L'\0') {
      key = plus;
      break;
    }
    tail = plus + 1;
  }
  if (key == 0) {
    key = tail;
  }
  if (mods == 0) {
    moonui_native_dump_putc(d, '-');
  }
  for (i = 0; i < 4; ++i) {
    if (mods & (1 << i)) {
      moonui_native_dump_putc(d, letters[i]);
    }
  }
  if (lstrlenW(key) == 1 && key[0] >= L'A' && key[0] <= L'Z') {
    moonui_native_dump_putc(d, (char)(key[0] + (L'a' - L'A')));
  } else {
    moonui_native_dump_putw(d, key);
  }
}

static void moonui_native_dump_nodes(MoonuiDump *d, HMENU menu);

/* 一节：分隔线 "-"，子菜单 "+label{…}"，可点项
 * "#<id>:<role><check><enabled>:<label>:<sc>"。id 减回基址才是 Core 的那个编号。
 * 文案缓冲 256 个 WCHAR，超了就截断——这根文本只给人和测试读，测试里的标签远短于此；
 * 截断只会让断言红，不会让哪一项凭空消失。 */
static void moonui_native_dump_node(MoonuiDump *d, HMENU menu, int index) {
  WCHAR text[256];
  MENUITEMINFOW mi;
  int label_len;
  int role;
  if (d->bad) {
    return;
  }
  text[0] = L'\0';
  ZeroMemory(&mi, sizeof(mi));
  mi.cbSize = sizeof(mi);
  mi.fMask = MIIM_FTYPE | MIIM_ID | MIIM_SUBMENU | MIIM_DATA | MIIM_STATE |
             MIIM_STRING;
  mi.dwTypeData = text;
  mi.cch = (UINT)(sizeof(text) / sizeof(text[0]) - 1u);
  if (GetMenuItemInfoW(menu, (UINT)index, TRUE, &mi) == 0) {
    return;
  }
  if ((mi.fType & MF_SEPARATOR) != 0) {
    moonui_native_dump_puts(d, "-");
    return;
  }
  /* 子菜单只能认 hSubMenu：Win32 对 MF_POPUP 挂上去的项，读回的 fType 不带 MF_POPUP
   * 位（adapter.c 的探针实测 fType=0x0、hSubMenu 有值），按类型位判会把子菜单当成
   * 一条 id 是句柄值的普通项。 */
  if (mi.hSubMenu != 0) {
    moonui_native_dump_puts(d, "+");
    moonui_native_dump_putw(d, text);
    moonui_native_dump_puts(d, "{");
    moonui_native_dump_nodes(d, mi.hSubMenu);
    moonui_native_dump_puts(d, "}");
    return;
  }
  label_len = 0;
  while (text[label_len] != L'\0' && text[label_len] != L'\t') {
    ++label_len;
  }
  role = (int)mi.dwItemData;
  moonui_native_dump_puts(d, "#");
  moonui_native_dump_puti(d, (int)mi.wID - MOONUI_MENU_ID_BASE);
  moonui_native_dump_puts(d, ":");
  moonui_native_dump_putc(d, role == 1 ? 'c' : (role == 2 ? 'r' : 'n'));
  if (role == 0) {
    moonui_native_dump_putc(d, '.');
  } else {
    moonui_native_dump_putc(d, ((mi.fType | mi.fState) & MF_CHECKED) != 0 ? '+' : '-');
  }
  moonui_native_dump_putc(d, moonui_native_menu_is_grayed(mi.fType, mi.fState) ? 'd' : 'e');
  moonui_native_dump_puts(d, ":");
  moonui_native_dump_putwn(d, text, label_len);
  moonui_native_dump_puts(d, ":");
  moonui_native_dump_combo(d, text);
}

/* 一层里的条目，逗号相连。顶层不走这一节（顶层在快照里没有 "+" 前缀）。 */
static void moonui_native_dump_nodes(MoonuiDump *d, HMENU menu) {
  int i;
  int n;
  if (menu == 0) {
    return;
  }
  n = GetMenuItemCount(menu);
  for (i = 0; i < n; ++i) {
    if (i > 0) {
      moonui_native_dump_puts(d, ",");
    }
    moonui_native_dump_node(d, menu, i);
  }
}

/* 整棵菜单位：顶层之间用 ";" 相连，每顶 = label{条目,…}。逐顶按位置取，因为 Win32 的
 * 顶层项挂的是子菜单句柄、没有 id 可查。 */
static void moonui_native_dump_bar(MoonuiDump *d, HMENU bar) {
  int i;
  int n = GetMenuItemCount(bar);
  for (i = 0; i < n; ++i) {
    WCHAR text[256];
    MENUITEMINFOW mi;
    text[0] = L'\0';
    ZeroMemory(&mi, sizeof(mi));
    mi.cbSize = sizeof(mi);
    mi.fMask = MIIM_SUBMENU | MIIM_STRING;
    mi.dwTypeData = text;
    mi.cch = (UINT)(sizeof(text) / sizeof(text[0]) - 1u);
    if (i > 0) {
      moonui_native_dump_puts(d, ";");
    }
    if (GetMenuItemInfoW(bar, (UINT)i, TRUE, &mi) == 0) {
      continue;
    }
    moonui_native_dump_putw(d, text);
    moonui_native_dump_puts(d, "{");
    moonui_native_dump_nodes(d, mi.hSubMenu);
    moonui_native_dump_puts(d, "}");
  }
}

/* 只给测试用：把当下挂在窗口上的那棵截成一根文本（格式在 adapter.h）。读的是 GetMenu
 * 给回来的那棵，不是自己记的 e->bar——见上面 moonui_native_menu_target_window。 */
moonbit_bytes_t moonui_native_menu_dump(void) {
  MoonuiDump d;
  HWND hwnd;
  moonbit_bytes_t out;
  TRACE("menu_dump");
  d.p = 0;
  d.len = 0;
  d.cap = 0;
  d.bad = 0;
  hwnd = moonui_native_menu_target_window();
  if (hwnd == 0) {
    return moonbit_make_bytes(0, 0);
  }
  moonui_native_dump_bar(&d, GetMenu(hwnd));
  if (d.p == 0 || d.bad || d.len == 0) {
    free(d.p);
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_native_bytes_of(d.p);
  free(d.p);
  return out;
}

/* 只给测试用：等价于"用户在原生菜单里点了 id 这一项"。发的是 WM_COMMAND，进的是我们
 * 自己的顶层窗口过程——和真人从菜单里点下去之后完全同一条路，不是把 MoonBit 的回调
 * 直接调一遍。用 SendMessage 而不是 PostMessage 是因为这条的契约是"回调在本次调用里
 * 已经跑过"（adapter.h），投递的那一条要等下一次循环才醒。
 * 置灰的那一项在这里先拦下来：mac 那份 `performActionForItemAtIndex:` 自己就尊重
 * isEnabled，而这里的消息绕过置灰，不拦就成了"什么也没发生但报 0"。 */
int moonui_native_menu_click_item(int id) {
  MoonuiMenuHit hit;
  HWND hwnd;
  UINT wID;
  TRACE("menu_click_item");
  if (id < 0 || id > 0xFFFF - MOONUI_MENU_ID_BASE) {
    return -1;
  }
  hwnd = moonui_native_menu_target_window();
  if (hwnd == 0) {
    return -1;
  }
  wID = (UINT)(id + MOONUI_MENU_ID_BASE);
  if (!moonui_native_menu_find_in(GetMenu(hwnd), wID, &hit)) {
    return -1;
  }
  if (moonui_native_menu_is_grayed(hit.ftype, hit.fstate)) {
    return -2;
  }
  /* lParam=0（不是控件）+ HIWORD(wParam)=0（不是通知码）——和菜单自己发上来的那条
   * 一模一样，于是回调在本次调用里就跑了。 */
  SendMessageW(hwnd, WM_COMMAND, (WPARAM)wID, 0);
  return 0;
}

/* ---- 键盘与焦点（§32 / §48-16，T39）----
 * 从 adapter.c 逐段搬过来。本后端和 libui 那侧的差别只有一处：控件就是原生窗口
 * 本身（分叉清单第 1 条），没有 libui 那层中间窗口，"往上退找 owner"的循环因此
 * 退得更短，代码一行不用改。词表、修饰键自计、Tab 接管、快照读回的契约全在
 * adapter.h，两份 C 给的是同一套字符串。 */

/* 词表在 adapter.h 的键盘那一节，两份 C 必须给同一套字符串。这张表只列"名字不等于
 * 字符自己"的那些键：字母和数字直接由 VK 码得出（Windows 的 VK_A..VK_Z、VK_0..VK_9
 * 和 ASCII 同值），空格单独一个名字。mac 那份同样位置写的是 NSFunctionKey 那批码元，
 * 两边共用的只有名字这一列。Insert 只有 Windows 的键盘真有，mac 那张表里没有它。 */
typedef struct {
  const char *name;
  WORD code;
} MoonuiSpecialKey;

static const MoonuiSpecialKey moonui_native_special_keys[] = {
    {"Enter", VK_RETURN},     {"Tab", VK_TAB},
    {"Escape", VK_ESCAPE},    {"Backspace", VK_BACK},
    {"Delete", VK_DELETE},    {"Home", VK_HOME},
    {"End", VK_END},          {"PageUp", VK_PRIOR},
    {"PageDown", VK_NEXT},    {"Left", VK_LEFT},
    {"Right", VK_RIGHT},      {"Down", VK_DOWN},
    {"Up", VK_UP},            {"Insert", VK_INSERT},
    {"F1", VK_F1},            {"F2", VK_F2},
    {"F3", VK_F3},            {"F4", VK_F4},
    {"F5", VK_F5},            {"F6", VK_F6},
    {"F7", VK_F7},            {"F8", VK_F8},
    {"F9", VK_F9},            {"F10", VK_F10},
    {"F11", VK_F11},          {"F12", VK_F12},
};

#define MOONUI_N(a) (sizeof(a) / sizeof((a)[0]))

/* 那一份钩子。WH_GETMESSAGE 而不是 WH_KEYBOARD：WH_KEYBOARD 只在系统把硬件输入转成
 * 消息的那一刻响，脚手架 PostMessage 出来的那条它听不见，键盘这一半就只剩真硬件能跑；
 * WH_GETMESSAGE 挂在"取消息"这一步，真按键和合成的那条进的是同一道门（adapter.h 的
 * 那条脚手架说的就是这条门）。
 * 最后一个参数是本线程：全局钩子要把 DLL 注入别人的进程，那是拿别人的键盘。
 * hMod 给 0——文档写明钩子过程在本进程、目标线程也是本进程时应当这样，传模块句柄反而
 * 意味着那个模块得能被映射进去。 */
static HHOOK moonui_native_key_hook = 0;

/* 进程级那一份槽位。owner 用自己的地址当哨兵：全进程唯一，永远不会和某个
 * moonui_ptr（在这儿就是 HWND）撞上（和 mac 那份同一个写法）。 */
static char moonui_native_key_slot_owner;
static int moonui_native_key_slot = -1;

/* 一颗键的快照：钩子只说"有颗键出事了"，内容全部由 MoonBit 当场读回去（§48-16）。
 * 写它的时机在调闭包之前，闭包返回之后没人再动，所以一次通知配一次读、中间插不进第二颗
 * 键。target 为 0 表示这颗键不属于我们任何窗口/控件。 */
static moonui_ptr moonui_native_key_target_ptr = 0;
static int moonui_native_key_down = 0;
static int moonui_native_key_mods = 0;
static char moonui_native_key_snapshot_name[32];

/* 修饰键位（bit0 ctrl、bit1 alt、bit2 shift、bit3 meta，和 §25 那棵树里组合那一栏同一个
 * 编码）。mac 从事件自己的 modifierFlags 现读；Windows 的 WM_KEYDOWN 没带 ctrl/shift
 * （lParam 里只有 bit29 那一位 Alt 上下文），而 GetKeyState 归的是"当前前台那套键盘"
 * 的账——测试进程没有前台，用它读出来的组合跟着激活时序漂。所以这里自己跟：系统给修饰键
 * 按下/抬起同样投一条 WM_KEYDOWN/WM_KEYUP 到有焦点的窗口，把这几颗数出来就是这颗键发生
 * 当下的组合。 */
static int moonui_native_mod_count[4] = {0, 0, 0, 0};

static const WORD moonui_native_mod_vk[4] = {VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN};

/* 这颗 VK 是修饰键吗？是的话归到哪一位（左右两只物理键共享一位：mac 的
 * modifierFlags 也只给一位）。 */
static int moonui_native_mod_slot_of(WPARAM vk) {
  switch (vk) {
    case VK_CONTROL:
    case VK_LCONTROL:
    case VK_RCONTROL:
      return 0;
    case VK_MENU:
    case VK_LMENU:
    case VK_RMENU:
      return 1;
    case VK_SHIFT:
    case VK_LSHIFT:
    case VK_RSHIFT:
      return 2;
    case VK_LWIN:
    case VK_RWIN:
      return 3;
    default:
      return -1;
  }
}

static void moonui_native_mod_update(WPARAM vk, int down) {
  int i = moonui_native_mod_slot_of(vk);
  if (i < 0) {
    return;
  }
  if (down) {
    if (moonui_native_mod_count[i] < 4) {
      ++moonui_native_mod_count[i];
    }
  } else if (moonui_native_mod_count[i] > 0) {
    --moonui_native_mod_count[i];
  }
}

/* 按着左 Shift 再松开右 Shift 不该把 shift 那位清掉，所以数的是"这一组里还有几颗按着"。
 * 上界 4 挡的是"两条抬起夹着一条按下"这种不该发生的序列：宁可少算也不许算出负数。 */
static int moonui_native_mods_of_state(void) {
  int mods = 0;
  int i;
  for (i = 0; i < 4; ++i) {
    if (moonui_native_mod_count[i] > 0) {
      mods |= (1 << i);
    }
  }
  return mods;
}

static void moonui_native_mod_reset(void) {
  int i;
  for (i = 0; i < 4; ++i) {
    moonui_native_mod_count[i] = 0;
  }
}

static const MoonuiSpecialKey *moonui_native_key_row_of_code(WORD code) {
  size_t i;
  for (i = 0; i < MOONUI_N(moonui_native_special_keys); ++i) {
    if (moonui_native_special_keys[i].code == code) {
      return &moonui_native_special_keys[i];
    }
  }
  return 0;
}

/* 把这颗键的名字写进 out（最长 "Backspace"，缓冲 32 绰绰有余）。词表以外留空串，
 * MoonBit 据此丢掉这颗键——宁可不产事件，也不产一个 Core 匹配不到的名字。修饰键自己不
 * 在词表里，所以按 Ctrl 本身不产事件，只改上面那四位。 */
static void moonui_native_key_read_name(WPARAM vk, char *out) {
  const MoonuiSpecialKey *row;
  out[0] = '\0';
  /* 字母 VK 两档大小写都收：真键盘投上来的本来就是 0x41-0x5A，脚手架那条 lookup
   * 折成小写（0x61-0x7A）。名字统一吐小写——Core 的词表是小写（真跑实测：只认大写
   * 区间时脚手架的字母键全部落进空名，事件被整颗丢掉）。 */
  if ((vk >= 'A' && vk <= 'Z') || (vk >= 'a' && vk <= 'z') ||
      (vk >= '0' && vk <= '9')) {
    out[0] = (char)tolower((int)(unsigned char)vk);
    out[1] = '\0';
    return;
  }
  if (vk == VK_SPACE) {
    strcpy(out, "Space");
    return;
  }
  row = moonui_native_key_row_of_code((WORD)vk);
  if (row != 0) {
    strcpy(out, row->name);
  }
}

/* 词表里的名字 → VK，只给合成脚手架用。0 = 不在词表里，脚手架据此报 -4，绝不"随便按
 * 一颗"——按错键的测试是一条假绿。单字符名一律折成小写，所以调用方写 "S" 和 "s" 是
 * 同一颗键。 */
static int moonui_native_key_lookup(const char *name, WORD *vk_out) {
  size_t i;
  char c;
  if (name == 0 || name[0] == '\0') {
    return 0;
  }
  if (name[1] == '\0') {
    c = (char)tolower((int)(unsigned char)name[0]);
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == ' ') {
      *vk_out = (c == ' ') ? VK_SPACE : (WORD)c;
      return 1;
    }
    return 0;
  }
  for (i = 0; i < MOONUI_N(moonui_native_special_keys); ++i) {
    if (strcmp(moonui_native_special_keys[i].name, name) == 0) {
      *vk_out = moonui_native_special_keys[i].code;
      return 1;
    }
  }
  return 0;
}

/* 本线程当下"焦点在谁身上"。GetFocus 只认调用线程的输入队列，而 MoonBit 的 FFI 调用
 * 和消息循环跑在同一个线程上，所以这里问得到自己那次 SetFocus 的结果；进程不在前台时
 * GetFocus 也可能给 0（键盘焦点归前台那个线程），同一线程的 GUITHREADINFO 还留着记录，
 * 于是两条都问一遍。哪一条在这台机器上真给得出数，由 Windows 那边量（T46）。 */
static HWND moonui_native_thread_focus(void) {
  GUITHREADINFO gi;
  HWND f = GetFocus();
  if (f != 0) {
    return f;
  }
  memset(&gi, 0, sizeof(gi));
  gi.cbSize = sizeof(gi);
  if (GetGUIThreadInfo(GetCurrentThreadId(), &gi)) {
    return gi.hwndFocus;
  }
  return 0;
}

/* 这只窗口当下把焦点给了哪个"我们的控件"，没有就报 0（adapter.h 那条声明只认控件；
 * 窗口级那一档归 KeyDown 的归属判断管，所以这里到 root 之前就要收口）。 */
static moonui_ptr moonui_native_focus_owner_of(HWND root) {
  HWND f = moonui_native_thread_focus();
  HWND cur;
  moonui_ptr owner;
  if (root == 0 || f == 0 || f == root ||
      GetAncestor(f, GA_ROOT) != root) {
    return 0;
  }
  for (cur = f; cur != 0 && cur != root; cur = GetParent(cur)) {
    owner = moonui_native_owner_of(cur);
    if (owner != 0) {
      return owner;
    }
  }
  return 0;
}

/* 这颗键该算给谁：消息自己的 hwnd 往上退，第一个打过标记的。焦点在我们控件上时是那个
 * 控件，否则算这只窗口自己（焦点在窗口身上就算"键给了这只窗口"）；连窗口都不是我们的
 * （例如别的进程的键）报 0，MoonBit 据此丢弃事件。 */
static moonui_ptr moonui_native_key_owner_of_msg(MSG *m) {
  HWND cur;
  moonui_ptr owner;
  for (cur = m->hwnd; cur != 0; cur = GetParent(cur)) {
    owner = moonui_native_owner_of(cur);
    if (owner != 0) {
      return owner;
    }
  }
  return 0;
}

/* owner 指针 → 它在这只窗口里的 HWND。Core 推下来的焦点链只有 owner 指针，SetFocus
 * 要的是另一头，只能反查。EnumChildWindows 会下到整棵后代树（我们自己的容器类——
 * 单选那一组——也拦不住它）。 */
typedef struct {
  moonui_ptr want;
  HWND found;
} MoonuiOwnerSearch;

static BOOL CALLBACK moonui_native_owner_search_cb(HWND hwnd, LPARAM lp) {
  MoonuiOwnerSearch *s = (MoonuiOwnerSearch *)lp;
  if (moonui_native_owner_of(hwnd) == s->want) {
    s->found = hwnd;
    return FALSE;
  }
  return TRUE;
}

static HWND moonui_native_hwnd_of_owner(HWND root, moonui_ptr want) {
  MoonuiOwnerSearch s;
  if (root == 0 || want == 0) {
    return 0;
  }
  s.want = want;
  s.found = 0;
  EnumChildWindows(root, moonui_native_owner_search_cb, (LPARAM)&s);
  return s.found;
}

/* Tab 遍历接管（`T66`，§48-16 的 T29 第二格）：Core 声明过焦点链的窗口，Tab 不再
 * 交给默认处理按 z-order 走，改按链走。链是 collect_native 的先序——含 Stack 的树
 * 里它和视觉层叠（paint_order，倒序提过）分道，这正是要接管的原因。
 * 事件照发：钩子先按原样把 KeyDown/KeyUp 报给 Core（归属是按下那一刻的持有者），
 * 这一步只动"原生焦点落到谁"，不改 Core 看到的事件流。Shift 反向；当下持有者不在
 * 链里（焦点在窗口自己、或链刚换过）时，正向从链头、反向从链尾起。
 * 只拦 WM_KEYDOWN：WM_SYSKEYDOWN 的 Tab 是 Alt 上下文，那是系统的快捷键面，不归我们。
 * 挪了焦点就把消息改写成 WM_NULL——默认处理再取到它时就是空消息，多行输入框不会
 * 因此吃进一个制表符。挪不动（找不到 HWND）就原样放行，走默认。 */
static void moonui_native_tab_advance(MSG *m) {
  HWND root;
  MoonuiWindowMenu *e;
  moonui_ptr cur;
  int n;
  int idx;
  int next;
  HWND target;
  if (m->hwnd == 0) {
    return;
  }
  root = GetAncestor(m->hwnd, GA_ROOT);
  if (root == 0) {
    return;
  }
  e = moonui_native_menu_entry_of(root);
  if (e == 0 || e->focus_chain_len <= 0) {
    return;
  }
  n = e->focus_chain_len;
  cur = moonui_native_focus_owner_of(root);
  idx = -1;
  {
    int i;
    for (i = 0; i < n; ++i) {
      if (e->focus_chain[i] == cur) {
        idx = i;
        break;
      }
    }
  }
  /* shift 用自计的状态机而不是 GetKeyState：PostMessage 投下来的合成键在
   * GetKeyState 那里根本不存在（键事件那节的注释说的就是这颗雷），真实按键
   * 两条路都通——Tab 取出来那一刻 shift 的按下早已从队列里过了一遍。 */
  if ((moonui_native_mods_of_state() & (1 << 2)) != 0) {
    next = idx < 0 ? n - 1 : (idx - 1 + n) % n;
  } else {
    next = idx < 0 ? 0 : (idx + 1) % n;
  }
  target = moonui_native_hwnd_of_owner(root, e->focus_chain[next]);
  if (target == 0) {
    return;
  }
  SetFocus(target);
  m->message = WM_NULL;
  m->wParam = 0;
  m->lParam = 0;
}

static LRESULT CALLBACK moonui_native_key_hook_proc(int code, WPARAM wParam,
                                             LPARAM lParam) {
  MSG *m;
  int down;
  moonui_ptr target;
  if (code >= 0 && wParam == TRUE) {
    /* wParam 是"这条消息是不是正被取走"：moonui_native_messages_pending 用 PM_NOREMOVE 探测，
     * 钩子在那一次也会响，不筛就把同一颗键数了两遍。 */
    m = (MSG *)lParam;
    down = -1;
    switch (m->message) {
      case WM_KEYDOWN:
      case WM_SYSKEYDOWN:
        down = 1;
        break;
      case WM_KEYUP:
      case WM_SYSKEYUP:
        down = 0;
        break;
      default:
        break;
    }
    if (down >= 0) {
      moonui_native_mod_update(m->wParam, down);
      if (moonui_native_key_slot >= 0) {
        target = moonui_native_key_owner_of_msg(m);
        if (target != 0) {
          moonui_native_key_target_ptr = target;
          moonui_native_key_down = down;
          moonui_native_key_mods = moonui_native_mods_of_state();
          moonui_native_key_read_name(m->wParam, moonui_native_key_snapshot_name);
          moonui_native_fire(&moonui_native_slots[moonui_native_key_slot]);
        }
      }
      /* Tab 的焦点挪动在事件发完之后做：Core 看到的归属是按下那一刻的持有者，
       * 原生焦点才按链挪（T66）。 */
      if (down == 1 && m->message == WM_KEYDOWN && m->wParam == VK_TAB) {
        moonui_native_tab_advance(m);
      }
    }
  }
  return CallNextHookEx(moonui_native_key_hook, code, wParam, lParam);
}

int moonui_native_on_key(moonui_closure_fn fn, void *closure) {
  int slot;
  TRACE("on_key");
  slot = moonui_native_take_slot((void *)&moonui_native_key_slot_owner, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_key_slot = slot;
  /* 监听整个进程只挂一份：重复调用到这里就换掉了槽位里的闭包，钩子原样留着。 */
  if (moonui_native_key_hook != 0) {
    return 0;
  }
  moonui_native_key_hook = SetWindowsHookExW(WH_GETMESSAGE, moonui_native_key_hook_proc, 0,
                                      GetCurrentThreadId());
  /* 装不上就把刚占的槽位还掉，让 MoonBit 侧报成显式错误而不是"监听永远不会响"。 */
  if (moonui_native_key_hook == 0) {
    moonui_native_forget((void *)&moonui_native_key_slot_owner, fn);
    moonui_native_key_slot = -1;
    return -1;
  }
  return 0;
}

/* terminate 的第一件事（见文件顶上的前置声明）。摘掉之后再没有回调会跑，槽位才可以
 * 排干。 */
static void moonui_native_key_drop_hook(void) {
  if (moonui_native_key_hook != 0) {
    UnhookWindowsHookEx(moonui_native_key_hook);
    moonui_native_key_hook = 0;
  }
  moonui_native_key_slot = -1;
  moonui_native_mod_reset();
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

/* Core 声明的焦点链（`T29` 的第二格，`T66` 在 Windows 接上）：ids 是空格分隔的
 * 十进制 owner 指针——MoonBit 的 FFI 过不来数组，序列化成文本（菜单树同一招）。
 * 每次推的是整份，直接替换；空串 = 清空（这只窗口的 Tab 回到默认 z-order 序）。
 * 返回 0 = 收下，-1 = 窗口不在登记表里，-3 = 文本解析失败。 */
int moonui_native_set_focus_chain(moonui_ptr window, const char *ids, int ids_len) {
  HWND root;
  MoonuiWindowMenu *e;
  moonui_ptr *chain = 0;
  int len = 0;
  int i;
  const char *p = ids;
  const char *end = ids + ids_len;
  char *stop;
  TRACE("set_focus_chain");
  root = moonui_native_hwnd(window);
  if (root == 0) {
    return -1;
  }
  e = moonui_native_menu_entry_of(root);
  if (e == 0) {
    return -1;
  }
  /* 两遍走：先数 token 数（每片至少 1 个字符，上界就是 ids_len），再照原样填。
   * strtoull 前进的位数就是 stop - p，0 表示一个数都没啃下来，那就是坏编码。 */
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
    /* 数值本身这一遍不消费（真正的解析在第二遍），只看 stop 前进了多少；压掉
     * -Wunused-but-set-variable，而不是把赋值删掉——留着它，读的人一眼看出这条
     * strtoull 同时承担"探多远"。 */
    (void)v;
    ++len;
    p = stop;
  }
  if (len > 0) {
    chain = (moonui_ptr *)malloc(sizeof(moonui_ptr) * (size_t)len);
    if (chain == 0) {
      return -3;
    }
    p = ids;
    for (i = 0; i < len; ++i) {
      while (*p == ' ' || *p == '\t') {
        ++p;
      }
      chain[i] = (moonui_ptr)strtoull(p, &stop, 10);
      p = stop;
    }
  }
  free(e->focus_chain);
  e->focus_chain = chain;
  e->focus_chain_len = len;
  return 0;
}

moonui_ptr moonui_native_focused_control(moonui_ptr w) {
  TRACE("focused_control");
  return moonui_native_focus_owner_of(moonui_native_hwnd(w));
}

/* ---- 鼠标与滚动（§10 的 MouseDown / MouseUp / MouseMove / Scroll / DoubleClick，
 * §48-17 的 `T39`）----
 *
 * 契约、kind/button 的编码、pos 与 delta 两个口径、两侧的平台差别都写在
 * adapter.h 那一段；这里只记 Windows 这一份的实现理由，逐段从 adapter.c 搬过来
 * （命中反查、坐标换算、滚轮三步换算在那边都过了真窗口测试）。
 *   1. 这是第二份 WH_GETMESSAGE 钩子，和键盘那一条分开挂。分开不是因为"Win32 只让挂
 *      一条"（同一条钩子里再多认一组鼠标消息完全可行），是两份快照、两个槽位、两次
 *      摘钩各自独立：键盘那一条还管着修饰键计数和 Tab 接管，鼠标这一档两样都没有，
 *      搅在一块儿之后每次改动都得重读另一档的规则。钩子是进程启动时装一次、terminate
 *      时摘一次，多那一发的开销看不见。
 *   2. 命中靠坐标反查，不给每只控件子类化收 WM_MOUSEMOVE：这就是 `T39` 挂账时预言的
 *      "鼠标按控件数乘槽位"没有发生的原因，槽位表因此还是 96 格。
 *   3. target 只认我们的控件，往上退到根窗口为止，落在空白处整条丢掉。和键盘那条的
 *      关键差别：moonui_native_key_owner_of_msg 允许把键算到窗口自己头上（焦点可以在窗口上），
 *      这一条不许——Core 现在没有任何一处消费落在空白处的鼠标事件（§32 的 focused
 *      改由点击驱动是 `T41`），而窗口和控件的 id 在同一个空间里，猜一条就等于往那张表
 *      里塞一个没人要的收件人。
 *   4. 抬起这一档 Windows 报得出、mac 报不出：钩子挂在"消息离开队列"那一步，控件自己
 *      的鼠标捕获（SetCapture 之后那一串 WM_MOUSEMOVE / WM_LBUTTONUP）也照样经过它，
 *      所以按下和抬起两条都进 Core。mac 的本地监听会被控件自己的 tracking loop 绕过，
 *      同一发落在会自跑的控件上就只剩按下（adapter_macos.m 本节第 4 条是本机实测）。
 *      这条差别和 ⌘Q 一样是平台自己的，各侧的测试按各侧的真值断言。
 *   5. 没按住键的纯光标移动在 Windows 也是一条 WM_MOUSEMOVE，所以这一档比 mac 多事件
 *      （mac 要窗口 acceptsMouseMovedEvents = YES）。WM_MOUSEMOVE 的"按住哪颗"只能
 *      从 MK_* 那组标志读，没人拖着时它们是空的、读回 0，而 0 正好是
 *      Left——"没人拖着"和"左键拖着"在这边是同一个数（mac 由事件类型自己说，分得开）。
 *      撞不上任何人：Core 的 Event::MouseMove 没有键这一栏，所以两边都不许在这里补断言。
 */

/* SPI_GETWHEELSCROLLCHARS（横向滚轮一行走几个字符）是 Win8 才进 SDK 的那条，值是
 * 0x006C。写死而不是等头文件里的宏：两台机器的头文件版本不同（MSVC 那份按
 * _WIN32_WINNT 分档，Homebrew 的 MinGW 又是另一套），少一个宏就是编译不过，而这个
 * 值从 Win8 起没动过。 */
#ifndef SPI_GETWHEELSCROLLCHARS
#define SPI_GETWHEELSCROLLCHARS 0x006C
#endif

static HHOOK moonui_native_mouse_hook = 0;

/* 进程级那一份槽位与一份快照，形状和键盘那六条一模一样：钩子只说"这儿有动作"，
 * 内容全部由 MoonBit 当场读回，写快照的时机在调闭包之前，所以一次通知配一次读。 */
static char moonui_native_mouse_slot_owner;
static int moonui_native_mouse_slot = -1;

static moonui_ptr moonui_native_mouse_target_ptr = 0;
static int moonui_native_mouse_code = 0;
static int moonui_native_mouse_px = 0;
static int moonui_native_mouse_py = 0;
static int moonui_native_mouse_ldx = 0;
static int moonui_native_mouse_ldy = 0;

/* 消息的 lParam 装的是两个 SHORT，而 LOWORD/HIWORD 给的是 WORD（无符号）。子窗口的
 * 客户区坐标可以是负的（控件摆在父窗口原点之上或之左），不折回 SHORT 就是一个几万的
 * 正数。windowsx.h 的 GET_X_LPARAM / GET_Y_LPARAM 就是这两行，不为它多一个包含。 */
static int moonui_native_lx_of(LPARAM p) { return (int)(SHORT)LOWORD(p); }
static int moonui_native_ly_of(LPARAM p) { return (int)(SHORT)HIWORD(p); }

/* 消息 → kind（0 按下 1 抬起 2 移动或拖拽 3 双击 4 滚轮），认不出来回 -1，钩子据此
 * 把这条消息当别人的事。第二次按下只产 kind 3、不再产一条按下：
 * WM_LBUTTONDBLCLK 本来就取代了第二颗 WM_LBUTTONDOWN（系统只在带 CS_DBLCLKS 的窗口类
 * 上这么发——公共控件那批类自带这个样式，所以点在按钮上的双击有 kind 3；我们自己两类
 * 窗口的 style 是 0，落在空白处的双击不产这条，而空白处的事件反正整条丢掉），所以
 * "一条 DoubleClick 前面恰好一条 Click"在这边是原生给的形状，不是我们在 MoonBit 侧
 * 拼出来的。 */
static int moonui_native_mouse_kind_of(UINT msg) {
  switch (msg) {
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_XBUTTONDOWN:
      return 0;
    case WM_LBUTTONUP:
    case WM_RBUTTONUP:
    case WM_MBUTTONUP:
    case WM_XBUTTONUP:
      return 1;
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDBLCLK:
    case WM_MBUTTONDBLCLK:
    case WM_XBUTTONDBLCLK:
      return 3;
    case WM_MOUSEMOVE:
      return 2;
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
      return 4;
    default:
      return -1;
  }
}

/* 消息 → Core 的 MouseButton 的序号（0 Left … 4 Extra2），和
 * packages/moonui/event.mbt 里那个声明的顺序一字不差（adapter.h 定的编码）。
 * 两个 wParam 字段别弄混：滚轮的格数在 HIWORD，而 WM_XBUTTON* 的那颗侧键在 LOWORD
 * ——文档各写各的，网上抄的代码里两种都有，读错的那一种在这里是"侧键永远算成 Extra1"。
 * WM_MOUSEMOVE 要从 MK_* 那组标志读，见上面本节第 5 条；滚轮恒 0（Core 的 Scroll
 * 没有键这一栏）。 */
static int moonui_native_mouse_button_of(UINT msg, WPARAM wParam) {
  switch (msg) {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      return 0;
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_RBUTTONDBLCLK:
      return 1;
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_MBUTTONDBLCLK:
      return 2;
    case WM_XBUTTONDOWN:
    case WM_XBUTTONUP:
    case WM_XBUTTONDBLCLK:
      return (LOWORD(wParam) == XBUTTON2) ? 4 : 3;
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
      return 0;
    case WM_MOUSEMOVE:
      if ((wParam & MK_LBUTTON) != 0) {
        return 0;
      }
      if ((wParam & MK_RBUTTON) != 0) {
        return 1;
      }
      if ((wParam & MK_MBUTTON) != 0) {
        return 2;
      }
      if ((wParam & MK_XBUTTON1) != 0) {
        return 3;
      }
      if ((wParam & MK_XBUTTON2) != 0) {
        return 4;
      }
      return 0;
    default:
      return -1;
  }
}

/* 一行文字多高（物理像素）。Windows 的滚轮给的是 WHEEL_DELTA 的格数，把格换成像素要
 * 两个数：一格走几行（下面那条 SPI），和一行多高。行高只认消息字体——
 * SPI_GETNONCLIENTMETRICS 的 lfMessageFont 就是资源对话框、菜单、提示条用的那一套字，
 * 也就是"这台机器上 Win32 界面的一行"。不用 96 除 dpi 那种自造换算（§30：Windows 的
 * 逻辑像素除的是 GetDpiForWindow，跟字体高度是两件事），也不用 SM_CYFONT（早就废弃）。
 * CreateFontIndirectW 出来的字体必须先 SelectObject 进 DC 才问得到自己的
 * GetTextMetricsW，直接对 DC 问读到的是它原来挂着的系统字体。
 * 进程级缓存一次就够：这几个读数运行期不变。缓存的值必须是正的（上面那条换算要乘它，
 * 而下面的反算要除它），所以两道兜底：消息字体拿不到退回 SM_CYMENU，再拿不到退回 16。 */
static int moonui_native_line_px(void) {
  static int cached = 0;
  /* 明确写 W 那一份：本文件不靠 UNICODE 宏（两台机器的头文件默认值不一样），而
   * NONCLIENTMETRICS 不带后缀时跟着 UNICODE 变成 A 或 W，和下面那句
   * CreateFontIndirectW 要的 LOGFONTW 就不是一回事了——MinGW 那边第一道编译就红。 */
  NONCLIENTMETRICSW ncm;
  HDC dc;
  HFONT font;
  HFONT old;
  TEXTMETRICW tm;
  if (cached > 0) {
    return cached;
  }
  memset(&ncm, 0, sizeof(ncm));
  ncm.cbSize = (DWORD)sizeof(ncm);
  if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, (DWORD)sizeof(ncm), &ncm,
                            0) != 0) {
    font = CreateFontIndirectW(&ncm.lfMessageFont);
    if (font != 0) {
      dc = GetDC(0);
      if (dc != 0) {
        old = (HFONT)SelectObject(dc, font);
        if (GetTextMetricsW(dc, &tm) != 0 && tm.tmHeight > 0) {
          cached = (int)tm.tmHeight;
        }
        SelectObject(dc, old);
        ReleaseDC(0, dc);
      }
      DeleteObject(font);
    }
  }
  if (cached <= 0) {
    cached = GetSystemMetrics(SM_CYMENU);
  }
  if (cached <= 0) {
    cached = 16;
  }
  return cached;
}

/* 物理像素 → 逻辑像素，四舍五入而不是截断（§30：Windows 除的是这只窗口的 dpi/96）。
 * 全程整数是因为这条 ABI 上两个数打包进一个 Int64、各占 32 位，给不了半个像素。
 * 先取模再补符号是为了"+ dpi/2"这一步真的落在四舍五入上：C 的除法朝零截断，
 * 负数直接加 dpi/2 会把 -79 这种数推到错误的一边。 */
static int moonui_native_px_to_logical(int phys, int dpi) {
  int mag = phys < 0 ? -phys : phys;
  int out = (int)(((int64_t)mag * 96 + (int64_t)dpi / 2) / (int64_t)dpi);
  return phys < 0 ? -out : out;
}

/* 一格滚轮走几"行"（横向那一档文档叫字符，同一个数位）。返回 -1 = 这台机器上这个数
 * 没有出处：调用失败，或者 SPI_GETWHEELSCROLLLINES 报回 -1——它的原话是"一格滚一页"，
 * 而"一页"是收件控件自己定的，乘不出一个有出处的像素数，只能让上层把整条事件丢掉。
 * 0 是有意义的（用户在设置里选了"滚动鼠标时不滚动"或者横向不走），那种机器上滚轮
 * 本来就不动，换算出来就是 0。 */
static int moonui_native_wheel_lines_of(UINT msg) {
  int lines = 0;
  if (SystemParametersInfoW(
          msg == WM_MOUSEHWHEEL ? SPI_GETWHEELSCROLLCHARS
                                : SPI_GETWHEELSCROLLLINES,
          0, &lines, 0) == 0) {
    return -1;
  }
  if (lines < 0) {
    return -1;
  }
  /* 横向问到的 Win8 之前没有这条 SPI，用户也可以只设纵向；两条都为 0 时跟着纵向走
   * 至少还是个有出处的数——横向滚动的设置和纵向不一致这种组合没人验证过，与其在这里
   * 猜一个"横向就是不走"，不如读同一次设置的另一半。 */
  if (msg == WM_MOUSEHWHEEL && lines == 0) {
    if (SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0) == 0 ||
        lines < 0) {
      return -1;
    }
  }
  return lines;
}

/* 滚轮消息 → 那两个逻辑像素。口径在 adapter.h：报给 MoonBit 的数**已经**换算完，
 * MoonBit 不许再除一次。三步都在 C 里做完，因为用的三个数只在 Windows 存在：
 *   格：(SHORT)HIWORD(wParam) / WHEEL_DELTA，一格正好是 WHEEL_DELTA(120)。不到一格的
 *     余数朝零截掉——真滚轮只给 120 的整数倍，而这条 ABI 报的是 Int，给不了半个像素。
 *   格 → 物理像素：乘上面那两条（一格几行 × 一行几像素）。
 *   物理像素 → 逻辑像素：乘 96 除以这只根窗口的 dpi，四舍五入。
 * 方向：WM_MOUSEWHEEL 的格数为正 = 滚轮往上转 = 内容往上走 = 滚动偏移减小，所以 dy
 * 取负；WM_MOUSEHWHEEL 为正 = 往右滚 = 偏移增大，dx 取正。和 adapter.h 那条
 * "正 = 往下读 / 往右读"对上。 */
static int moonui_native_wheel_delta_of(UINT msg, WPARAM wParam, int dpi, int *dx_out,
                                 int *dy_out) {
  int notches = (int)(SHORT)HIWORD(wParam) / WHEEL_DELTA;
  int lines;
  int logical;
  *dx_out = 0;
  *dy_out = 0;
  if (notches == 0) {
    return 0;
  }
  lines = moonui_native_wheel_lines_of(msg);
  if (lines < 0) {
    return -1;
  }
  logical = moonui_native_px_to_logical(notches * lines * moonui_native_line_px(), dpi);
  if (msg == WM_MOUSEWHEEL) {
    *dy_out = -logical;
  } else {
    *dx_out = logical;
  }
  return 0;
}

/* 这条鼠标消息该算给"我们的哪个控件"，根窗口从 win_out 带回去；没有就报 0。
 * 往上退而不是直接用消息自己的 hwnd：我们自己的容器（单选那一组）包着子控件时，
 * 命中的是那颗子控件，但打过 owner 标记的是容器——退到根之前找到的第一个标记才是
 * Core 要的那一只。判据用那笔反查标记而不是类名，和 moonui_native_focus_widget_in_window
 * 同一条理由。 */
static moonui_ptr moonui_native_mouse_owner_of_msg(MSG *m, HWND *win_out) {
  HWND win = GetAncestor(m->hwnd, GA_ROOT);
  HWND up;
  moonui_ptr owner;
  if (win_out != 0) {
    *win_out = win;
  }
  if (win == 0 || moonui_native_owner_of(win) == 0) {
    return 0;
  }
  for (up = m->hwnd; up != 0 && up != win; up = GetParent(up)) {
    owner = moonui_native_owner_of(up);
    if (owner != 0) {
      return owner;
    }
  }
  return 0;
}

static LRESULT CALLBACK moonui_native_mouse_hook_proc(int code, WPARAM wParam,
                                               LPARAM lParam) {
  MSG *m;
  int kind;
  int button;
  int drop;
  int ldx = 0;
  int ldy = 0;
  HWND win = 0;
  POINT pt;
  moonui_ptr target;
  if (code >= 0 && wParam == TRUE) {
    /* wParam 是"这条消息是不是正被取走"：moonui_native_messages_pending 用 PM_NOREMOVE 探测
     * 的时候钩子照样响，不筛就把同一次动作数了两遍（键盘那一条同一个理由）。 */
    m = (MSG *)lParam;
    kind = moonui_native_mouse_kind_of(m->message);
    if (kind >= 0 && moonui_native_mouse_slot >= 0) {
      button = moonui_native_mouse_button_of(m->message, m->wParam);
      if (button >= 0) {
        target = moonui_native_mouse_owner_of_msg(m, &win);
        if (target != 0) {
          pt.x = moonui_native_lx_of(m->lParam);
          pt.y = moonui_native_ly_of(m->lParam);
          /* 两种 lParam 空间：滚轮按文档给的是屏幕坐标（发给谁都是那个空间），其余
           * 几条给的是"发给谁就是谁的客户区"。两个都要换成根窗口的客户区坐标才是
           * adapter.h 说的那个 pos——和 moonui_native_widget_origin 报的、
           * moonui_native_click_button_in_window 收的是同一个空间。 */
          if (kind == 4) {
            ScreenToClient(win, &pt);
          } else {
            ClientToScreen(m->hwnd, &pt);
            ScreenToClient(win, &pt);
          }
          drop = 0;
          if (kind == 4 && moonui_native_wheel_delta_of(m->message, m->wParam,
                                                 moonui_native_dpi_of(win), &ldx,
                                                 &ldy) != 0) {
            /* 这台机器上"一格滚多少"没有出处（-1 = 一格滚一页）：整条丢掉，
             * 宁可少一条事件，也不要一条猜出来的。 */
            drop = 1;
          }
          if (!drop) {
            moonui_native_mouse_target_ptr = target;
            moonui_native_mouse_code = kind * 8 + button;
            moonui_native_mouse_px = (int)pt.x;
            moonui_native_mouse_py = (int)pt.y;
            moonui_native_mouse_ldx = ldx;
            moonui_native_mouse_ldy = ldy;
            moonui_native_fire(&moonui_native_slots[moonui_native_mouse_slot]);
          }
        }
      }
    }
  }
  return CallNextHookEx(moonui_native_mouse_hook, code, wParam, lParam);
}

int moonui_native_on_mouse(moonui_closure_fn fn, void *closure) {
  int slot;
  TRACE("on_mouse");
  slot = moonui_native_take_slot((void *)&moonui_native_mouse_slot_owner, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_mouse_slot = slot;
  /* 监听整个进程只挂一份：重复调用到这里就换掉了槽位里的闭包，钩子原样留着。 */
  if (moonui_native_mouse_hook != 0) {
    return 0;
  }
  moonui_native_mouse_hook = SetWindowsHookExW(WH_GETMESSAGE, moonui_native_mouse_hook_proc, 0,
                                        GetCurrentThreadId());
  /* 装不上就把刚占的槽位还掉，让 MoonBit 侧报成显式错误而不是"监听永远不会响"。 */
  if (moonui_native_mouse_hook == 0) {
    moonui_native_forget((void *)&moonui_native_mouse_slot_owner, fn);
    moonui_native_mouse_slot = -1;
    return -1;
  }
  return 0;
}

/* terminate 的第一批事之一（见文件顶上的前置声明）。摘掉之后再没有回调会跑，
 * 槽位才可以排干。 */
static void moonui_native_mouse_drop_hook(void) {
  if (moonui_native_mouse_hook != 0) {
    UnhookWindowsHookEx(moonui_native_mouse_hook);
    moonui_native_mouse_hook = 0;
  }
  moonui_native_mouse_slot = -1;
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

/* ---- 事件循环 ----
 *
 * 和 libui 那侧不一样的地方：这里没有 uiMainStep 可转，而共享的 backend.mbt 对
 * "原生后端"的期待是从 mac 原生那份定下的（§51）：quit 只立标志，main_step 每次泵
 * 一条消息、只有 loop_ended 之后才报 0。adapter.c 那边"main_step 处理一条就返回 1"
 * 的语义对 MoonBit 侧不可见——它只看返回 0 与否（分叉清单第 7 条）。 */

void moonui_native_main_steps(void) {
  /* 直写 Win32 没有"批处理模式"这档事：保留这个入口只为同一份 adapter.h 契约，
   * MoonBit 侧调了等于没调。 */
  TRACE("main_steps");
}

int moonui_native_main_step(int wait) {
  MSG msg;
  TRACE("main_step");
  /* wait 忽略：mac 原生那份的 main_step 也没有阻塞档，MoonBit 侧的等待全靠
   * moonui_native_wait_messages 先熬，然后进来泵。 */
  (void)wait;
  if (moonui_native_loop_ended) {
    return 0;
  }
  /* 泵一条就走：PeekMessage 的 HWND 给 0 是"本线程整队"——park、对话框、钩子改写过的
   * 那些消息全都要过这道门。分派用的还是 TranslateMessage/DispatchMessageW 那一
   * 对标准动作，键盘翻译（WM_CHAR）在这步里完成。 */
  if (PeekMessageW(&msg, 0, 0, 0, PM_REMOVE) != 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  return moonui_native_loop_ended ? 0 : 1;
}

/* PM_NOREMOVE 只探测不取，所以问完还能让 moonui_native_main_step 去处理那条。
 * 队列里有 WM_QUIT 之类的杂消息也不影响：本循环不用 WM_QUIT 判终止（loop_ended
 * 才是判据），PeekMessage 只看"有没有东西"。 */
int moonui_native_messages_pending(void) {
  MSG msg;
  TRACE("messages_pending");
  return PeekMessageW(&msg, 0, 0, 0, PM_NOREMOVE) != 0;
}

/* QS_ALLINPUT 把"队列里有新消息"和"该超时了"分开，MoonBit 因此能在不卡死
 * 的前提下等到事件，而不是直接睡死。
 * 用不带 W 后缀的名字：这个 SDK 的 WinUser.h 只声明通用名，由 user32.lib
 * 提供导入项；写 `...ObjectsW` 既没有原型也链不上。
 * 这里的"新"是相对上次唤醒算的：队列里有积压时它照样报超时，所以这个返回值
 * 只能当唤醒用，判断有没有活要干得靠 moonui_native_messages_pending。 */
int moonui_native_wait_messages(int ms) {
  TRACE("wait_messages");
  return MsgWaitForMultipleObjects(0, 0, FALSE, (DWORD)ms, QS_ALLINPUT) ==
                 WAIT_TIMEOUT
             ? 0
             : 1;
}

int64_t moonui_native_time_ms(void) {
  TRACE("time_ms");
  return (int64_t)GetTickCount64();
}

void moonui_native_quit(void) {
  /* 只立标志，不 PostQuitMessage：那是给"下一圈取到 WM_QUIT 就退出"的老式循环用的，
   * 我们的 main_step 不认 WM_QUIT，投了反而把队尾垫一条别人不处理的消息。窗口的
   * 销毁归 MoonBit 侧 destroy，标志立起来之后 main_step 自然开始报 0。 */
  TRACE("quit");
  moonui_native_loop_ended = 1;
}

/* ---- 测试脚手架 ---- */

/* 标题 → 窗口标题是唯一的"按身份找回原生对象"的通道，测试够用：
 * MoonBit 侧只拿得到句柄，拿不到 HWND。 */
static HWND moonui_native_find_window(const char *title, int title_len) {
  char *t;
  WCHAR wtitle[256];
  HWND win;
  t = moonui_native_dup(title, title_len);
  if (t == 0) {
    return 0;
  }
  if (MultiByteToWideChar(CP_UTF8, 0, t, -1, wtitle, 256) == 0) {
    free(t);
    return 0;
  }
  free(t);
  win = FindWindowW(0, wtitle);
  return win;
}

/* 按坐标命中，而不是"找窗口里第一个按钮"：这样点的确实是 MoonUI 摆过去的那个
 * 矩形，布局算错的话这里就找不到控件（返回负数），不需要产品侧再开一个
 * geometry getter。ChildWindowFromPoint 命不中子窗口时返回的是父窗口自己，
 * 所以"空白处"会落到类名检查上、返回 -4。
 * BM_CLICK 让真的 BUTTON 控件自己发出 BN_CLICKED，于是消息进的是我们自己的
 * moonui_native_wndproc 的 WM_COMMAND 那一支——和鼠标点下去之后完全同一条路径，不是把
 * 回调函数直接调一遍。 */
int moonui_native_click_button_in_window(const char *title,
                                  int title_len,
                                  int x,
                                  int y) {
  WCHAR cls[64];
  HWND win;
  HWND hit;
  POINT pt;
  TRACE("click_button_in_window");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  pt.x = x;
  pt.y = y;
  hit = ChildWindowFromPoint(win, pt);
  if (hit == 0) {
    return -3;
  }
  if (GetClassNameW(hit, cls, 64) == 0 || lstrcmpiW(cls, L"button") != 0) {
    return -4;
  }
  SendMessageW(hit, BM_CLICK, 0, 0);
  return 0;
}

/* 等价于"用户在客户区 (x, y) 处那个输入框里逐字打出 text"。
 *
 * 命中测试和上面那条同一条理由：坐标命不中就说明布局没摆到 Core 以为的矩形上，
 * 摆放因此连带被验了。真正区别于"把回调调一遍"的是这两步：先把插入点放到文末，
 * 再**逐字符** SendMessage(WM_CHAR)——那是键盘消息进编辑框的正门：EDIT 自己处理
 * 字符、改内容、向父窗口发 WM_COMMAND/EN_CHANGE，我们的 moonui_native_dispatch_command
 * 再报给 MoonBit。
 * 对照组有两条，都不用：EM_REPLACESEL 一次换整段、跳过了字符处理那一层，不是
 * 键盘那条路；SetWindowText 走 moonui_native_widget_set_text，被我们自己的 inhibit 挡着，
 * 本来就不该报"用户打了字"。
 * 一个字符一条 EN_CHANGE，所以打 N 个码元来 N 条通知——真键盘本来就这样；macOS
 * 那份把整串一次 insertText:（相当于输入法成串上屏），只来一条。这条差异留在两边
 * 的测试里，MoonBit 侧读不出差别（T18 定下的形状：分叉只在 C）。
 * 返回值和 mac 那份同一套阶梯：0 已送达，-1 编码失败，-2 找不到窗口，
 * -3 命不中子窗口，-4 命中的不是编辑框，-5 命中的是只读编辑框。 */
int moonui_native_type_text_in_window(const char *title,
                               int title_len,
                               int x,
                               int y,
                               const char *text,
                               int text_len) {
  WCHAR cls[64];
  LPWSTR chars;
  HWND win;
  HWND hit;
  POINT pt;
  int len;
  int i;
  TRACE("type_text_in_window");
  chars = moonui_native_utf16_of(text, text_len);
  if (chars == 0) {
    return -1;
  }
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    free(chars);
    return -2;
  }
  pt.x = x;
  pt.y = y;
  hit = ChildWindowFromPoint(win, pt);
  if (hit == 0) {
    free(chars);
    return -3;
  }
  if (GetClassNameW(hit, cls, 64) == 0 || lstrcmpiW(cls, L"edit") != 0) {
    free(chars);
    return -4;
  }
  if ((GetWindowLongW(hit, GWL_STYLE) & ES_READONLY) != 0) {
    free(chars);
    return -5;
  }
  len = (int)GetWindowTextLengthW(hit);
  /* 光标显式放到文末：没焦点的编辑框初始选中区在 0，不摆的话新字符会插到已有
   * 文字前面。选中区存在编辑框自己身上，不需要进程拿到前台——那是 Tab 那类
   * 脚手架在这台机器上做不到的原因。 */
  SendMessageW(hit, EM_SETSEL, (WPARAM)len, (LPARAM)len);
  for (i = 0; chars[i] != L'\0'; ++i) {
    /* lParam 低 16 位是重复次数：按一次键就是 1。EN_CHANGE 在这次 SendMessage
     * 里面同步发给父窗口，所以回调在这条脚手架返回前就已经把事件放进 MoonBit
     * 队列了——和 mac 那份的时机一致。 */
    SendMessageW(hit, WM_CHAR, (WPARAM)chars[i], 1);
  }
  free(chars);
  return 0;
}

/* 等价于"用户把焦点挪到客户区 (x, y) 处那个控件上"。
 *
 * 命中测试和上面两条同一条理由：按坐标而不是"取第几只控件"，布局摆错了这里就命不中。
 * 文档写明的阶梯是：点在父窗口之外给 NULL（那才是 -3），点在客户区里但不落在任何子窗口
 * 上给的是父窗口自己（往上退那一步查不到标记，-4）；禁用和隐藏的子女窗口照样返回，所以
 * 下面那条"禁用控件"不会走到 -3 那一支上去。
 * 判据是回读而不是 SetFocus 的返回值：那条 API 分不清"失败"和"本来就没有焦点"（两种都给
 * NULL），文档确定的失败只有句柄无效、不在本线程的消息队列上、以及禁用（扩展错误 0x57）
 * 三种。label 就是 STATIC，它能不能拿焦点不在文档里，归 TODO T46 量。mac 那边同一档给的
 * 是 -4（label 那里 makeFirstResponder: 答应了却落回窗口自己），两边因此共用一条回读判据。 */
int moonui_native_focus_widget_in_window(const char *title,
                                  int title_len,
                                  int x,
                                  int y) {
  POINT pt;
  HWND win;
  HWND hit;
  HWND up;
  moonui_ptr want;
  TRACE("focus_widget_in_window");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  pt.x = x;
  pt.y = y;
  hit = ChildWindowFromPoint(win, pt);
  if (hit == 0) {
    return -3;
  }
  up = hit;
  while (up != 0 && up != win && moonui_native_owner_of(up) == 0) {
    up = GetParent(up);
  }
  if (up == 0 || up == win || moonui_native_owner_of(up) == 0) {
    return -4;
  }
  want = moonui_native_owner_of(up);
  SetFocus(up);
  if (moonui_native_focus_owner_of(win) != want) {
    return -4;
  }
  return 0;
}

/* 等价于"用户在键盘上按了（或抬起了）一颗键"，落点是当下有焦点的那个控件。
 *
 * PostMessage 而不是 SendMessage：WH_GETMESSAGE 挂在"取消息"那一步，SendMessage 是直接
 * 调窗口过程、钩子根本听不见。投递的那一条由事件循环取出来，走的是和真键盘同一道门，
 * 所以回调不在这次调用里跑，而是在下一次 moonui_native_main_step 取到它时跑——测试因此要先
 * step 再断言（mac 那份是 [NSApp sendEvent:] 同步派发，当场就跑完了；这是两边唯一的时间
 * 差，adapter.h 那条已经写明）。
 * 修饰组合靠的是"先投修饰键自己的按下、再投这颗键"，抬起反过来：钩子那四位数的就是这些
 * 消息（见上面 moonui_native_mod_count），和人手按出来的序列同一种形状。Alt 那一位在这里有个
 * 坑：DefWindowProc 收到 VK_MENU 的按下会进菜单模式，那是用户桌面上的事，所以 Windows 的
 * 测试只用 ctrl / shift 组合（mac 那边 ⌘ 归 meta，同一个坑不存在）。
 * lParam 只填重复次数 1，状态位（bit29 的 Alt 上下文、抬起的 bit30/31）留 0：读它们的
 * 是"想知道这颗键是不是合成出来的"那一类程序，我们都按消息 id 分派。 */
int moonui_native_send_key_in_window(const char *title,
                              int title_len,
                              const char *key,
                              int key_len,
                              int mods,
                              int down) {
  char *k;
  HWND win;
  HWND f;
  WORD vk = 0;
  int i;
  TRACE("send_key_in_window");
  k = moonui_native_dup(key, key_len);
  if (k == 0) {
    return -1;
  }
  if (!moonui_native_key_lookup(k, &vk)) {
    free(k);
    return -4;
  }
  free(k);
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  /* 归属靠焦点而不是坐标，所以调用方要先用上一条把焦点放好；没放好时这颗键会算到窗口
   * 自己头上，那条断言就成了假绿，所以这里先查、查不到直接报 -3。上面那条已经保证
   * "焦点在这只窗口的某个我们的控件上"，这里的 thread_focus 因此不会是 0。 */
  if (moonui_native_focus_owner_of(win) == 0) {
    return -3;
  }
  f = moonui_native_thread_focus();
  if (down != 0) {
    for (i = 0; i < 4; ++i) {
      if ((mods & (1 << i)) != 0) {
        PostMessageW(f, WM_KEYDOWN, (WPARAM)moonui_native_mod_vk[i], 1);
      }
    }
    PostMessageW(f, WM_KEYDOWN, (WPARAM)vk, 1);
  } else {
    PostMessageW(f, WM_KEYUP, (WPARAM)vk, 0xC0000001L);
    for (i = 3; i >= 0; --i) {
      if ((mods & (1 << i)) != 0) {
        PostMessageW(f, WM_KEYUP, (WPARAM)moonui_native_mod_vk[i], 0xC0000001L);
      }
    }
  }
  return 0;
}

/* kind(0 按下 / 1 抬起 / 3 双击) + button → 那一条消息。三张表而不是 switch 套 switch：
 * 五颗键乘三种动作是十五个 case，读的人要在里面找"哪一族"，表把族摆在行上。
 * kind 2 和 4 不走这里（WM_MOUSEMOVE 与滚轮那两条各自唯一）。button 已经在上层
 * 查过 0..4，越界轮不到这张表。 */
static UINT moonui_native_mouse_press_msg(int kind, int button) {
  static const UINT row_down[5] = {WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN,
                                   WM_XBUTTONDOWN, WM_XBUTTONDOWN};
  static const UINT row_up[5] = {WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP,
                                 WM_XBUTTONUP, WM_XBUTTONUP};
  static const UINT row_dbl[5] = {WM_LBUTTONDBLCLK, WM_RBUTTONDBLCLK,
                                  WM_MBUTTONDBLCLK, WM_XBUTTONDBLCLK,
                                  WM_XBUTTONDBLCLK};
  if (kind == 1) {
    return row_up[button];
  }
  if (kind == 3) {
    return row_dbl[button];
  }
  return row_down[button];
}

/* WM_XBUTTON* 的 wParam 低字是那颗侧键的编号（和滚轮的格数在同一个 wParam 的不同字里，
 * 见上面 moonui_native_mouse_button_of 的注释）；其余几种消息的 wParam 里没有键这一维。 */
static WPARAM moonui_native_mouse_xbutton_wparam(int button) {
  if (button == 3) {
    return (WPARAM)XBUTTON1;
  }
  if (button == 4) {
    return (WPARAM)XBUTTON2;
  }
  return 0;
}

/* WM_MOUSEMOVE 的 wParam 是 MK_* 那一组标志（见鼠标那节第 5 条）。 */
static WPARAM moonui_native_mouse_mk_wparam(int button) {
  switch (button) {
    case 0:
      return (WPARAM)MK_LBUTTON;
    case 1:
      return (WPARAM)MK_RBUTTON;
    case 2:
      return (WPARAM)MK_MBUTTON;
    case 3:
      return (WPARAM)MK_XBUTTON1;
    default:
      return (WPARAM)MK_XBUTTON2;
  }
}

/* 等价于"用户在窗口客户区 (x, y) 处给出一次鼠标动作"，dx/dy 是 Core 该看到的逻辑像素。
 *
 * 命中按坐标而不是"找窗口里第一个按钮"，和上面两条同一条理由：布局摆错了这里就命不中。
 * ChildWindowFromPoint 的阶梯也照那两条：点在窗口之外给 NULL（-3），落在客户区里但不
 * 落在任何子女窗口上给的是父窗口自己（往上退查不到标记，-4）。
 *
 * PostMessage 而不是 SendMessage（键盘那一条同一条理由）：钩子挂在"取消息"那一步，
 * SendMessage 是直接调窗口过程、钩子听不见。于是回调不在这次调用里跑，而是在下一次
 * moonui_native_main_step 取到那条消息时跑——测试要先 step 再断言（mac 那份是
 * -[NSApplication sendEvent:] 同步派发，当场就跑完，那是两边唯一的时间差）。
 * 也正因为投出去的时候钩子还一口都没咬，这一侧没法像 mac 那样比"这份监听有没有认领"：
 * 那个计数在调用返回时必然没动。所以 adapter.h 那条 -1 里"造出来没被认领"这一半只属于
 * mac，在这边 -1 只是编码失败、表达不出来或者 PostMessage 失败。
 *
 * 按下（kind 0）和双击（kind 3）要配一颗抬起，和 mac 同一个理由但落在不同的东西上：
 * 按钮给父窗口发 BN_CLICKED 的那一步在 WM_*BUTTONUP 上，而我们的 WM_COMMAND 分派走的
 * 正是 BN_CLICKED——少了那颗抬起，Click 这一档在测试里永远不出现（mac 那边是
 * trackMouse: 要从队列里取，取不到就出不来）。kind 3 投四条（按下、抬起、双击、
 * 抬起），那是真人双击在 Win32 上本来的形状：BN_CLICKED 两次，而第二次按下被系统
 * 换成了 WM_*BUTTONDBLCLK、不再有一条按下。
 *
 * 滚轮这里给的是"Core 该看到的数"，要投的原生格数按上面 moonui_native_wheel_delta_of 那三步
 * 反着算回去（格 = 逻辑像素 × dpi ÷ (行数 × 行高 × 96)，dy 那一支还要翻符号）。反向给数
 * 的理由在 adapter.h：往返自逆就把"换算只做一次、方向不漂"钉住了。钉不住的是量级——
 * 一格是多少逻辑像素的那三个数（行数、行高、dpi）测试侧一个都问不到，四舍五入之后
 * 投出去的格数几乎不会正好还原请求里那个整数，所以 Windows 的 Scroll 用例只钉方向和
 * "这一格走没走"，精确量级归那台机器上真跑的 `T53`。 */
int moonui_native_send_mouse_in_window(const char *title, int title_len,
                                int kind_button, int x, int y, int dx, int dy) {
  int kind;
  int button;
  int logical;
  int mag;
  int sign;
  int lines;
  int notches = 0;
  int dpi;
  int64_t denom;
  HWND win;
  HWND hit;
  HWND up;
  POINT pt;
  WPARAM xwp;
  UINT msg;
  UINT seq[4];
  WPARAM wps[4];
  LPARAM lp;
  int n = 0;
  int i;
  TRACE("send_mouse_in_window");
  /* 编码检查排最前：越界的 kind 或 button 必须"什么都没发生"（-5），而不是投出一条
   * Core 匹配不到的东西。两轴同时非零的滚轮也归这一档：Win32 没有一条消息同时带两个
   * 轴的滚动（纵向 WM_MOUSEWHEEL、横向 WM_MOUSEHWHEEL 各一条），mac 的 CGEvent 带得动，
   * 但那条 ABI 是两边共用的，于是 mac 侧同样在门口就报回 -5（adapter_native.m 里那一段），
   * 免得一侧投两条、另一侧投一条，测试去猜顺序。 */
  if (kind_button < 0 || kind_button / 8 > 4 || kind_button % 8 > 4) {
    return -5;
  }
  kind = kind_button / 8;
  button = kind_button % 8;
  if (kind == 4 && dx != 0 && dy != 0) {
    return -5;
  }
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  pt.x = x;
  pt.y = y;
  hit = ChildWindowFromPoint(win, pt);
  if (hit == 0) {
    return -3;
  }
  for (up = hit; up != 0 && up != win && moonui_native_owner_of(up) == 0;
       up = GetParent(up)) {
  }
  if (up == 0 || up == win || moonui_native_owner_of(up) == 0) {
    return -4;
  }
  /* 坐标两个空间：非滚轮按命中的那只原生窗口自己的客户区给（真人点到时系统给的就是
   * 这一套），滚轮按文档给屏幕坐标。两条都从"窗口客户区里的这个点"出发——那是 MoonBit
   * 传进来的空间，也是钩子读回来的空间，中间这一次换算是往返的必经之路。 */
  ClientToScreen(win, &pt);
  if (kind == 4) {
    lp = MAKELPARAM(pt.x, pt.y);
  } else {
    ScreenToClient(hit, &pt);
    lp = MAKELPARAM(pt.x, pt.y);
  }
  xwp = moonui_native_mouse_xbutton_wparam(button);
  if (kind == 2) {
    seq[n] = WM_MOUSEMOVE;
    wps[n] = moonui_native_mouse_mk_wparam(button);
    ++n;
  } else if (kind == 4) {
    logical = dy != 0 ? dy : dx;
    msg = dy != 0 ? WM_MOUSEWHEEL : WM_MOUSEHWHEEL;
    lines = moonui_native_wheel_lines_of(msg);
    if (lines < 0) {
      /* 这台机器上一格滚多少没有出处（-1 = 滚一页），造不出这条事件。 */
      return -1;
    }
    denom = (int64_t)lines * moonui_native_line_px() * 96;
    dpi = moonui_native_dpi_of(win);
    if (logical != 0) {
      if (denom <= 0) {
        /* 用户把滚轮设成"不滚动"：这条请求在这台机器上表达不出来，而不是投一条
         * 零增量的消息假装动了。 */
        return -1;
      }
      mag = logical < 0 ? -logical : logical;
      notches = (int)(((int64_t)mag * dpi + denom / 2) / denom);
      if (notches == 0) {
        /* 请求既然非零，至少走一格：投一条零增量的滚轮等于什么都没发生。 */
        notches = 1;
      }
      sign = logical < 0 ? -1 : 1;
      if (msg == WM_MOUSEWHEEL) {
        /* Core 的正 = 往下读，而 WM_MOUSEWHEEL 的正格 = 滚轮往上转 = 偏移减小。 */
        sign = -sign;
      }
      notches *= sign;
    }
    seq[0] = msg;
    /* 格数按 Win32 的规矩乘上 WHEEL_DELTA 再进 HIWORD：那一栏的单位就是一格 120，
     * 钩子那侧按 SHORT(HIWORD)/WHEEL_DELTA 整除还原——真跑实测，投 ±1 这种"裸格数"
     * 读回来恒为 0 格，整条事件就成了 Scroll(0,0)。 */
    wps[0] = MAKELPARAM(0, (SHORT)(notches * WHEEL_DELTA));
    n = 1;
  } else {
    if (kind == 0 || kind == 3) {
      seq[n] = moonui_native_mouse_press_msg(0, button);
      wps[n] = xwp;
      ++n;
      seq[n] = moonui_native_mouse_press_msg(1, button);
      wps[n] = xwp;
      ++n;
    }
    if (kind == 3) {
      seq[n] = moonui_native_mouse_press_msg(3, button);
      wps[n] = xwp;
      ++n;
      seq[n] = moonui_native_mouse_press_msg(1, button);
      wps[n] = xwp;
      ++n;
    }
    if (kind == 1) {
      seq[n] = moonui_native_mouse_press_msg(1, button);
      wps[n] = xwp;
      ++n;
    }
  }
  for (i = 0; i < n; ++i) {
    /* 命中的是我们自己的容器（单选那一组）时照样发给它：钩子里那条往上退的链负责认
     * 收件人，不在这儿替它挑一个。 */
    if (PostMessageW(hit, seq[i], wps[i], lp) == 0) {
      /* 投到第几条失败就停在这里：前面那几条已经进队列了，报 -1 而不是 0——一次
       * 不完整的动作会让测试红，而"什么也没投出去"和"投了一半"都绝不该报成已送达。 */
      return -1;
    }
  }
  return 0;
}

int moonui_native_request_window_close(const char *title, int title_len) {
  HWND win;
  TRACE("request_window_close");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  /* PostMessage 而不是 SendMessage：真人点关闭按钮也是投递一条消息，
   * 而且这样回调发生在事件循环里，和 Close 事件的取货顺序一致。 */
  if (PostMessageW(win, WM_CLOSE, 0, 0) == 0) {
    return -1;
  }
  return 0;
}

/* 装好"ms 毫秒之后按下下一个对话框的第 index 个按钮"。契约（为什么必须有这条、
 * 为什么越界当场报回去）在 adapter.h 的测试脚手架那段；真正按下去的过程在上面
 * moonui_native_start_dismissor 起的线程里。
 * 这里不起线程：对话框还没建，线程一醒过来无处可点。等下一个对话框来认领。 */
int moonui_native_auto_dismiss_dialog(int ms, int index) {
  TRACE("auto_dismiss_dialog");
  if (index < 0 || index > 1) {
    return -1;
  }
  moonui_native_dismiss_after_ms = ms < 0 ? 0 : ms;
  moonui_native_dismiss_index = index;
  return 0;
}

/* 装好"ms 毫秒之后对下一个文件面板按下接受 / 取消，并且面板停在 path 上"。契约
 * （-1 的校验为什么排最前、-2 为什么只在 mac 上出现）在 adapter.h 的测试脚手架
 * 那段；认领与执行在文件面板那段的 moonui_native_claim_file_answer /
 * moonui_native_file_answer_worker。
 * 这里同样不起线程：面板还没建，线程一醒过来无处可按。等下一个面板来认领。 */
int moonui_native_auto_answer_file_dialog(int ms,
                                   const char *path,
                                   int path_len,
                                   int accept) {
  LPWSTR w = 0;
  TRACE("auto_answer_file_dialog");
  if (accept != 0) {
    /* 校验在改状态之前做完：报错的这一发不许留下半装好的状态。 */
    if (path == 0 || path_len <= 0) {
      return -1;
    }
    w = moonui_native_utf16_of(path, path_len);
    if (w == 0) {
      return -1;
    }
  }
  /* 取消不需要导航（答案和面板停在哪无关），path 直接丢掉。重复装以最后一次为
   * 准：旧的（上一次没被认领的）作废，和"一直没有面板来认领，下一个面板会被它
   * 答掉"相反的那一半——认领即失效，没认领的被覆盖。 */
  free(moonui_native_file_answer_path);
  moonui_native_file_answer_path = w;
  moonui_native_file_answer_accept = accept != 0;
  moonui_native_file_answer_after_ms = ms < 0 ? 0 : ms;
  return 0;
}

#else
/* 非 Windows 宿主：本翻译单元什么也不定义，只留一个 typedef，免得空翻译单元
 * 触发 C99 的诊断。Cocoa 那份实现在 ../native-macos/adapter_native.m，
 * 两个文件提供同一套 adapter.h 契约。 */
typedef int moonui_native_adapter_host_not_windows_t;
#endif /* _WIN32 */
