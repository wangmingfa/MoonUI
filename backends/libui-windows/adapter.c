/* libui-ng C Adapter 的 Windows 实现（§5）。
 *
 * 本文件与 vendored 的 ui.h / ui_windows.h 同目录：moon 的 native-stub 只编译
 * 包目录里的 C 文件，所以同目录的包含全部相对自身，既不依赖 -I，也不受跑 moon
 * 命令时的工作目录影响。两份实现共用的 ABI 契约在 ../libui-common/adapter.h，那边
 * 只有声明；Cocoa 那份实现在 ../libui-macos/adapter_macos.m，两个目录各有一套链接
 * 配置。链接用的静态库路径见本目录的 moon.pkg。
 *
 * `#if defined(_WIN32)` 现在是一道防线而不是必需品：共享包 ../libui-common 没有
 * native-stub，mac 那条路径不会再把这个文件编进去（改名之前它和共享实现同目录，
 * native-stub 顺着 import 传下去，mac 上每次构建都编一遍这个空 TU）。留着是因为
 * "本文件只属于 Windows"这句话写在这里比写在注释里可靠——本机实测在 mac 上点名
 * `moon test backends/libui-windows`，clang 照样编它，得到空 TU 而不是撞 windows.h。
 */
#if defined(_WIN32)
#include "../libui-common/adapter.h"

#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include <windows.h>

/* 文件面板那半要用 IFileDialog（§24 / §48-18）：COM 初始化与 CLSID/IID 来自
 * objbase.h，对话框接口来自 shobjidl.h。两个符号库 ole32.lib / uuid.lib 在
 * moon.pkg 的链接清单里本来就有，不用新增。 */
#include <objbase.h>
#include <shobjidl.h>

#include "ui.h"
#include "ui_windows.h"

/* libui 的 Windows 后端把 manifest（Common Controls v6 + DPI 感知）编在 DLL 里；
 * 链静态库时那份 manifest 不会跟过来，所以在这里自己声明。少了它，
 * InitCommonControlsEx 只拿到旧版控件，libui 初始化会直接返回错误。 */
#pragma comment(linker,                                                      \
                "\"/manifestdependency:type='Win32'                         \
name='Microsoft.Windows.Common-Controls' version='6.0.0.0'                  \
processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

/* 排查"死在哪一次 FFI 调用"用的开关：native 测试进程里 MoonBit 的 println 是
 * 全缓冲的，异常退出时整段丢失，只有 C 侧即时 fflush 的输出留得住顺序。
 * 打开方式是临时在本包 moon.pkg 里加回 stub-cc-flags: "-DMOONUI_TRACE"——
 * 那份 flags 现在是空的，因为 mac 构建也要编译这个文件。 */
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

/* 控件回调的槽位表。C 必须替 MoonBit 看守闭包的生命周期：libui 只记函数指针
 * + void*，GC 看不见它，不 incref 回来的就是尸体（§47 风险 1）。
 * 一个控件一个点击回调、一个窗口两个回调（closing / resized），96 个对当前
 * 的 Demo 和测试都很够用；用满时注册返回 -1，MoonBit 侧变成显式错误。 */
#define MOONUI_SLOTS 96

typedef struct {
  void *owner;
  moonui_closure_fn fn;
  void *closure;
} MoonuiSlot;

static MoonuiSlot moonui_slots[MOONUI_SLOTS];
static char moonui_error[512];

/* libui 的初始化是进程级的，重复 uiInit 会去注册已存在的窗口类而直接失败，
 * uiUninit 也没有引用计数。所以这里当单例看守：初始化幂等，未初始化时
 * 退出也是空操作。MoonBit 侧的 initialize()/terminate() 因此可以成对调用，
 * 不必担心同一个测试进程里跑了两条测试。 */
static int moonui_inited = 0;

/* attach 时给控件 HWND 分配的 ID 计数器，见 moonui_control_attach 的注释。 */
static int moonui_next_control_id = 0;

/* detach 之后控件的临时住所。必须是自建的隐藏窗口而不是 libui 的 utilWindow：
 * WM_COMMAND 是发给父窗口的，挂在这里就等于消息进不了任何 libui 窗口的方法，
 * 摘下来的控件因此是"沉默"的。 */
static HWND moonui_park = 0;

/* 菜单栏那一整块写在本文件后面（§25 / §48-20，紧挨在事件循环之前）。窗口那几条要
 * 在建好之后把活窗口登记上、按当下这棵树挂菜单位，所以这里先给一组前置声明。 */
static int moonui_menu_wanted(void);
static void moonui_menu_register(uiWindow *win, HWND hwnd);
static void moonui_menu_unregister(HWND hwnd);
static void moonui_menu_clear_all(void);
static int moonui_menu_pad_of(HWND hwnd);

/* 键盘那一节（§32 / §48-16 的 T39）写在文件后面，但 terminate 第一件事就是摘掉那份
 * 钩子——摘晚了槽位排干之后还会来回调。 */
static void moonui_key_drop_hook(void);

/* ---- 小工具 ---- */

static HWND moonui_hwnd(moonui_ptr c) {
  return (HWND)(uintptr_t)uiControlHandle((uiControl *)(uintptr_t)c);
}

/* 原生对象 → moonui_ptr 的反查，adapter.h 的"归属怎么认"那一段说的就是它。mac 用
 * objc_setAssociatedObject 的 ASSIGN 策略，Windows 用窗口属性表：属性跟着 HWND 一起
 * 没，所以这条反记不需要配对清理，也不会有第二张活对象表（那份账在 MoonBit 的
 * HandleTable 里，两处记就一定分叉）。
 * 打标记的是真 HWND，不是 libui 的 C 结构体指针——GetFocus / ChildWindowFromPoint
 * 给我们的本来就是 HWND，把另一头的指针挂上去等于两张表各存一份身份。 */
static const WCHAR moonui_owner_prop[] = L"moonui.owner";

static void moonui_mark_owner(HWND hwnd, moonui_ptr owner) {
  if (hwnd == 0 || owner == 0) {
    return;
  }
  SetPropW(hwnd, moonui_owner_prop, (HANDLE)(uintptr_t)owner);
}

static moonui_ptr moonui_owner_of(HWND hwnd) {
  if (hwnd == 0) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)GetPropW(hwnd, moonui_owner_prop);
}

/* 两个 int32 打包进一个 int64：MoonBit 的 native FFI 只有单返回值。 */
static int64_t moonui_pack2(int a, int b) {
  return ((int64_t)(int32_t)a << 32) | (int64_t)(uint32_t)b;
}

/* MoonBit 的 Bytes 不保证 NUL 结尾，而 Win32 全收 UTF-16、libui 全收
 * NUL 结尾的 UTF-8。复制一份是唯一不靠运气的做法，调用方负责 free。 */
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

static LPWSTR moonui_utf16_of(const char *s, int len) {
  LPWSTR out;
  int needed;
  if (s == 0 || len < 0) {
    return 0;
  }
  /* 空串单独走一发：cbMultiByte=0 在 MultiByteToWideChar 那里不是"零个字符"，
   * 而是"自己数到终止符"，而 MoonBit 的 Bytes 不保证 NUL 结尾，于是读过界。
   * 剪贴板那条踩过（TODO 的 `T19`），这里同一个坑同一个修法：直接构造只含一个
   * L'\0' 的块。 */
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

static char *moonui_utf8_of(LPCWSTR w) {
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

static moonbit_bytes_t moonui_bytes_of(const char *s) {
  int n = (int)strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  if (n > 0) {
    memcpy(out, s, (size_t)n);
  }
  return out;
}

/* ---- 回调槽位 ---- */

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
 * 和勾选态由 MoonBit 回读，见 adapter.h 那两条的约定。
 * 触发点：输入框是 windows/entry.cpp:12 的 onWM_COMMAND（code==EN_CHANGE），
 * 勾选框是 windows/checkbox.cpp:12 的同名处理器（code==BN_CLICKED，并且由 libui
 * 自己翻 BM_SETCHECK）。两者的共同点都是"父窗口收到 WM_COMMAND 后按控件 HWND
 * 查表转回来"，和人手操作走的是同一条路由，不是把回调函数直接调一遍。 */
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

/* 返回 0 = 否决 libui 自己销毁窗口。销毁顺序由 Core 决定（先内容树后窗口），
 * 而 libui 的默认行为是先拆窗口再返回，Core 会在拆掉的内容树上读到没的对象。 */
static int moonui_closing_trampoline(uiWindow *w, void *data) {
  (void)w;
  moonui_fire(data);
  return 0;
}

/* ---- DPI ---- */

/* 静态库不带 manifest 里的 DPI 感知声明，必须在建任何窗口之前用运行时方式设。
 * 取不到函数（老系统）就放弃，让系统按默认虚拟化，不影响后续流程。 */
static void moonui_ensure_dpi_aware(void) {
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

/* GetDpiForWindow 是 Win10 1607 才有的，所以和上面一样按名字取：
 * 直接静态导入会让二进制在老系统上连加载都加载不了。取不到退回 DC 的
 * 系统 DPI，再退回归一化用的基准 96。返回 0 是不可能的——0 会让 MoonBit
 * 侧的除法变成无穷大。 */
static int moonui_dpi_of(HWND hwnd) {
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
  return moonui_system_dpi();
}

int moonui_system_dpi(void) {
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

int moonui_window_dpi(moonui_ptr w) { return moonui_dpi_of(moonui_hwnd(w)); }

int moonui_widget_dpi(moonui_ptr c) {
  HWND parent = GetParent(moonui_hwnd(c));
  if (parent == 0) {
    return moonui_system_dpi();
  }
  return moonui_dpi_of(parent);
}

int64_t moonui_screen_work_area(void) {
  /* SPI_GETWORKAREA 按定义只有主屏，所以这条只服务"进程级屏幕尺寸"
   * （Core 的 `App::screen_size()`）；按窗口的读数走下面那两条
   * `moonui_window_screen_*`（`T42`）。 */
  RECT r;
  if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &r, 0) == 0) {
    return moonui_pack2(GetSystemMetrics(SM_CXSCREEN),
                        GetSystemMetrics(SM_CYSCREEN));
  }
  return moonui_pack2(r.right - r.left, r.bottom - r.top);
}

/* 这只窗口当下所在那块屏的工作区，虚拟屏幕绝对坐标、物理像素（T42）。
 * SPI_GETWORKAREA 按定义只有主屏，所以副屏上的窗口拿它的数必然错。
 * MONITOR_DEFAULTTONEAREST 不是省事：窗口跨在两块屏的交界上时系统给的是重叠最多的
 * 那块，而 flags 为 0 时窗口不在任何监视器上（还没上屏、被挪到虚拟屏幕的空洞）会
 * 返回 NULL。nearest 让这条入口在"还没定位"时也有一个可报的矩形。 */
static int moonui_window_work_rect(moonui_ptr w, RECT *out) {
  MONITORINFO mi;
  HMONITOR mon;
  mon = MonitorFromWindow(moonui_hwnd(w), MONITOR_DEFAULTTONEAREST);
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

int64_t moonui_window_screen_origin(moonui_ptr w) {
  RECT r;
  RECT main_r;
  TRACE("window_screen_origin");
  if (moonui_window_work_rect(w, &r)) {
    return moonui_pack2(r.left, r.top);
  }
  /* 兜底：退回主屏的工作区原点（通常就是 0,0），理由写在 adapter.h——报主屏的数
   * 比报一个 0 尺寸更像"还没定位"，而 0 尺寸会让 LogicalRect::center 把窗口堆到
   * 左上角，症状会被读成"居中算错了"。 */
  if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &main_r, 0) != 0) {
    return moonui_pack2(main_r.left, main_r.top);
  }
  return moonui_pack2(0, 0);
}

int64_t moonui_window_screen_size(moonui_ptr w) {
  RECT r;
  TRACE("window_screen_size");
  if (!moonui_window_work_rect(w, &r)) {
    return moonui_screen_work_area();
  }
  return moonui_pack2(r.right - r.left, r.bottom - r.top);
}

int moonui_system_theme(void) {
  HKEY key;
  DWORD type;
  DWORD value;
  DWORD size;
  int dark;

  /* 深色模式在 Win32 上没有查询 API（libui-ng 那边也没接：既没读这个值也没订阅
   * WM_SETTINGCHANGE），能读的就是这个注册表值——它是"应用用浅色吗"，0 才是深色。
   * 键、值、类型任何一个对不上都落回 0（浅色）：Windows 7 没有这个值，而这里没有
   * 错误可报（ABI 那条入口的说明）。用 RegOpenKeyExW/RegQueryValueExW 而不是
   * RegGetValueW，因为后者要 _WIN32_WINNT >= 0x0601，本文件没有声明那个宏。
   * advapi32.lib 在本目录 moon.pkg 的链接清单里（这条入口是第一个用到它的）。 */
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
  moonui_ensure_dpi_aware();
  memset(&options, 0, sizeof(options));
  err = uiInit(&options);
  if (err == 0) {
    moonui_inited = 1;
    return 0;
  }
  /* libui 用返回值当错误串；拷进静态缓冲后立刻还给 libui */
  n = strlen(err);
  if (n > sizeof(moonui_error) - 1u) {
    n = sizeof(moonui_error) - 1u;
  }
  memcpy(moonui_error, err, n);
  moonui_error[n] = '\0';
  uiFreeInitError(err);
  return 1;
}

moonbit_bytes_t moonui_last_error(void) {
  TRACE("last_error");
  return moonui_bytes_of(moonui_error);
}

void moonui_terminate(void) {
  int i;
  TRACE("terminate");
  /* 第一件事是摘钩子：槽位一排干，钩子里那句 moonui_fire 就会调到已经没了的闭包上
   * （和 mac 那份 removeMonitor 同一条理由，见 adapter_macos.m 的本函数）。 */
  moonui_key_drop_hook();
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    moonui_release_slot(&moonui_slots[i]);
  }
  /* 菜单栏不在这张槽位表里、也不归句柄表管（它是逐窗口的原生对象 + 进程全局的
   * 一份回调和一份树的副本），所以收尾要单独走一遍：拆每只窗口挂的那棵、换回窗口
   * 过程、松开闭包、free 掉那棵树。漏了这一步的话下一跑的快照读回来的是上一跑的树。 */
  moonui_menu_clear_all();
  if (moonui_park != 0) {
    DestroyWindow(moonui_park);
    moonui_park = 0;
  }
  if (!moonui_inited) {
    return;
  }
  moonui_inited = 0;
  /* uiUninit 末尾会审计 libui 自己的分配表：只要还漏着一块，它就当成 bug
   * 调用 DebugBreak()——没有调试器时这就是一个退出不了的测试进程。所以
   * 走到这里之前，MoonBit 侧必须把所有控件和窗口销毁干净（句柄表归零）。 */
  uiUninit();
}

/* ---- 窗口 ---- */

moonui_ptr moonui_window_new(const char *title,
                             int title_len,
                             int width,
                             int height) {
  char *t;
  uiWindow *win;
  HWND hwnd;
  int has_bar;
  TRACE("window_new");
  t = moonui_dup(title, title_len);
  if (t == 0) {
    return 0;
  }
  /* 最后一个参数是"有没有菜单位"。§25 的菜单是运行时才装的，而 Win32 的菜单位是逐窗口
   * 的（adapter.h 那段），所以这一位要看当下有没有一棵非空的树等着挂：
   *   - 没装过（或装的是空的一棵）→ 给 0，和这次改动之前一模一样，libui 不占那一行；
   *   - 已经有一棵 → 给 1，让 libui 自己把那一行算进外框。它每次换算都现量当下挂着的
   *     那棵（windows/winutil.cpp:80-106），我们随后换上自己那棵，行高是同一个数，
   *     Core 之后读到的客户区因此不会莫名少一行。
   * 换上自己那棵、以及"事后才装"的那条路（登记时 knows_bar=0，靠量出来的 menu_pad
   * 补偿）都在下面菜单栏那一节。mac 那边这个参数没人读（主菜单是进程全局的）。 */
  has_bar = moonui_menu_wanted();
  win = uiNewWindow(t, width, height, has_bar);
  free(t);
  if (win == 0) {
    return 0;
  }
  hwnd = (HWND)(uintptr_t)uiControlHandle((uiControl *)win);
  moonui_mark_owner(hwnd, (moonui_ptr)(uintptr_t)win);
  moonui_menu_register(win, hwnd);
  return (moonui_ptr)(uintptr_t)win;
}

void moonui_window_show(moonui_ptr w) {
  TRACE("window_show");
  uiControlShow((uiControl *)(uintptr_t)w);
}

void moonui_window_hide(moonui_ptr w) {
  TRACE("window_hide");
  uiControlHide((uiControl *)(uintptr_t)w);
}

void moonui_window_destroy(moonui_ptr w) {
  TRACE("window_destroy");
  /* 控件是自己挂在窗口 HWND 下的，libui 不会替它回收闭包，所以窗口拆之前
   * 必须把替它看守的 closing/resized 引用松开；否则回调槽里留着的是一个
   * 已经失效的 uiWindow 指针，之后任何一次按 owner 查找都可能命中它。 */
  /* 菜单那一头同理：先换回原来的窗口过程、拆掉我们那棵 HMENU、空出登记位，再让
   * libui 销毁窗口。反过来的话销毁途中来的消息就落在一个登记项已经作废的子类上。 */
  moonui_menu_unregister(moonui_hwnd(w));
  moonui_forget((void *)(uintptr_t)w, 0);
  uiControlDestroy((uiControl *)(uintptr_t)w);
}

void moonui_window_set_title(moonui_ptr w, const char *title, int title_len) {
  LPWSTR t = moonui_utf16_of(title, title_len);
  TRACE("window_set_title");
  if (t == 0) {
    return;
  }
  SetWindowTextW(moonui_hwnd(w), t);
  free(t);
}

void moonui_window_set_content_size(moonui_ptr w, int width, int height) {
  TRACE("window_set_content_size");
  /* 加的是 C 自己量出来的那一行（moonui_menu_apply），不是系统参数：libui 的
   * hasMenubar 在建窗口时就定死了，事后 SetMenu 它并不知道，于是它算外框时少算一行、
   * 客户区因此被菜单位吃掉一行。建窗口时就知道有菜单位的那些，这里加的是 0——libui
   * 自己已经算过一遍了，再加就成两行。 */
  uiWindowSetContentSize((uiWindow *)(uintptr_t)w, width,
                         height + moonui_menu_pad_of(moonui_hwnd(w)));
}

int64_t moonui_window_content_size(moonui_ptr w) {
  int width = 0;
  int height = 0;
  TRACE("window_content_size");
  uiWindowContentSize((uiWindow *)(uintptr_t)w, &width, &height);
  return moonui_pack2(width, height);
}

void moonui_window_set_position(moonui_ptr w, int x, int y) {
  TRACE("window_set_position");
  uiWindowSetPosition((uiWindow *)(uintptr_t)w, x, y);
}

int64_t moonui_window_position(moonui_ptr w) {
  int x = 0;
  int y = 0;
  TRACE("window_position");
  uiWindowPosition((uiWindow *)(uintptr_t)w, &x, &y);
  return moonui_pack2(x, y);
}

void moonui_window_set_resizable(moonui_ptr w, int resizable) {
  TRACE("window_set_resizable");
  uiWindowSetResizeable((uiWindow *)(uintptr_t)w, resizable);
}

void moonui_window_set_fullscreen(moonui_ptr w, int fullscreen) {
  TRACE("window_set_fullscreen");
  uiWindowSetFullscreen((uiWindow *)(uintptr_t)w, fullscreen);
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
  uiWindowOnClosing((uiWindow *)(uintptr_t)w, moonui_closing_trampoline,
                    &moonui_slots[slot]);
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
  uiWindowOnContentSizeChanged((uiWindow *)(uintptr_t)w,
                               moonui_resize_trampoline, &moonui_slots[slot]);
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
  free(t);
  if (c != 0) {
    moonui_mark_owner(moonui_hwnd((moonui_ptr)(uintptr_t)c),
                      (moonui_ptr)(uintptr_t)c);
  }
  return (moonui_ptr)(uintptr_t)c;
}

void moonui_widget_destroy(moonui_ptr c) {
  TRACE("widget_destroy");
  moonui_forget((void *)(uintptr_t)c, 0);
  uiControlDestroy((uiControl *)(uintptr_t)c);
}

void moonui_widget_set_text(moonui_ptr c, const char *text, int text_len) {
  char *t = moonui_dup(text, text_len);
  WCHAR cls[64];
  HWND hwnd;
  LONG style;
  TRACE("widget_set_text");
  if (t == 0) {
    return;
  }
  /* 分派到 libui 自己的 setter，而不是直接发 WM_SETTEXT：uiEntrySetText 会先立
   * inhibitChanged 再 SetWindowText（windows/entry.cpp:64-77），EN_CHANGE 因此被吞掉，
   * 程序赋值不会回声成用户打字。原先那句 SendMessageW(WM_SETTEXT) 跳不过这道闸，
   * 多出来的一条 EN_CHANGE 把 backend_wbtest.mbt 的"程序改文案不回声"跑红了。
   * 类名本身不够分：uiButton 和 uiCheckbox 都是 L"button"（button.cpp:92-94 用
   * BS_PUSHBUTTON、checkbox.cpp:106-108 用 BS_CHECKBOX），所以 button 那一支再按
   * BS_TYPEMASK 分一次——不然就是把 uiCheckbox* 当 uiButton* 使，两者 hwnd 偏移恰好
   * 相同（两个结构都是 uiWindowsControl c 后面紧跟 HWND hwnd）不等于这是对的。 */
  hwnd = moonui_hwnd(c);
  if (GetClassNameW(hwnd, cls, 64) == 0) {
    free(t);
    return;
  }
  if (lstrcmpiW(cls, L"edit") == 0) {
    uiEntrySetText((uiEntry *)(uintptr_t)c, t);
  } else if (lstrcmpiW(cls, L"button") == 0) {
    style = GetWindowLongW(hwnd, GWL_STYLE) & BS_TYPEMASK;
    if (style == BS_CHECKBOX || style == BS_AUTOCHECKBOX) {
      uiCheckboxSetText((uiCheckbox *)(uintptr_t)c, t);
    } else {
      uiButtonSetText((uiButton *)(uintptr_t)c, t);
    }
  } else {
    /* 剩下的是 uiLabel（类名 Static）。 */
    uiLabelSetText((uiLabel *)(uintptr_t)c, t);
  }
  free(t);
}

moonbit_bytes_t moonui_widget_text(moonui_ptr c) {
  HWND hwnd = moonui_hwnd(c);
  int n = GetWindowTextLengthW(hwnd);
  WCHAR *wbuf;
  char *ubuf;
  moonbit_bytes_t out;
  TRACE("widget_text");
  if (n < 0) {
    n = 0;
  }
  wbuf = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
  if (wbuf == 0) {
    return moonbit_make_bytes(0, 0);
  }
  wbuf[0] = L'\0';
  /* GetWindowTextW 会把拷出的长度返回，截断到给定容量，所以多给的 1 格只用来兜 NUL */
  GetWindowTextW(hwnd, wbuf, n + 1);
  ubuf = moonui_utf8_of(wbuf);
  free(wbuf);
  if (ubuf == 0) {
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_bytes_of(ubuf);
  free(ubuf);
  return out;
}

void moonui_widget_set_checked(moonui_ptr c, int checked) {
  TRACE("widget_set_checked");
  SendMessageW(moonui_hwnd(c), BM_SETCHECK,
               (WPARAM)(checked ? BST_CHECKED : BST_UNCHECKED), 0);
}

int moonui_widget_checked(moonui_ptr c) {
  TRACE("widget_checked");
  return SendMessageW(moonui_hwnd(c), BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0;
}

void moonui_widget_set_visible(moonui_ptr c, int visible) {
  TRACE("widget_set_visible");
  ShowWindow(moonui_hwnd(c), visible ? SW_SHOW : SW_HIDE);
}

int moonui_widget_visible(moonui_ptr c) {
  TRACE("widget_visible");
  return IsWindowVisible(moonui_hwnd(c)) ? 1 : 0;
}

void moonui_widget_set_enabled(moonui_ptr c, int enabled) {
  TRACE("widget_set_enabled");
  EnableWindow(moonui_hwnd(c), enabled ? TRUE : FALSE);
}

int moonui_widget_enabled(moonui_ptr c) {
  TRACE("widget_enabled");
  return IsWindowEnabled(moonui_hwnd(c)) ? 1 : 0;
}

int64_t moonui_widget_minimum_size(moonui_ptr c) {
  int width = 0;
  int height = 0;
  TRACE("widget_minimum_size");
  uiWindowsControlMinimumSize((uiWindowsControl *)(uintptr_t)c, &width, &height);
  return moonui_pack2(width, height);
}

int64_t moonui_widget_origin(moonui_ptr c) {
  HWND hwnd = moonui_hwnd(c);
  HWND parent = GetParent(hwnd);
  RECT r;
  POINT p;
  TRACE("widget_origin");
  if (parent == 0 || GetWindowRect(hwnd, &r) == 0) {
    return moonui_pack2(0, 0);
  }
  p.x = r.left;
  p.y = r.top;
  /* 屏幕坐标 -> 父窗口客户区坐标，正好和 moonui_control_set_bounds 收的那套一致 */
  ScreenToClient(parent, &p);
  return moonui_pack2((int)p.x, (int)p.y);
}

int64_t moonui_widget_size(moonui_ptr c) {
  RECT r;
  TRACE("widget_size");
  if (GetWindowRect(moonui_hwnd(c), &r) == 0) {
    return moonui_pack2(0, 0);
  }
  return moonui_pack2(r.right - r.left, r.bottom - r.top);
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
  uiButtonOnClicked((uiButton *)(uintptr_t)c, moonui_click_trampoline,
                    &moonui_slots[slot]);
  return 0;
}

/* 输入框的文字变了。libui 的 uiEntrySetText 会先立 inhibitChanged 再 SetWindowText
 * （windows/entry.cpp:68-75），所以 Core 那侧的程序赋值不会回声成用户打字——
 * 这条差异是 moonui_widget_on_text_changed 与 moonui_type_text_in_window 能分成
 * 两个入口的前提，Windows 上是 libui 替我们做到的。 */
int moonui_widget_on_text_changed(moonui_ptr c,
                                  moonui_closure_fn fn,
                                  void *closure) {
  int slot;
  TRACE("widget_on_text_changed");
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  uiEntryOnChanged((uiEntry *)(uintptr_t)c, moonui_text_changed_trampoline,
                   &moonui_slots[slot]);
  return 0;
}

/* 勾选框被点了一下。和点击按钮不同，勾选态是 libui 自己在 onWM_COMMAND 里翻的
 * （windows/checkbox.cpp:20-24，因为它没用 BS_AUTOCHECKBOX），回调只报"出事了"，
 * 新状态由 MoonBit 读 moonui_widget_checked。 */
int moonui_widget_on_toggled(moonui_ptr c,
                             moonui_closure_fn fn,
                             void *closure) {
  int slot;
  TRACE("widget_on_toggled");
  slot = moonui_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  uiCheckboxOnToggled((uiCheckbox *)(uintptr_t)c, moonui_toggled_trampoline,
                      &moonui_slots[slot]);
  return 0;
}

/* ---- 控件摆放（§14）----
 * 布局算在 MoonUI 这一侧，libui 的容器布局完全不参与。
 *
 * 控件的 HWND 一出生挂在 libui 的隐藏工具窗口下（windows/control.cpp 里
 * uiWindowsEnsureCreateControlHWND 的 parent 就是 utilWindow），所以"挂进窗口"
 * 在这里就是把 HWND 搬到目标窗口的客户区。两条不变量支持了这条捷径：
 *   - 回调路由按控件 HWND 查表（windows/events.cpp 的 runWM_COMMAND 用
 *     lParam 当键，不用控件 ID），父级是谁不影响路由；WM_COMMAND 本身是发给
 *     父窗口的，而 libui 的顶层窗口方法（windows/window.cpp）会把它交给
 *     handleParentMessages，所以搬进真窗口之后点击照样能回来；
 *   - 主循环对顶层祖先跑 IsDialogMessage（windows/main.cpp processMessage），
 *     焦点链因此还是键盘 Tab 能走通的——只是 Tab 顺序跟 z-order 走，
 *     所以每个新控件插到 z-order 末尾，插入顺序就是 Tab 顺序。
 * 代价：窗口不再替 child 销毁控件，child 必须在窗口之前逐个显式销毁
 * （DestroyWindow 会连带销毁子窗口，之后再 destroy 就是野句柄，
 * libui 的分配审计会把这变成 DebugBreak）。这条顺序由 MoonBit 侧保证。 */
void moonui_control_attach(moonui_ptr window, moonui_ptr child) {
  HWND parent = moonui_hwnd(window);
  HWND hwnd = moonui_hwnd(child);
  TRACE("control_attach");
  if (GetParent(hwnd) == parent) {
    return;
  }
  if (SetParent(hwnd, parent) == 0) {
    return;
  }
  if ((LONG_PTR)GetWindowLongPtrW(hwnd, GWLP_ID) == 0) {
    /* ID 只要在本窗口内互不相同；起点避开 IDOK/IDCANCEL（1/2）。 */
    SetWindowLongPtrW(hwnd, GWLP_ID, (LONG_PTR)(1000 + moonui_next_control_id));
    moonui_next_control_id += 1;
  }
  SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOMOVE);
}

void moonui_control_set_bounds(moonui_ptr child,
                               int x,
                               int y,
                               int width,
                               int height) {
  TRACE("control_set_bounds");
  /* z-order 原样保留：否则每次 resize 都会把控件重新排一遍，
   * Tab 顺序跟着布局抖动。 */
  SetWindowPos(moonui_hwnd(child), 0, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOZORDER);
}

static void moonui_ensure_park(void) {
  if (moonui_park != 0) {
    return;
  }
  moonui_park = CreateWindowExW(0, L"STATIC", L"", WS_POPUP, -32000, -32000, 0,
                                0, 0, 0, GetModuleHandleW(0), 0);
}

void moonui_control_detach(moonui_ptr child) {
  HWND hwnd = moonui_hwnd(child);
  TRACE("control_detach");
  moonui_ensure_park();
  if (moonui_park == 0) {
    return;
  }
  if (SetParent(hwnd, moonui_park) == 0) {
    return;
  }
  /* ID 清零 = 回到"还没挂进任何窗口"的状态，重新 attach 时按新末尾插入 */
  SetWindowLongPtrW(hwnd, GWLP_ID, 0);
  SetWindowPos(hwnd, 0, 0, 0, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER);
}

/* Stack 的层叠（§14、§48-15）。Core 按数组顺序把 Stack 的叶子逐个提上来，
 * 提完之后的顺序就是"后提的在最上面"，也就是数组靠后的画在上层。
 * 只提不动矩形，所以这条和 set_bounds 互不干扰。 */
void moonui_control_raise(moonui_ptr child) {
  TRACE("control_raise");
  SetWindowPos(moonui_hwnd(child), HWND_TOP, 0, 0, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOMOVE);
}

/* 往上数 GW_HWNDPREV 的步数就是"从顶层数第几个"，和 EnumChildWindows 的返回
 * 顺序同向。所以这条既能当断言用，也顺手回答了"HWND_TOP 到底提到哪去了"。 */
int moonui_control_z_index(moonui_ptr child) {
  HWND hwnd;
  int index = 0;
  TRACE("control_z_index");
  hwnd = moonui_hwnd(child);
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

/* ---- 剪贴板 ----
 * libui 不管剪贴板，所以这里直接打 Win32（契约见 adapter.h）。选 CF_UNICODETEXT
 * 而不是 CF_TEXT：记事本、浏览器、libui 自己的控件认的都是前者，而 CF_TEXT 绑
 * 当前 ANSI 代码页，非 ASCII 文案（中文）在代码页转换里会丢字——UTF-16 没有这个
 * 问题，MoonBit 侧的 UTF-8 在这里就地转码。 */

moonbit_bytes_t moonui_clipboard_text(void) {
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
  if (!OpenClipboard(NULL)) {
    return out;
  }
  h = GetClipboardData(CF_UNICODETEXT);
  if (h != NULL) {
    w = (LPWSTR)GlobalLock(h);
    if (w != 0) {
      u = moonui_utf8_of(w);
      if (u != 0) {
        out = moonui_bytes_of(u);
        free(u);
      }
      GlobalUnlock(h);
    }
  }
  CloseClipboard();
  return out;
}

int moonui_clipboard_set_text(const char *text, int text_len) {
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
    w = moonui_utf16_of(text, text_len);
    if (w == 0) {
      return -2;
    }
  }
  /* CF_UNICODETEXT 要求块里带结尾的那个 L'\\0'，GlobalSize 就是它。 */
  bytes = ((size_t)lstrlenW(w) + 1u) * sizeof(WCHAR);
  if (!OpenClipboard(NULL)) {
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
 * 契约见 adapter.h 的对话框那段：为什么不走 libui 的 uiMsgBox（它把用户的选择吞
 * 在返回值缺失里）、为什么不带窗口句柄、-1/-2 两个失败码分别是什么。
 *
 * MessageBoxW 在自己的调用里跑一层任务模态循环（MB_TASKMODAL：调用线程此后只在
 * 那个对话框的消息循环里，和 mac 的 NSAlert runModal 同层），所以它必须从 handler
 * 里调用，且期间 MoonBit 一行都跑不到。 */

/* 测试脚手架装的那发"用户会在 ms 毫秒后按第 index 个按钮"，认领者是本文件下面
 * moonui_start_dismissor（在 MessageBoxW 之前认领，因为调用一阻塞就没机会了）。 */
static int moonui_dismiss_after_ms = -1;
static int moonui_dismiss_index = -1;

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
static int moonui_dialog_gone(HWND dialog) {
  int waited;
  for (waited = 0; waited < MOONUI_DISMISS_LOOK_MS && IsWindow(dialog);
       waited += MOONUI_DISMISS_POLL_MS) {
    Sleep(MOONUI_DISMISS_POLL_MS);
  }
  return !IsWindow(dialog);
}

static DWORD WINAPI moonui_dismiss_worker(LPVOID raw) {
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
     * 理由，也和 moonui_click_button_in_window 同一个理由）。 */
    SendDlgItemMessageW(dialog, d->id, BM_CLICK, 0, 0);
    /* 两级兜底。按下没生效时，WM_CLOSE 和 ESC 都会让 MessageBox 以 IDCANCEL 结束，
     * 于是调用方拿到"否"、断言红在那里。留着这段是因为脚手架坏掉的代价不该是
     * 一整轮挂住的测试。 */
    if (!moonui_dialog_gone(dialog)) {
      PostMessageW(dialog, WM_CLOSE, 0, 0);
      if (!moonui_dialog_gone(dialog)) {
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
static void moonui_start_dismissor(const WORD *ids, int count, LPCWSTR caption) {
  MoonuiDismiss *d;
  HANDLE thread;
  DWORD tid;
  int index;
  int n;
  if (moonui_dismiss_after_ms < 0 || count <= 0 || caption == 0) {
    return;
  }
  index = moonui_dismiss_index;
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
  d->delay_ms = (DWORD)(moonui_dismiss_after_ms < 0 ? 0 : moonui_dismiss_after_ms);
  /* 认领即失效：这一发只属于当前这个对话框，不许漏给下一个。 */
  moonui_dismiss_after_ms = -1;
  moonui_dismiss_index = -1;
  thread = CreateThread(0, 0, moonui_dismiss_worker, d, 0, &tid);
  if (thread == 0) {
    free(d->caption);
    free(d);
    return;
  }
  /* 主线程不能 join：它马上要进模态循环，而这一发的按钮点击正是要发给那个循环。
     CloseHandle 只关掉本线程自己的句柄，线程对象在它跑完之前都还在。 */
  CloseHandle(thread);
}

int moonui_dialog_message(const char *title,
                          int title_len,
                          const char *text,
                          int text_len) {
  static const WORD ids[1] = {IDOK};
  LPWSTR t = moonui_utf16_of(title, title_len);
  LPWSTR s = moonui_utf16_of(text, text_len);
  int rc;
  TRACE("dialog_message");
  if (t == 0 || s == 0) {
    free(t);
    free(s);
    return -1;
  }
  moonui_start_dismissor(ids, 1, t);
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

int moonui_dialog_confirm(const char *title,
                          int title_len,
                          const char *text,
                          int text_len) {
  static const WORD ids[2] = {IDYES, IDNO};
  LPWSTR t = moonui_utf16_of(title, title_len);
  LPWSTR s = moonui_utf16_of(text, text_len);
  int rc;
  TRACE("dialog_confirm");
  if (t == 0 || s == 0) {
    free(t);
    free(s);
    return -1;
  }
  moonui_start_dismissor(ids, 2, t);
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
 * 契约在 adapter.h 的文件对话框那段：为什么不用 libui 的 uiOpenFile / uiSaveFile
 * （取消和失败在那边是同一个 NULL）、返回码表、结果取走语义。
 *
 * 与 mac 那份有一处结构性差别：IFileDialog 在本进程自己的模态循环里跑（macOS
 * 15.6 的面板在 XPC 服务进程里），所以测试脚手架能替用户真的按下"打开 / 保存 /
 * 选择文件夹"——按下去的是真按键，路径由面板自己的提交路径给出（见下面
 * moonui_file_answer_worker）。 */

/* 测试脚手架装的那发"用户会在 ms 毫秒后对下一个面板按接受 / 取消，且面板停在
 * path 上"。认领者是下面的 moonui_claim_file_answer（Show 之前认领，因为 Show
 * 一进模态循环主线程就没机会了）；装它的入口 moonui_auto_answer_file_dialog 在
 * 测试脚手架那段。 */
static int moonui_file_answer_after_ms = -1;
static int moonui_file_answer_accept = 0;
static WCHAR *moonui_file_answer_path = 0;

/* 面板结果的落点：到 moonui_file_dialog_path 取走（或下一次面板打开）之前归本
 * 文件所有。取走语义和 mac 那份逐字一致，免得两边各理解一次。 */
static char *moonui_file_result = 0;

/* 三种形态共用一段实现，取值和 mac 的 MOONUI_FILE_* 同一张表。 */
#define MOONUI_FILE_OPEN 0
#define MOONUI_FILE_SAVE 1
#define MOONUI_FILE_FOLDER 2

typedef struct {
  WCHAR *caption; /* 自己拷的一份，由本结构负责 free */
  int accept;     /* 1 = 按下接受，0 = 关掉（取消） */
  DWORD delay_ms;
} MoonuiFileAnswer;

/* 到点按下按钮的线程，和上面 moonui_dismiss_worker 的结构逐句对应（找对话框、
 * 真按键、逐级兜底），差别只在"按什么"：接受是回车 / IDOK，取消是关闭 / ESC。 */
static DWORD WINAPI moonui_file_answer_worker(LPVOID raw) {
  MoonuiFileAnswer *a = (MoonuiFileAnswer *)raw;
  HWND dialog = 0;
  int waited;
  Sleep(a->delay_ms);
  /* 文件对话框也是系统预定义对话框类 "#32770"，标题是 SetTitle 的那串；找不到时
   * 退到只按类名，这一档和 moonui_dismiss_worker 同一个理由。 */
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
      if (!moonui_dialog_gone(dialog)) {
        /* 第二级是老式对话框形态的 OK 钮（控件 ID 固定是 IDOK）。BM_CLICK 让
         * 按钮自己发 BN_CLICKED，面板的提交路径因此真跑一遍——回来的路径是
         * 面板兑的，不是这里编的。 */
        SendDlgItemMessageW(dialog, IDOK, BM_CLICK, 0, 0);
        if (!moonui_dialog_gone(dialog)) {
          PostMessageW(dialog, WM_CLOSE, 0, 0);
          if (!moonui_dialog_gone(dialog)) {
            PostMessageW(dialog, WM_KEYDOWN, VK_ESCAPE, 0);
          }
        }
      }
    } else {
      /* 取消是关掉对话框：WM_CLOSE 让 Show 以 ERROR_CANCELLED 回来，和真人按
       * "取消"同一条路。 */
      PostMessageW(dialog, WM_CLOSE, 0, 0);
      if (!moonui_dialog_gone(dialog)) {
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
 * 这一发只属于当前这个面板，不许漏给下一个，和 mac 的 moonui_arm_file_answer
 * 同一个时点。 */
static void moonui_claim_file_answer(IFileDialog *dialog, LPCWSTR caption) {
  MoonuiFileAnswer *a;
  HANDLE thread;
  DWORD tid;
  WCHAR *path;
  int accept;
  DWORD after;
  int n;
  if (moonui_file_answer_after_ms < 0) {
    return;
  }
  accept = moonui_file_answer_accept;
  path = moonui_file_answer_path;
  after = (DWORD)moonui_file_answer_after_ms;
  moonui_file_answer_after_ms = -1;
  moonui_file_answer_accept = 0;
  moonui_file_answer_path = 0;
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
  thread = CreateThread(0, 0, moonui_file_answer_worker, a, 0, &tid);
  if (thread == 0) {
    free(a->caption);
    free(a);
    return;
  }
  /* 和 moonui_start_dismissor 同一行注释：主线程马上要进模态循环，不能 join；
   * CloseHandle 只关掉本线程自己的句柄，线程对象在它跑完之前都还在。 */
  CloseHandle(thread);
}

/* 三种形态共用的一段：建 COM 对话框、设选项、跑 Show 的模态循环、把结果存进
 * moonui_file_result。 */
static int moonui_run_file_panel(const char *title,
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
  t = moonui_utf16_of(title, title_len);
  if (t == 0) {
    return -1;
  }
  if (default_name != 0) {
    d = moonui_utf16_of(default_name, default_name_len);
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
  free(moonui_file_result);
  moonui_file_result = 0;
  moonui_claim_file_answer(dialog, t);
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
        char *u = moonui_utf8_of(p);
        if (u != 0) {
          moonui_file_result = moonui_dup(u, (int)strlen(u));
          free(u);
        }
        CoTaskMemFree(p);
      }
      item->lpVtbl->Release(item);
    }
    /* 选了东西但路径没拿到：属于"面板状态不对"，同 mac 归 -2。 */
    if (moonui_file_result != 0) {
      rc = 1;
    }
  }
  dialog->lpVtbl->Release(dialog);
  free(t);
  free(d);
  return rc;
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

/* 取走结果：返回值是当场拷进 MoonBit 堆的一份（GC 回收，那边不用 free），内部
 * 指针顺带清空。没结果时给空 bytes。和 mac 那份逐字一致。 */
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
 * 为什么这里自己搭 HMENU 而不是用 libui 的菜单 API，理由全在 adapter.h（一句话版：
 * 窗口过程把不认识的 WM_COMMAND 一律交给 runMenuEvent，那里对未知 id 直接
 * DebugBreak，见 windows/menu.cpp:296，而我们的 id 是 Core 的编号、libui 的账本里没有）。
 * Win32 这一侧的实现形状：
 *   - 菜单位是**逐窗口**的（libui 自己也是每只窗口 makeMenubar() 一份，
 *     windows/window.cpp:554），所以"装一棵"= 给当下每只活窗口各建一棵 HMENU，并把树
 *     本身留下，之后新建的窗口照着再建一棵。活窗口记在 moonui_win_menu 这张定长表里：
 *     moonui_window_new 登记、moonui_window_destroy 摘掉。表满了只是"这只窗口没有菜单位"，
 *     窗口本身照建（64 只对 Demo 和测试都远够用）。
 *   - 命令 id = Core 的 id + MOONUI_MENU_ID_BASE。基址避开 libui 自己那批（它的从 100 起，
 *     windows/menu.cpp:11）和控件那批（attach 时发 1000+，见 moonui_control_attach）。
 *     WM_COMMAND 只带 16 位 id，所以越界在装之前就当场报 -1，不许留到点击时变成
 *     "消息发出去了、回调没跑"。
 *   - libui 的窗口过程把 lParam==0 且 HIWORD(wParam)==0 的命令一律当菜单消息
 *     （windows/window.cpp:93-101），我们那棵发上来的正好满足这个条件，会原样落到
 *     runMenuEvent。所以子类化窗口过程，只把"命中我们基址"的那一条截下来报给 MoonBit，
 *     其余全部转给登记时抄下来的那一份——控件的 BN_CLICKED / EN_CHANGE 一个字都不动。
 *     用经典子类化（GWLP_WNDPROC + CallWindowProcW）而不是 SetWindowSubclass：这里只需要
 *     在窗口过程前面加一层，装拆各一次调用就干净了，不必再多一套子类管理。
 *   - role（Normal/Check/Radio）存在条目的 dwItemData 上。状态位里的 MF_CHECKED 分不清
 *     Check 和 Radio（没勾的 Check 项两个位都没有），而快照要分得开 c/r——和 mac 那边把
 *     role 存在 representedObject 上同一件事，读的都是条目自己的状态。
 *   - 装完把菜单位挤掉的客户区高度还给 Core，还给多少是量出来的（摘掉量一次、挂上再量
 *     一次；不同 DPI、不同菜单字体下 SM_CYMENU 不等于实际行高），而且走 libui 自己的
 *     uiWindowSetContentSize：它把 changingSize 立起来，于是这次补偿不会冒出一条 Core
 *     没要求的尺寸变化事件（windows/window.cpp:368-375）。
 */

#define MOONUI_MENU_ID_BASE 0x4000
#define MOONUI_MENU_WINDOWS 64

typedef struct {
  HWND hwnd;
  uiWindow *win;
  WNDPROC prev_proc;
  HMENU bar;
  /* "Core 要的客户区高度"和"libui 以为的客户区高度"之间差的那一行。knows_bar 为真时
   * 恒为 0：libui 每次换算都现量当下挂着的那棵，本来就带着这一行。 */
  int menu_pad;
  int knows_bar;
} MoonuiWindowMenu;

static MoonuiWindowMenu moonui_win_menu[MOONUI_MENU_WINDOWS];

/* 点击回调是进程全局的一份，不占 moonui_slots 那张表：它不属于任何一个 owner，而那张表
 * 是按"一个控件一格"设计的。closure 照样要 incref——Win32 只存函数指针，GC 看不见它。 */
static moonui_closure_id_fn moonui_menu_fn = 0;
static void *moonui_menu_closure = 0;

/* 当下这棵树的原样副本（布局见 adapter.h），新建窗口照着它再建一棵 HMENU；
 * moonui_menu_top_count 是装的时候试建那棵数出来的顶层数，0 = 没有菜单位。 */
static char *moonui_menu_tree = 0;
static int moonui_menu_tree_len = 0;
static int moonui_menu_top_count = 0;

/* 登记时抄下来的 libui 自己那份窗口过程。所有顶层窗口共用本进程注册的同一个窗口类
 * （windows/window.cpp 的 registerWindowClass），所以这一个值对所有登记项都是同一个函数；
 * 它只当兜底用，正常路径每次都用自己那一格的 prev_proc。 */
static WNDPROC moonui_menu_orig_proc = 0;

/* ---- 打包树的读游标（布局见 adapter.h，和 mac 那一份逐字段同形）---- */

typedef struct {
  const unsigned char *p;
  int len;
  int pos;
  int bad;
} MoonuiTree;

static void moonui_tree_init(MoonuiTree *t, const char *bytes, int len) {
  t->p = (const unsigned char *)bytes;
  t->len = len;
  t->pos = 0;
  t->bad = 0;
}

static int moonui_tree_u8(MoonuiTree *t) {
  if (t->bad || t->pos + 1 > t->len) {
    t->bad = 1;
    return 0;
  }
  return (int)t->p[t->pos++];
}

/* 小端 i32。四个字节齐了才动 pos，越界的那一步整体作废（bad 一旦为真就不再翻案）。 */
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

/* i32 长度 + UTF-8 → UTF-16（malloc，调用方 free）。转不出来也算读坏：树是 MoonBit
 * `@utf8.encode` 出来的，坏字节只可能是布局和 adapter.h 对不上，那正是 -1 要报的东西。 */
static LPWSTR moonui_tree_wstr(MoonuiTree *t) {
  int n;
  LPWSTR w;
  if (t->bad) {
    return 0;
  }
  n = moonui_tree_i32(t);
  if (t->bad || n < 0 || t->pos + n > t->len) {
    t->bad = 1;
    return 0;
  }
  w = moonui_utf16_of((const char *)(t->p + t->pos), n);
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
static LPWSTR moonui_menu_item_text(LPCWSTR label, int has_sc, int mods,
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
static int moonui_menu_append_item(HMENU menu, MoonuiTree *t) {
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
  label = moonui_tree_wstr(t);
  item_id = moonui_tree_i32(t);
  role = moonui_tree_u8(t);
  checked = moonui_tree_u8(t);
  enabled = moonui_tree_u8(t);
  has_sc = moonui_tree_u8(t);
  if (has_sc != 0) {
    mods = moonui_tree_u8(t);
    key = moonui_tree_wstr(t);
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
  text = moonui_menu_item_text(label, has_sc, mods, key);
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
static int moonui_menu_fill(HMENU menu, MoonuiTree *t, int count) {
  int i;
  for (i = 0; i < count; ++i) {
    int kind = moonui_tree_u8(t);
    if (t->bad) {
      return 0;
    }
    if (kind == 0) {
      if (!moonui_menu_append_item(menu, t)) {
        return 0;
      }
    } else if (kind == 1) {
      if (AppendMenuW(menu, MF_SEPARATOR, 0, 0) == 0) {
        t->bad = 1;
        return 0;
      }
    } else if (kind == 2) {
      LPWSTR label = moonui_tree_wstr(t);
      int sub_count = moonui_tree_i32(t);
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
      if (!moonui_menu_fill(sub, t, sub_count)) {
        free(label);
        DestroyMenu(sub);
        return 0;
      }
      /* 子菜单挂在父条目上就是 MF_POPUP + 句柄当值（libui 自己同形，
       * windows/menu.cpp:272-274）。 */
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
static HMENU moonui_menu_build(MoonuiTree *t) {
  HMENU bar;
  int count;
  int i;
  bar = CreateMenu();
  if (bar == 0) {
    return 0;
  }
  if (moonui_tree_u8(t) != 1) {
    DestroyMenu(bar);
    return 0;
  }
  count = moonui_tree_i32(t);
  if (t->bad || count < 0) {
    DestroyMenu(bar);
    return 0;
  }
  for (i = 0; i < count; ++i) {
    LPWSTR label = moonui_tree_wstr(t);
    int node_count = moonui_tree_i32(t);
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
    if (!moonui_menu_fill(sub, t, node_count)) {
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

static MoonuiWindowMenu *moonui_menu_entry_of(HWND hwnd) {
  int i;
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_win_menu[i].hwnd == hwnd) {
      return &moonui_win_menu[i];
    }
  }
  return 0;
}

static MoonuiWindowMenu *moonui_menu_free_slot(void) {
  int i;
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_win_menu[i].hwnd == 0) {
      return &moonui_win_menu[i];
    }
  }
  return 0;
}

/* 子类化之后的窗口过程。只截"命中我们基址的菜单命令"，其余原样转给登记的那一份。
 * 控件发上来的 WM_COMMAND 一律带 lParam=控件句柄，所以这里不会把 BN_CLICKED/EN_CHANGE
 * 错当成菜单；IDOK/IDCANCEL（IsDialogMessage 按 Enter/Esc 合成的那两条）在基址之下，
 * 照样留给 libui 自己处理（它正是要吞掉那两条的）。 */
static LRESULT CALLBACK moonui_menu_wndproc(HWND hwnd, UINT msg, WPARAM wParam,
                                            LPARAM lParam) {
  MoonuiWindowMenu *e;
  WNDPROC prev;
  e = moonui_menu_entry_of(hwnd);
  if (msg == WM_COMMAND && lParam == 0 && HIWORD(wParam) == 0) {
    int id = (int)LOWORD(wParam) - MOONUI_MENU_ID_BASE;
    if (id >= 0) {
      if (moonui_menu_fn != 0 && moonui_menu_closure != 0) {
        moonui_menu_fn(moonui_menu_closure, id);
      }
      return 0;
    }
  }
  prev = e != 0 ? e->prev_proc : moonui_menu_orig_proc;
  if (prev == 0) {
    /* 只可能是登记项已经作废（unregister 排在 uiControlDestroy 之前，那时窗口过程已经
     * 换回去了），这里不是正常路径；交给默认过程，总好过转一个空指针。 */
    return DefWindowProcW(hwnd, msg, wParam, lParam);
  }
  return CallWindowProcW(prev, hwnd, msg, wParam, lParam);
}

/* 给一只窗口换上 bar（0 = 摘掉），并把菜单位挤掉的客户区高度还给 Core。
 *
 * 行高不抄 SM_CYMENU：先全摘、量一次，再挂上、量一次，两次之间唯一的变量就是"挂着没
 * 挂着"，差值才是这一行真正占掉多少。挂上之后要是 SetMenu 没成功，第二次量出来的还是
 * "没有菜单位"那一个数，row 因此是 0、补偿也不做，而快照读回来的是系统当下真正挂着的
 * 那棵——失败会红在断言上，不会变成一处悄悄偏矮的布局。
 *
 * 摘掉再挂新的，中间那一步顺带把 libui 建窗口时给的菜单位也卸了。换下来的菜单不会随窗口
 * 销毁（窗口只销毁当时还挂着的那棵），而 libui 记账用的 w->menubar 之后只会被
 * freeMenubar 碰一次，那个函数遍历的是 uiNewMenu 建过的菜单表、我们一个都没建过，于是
 * 整段不循环、不会再解引用这个句柄（windows/menu.cpp:327-343）。该拆就拆，留着是每只
 * 窗口漏一只句柄。 */
static void moonui_menu_apply(MoonuiWindowMenu *e, HMENU bar) {
  RECT c0;
  RECT c_no;
  RECT c_yes;
  HMENU prev;
  int width;
  int height;
  int row;
  GetClientRect(e->hwnd, &c0);
  width = c0.right - c0.left;
  height = c0.bottom - c0.top;
  prev = GetMenu(e->hwnd);
  SetMenu(e->hwnd, 0);
  GetClientRect(e->hwnd, &c_no);
  if (prev != 0 && prev != bar) {
    DestroyMenu(prev);
  }
  if (bar != 0) {
    if (e->prev_proc == 0) {
      e->prev_proc = (WNDPROC)(LONG_PTR)SetWindowLongPtrW(
          e->hwnd, GWLP_WNDPROC, (LONG_PTR)moonui_menu_wndproc);
      moonui_menu_orig_proc = e->prev_proc;
    }
    SetMenu(e->hwnd, bar);
  } else if (e->prev_proc != 0) {
    /* 没有菜单位也就没有要截的 WM_COMMAND，窗口过程当场换回去。 */
    SetWindowLongPtrW(e->hwnd, GWLP_WNDPROC, (LONG_PTR)e->prev_proc);
    e->prev_proc = 0;
  }
  e->bar = bar;
  GetClientRect(e->hwnd, &c_yes);
  row = (c_no.bottom - c_no.top) - (c_yes.bottom - c_yes.top);
  e->menu_pad = e->knows_bar ? 0 : row;
  if ((c_yes.bottom - c_yes.top) != height) {
    uiWindowSetContentSize(e->win, width, height + e->menu_pad);
  }
}

/* 照存下来的那棵树给这只窗口现建一棵挂上；没装过菜单、或者装的是空的一棵 → 摘掉。 */
static void moonui_menu_refresh(MoonuiWindowMenu *e) {
  HMENU bar = 0;
  if (moonui_menu_tree != 0 && moonui_menu_top_count > 0) {
    MoonuiTree t;
    moonui_tree_init(&t, moonui_menu_tree, moonui_menu_tree_len);
    bar = moonui_menu_build(&t);
    if (bar == 0) {
      /* 同一份字节第二次读坏，只可能是我们自己把副本写坏了。这一只窗口就不挂菜单，
       * 不把半棵树端上去。 */
      return;
    }
  }
  moonui_menu_apply(e, bar);
}

static int moonui_menu_wanted(void) {
  return moonui_menu_tree != 0 && moonui_menu_top_count > 0;
}

static void moonui_menu_register(uiWindow *win, HWND hwnd) {
  MoonuiWindowMenu *e = moonui_menu_free_slot();
  if (e == 0) {
    return;
  }
  e->hwnd = hwnd;
  e->win = win;
  e->bar = 0;
  e->prev_proc = 0;
  e->menu_pad = 0;
  /* 问系统要，而不是回头读自己传给 uiNewWindow 的那一位：这一位要钉的就是"libui 以为
   * 这里有没有菜单位"，事后它要是换了主意，这里跟着现实走。 */
  e->knows_bar = GetMenu(hwnd) != 0;
  moonui_menu_refresh(e);
}

static void moonui_menu_unregister(HWND hwnd) {
  MoonuiWindowMenu *e = moonui_menu_entry_of(hwnd);
  if (e == 0) {
    return;
  }
  if (e->prev_proc != 0) {
    SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)e->prev_proc);
  }
  if (e->bar != 0) {
    SetMenu(hwnd, 0);
    DestroyMenu(e->bar);
  }
  e->hwnd = 0;
  e->win = 0;
  e->bar = 0;
  e->prev_proc = 0;
  e->menu_pad = 0;
  e->knows_bar = 0;
}

static void moonui_menu_drop_closure(void) {
  if (moonui_menu_closure != 0) {
    moonbit_decref(moonui_menu_closure);
    moonui_menu_closure = 0;
  }
  moonui_menu_fn = 0;
}

static void moonui_menu_clear_all(void) {
  int i;
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_win_menu[i].hwnd != 0) {
      moonui_menu_unregister(moonui_win_menu[i].hwnd);
    }
  }
  free(moonui_menu_tree);
  moonui_menu_tree = 0;
  moonui_menu_tree_len = 0;
  moonui_menu_top_count = 0;
  moonui_menu_orig_proc = 0;
  moonui_menu_drop_closure();
}

static int moonui_menu_pad_of(HWND hwnd) {
  MoonuiWindowMenu *e = moonui_menu_entry_of(hwnd);
  return e == 0 ? 0 : e->menu_pad;
}

/* ---- 两条对外入口 ---- */

int moonui_set_menu_bar(const char *tree,
                        int tree_len,
                        moonui_closure_id_fn fn,
                        void *closure) {
  MoonuiTree t;
  HMENU probe;
  char *copy;
  int i;
  TRACE("set_menu_bar");
  if (!moonui_inited) {
    return -2;
  }
  /* 最短的合法树是 version(1 字节) + count(i32)，空的也行：那就是"把菜单拆掉"。 */
  if (tree == 0 || tree_len < 5) {
    return -1;
  }
  /* 先照布局试建一棵，只为验证读得动（每窗口那一棵在下面按副本现建）。试建不过就原样
   * 退回：旧的菜单、旧的那份树、旧的回调都一动不动（adapter.h 的"装了一半比装不上难
   * 查"）。这条 -1 从 MoonBit 走不到——序列化器每次都产一棵合法的树，所以它是给
   * "布局和 adapter.h 对不上"这种我们自己的 bug 留的（TODO 的 `T38` 记的就是这一类）。 */
  moonui_tree_init(&t, tree, tree_len);
  probe = moonui_menu_build(&t);
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
  free(moonui_menu_tree);
  moonui_menu_tree = copy;
  moonui_menu_tree_len = tree_len;
  moonui_menu_top_count = GetMenuItemCount(probe);
  DestroyMenu(probe);
  moonui_menu_drop_closure();
  moonui_menu_fn = fn;
  if (closure != 0) {
    moonbit_incref(closure);
    moonui_menu_closure = closure;
  }
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_win_menu[i].hwnd != 0) {
      moonui_menu_refresh(&moonui_win_menu[i]);
    }
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

static int moonui_menu_find_in(HMENU menu, UINT wID, MoonuiMenuHit *out) {
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
      if (moonui_menu_find_in(mi.hSubMenu, wID, out)) {
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
static int moonui_menu_is_grayed(UINT ftype, UINT fstate) {
  return ((ftype | fstate) & (MF_GRAYED | MF_DISABLED)) != 0;
}

/* 把勾选态推给**当下每一只**窗口挂的那棵：§25 是一棵逻辑菜单，Win32 却是逐窗口的，
 * 只推"最后开的那只"就会留下两扇窗显示不同的勾选。
 * 一条都没找到才报 -1（没装过菜单，或者装的树里没有这一项）。 */
int moonui_menu_item_set_checked(int id, int checked) {
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
    HWND hwnd = moonui_win_menu[i].hwnd;
    HMENU bar;
    if (hwnd == 0 || !IsWindow(hwnd)) {
      continue;
    }
    bar = GetMenu(hwnd);
    if (bar == 0) {
      continue;
    }
    if (!moonui_menu_find_in(bar, wID, &hit)) {
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
        (moonui_menu_is_grayed(hit.ftype, hit.fstate) ? MF_GRAYED : MF_ENABLED) |
        (checked != 0 ? MF_CHECKED : MF_UNCHECKED);
    if (SetMenuItemInfoW(hit.menu, wID, FALSE, &mi) != 0) {
      ++hits;
    }
  }
  return hits > 0 ? 0 : -1;
}

/* ---- 测试脚手架（格式和"为什么两边逐字符一致"都在 adapter.h）---- */

/* 读哪一只窗口：倒着找最后一只还活着、且系统里真挂着菜单的登记窗口（测试总是用最后开的
 * 那一只）。判据用 GetMenu 而不是自己记的 e->bar——这根快照和这条点击要钉的就是"真的
 * 挂上了"：只抄自己那份名单的话，SetMenu 整段删掉也照样绿。
 * 没有活窗口就什么都读不出来，报空（mac 那边主菜单是进程全局的，没有这一条）。 */
static HWND moonui_menu_target_window(void) {
  int i;
  for (i = MOONUI_MENU_WINDOWS - 1; i >= 0; --i) {
    HWND hwnd = moonui_win_menu[i].hwnd;
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

static void moonui_dump_reserve(MoonuiDump *d, int need) {
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

static void moonui_dump_putc(MoonuiDump *d, char c) {
  moonui_dump_reserve(d, 1);
  if (d->bad) {
    return;
  }
  d->p[d->len++] = c;
  d->p[d->len] = '\0';
}

static void moonui_dump_puts(MoonuiDump *d, const char *s) {
  int n = (int)strlen(s);
  moonui_dump_reserve(d, n);
  if (d->bad) {
    return;
  }
  memcpy(d->p + d->len, s, (size_t)n);
  d->len += n;
  d->p[d->len] = '\0';
}

static void moonui_dump_putwn(MoonuiDump *d, LPCWSTR w, int n) {
  int needed;
  if (d->bad || w == 0 || n <= 0) {
    return;
  }
  needed = WideCharToMultiByte(CP_UTF8, 0, w, n, 0, 0, 0, 0);
  if (needed <= 0) {
    d->bad = 1;
    return;
  }
  moonui_dump_reserve(d, needed);
  if (d->bad) {
    return;
  }
  WideCharToMultiByte(CP_UTF8, 0, w, n, d->p + d->len, needed, 0, 0);
  d->len += needed;
  d->p[d->len] = '\0';
}

static void moonui_dump_putw(MoonuiDump *d, LPCWSTR w) {
  moonui_dump_putwn(d, w, w == 0 ? 0 : lstrlenW(w));
}

static void moonui_dump_puti(MoonuiDump *d, int v) {
  char buf[16];
  int i = 0;
  unsigned int u;
  if (v < 0) {
    moonui_dump_putc(d, '-');
    u = (unsigned int)(-(v + 1)) + 1u;
  } else {
    u = (unsigned int)v;
  }
  do {
    buf[i++] = (char)('0' + (int)(u % 10u));
    u /= 10u;
  } while (u != 0);
  while (i > 0) {
    moonui_dump_putc(d, buf[--i]);
  }
}

/* 这一段是不是四个修饰键名之一（按我们写进去的那种大小写比）。 */
static int moonui_dump_mod_bit(LPCWSTR s, int n) {
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

/* <sc> 那一栏：把标题里 \t 之后那段拆回来（拼法见上面 moonui_menu_item_text）。读的是
 * 原生项自己的文案，所以它证明的是"组合真的落到了菜单项上"。没有 \t 就是 "."。
 * 功能键 mac 落不下去、这边落得下去，于是同一个 `Shortcut::new("F5")` mac 报 "."、这里
 * 报 "-F5"（adapter.h 明写的分叉，测试因此只用两边都认的组合）。
 * 单个字母收小写，和 mac 那一份对齐：那边读的是 keyEquivalent，字母本来就存着小写。 */
static void moonui_dump_combo(MoonuiDump *d, LPCWSTR text) {
  LPCWSTR tail = text;
  LPCWSTR key = 0;
  int mods = 0;
  int i;
  const char *letters = "CASM";
  if (text == 0) {
    moonui_dump_puts(d, ".");
    return;
  }
  while (*tail != L'\0' && *tail != L'\t') {
    ++tail;
  }
  if (*tail == L'\0') {
    moonui_dump_puts(d, ".");
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
    bit = moonui_dump_mod_bit(tail, n);
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
    moonui_dump_putc(d, '-');
  }
  for (i = 0; i < 4; ++i) {
    if (mods & (1 << i)) {
      moonui_dump_putc(d, letters[i]);
    }
  }
  if (lstrlenW(key) == 1 && key[0] >= L'A' && key[0] <= L'Z') {
    moonui_dump_putc(d, (char)(key[0] + (L'a' - L'A')));
  } else {
    moonui_dump_putw(d, key);
  }
}

static void moonui_dump_nodes(MoonuiDump *d, HMENU menu);

/* 一节：分隔线 "-"，子菜单 "+label{…}"，可点项
 * "#<id>:<role><check><enabled>:<label>:<sc>"。id 减回基址才是 Core 的那个编号。
 * 文案缓冲 256 个 WCHAR，超了就截断——这根文本只给人和测试读，测试里的标签远短于此；
 * 截断只会让断言红，不会让哪一项凭空消失。 */
static void moonui_dump_node(MoonuiDump *d, HMENU menu, int index) {
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
    moonui_dump_puts(d, "-");
    return;
  }
  if ((mi.fType & MF_POPUP) != 0) {
    moonui_dump_puts(d, "+");
    moonui_dump_putw(d, text);
    moonui_dump_puts(d, "{");
    moonui_dump_nodes(d, mi.hSubMenu);
    moonui_dump_puts(d, "}");
    return;
  }
  label_len = 0;
  while (text[label_len] != L'\0' && text[label_len] != L'\t') {
    ++label_len;
  }
  role = (int)mi.dwItemData;
  moonui_dump_puts(d, "#");
  moonui_dump_puti(d, (int)mi.wID - MOONUI_MENU_ID_BASE);
  moonui_dump_puts(d, ":");
  moonui_dump_putc(d, role == 1 ? 'c' : (role == 2 ? 'r' : 'n'));
  if (role == 0) {
    moonui_dump_putc(d, '.');
  } else {
    moonui_dump_putc(d, ((mi.fType | mi.fState) & MF_CHECKED) != 0 ? '+' : '-');
  }
  moonui_dump_putc(d, moonui_menu_is_grayed(mi.fType, mi.fState) ? 'd' : 'e');
  moonui_dump_puts(d, ":");
  moonui_dump_putwn(d, text, label_len);
  moonui_dump_puts(d, ":");
  moonui_dump_combo(d, text);
}

/* 一层里的条目，逗号相连。顶层不走这一节（顶层在快照里没有 "+" 前缀）。 */
static void moonui_dump_nodes(MoonuiDump *d, HMENU menu) {
  int i;
  int n;
  if (menu == 0) {
    return;
  }
  n = GetMenuItemCount(menu);
  for (i = 0; i < n; ++i) {
    if (i > 0) {
      moonui_dump_puts(d, ",");
    }
    moonui_dump_node(d, menu, i);
  }
}

/* 整棵菜单位：顶层之间用 ";" 相连，每顶 = label{条目,…}。逐顶按位置取，因为 Win32 的
 * 顶层项挂的是子菜单句柄、没有 id 可查。 */
static void moonui_dump_bar(MoonuiDump *d, HMENU bar) {
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
      moonui_dump_puts(d, ";");
    }
    if (GetMenuItemInfoW(bar, (UINT)i, TRUE, &mi) == 0) {
      continue;
    }
    moonui_dump_putw(d, text);
    moonui_dump_puts(d, "{");
    moonui_dump_nodes(d, mi.hSubMenu);
    moonui_dump_puts(d, "}");
  }
}

/* 只给测试用：把当下挂在窗口上的那棵截成一根文本（格式在 adapter.h）。读的是 GetMenu
 * 给回来的那棵，不是自己记的 e->bar——见上面 moonui_menu_target_window。 */
moonbit_bytes_t moonui_menu_dump(void) {
  MoonuiDump d;
  HWND hwnd;
  moonbit_bytes_t out;
  TRACE("menu_dump");
  d.p = 0;
  d.len = 0;
  d.cap = 0;
  d.bad = 0;
  hwnd = moonui_menu_target_window();
  if (hwnd == 0) {
    return moonbit_make_bytes(0, 0);
  }
  moonui_dump_bar(&d, GetMenu(hwnd));
  if (d.p == 0 || d.bad || d.len == 0) {
    free(d.p);
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_bytes_of(d.p);
  free(d.p);
  return out;
}

/* 只给测试用：等价于"用户在原生菜单里点了 id 这一项"。发的是 WM_COMMAND，进的是我们
 * 子类化后的那个窗口过程——和真人从菜单里点下去之后完全同一条路，不是把 MoonBit 的回调
 * 直接调一遍。用 SendMessage 而不是 PostMessage 是因为这条的契约是"回调在本次调用里已经
 * 跑过"（adapter.h），投递的那一条要等下一次循环才醒。
 * 置灰的那一项在这里先拦下来：mac 那份 `performActionForItemAtIndex:` 自己就尊重
 * isEnabled，而这里的消息绕过置灰，不拦就成了"什么也没发生但报 0"。 */
int moonui_menu_click_item(int id) {
  MoonuiMenuHit hit;
  HWND hwnd;
  UINT wID;
  TRACE("menu_click_item");
  if (id < 0 || id > 0xFFFF - MOONUI_MENU_ID_BASE) {
    return -1;
  }
  hwnd = moonui_menu_target_window();
  if (hwnd == 0) {
    return -1;
  }
  wID = (UINT)(id + MOONUI_MENU_ID_BASE);
  if (!moonui_menu_find_in(GetMenu(hwnd), wID, &hit)) {
    return -1;
  }
  if (moonui_menu_is_grayed(hit.ftype, hit.fstate)) {
    return -2;
  }
  /* lParam=0（不是控件）+ HIWORD(wParam)=0（不是通知码）——和菜单自己发上来的那条
   * 一模一样，于是回调在本次调用里就跑了。 */
  SendMessageW(hwnd, WM_COMMAND, (WPARAM)wID, 0);
  return 0;
}

/* ---- 键盘与焦点（§32 / §48-16，T39）---- */

/* 词表在 adapter.h 的键盘那一节，两份 C 必须给同一套字符串。这张表只列"名字不等于
 * 字符自己"的那些键：字母和数字直接由 VK 码得出（Windows 的 VK_A..VK_Z、VK_0..VK_9
 * 和 ASCII 同值），空格单独一个名字。mac 那份同样位置写的是 NSFunctionKey 那批码元，
 * 两边共用的只有名字这一列。Insert 只有 Windows 的键盘真有，mac 那张表里没有它。 */
typedef struct {
  const char *name;
  WORD code;
} MoonuiSpecialKey;

static const MoonuiSpecialKey moonui_special_keys[] = {
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
static HHOOK moonui_key_hook = 0;

/* 进程级那一份槽位。owner 用自己的地址当哨兵：全进程唯一，永远不会和某个 uiControl*
 * 撞上（和 mac 那份同一个写法）。 */
static char moonui_key_slot_owner;
static int moonui_key_slot = -1;

/* 一颗键的快照：钩子只说"有颗键出事了"，内容全部由 MoonBit 当场读回去（§48-16）。
 * 写它的时机在调闭包之前，闭包返回之后没人再动，所以一次通知配一次读、中间插不进第二颗
 * 键。target 为 0 表示这颗键不属于我们任何窗口/控件。 */
static moonui_ptr moonui_key_target_ptr = 0;
static int moonui_key_down = 0;
static int moonui_key_mods = 0;
static char moonui_key_snapshot_name[32];

/* 修饰键位（bit0 ctrl、bit1 alt、bit2 shift、bit3 meta，和 §25 那棵树里组合那一栏同一个
 * 编码）。mac 从事件自己的 modifierFlags 现读；Windows 的 WM_KEYDOWN 没带 ctrl/shift
 * （lParam 里只有 bit29 那一位 Alt 上下文），而 GetKeyState 归的是"当前前台那套键盘"
 * 的账——测试进程没有前台，用它读出来的组合跟着激活时序漂。所以这里自己跟：系统给修饰键
 * 按下/抬起同样投一条 WM_KEYDOWN/WM_KEYUP 到有焦点的窗口，把这几颗数出来就是这颗键发生
 * 当下的组合。 */
static int moonui_mod_count[4] = {0, 0, 0, 0};

static const WORD moonui_mod_vk[4] = {VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN};

/* 这颗 VK 是修饰键吗？是的话归到哪一位（左右两只物理键共享一位：mac 的
 * modifierFlags 也只给一位）。 */
static int moonui_mod_slot_of(WPARAM vk) {
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

static void moonui_mod_update(WPARAM vk, int down) {
  int i = moonui_mod_slot_of(vk);
  if (i < 0) {
    return;
  }
  if (down) {
    if (moonui_mod_count[i] < 4) {
      ++moonui_mod_count[i];
    }
  } else if (moonui_mod_count[i] > 0) {
    --moonui_mod_count[i];
  }
}

/* 按着左 Shift 再松开右 Shift 不该把 shift 那位清掉，所以数的是"这一组里还有几颗按着"。
 * 上界 4 挡的是"两条抬起夹着一条按下"这种不该发生的序列：宁可少算也不许算出负数。 */
static int moonui_mods_of_state(void) {
  int mods = 0;
  int i;
  for (i = 0; i < 4; ++i) {
    if (moonui_mod_count[i] > 0) {
      mods |= (1 << i);
    }
  }
  return mods;
}

static void moonui_mod_reset(void) {
  int i;
  for (i = 0; i < 4; ++i) {
    moonui_mod_count[i] = 0;
  }
}

static const MoonuiSpecialKey *moonui_key_row_of_code(WORD code) {
  size_t i;
  for (i = 0; i < MOONUI_N(moonui_special_keys); ++i) {
    if (moonui_special_keys[i].code == code) {
      return &moonui_special_keys[i];
    }
  }
  return 0;
}

/* 把这颗键的名字写进 out（最长 "Backspace"，缓冲 32 绰绰有余）。词表以外留空串，
 * MoonBit 据此丢掉这颗键——宁可不产事件，也不产一个 Core 匹配不到的名字。修饰键自己不
 * 在词表里，所以按 Ctrl 本身不产事件，只改上面那四位。 */
static void moonui_key_read_name(WPARAM vk, char *out) {
  const MoonuiSpecialKey *row;
  out[0] = '\0';
  if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) {
    out[0] = (char)vk;
    out[1] = '\0';
    return;
  }
  if (vk == VK_SPACE) {
    strcpy(out, "Space");
    return;
  }
  row = moonui_key_row_of_code((WORD)vk);
  if (row != 0) {
    strcpy(out, row->name);
  }
}

/* 词表里的名字 → VK，只给合成脚手架用。0 = 不在词表里，脚手架据此报 -4，绝不"随便按
 * 一颗"——按错键的测试是一条假绿。单字符名一律折成小写，所以调用方写 "S" 和 "s" 是
 * 同一颗键。 */
static int moonui_key_lookup(const char *name, WORD *vk_out) {
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
  for (i = 0; i < MOONUI_N(moonui_special_keys); ++i) {
    if (strcmp(moonui_special_keys[i].name, name) == 0) {
      *vk_out = moonui_special_keys[i].code;
      return 1;
    }
  }
  return 0;
}

/* 本线程当下"焦点在谁身上"。GetFocus 只认调用线程的输入队列，而 MoonBit 的 FFI 调用
 * 和消息循环跑在同一个线程上，所以这里问得到自己那次 SetFocus 的结果；进程不在前台时
 * GetFocus 也可能给 0（键盘焦点归前台那个线程），同一线程的 GUITHREADINFO 还留着记录，
 * 于是两条都问一遍。哪一条在这台机器上真给得出数，由 Windows 那边量（T46）。 */
static HWND moonui_thread_focus(void) {
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
 * 窗口级那一档归 KeyDown 的归属判断管，所以这里到 root 之前就要收口）。libui 把控件
 * 包在中间层窗口里时（容器那类），第一个打过标记的祖先才是要的那个。 */
static moonui_ptr moonui_focus_owner_of(HWND root) {
  HWND f = moonui_thread_focus();
  HWND cur;
  moonui_ptr owner;
  if (root == 0 || f == 0 || f == root ||
      GetAncestor(f, GA_ROOT) != root) {
    return 0;
  }
  for (cur = f; cur != 0 && cur != root; cur = GetParent(cur)) {
    owner = moonui_owner_of(cur);
    if (owner != 0) {
      return owner;
    }
  }
  return 0;
}

/* 这颗键该算给谁：消息自己的 hwnd 往上退，第一个打过标记的。焦点在我们控件上时是那个
 * 控件，否则算这只窗口自己（焦点在窗口、在 libui 的中间层窗口上都算"键给了这只窗口"）；
 * 连窗口都不是我们的（例如别的进程的键）报 0，MoonBit 据此丢弃事件。 */
static moonui_ptr moonui_key_owner_of_msg(MSG *m) {
  HWND cur;
  moonui_ptr owner;
  for (cur = m->hwnd; cur != 0; cur = GetParent(cur)) {
    owner = moonui_owner_of(cur);
    if (owner != 0) {
      return owner;
    }
  }
  return 0;
}

static LRESULT CALLBACK moonui_key_hook_proc(int code, WPARAM wParam,
                                             LPARAM lParam) {
  MSG *m;
  int down;
  moonui_ptr target;
  if (code >= 0 && wParam == TRUE) {
    /* wParam 是"这条消息是不是正被取走"：moonui_messages_pending 用 PM_NOREMOVE 探测，
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
      moonui_mod_update(m->wParam, down);
      if (moonui_key_slot >= 0) {
        target = moonui_key_owner_of_msg(m);
        if (target != 0) {
          moonui_key_target_ptr = target;
          moonui_key_down = down;
          moonui_key_mods = moonui_mods_of_state();
          moonui_key_read_name(m->wParam, moonui_key_snapshot_name);
          moonui_fire(&moonui_slots[moonui_key_slot]);
        }
      }
    }
  }
  return CallNextHookEx(moonui_key_hook, code, wParam, lParam);
}

int moonui_on_key(moonui_closure_fn fn, void *closure) {
  int slot;
  TRACE("on_key");
  slot = moonui_take_slot((void *)&moonui_key_slot_owner, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_key_slot = slot;
  /* 监听整个进程只挂一份：重复调用到这里就换掉了槽位里的闭包，钩子原样留着。 */
  if (moonui_key_hook != 0) {
    return 0;
  }
  moonui_key_hook = SetWindowsHookExW(WH_GETMESSAGE, moonui_key_hook_proc, 0,
                                      GetCurrentThreadId());
  /* 装不上就把刚占的槽位还掉，让 MoonBit 侧报成显式错误而不是"监听永远不会响"。 */
  if (moonui_key_hook == 0) {
    moonui_forget((void *)&moonui_key_slot_owner, fn);
    moonui_key_slot = -1;
    return -1;
  }
  return 0;
}

/* terminate 的第一件事（见文件顶上的前置声明）。摘掉之后再没有回调会跑，槽位才可以
 * 排干。 */
static void moonui_key_drop_hook(void) {
  if (moonui_key_hook != 0) {
    UnhookWindowsHookEx(moonui_key_hook);
    moonui_key_hook = 0;
  }
  moonui_key_slot = -1;
  moonui_mod_reset();
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
  return moonui_focus_owner_of(moonui_hwnd(w));
}

/* ---- 事件循环 ---- */

void moonui_main_steps(void) {
  TRACE("main_steps");
  uiMainSteps();
}

int moonui_main_step(int wait) {
  TRACE("main_step");
  return uiMainStep(wait);
}

/* PM_NOREMOVE 只探测不取，所以问完还能让 uiMainStep 去处理那条。
 * 为什么不拿 uiMainStep 的返回值当"队列空了"的判据：它处理了一条消息和队列
 * 本来就空着都返回 1，只有 WM_QUIT 才是 0（见 windows/main.cpp 的 peekMessage）。 */
int moonui_messages_pending(void) {
  MSG msg;
  return PeekMessageW(&msg, 0, 0, 0, PM_NOREMOVE) != 0;
}

/* QS_ALLINPUT 把"队列里有新消息"和"该超时了"分开，MoonBit 因此能在不卡死
 * 的前提下等到事件，而不是直接调 uiMainStep(1) 睡进 GetMessage。
 * 用不带 W 后缀的名字：这个 SDK 的 WinUser.h 只声明通用名，由 user32.lib
 * 提供导入项；写 `...ObjectsW` 既没有原型也链不上。
 * 这里的"新"是相对上次唤醒算的：队列里有积压时它照样报超时，所以这个返回值
 * 只能当唤醒用，判断有没有活要干得靠 moonui_messages_pending。 */
int moonui_wait_messages(int ms) {
  TRACE("wait_messages");
  return MsgWaitForMultipleObjects(0, 0, FALSE, (DWORD)ms, QS_ALLINPUT) ==
                 WAIT_TIMEOUT
             ? 0
             : 1;
}

int64_t moonui_time_ms(void) { return (int64_t)GetTickCount64(); }

void moonui_quit(void) {
  TRACE("quit");
  uiQuit();
}

/* ---- 测试脚手架 ---- */

/* 标题 → 窗口标题是唯一的"按身份找回原生对象"的通道，测试够用：
 * MoonBit 侧只拿得到句柄，拿不到 HWND。 */
static HWND moonui_find_window(const char *title, int title_len) {
  char *t;
  WCHAR wtitle[256];
  HWND win;
  t = moonui_dup(title, title_len);
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
 * BM_CLICK 让真的 BUTTON 控件自己发出 BN_CLICKED，于是消息进的是 libui 注册的
 * WM_COMMAND 处理器——和鼠标点下去之后完全同一条路径，不是把回调函数直接调一遍。 */
int moonui_click_button_in_window(const char *title,
                                  int title_len,
                                  int x,
                                  int y) {
  WCHAR cls[64];
  HWND win;
  HWND hit;
  POINT pt;
  TRACE("click_button_in_window");
  win = moonui_find_window(title, title_len);
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
 * 字符、改内容、向父窗口发 WM_COMMAND/EN_CHANGE，libui 的 onWM_COMMAND
 * （windows/entry.cpp:12）再报给我们。
 * 对照组有两条，都不用：EM_REPLACESEL 一次换整段、跳过了字符处理那一层，不是
 * 键盘那条路；SetWindowText 走 uiEntrySetText，被 libui 自己的 inhibitChanged
 * 挡着（windows/entry.cpp:68-75），本来就不该报"用户打了字"。
 * 一个字符一条 EN_CHANGE，所以打 N 个码元来 N 条通知——真键盘本来就这样；macOS
 * 那份把整串一次 insertText:（相当于输入法成串上屏），只来一条。这条差异留在两边
 * 的测试里，MoonBit 侧读不出差别（T18 定下的形状：分叉只在 C）。
 * 返回值和 mac 那份同一套阶梯：0 已送达，-1 编码失败，-2 找不到窗口，
 * -3 命不中子窗口，-4 命中的不是编辑框，-5 命中的是只读编辑框。 */
int moonui_type_text_in_window(const char *title,
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
  chars = moonui_utf16_of(text, text_len);
  if (chars == 0) {
    return -1;
  }
  win = moonui_find_window(title, title_len);
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
int moonui_focus_widget_in_window(const char *title,
                                  int title_len,
                                  int x,
                                  int y) {
  POINT pt;
  HWND win;
  HWND hit;
  HWND up;
  moonui_ptr want;
  TRACE("focus_widget_in_window");
  win = moonui_find_window(title, title_len);
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
  while (up != 0 && up != win && moonui_owner_of(up) == 0) {
    up = GetParent(up);
  }
  if (up == 0 || up == win || moonui_owner_of(up) == 0) {
    return -4;
  }
  want = moonui_owner_of(up);
  SetFocus(up);
  if (moonui_focus_owner_of(win) != want) {
    return -4;
  }
  return 0;
}

/* 等价于"用户在键盘上按了（或抬起了）一颗键"，落点是当下有焦点的那个控件。
 *
 * PostMessage 而不是 SendMessage：WH_GETMESSAGE 挂在"取消息"那一步，SendMessage 是直接
 * 调窗口过程、钩子根本听不见。投递的那一条由事件循环取出来，走的是和真键盘同一道门，
 * 所以回调不在这次调用里跑，而是在下一次 moonui_main_step 取到它时跑——测试因此要先
 * step 再断言（mac 那份是 [NSApp sendEvent:] 同步派发，当场就跑完了；这是两边唯一的时间
 * 差，adapter.h 那条已经写明）。
 * 修饰组合靠的是"先投修饰键自己的按下、再投这颗键"，抬起反过来：钩子那四位数的就是这些
 * 消息（见上面 moonui_mod_count），和人手按出来的序列同一种形状。Alt 那一位在这里有个
 * 坑：DefWindowProc 收到 VK_MENU 的按下会进菜单模式，那是用户桌面上的事，所以 Windows 的
 * 测试只用 ctrl / shift 组合（mac 那边 ⌘ 归 meta，同一个坑不存在）。
 * lParam 只填重复次数 1，状态位（bit29 的 Alt 上下文、抬起的 bit30/31）留 0：读它们的
 * 是"想知道这颗键是不是合成出来的"那一类程序，我们和 libui 都按消息 id 分派。 */
int moonui_send_key_in_window(const char *title,
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
  k = moonui_dup(key, key_len);
  if (k == 0) {
    return -1;
  }
  if (!moonui_key_lookup(k, &vk)) {
    free(k);
    return -4;
  }
  free(k);
  win = moonui_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  /* 归属靠焦点而不是坐标，所以调用方要先用上一条把焦点放好；没放好时这颗键会算到窗口
   * 自己头上，那条断言就成了假绿，所以这里先查、查不到直接报 -3。上面那条已经保证
   * "焦点在这只窗口的某个我们的控件上"，这里的 thread_focus 因此不会是 0。 */
  if (moonui_focus_owner_of(win) == 0) {
    return -3;
  }
  f = moonui_thread_focus();
  if (down != 0) {
    for (i = 0; i < 4; ++i) {
      if ((mods & (1 << i)) != 0) {
        PostMessageW(f, WM_KEYDOWN, (WPARAM)moonui_mod_vk[i], 1);
      }
    }
    PostMessageW(f, WM_KEYDOWN, (WPARAM)vk, 1);
  } else {
    PostMessageW(f, WM_KEYUP, (WPARAM)vk, 0xC0000001L);
    for (i = 3; i >= 0; --i) {
      if ((mods & (1 << i)) != 0) {
        PostMessageW(f, WM_KEYUP, (WPARAM)moonui_mod_vk[i], 0xC0000001L);
      }
    }
  }
  return 0;
}

int moonui_request_window_close(const char *title, int title_len) {
  HWND win;
  TRACE("request_window_close");
  win = moonui_find_window(title, title_len);
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
 * moonui_start_dismissor 起的线程里。
 * 这里不起线程：对话框还没建，线程一醒过来无处可点。等下一个对话框来认领。 */
int moonui_auto_dismiss_dialog(int ms, int index) {
  TRACE("auto_dismiss_dialog");
  if (index < 0 || index > 1) {
    return -1;
  }
  moonui_dismiss_after_ms = ms < 0 ? 0 : ms;
  moonui_dismiss_index = index;
  return 0;
}

/* 装好"ms 毫秒之后对下一个文件面板按下接受 / 取消，并且面板停在 path 上"。契约
 * （-1 的校验为什么排最前、-2 为什么只在 mac 上出现）在 adapter.h 的测试脚手架
 * 那段；认领与执行在文件面板那段的 moonui_claim_file_answer /
 * moonui_file_answer_worker。
 * 这里同样不起线程：面板还没建，线程一醒过来无处可按。等下一个面板来认领。 */
int moonui_auto_answer_file_dialog(int ms,
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
    w = moonui_utf16_of(path, path_len);
    if (w == 0) {
      return -1;
    }
  }
  /* 取消不需要导航（答案和面板停在哪无关），path 直接丢掉。重复装以最后一次为
   * 准：旧的（上一次没被认领的）作废，和"一直没有面板来认领，下一个面板会被它
   * 答掉"相反的那一半——认领即失效，没认领的被覆盖。 */
  free(moonui_file_answer_path);
  moonui_file_answer_path = w;
  moonui_file_answer_accept = accept != 0;
  moonui_file_answer_after_ms = ms < 0 ? 0 : ms;
  return 0;
}

#else
/* 非 Windows 宿主：本翻译单元什么也不定义，只留一个 typedef，免得空翻译单元
 * 触发 C99 的诊断。Cocoa 那份实现在 ../libui-macos/adapter_macos.m，
 * 两个文件提供同一套 adapter.h 契约。 */
typedef int moonui_adapter_host_not_windows_t;
#endif /* _WIN32 */
