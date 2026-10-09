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

#include <windows.h>

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

/* ---- 小工具 ---- */

static HWND moonui_hwnd(moonui_ptr c) {
  return (HWND)(uintptr_t)uiControlHandle((uiControl *)(uintptr_t)c);
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
  RECT r;
  if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &r, 0) == 0) {
    return moonui_pack2(GetSystemMetrics(SM_CXSCREEN),
                        GetSystemMetrics(SM_CYSCREEN));
  }
  return moonui_pack2(r.right - r.left, r.bottom - r.top);
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
  for (i = 0; i < MOONUI_SLOTS; ++i) {
    moonui_release_slot(&moonui_slots[i]);
  }
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
  TRACE("window_new");
  t = moonui_dup(title, title_len);
  if (t == 0) {
    return 0;
  }
  /* 最后一个参数是有菜单位：MoonUI 的菜单栏还没接（§48-18~20），所以先无菜单。 */
  win = uiNewWindow(t, width, height, 0);
  free(t);
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
  uiWindowSetContentSize((uiWindow *)(uintptr_t)w, width, height);
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
  return (moonui_ptr)(uintptr_t)c;
}

void moonui_widget_destroy(moonui_ptr c) {
  TRACE("widget_destroy");
  moonui_forget((void *)(uintptr_t)c, 0);
  uiControlDestroy((uiControl *)(uintptr_t)c);
}

void moonui_widget_set_text(moonui_ptr c, const char *text, int text_len) {
  LPWSTR t = moonui_utf16_of(text, text_len);
  TRACE("widget_set_text");
  if (t == 0) {
    return;
  }
  SendMessageW(moonui_hwnd(c), WM_SETTEXT, 0, (LPARAM)t);
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

#else
/* 非 Windows 宿主：本翻译单元什么也不定义，只留一个 typedef，免得空翻译单元
 * 触发 C99 的诊断。Cocoa 那份实现在 ../libui-macos/adapter_macos.m，
 * 两个文件提供同一套 adapter.h 契约。 */
typedef int moonui_adapter_host_not_windows_t;
#endif /* _WIN32 */
