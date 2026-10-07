/* libui-ng C Adapter 的实现（§5）。
 *
 * 本文件与 vendored 的 ui.h 同目录：moon 的 native-stub 只编译包目录里的 C
 * 文件，所以包含关系全部相对自身，既不依赖 -I，也不受跑 moon 命令时的工作
 * 目录影响。链接用的静态库路径见 moon.pkg。
 */
#include "adapter.h"

#include <stdlib.h>
#include <string.h>

#include <windows.h>

#include "ui.h"

/* libui 的 Windows 后端把 manifest（Common Controls v6 + DPI 感知）编在 DLL 里；
 * 链静态库时那份 manifest 不会跟过来，所以在这里自己声明。少了它，
 * InitCommonControlsEx 只拿到旧版控件，libui 初始化会直接返回错误。 */
#pragma comment(linker,                                                      \
                "\"/manifestdependency:type='Win32'                         \
name='Microsoft.Windows.Common-Controls' version='6.0.0.0'                  \
processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

/* 排查"死在哪一次 FFI 调用"用的开关：native 测试进程里 MoonBit 的 println 是
 * 全缓冲的，异常退出时整段丢失，只有 C 侧即时 fflush 的输出留得住顺序。
 * 打开方式是在 stub-cc-flags 里加 /DMOONUI_TRACE。 */
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

/* 每个按钮最多一个点击回调。C 必须替 MoonBit 看守闭包的生命周期：libui 只记
 * 函数指针 + void*，GC 看不见它，不 incref 回来的就是尸体（§47 风险 1）。 */
#define MOONUI_CLICK_SLOTS 64

typedef struct {
  uiButton *button;
  moonui_closure_fn fn;
  void *closure;
} MoonuiClickSlot;

static MoonuiClickSlot moonui_clicks[MOONUI_CLICK_SLOTS];
static char moonui_error[512];

/* libui 的初始化是进程级的，重复 uiInit 会去注册已存在的窗口类而直接失败，
 * uiUninit 也没有引用计数。所以这里当单例看守：初始化幂等，未初始化时
 * 退出也是空操作。MoonBit 侧的 initialize()/terminate() 因此可以成对调用，
 * 不必担心同一个测试进程里跑了两条测试。 */
static int moonui_inited = 0;

/* attach 时给控件的 HWND 分配的 ID 计数器，见 moonui_control_attach 的注释。 */
static int moonui_next_control_id = 0;

static void moonui_release_slot(MoonuiClickSlot *slot) {
  if (slot->closure != 0) {
    moonbit_decref(slot->closure);
    slot->closure = 0;
  }
  slot->fn = 0;
  slot->button = 0;
}

/* 交还某个控件占用的回调槽：只放闭包引用，不销毁控件本身。
 * 挂在窗口上的按钮是被窗口连带销毁的，C 侧看不见那次销毁，
 * 所以必须由 MoonBit 在销毁窗口之前逐个 child 显式调用，
 * 否则槽里留着的就是一个已经失效的 uiButton 指针。 */
static void moonui_forget_control(uiButton *b) {
  int i;
  for (i = 0; i < MOONUI_CLICK_SLOTS; ++i) {
    if (moonui_clicks[i].button == b) {
      moonui_release_slot(&moonui_clicks[i]);
      return;
    }
  }
}

/* libui 的回调签名多一个 uiButton* 参数，这一层就是那条签名差异的适配器：
 * data 还原成槽位，再按 MoonBit 的形状调用。 */
static void moonui_click_trampoline(uiButton *b, void *data) {
  MoonuiClickSlot *slot = (MoonuiClickSlot *)data;
  (void)b;
  if (slot != 0 && slot->fn != 0) {
    slot->fn(slot->closure);
  }
}

/* MoonBit 的 Bytes 不保证 NUL 结尾，而 libui 全收 NUL 结尾的 UTF-8。
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

static moonbit_bytes_t moonui_bytes_of(const char *s) {
  int n = (int)strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  if (n > 0) {
    memcpy(out, s, (size_t)n);
  }
  return out;
}

/* 静态库不带 manifest 里的 DPI 感知声明，必须在建任何窗口之前用运行时方式设。
 * 取不到函数（老系统）就放弃，让系统按默认虚拟化，不影响后续流程。 */
static void moonui_ensure_dpi_aware(void) {
  HMODULE user32 = GetModuleHandleW(L"user32");
  BOOL(WINAPI * set_context)(HANDLE);
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
  for (i = 0; i < MOONUI_CLICK_SLOTS; ++i) {
    moonui_release_slot(&moonui_clicks[i]);
  }
  if (!moonui_inited) {
    return;
  }
  moonui_inited = 0;
  /* uiUninit 末尾会审计 libui 自己的分配表：只要还漏着一块，它就当成 bug
   * 调用 DebugBreak()——没有调试器时这就是一个退出不了的测试进程。所以
   * 走到这里之前，MoonBit 侧必须把所有控件销毁干净（句柄表归零）。 */
  uiUninit();
}

moonui_ptr moonui_window_new(const char *title,
                             int title_len,
                             int width,
                             int height) {
  char *w;
  uiWindow *win;
  TRACE("window_new");
  w = moonui_dup(title, title_len);
  if (w == 0) {
    return 0;
  }
  win = uiNewWindow(w, width, height, 0);
  free(w);
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

/* §14 的落点：布局算在 MoonUI 这一侧，libui 的容器布局完全不参与。
 *
 * 控件的 HWND 一出生挂在 libui 的隐藏工具窗口下（windows/control.cpp 里
 * uiWindowsEnsureCreateControlHWND 的 parent 就是 utilWindow），所以"挂进窗口"
 * 在这里就是把 HWND 搬到目标窗口的客户区，再按 MoonUI 算出的矩形摆放。
 * 两条不变量支持了这条捷径：
 *   - 回调路由按控件 HWND 查表（windows/events.cpp 的 runWM_COMMAND 用
 *     lParam 当键，不用控件 ID），所以换父级不影响 WM_COMMAND；
 *   - 主循环对顶层祖先跑 IsDialogMessage（windows/main.cpp processMessage），
 *     焦点链因此还是键盘 Tab 能走通的——只是 Tab 顺序跟 z-order 走，
 *     所以每个新控件插到 z-order 末尾，插入顺序就是 Tab 顺序。
 * 代价：窗口不再替 child 销毁控件，child 必须在窗口之前逐个显式销毁
 * （DestroyWindow 会连带销毁子窗口，之后再 destroy 就是野句柄，
 * libui 的分配审计会把这变成 DebugBreak）。这条顺序由 MoonBit 侧保证。 */
void moonui_control_attach(moonui_ptr window,
                           moonui_ptr child,
                           int x,
                           int y,
                           int width,
                           int height) {
  HWND parent = (HWND)(uintptr_t)uiControlHandle((uiControl *)(uintptr_t)window);
  HWND hwnd = (HWND)(uintptr_t)uiControlHandle((uiControl *)(uintptr_t)child);
  TRACE("control_attach");
  if ((LONG_PTR)GetWindowLongPtrW(hwnd, GWLP_ID) == 0) {
    if (SetParent(hwnd, parent) == 0) {
      return;
    }
    /* ID 只要在本窗口内互不相同；起点避开 IDOK/IDCANCEL（1/2）。 */
    SetWindowLongPtrW(hwnd, GWLP_ID, (LONG_PTR)(1000 + moonui_next_control_id));
    moonui_next_control_id += 1;
    SetWindowPos(hwnd, HWND_BOTTOM, x, y, width, height, SWP_NOACTIVATE);
    return;
  }
  /* 已经挂过一次：重新布局只改矩形，z-order 原样保留，否则每次 resize
   * 都会把控件重新排队一遍，Tab 顺序跟着布局抖动。 */
  SetWindowPos(hwnd, 0, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOZORDER);
}

void moonui_window_destroy(moonui_ptr w) {
  TRACE("window_destroy");
  uiControlDestroy((uiControl *)(uintptr_t)w);
}

moonui_ptr moonui_button_new(const char *text, int text_len) {
  char *t;
  uiButton *btn;
  TRACE("button_new");
  t = moonui_dup(text, text_len);
  if (t == 0) {
    return 0;
  }
  btn = uiNewButton(t);
  free(t);
  return (moonui_ptr)(uintptr_t)btn;
}

void moonui_button_set_text(moonui_ptr b, const char *text, int text_len) {
  char *t;
  TRACE("button_set_text");
  t = moonui_dup(text, text_len);
  if (t == 0) {
    return;
  }
  uiButtonSetText((uiButton *)(uintptr_t)b, t);
  free(t);
}

moonbit_bytes_t moonui_button_text(moonui_ptr b) {
  char *text;
  moonbit_bytes_t out;
  TRACE("button_text");
  /* libui 这里返回的是它 malloc 出来的副本（ui.h 里写明 caller must
   * uiFreeText），不是内部缓存。漏掉 uiFreeText 的话，libui 退出时的
   * 分配审计会把这一次泄漏当成 bug 并 DebugBreak——实测就是这么挂住的。 */
  text = uiButtonText((uiButton *)(uintptr_t)b);
  if (text == 0) {
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_bytes_of(text);
  uiFreeText(text);
  return out;
}

int moonui_button_on_clicked(moonui_ptr b,
                             moonui_closure_fn fn,
                             void *closure) {
  int i;
  TRACE("button_on_clicked");
  for (i = 0; i < MOONUI_CLICK_SLOTS; ++i) {
    if (moonui_clicks[i].button == 0) {
      moonui_clicks[i].button = (uiButton *)(uintptr_t)b;
      moonui_clicks[i].fn = fn;
      moonui_clicks[i].closure = closure;
      if (closure != 0) {
        moonbit_incref(closure);
      }
      uiButtonOnClicked((uiButton *)(uintptr_t)b, moonui_click_trampoline,
                        &moonui_clicks[i]);
      return 0;
    }
  }
  return -1;
}

void moonui_button_destroy(moonui_ptr b) {
  TRACE("button_destroy");
  /* 控件是自己挂在窗口的 HWND 下的，libui 不会替它回收闭包，所以引用必须由
   * 这里松开：先按控件找到槽位并 decref，再销毁控件本身。调用顺序由 MoonBit
   * 侧的 HandleTable 负责保证——child 必须在窗口之前销毁。 */
  moonui_forget_control((uiButton *)(uintptr_t)b);
  uiControlDestroy((uiControl *)(uintptr_t)b);
}

void moonui_main_steps(void) {
  TRACE("main_steps");
  uiMainSteps();
}

int moonui_main_step(int wait) {
  TRACE("main_step");
  return uiMainStep(wait);
}

void moonui_quit(void) {
  TRACE("quit");
  uiQuit();
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
  char *t;
  WCHAR wtitle[256];
  WCHAR cls[64];
  HWND win;
  HWND hit;
  POINT pt;
  TRACE("click_button_in_window");
  t = moonui_dup(title, title_len);
  if (t == 0) {
    return -1;
  }
  if (MultiByteToWideChar(CP_UTF8, 0, t, -1, wtitle, 256) == 0) {
    free(t);
    return -1;
  }
  free(t);
  win = FindWindowW(0, wtitle);
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
