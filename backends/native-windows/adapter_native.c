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
#include "../native-common/adapter.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>

#include <windows.h>

/* 输入法组合事件源（`T85②`）读组合串要过 IMM：HIMC/ImmGetContext/
 * ImmGetCompositionStringW/GCS_COMPSTR 都在 imm.h，它要 windows.h 先到
 * （DECLARE_HANDLE 那组宏）。真链接时那侧还要补 -limm32（`T85②` 的 Windows
 * 真跑欠账一并挂）。 */
#include <imm.h>

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

/* 图像那半要 WIC 解码（`T86⑤`，解码归平台——开工决策记在 TODO `T86⑤`）：
 * IWICImagingFactory / IWICBitmapDecoder / IWICFormatConverter 与像素格式
 * GUID 都在 wincodec.h，解码到 HBITMAP 喂 STATIC 的 STM_SETIMAGE。链接清单
 * 不用新库：CoCreateInstance 的 CLSID 由 initguid 在本单元定义（与 oleacc
 * 同一条规矩），CreateDIBSection 是 gdi32，都在既有清单里。 */
#include <wincodec.h>
#include <oleauto.h>

/* 音频（lunamusic 第一期，adapter.h 音频段注）走 **Media Foundation 解码 +
 * WASAPI 出声**，与 mac 半的 AVAudioEngine 同一层职责分工：
 *
 *   - 解码归系统：`IMFSourceReader` 认 mp3 / flac / wav / m4a / alac / aiff，
 *     并把源格式重采样到设备混音格式（MF 的 Audio Resampler DSP）——应用侧
 *     拿到的永远是"设备能直接吃的 PCM"。
 *   - 出声归 WASAPI 共享模式：`IAudioClient` + `IAudioRenderClient`，音量与
 *     归一化增益在软件侧乘（WASAPI 的 `ISimpleAudioVolume` 改的是会话音量，
 *     会把"这首歌的增益"和"系统音量"混成一笔账，`T170` 的归一化需要前者）。
 *   - 位置账：交出去的帧数减去渲染端缓冲里还没播的帧数（`GetCurrentPadding`），
 *     再按混音采样率折算——`IAudioClock` 那套要 QPC 对齐，v1 用前者。
 *
 * 为什么不用 MCI（`mciSendString`）：位置只有秒级精度、没有 EOS 事件、
 * 对 flac/m4a 靠系统编解码器碰运气——seek 条与自动下一曲都得靠它，不够用。
 *
 * 为什么不用 `IMFMediaSession` + SAR：那是"媒体会话替你调度"的形态，位置与
 * 结束判定要经 `IMFPresentationClock` 反推，比这条直给的账更难对。 */
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

/* ---- 画布（§52 分期④，`T98`）用的 GDI+ flat API，手工声明 ----
 *
 * mac 半的画布是 CGBitmapContext 的 CPU 光栅化（不是 GPU），Windows 的
 * 对等物就是"光栅化进一张预乘位图再上屏"——GDI+ 的 flat C API（Gdip*）
 * 直画进 scan0 缓冲，与 AlphaBlend（msimg32）要的 32bpp 预乘 BGRA 同一块
 * 内存，中间零拷贝。Direct2D 那条 GPU 路留作将来换芯（§44 的 GPU
 * Rendering 在两半都还没立项，先保与 mac 同形状的 CPU 位图帧）。
 *
 * 为什么不用 SDK 的 <gdiplus.h>：MSVC 那份整个包在 `namespace Gdiplus`
 * 里（GdiplusHeaders.h 的 C++ 包装类），C 模式第一行就红；mingw 那份的
 * C 支持又是另一套口径。flat API 本身就是稳定的 C ABI（GdiplusFlat.h，
 * extern "C" 一直包着），本文件只用到下面这一小圈——自己声明，两边
 * （cl / mingw 语法闸门）都不再依赖那张头。
 *
 * 枚举值取自 GdiplusEnums.h / GdiplusPixelFormats.h 的现值（GDI+ ABI
 * 二十年没动过），不展开整枚举表，只声明用到的那几档。 */
typedef int GpStatus; /* Status 枚举，MOONUI_GDIP_OK = 0 */
typedef struct GpGraphics GpGraphics;
typedef struct GpImage GpImage;
typedef struct GpBitmap GpBitmap;
typedef struct GpPath GpPath;
typedef struct GpPen GpPen;
typedef struct GpBrush GpBrush;
typedef struct GpSolidFill GpSolidFill;
typedef struct GpLineGradient GpLineGradient;
typedef struct GpFont GpFont;
typedef struct GpFontFamily GpFontFamily;
typedef DWORD ARGB;
typedef float REAL;
typedef UINT32 GraphicsState;
typedef struct {
  REAL X;
  REAL Y;
  REAL Width;
  REAL Height;
} GpRectF;
/* 多边形顶点（`GdipAddPathPolygon` 的入参）。图标那半（`T131`）用它画三角
 * 形的播放 / 快退 / 快进箭头——GDI 的 `Polygon` 没有抗锯齿，12 物理像素的
 * 三角画出来是锯的，GDI+ 的路径填充是平滑的，与 Panel 圆角同一条。 */
typedef struct {
  REAL X;
  REAL Y;
} GpPointF;
typedef struct {
  UINT32 GdiplusVersion;
  void *DebugEventCallback; /* 与 SDK 的 GdiplusStartupInput 同布局：
                             * GdiplusBase 没有数据成员，就是这四格 */
  BOOL SuppressBackgroundThread;
  BOOL SuppressExternalCodecs;
} MoonuiGdiplusStartupInput;

#define MOONUI_GDIP_OK 0
#define MOONUI_GDIP_FILLMODE_WINDING 1
#define MOONUI_GDIP_UNIT_PIXEL 2
#define MOONUI_GDIP_FONTSTYLE_BOLD 1
#define MOONUI_GDIP_SMOOTH_ANTIALIAS 4
#define MOONUI_GDIP_TEXTHINT_ANTIALIAS 4
#define MOONUI_GDIP_COMBINE_INTERSECT 1
#define MOONUI_GDIP_MATRIX_APPEND 1
#define MOONUI_GDIP_LINEAR_VERTICAL 1
#define MOONUI_GDIP_WRAP_CLAMP 0
#define MOONUI_GDIP_PIXFMT_PARGB 0xE200B /* MOONUI_GDIP_PIXFMT_PARGB */

/* 只列本文件真调用的那批；全部 __stdcall（x64 上无修饰，32 位上带 @N，
 * 与 GdiplusFlat.h 的 WINGDIPAPI 同一口径）。 */
GpStatus WINAPI GdiplusStartup(ULONG_PTR *token,
                               const MoonuiGdiplusStartupInput *input,
                               void *output);
GpStatus WINAPI GdipCreateBitmapFromScan0(INT width, INT height, INT stride,
                                          INT format, BYTE *scan0,
                                          GpBitmap **bitmap);
GpStatus WINAPI GdipDisposeImage(GpImage *image);
GpStatus WINAPI GdipGetImageGraphicsContext(GpImage *image,
                                            GpGraphics **graphics);
/* 从一只 HDC 开 GDI+ 图形上下文（皮肤那半：Panel 的圆角底色直接画在控件的
 * DC 上，不进画布帧）。 */
GpStatus WINAPI GdipCreateFromHDC(HDC hdc, GpGraphics **graphics);
GpStatus WINAPI GdipDeleteGraphics(GpGraphics *graphics);
GpStatus WINAPI GdipSaveGraphics(GpGraphics *graphics, GraphicsState *state);
GpStatus WINAPI GdipRestoreGraphics(GpGraphics *graphics, GraphicsState state);
GpStatus WINAPI GdipSetClipRectI(GpGraphics *graphics, INT x, INT y, INT w,
                                 INT h, INT combineMode);
GpStatus WINAPI GdipTranslateWorldTransform(GpGraphics *graphics, REAL dx,
                                            REAL dy, INT order);
GpStatus WINAPI GdipCreatePath(INT fillMode, GpPath **path);
GpStatus WINAPI GdipDeletePath(GpPath *path);
GpStatus WINAPI GdipAddPathRectangle(GpPath *path, REAL x, REAL y, REAL w,
                                     REAL h);
GpStatus WINAPI GdipAddPathEllipse(GpPath *path, REAL x, REAL y, REAL w,
                                   REAL h);
GpStatus WINAPI GdipAddPathLine(GpPath *path, REAL x1, REAL y1, REAL x2,
                                REAL y2);
GpStatus WINAPI GdipAddPathPolygon(GpPath *path, const GpPointF *points,
                                   INT count);
GpStatus WINAPI GdipAddPathArc(GpPath *path, REAL x, REAL y, REAL w, REAL h,
                               REAL startAngle, REAL sweepAngle);
GpStatus WINAPI GdipClosePathFigure(GpPath *path);
GpStatus WINAPI GdipCreateSolidFill(ARGB color, GpBrush **brush);
GpStatus WINAPI GdipDeleteBrush(GpBrush *brush);
GpStatus WINAPI GdipFillPath(GpGraphics *graphics, GpBrush *brush,
                             GpPath *path);
GpStatus WINAPI GdipCreatePen1(ARGB color, REAL width, INT unit, GpPen **pen);
GpStatus WINAPI GdipDeletePen(GpPen *pen);
GpStatus WINAPI GdipDrawPath(GpGraphics *graphics, GpPen *pen, GpPath *path);
GpStatus WINAPI GdipDrawLineI(GpGraphics *graphics, GpPen *pen, INT x1, INT y1,
                              INT x2, INT y2);
GpStatus WINAPI GdipCreateLineBrushFromRect(const GpRectF *rect, ARGB color1,
                                            ARGB color2, INT mode, INT wrap,
                                            GpLineGradient **lineGradient);
GpStatus WINAPI GdipSetLinePresetBlend(GpLineGradient *brush,
                                       const ARGB *presetColors,
                                       const REAL *blendPositions, INT count);
GpStatus WINAPI GdipFillRectangleI(GpGraphics *graphics, GpBrush *brush, INT x,
                                   INT y, INT w, INT h);
GpStatus WINAPI GdipDrawImageRectI(GpGraphics *graphics, GpImage *image, INT x,
                                   INT y, INT w, INT h);
GpStatus WINAPI GdipCreateFontFamilyFromName(const WCHAR *name, void *collection,
                                             GpFontFamily **fontFamily);
/* 字族名回读（`T313` 的"一屏一种字"探针用：要比的是 GDI+ 真给的那一族，
 * 不是我们请求的名字）。注意 flat API 的导出名是 `GdipGetFamilyName`，
 * 不是 `GdipGetFontFamilyName`——后者是 C++ 那层 wrapper 的名字，import lib
 * 里没有，写错了是 LNK2019（这条撞过）。 */
GpStatus WINAPI GdipGetFamilyName(GpFontFamily *fontFamily, WCHAR *name,
                                  LANGID language);
GpStatus WINAPI GdipGetGenericFontFamilySansSerif(GpFontFamily **fontFamily);
GpStatus WINAPI GdipCreateFont(GpFontFamily *fontFamily, REAL emSize,
                               INT style, INT unit, GpFont **font);
GpStatus WINAPI GdipDeleteFont(GpFont *font);
GpStatus WINAPI GdipDrawString(GpGraphics *graphics, const WCHAR *string,
                               INT length, const GpFont *font,
                               const GpRectF *layoutRect, const void *format,
                               GpBrush *brush);
GpStatus WINAPI GdipMeasureString(GpGraphics *graphics, const WCHAR *string,
                                  INT length, const GpFont *font,
                                  const GpRectF *layoutRect, const void *format,
                                  GpRectF *boundingBox, INT *codepointsFitted,
                                  INT *linesFilled);
GpStatus WINAPI GdipSetSmoothingMode(GpGraphics *graphics, INT mode);
GpStatus WINAPI GdipSetTextRenderingHint(GpGraphics *graphics, INT mode);

/* 直写 Win32 的控件：TRACKBAR_CLASSW / UPDOWN_CLASSW / PROGRESS_CLASSW /
 * DATETIMEPICK_CLASSW / InitCommonControlsEx 都在 commctrl.h。libui 那份是
 * 从 ui_windows.h 间接带进来的，这里自己包。 */
#include <commctrl.h>

/* DatePicker 的文字通道翻 SYSTEMTIME，格式化用 sscanf/snprintf；画布的弧
 * 采样要 cos/sin。 */
#include <stdio.h>
#include <math.h>

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

/* 排查"死在哪一次 FFI 调用"用的开关（和 mac 半同一条）：打开方式是
 * `MOONUI_NATIVE_TRACE=1 moon build/test ...`——prebuild-link.js 的
 * compileAdapter 看到这个环境变量就给 cl.exe 多带一条 /DMOONUI_TRACE。 */
#ifdef MOONUI_TRACE
#include <stdio.h>
#define TRACE(name)                  \
  do {                               \
    printf("[trace] %s\n", (name));  \
    fflush(stdout);                  \
  } while (0)
/* 带时刻的追踪（`T328`）：排查"底画了、字还没轮到"这一类跨窗口的先后问题，
 * 光有名字不够，得能对齐到毫秒。只在 `MOONUI_NATIVE_TRACE=1` 编进来的档有，
 * 平时编译成空。 */
#define TRACE_AT(name, hwnd)                                            \
  do {                                                                  \
    printf("[trace] %s %p %llu\n", (name), (void *)(hwnd),              \
           (unsigned long long)GetTickCount64());                       \
    fflush(stdout);                                                     \
  } while (0)
#else
#define TRACE(name) ((void)0)
#define TRACE_AT(name, hwnd) ((void)0)
#endif

/* 控件回调的槽位表。C 必须替 MoonBit 看守闭包的生命周期：Win32 只记函数指针
 * + void*，GC 看不见它，不 incref 回来的就是尸体（§47 风险 1）。
 * 用满时注册返回 -1，MoonBit 侧变成显式错误。
 *
 * 512 而不是 96：换树时新树先建、旧树后拆，峰值 ≈ 两棵树的回调之和（与 mac 半
 * 同一笔账，那边的段注有真实现象）。一格 24 字节，12KB 换掉"重建一次就 panic"。 */
#define MOONUI_SLOTS 512

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
/* `T85①`：worker 落地的专用消息（WM_APP 区段自由），wp/lParam 是 land 闭包的
 * (函数指针, 环境) 对——顶层窗口过程的路由见 moonui_native_wndproc。
 * `T86⑥`：托盘回调的专用消息（NOTIFYICONDATA.uCallbackMessage），lp 是鼠标
 * 事件（WM_LBUTTONUP 时弹托盘菜单），路由同在 moonui_native_wndproc。 */
#define MOONUI_WORK_MSG (WM_APP + 1)
#define MOONUI_TRAY_MSG (WM_APP + 2)
/* 音频播完回调的投递消息（`T326`）：引擎线程在 EOS 时把
 * {函数指针, 环境, 令牌} 包成一块堆内存投上来，顶层窗口过程核对令牌后
 * 在 UI 线程执行并回收——与 `T85①` 的 land 投递同一条纪律，区别只在多带一个
 * 令牌（load/stop 会作废已排队但还没执行完的那一发，否则"刚换歌就收到上一首
 * 的播完"会让队列多跳一格）。 */
#define MOONUI_AUDIO_MSG (WM_APP + 3)
static LRESULT moonui_wa_on_deliver(LPARAM lp);
static int moonui_native_menu_wanted(void);
static void moonui_native_menu_register(HWND hwnd);
static void moonui_native_icon_apply(HWND hwnd);
static void moonui_native_menu_unregister(HWND hwnd);
static void moonui_native_menu_clear_all(void);
static moonui_closure_id_fn moonui_native_menu_fn;
static void *moonui_native_menu_closure;
static void moonui_native_dispatch_command(HWND ctrl, int code);
/* 真滚动：视口自己那只原生滚动条的通知 + 视口内滚轮。定义在滚轮换算一节
 * （line_px 之后），scroll_proc 在前，先声明。返回 1 = 已消费、不再转发父。 */
static int moonui_native_scroll_on_bar(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
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
/* `T85②`：组合监听是进程一份（定义在控件一节之前的好几节之后），terminate
 * 在控件一节之前就要松它，先声明。 */
static void moonui_native_ime_drop_closure(void);
/* `T86`：托盘点击的菜单弹出（定义在文件尾部的托盘一节，顶层窗口过程的
 * WM_APP+2 分支在它之前就要调，先声明）。 */
static void moonui_native_tray_show_menu(HWND hwnd);
/* `T86⑥`：托盘的清理（terminate 在托盘一节之前就要松闭包），先声明。 */
static void moonui_native_tray_drop_closure(void);
/* `T86③`：文件拖入源的清理（同一条规矩）。 */
static void moonui_native_drop_drop_closure(void);
/* `T106`：手势监听的清理（同一条规矩）。 */
static void moonui_native_gesture_drop_closure(void);
/* `T106`：WM_GESTURE 的处理体（定义在手势一节，顶层窗口过程先要）。 */
static int moonui_native_gesture_handle(HWND hwnd, LPARAM lp);

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
  /* 客户区最小尺寸（§12），物理像素；0 = 没设过。落成 WM_GETMINMAXINFO 的
   * ptMinTrackSize——那是**用户拖边框**时的钳位，Core 侧的 clamped 只管
   * 程序化改尺寸，拖拽根本不经过 Core。 */
  int min_w;
  int min_h;
  /* 当下是不是在用户拖边框的 sizing 会话里（WM_ENTERSIZEMOVE..
   * WM_EXITSIZEMOVE 之间）。实时重排（live redraw）只认这条——程序化
   * SetWindowPos 的 WM_SIZE 回声不算（Core 的 set_size 自己当场重排）。 */
  int in_size_move;
  /* 沉浸式标题栏（`T116`）：1 = 摘掉系统标题栏与菜单位，自绘顶条就是标题栏。
   * 摘的是 GWL_STYLE 的 WS_CAPTION（见 moonui_native_window_set_titlebar_style），
   * 缩放的 WS_THICKFRAME 留着——窗还得能拉边。 */
  int immersive;
  /* 自绘标题条的拖动带高（物理像素，自窗口外框上缘算起；0 = 没设过）。
   * Core 只知道顶条多高（每只窗不一样），C 侧据此在 WM_NCHITTEST 里报
   * HTCAPTION，窗才拖得动。 */
  int drag_h;
  /* 窗口圆角半径（T295），千分比物理像素，-1 = 关。Windows 的外轮廓归 DWM，
   * 没有「改窗角半径」的入口，只记账给 getter 对账（与 mac 侧同形）。 */
  int corner_radius_pm;
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

/* 菜单那一节整体写在文件后面；沉浸式标题栏这半（`T116`）进出时要挂 / 摘
 * 系统菜单条，所以先声明。 */
static void moonui_native_menu_refresh(MoonuiWindowMenu *e, int restore);

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

/* "这是一只滑块吗"——**记号 + 类名**两条判据取或，不写死一个数字。
 *
 * 数字本身是 ABI 的一部分（adapter.h 的 kind 表：6=Slider），但只看数字要
 * 求"记号一定打上了"：`moonui_native_create_control` 之外建出来的 trackbar
 * （测试脚手架、将来某个直建路径）没走 `moonui_native_finish_new`，记号是
 * 空的，按数字判就把一条**真滑块**当成别的控件静默放过（`T137`）。
 * 反方向的坑也记在这：`moonui.kind` 这个属性存的是 **kind+1**（0 = 没记号），
 * 所以从进程外读到的滑块是 7 而不是 6——别把那 +1 当成"记号被谁改坏了"。 */
static int moonui_native_is_slider(HWND hwnd) {
  WCHAR cls[32];
  if (hwnd == 0) {
    return 0;
  }
  if (moonui_native_kind_of_hwnd(hwnd) == 6) {
    return 1;
  }
  cls[0] = L'\0';
  if (GetClassNameW(hwnd, cls, 32) == 0) {
    return 0;
  }
  return lstrcmpiW(cls, TRACKBAR_CLASSW) == 0;
}

/* 建出来就装上系统消息字体（`T313`）——实现落在 `moonui_native_font_of` 那节
 * （要用那边的造字函数和皮肤通道的 prop），这里先声明：七个专属构造入口都过
 * `moonui_native_finish_new`，把这一步挂在那儿一个都漏不掉。 */
static void moonui_native_install_default_font(HWND hwnd, int kind);

/* 创建控件的公共尾巴：打 owner 与 kind 两个记号 + 装默认字。返回非 0 表示
 * 成功。 */
static int moonui_native_finish_new(HWND hwnd, int kind) {
  if (hwnd == 0) {
    return 0;
  }
  moonui_native_mark_owner(hwnd, (moonui_ptr)(uintptr_t)hwnd);
  moonui_native_mark_kind(hwnd, kind);
  moonui_native_install_default_font(hwnd, kind);
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
static const WCHAR moonui_native_slot_moved_prop[] = L"moonui.slot.moved";

/* 程序赋值的回声抑制（对应 libui 各控件自己的 inhibitChanged）：置位期间
 * 到来的 EN_CHANGE / DTN_DATETIMECHANGE 一律吞掉。 */
static const WCHAR moonui_native_inhibit_prop[] = L"moonui.inhibit";

/* spinbox 的 updown 兄弟（见 moonui_native_spinbox_new 那节）。 */
static const WCHAR moonui_native_updown_prop[] = L"moonui.updown";

/* 单选组的子按钮名单（见 moonui_native_radio_new 那节）。 */
static const WCHAR moonui_native_radiokids_prop[] = L"moonui.radiokids";

/* 画布挂点（`T98`④ / `T111`）：present / present_view 把画布指针记在目标
 * HWND 的属性表上，WM_PAINT 时读回来贴帧。指针是借来的——画布销毁时
 * （canvas_destroy）按自己记的 window/view 两枚把 prop 摘掉，窗口先死则
 * prop 随窗口一起消失。 */
static const WCHAR moonui_native_canvas_prop[] = L"moonui.canvas";

/* 自定义绘制面（`T111`）的三枚 prop：点击槽位、焦点 opt-in、按住标志。 */
static const WCHAR moonui_native_slot_customclick_prop[] =
    L"moonui.slot.customclick";
static const WCHAR moonui_native_custom_focusable_prop[] =
    L"moonui.customfocusable";
static const WCHAR moonui_native_custom_pressed_prop[] =
    L"moonui.custompressed";

/* ---- 皮肤通道的落点（§32 定点豁免的 Windows 半）----
 *
 * 颜色一律存 `rgb + 1`（0 = 没设过），因为 HWND 属性表的 0 就是"这一项没有"，
 * 而 0x000000 是合法的黑色。font 那枚存 HFONT 本身（销毁时 DeleteObject），
 * font_permille / weight 另存一份是为了读回探针——HFONT 拿不回"当初给的
 * 千分比"，而判据要对账的正是下发值。 */
static const WCHAR moonui_native_bg_prop[] = L"moonui.style.bg";
static const WCHAR moonui_native_fg_prop[] = L"moonui.style.fg";
static const WCHAR moonui_native_bg_paint_prop[] = L"moonui.style.bgpaint";
/* 布局父（`T135`）：Panel 的子树在 C 侧被平铺挂到 Panel 的**父**窗口
 * （container_attach 的 kind 17 分支），真实 HWND 父子关系因此不再反映布局树
 * 的祖先链。垫 AA 底色要问"这块底下画的是什么"，那就得沿布局树往上走，所以
 * 挂接时把逻辑容器记在这枚 prop 上（存 HWND 本身，没有分配，不用配对清理）。 */
static const WCHAR moonui_native_holder_prop[] = L"moonui.holder";
static const WCHAR moonui_native_radius_prop[] = L"moonui.style.radius";
static const WCHAR moonui_native_font_prop[] = L"moonui.style.font";
static const WCHAR moonui_native_fontpt_prop[] = L"moonui.style.fontpt";
static const WCHAR moonui_native_weight_prop[] = L"moonui.style.weight";
/* 上一次下发样式的指纹（5 个入参的 64 位散列 + 1；0 = 还没下发过）。
 * Core 每次 relayout 都对整棵树重推同一份样式，重推会重建画刷 + 逐控件失效，
 * 几十只控件各重画一次就是用户看到的"删一行整片闪一下"。指纹相等时后端状态
 * 已经是这一份，直接返回。 */
static const WCHAR moonui_native_style_fp_prop[] = L"moonui.style.fp";
/* 图标名（`set_icon` 推来的 SF Symbol 名，堆上的 NUL 结尾串，销毁时 free）。
 * 没名字 = 文本钮，与 mac 半"没装图就画标题"同一条。 */
static const WCHAR moonui_native_icon_prop[] = L"moonui.style.icon";
/* 字体族名（set_font_family 推来的 UTF-8 串，堆上 NUL 结尾，销毁时 free）。
 * 没名字 = 用系统消息字体（§32 原生外观），造 HFONT 时填 lfFaceName。 */
static const WCHAR moonui_native_family_prop[] = L"moonui.style.family";
/* 占位提示文案（`set_placeholder` 推来的 UTF-8 串，堆上 NUL 结尾，换一份 /
 * 销毁时 free；没有 = 这个框没有占位）。为什么不落 EM_SETCUEBANNER 见
 * `moonui_native_edit_placeholder_active` 段注。 */
static const WCHAR moonui_native_placeholder_prop[] = L"moonui.placeholder";
/* Windows 真滚动：`X/Y` 打包成一个 int64（低 32 = 横向、高 32 = 纵向），
 * 记录视口当前滚出多少物理像素。Core 的 frame 恒为文档坐标、不存偏移
 * （`window.mbt` §14），偏移这本账整个在后端——与 GTK 的 GtkViewport /
 * mac 的 NSScrollView 同一分工。props 随 HWND 一起消失，无堆分配。 */
static const WCHAR moonui_native_scroll_offset_prop[] = L"moonui.scroll.offset";

/* 平面钮（`T115`①）的两枚 prop：子类原过程（与 IME 那半同一套手法，跟着
 * HWND 一起没，不用配对清理）与悬停标志（TrackMouseEvent 起的沿，进 / 出
 * 各翻一次）。 */
static const WCHAR moonui_native_button_orig_prop[] = L"moonui.button.orig";
static const WCHAR moonui_native_button_hot_prop[] = L"moonui.button.hot";

/* 滑块的子类原过程（与按钮同一套手法，`T132`）。 */
static const WCHAR moonui_native_slider_orig_prop[] = L"moonui.slider.orig";

static void moonui_native_set_rgb_prop(HWND hwnd, const WCHAR *prop, int64_t rgb) {
  if (hwnd == 0) {
    return;
  }
  if (rgb < 0) {
    RemovePropW(hwnd, prop);
    return;
  }
  SetPropW(hwnd, prop, (HANDLE)(uintptr_t)(((uint32_t)rgb & 0xFFFFFFu) + 1u));
}

static int64_t moonui_native_rgb_prop(HWND hwnd, const WCHAR *prop) {
  HANDLE v;
  if (hwnd == 0) {
    return -1;
  }
  v = GetPropW(hwnd, prop);
  if (v == 0) {
    return -1;
  }
  return (int64_t)(uintptr_t)v - 1;
}

/* 0xRRGGBB → Win32 的 COLORREF（0x00BBGGRR）。两个后端的颜色口径都是
 * 0xRRGGBB，系统 GDI 那套是反的，转换只在这一处做。 */
static COLORREF moonui_native_colorref_of(int64_t rgb) {
  return (COLORREF)(((uint32_t)rgb & 0xFFu) << 16) |
         ((COLORREF)((uint32_t)rgb & 0xFF00u)) |
         ((COLORREF)(((uint32_t)rgb >> 16) & 0xFFu));
}

static int64_t moonui_native_rgb_of_colorref(COLORREF c) {
  return (int64_t)(((uint32_t)c & 0xFFu) << 16) |
         (int64_t)((uint32_t)c & 0xFF00u) |
         (int64_t)(((uint32_t)c >> 16) & 0xFFu);
}

/* 两个 0xRRGGBB 按百分比混色（`pct` = 0..100，从 a 走向 b）。
 *
 * 平面钮（`T115`①）的四态只有**一个**底色可用——皮肤通道只下发 `background`
 * 一项，Core 那边没有"悬停色 / 按下色"的第二个字段（`hover_style` 是整层
 * 样式，不是按钮状态色）。所以悬停与按下这两个状态色只能从底色自己推：
 * 亮度亮的往黑走、暗的往白走，看得见"这一下按下去了"，又不引入第二份配色。 */
static int64_t moonui_native_mix_rgb(int64_t a, int64_t b, int pct) {
  int64_t out = 0;
  int shift;
  for (shift = 0; shift <= 16; shift += 8) {
    int ca = (int)(((uint32_t)a >> shift) & 0xFFu);
    int cb = (int)(((uint32_t)b >> shift) & 0xFFu);
    int cm = (ca * (100 - pct) + cb * pct + 50) / 100;
    if (cm < 0) {
      cm = 0;
    }
    if (cm > 255) {
      cm = 255;
    }
    out |= ((int64_t)cm) << shift;
  }
  return out;
}

/* 相对亮度（ITU-R BT.601 的整数版）：只用来决定"该往黑走还是往白走"。 */
static int moonui_native_luminance(int64_t rgb) {
  int r = (int)(((uint32_t)rgb >> 16) & 0xFFu);
  int g = (int)(((uint32_t)rgb >> 8) & 0xFFu);
  int b = (int)((uint32_t)rgb & 0xFFu);
  return (299 * r + 587 * g + 114 * b) / 1000;
}

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
  /* 皮肤通道那几枚 prop 里有两样是我们自己造的 GDI 对象（HFONT、HBRUSH），
   * 属性表随窗口一起消失、对象不会——这里先摘 prop 再 DeleteObject。 */
  HFONT skin_font = (HFONT)(uintptr_t)GetPropW(hwnd, moonui_native_font_prop);
  HBRUSH skin_brush =
      (HBRUSH)(uintptr_t)GetPropW(hwnd, moonui_native_bg_paint_prop);
  char *icon_name = (char *)(uintptr_t)GetPropW(hwnd, moonui_native_icon_prop);
  char *family_name =
      (char *)(uintptr_t)GetPropW(hwnd, moonui_native_family_prop);
  char *placeholder =
      (char *)(uintptr_t)GetPropW(hwnd, moonui_native_placeholder_prop);
  RemovePropW(hwnd, moonui_native_owner_prop);
  RemovePropW(hwnd, moonui_native_kind_prop);
  RemovePropW(hwnd, moonui_native_slot_click_prop);
  RemovePropW(hwnd, moonui_native_slot_text_prop);
  RemovePropW(hwnd, moonui_native_slot_toggled_prop);
  RemovePropW(hwnd, moonui_native_slot_changed_prop);
  RemovePropW(hwnd, moonui_native_slot_closing_prop);
  RemovePropW(hwnd, moonui_native_slot_resized_prop);
  RemovePropW(hwnd, moonui_native_slot_moved_prop);
  RemovePropW(hwnd, moonui_native_inhibit_prop);
  RemovePropW(hwnd, moonui_native_slot_customclick_prop);
  RemovePropW(hwnd, moonui_native_custom_focusable_prop);
  RemovePropW(hwnd, moonui_native_custom_pressed_prop);
  RemovePropW(hwnd, moonui_native_bg_prop);
  RemovePropW(hwnd, moonui_native_fg_prop);
  RemovePropW(hwnd, moonui_native_radius_prop);
  RemovePropW(hwnd, moonui_native_font_prop);
  RemovePropW(hwnd, moonui_native_fontpt_prop);
  RemovePropW(hwnd, moonui_native_weight_prop);
  RemovePropW(hwnd, moonui_native_bg_paint_prop);
  RemovePropW(hwnd, moonui_native_icon_prop);
  RemovePropW(hwnd, moonui_native_family_prop);
  RemovePropW(hwnd, moonui_native_placeholder_prop);
  RemovePropW(hwnd, moonui_native_updown_prop);
  RemovePropW(hwnd, moonui_native_radiokids_prop);
  if (skin_font != 0) {
    DeleteObject(skin_font);
  }
  if (skin_brush != 0) {
    DeleteObject(skin_brush);
  }
  if (icon_name != 0) {
    free(icon_name);
  }
  if (family_name != 0) {
    free(family_name);
  }
  if (placeholder != 0) {
    free(placeholder);
  }
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

/* ---- 真滚动：视口的滚动偏移账（Windows 半）----
 * Core 的 frame 是文档坐标、不存滚动偏移（window.mbt §14 / ScrollSpec 注），
 * 偏移整本在后端。这里把它挂在视口 HWND 的一个 prop 上：低 32 位横向、
 * 高 32 位纵向，单位物理像素，语义是"文档原点被卷出视口左上角的距离"
 * （正值 = 内容往上/左走）。prop 随 HWND 消失，无堆分配、无需配对清理。
 * 没有 prop = (0,0)，也正是没滚过的初态。 */
static void moonui_native_scroll_offset(moonui_ptr scroll, int *x, int *y) {
  HANDLE v = GetPropW(moonui_native_hwnd(scroll),
                      moonui_native_scroll_offset_prop);
  int64_t packed = (int64_t)(uintptr_t)v;
  *x = (int)(int32_t)packed;
  *y = (int)(int32_t)(packed >> 32);
}

static void moonui_native_scroll_set_offset(moonui_ptr scroll, int x, int y) {
  /* 读侧约定：低 32 = 横向 x、高 32 = 纵向 y；pack2(a,b) 是 a 在高位，
   * 所以这里传 (y, x) 而不是 (x, y)——顺序写反会让纵向偏移记到横向账上，
   * set_content 收缩时读回 0、不补偿，滚过的行就停在半路回不去。 */
  int64_t packed = moonui_native_pack2(y, x);
  SetPropW(moonui_native_hwnd(scroll), moonui_native_scroll_offset_prop,
           (HANDLE)(uintptr_t)packed);
}

/* 失效包装（`moonui_native_invalidate`）定义在后文；滚动收笔要走它，这里先用。
 * 为什么不在这儿自己 `InvalidateRect`：包装干的是"配对 + 当场落笔"两件事
 * （`T140` / `T318`），绕过它等于把压在行底上的透明标签漏在更新区外。 */
static void moonui_native_invalidate(HWND hwnd, int erase);

/* 整棵子树原子落笔（`T324`）。滚动收笔的第三步要走它（`T328`），定义在后文。
 * `clip` 是屏幕坐标的裁剪区：非 0 时只有与它相交的窗口会被画，不相交的连子窗
 * 都不递归进去（视口外的行不在这一帧的账上，`T319` 的契约）。传 0 = 不裁剪。 */
static void moonui_native_present_subtree(HWND h, int *budget, const RECT *clip);

/* `child` 落在视口客户区里吗（滚动收笔只画屏幕上真看得见的那些）。 */
static int moonui_native_child_in_view(HWND view, HWND child, const RECT *cr) {
  RECT r;
  POINT p;
  if (IsWindowVisible(child) == 0 || GetWindowRect(child, &r) == 0) {
    return 0;
  }
  p.x = r.left;
  p.y = r.top;
  if (ScreenToClient(view, &p) == 0) {
    return 0;
  }
  return p.x < cr->right && p.y < cr->bottom &&
         p.x + (r.right - r.left) > cr->left &&
         p.y + (r.bottom - r.top) > cr->top;
}

/* 滚动把子控件平移之后，必须让视口**连同背景**重画一遍，而且**当场画完**。
 *
 * 视口是 WS_EX_TRANSPARENT 的 STATIC，自己不画任何内容（scroll_proc 没有
 * WM_PAINT 落笔），子控件是它的兄弟层里独立 HWND。SetWindowPos 平移只动子
 * 控件自己，**不会**擦掉它离开的那块矩形——那块归视口这一层管。如果只用
 * InvalidateRect 走 erase=FALSE（attach / 常规重排那条路，见 T126），擦除消息
 * 根本不来，旧像素就永久留在屏幕上：用户 2026-11-17 报的"滚动后有残影、
 * 不会消失"正是这个。所以这里显式给一次**带 erase** 的重画。
 *
 * 为什么还要求"当场"（`T319`）：一次翻页要画的东西是"视口底色 + 每块面板 +
 * 每只标签"，在 Windows 上是**每只窗口各一条 WM_PAINT**，而 `moonui_native_main_step`
 * 一圈只泵一条消息。只标脏的话，这一帧要好几轮才补完——新露出来的那几行在
 * 屏幕上就是先空白、再一行行冒字（owner 2026-11-18 截图：滚动时中间几行只剩
 * 斑马底）。这里把整帧收在同一次调用里落笔：
 *   ① `UpdateWindow` 落视口底色——空出来的那条只有它管；视口带
 *      `WS_CLIPCHILDREN`，这层底色盖不到子控件（`T126` 担心的"满屏底色闪一下"
 *      本来就是因为只画这一层、子控件留到后面几帧；两层一起画就不存在那一帧）。
 *   ② 与客户区相交的子窗逐个走 `moonui_native_invalidate`：它会把面板和压在
 *      面板上的透明标签一起配进更新区，配上时当场落笔（`T318`）。按 `GW_CHILD`
 *      的顺序（最上层在前）走，于是标签先被标脏、面板随后把"底 + 字"一起画完。
 *   ③ 兜底收笔：没配上标签的面板、被后一次失效又标脏的标签，更新区还留着。
 *      倒着走 = 自下而上，面板先落底、标签后落字，不留半成品帧。
 *
 * 只画与客户区相交的那些：视口外的行（还没滚进来的）不在这笔账里，它们本来就
 * 不该在屏幕上出现。 */
static void moonui_native_scroll_erase(HWND view) {
  HWND kids[256];
  TRACE_AT("scroll_erase", view);
  RECT cr;
  int n = 0;
  int i;
  if (view == 0) {
    return;
  }
  RedrawWindow(view, 0, 0, RDW_INVALIDATE | RDW_ERASE);
  if (GetClientRect(view, &cr) == 0) {
    return;
  }
  /* 收一遍直属子窗。256 是兜底：列表一屏通常十行上下（每行 5～6 只窗），
   * 超出的部分照旧等各自的 WM_PAINT——不会漏画，只是不在这一个原子里。 */
  {
    HWND c;
    for (c = GetWindow(view, GW_CHILD); c != 0 && n < 256;
         c = GetWindow(c, GW_HWNDNEXT)) {
      kids[n++] = c;
    }
  }
  /* ① 先落视口自己那层（空出来的条）。 */
  UpdateWindow(view);
  /* ② 相交的子窗走正规失效路径（配对 + 同步落笔）。 */
  for (i = 0; i < n; i += 1) {
    if (moonui_native_child_in_view(view, kids[i], &cr)) {
      moonui_native_invalidate(kids[i], 0);
    }
  }
  /* ③ 兜底收笔：整棵子树按"父先子后、兄弟自下而上"一次画完（`T324` 那套
   * `moonui_native_present_subtree`）。
   *
   * 这一步在 `T328` 之前是"倒着走一遍、给还挂着更新区的发 `WM_PAINT`"。那样
   * 只补得上**已经有脏区**的窗口：平移带了 `SWP_NOREDRAW` 之后，子窗既不搬
   * 像素也不挂脏，屏幕上留着旧位置的像素、新位置一片空，而 Windows 认为它
   * "干净"——谁都不会再画它。整行只剩斑马底、鼠标划过才长回来，就是这一步
   * 漏的账。`present_subtree` 对透明标签是**无条件**标脏再画的（`T326③`），
   * 正好补上这一类"干净但没像素"的窗口。
   *
   * 落笔范围限在**视口客户区**（屏幕坐标的裁剪区）：视口外的行不画、也不
   * 递归进去——`T319` 钉的就是这条（整行滚出一屏的那 3 只，既没画过、也不该
   * 有待画区）。不裁剪的话它们会被这一步顺手画掉，判据读数会从 16/3 变成
   * 18/1。 */
  {
    int budget = 4096;
    RECT clip;
    POINT tl;
    POINT br;
    tl.x = cr.left;
    tl.y = cr.top;
    br.x = cr.right;
    br.y = cr.bottom;
    ClientToScreen(view, &tl);
    ClientToScreen(view, &br);
    clip.left = tl.x;
    clip.top = tl.y;
    clip.right = br.x;
    clip.bottom = br.y;
    moonui_native_present_subtree(view, &budget, &clip);
  }
}

/* 把视口里所有直属子控件按 (dx,dy) 挪一下——滚动的核心动作。
 * 视口子控件的坐标是"父客户区坐标"（container_attach 的 kind 15 分支），
 * 而 set_bounds 摆进去的又是 Core 的文档坐标；所以滚动时把文档坐标整体
 * 平移 (-offx, -offy) 就是屏幕上的滚动，不必另造文档视图层。
 * 只认 kind 15 的直属孩子：Panel 子树在 Windows 半是平铺进同一层的
 * （container_attach kind 17），它们同样要跟着滚。不动视口自己。
 *
 * **`SWP_NOREDRAW` 不可省**（`T328`）：一屏要挪两百来只窗口（每行一只面板 +
 * 五六只标签，几十行），每挪一只系统都会顺手把那只窗口现有的像素搬到新位置、
 * 再把新露出来的边条标脏。搬过去的是**它自己刚才那张脸**：面板搬过去只有底、
 * 字还留在旧位置（标签是另一只窗口，要等自己的 `WM_PAINT`）。于是整段平移
 * 过程中屏幕上是"底到了、字没到"的半途态——owner 录屏里那一下轻微闪字就是
 * 它，量下来每次滚动后必现（683 帧 28 次，命中的那一瞬整行 5 只标签全欠着
 * 更新区、屏幕上只剩斑马底）。
 *
 * 带上这一位，挪的过程一个像素都不动屏幕，等随后 `moonui_native_scroll_erase`
 * 把"视口底 + 面板 + 标签"按底到字的顺序一次画完——那一发才是这一帧的样子。
 * 三个调用点（`scroll_set`、滚动条补偿两处）都在平移后立刻收笔，没有"挪了不
 * 画"的路。 */
static void moonui_native_scroll_shift_children(moonui_ptr scroll, int dx,
                                                int dy) {
  HWND view = moonui_native_hwnd(scroll);
  HWND child;
  if (dx == 0 && dy == 0) {
    return;
  }
  for (child = GetWindow(view, GW_CHILD); child != 0;
       child = GetWindow(child, GW_HWNDNEXT)) {
    POINT p;
    RECT r;
    if (GetWindowRect(child, &r) == 0) {
      continue;
    }
    p.x = r.left;
    p.y = r.top;
    if (ScreenToClient(view, &p) == 0) {
      continue;
    }
    TRACE_AT("shift", child);
    SetWindowPos(child, 0, p.x + dx, p.y + dy, 0, 0,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSIZE |
                     SWP_NOOWNERZORDER | SWP_NOREDRAW);
  }
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

/* ---- 输入法组合事件源（`T85②`，adapter.h 的 IME 段注）----
 *
 * 组合监听是进程全局的一份（与键盘/鼠标钩子同一档形状），通知不带内容，
 * 相位/target/组合串三样当场读回——快照在调闭包之前写好、闭包返回之后没人再动，
 * 一次通知配一次读（§48-16）。
 *
 * 相位从三类消息分流：WM_IME_STARTCOMPOSITION（开始，不带组合串——与 mac 半
 * 从无到有那条不带串的切换沿对齐）、WM_IME_COMPOSITION（进行，带 GCS_COMPSTR
 * 读出的组合串）、WM_IME_ENDCOMPOSITION（结束，上屏全文随既有文本变化通道走）。
 * 组合串在 WM_IME_COMPOSITION 的消息间隙里有效，当场经 IMM 读出（UTF-16 →
 * UTF-8 存进快照；上下文拿不到或串为空都存空串）。**这条只在 mingw 语法闸门
 * 量过**：真跑欠账（组合串编码、消息序列计数、ImmGetContext 的消息间隙前提）
 * 挂在 `T85②` 的 Windows 真跑账里，链接时还要补 -limm32。 */

static moonui_closure_fn moonui_native_ime_fn = 0;
static void *moonui_native_ime_closure = 0;

/* target 是正在组合的那只我们的控件 HWND（0 = 反查不到），phase 见 adapter.h
 * 编码，text 是组合串的 UTF-8（起始/结束为空串）。 */
static HWND moonui_native_ime_target_hwnd = 0;
static int moonui_native_ime_phase_now = 0;
static char *moonui_native_ime_text_bytes = 0;

/* 组合消息进的是焦点窗口的过程，而组合发生在焦点 EDIT 里（系统 EDIT 类的过程
 * 自己收这三类消息），顶层窗口过程看不见它们——所以创建 kind 2/4 时换上子类
 * 过程（滚动剪裁容器同一条手法：SetWindowLongPtrW 换 GWLP_WNDPROC、不动类
 * 注册），这里分流三类消息，其余一律链回系统 EDIT 过程。原过程存属性表（与
 * kind 记号同一套手法，跟着 HWND 一起没，不用配对清理）。 */
static const WCHAR moonui_native_ime_orig_prop[] = L"moonui.ime.orig";

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
  return (moonui_ptr)(uintptr_t)moonui_native_ime_target_hwnd;
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

/* 读当下的组合串（GCS_COMPSTR，UTF-16 → UTF-8 存进快照）。字节计数按文档是
 * "拷出的字节数"（含终止符那一档的出入归真跑账），这里多给一格 WCHAR 兜 NUL。 */
static void moonui_native_ime_snapshot_comp(HWND hwnd) {
  HIMC ctx = ImmGetContext(hwnd);
  LONG bytes;
  LONG got;
  LPWSTR w;
  if (ctx == 0) {
    return;
  }
  bytes = ImmGetCompositionStringW(ctx, GCS_COMPSTR, 0, 0);
  if (bytes <= 0) {
    ImmReleaseContext(hwnd, ctx);
    return;
  }
  w = (LPWSTR)malloc((size_t)bytes + sizeof(WCHAR));
  if (w != 0) {
    got = ImmGetCompositionStringW(ctx, GCS_COMPSTR, (LPVOID)w, bytes);
    if (got > 0) {
      char *u;
      w[bytes / sizeof(WCHAR)] = L'\0';
      u = moonui_native_utf8_of(w);
      free(moonui_native_ime_text_bytes);
      moonui_native_ime_text_bytes = u;
    }
    free(w);
  }
  ImmReleaseContext(hwnd, ctx);
}

/* 写相位快照再调监听。进行通知当场读组合串，起始/结束不带（与 mac 半同一条
 * 对齐约定：串跟在同一条序列的下一条进行通知上）。 */
static void moonui_native_ime_notify(HWND hwnd, int phase) {
  if (moonui_native_ime_fn == 0) {
    return;
  }
  moonui_native_ime_target_hwnd = hwnd;
  moonui_native_ime_phase_now = phase;
  free(moonui_native_ime_text_bytes);
  moonui_native_ime_text_bytes = 0;
  if (phase == 1) {
    moonui_native_ime_snapshot_comp(hwnd);
  }
  moonui_native_ime_fn(moonui_native_ime_closure);
}

/* ---- 占位提示（`T317`）----
 *
 * 原先直接落 EM_SETCUEBANNER（`T220`），由系统在 EDIT 自己的绘制路径里画那行
 * 灰字。owner 2026-11-18 的截图推翻了这条路：点进播放列表的搜索框之后，框还在、
 * 焦点下划线还在、字段也确实是空的，**那行灰字整条没了**——占位读不出来。
 * cue banner 的可见性不归我们管（焦点态 / 重画时机 / 主题态任何一环都可能把它
 * 吞掉），而它是这个框唯一的提示来源，被吞掉就等于没有占位。
 *
 * 所以改成自己存串、自己画（`moonui.placeholder` 这枚 prop）：空字段的那一帧
 * 整块由我们落笔，底色与灰字在**同一次绘制**里画完，焦点、强制重绘、换主题都
 * 是同一个结果。系统 cue 一并撤掉，否则两行字叠在一起。
 *
 * 判据（`native_test.mbt` 的 `T220` 条）读的是 `WM_PRINTCLIENT` 的异色像素，
 * 两条路都覆盖：离屏那条走 WM_PRINTCLIENT 分支，屏幕那条走 WM_PAINT 分支。 */

/* 现在该不该画占位：有串、字段是空的、且没在输入法组合里。 */
static int moonui_native_edit_placeholder_active(HWND hwnd) {
  char *ph = (char *)(uintptr_t)GetPropW(hwnd, moonui_native_placeholder_prop);
  if (ph == 0 || ph[0] == '\0') {
    return 0;
  }
  if (GetWindowTextLengthW(hwnd) > 0) {
    return 0; /* 有字就不是占位 */
  }
  /* 组合中不画：候选串由系统画在同一块客户区，垫一层占位会与它叠在一起。
   * 相位 1 = 正在组合（与 IME 事件那条快照同一套记账）。 */
  if (moonui_native_ime_target_hwnd == hwnd && moonui_native_ime_phase_now == 1) {
    return 0;
  }
  return 1;
}

/* 把占位串画进 dc。文字区取 EM_GETRECT（已扣掉 WS_EX_CLIENTEDGE 的边框），
 * 颜色取系统的 COLOR_GRAYTEXT——深浅主题各给各的提示色，不写死。 */
static void moonui_native_edit_paint_placeholder(HWND hwnd, HDC dc) {
  char *ph = (char *)(uintptr_t)GetPropW(hwnd, moonui_native_placeholder_prop);
  LPWSTR w;
  RECT fr;
  HFONT font;
  HGDIOBJ old_font;
  int old_mode;
  COLORREF old_fg;
  if (ph == 0 || ph[0] == '\0' || dc == 0) {
    return;
  }
  w = moonui_native_utf16_of(ph, (int)strlen(ph));
  if (w == 0) {
    return;
  }
  memset(&fr, 0, sizeof(fr));
  SendMessageW(hwnd, EM_GETRECT, 0, (LPARAM)&fr);
  old_mode = SetBkMode(dc, TRANSPARENT);
  old_fg = SetTextColor(dc, GetSysColor(COLOR_GRAYTEXT));
  font = (HFONT)SendMessageW(hwnd, WM_GETFONT, 0, 0); /* 与正文同一只字（T313） */
  old_font = font != 0 ? SelectObject(dc, font) : 0;
  DrawTextW(dc, w, -1, &fr,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
  if (old_font != 0) {
    SelectObject(dc, old_font);
  }
  SetTextColor(dc, old_fg);
  SetBkMode(dc, old_mode);
  free(w);
}

static LRESULT CALLBACK moonui_native_edit_proc(HWND hwnd, UINT msg, WPARAM wp,
                                                LPARAM lp) {
  WNDPROC orig = (WNDPROC)GetPropW(hwnd, moonui_native_ime_orig_prop);
  if (moonui_native_ime_fn != 0) {
    if (msg == WM_IME_STARTCOMPOSITION) {
      moonui_native_ime_notify(hwnd, 0);
    } else if (msg == WM_IME_COMPOSITION && (lp & GCS_COMPSTR) != 0) {
      moonui_native_ime_notify(hwnd, 1);
    } else if (msg == WM_IME_ENDCOMPOSITION) {
      moonui_native_ime_notify(hwnd, 2);
    }
  }
  /* 离屏重画（判据与截图工具走这条）：先让系统把底与正文画完，再叠占位。 */
  if (msg == WM_PRINTCLIENT) {
    LRESULT r = orig != 0 ? CallWindowProcW(orig, hwnd, msg, wp, lp)
                          : DefWindowProcW(hwnd, msg, wp, lp);
    if ((lp & PRF_CLIENT) != 0 && moonui_native_edit_placeholder_active(hwnd)) {
      moonui_native_edit_paint_placeholder(hwnd, (HDC)wp);
    }
    return r;
  }
  /* 上屏那条：空字段 + 有占位时整块自己画。这一态没有正文也没有选中区，
   * 系统那条路会画的也就底色 + 灰字两样；收成一次落笔之后，"底色画了、字没
   * 画"的中间帧（owner 看到的那一格）在机制上不可能出现。 */
  if (msg == WM_PAINT && moonui_native_edit_placeholder_active(hwnd)) {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    if (dc != 0) {
      /* 底色按可用态取：禁用态系统用的是按钮面（灰），照抄，别把一只灰底
       * 的框刷成白的。 */
      FillRect(dc, &ps.rcPaint,
               (HBRUSH)(UINT_PTR)(IsWindowEnabled(hwnd) ? COLOR_WINDOW + 1
                                                        : COLOR_3DFACE + 1));
      moonui_native_edit_paint_placeholder(hwnd, dc);
    }
    EndPaint(hwnd, &ps);
    return 0;
  }
  return orig != 0 ? CallWindowProcW(orig, hwnd, msg, wp, lp)
                   : DefWindowProcW(hwnd, msg, wp, lp);
}

/* 创建 kind 2/4 时装子类：换过程、记原过程。失败就保持系统 EDIT 原样——
 * 组合相位那侧退化成没有事件源，控件照常工作。 */
static void moonui_native_ime_subclass(HWND edit) {
  WNDPROC orig =
      (WNDPROC)SetWindowLongPtrW(edit, GWLP_WNDPROC, (LONG_PTR)moonui_native_edit_proc);
  if (orig != 0) {
    SetPropW(edit, moonui_native_ime_orig_prop, (HANDLE)(uintptr_t)orig);
  }
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

/* 缺字形时的兜底字体（`T131`）。
 *
 * GDI 的字体链接只覆盖东亚字形：`♡`(U+2661)、`▣`(U+25A3)、`✕`(U+2715) 这
 * 一族在系统 UI 字体（Microsoft YaHei UI）里没有——`GetGlyphIndicesW` 回
 * 65535，`GetTextExtentPoint32` 只量出 4 像素，画出来是一颗空白钮（owner 报
 * 的"按钮空白 / 按钮显示异常"里，窗口那三颗和收藏那颗就是这条）。系统里覆
 * 盖这些符号的是 Segoe UI Symbol，于是这里按"同样高度、同样粗度、只换字族"
 * 造一只替代字体。
 *
 * 只在 `text` 里**真有**缺字形时才造（`*out_delete` 置 1，调用方用完
 * DeleteObject）；没缺就原样返回 `f` 且 `*out_delete` 置 0。返回值 0 = 没有
 * 可用的字体（调用方按系统默认处理）。
 *
 * 度量（`moonui_native_text_extent_font`）与绘制（`button_paint`）都走这
 * 一处：量的时候按替代字体的宽度算，画的时候用同一只，固有宽度才不会跟字
 * 对不上。 */
static HFONT moonui_native_font_fallback(HFONT f, LPCWSTR text,
                                         int *out_delete) {
  LOGFONTW lf;
  HDC dc;
  HFONT old;
  HFONT made;
  WORD glyphs[64];
  int len;
  int i;
  int j;
  int missing = 0;
  *out_delete = 0;
  if (f == 0 || text == 0) {
    return f;
  }
  len = lstrlenW(text);
  if (len <= 0) {
    return f;
  }
  dc = GetDC(0);
  if (dc == 0) {
    return f;
  }
  old = (HFONT)SelectObject(dc, f);
  for (i = 0; i < len && !missing; i += 64) {
    int chunk = (len - i > 64) ? 64 : (len - i);
    if (GetGlyphIndicesW(dc, text + i, chunk, glyphs,
                         GGI_MARK_NONEXISTING_GLYPHS) == GDI_ERROR) {
      break;
    }
    for (j = 0; j < chunk; j++) {
      if (glyphs[j] == 0xFFFF) {
        missing = 1;
        break;
      }
    }
  }
  SelectObject(dc, old);
  ReleaseDC(0, dc);
  if (!missing) {
    return f;
  }
  memset(&lf, 0, sizeof(lf));
  if (GetObjectW(f, (int)sizeof(lf), &lf) != (int)sizeof(lf)) {
    return f;
  }
  lstrcpynW(lf.lfFaceName, L"Segoe UI Symbol", LF_FACESIZE);
  lf.lfQuality = CLEARTYPE_QUALITY;
  made = CreateFontIndirectW(&lf);
  if (made == 0) {
    return f;
  }
  *out_delete = 1;
  return made;
}

/* 一段文字在指定字体下的尺寸（物理像素）。标签 / 按钮的 intrinsic 宽度都从
 * 这里来——GetTextExtentPoint32 必须先 SelectObject 进 DC 才问得到。
 * `font == 0` 表示按系统消息字体量（默认口径）；皮肤通道用 WM_SETFONT 换过
 * 字体的控件必须**用它自己那只字体**量，否则"量出来的宽"和"画出来的字"
 * 是两把尺（样式把字号调大之后，按钮的固有宽度不跟着长，字会被裁掉）。 */
static void moonui_native_text_extent_font(HFONT font, LPCWSTR w, int *out_w,
                                           int *out_h) {
  NONCLIENTMETRICSW ncm;
  HDC dc;
  HFONT used = font;
  HFONT created = 0;
  HFONT old;
  HFONT fb;
  int fb_delete;
  SIZE size = {0, 0};
  int len = w == 0 ? 0 : lstrlenW(w);
  if (w == 0 || len == 0) {
    *out_w = 0;
    *out_h = 0;
    return;
  }
  if (used == 0) {
    memset(&ncm, 0, sizeof(ncm));
    ncm.cbSize = (DWORD)sizeof(ncm);
    if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, (DWORD)sizeof(ncm), &ncm,
                              0) == 0) {
      *out_w = 0;
      *out_h = 0;
      return;
    }
    created = CreateFontIndirectW(&ncm.lfMessageFont);
    used = created;
  }
  if (used != 0) {
    dc = GetDC(0);
    if (dc != 0) {
      old = (HFONT)SelectObject(dc, used);
      /* 缺字形的钮量它的替代字体（`T131`），否则固有宽按 4 像素算，画出来
       * 却是替代字体那个宽的字。 */
      fb = moonui_native_font_fallback(used, w, &fb_delete);
      if (fb_delete) {
        SelectObject(dc, fb);
      }
      if (GetTextExtentPoint32W(dc, w, len, &size) == 0) {
        size.cx = 0;
        size.cy = 0;
      }
      SelectObject(dc, old);
      if (fb_delete) {
        DeleteObject(fb);
      }
      ReleaseDC(0, dc);
    }
    if (created != 0) {
      DeleteObject(created);
    }
  }
  *out_w = (int)size.cx;
  *out_h = (int)size.cy;
}

/* 消息字体口径的老入口（tax 那套不变：DLU 基准仍按消息字体算）。 */
static void moonui_native_text_extent(LPCWSTR w, int *out_w, int *out_h) {
  moonui_native_text_extent_font(0, w, out_w, out_h);
}

/* 控件自己挂的字体（皮肤通道 WM_SETFONT 装上去的那只）；没装过返回 0。 */
static HFONT moonui_native_control_font(HWND hwnd) {
  if (hwnd == 0) {
    return 0;
  }
  return (HFONT)(uintptr_t)SendMessageW(hwnd, WM_GETFONT, 0, 0);
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

int moonui_native_host_platform(void) {
  /* 血统不是运行时事实，是这个二进制的事实：2 = Windows（见 adapter.h 段注）。 */
  return 2;
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

/* ---- 进程级偏好读数（T87②/③）----
 * 两条都走 SystemParametersInfo 的查询（user32，已在 windowsNativeLinkFlags
 * 里）：concrete 常量与结构 mingw -fsyntax-only 查证过（2026-10-15——
 * SPI_GETCLIENTAREAANIMATION 的 BOOL、HIGHCONTRASTW + HCF_HIGHCONTRASTON，
 * MinGW 头文件里拼写全在，不用拍脑袋的旧名）。查询失败返回 0（偏好关），
 * 不设错误码——外观那条入口（注册表值对不上落回 0）同一条绕行。 */
/* 减少动态效果（T87③）：SPI_GETCLIENTAREAANIMATION 问"客户区动画开着吗"，
 * FALSE 才是偏好开（动画退场闸门，MoonBit 侧 pump 读它）。查不到（老系统）
 * 落 0 当关。 */
int moonui_native_prefers_reduced_motion(void) {
  BOOL anim;
  int on;
  TRACE("prefers_reduced_motion");
  anim = TRUE;
  if (SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &anim, 0) == 0) {
    return 0;
  }
  on = 0;
  if (anim == FALSE) {
    on = 1;
  }
  return on;
}

/* 增强对比度（T87②）：SPI_GETHIGHCONTRAST 填 HIGHCONTRASTW，dwFlags 里
 * HCF_HIGHCONTRASTON 置位才是偏好开。首版只做读口；消费点（主题读数档）
 * 第二版接。 */
int moonui_native_prefers_high_contrast(void) {
  HIGHCONTRASTW hc;
  int on;
  TRACE("prefers_high_contrast");
  hc.cbSize = (UINT)sizeof(hc);
  if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, (UINT)sizeof(hc), &hc, 0) ==
      0) {
    return 0;
  }
  on = 0;
  if ((hc.dwFlags & HCF_HIGHCONTRASTON) != 0) {
    on = 1;
  }
  return on;
}

/* ---- 生命周期：窗口类 + 初始化 ---- */

static const WCHAR moonui_native_wnd_class_name[] = L"MoonuiWndClass";
static const WCHAR moonui_native_container_class_name[] = L"MoonuiContainerClass";
/* 自定义绘制面（`T111`，§17 的 CustomWidget）：一只什么都不画的子窗口——
 * 布局给的矩形由它占住、内容是画布 present 上来的位图、点击/焦点/捕获由
 * 它自己的窗口过程接（见 moonui_native_custom_proc 那节）。类背景给 NULL：
 * 贴帧走 AlphaBlend，别让系统先糊一层底色。 */
static const WCHAR moonui_native_custom_class_name[] = L"MoonuiCustomClass";
/* 自绘面板（kind 17，皮肤账的载体）：底色与圆角由自己的过程用 GDI+ 画。
 * 类背景必须是 NULL——给了类背景刷，系统会把整块矩形刷成实色，四个圆角
 * 当场被刷平（圆角只在"我们自己画、且没被系统先刷过"时才存在）。 */
static const WCHAR moonui_native_panel_class_name[] = L"MoonuiPanelClass";

/* 客户区尺寸 → 外框尺寸（定义在窗口那一节，这里先声明：WM_GETMINMAXINFO 要
 * 把 ptMinTrackSize 换算成外框口径，而窗口过程在文件更前面）。 */
static void moonui_native_outer_size(HWND hwnd, int width, int height,
                                     int *out_w, int *out_h);

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
 *   MOONUI_WORK_MSG → worker 落地（`T85①`）：在 UI 线程执行 land 闭包并回收
 *                引用——外来投递经投递原语变成 UI 线程投递（adapter.h 的
 *                worker 段注）。
 * 其余（含 park 窗口收到的任何消息）交给 DefWindowProcW。 */
/* 画布贴帧（`T98`④ / `T111`）：把挂在 hwnd 属性表上的那只画布的当前帧
 * 预乘混进 dc 的整个客户区。没挂画布时不接手（返回 0 表示"我画了"，调用
 * 方拿这个值决定要不要落回 DefWindowProc）。实现在画布那节。 */
static int moonui_native_canvas_paint_layer(HWND hwnd, HDC dc);
/* 面板自绘（kind 17，皮肤通道）要用的三件画布设施——它们定义在文件后段的
 * 画布那节，这里先声明（面板过程在窗口过程这一节，排在前面）。 */
static void moonui_native_ensure_gdiplus(void);
static GpPath *moonui_canvas_rounded_path(int x, int y, int w, int h,
                                          double radius);
static ARGB moonui_canvas_argb(int64_t rgb, int alpha);
/* lParam 里的坐标解包（定义在鼠标那节，这里先用）：SHORT 折回、负数也认。 */
static int moonui_native_lx_of(LPARAM p);
static int moonui_native_ly_of(LPARAM p);
/* 画底的控件重画时要连带重画压在它上面的透明标签（`T140`），定义在
 * `moonui_native_sync_transparent` 之后。 */
static void moonui_native_invalidate(HWND hwnd, int erase);
/* 自绘面补底用的两件（`T311`）：问"这块底下是什么色"与按色填一块矩形。
 * 两者都定义在窗口过程这一节之后（`moonui_native_under_color_of` /
 * `moonui_native_fill_rect_rgb`），这里先声明。 */
static int64_t moonui_native_under_color_of(HWND hwnd, int64_t own);
static void moonui_native_fill_rect_rgb(HDC dc, int w, int h, int64_t rgb);

/* 自绘面底下那块底色（`T311`）。
 *
 * 为什么非得补：kind 18 的帧是一张**只有落笔处不透明**的位图——画布
 * `begin_frame` 只把位面 memset 成 0，清单里没画到的地方 alpha 全 0。而
 * `AlphaBlend` 对 alpha=0 的源像素**不动目标**，于是这块矩形里"清单没画到"
 * 的部分保留的是它下面那层上一次合成进来的像素。偏偏它下面也没有人补：
 * 同父的 Panel 带 `WS_CLIPSIBLINGS`，压在上面的兄弟（就是这只面自己）那一格
 * 它画不到；顶层窗又是沉浸式的（`WM_ERASEBKGND` 回 1、客户区从不落笔）。
 * 结果这一整格永远停着"窗口第一次盖住屏幕时的那块像素"——用户看到的是背后
 * 窗口的一张快照，拖动窗口也不变（2026-11-17 owner 报的歌词秀那块面，
 * 360×120 的矩形里透出的是别人的窗口）。
 *
 * mac 半没有这个洞：NSView 的图层按 alpha 合成，透明处自然透出底下那块视图。
 * Windows 的子窗口不是合成的（各自的表面是实心的），等价语义只能自己补：
 * 先按布局树问出"这块底下是什么色"（`moonui_native_under_color_of`，与
 * `T135` 圆角垫底同一把尺，沿 holder 走），把整块客户区铺一遍，再叠画布帧。
 *
 * 问不到色（返回 -1）时**不铺**：宁可留旧行为，也不要拿一个猜出来的色把别处
 * 盖错——那种错在真窗上比一个洞更难认。 */
static void moonui_native_custom_fill_under(HWND hwnd, HDC dc) {
  RECT rc;
  int64_t color;
  if (dc == 0) {
    return;
  }
  if (GetClientRect(hwnd, &rc) == 0 || rc.right <= 0 || rc.bottom <= 0) {
    return;
  }
  color = moonui_native_under_color_of(hwnd, -1);
  if (color < 0) {
    return;
  }
  moonui_native_fill_rect_rgb(dc, rc.right, rc.bottom, color);
}

/* 自定义绘制面（`T111`）的窗口过程。这只窗口自己什么都不画——帧由画布
 * present 上来（WM_PAINT 读 moonui.canvas 那枚 prop），行为对齐 mac 半的
 * MoonuiCustomView：
 *   - 点击：按下并原地抬起才算一次（与按钮的判定同一条），抬起点在面外
 *     不算——按住拖出去松手是"取消"，不是"提交"；不吞别的鼠标消息，
 *     拖动/滚轮照常经钩子上报（拖动的收件人由捕获钉住，见下）。
 *   - 焦点：默认不抢（否则每块面都挤进 Tab 链、还会从文本框手里抢焦点），
 *     custom_set_focusable 声明过的面在按下那一刻 SetFocus 自己。
 *   - 捕获（`T102` 第十三刀）：按下 SetCapture、抬起 ReleaseCapture——
 *     拖出面外后 WM_MOUSEMOVE / WM_LBUTTONUP 仍投给这块面，DataGrid 那类
 *     拖拽重排才收得到"抬起提交"。捕获被别人拆走（WM_CAPTURECHANGED）
 *     时把按住标志一并清掉，别让下一颗无主抬起误判成点击。 */
/* 画一帧：先补底下那块底色（`T311`，见 `moonui_native_custom_fill_under`），
 * 再把画布帧叠上去。还没 present 过（属性表上没有 canvas）时只剩补底那一步
 * ——那也正是"面还没出帧"时该有的样子：一块干净的底色，不是背后的窗口。 */
static void moonui_native_custom_paint(HWND hwnd, HDC dc) {
  if (dc == 0) {
    return;
  }
  moonui_native_custom_fill_under(hwnd, dc);
  if (GetPropW(hwnd, moonui_native_canvas_prop) != 0) {
    moonui_native_canvas_paint_layer(hwnd, dc);
  }
}

static LRESULT CALLBACK moonui_native_custom_proc(HWND hwnd, UINT msg,
                                                  WPARAM wp, LPARAM lp) {
  if (msg == WM_PAINT) {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    moonui_native_custom_paint(hwnd, dc);
    if (dc != 0) {
      EndPaint(hwnd, &ps);
    }
    return 0;
  }
  /* 离屏重画（探针那条路，`T311`）：与 WM_PAINT 共用同一份画法，判据才能在
   * 一块自己填过色的 DC 上验「补底有没有真发生」，不受屏幕上原本是什么影响。 */
  if (msg == WM_PRINTCLIENT) {
    moonui_native_custom_paint(hwnd, (HDC)wp);
    return 0;
  }
  if (msg == WM_SIZE) {
    /* 帧与矩形不等大由 paint_layer 拉伸对齐（mac 的 layer gravity 同款） */
    moonui_native_invalidate(hwnd, 0);
    return 0;
  }
  if (msg == WM_LBUTTONDOWN) {
    if (GetPropW(hwnd, moonui_native_custom_focusable_prop) != 0) {
      SetFocus(hwnd);
    }
    SetPropW(hwnd, moonui_native_custom_pressed_prop, (HANDLE)1);
    SetCapture(hwnd);
    return 0;
  }
  if (msg == WM_LBUTTONUP) {
    POINT pt;
    RECT rc;
    if (GetPropW(hwnd, moonui_native_custom_pressed_prop) != 0) {
      SetPropW(hwnd, moonui_native_custom_pressed_prop, (HANDLE)0);
      ReleaseCapture();
      pt.x = moonui_native_lx_of(lp);
      pt.y = moonui_native_ly_of(lp);
      if (GetClientRect(hwnd, &rc) != 0 && pt.x >= rc.left &&
          pt.x < rc.right && pt.y >= rc.top && pt.y < rc.bottom) {
        moonui_native_fire_slot_prop(hwnd, moonui_native_slot_customclick_prop);
      }
    }
    return 0;
  }
  if (msg == WM_CAPTURECHANGED) {
    SetPropW(hwnd, moonui_native_custom_pressed_prop, (HANDLE)0);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

/* 自绘面板（kind 17，皮肤通道的 Windows 落点）的窗口过程。
 *
 * 为什么不复用 STATIC：STATIC 的类背景刷会把整块矩形刷成实色，圆角在系统那
 * 一层就被刷平了——要真圆角就得自己画。所以 kind 17 是一只自注册窗口类的
 * 子窗口，类背景 NULL，WM_PAINT 里按 skin prop 画：有圆角走 GDI+ 的圆角路径，
 * 直角就走 FillRect（省一次 GDI+ 上下文开关）。
 *
 * 底色没设过时**什么都不画**（透出父窗的底色）。这与 mac 半的 NSView 语义
 * 一致：Panel 没给背景就是一块透明底板，不是一块白板——lunamusic 的树里
 * Panel 大量当"分层的容器"用，给它默认白底会把整片界面洗成白色。
 *
 * `WS_EX_TRANSPARENT` **跟着底色有无翻**（`T117`，2026-10-23 修）：没有底色的
 * Panel 什么都不画、要这个位让兄弟先铺满；有底色的 Panel 自己填满整块，必须摘
 * 掉——留着它等于把这只排到所有兄弟之后画，变成盖住内容的覆盖层。开关在
 * `moonui_native_sync_transparent`，由 `widget_set_style` 按底色调。
 *
 * 至于"点击穿透"那桩与这一位无关（`WS_EX_TRANSPARENT` 不管命中）：Panel 盖在
 * 兄弟上面、点击要能穿到层级更低的真控件，那是 Core 的 `hit_test` 在算（按
 * paint order 反过来搜）。`T256` 起 Panel 自己也接单击（列表行/卡片的
 * `on_click` 挂在这一层），派发见本过程 WM_LBUTTONUP 那一支；落在真控件上
 * 仍归控件，命中优先级由 Core 的 hit_test 定，这一位不管命中。 */
/* 圆角的物理像素值（-1 = 没设过）。Panel(17) 与平面钮(1/14) 共用这一把尺。
 *
 * `moonui_native_widget_set_style` 收的 radius 是**逻辑点 ×1000**（与 mac 半
 * 同一把尺：那边直接把它除以 1000 交给 CALayer 的 cornerRadius，AppKit 自己
 * 按 backing scale 放大）。GDI+ 不知道缩放，画的是物理像素，所以这里得自己
 * 乘一次 dpi/96——不乘的话 1.25 倍的屏上圆角只有该有的八成，看着像"有那么个
 * 意思"却没量对。 */
static int moonui_native_radius_px(HWND hwnd) {
  HANDLE rad = GetPropW(hwnd, moonui_native_radius_prop);
  int pt1000;
  if (rad == 0) {
    return -1;
  }
  pt1000 = (int)(uintptr_t)rad - 1;
  if (pt1000 < 0) {
    return -1;
  }
  return (int)(((long long)pt1000 * (long long)moonui_native_dpi_of(hwnd) +
                96000LL) /
               192000LL);
}

/* 一块实色（`fill_round` 的两条腿都用它：直角那条的全部、圆角那条的垫底）。 */
static void moonui_native_fill_rect_rgb(HDC dc, int w, int h, int64_t rgb) {
  RECT r;
  HBRUSH brush = CreateSolidBrush(moonui_native_colorref_of(rgb));
  if (brush == 0) {
    return;
  }
  r.left = 0;
  r.top = 0;
  r.right = w;
  r.bottom = h;
  FillRect(dc, &r, brush);
  DeleteObject(brush);
}

/* 窗口类背景刷给的颜色（只认系统色刷那种，值形如 `COLOR_* + 1`）。
 *
 * 这是标准顶层窗口真在那块画的东西：`WM_ERASEBKGND` 交给 `DefWindowProc` 时
 * 它拿类背景刷把客户区刷一遍（`T114` 的皮肤通道还没接窗口底色那一层）。
 * 沉浸式窗问不到——它的 `WM_ERASEBKGND` 回 1、客户区从不落笔（`T126` 的
 * 决定），底下是自绘内容，返回 -1 让调用方退回自己的色。
 *
 * 系统色刷的编码是 `索引 + 1`（0 号不是合法的刷子句柄）：索引 0..30 覆盖
 * winuser.h 的全部 `COLOR_*`，比这大的才是真刷子句柄，这一档问不出来。 */
#define MOONUI_SYSTEM_BRUSH_MAX 31
static int64_t moonui_native_window_bg_of(HWND hwnd) {
  HWND root = GetAncestor(hwnd, GA_ROOT);
  HBRUSH brush;
  MoonuiWindowMenu *e;
  if (root == 0) {
    return -1;
  }
  e = moonui_native_menu_entry_of(root);
  if (e != 0 && e->immersive) {
    return -1;
  }
  brush = (HBRUSH)(uintptr_t)GetClassLongPtrW(root, GCLP_HBRBACKGROUND);
  if ((uintptr_t)brush == 0 || (uintptr_t)brush > MOONUI_SYSTEM_BRUSH_MAX) {
    return -1;
  }
  return moonui_native_rgb_of_colorref(GetSysColor((int)(uintptr_t)brush - 1));
}

/* `T332`：布局树上**真有**一块画纯色的祖先 Panel 才算有底；不退回窗口类
 * 背景。透明标签的 ClearType 彩边需要按底下那块实色混合，但自绘 / 图片底的
 * 面板（播放条）拿不到这样的纯色——那种情况若拿窗口类背景白去混合，白字就
 * 被铺成白块（实测，owner 2026-11-20 截图）。与 `under_color_of` 走同一条
 * holder / parent 链，只是这里不兜底，让调用方区分"找不到"和"找到了白"。 */
static int64_t moonui_native_layout_bg_of(HWND hwnd) {
  HWND p = hwnd;
  int guard = 0;
  if (hwnd == 0) {
    return -1;
  }
  while (guard < 64) {
    HWND up = (HWND)(uintptr_t)GetPropW(p, moonui_native_holder_prop);
    int64_t bg;
    if (up == 0) {
      up = GetParent(p);
    }
    if (up == 0 || up == p) {
      break;
    }
    p = up;
    bg = moonui_native_rgb_prop(p, moonui_native_bg_prop);
    if (bg >= 0) {
      return bg;
    }
    guard += 1;
  }
  return -1;
}

/* 圆角 AA 的垫底颜色：**布局树**上最近一块有底色的 Panel（`T135`）。
 *
 * 为什么非得垫：GDI+ 的 `GdipFillPath` 在边界像素上只覆盖一部分，剩下的分量
 * 混的是**这块 DC 里已有的内容**。子窗口（频谱小方块、圆角 Panel）画之前那块
 * 区域是空的——父窗开着 `WS_CLIPCHILDREN`，子窗口矩形里它一笔不落（`T117` 同
 * 一条账）——空 = 全零，于是边缘混成半截黑、圆角那一颗像素干脆是纯 `#000000`
 * （`T135` 量到的 16 段 × 7 颗各一颗 + 外框角上三颗）。真窗上这些像素由 DWM
 * 按"透明"合成，透出窗口后面的东西。
 *
 * 垫父窗的底色而不是自己的：圆角过渡本该是"自己的色 → 底下的色"，父色垫进去
 * 正好还原这个过渡（两者同色时边界本来就看不出，也不亏）。父链沿 **holder**
 * 走（见 moonui_native_holder_prop）——Panel 的子树被平铺挂到父窗口之后，
 * `GetParent` 只到窗口为止，祖先 Panel 的底色就再也问不到了。到顶都没人报
 * 底色时问顶层窗口的类背景（标准窗就是它在那块真画的色）；沉浸式窗或问不到
 * 时退回自己的色——洞先没了，圆角只在那一档变成直角。 */
static int64_t moonui_native_under_color_of(HWND hwnd, int64_t own) {
  HWND p = hwnd;
  int guard = 0;
  if (hwnd == 0) {
    return own;
  }
  while (guard < 64) {
    HWND up = (HWND)(uintptr_t)GetPropW(p, moonui_native_holder_prop);
    int64_t bg;
    if (up == 0) {
      up = GetParent(p);
    }
    if (up == 0 || up == p) {
      break;
    }
    p = up;
    bg = moonui_native_rgb_prop(p, moonui_native_bg_prop);
    if (bg >= 0) {
      return bg;
    }
    guard += 1;
  }
  {
    int64_t wbg = moonui_native_window_bg_of(hwnd);
    if (wbg >= 0) {
      return wbg;
    }
  }
  return own;
}

/* 一块圆角实色（Panel 的底与平面钮的脸共用这一份）。`radius < 1` 走 GDI 的
 * FillRect（省一次 GDI+ 上下文开关），否则先拿 `under` 铺满整块、再走 GDI+
 * 的圆角路径——矩形与半径都已是物理像素（半径的换算在
 * moonui_native_radius_px）。抗锯齿会把四个角画成半透明过渡，那正是圆角该有
 * 的样子；`under` 就是这个过渡底下该混的色（见
 * moonui_native_under_color_of）。 */
static void moonui_native_fill_round(HDC dc, int w, int h, int radius,
                                     int64_t rgb, int64_t under) {
  if (dc == 0 || w <= 0 || h <= 0) {
    return;
  }
  if (radius < 1) {
    moonui_native_fill_rect_rgb(dc, w, h, rgb);
    return;
  }
  {
    GpGraphics *gfx = 0;
    GpPath *path;
    GpBrush *brush = 0;
    moonui_native_fill_rect_rgb(dc, w, h, under);
    moonui_native_ensure_gdiplus();
    if (GdipCreateFromHDC(dc, &gfx) == MOONUI_GDIP_OK && gfx != 0) {
      path = moonui_canvas_rounded_path(0, 0, w, h, (double)radius);
      if (path != 0) {
        if (GdipCreateSolidFill(moonui_canvas_argb(rgb, 255), &brush) ==
                MOONUI_GDIP_OK &&
            brush != 0) {
          GdipSetSmoothingMode(gfx, MOONUI_GDIP_SMOOTH_ANTIALIAS);
          GdipFillPath(gfx, brush, path);
          GdipDeleteBrush(brush);
        }
        GdipDeletePath(path);
      }
      GdipDeleteGraphics(gfx);
    }
  }
}

/* 面板的画：底色 + 圆角。WM_PAINT 与 WM_PRINTCLIENT 共用这一份，所以
 * "屏幕上看到的"和"探针离屏画出来的"是同一条代码路径（像素探针靠后者，
 * 不必去读屏幕）。 */
static void moonui_native_panel_paint(HWND hwnd, HDC dc) {
  RECT r;
  int64_t bg = moonui_native_rgb_prop(hwnd, moonui_native_bg_prop);
  int w;
  int h;
  if (dc == 0 || GetClientRect(hwnd, &r) == 0) {
    return;
  }
  w = r.right - r.left;
  h = r.bottom - r.top;
  if (bg < 0 || w <= 0 || h <= 0) {
    return;
  }
  moonui_native_fill_round(dc, w, h, moonui_native_radius_px(hwnd), bg,
                            moonui_native_under_color_of(hwnd, bg));
}

static LRESULT CALLBACK moonui_native_panel_proc(HWND hwnd, UINT msg,
                                                 WPARAM wp, LPARAM lp) {
  if (msg == WM_PAINT) {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    if (dc != 0) {
      TRACE_AT("panel_paint", hwnd);
      moonui_native_panel_paint(hwnd, dc);
      EndPaint(hwnd, &ps);
    }
    return 0;
  }
  if (msg == WM_PRINTCLIENT) {
    /* 离屏重画（探针那条路）：draw 进调用方给的 DC，语义与 WM_PAINT 同。 */
    moonui_native_panel_paint(hwnd, (HDC)(uintptr_t)wp);
    return 0;
  }
  if (msg == WM_NCHITTEST) {
    /* 沉浸式窗的顶条就是一块 Panel：它要是不接这一问，鼠标落在条上的空白处
     * 就停在 Panel 上，拖动带永远轮不到顶层窗口判（`T116`）。落在父窗拖动带
     * 里的点回 HTTRANSPARENT，让系统把命中交回父窗——父窗的
     * moonui_native_immersive_hit 在那里报 HTCAPTION。
     *
     * 只在这一种情形下回：Panel 是"分层容器"的主力（lunamusic 整片界面都是
     * 它），无条件透明会改掉所有既有的命中归属。条上的按钮是 Panel 的**兄弟**
     * （kind 17 的子树平铺到父窗），它们各自接自己的命中，不受这条影响。 */
    {
      HWND parent = GetParent(hwnd);
      MoonuiWindowMenu *e = parent != 0 ? moonui_native_menu_entry_of(parent) : 0;
      if (e != 0 && e->immersive && e->drag_h > 0) {
        POINT pt;
        RECT wr;
        pt.x = (int)(SHORT)LOWORD(lp);
        pt.y = (int)(SHORT)HIWORD(lp);
        if (GetWindowRect(parent, &wr) != 0 &&
            pt.y - wr.top >= 0 && pt.y - wr.top < e->drag_h) {
          return HTTRANSPARENT;
        }
      }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_SIZE) {
    /* 矩形变了要重画一遍底（类背景 NULL，系统不会替我们刷）。顺带把压在
     * 这条带上的透明标签拖着重画（`T140`，见 `moonui_native_invalidate`）。 */
    moonui_native_invalidate(hwnd, 1);
    return 0;
  }
  if (msg == WM_ERASEBKGND) {
    /* 背景由 WM_PAINT 按圆角画，别让系统先刷一层方的。 */
    return 1;
  }
  /* T256：面板的 Click 源，形状与 moonui_native_custom_proc 那一支同构——
   * 按下记一笔，抬起时点仍在自己客户区内才 fire；拖出去抬或没按过就抬
   * 都不算一次单击。不 SetCapture：mac 半的 MoonuiClickPanel 也不开跟踪
   * 循环，两侧语义一致（真人把鼠标拖出面板再松手，同样不发 Click）。 */
  if (msg == WM_LBUTTONDOWN) {
    SetPropW(hwnd, moonui_native_custom_pressed_prop, (HANDLE)1);
    return 0;
  }
  if (msg == WM_LBUTTONUP) {
    if (GetPropW(hwnd, moonui_native_custom_pressed_prop) != 0) {
      POINT pt;
      RECT rc;
      SetPropW(hwnd, moonui_native_custom_pressed_prop, (HANDLE)0);
      pt.x = moonui_native_lx_of(lp);
      pt.y = moonui_native_ly_of(lp);
      if (GetClientRect(hwnd, &rc) != 0 && pt.x >= rc.left &&
          pt.x < rc.right && pt.y >= rc.top && pt.y < rc.bottom) {
        moonui_native_fire_slot_prop(hwnd, moonui_native_slot_customclick_prop);
      }
    }
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

/* ---- 平面钮（`T115`①：Button(1) / MenuRow(14) 的底色真画出来）----
 *
 * 为什么不能用 `WM_CTLCOLORBTN`：comctl32 v6 的主题绘制接管了 push button
 * 的整块脸，那条消息对它**整条失效**（系统照样画主题脸），所以皮肤通道的
 * `background` 在按钮上曾经是"记下来了、画不出来"。
 *
 * 这一刀的做法是**子类化而不换样式**：`SetWindowLongPtrW` 换掉按钮的过程
 * （与 IME 那半同一套手法），只在我们**自己**有底色时接住 `WM_PAINT` /
 * `WM_PRINTCLIENT` / `WM_ERASEBKGND`，其余消息一律链回原过程。
 *
 * 为什么不走 `BS_OWNERDRAW`（`TODO` 里原来写的那条）：owner-draw 把绘制
 * 交给**父窗口**的 `WM_DRAWITEM`，而这里的父窗口有三种（顶层窗口、滚动视口、
 * 单选组容器），每一种都得再开一条转发；而且 `BCM_GETIDEALSIZE` 对
 * owner-draw 钮不再回答，固有尺寸那支要跟着重写。子类化这条路把这两笔全绕开：
 * 控件本身仍是标准 BUTTON，`BN_CLICKED` / `BM_GETCHECK` / `BCM_GETIDEALSIZE`
 * 一条都不动，改的只是"这支笔画不画脸"。代价是按下/禁用/焦点这三态得自己
 * 问、自己画（下面逐条注）。
 *
 * 圆角用 `SetWindowRgn`（不是把角画成透明）：子窗口的像素在区域之外就**不
 * 属于它**，底下那层（同级 Panel / 父窗口）的画自然透出来——这正是 mac 半
 * cornerRadius 的语义。若改成"在 DC 里把角涂成别的颜色"，那个颜色从哪来
 * 又是一笔新账（父窗底色在 Windows 上不是控件能读到的属性）。 */

/* 四态的脸：皮肤通道只有**一个**底色字段（没有悬停色 / 按下色），所以
 * 悬停与按下从底色自己推——亮的往黑走、暗的往白走（`moonui_native_luminance`
 * 决定方向），比例只取够看出"这一下动了"的量，不引入第二份配色。
 * 禁用态往中性灰靠：比"淡一点的同色"更容易一眼看出不能点。 */
static int64_t moonui_native_button_face(int64_t bg, int state) {
  int lum = moonui_native_luminance(bg);
  int64_t toward = lum > 140 ? (int64_t)0x000000 : (int64_t)0xFFFFFF;
  if (state == 3) {
    /* 禁用：往中性灰偏，同时压掉对比度。 */
    return moonui_native_mix_rgb(
        moonui_native_mix_rgb(bg, (int64_t)0x000000, 12), (int64_t)0xF0F0F0, 62);
  }
  if (state == 2) {
    return moonui_native_mix_rgb(bg, toward, 18); /* 按下 */
  }
  if (state == 1) {
    return moonui_native_mix_rgb(bg, toward, 8); /* 悬停 */
  }
  return bg;
}

/* 按钮此刻该画哪一态。按下**不问自己记的标志**：`BM_GETSTATE` 的
 * `BST_PUSHED` 就是按钮控件内部那份"正被按住"的状态（系统在 WM_LBUTTONDOWN
 * 里置、抬起里清），问它比自己记一份更准——捕获被抢、拖动出界这些边界它
 * 自己已经处理过了。悬停则是我们自己 TrackMouseEvent 记的（系统没有对应的
 * 可读状态）。 */
static int moonui_native_button_state(HWND hwnd) {
  if (IsWindowEnabled(hwnd) == 0) {
    return 3;
  }
  if ((SendMessageW(hwnd, BM_GETSTATE, 0, 0) & BST_PUSHED) != 0) {
    return 2;
  }
  if (GetPropW(hwnd, moonui_native_button_hot_prop) != 0) {
    return 1;
  }
  return 0;
}

/* ---- 图标（`T131`：Windows 半的 `set_icon` 第一次真画）----
 *
 * 这一刀之前 `moonui_native_widget_set_icon` 是一只直接 `return 0` 的空桩
 * （`T115`② 记在案），lunamusic 的走带四钮靠**文字**兜底：mac 走 SF Symbol
 * 只看图，Windows 看 `⏮ ▶ ⏹ ⏭` 这些字。问题是 U+23EE/23ED/23F9 这一族
 * 在 GDI 的字形链接里拿不到（live 控件 `GetTextExtentPoint32` 量出 4 像素宽
 * = 缺字形），画出来是两个豆腐块；`▶` 能画但那是**正文字体**里的几何字符，
 * 基线排版把它的重心压在按钮中心下面几个像素；模式钮标题本来就是空串（mac
 * 只看图），Windows 上于是整颗空白。owner 截图里的"按钮显示异常 / 播放按钮
 * 没有居中 / 按钮空白"三条都是这一件事（`T131`）。
 *
 * 做法与 mac 对齐而不是"换一套能画的字"：名字认得的按**矢量**画在按钮正
 * 中央——重心由坐标决定，不吃字体基线；名字不认得的照旧回退文字兜底（mac
 * 取不到 SF Symbol 时也是保文字）。名字表只收当前几个 Demo 真用到的那些，
 * 缺的按"回退文字"处理，不做假实现。
 *
 * 归一的图标框是 [0,1]×[0,1]，实际边长取按钮短边减 4 物理像素、居中对齐。 */

/* 归一化多边形顶点（x,y 成对出现）。 */
static void moonui_native_icon_poly(GpPath *path, double x0, double y0,
                                    double s, const double *pts, int n) {
  GpPointF p[8];
  int i;
  if (path == 0 || pts == 0 || n <= 0 || n > 8) {
    return;
  }
  for (i = 0; i < n; i++) {
    p[i].X = (REAL)(x0 + pts[i * 2] * s);
    p[i].Y = (REAL)(y0 + pts[i * 2 + 1] * s);
  }
  GdipAddPathPolygon(path, p, n);
}

/* 归一化矩形（x,y,w,h 都是图标框里的比值）。 */
static void moonui_native_icon_rect(GpPath *path, double x0, double y0, double s,
                                    double rx, double ry, double rw,
                                    double rh) {
  if (path == 0) {
    return;
  }
  GdipAddPathRectangle(path, (REAL)(x0 + rx * s), (REAL)(y0 + ry * s),
                       (REAL)(rw * s), (REAL)(rh * s));
}

/* 归一化线段。 */
static void moonui_native_icon_line(GpPath *path, double x0, double y0, double s,
                                    double x1, double y1, double x2,
                                    double y2) {
  if (path == 0) {
    return;
  }
  GdipAddPathLine(path, (REAL)(x0 + x1 * s), (REAL)(y0 + y1 * s),
                  (REAL)(x0 + x2 * s), (REAL)(y0 + y2 * s));
}

/* 把图标画进 `dc` 的 (0,0,w,h) 那块，颜色 `fg`。画成了返回 1（调用方不再
 * 画标题），名字不认识返回 0。 */
static int moonui_native_draw_icon(HWND hwnd, HDC dc, int w, int h, int64_t fg) {
  static const double play_pts[] = {0.30, 0.15, 0.30, 0.85, 0.80, 0.50};
  static const double back_tri[] = {0.86, 0.13, 0.86, 0.87, 0.34, 0.50};
  static const double fwd_tri[] = {0.14, 0.13, 0.14, 0.87, 0.66, 0.50};
  static const double head_r[] = {0.70, 0.22, 0.94, 0.36, 0.70, 0.50};
  static const double head_l[] = {0.30, 0.50, 0.06, 0.64, 0.30, 0.78};
  char *name = (char *)(uintptr_t)GetPropW(hwnd, moonui_native_icon_prop);
  GpGraphics *gfx = 0;
  GpPath *fill = 0;
  GpPath *lines = 0;
  GpBrush *brush = 0;
  GpPen *pen = 0;
  ARGB argb;
  int s;
  int x0;
  int y0;
  int known = 1;
  if (dc == 0 || name == 0 || name[0] == '\0' || w <= 0 || h <= 0) {
    return 0;
  }
  s = (w < h ? w : h) - 4;
  if (s < 6) {
    s = (w < h ? w : h);
  }
  if (s < 4) {
    return 0;
  }
  x0 = (w - s) / 2;
  y0 = (h - s) / 2;
  argb = moonui_canvas_argb(fg, 255);
  moonui_native_ensure_gdiplus();
  if (GdipCreateFromHDC(dc, &gfx) != MOONUI_GDIP_OK || gfx == 0) {
    return 0;
  }
  GdipSetSmoothingMode(gfx, MOONUI_GDIP_SMOOTH_ANTIALIAS);
  if (GdipCreatePath(MOONUI_GDIP_FILLMODE_WINDING, &fill) != MOONUI_GDIP_OK) {
    fill = 0;
  }
  if (strcmp(name, "play.fill") == 0) {
    moonui_native_icon_poly(fill, x0, y0, s, play_pts, 3);
  } else if (strcmp(name, "pause.fill") == 0) {
    moonui_native_icon_rect(fill, x0, y0, s, 0.24, 0.16, 0.18, 0.68);
    moonui_native_icon_rect(fill, x0, y0, s, 0.58, 0.16, 0.18, 0.68);
  } else if (strcmp(name, "stop.fill") == 0) {
    moonui_native_icon_rect(fill, x0, y0, s, 0.22, 0.22, 0.56, 0.56);
  } else if (strcmp(name, "backward.fill") == 0) {
    moonui_native_icon_rect(fill, x0, y0, s, 0.16, 0.16, 0.13, 0.68);
    moonui_native_icon_poly(fill, x0, y0, s, back_tri, 3);
  } else if (strcmp(name, "forward.fill") == 0) {
    moonui_native_icon_poly(fill, x0, y0, s, fwd_tri, 3);
    moonui_native_icon_rect(fill, x0, y0, s, 0.71, 0.16, 0.13, 0.68);
  } else if (strcmp(name, "repeat") == 0 || strcmp(name, "repeat.1") == 0 ||
             strcmp(name, "shuffle") == 0) {
    if (GdipCreatePath(MOONUI_GDIP_FILLMODE_WINDING, &lines) !=
        MOONUI_GDIP_OK) {
      lines = 0;
    }
    if (strcmp(name, "shuffle") == 0) {
      /* 交叉的两支箭头（随机播放）。 */
      moonui_native_icon_line(lines, x0, y0, s, 0.16, 0.30, 0.70, 0.70);
      moonui_native_icon_line(lines, x0, y0, s, 0.16, 0.70, 0.70, 0.30);
      moonui_native_icon_poly(fill, x0 + 0.04 * s, y0 + 0.34 * s, s, head_r, 3);
      moonui_native_icon_poly(fill, x0 + 0.04 * s, y0 - 0.06 * s, s, head_r, 3);
    } else {
      /* 单曲循环 / 列表循环：两条同向回路（上→右、下→左），repeat.1 多一
       * 竖笔当"1"。 */
      moonui_native_icon_line(lines, x0, y0, s, 0.20, 0.36, 0.72, 0.36);
      moonui_native_icon_line(lines, x0, y0, s, 0.80, 0.64, 0.28, 0.64);
      moonui_native_icon_poly(fill, x0, y0, s, head_r, 3);
      moonui_native_icon_poly(fill, x0, y0, s, head_l, 3);
      if (strcmp(name, "repeat.1") == 0) {
        moonui_native_icon_line(lines, x0, y0, s, 0.50, 0.40, 0.50, 0.60);
      }
    }
  } else {
    known = 0;
  }
  if (known) {
    if (fill != 0 && GdipCreateSolidFill(argb, &brush) == MOONUI_GDIP_OK &&
        brush != 0) {
      GdipFillPath(gfx, brush, fill);
      GdipDeleteBrush(brush);
      brush = 0;
    }
    if (lines != 0 &&
        GdipCreatePen1(argb, (REAL)(s * 0.11 < 1.0 ? 1.0 : s * 0.11),
                       MOONUI_GDIP_UNIT_PIXEL, &pen) == MOONUI_GDIP_OK &&
        pen != 0) {
      GdipDrawPath(gfx, pen, lines);
      GdipDeletePen(pen);
      pen = 0;
    }
  }
  if (fill != 0) {
    GdipDeletePath(fill);
  }
  if (lines != 0) {
    GdipDeletePath(lines);
  }
  GdipDeleteGraphics(gfx);
  return known;
}

/* 画一张平面脸 + 标题 + 焦点框。返回 1 = 画了（有底色），0 = 没底色、
 * 调用方该把这一笔交回系统过程。 */
static int moonui_native_button_paint(HWND hwnd, HDC dc, int w, int h) {
  int64_t bg = moonui_native_rgb_prop(hwnd, moonui_native_bg_prop);
  int64_t fg;
  int64_t face;
  int state;
  RECT r;
  HFONT font;
  HFONT created = 0;
  HFONT old = 0;
  HFONT sym = 0;
  int sym_delete = 0;
  WCHAR *text;
  int n;
  if (dc == 0 || bg < 0 || w <= 0 || h <= 0) {
    return 0;
  }
  state = moonui_native_button_state(hwnd);
  face = moonui_native_button_face(bg, state);
  if (state != 3 && moonui_native_kind_of_hwnd(hwnd) == 14 &&
      SendMessageW(hwnd, BM_GETCHECK, 0, 0) == BST_CHECKED) {
    /* MenuRow 的选中态（§51 画册左栏）：系统那只"按下去的脸"跟着主题脸
     * 一起被我们换掉了，这里按系统的高亮色补回来——与 mac 半拿
     * selectedContentBackgroundColor 铺底同一条语义（选中由 Core 推，见
     * widget_set_checked）。悬停 / 按下仍在其上叠一层，所以看不出"点不动"。 */
    face = moonui_native_mix_rgb(
        face, moonui_native_rgb_of_colorref(GetSysColor(COLOR_HIGHLIGHT)), 45);
  }
  r.left = 0;
  r.top = 0;
  r.right = w;
  r.bottom = h;
  /* 脸按圆角路径画（不是直角再靠区域剪一刀）：屏幕上由 SetWindowRgn 保证
   * 角外面透出底下的画，WM_PRINTCLIENT 那条路没有区域，靠的就是这一笔
   * 圆角——两条路因此是同一个形状，探针读到的就是屏幕上的。 */
  moonui_native_fill_round(dc, w, h, moonui_native_radius_px(hwnd), face,
                            moonui_native_under_color_of(hwnd, face));
  /* 标题：文字色沿用皮肤通道下发的 fg；没给过就退回系统的按钮文字色。
   * 禁用态把文字也压淡一档（与脸同一条"看得出不能点"）。 */
  fg = moonui_native_rgb_prop(hwnd, moonui_native_fg_prop);
  if (fg < 0) {
    fg = moonui_native_rgb_of_colorref(GetSysColor(COLOR_BTNTEXT));
  }
  if (state == 3) {
    fg = moonui_native_mix_rgb(fg, face, 55);
  }
  /* 图标钮先画图（`T131`）：画成了就不再叠标题，与 mac 半 `set_icon` 把
   * imagePosition 设成 NSImageOnly 同一条语义。名字不认得的（普通文字钮、
   * 以及还没实现的那几个）照旧走下面这条文字路。 */
  if (!moonui_native_draw_icon(hwnd, dc, w, h, fg)) {
    n = GetWindowTextLengthW(hwnd);
    text = 0;
    if (n > 0) {
      text = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
      if (text != 0) {
        text[0] = L'\0';
        GetWindowTextW(hwnd, text, n + 1);
      }
    }
    font = moonui_native_control_font(hwnd);
    if (font == 0) {
      NONCLIENTMETRICSW ncm;
      memset(&ncm, 0, sizeof(ncm));
      ncm.cbSize = (DWORD)sizeof(ncm);
      if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, (DWORD)sizeof(ncm),
                                &ncm, 0) != 0) {
        created = CreateFontIndirectW(&ncm.lfMessageFont);
        font = created;
      }
    }
    if (font != 0) {
      old = (HFONT)SelectObject(dc, font);
    }
    /* 标题里有系统 UI 字体缺的符号（`♡ ▣ ✕`）就换替代字体画（`T131`）。 */
    if (font != 0 && text != 0) {
      sym = moonui_native_font_fallback(font, text, &sym_delete);
      if (sym_delete) {
        SelectObject(dc, sym);
      }
    }
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, moonui_native_colorref_of(fg));
    if (text != 0) {
      RECT tr = r;
      /* MenuRow(14) 是左对齐的菜单行，普通按钮居中。左右各留一点内缩，
       * 别让字贴着圆角。
       *
       * `T325`：内缩原来是写死的 6 物理像素。两头都错——窄钮（走带条上
       * PL/EQ 只有 24 宽）被吃掉一半可用宽度，12px 的字直接截成 "P."；
       * 高 DPI 下又相对变小、字贴到圆角上。改成按 DPI 缩放，并对窄钮收到
       * 2：那类钮的圆角半径本来也小，2px 已经够离开圆弧。 */
      {
        int pad = (int)((6 * (long long)moonui_native_dpi_of(hwnd) + 48) / 96);
        if (w < 36) {
          pad = 2;
        }
        tr.left += pad;
        tr.right -= pad;
      }
      DrawTextW(dc, text, -1, &tr,
                (moonui_native_kind_of_hwnd(hwnd) == 14 ? DT_LEFT : DT_CENTER) |
                    DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX |
                    DT_END_ELLIPSIS);
      free(text);
    }
    if (old != 0) {
      SelectObject(dc, old);
    }
    if (sym_delete) {
      DeleteObject(sym);
    }
    if (created != 0) {
      DeleteObject(created);
    }
  }
  /* 焦点框：系统那支画在主题脸上，我们把脸换掉了，得自己补回来——否则
   * Tab 走到这只钮上时键盘用户看不到焦点在哪。 */
  if (GetFocus() == hwnd && state != 3) {
    RECT fr = r;
    InflateRect(&fr, -3, -3);
    SetTextColor(dc, moonui_native_colorref_of(fg));
    DrawFocusRect(dc, &fr);
  }
  return 1;
}

/* 圆角区域：半径变了 / 尺寸变了都要重落一次。radius < 1 就把区域摘掉
 * （RESET 成整块矩形），与"没设过圆角"同义。
 *
 * 只有平面钮（有底色）才落区域：系统主题脸的按钮剪一刀会把它自己的圆角
 * 和焦点框切掉，那不是我们该动的东西。 */
static void moonui_native_button_apply_region(HWND hwnd) {
  int radius = moonui_native_radius_px(hwnd);
  RECT r;
  HRGN rgn;
  if (GetClientRect(hwnd, &r) == 0) {
    return;
  }
  if (radius < 1 || r.right <= 0 || r.bottom <= 0 ||
      moonui_native_rgb_prop(hwnd, moonui_native_bg_prop) < 0) {
    SetWindowRgn(hwnd, 0, TRUE);
    return;
  }
  /* CreateRoundRectRgn 的右下角是**开区间**（x2/y2 不含），所以各 +1；
   * 椭圆的宽高是直径，即半径的两倍。 */
  rgn = CreateRoundRectRgn(0, 0, r.right + 1, r.bottom + 1, radius * 2,
                           radius * 2);
  if (rgn != 0) {
    SetWindowRgn(hwnd, rgn, TRUE); /* 成功后区域归系统所有，不删 */
  }
}

static LRESULT CALLBACK moonui_native_button_proc(HWND hwnd, UINT msg,
                                                  WPARAM wp, LPARAM lp) {
  WNDPROC orig = (WNDPROC)GetPropW(hwnd, moonui_native_button_orig_prop);
  int flat = moonui_native_rgb_prop(hwnd, moonui_native_bg_prop) >= 0;
  if (flat) {
    if (msg == WM_PAINT) {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(hwnd, &ps);
      if (dc != 0) {
        RECT r;
        GetClientRect(hwnd, &r);
        moonui_native_button_paint(hwnd, dc, r.right - r.left,
                                   r.bottom - r.top);
        EndPaint(hwnd, &ps);
      }
      return 0;
    }
    if (msg == WM_PRINTCLIENT) {
      /* 离屏重画（探针那条路）：与 WM_PAINT 共用同一份画法。 */
      RECT r;
      if (GetClientRect(hwnd, &r) != 0) {
        moonui_native_button_paint(hwnd, (HDC)(uintptr_t)wp, r.right - r.left,
                                   r.bottom - r.top);
      }
      return 0;
    }
    if (msg == WM_ERASEBKGND) {
      /* 脸由 WM_PAINT 整块盖掉；让系统先刷一层背景会闪一下。 */
      return 1;
    }
  }
  if (flat && msg == WM_SETTEXT) {
    /* comctl32 v6 的主题按钮每收一次 WM_SETTEXT 就自己画一遍系统主题脸
     * （近白 #FDFDFD），盖掉我们那张皮肤脸；它不走 WM_PAINT，所以子类
     * 的绘制分支拦不住（owner 2026-11-19 截图：播放/模式钮拖动音量时
     * 闪白，探针实测对正常钮连发 WM_SETTEXT 白像素 0/20 → 10/20）。
     * 文本必须让原过程设进去（否则下次读回是旧值），紧接着拿窗口 DC
     * 当场把皮肤脸重画一遍盖住那层白——不等下一轮 WM_PAINT，同一条
     * 消息里落完，屏幕上看不见中间那帧。截图那段"真变了"的文案切换
     * （▶→⏸）也走这里，不再闪白。 */
    LRESULT r = orig != 0 ? CallWindowProcW(orig, hwnd, msg, wp, lp)
                          : DefWindowProcW(hwnd, msg, wp, lp);
    HDC dc = GetDC(hwnd);
    if (dc != 0) {
      RECT rc;
      if (GetClientRect(hwnd, &rc) != 0) {
        moonui_native_button_paint(hwnd, dc, rc.right - rc.left,
                                   rc.bottom - rc.top);
      }
      ReleaseDC(hwnd, dc);
    }
    return r;
  }
  if (msg == WM_SIZE) {
    /* 区域要按新矩形重落一次（圆角像素与原客户区一样大才贴边）。 */
    moonui_native_button_apply_region(hwnd);
    moonui_native_invalidate(hwnd, 1);
  } else if (msg == WM_MOUSEMOVE) {
    if (GetPropW(hwnd, moonui_native_button_hot_prop) == 0) {
      TRACKMOUSEEVENT tme;
      SetPropW(hwnd, moonui_native_button_hot_prop, (HANDLE)1);
      memset(&tme, 0, sizeof(tme));
      tme.cbSize = (DWORD)sizeof(tme);
      tme.dwFlags = TME_LEAVE;
      tme.hwndTrack = hwnd;
      TrackMouseEvent(&tme);
      if (flat) {
        moonui_native_invalidate(hwnd, 0);
      }
    }
  } else if (msg == WM_MOUSELEAVE) {
    if (GetPropW(hwnd, moonui_native_button_hot_prop) != 0) {
      RemovePropW(hwnd, moonui_native_button_hot_prop);
      if (flat) {
        moonui_native_invalidate(hwnd, 0);
      }
    }
  } else if (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP ||
             msg == WM_SETFOCUS || msg == WM_KILLFOCUS || msg == WM_ENABLE) {
    /* 这四条都会改一态：按下 / 抬起（BST_PUSHED）、焦点框、禁用灰。系统
     * 过程自己只会失效主题脸那一份，这里替我们那份也失效一次。 */
    if (flat) {
      moonui_native_invalidate(hwnd, 0);
    }
  }
  return orig != 0 ? CallWindowProcW(orig, hwnd, msg, wp, lp)
                   : DefWindowProcW(hwnd, msg, wp, lp);
}

/* 创建 kind 1/14 时装子类：换过程、记原过程（与 IME 那半同一套）。装不上
 * 就保持系统外观——控件照常工作，只是底色画不出来。 */
static void moonui_native_button_subclass(HWND button) {
  WNDPROC orig;
  if (GetPropW(button, moonui_native_button_orig_prop) != 0) {
    return;
  }
  orig = (WNDPROC)SetWindowLongPtrW(button, GWLP_WNDPROC,
                                    (LONG_PTR)moonui_native_button_proc);
  if (orig != 0) {
    SetPropW(button, moonui_native_button_orig_prop, (HANDLE)(uintptr_t)orig);
  }
}

/* ---- 滑块（kind 6）的皮肤半（`T132`）----
 *
 * 为什么必须自己画：mac 半的 `CmBar` 靠 `opacity(0.01)`（NSView.alphaValue）
 * 把原生滑块蒙成"只剩拖动能力"的那一层，画面交给叠在上面的方块。Windows
 * 的子分层被系统整体拒绝（见 `moonui_native_set_layered_alpha` 段注），那条
 * 蒙版在子窗口上是 no-op——系统轨道条（COLOR_BTNFACE 底 + 主题蓝钮）照常
 * 整块盖住方块，界面上就是一块灰白补丁（owner 2026-10-27 报的那块）。
 *
 * 做法与平面钮同一套：子类化、只在自己有 `background` 时接住绘制。两格皮肤
 * 字段在这里的含义是滑块自己的：
 *   `background` = 轨道所在条带的底色（应用必须传**同一条带那个色**，否则
 *                  自绘块自己就成了新的补丁）；也当"是否自绘"的开关。
 *   `foreground` = 已走过那段（与上层 `CmBar` 的 on 色一致）。
 * 没给底色就整条交回系统过程——其它用滑块的界面外观一点不变。 */

/* 槽用的圆角实心条：3~10px 高的窄条，GDI 的 RoundRect 够了，不引 GDI+。 */
static void moonui_native_slider_bar(HDC dc, int x, int y, int w, int h,
                                     int64_t rgb) {
  HBRUSH brush;
  HGDIOBJ old_brush;
  HGDIOBJ old_pen;
  if (w <= 0 || h <= 0) {
    return;
  }
  brush = CreateSolidBrush(moonui_native_colorref_of(rgb));
  if (brush == 0) {
    return;
  }
  old_brush = SelectObject(dc, brush);
  old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
  RoundRect(dc, x, y, x + w, y + h, h, h);
  SelectObject(dc, old_pen);
  SelectObject(dc, old_brush);
  DeleteObject(brush);
}

/* 槽的高度：整高的三分之一（夹在 3..10 之间）。进度条 25 高 → 8，
 * 音量条 23 高 → 7，都落在这个区间里。 */
static int moonui_native_slider_groove_h(HWND hwnd) {
  RECT r;
  int h;
  int gh;
  if (GetClientRect(hwnd, &r) == 0) {
    return 3;
  }
  h = r.bottom - r.top;
  gh = h / 3;
  if (gh < 3) {
    gh = 3;
  }
  if (gh > 10) {
    gh = 10;
  }
  return gh;
}

/* 拖动圆点（`T146`）：圆心 (cx, cy)、直径 d 的实心圆。
 *
 * `T325`：原来走 GDI 的 `Ellipse`——那是一个**无抗锯齿**的扫描线多边形，
 * 12px 的圆在 100% 缩放下就是 8~10 段台阶（owner 2026-11-19 拿 100%/125%
 * 两张截图对比时报的"音量条、时间条的圆点有锯齿"）。改走 GDI+ 的抗锯齿椭圆
 * 路径：边缘混的是这条带子的底色（`moonui_native_slider_paint` 已经整块铺过
 * `background`），过渡色正好对得上。
 *
 * 为什么不是"顺手把槽也换掉"：槽只有 3~10px 高、端头圆角半径等于高度，锯齿
 * 在两条水平边上本来就看不出；而 `T146`/`T150` 那几条像素判据读的是槽的实色
 * 像素，抗锯齿会把端头变成半透明，判据跟着漂。只动用户看得见的那一颗圆。
 *
 * GDI+ 起不来（`GdipCreateFromHDC` 失败）时退回 GDI 的 `Ellipse`：形状还在，
 * 只是毛——这条路径不能因为"画不漂亮"变成"不画"。 */
static void moonui_native_slider_knob(HDC dc, int cx, int cy, int d,
                                      int64_t rgb) {
  HBRUSH brush;
  HGDIOBJ old_brush;
  HGDIOBJ old_pen;
  GpGraphics *gfx = 0;
  GpPath *path = 0;
  GpBrush *gbrush = 0;
  if (dc == 0 || d <= 0) {
    return;
  }
  moonui_native_ensure_gdiplus();
  if (GdipCreateFromHDC(dc, &gfx) == MOONUI_GDIP_OK && gfx != 0) {
    if (GdipCreatePath(MOONUI_GDIP_FILLMODE_WINDING, &path) == MOONUI_GDIP_OK &&
        path != 0) {
      GdipAddPathEllipse(path, (REAL)((double)cx - (double)d / 2.0),
                         (REAL)((double)cy - (double)d / 2.0), (REAL)d,
                         (REAL)d);
      if (GdipCreateSolidFill(moonui_canvas_argb(rgb, 255), &gbrush) ==
              MOONUI_GDIP_OK &&
          gbrush != 0) {
        GdipSetSmoothingMode(gfx, MOONUI_GDIP_SMOOTH_ANTIALIAS);
        GdipFillPath(gfx, gbrush, path);
        GdipDeleteBrush(gbrush);
      }
      GdipDeletePath(path);
    }
    GdipDeleteGraphics(gfx);
    return;
  }
  brush = CreateSolidBrush(moonui_native_colorref_of(rgb));
  if (brush == 0) {
    return;
  }
  old_brush = SelectObject(dc, brush);
  old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
  Ellipse(dc, cx - d / 2, cy - d / 2, cx - d / 2 + d, cy - d / 2 + d);
  SelectObject(dc, old_pen);
  SelectObject(dc, old_brush);
  DeleteObject(brush);
}

/* 拖动圆点的圆心（`T150`）：**系统那颗真拇指的圆心**，从
 * `TBM_GETTHUMBRECT` 读——那条消息问的就是轨道条自己按通道/刻度/页步算好的
 * 拇指框，比反推"指针 → 值"的那把尺稳。原来这里按 `w * permille / 1000`
 * 画（两端各夹半个圆点直径），与条子那把尺只在 0/中点/1 重合，中段差随离
 * 中心的距离线性长——"拖得越远圆点离指针越远"就是这条差。
 *
 * 返回 1 = 锚在真拇指上（`*out` 已写）；0 = 没有拇指可取（矩形为空、或宽到
 * 框外），调用方按旧映射画。取真矩形与 `moonui_native_slider_knob_probe`
 * 同一处口径，所以探针红的时候就是用户看见漂的时候。 */
static int moonui_native_slider_knob_cx(HWND hwnd, int w, int *out) {
  RECT thumb;
  if (out == 0) {
    return 0;
  }
  ZeroMemory(&thumb, sizeof(thumb));
  /* 这条消息没有返回值，矩形只从 lParam 拿：空矩形（老系统/未初始化）就当
   * 拿不到。 */
  SendMessageW(hwnd, TBM_GETTHUMBRECT, 0, (LPARAM)&thumb);
  if (thumb.right <= thumb.left || thumb.left < 0 || thumb.right > w) {
    return 0;
  }
  *out = (int)((thumb.left + thumb.right) / 2);
  return 1;
}

static void moonui_native_slider_paint(HWND hwnd, HDC dc) {
  RECT r;
  int w;
  int h;
  int gh;
  int top;
  int filled;
  int permille;
  int lo;
  int hi;
  int pos;
  int kcx = 0;
  int64_t bg = moonui_native_rgb_prop(hwnd, moonui_native_bg_prop);
  int64_t fg = moonui_native_rgb_prop(hwnd, moonui_native_fg_prop);
  if (dc == 0 || bg < 0 || GetClientRect(hwnd, &r) == 0) {
    return;
  }
  w = r.right - r.left;
  h = r.bottom - r.top;
  if (w <= 0 || h <= 0) {
    return;
  }
  /* 底：与所在条带同色（应用传的就是外面那条带的底色）。 */
  {
    HBRUSH brush = CreateSolidBrush(moonui_native_colorref_of(bg));
    if (brush != 0) {
      FillRect(dc, &r, brush);
      DeleteObject(brush);
    }
  }
  gh = moonui_native_slider_groove_h(hwnd);
  top = (h - gh) / 2;
  /* 槽：底色压暗一档，读起来是"嵌进条带的一根槽"。 */
  moonui_native_slider_bar(dc, 0, top, w, gh,
                           moonui_native_mix_rgb(bg, (int64_t)0x000000, 30));
  lo = (int)SendMessageW(hwnd, TBM_GETRANGEMIN, 0, 0);
  hi = (int)SendMessageW(hwnd, TBM_GETRANGEMAX, 0, 0);
  pos = (int)SendMessageW(hwnd, TBM_GETPOS, 0, 0);
  permille = hi > lo ? (int)(((long long)(pos - lo) * 1000) / (hi - lo)) : 0;
  if (permille < 0) {
    permille = 0;
  }
  if (permille > 1000) {
    permille = 1000;
  }
  filled = (int)(((long long)w * permille) / 1000);
  {
    int kt_ok = moonui_native_slider_knob_cx(hwnd, w, &kcx);
    if (kt_ok) {
      if (permille <= 0) {
        filled = 0;
      } else if (permille >= 1000) {
        filled = w;
      } else {
        filled = kcx;
      }
    }
    if (filled > 0) {
      moonui_native_slider_bar(
          dc, 0, top, filled, gh,
          fg >= 0 ? fg : moonui_native_mix_rgb(bg, (int64_t)0xFFFFFF, 55));
    }
    {
      int d;
      int cx;
      d = (int)(((long long)12 * (long long)moonui_native_dpi_of(hwnd) + 48LL) /
                96LL);
      if (d > h) {
        d = h;
      }
      if (d > w) {
        d = w;
      }
      if (d > 0) {
        if (kt_ok) {
          cx = kcx;
        } else {
          cx = filled;
          if (cx < d / 2) {
            cx = d / 2;
          }
          if (cx > w - d / 2) {
            cx = w - d / 2;
          }
        }
        moonui_native_slider_knob(dc, cx, h / 2, d,
                                  moonui_native_mix_rgb(bg, (int64_t)0xF2F6FA, 88));
      }
    }
  }
}

/* 圆点跟手探针（`T150`，契约在 adapter.h）：把滑块摆到千分位 `permille`，
 * 返回**自绘圆点圆心与"指针能到的圆心"之差**，单位百分之一点；-2147483648
 * = 句柄不是滑块或取不到通道/拇指框。
 *
 * 基准是指针而不是真拇指框：真拇指框就是轨道条自己的输出，拿它比等于让画法
 * 自己给自己判分。这里用 `TBM_GETCHANNELRECT`（通道框，拖动语义的输入侧）+
 * 拇指宽推出"指针在本千分位能落到哪儿"，再拿我们的画法去对。
 *
 * 这一份仍是**弱判据**：通道框、拇指框都来自同一条控件，Windows 真机上
 * `MouseMove` 把指针换算成值的那几步无法在本机复现（`T150` 欠条）。强的那份
 * 在 mac：那边真走 AppKit 的跟踪循环，指针是货真价实的输入。 */
int64_t moonui_native_slider_knob_probe(moonui_ptr c, int permille) {
  HWND hwnd = (HWND)(uintptr_t)c;
  RECT r;
  RECT thumb;
  RECT chan;
  int w;
  int kcx = 0;
  int expect;
  int span;
  TRACE("slider_knob_probe");
  if (hwnd == 0 || GetClientRect(hwnd, &r) == 0) {
    return (int64_t)-2147483648LL;
  }
  w = r.right - r.left;
  if (w <= 0) {
    return (int64_t)-2147483648LL;
  }
  if (permille < 0) {
    permille = 0;
  }
  if (permille > 1000) {
    permille = 1000;
  }
  {
    int lo = (int)SendMessageW(hwnd, TBM_GETRANGEMIN, 0, 0);
    int hi = (int)SendMessageW(hwnd, TBM_GETRANGEMAX, 0, 0);
    int pos =
        hi > lo ? lo + (int)(((long long)(hi - lo) * permille) / 1000LL) : lo;
    SendMessageW(hwnd, TBM_SETPOS, 1, pos);
  }
  ZeroMemory(&thumb, sizeof(thumb));
  SendMessageW(hwnd, TBM_GETTHUMBRECT, 0, (LPARAM)&thumb);
  ZeroMemory(&chan, sizeof(chan));
  SendMessageW(hwnd, TBM_GETCHANNELRECT, 0, (LPARAM)&chan);
  if (thumb.right <= thumb.left || chan.right <= chan.left) {
    return (int64_t)-2147483648LL;
  }
  /* 指针在通道上走到这一千分位时，拇指圆心能到哪儿：拇指左缘走
   * `chan.left .. chan.right - thumbW`，圆心取它的中点区间。 */
  span = (chan.right - chan.left) - (thumb.right - thumb.left);
  if (span < 0) {
    span = 0;
  }
  expect = chan.left + (int)(((long long)span * permille) / 1000LL) +
           (thumb.right - thumb.left) / 2;
  if (moonui_native_slider_knob_cx(hwnd, w, &kcx) == 0) {
    return (int64_t)-2147483648LL;
  }
  return (int64_t)((long long)(kcx - expect) * 100LL);
}

/* "在轨道上点一下，圆点当场落在哪儿"（`T157`，契约在 adapter.h）。
 *
 * mac 半那个缺陷（点轨道后拇指走一段约 270ms 的动画、自绘圆点照着动画途中的
 * 框画于是停在半路）在 Windows 上不存在：轨道条收到 `WM_LBUTTONDOWN` 就把 pos
 * 直接挪到点击处，`TBM_GETTHUMBRECT` 下一句问到的已经是终态，没有"途中"这个
 * 阶段。所以这份实现与 `moonui_native_slider_knob_probe` 同一条读数——它恒绿
 * 不是判据松，是平台本来就没这个病。
 *
 * 留着它有两个用处：①ABI 两半形状对齐（声明只有一份，`scripts/abi-symbols.sh`
 * 要求两份都定义）；②把"Windows 无此缺陷"写成可执行的事实，将来谁给轨道条
 * 加动画，这条会跟着红。 */
int64_t moonui_native_slider_click_probe(moonui_ptr c, int from_pm, int to_pm) {
  HWND hwnd = (HWND)(uintptr_t)c;
  RECT r;
  RECT thumb;
  RECT chan;
  int w;
  int kcx = 0;
  int expect;
  int span;
  TRACE("slider_click_probe");
  (void)from_pm; /* 起点不影响读数：点击直接把 pos 挪到终点，没有动画可等 */
  if (hwnd == 0 || GetClientRect(hwnd, &r) == 0) {
    return (int64_t)-2147483648LL;
  }
  w = r.right - r.left;
  if (w <= 0) {
    return (int64_t)-2147483648LL;
  }
  if (to_pm < 0) {
    to_pm = 0;
  }
  if (to_pm > 1000) {
    to_pm = 1000;
  }
  {
    int lo = (int)SendMessageW(hwnd, TBM_GETRANGEMIN, 0, 0);
    int hi = (int)SendMessageW(hwnd, TBM_GETRANGEMAX, 0, 0);
    int pos =
        hi > lo ? lo + (int)(((long long)(hi - lo) * to_pm) / 1000LL) : lo;
    SendMessageW(hwnd, TBM_SETPOS, 1, pos);
  }
  ZeroMemory(&thumb, sizeof(thumb));
  SendMessageW(hwnd, TBM_GETTHUMBRECT, 0, (LPARAM)&thumb);
  ZeroMemory(&chan, sizeof(chan));
  SendMessageW(hwnd, TBM_GETCHANNELRECT, 0, (LPARAM)&chan);
  if (thumb.right <= thumb.left || chan.right <= chan.left) {
    return (int64_t)-2147483648LL;
  }
  span = (chan.right - chan.left) - (thumb.right - thumb.left);
  if (span < 0) {
    span = 0;
  }
  expect = chan.left + (int)(((long long)span * to_pm) / 1000LL) +
           (thumb.right - thumb.left) / 2;
  if (moonui_native_slider_knob_cx(hwnd, w, &kcx) == 0) {
    return (int64_t)-2147483648LL;
  }
  return (int64_t)((long long)(kcx - expect) * 100LL);
}

static LRESULT CALLBACK moonui_native_slider_proc(HWND hwnd, UINT msg,
                                                  WPARAM wp, LPARAM lp) {
  WNDPROC orig = (WNDPROC)GetPropW(hwnd, moonui_native_slider_orig_prop);
  int skin = moonui_native_rgb_prop(hwnd, moonui_native_bg_prop) >= 0;
  if (skin) {
    if (msg == WM_PAINT) {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(hwnd, &ps);
      if (dc != 0) {
        moonui_native_slider_paint(hwnd, dc);
        EndPaint(hwnd, &ps);
      }
      return 0;
    }
    if (msg == WM_PRINTCLIENT) {
      /* 离屏重画（探针那条路）：与 WM_PAINT 共用同一份画法。 */
      moonui_native_slider_paint(hwnd, (HDC)(uintptr_t)wp);
      return 0;
    }
    if (msg == WM_ERASEBKGND) {
      /* 底由 WM_PAINT 整块盖掉；让系统先刷一层会闪一下（`T126` 同一课）。 */
      return 1;
    }
    if (msg == WM_SIZE) {
      /* 宽度变了：整条槽按新宽度重画。 */
      moonui_native_invalidate(hwnd, 0);
    }
    /* 值与交互类消息（`T136`）：系统轨道条遇到点击/拖动只失效**拇指前后那两
     * 小块矩形**，而皮肤画的是整条槽 + 整段填充——只重画那一小块，其余部分
     * 还是上一次的位置，于是点完/拖完填充就拼成一段段（accent 与槽色交替）。
     * 所以这些消息转给原件之后再整窗失效一次，保证整条按新值重画。
     *
     * 注意 `WM_HSCROLL` 正常情况下到不了这里（轨道条把它发给父窗口），别指望
     * 靠它兜底；程序赋值走 `TBM_SETPOS`，拖动走鼠标消息，两头都得列进来。 */
    if (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP ||
        msg == WM_LBUTTONDBLCLK || msg == WM_MOUSEMOVE ||
        msg == WM_KEYDOWN || msg == WM_KEYUP || msg == WM_MOUSEWHEEL ||
        msg == WM_HSCROLL || msg == WM_VSCROLL || msg == TBM_SETPOS ||
        msg == TBM_SETRANGE || msg == TBM_SETRANGEMIN ||
        msg == TBM_SETRANGEMAX || msg == TBM_SETPAGESIZE ||
        msg == TBM_SETLINESIZE) {
      LRESULT r = orig != 0 ? CallWindowProcW(orig, hwnd, msg, wp, lp)
                            : DefWindowProcW(hwnd, msg, wp, lp);
      moonui_native_invalidate(hwnd, 0);
      return r;
    }
  }
  return orig != 0 ? CallWindowProcW(orig, hwnd, msg, wp, lp)
                   : DefWindowProcW(hwnd, msg, wp, lp);
}

/* 创建 kind 6 时装子类：换过程、记原过程（与平面钮同一套）。装不上就保持
 * 系统轨道条外观——控件照常工作，只是皮肤画不出来。 */
static void moonui_native_slider_subclass(HWND slider) {
  WNDPROC orig;
  if (GetPropW(slider, moonui_native_slider_orig_prop) != 0) {
    return;
  }
  orig = (WNDPROC)SetWindowLongPtrW(slider, GWLP_WNDPROC,
                                    (LONG_PTR)moonui_native_slider_proc);
  if (orig != 0) {
    SetPropW(slider, moonui_native_slider_orig_prop, (HANDLE)(uintptr_t)orig);
  }
}

/* 文件拖入（`T86③`/`T91③`）：WM_DROPFILES 的处理体定义在文件后段。 */
static void moonui_native_drop_take(HWND hwnd, HDROP drop);

/* 子控件的文字色 / 底色：Win32 里这两样**不是控件的属性**，只能由父窗口在
 * `WM_CTLCOLORSTATIC` / `WM_CTLCOLORBTN` 里回答（wParam = 子控件的 DC，
 * lParam = 子控件）。皮肤通道把颜色记在子控件自己的属性表上，这里读出来用。
 *
 * 返回 1 = 接手了（`*out` 是要交给系统的画刷），0 = 这只控件没设过皮肤字段、
 * 交回默认过程（系统外观照旧，§32 的豁免不扩到没被显式指定的控件上）。
 *
 * 底色分两态：设过就 OPAQUE + 实色画刷（那块色由系统填）；没设过就
 * TRANSPARENT + 空画刷（透出底下那层——Panel 画好的底，与 mac 的
 * NSTextField 不画底同一条）。 */
static int moonui_native_ctlcolor(WPARAM wp, LPARAM lp, HBRUSH *out) {
  HWND child = (HWND)(uintptr_t)lp;
  HDC dc = (HDC)(uintptr_t)wp;
  int64_t fg;
  int64_t bg;
  HBRUSH brush;
  if (child == 0 || dc == 0 || out == 0) {
    return 0;
  }
  fg = moonui_native_rgb_prop(child, moonui_native_fg_prop);
  bg = moonui_native_rgb_prop(child, moonui_native_bg_prop);
  if (fg < 0 && bg < 0) {
    return 0;
  }
  if (fg >= 0) {
    SetTextColor(dc, moonui_native_colorref_of(fg));
  }
  if (bg >= 0) {
    SetBkMode(dc, OPAQUE);
    SetBkColor(dc, moonui_native_colorref_of(bg));
    brush = (HBRUSH)(uintptr_t)GetPropW(child, moonui_native_bg_paint_prop);
    if (brush == 0) {
      /* 缓存由样式下发那半建；这里只是防御性补一份（属性表被谁清过也不会
       * 让底色退成系统色）。 */
      brush = CreateSolidBrush(moonui_native_colorref_of(bg));
      if (brush != 0) {
        SetPropW(child, moonui_native_bg_paint_prop, (HANDLE)(uintptr_t)brush);
      }
    }
  } else {
    /* `T331`：透明标签的字走 ClearType，彩边按"画字那刻 DC 认为的背景色"
     * 做子像素混合。原来这里只 `SetBkMode(TRANSPARENT)` + 空画刷：BkColor
     * 留在系统缓存 DC 的旧值上，父面板 hover 换底时没人同步它——字核心
     * （最深那几颗像素）没变，彩边却停在 hover 底那一份混合值上，移开鼠标
     * 背景回白后看起来整行字淡了一档（owner 2026-11-20 截图）。
     *
     * `OPAQUE` 才让 GDI 按这份色重算子像素覆盖（实测 `TRANSPARENT` 下设
     * BkColor 无效：hover 进/出各 4 次 CTLCOLOR、BkColor 已是白色，彩边仍是
     * hover 那份）。画刷仍回 NULL，标签自己不铺底，底下 Panel 的纯色照旧
     * 透出来——改的只是 ClearType 的取色依据。
     *
     * `T332`：必须是**真有**纯色底的祖先才这么做。播放条那几只标签底下是
     * 自绘 / 图片，`layout_bg_of` 找不到，上一版拿 `under_color_of` 的窗口
     * 类背景白顶上，白字连底色一起被铺成白矩形（owner 2026-11-20 截图）。
     * 找不到就保持原 TRANSPARENT，透明语义一动不动。 */
    int64_t under = moonui_native_layout_bg_of(child);
    if (under >= 0) {
      SetBkMode(dc, OPAQUE);
      SetBkColor(dc, moonui_native_colorref_of(under));
    } else {
      SetBkMode(dc, TRANSPARENT);
    }
    brush = (HBRUSH)GetStockObject(NULL_BRUSH);
  }
  *out = brush;
  return 1;
}

/* ---- 沉浸式标题栏（`T116`，Windows 半）----
 *
 * mac 的沉浸式靠 `NSWindowStyleMaskFullSizeContentView` + 透明标题栏；Win32 没有
 * 等价的一位，得自己拼三件事：
 *   1. 摘掉 `WS_CAPTION`（它 = `WS_BORDER | WS_DLGFRAME`，标题栏与边框全在这一位里），
 *      保留 `WS_THICKFRAME` —— 窗还得能拉边；保留 `WS_SYSMENU`/任务栏行为。
 *   2. `WM_NCCALCSIZE` 里把客户区放成整窗（默认过程会按新风格裁掉一圈非客户区）。
 *      最大化要单独处理：带 `WS_THICKFRAME` 的窗最大化时外框会探出屏幕，
 *      客户区照抄整窗就会把内容顶到屏幕外——按该屏**工作区**回缩。
 *   3. `WM_NCHITTEST` 补回被 `WM_NCCALCSIZE` 抹掉的两种命中：边角（拉大小）与
 *      顶条（`HTCAPTION` 拖动）。顶条高多少只有 Core 知道（每只窗不同），由
 *      `moonui_native_window_set_drag_band` 送进来。
 *
 * 顶条本身是 Panel(17) 这类**子窗口**，它会先拿到 `WM_NCHITTEST`；所以 Panel 的
 * 过程在被问到"落点是不是在父窗拖动带里"时回 `HTTRANSPARENT`，把这个问题交回
 * 顶层窗口（同线程的子窗口才允许这样转交）。Label/Image 那类 STATIC 不带
 * `SS_NOTIFY`，系统本来就把鼠标问题转给父窗，不用另处理。
 *
 * 双击不放行：带 `HTCAPTION` 的 `WM_NCLBUTTONDBLCLK` 默认过程会**最大化**窗口，
 * 一个定尺的音乐播放器被双击拉满是坏事，所以在沉浸式窗上吞掉（mac 上双击顶条
 * 是卷起，那条手势在 Windows 走「窗口」菜单）。 */

/* 拉边区的宽（逻辑点）：取系统皮肤的量级，太窄拖不中、太宽会吃掉自绘边框。 */
static int moonui_native_resize_border_px(HWND hwnd) {
  int px = (int)(((long long)5 * (long long)moonui_native_dpi_of(hwnd) + 48LL) /
                 96LL);
  return px < 2 ? 2 : px;
}

/* 沉浸式窗的命中判定。lp 是屏幕坐标（`WM_NCHITTEST` 的约定），一律换成"相对
 * 外框左上角"再比——客户区此时等于整窗，两个空间只差一个外框原点。 */
static LRESULT moonui_native_immersive_hit(HWND hwnd, MoonuiWindowMenu *e,
                                           LPARAM lp) {
  RECT w;
  int x;
  int y;
  int ww;
  int hh;
  int b;
  x = (int)(SHORT)LOWORD(lp);
  y = (int)(SHORT)HIWORD(lp);
  if (GetWindowRect(hwnd, &w) == 0) {
    return HTCLIENT;
  }
  x -= w.left;
  y -= w.top;
  ww = w.right - w.left;
  hh = w.bottom - w.top;
  /* 最大化时没有边可拉：那圈边在屏幕外，报 HTLEFT 会让光标在屏幕边缘变成
   * 双向箭头却拖不动。 */
  if (IsZoomed(hwnd) == 0 &&
      (GetWindowLongW(hwnd, GWL_STYLE) & WS_THICKFRAME) != 0) {
    b = moonui_native_resize_border_px(hwnd);
    /* 角优先于边：落在左上角那一个小方块里该报 HTTOPLEFT 而不是 HTLEFT。 */
    if (x < b && y < b) return HTTOPLEFT;
    if (x >= ww - b && y < b) return HTTOPRIGHT;
    if (x < b && y >= hh - b) return HTBOTTOMLEFT;
    if (x >= ww - b && y >= hh - b) return HTBOTTOMRIGHT;
    if (x < b) return HTLEFT;
    if (x >= ww - b) return HTRIGHT;
    if (y < b) return HTTOP;
    if (y >= hh - b) return HTBOTTOM;
  }
  if (e != 0 && e->drag_h > 0 && y >= 0 && y < e->drag_h) {
    return HTCAPTION;
  }
  return HTCLIENT;
}

static LRESULT CALLBACK moonui_native_wndproc(HWND hwnd, UINT msg, WPARAM wp,
                                       LPARAM lp) {
  if (msg == WM_PAINT && GetPropW(hwnd, moonui_native_canvas_prop) != 0) {
    /* `T98`④ 的上屏账：挂了画布的窗口整窗按画布帧重画（自绘后端那半的
     * 粘合点），没挂的窗口走默认（类背景刷）——不在这里验证，控件自己的
     * 画布贴在 kind 18 的子窗口上（`T111`），各回各的 proc。 */
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    if (dc != 0) {
      moonui_native_canvas_paint_layer(hwnd, dc);
      EndPaint(hwnd, &ps);
    }
    return 0;
  }
  if (msg == MOONUI_WORK_MSG) {
    /* `T85①` worker 落地：wp/lParam 是 land 闭包的 (函数指针, 环境) 对，由
     * worker 线程 PostMessage 投回（park 窗口收着）。这条在 UI 线程的消息泵
     * 里运行 land 闭包——落地动作是 MoonBit 侧的 app.post（排队、下一圈且
     * 排在事件前），不在泵的回调栈里碰控件树；执行完回收 land 那份引用
     * （work 那份由 worker 自己回收）。 */
    moonui_closure_fn land_call = (moonui_closure_fn)(uintptr_t)wp;
    void *land_closure = (void *)(uintptr_t)lp;
    land_call(land_closure);
    moonbit_decref(land_closure);
    return 0;
  }
  if (msg == MOONUI_AUDIO_MSG) {
    /* 音频播完（`T326`）：引擎线程投上来的一发，令牌核对与闭包回收都在
     * moonui_wa_on_deliver 里（它要摸音频状态，那半在文件后面）。 */
    return moonui_wa_on_deliver(lp);
  }
  if (msg == MOONUI_TRAY_MSG) {
    /* `T86⑥` 托盘回调：托盘图标的那只 NOTIFYICONDATA 把鼠标消息转投到 park
     * 窗口（lp 是鼠标事件号）。左键抬起（WM_LBUTTONUP）弹菜单——AppKit 那半
     * 是点击自动弹，这半用同一颗"抬起"当弹出的沿；其余事件忽略。选中项的
     * id 走 TPM_RETURNCMD 的返回值，闭包在弹出返回后当场调（选中语义沿
     * `T86⑥` 落地注记，同步解析）。 */
    if ((UINT)lp == WM_LBUTTONUP) {
      moonui_native_tray_show_menu(hwnd);
    }
    return 0;
  }
  if (msg == WM_ERASEBKGND) {
    /* 沉浸式窗的客户区**不许系统拿类背景刷去刷**（`T126`）。
     *
     * 类背景给的是 `COLOR_BTNFACE`（`#F0F0F0`，见 init 里 RegisterClassW 那行），
     * 系统在 `DefWindowProc` 的 `WM_ERASEBKGND` 里拿它把整块客户区刷一遍。
     * 平时看不出来——子窗口盖在上面；可是 lunamusic 换页签走的是整树重建
     * （`set_tab` → `rebuild_ui` → 六只窗依次 `set_content`）：旧子窗口一批批
     * 销毁，父窗那块地就露出来，系统先刷一层整窗近白，新子窗口再逐个长回来。
     * 2026-10-26 逐帧量到三只可见窗**同时**冲到 `near-white 100%`（主控从
     * 13.7% 起跳，约 120ms 见白、约 640ms 才回），正是 owner 说的"所有窗口
     * 闪一下白屏"。
     *
     * 回 1 = "这次擦除我认了、别再画"：露出来的那块保持旧像素，等新子树自绘
     * 盖上——旧内容留一瞬，比一层白好，而且不留"挖洞"式的错色。
     * 只对沉浸式生效：标准窗的客户区底色本来就得靠类背景刷给（`T114` 的皮肤
     * 通道没接窗口底色那一层），摘掉它那些窗会露出桌面。 */
    MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
    if (e != 0 && e->immersive) {
      return 1;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_NCCALCSIZE) {
    /* 沉浸式窗：客户区就是整只窗（见上面那节段注）。两档 wParam 的 lp 里
     * **已经装着系统算好的那份新矩形**（TRUE 那档是 NCCALCSIZE_PARAMS 的
     * rgrc[0]，FALSE 那档直接就是 RECT），屏幕坐标。所以这里一个字都不用填：
     * 原样留着、回 0 = "就按这份来，别再按风格扣"。
     *
     * 这里踩过一次坑（`T116`）：早先那版用 GetWindowRect 覆盖 rgrc[0]。
     * 这条消息是在窗口**改尺寸之前**发的，GetWindowRect 拿到的是旧外框——
     * 于是每次 set_size 都把客户区钉在旧尺寸上，窗口外框却按新尺寸变了，
     * 客户区比外框小一大块（实测 320×240 的窗，客户区读到 334×297 的
     * 反方向越差越远）。系统给的那份才是对的。
     *
     * 唯一的例外是最大化：带 WS_THICKFRAME 最大化的外框会比工作区大一圈
     * （系统故意把边框推到屏幕外），照抄就把自绘顶条的头几个像素顶到屏幕
     * 上面去。那一档换成该屏工作区。 */
    MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
    if (e == 0 || !e->immersive) {
      return DefWindowProcW(hwnd, msg, wp, lp);
    }
    if (lp != 0 && IsZoomed(hwnd) != 0) {
      MONITORINFO mi;
      mi.cbSize = sizeof(mi);
      if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                          &mi) != 0) {
        RECT *rgrc = wp != 0 ? &((NCCALCSIZE_PARAMS *)(uintptr_t)lp)->rgrc[0]
                             : (RECT *)(uintptr_t)lp;
        *rgrc = mi.rcWork;
      }
    }
    return 0;
  }
  if (msg == WM_NCPAINT) {
    /* 沉浸式窗的非客户区一个字都不许系统画（`T124`）。
     *
     * 为什么必须自己堵：`WM_NCCALCSIZE` 回 0 只说明"客户区是整窗"，并**没有**
     * 摘掉系统那份非客户区的画法。窗口是在有 `WS_CAPTION` 的形态下建出来的
     * （`moonui_native_window_style`），后来 `set_titlebar_style(immersive)`
     * 才把这一位摘掉；而系统手里那份"这只窗有标题栏"的账不会因为样式位变了
     * 就消失——每次它想重画外框都照样按标题栏画：一条浅蓝灰渐变 + 应用图标 +
     * 窗口标题，直接盖在客户区顶上（客户区是整窗，所以盖的正是自绘顶条）。
     * 2026-10-26 抓图量到：380 宽的 Luna 主窗顶上 29 行是系统标题栏（月亮图标
     * + "Luna"），顶条自己画的「♪ Luna / 播放 / 控制 / 窗口 / 皮肤 / 复位」
     * 全被压在底下；整窗重画一次就没了 —— 所以这不是"没画"，是"被盖了"。
     *
     * 这条就是 T117 那族裁剪账的第三只手：不是"没人画"，是"系统替我们画了
     * 一块我们不要的"。回 0 = 交了张白卷，系统这块不再落笔。 */
    MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
    if (e != 0 && e->immersive) {
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_NCACTIVATE) {
    /* 激活态的切换是那只残影的**触发器**（`T124`）：默认过程在这里重画一遍
     * 非客户区（理由见上面 `WM_NCPAINT` 那条），于是"点一下窗口"就多一条系统
     * 标题栏盖在顶条上，随后任何一次整窗重画又把它擦掉——用户看到的就是
     * "点空白就坏、鼠标动一动又好了"。
     *
     * 回 TRUE = "非客户区我自理"，默认过程因此不再落笔。这里**不**顺手补一次
     * 整窗重画：`WM_NCPAINT` 那条已经把这条路堵死，系统手里不会再攒下要擦的
     * 残影；反过来，每次切焦点都 RDW_ALLCHILDREN 重画一遍全窗，在六窗互切时
     * 会变成可见的闪白。 */
    MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
    if (e != 0 && e->immersive) {
      return TRUE;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_NCHITTEST) {
    MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
    if (e != 0 && e->immersive) {
      return moonui_native_immersive_hit(hwnd, e, lp);
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_NCLBUTTONDBLCLK) {
    /* 沉浸式窗上双击顶条 = 双击标题栏，默认过程会**最大化**并吃下这一下。
     * 定尺的播放器被双击拉满不是我们想要的（mac 同位置是卷起），所以整条
     * 吞掉：任务栏/系统菜单里的最大化照旧可用（见上面那节段注）。 */
    MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
    if (e != 0 && e->immersive) {
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_CLOSE) {
    moonui_native_fire_slot_prop(hwnd, moonui_native_slot_closing_prop);
    return 0;
  }
  if (msg == WM_GETMINMAXINFO) {
    /* 用户拖边框时系统问"最小能拖到多大"：这里回 Core 下发的最小**客户区**
     * 尺寸换成外框的等价值（ptMinTrackSize 是整窗尺寸）。没设过就交默认。 */
    MINMAXINFO *mm = (MINMAXINFO *)(uintptr_t)lp;
    MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
    if (mm != 0 && e != 0 && e->min_w > 0 && e->min_h > 0) {
      int ow = 0;
      int oh = 0;
      moonui_native_outer_size(hwnd, e->min_w, e->min_h, &ow, &oh);
      mm->ptMinTrackSize.x = ow;
      mm->ptMinTrackSize.y = oh;
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_ENTERSIZEMOVE || msg == WM_EXITSIZEMOVE) {
    /* 拖边框/拖标题的模态会话边界（live resize 检测，见 MoonuiWindowMenu 的
     * in_size_move 段注）。会话内的 WM_SIZE 才走实时重排那条。 */
    MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
    if (e != 0) {
      e->in_size_move = (msg == WM_ENTERSIZEMOVE) ? 1 : 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_SIZE) {
    moonui_native_fire_slot_prop(hwnd, moonui_native_slot_resized_prop);
    return 0;
  }
  if (msg == WM_MOVE) {
    /* 用户拖标题栏才走到这；程序化 SetWindowPos 有 inhibit 挡着不报。读位置交给
     * 共享层（push_move 走 native_window_position），这里只管点火。 */
    if (!moonui_native_inhibited(hwnd)) {
      moonui_native_fire_slot_prop(hwnd, moonui_native_slot_moved_prop);
    }
    return 0;
  }
  if (msg == WM_DROPFILES) {
    /* `T86③` 第一期（`T91③` 真跑）：DragAcceptFiles 挂上的接受位让系统把
     * 拖入翻译成这条消息，处理体在 drop_take（读 HDROP → 打包 → 通知）。 */
    moonui_native_drop_take(hwnd, (HDROP)wp);
    return 0;
  }
  if (msg == WM_GESTURE) {
    /* `T106`：解析在 gesture_handle（GID_ZOOM/GID_ROTATE → 四样读回 +
     * 通知）；它没消化的手势交回默认过程（那里替我们 CloseGestureInfo）。 */
    if (moonui_native_gesture_handle(hwnd, lp) != 0) {
      return 0;
    }
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
  if (msg == WM_CTLCOLORSTATIC || msg == WM_CTLCOLORBTN) {
    /* 皮肤通道的文字色/底色（见 moonui_native_ctlcolor 段注）。子控件把这条
     * 发给**父窗口**，所以接班点就在顶层窗口过程；没设过皮肤的控件返回 0，
     * 交回默认过程维持系统外观。 */
    HBRUSH brush = 0;
    if (moonui_native_ctlcolor(wp, lp, &brush)) {
      return (LRESULT)(uintptr_t)brush;
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
  if (msg == WM_CTLCOLORSTATIC || msg == WM_CTLCOLORBTN) {
    /* 单选组里的子按钮是**这只容器**的子窗口，它们的文字色/底色问到这儿。
     * 容器自己不是顶层窗口过程，得自己接一手（见 moonui_native_ctlcolor）。 */
    HBRUSH brush = 0;
    if (moonui_native_ctlcolor(wp, lp, &brush)) {
      return (LRESULT)(uintptr_t)brush;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
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
  /* 自定义绘制面（`T111`）：类背景 NULL——贴帧走 AlphaBlend，系统别先糊一层
   * 底色把半透明帧洗掉；WM_SIZE 触发重画（拉伸对齐在 paint_layer）。 */
  memset(&wc, 0, sizeof(wc));
  wc.lpszClassName = moonui_native_custom_class_name;
  wc.lpfnWndProc = moonui_native_custom_proc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorW(0, (LPCWSTR)IDC_ARROW);
  wc.hbrBackground = 0;
  if (RegisterClassW(&wc) == 0) {
    DestroyWindow(moonui_native_park);
    moonui_native_park = 0;
    UnregisterClassW(moonui_native_container_class_name, inst);
    UnregisterClassW(moonui_native_wnd_class_name, inst);
    snprintf(moonui_native_error, sizeof(moonui_native_error),
             "RegisterClassW(MoonuiCustomClass) failed: %lu", GetLastError());
    return 1;
  }
  /* 自绘面板（kind 17，皮肤通道）：类背景 NULL——底色与圆角由 panel_proc
   * 自己画（给了类背景刷的话系统会把四个圆角刷平）。
   * `T333`：必须是 CS_DBLCLKS——行是 Panel、行内 Label 又是 WS_EX_TRANSPARENT
   * （鼠标穿透到 Panel），所以整行的点击命中的都是这只类；没有这个标志 OS
   * 就不发 WM_LBUTTONDBLCLK，挂在 Panel 上的 `with_on_double_click` 永远收不到
   * ——双击播放列表行没反应、只有右键菜单「播放」能用（owner 2026-11-20 报）。 */
  memset(&wc, 0, sizeof(wc));
  wc.style = CS_DBLCLKS;
  wc.lpszClassName = moonui_native_panel_class_name;
  wc.lpfnWndProc = moonui_native_panel_proc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorW(0, (LPCWSTR)IDC_ARROW);
  wc.hbrBackground = 0;
  if (RegisterClassW(&wc) == 0) {
    DestroyWindow(moonui_native_park);
    moonui_native_park = 0;
    UnregisterClassW(moonui_native_custom_class_name, inst);
    UnregisterClassW(moonui_native_container_class_name, inst);
    UnregisterClassW(moonui_native_wnd_class_name, inst);
    snprintf(moonui_native_error, sizeof(moonui_native_error),
             "RegisterClassW(MoonuiPanelClass) failed: %lu", GetLastError());
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
  /* `T85②`：组合监听进程一份，与那两条钩子同一档收尾（排在排槽之前一起松）。
   * `T86`：文件拖入源与托盘的闭包同一条档（进程一份，定义在文件尾部，
   * 前向声明在文件顶部）。 */
  moonui_native_drop_drop_closure();
  moonui_native_tray_drop_closure();
  moonui_native_gesture_drop_closure();
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
  UnregisterClassW(moonui_native_custom_class_name, GetModuleHandleW(0));
  UnregisterClassW(moonui_native_panel_class_name, GetModuleHandleW(0));
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
  MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
  /* 沉浸式窗（`T116`）：`WM_NCCALCSIZE` 回 0 之后客户区就是整窗，外框尺寸
   * **恒等**于客户区尺寸。这里不能交给 AdjustWindowRectEx——它按风格算，
   * WS_THICKFRAME 还在（要能拉边），算出来的外框会凭空多出那圈边框宽，
   * 每次 set_size 都把窗撑大 8pt、内容跟着超出去。 */
  if (e != 0 && e->immersive) {
    *out_w = width;
    *out_h = height;
    return;
  }
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

/* 顶层窗口的样式：标准可调边框 + WS_CLIPCHILDREN（理由见
 * moonui_native_window_new 里的段注）。单独抽出来是因为 AdjustWindowRectEx
 * 与 CreateWindowExW 必须用同一份——外框换算按风格算，WS_OVERLAPPEDWINDOW 与
 * WS_CLIPCHILDREN 对客户区边距的影响都在 AdjustWindowRectEx 的账上，两边不
 * 一致客户区就对不上。 */
static DWORD moonui_native_window_style(void) {
  return WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;
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
   * 风格"估——风格是固定的 WS_OVERLAPPEDWINDOW（**外加 WS_CLIPCHILDREN**，
   * 见下），菜单位看当下有没有一棵非空的树等着挂（§25 的菜单是运行时才装
   * 的，Win32 的菜单位影响客户区）。 */
  r.left = 0;
  r.top = 0;
  r.right = width;
  r.bottom = height;
  has_bar = moonui_native_menu_wanted();
  AdjustWindowRectEx(&r, moonui_native_window_style(), has_bar, 0);
  /* WS_CLIPCHILDREN：类背景刷是 COLOR_BTNFACE，父窗擦背景时默认会把**整片**
   * 客户区（含子控件占的矩形）刷成按钮面灰，子控件只能靠自己的 WM_PAINT 补
   * 回来。带上这一位，父窗擦背景时就跳过子控件矩形，少一层闪烁。
   *
   * 注意它不是 2026-10-22 lunamusic"整窗空白"那条的成因——单独加这一位，现
   * 象照旧；真正的原因在子控件那边缺 WS_CLIPSIBLINGS（见
   * moonui_native_create_control 的段注）。这两位各管一头：CLIPCHILDREN 管
   * "父窗画时别碰子的地盘"，CLIPSIBLINGS 管"子窗画时别碰兄弟的地盘"。 */
  hwnd = CreateWindowExW(0, moonui_native_wnd_class_name, t,
                         moonui_native_window_style(), CW_USEDEFAULT,
                         CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, 0, 0,
                         GetModuleHandleW(0), 0);
  free(t);
  if (hwnd == 0) {
    return 0;
  }
  /* owner 记号指向自己（句柄恒等约定），登记进菜单 / 图标那张逐窗口表。 */
  moonui_native_mark_owner(hwnd, (moonui_ptr)(uintptr_t)hwnd);
  moonui_native_menu_register(hwnd);
  moonui_native_icon_apply(hwnd); /* 之前 set_app_icon 存下的图标，新窗口也要带（§26） */
  /* 文件拖入（`T86③`/`T91③`）：DragAcceptFiles 开的是"接收外部文件拖入"那道
   * 系统门（WS_EX_ACCEPTFILES），拖入经 WM_DROPFILES 落到顶层过程；窗口级
   * 的接受开关由"监听装没装"那一档管（drop_fn 为 0 时收到也不发事件）。 */
  DragAcceptFiles(hwnd, TRUE);
  /* 手势（`T106`）：逐窗口开 GID_ZOOM/GID_ROTATE——默认配置里旋转是关的，
   * 不开就只有捏合；PAN 不开（Windows 的 pan 是连续拖动，与离散 swipe 的
   * 语义对不上，不硬翻）。 */
  {
    GESTURECONFIG gc[2];
    ZeroMemory(gc, sizeof(gc));
    gc[0].dwID = GID_ZOOM;
    gc[0].dwWant = GC_ZOOM;
    gc[1].dwID = GID_ROTATE;
    gc[1].dwWant = GC_ROTATE;
    SetGestureConfig(hwnd, 0, 2, gc, sizeof(GESTURECONFIG));
  }
  return (moonui_ptr)(uintptr_t)hwnd;
}

/* 整棵子树一次性落笔（`T324` 帧原子化）。
 *
 * 病根：Win32 是"每只控件一个 HWND"，一次 show / 整树重建要画的窗口有 N 只，
 * 每只各欠一条 `WM_PAINT`；而主循环的 `poll_event` 每泵一条就睡
 * `wait_slice_ms` = 8ms（`backends/native-common/backend.mbt`），整帧被摊成
 * N×8ms。owner 2026-11-19 的录屏就是这件事的外形：窗口先露出来一片白底，
 * 然后侧栏、表头、列表一帧一帧地长出来，前后约 2.5 秒。
 *
 * 这里给一个"当场把整棵子树画完"的入口，落笔顺序由我们定——**父先子后**
 * （父是底、子是面），不交给 Windows 的队列排序：
 *   ① 非透明窗走 `UpdateWindow` 落自己的底与内容，更新区还在时补一发
 *      `WM_PAINT`；
 *   ② 透明层（`WS_EX_TRANSPARENT`）不吃 `UpdateWindow` / `RDW_UPDATENOW`，
 *      只回成功不发画（`T318` 实测），**且必须无条件先标脏再投 `WM_PAINT`**
 *      ——`BeginPaint` 的 `rcPaint` 取更新区，没有更新区时系统 STATIC 一个字
 *      都不画（`T326③` 实测：播放列表里 210 只标签全在屏幕上，更新区却只有
 *      43 只 0×0 占位标签有）。细节见下面分支里的注释。
 *
 * `budget` 是防活锁的闸：`WM_PAINT` 的处理里可能又把自己标脏
 * （`moonui_native_invalidate` 的配对路径就会），没有上限就是一条无限长的链。
 * 画完预算不报错——剩下的留给常规消息泵，只是不在这一个原子里。
 */
static void moonui_native_present_subtree(HWND h, int *budget, const RECT *clip) {
  HWND kids[256];
  int n = 0;
  int i;
  int transparent;
  HWND c;
  if (h == 0 || *budget <= 0) {
    return;
  }
  /* 裁剪区外的一只都不碰：不画它、也不递归进它的子窗。滚动时视口外的行
   * （刚滚出去的那几行、还没滚进来的那几行）不该被这一帧牵动——`T319`
   * 钉的就是这条：滚出一屏的那 3 只既没画过、也不该有待画区。 */
  if (clip != 0) {
    RECT wr;
    RECT hit;
    if (GetWindowRect(h, &wr) == 0) {
      return;
    }
    if (!IntersectRect(&hit, &wr, clip)) {
      return;
    }
  }
  *budget -= 1;
  transparent = (GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TRANSPARENT) != 0;
  UpdateWindow(h);
  if (transparent) {
    /* `T326③`：透明标签必须**先标脏再投 `WM_PAINT`**，不能只投消息。
     *
     * `SendMessage(WM_PAINT)` 只是让窗口过程跑一遍 `BeginPaint`，而
     * `BeginPaint` 的 `rcPaint` 取的是**更新区**：没有更新区时它是空矩形，
     * 系统 STATIC 用 `rcPaint` 裁字，于是一个字都不画。定位好的标签正好卡在
     * 这个缝里——它们在**藏着的**父窗里被 `SetWindowPos` 摆位置，那次失效按
     * 可见区裁下来是空，`RedrawWindow(RDW_ALLCHILDREN)` 也一样是空转；此后
     * 只要内容不变就再也不会有第二次失效。
     *
     * 实测（2026-11-19，`examples/lunamusic-native`，present 入口读数）：
     * `vis=210` 的窗口里，**定位好的行标签一只更新区都没有**——只有 43 只
     * 0×0 的占位标签还挂着创建时的脏区。老代码（"更新区还在时才补一发"）
     * 因此一条 `WM_PAINT` 都不发，屏幕上整片列表只有斑马底没有字；鼠标划过
     * 哪一行、哪一行走了 `T318` 的配对收笔才冒出来。
     *
     * 对透明窗**无条件**做这一对（不看 `GetUpdateRect`）：它们连脏区都可能
     * 没有，而这正是要补的那一半。`erase=FALSE` 与 `T126` 的口径一致——标签
     * 自己整块画字，先擦一遍只是多一层白。
     *
     * 非透明窗不吃这一发：`UpdateWindow` 已经按更新区画完了，再标脏重画是
     * 白费一次（窗体多的时候这笔账不小）。
     *
     * 标脏走包装 `moonui_native_invalidate` 而不是裸调 `InvalidateRect`
     * （`T140` 的纪律：产品路径的失效一律走包装）。文字层在包装里是早退的
     * 一支——只失效自己、不往外配对，与裸调等价；带底色的透明窗则由包装照
     * `T318` 的口径配对，省得它被底下那块重新盖掉。 */
    moonui_native_invalidate(h, 0);
    SendMessageW(h, WM_PAINT, 0, 0);
  } else if (GetUpdateRect(h, 0, FALSE) != 0) {
    SendMessageW(h, WM_PAINT, 0, 0);
  }
  /* 先快照再递归：`WM_PAINT` 的处理里可能重建子窗树，边遍历边取不安全。 */
  for (c = GetWindow(h, GW_CHILD); c != 0 && n < 256;
       c = GetWindow(c, GW_HWNDNEXT)) {
    kids[n++] = c;
  }
  /* **兄弟之间倒着走**（`T328`）：`GW_CHILD` 是 z 序正序（最上层在前），正着
   * 递归就是"字先画、底后画"——行面板后落底，把刚画好的标签整片盖掉。
   *
   * 播放列表的形态正是这样：行 Panel 与它那 5 只透明标签是**兄弟**（都挂在
   * 视口下），标签在面板之上。渲染底色、`WS_CLIPSIBLINGS` 都不是这里该动的
   * ——那是滚动路径 `scroll_erase` 的活，它第③步本来就是倒序（"自下而上，
   * 面板先落底、标签后落字"）。`present` 这条路漏了同一条纪律：owner 报的
   * "滚动时行里的字轻微闪一下"，量下来是整行 5 只标签同时空白、底色还在，
   * 每次滚动后必现（683 帧 28 次），命中的那一瞬 5 只标签全都欠着更新区。
   *
   * 倒序不是"反过来随便画画"：z 序自下而上，天然就是"先底后字"。子树里
   * 再套子树时同一规矩逐层成立（父先于子，由上一层那次递归保证）。 */
  for (i = n - 1; i >= 0; i -= 1) {
    moonui_native_present_subtree(kids[i], budget, clip);
  }
}

void moonui_native_window_present(moonui_ptr w) {
  int budget = 4096;
  TRACE_AT("present", moonui_native_hwnd(w));
  moonui_native_present_subtree(moonui_native_hwnd(w), &budget, 0);
}

void moonui_native_window_show(moonui_ptr w) {
  HWND hwnd = moonui_native_hwnd(w);
  TRACE("window_show");
  /* `T324` 推翻了 `T121` 那句"RDW_UPDATENOW 故意不加"。
   *
   * `T121` 的顾虑是"别在 show 里同步重画整棵树"——当时怕的是一次同步落笔把
   * show 拖慢。实测下来错的正是这个方向：不在这里画，那 N 条 `WM_PAINT` 就得
   * 由消息泵一条一条还，而每还一条要睡 8ms（见 `moonui_native_present_subtree`
   * 段注），启动那一下要 2.5 秒才长齐，比一次同步落笔慢两个数量级。
   *
   * 所以改成**先画后显**：窗口还藏着的时候就把整棵树画完（含擦旧像素），
   * 再 `ShowWindow` 露出来。用户看到的第一帧就是完成态，中间帧数为 0。
   * 擦（`RDW_ERASE`）也放在藏着的时候——旧像素清掉的那一帧同样没人看得见。 */
  RedrawWindow(hwnd, 0, 0,
               RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_FRAME);
  moonui_native_window_present(w);
  ShowWindow(hwnd, SW_SHOW);
  /* `T121` 那条不变量照旧成立：`ShowWindow` 会让系统把整棵子树重新排进待画
   * 队列（`T121` 探针量过）。露出来之后再收一次——这一发是**已知会发生**的
   * 补画，不是碰巧兜底；成本是一次空遍历（更新区刚被上一次收干净）。
   * `T121` 原文：显示过的窗口，每只子窗口都欠一次重画。 */
  moonui_native_window_present(w);
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
  RemovePropW(hwnd, moonui_native_slot_moved_prop);
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

void moonui_native_window_set_min_size(moonui_ptr w, int width, int height) {
  HWND hwnd = moonui_native_hwnd(w);
  MoonuiWindowMenu *e = moonui_native_menu_entry_of(hwnd);
  TRACE("window_set_min_size");
  if (e == 0) {
    return;
  }
  /* 0 当"清掉限制"（两平台同一口径）。记下来就够——钳位在 WM_GETMINMAXINFO
   * 里兑现；已经比下限还小的窗口由 Core 那侧 set_size 抬上去（系统不会因为设了
   * 下限就自己长大）。 */
  e->min_w = width > 0 ? width : 0;
  e->min_h = height > 0 ? height : 0;
}

int64_t moonui_native_window_min_size(moonui_ptr w) {
  MoonuiWindowMenu *e;
  TRACE("window_min_size");
  e = moonui_native_menu_entry_of(moonui_native_hwnd(w));
  if (e == 0) {
    return moonui_native_pack2(0, 0);
  }
  return moonui_native_pack2(e->min_w, e->min_h);
}

int moonui_native_window_in_live_resize(moonui_ptr w) {
  MoonuiWindowMenu *e;
  TRACE("window_in_live_resize");
  e = moonui_native_menu_entry_of(moonui_native_hwnd(w));
  if (e == 0) {
    return 0;
  }
  return e->in_size_move ? 1 : 0;
}

void moonui_native_window_set_position(moonui_ptr w, int x, int y) {
  HWND hwnd;
  TRACE("window_set_position");
  hwnd = moonui_native_hwnd(w);
  /* inhibit 挡掉"程序化搬窗"的回声（adapter.h 的 on_moved 契约）：Core 的吸附
   * 联动（`App::follow_move`）搬邻居时调的就是这条，那不该回声成一条 WM_MOVE——
   * 否则联动会自拖自、邻居被搬两遍。 */
  moonui_native_inhibit(hwnd);
  SetWindowPos(hwnd, 0, x, y, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER);
  moonui_native_uninhibit(hwnd);
}

int64_t moonui_native_window_position(moonui_ptr w) {
  RECT r;
  TRACE("window_position");
  if (GetWindowRect(moonui_native_hwnd(w), &r) == 0) {
    return moonui_native_pack2(0, 0);
  }
  return moonui_native_pack2(r.left, r.top);
}

/* 测试缝（见 adapter.h）：模拟"外部移窗"——不 inhibit，WM_MOVE 照发，和用户
 * 拖动同一形态（Windows 的 WM_MOVE 在拖动循环里本来就连续发，没有 mac 那种
 * "只在松手补报"的中间态，所以这条不需要轮询配套）。 */
void moonui_native_window_move_external(moonui_ptr w, int x, int y) {
  HWND hwnd;
  TRACE("window_move_external");
  hwnd = moonui_native_hwnd(w);
  SetWindowPos(hwnd, 0, x, y, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER);
}

/* 测试缝（见 adapter.h）：喂一拍"合成拖动"。Windows 没有 mac 那种"拖动中途
 * 无通知"的中间态（WM_MOVE 在拖动循环里连续发、且同线程同步送达），鼠标增量
 * 预测在那侧没有存在的必要——这一拍退化成一次外部移窗：不 inhibit，WM_MOVE
 * 当场走既有链路（→ push_move → 吸附联动），"同拍"由 SendMessage 的同步语义
 * 保证。 */
void moonui_native_window_drag_step(moonui_ptr w, int x, int y) {
  HWND hwnd;
  TRACE("window_drag_step");
  hwnd = moonui_native_hwnd(w);
  SetWindowPos(hwnd, 0, x, y, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER);
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
  HWND hwnd = moonui_native_hwnd(w);
  MoonuiWindowMenu *e;
  LONG style;
  int want;
  TRACE("window_set_titlebar_style");
  /* 沉浸式在 Win32 上 = 摘掉整条标题栏（见上面那节段注）。重复设幂等：
   * 状态没变就什么都不做，不白走一趟 SetWindowPos（那里带 FRAMECHANGED，
   * 每走一次都要重算非客户区、重画一遍）。 */
  e = moonui_native_menu_entry_of(hwnd);
  if (e == 0) {
    return;
  }
  want = immersive != 0 ? 1 : 0;
  if (e->immersive == want) {
    return;
  }
  e->immersive = want;
  if (want && e->bar != 0) {
    /* 沉浸式窗不要系统菜单条（`WM_NCCALCSIZE` 回 0 之后这条也没地方摆了：
     * 它本来是画在非客户区里的）。菜单树本身留着——切回标准标题栏时
     * moonui_native_menu_refresh 会照它重建。 */
    SetMenu(hwnd, 0);
    DestroyMenu(e->bar);
    e->bar = 0;
    e->menu_pad = 0;
  }
  style = GetWindowLongW(hwnd, GWL_STYLE);
  if (want) {
    /* 只摘 WS_CAPTION：WS_THICKFRAME 留着（能拉边）、WS_SYSMENU 留着
     * （系统菜单与 Alt+F4 照旧）。 */
    style &= ~WS_CAPTION;
  } else {
    /* 切回标准标题栏：边框 / 对话框框 / 系统菜单 / 最大化最小化箱全补回来。
     * WS_OVERLAPPEDWINDOW 是这四位的并，与 moonui_native_window_style 同源。 */
    style |= WS_OVERLAPPEDWINDOW;
  }
  SetWindowLongW(hwnd, GWL_STYLE, style);
  /* 非客户区变了必须 FRAMECHANGED，否则要等下一次 resize 才生效。 */
  SetWindowPos(hwnd, 0, 0, 0, 0, 0,
               SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_FRAMECHANGED);
  if (!want) {
    /* 切回标准标题栏：顶上那条菜单得重新挂回来（摘掉的那份在切走时已经
     * 销毁，这里按存下来的树现建一棵）。 */
    moonui_native_menu_refresh(e, 0);
  }
}

int moonui_native_window_titlebar_style(moonui_ptr w) {
  MoonuiWindowMenu *e;
  TRACE("window_titlebar_style");
  /* 读回：沉浸式时三条都置位（bit0/1/2 = 内容铺满 / 标题栏没有 / 标题文字
   * 没有），与 mac 那侧"三条都置位 = 沉浸式"同一个判据——调用方与测试因此
   * 不按平台分叉。标准态回 0。 */
  e = moonui_native_menu_entry_of(moonui_native_hwnd(w));
  if (e == 0 || !e->immersive) {
    return 0;
  }
  return 1 | 2 | 4;
}

void moonui_native_window_set_drag_band(moonui_ptr w, int height) {
  MoonuiWindowMenu *e;
  TRACE("window_set_drag_band");
  /* 自绘顶条多高只有 Core 知道（每只窗不一样：主窗 30、伴随条 22、迷你 48、
   * 桌面窗没有）。C 侧只是把这条高度记下来，供 WM_NCHITTEST 判 HTCAPTION。
   * 负数按 0 处理——不然 WM_NCHITTEST 里 y < drag_h 的判据会变成永不成立。 */
  e = moonui_native_menu_entry_of(moonui_native_hwnd(w));
  if (e == 0) {
    return;
  }
  e->drag_h = height > 0 ? height : 0;
}

int moonui_native_window_drag_band(moonui_ptr w) {
  MoonuiWindowMenu *e;
  TRACE("window_drag_band");
  /* 没设过回 0，与 mac 侧的无操作实现同一个兜底。 */
  e = moonui_native_menu_entry_of(moonui_native_hwnd(w));
  if (e == 0) {
    return 0;
  }
  return e->drag_h;
}

void moonui_native_window_set_corner_radius(moonui_ptr w, int radius_pm) {
  MoonuiWindowMenu *e;
  TRACE("window_set_corner_radius");
  /* 空操作（只记账）：Windows 的窗口外轮廓归 DWM 的 `SetWindowRgn` /
   * 系统圆角策略，没有「改某个半径」的入口——用 SetWindowRgn 画圆角会把
   * 整窗剪成非矩形（输入区域也跟着缺角、边缘有锯齿），与 Core 的矩形客户区
   * 口径冲突。留这条让三平台 ABI 同形、调用方不按平台分叉。 */
  e = moonui_native_menu_entry_of(moonui_native_hwnd(w));
  if (e == 0) {
    return;
  }
  e->corner_radius_pm = radius_pm;
}

int moonui_native_window_corner_radius(moonui_ptr w) {
  MoonuiWindowMenu *e;
  TRACE("window_corner_radius");
  e = moonui_native_menu_entry_of(moonui_native_hwnd(w));
  if (e == 0) {
    return -1;
  }
  return e->corner_radius_pm;
}

int64_t moonui_native_window_movable_probe(moonui_ptr w) {
  TRACE("window_movable_probe");
  /* Windows 半恒 0：拖动带走 WM_NCHITTEST 回 HTCAPTION（上面的 drag_h），
   * 没有 movableByWindowBackground / mouseDownCanMoveWindow 这两个 AppKit
   * 概念。这条进 ABI 只为两半形状对齐（声明了就得两半都定义，判据在
   * scripts/abi-symbols.sh）。 */
  (void)w;
  return 0;
}

int moonui_native_window_is_key(moonui_ptr w) {
  TRACE("window_is_key");
  /* 同一问句在 Win32 的问法：前台窗口是不是这只。 */
  {
    HWND hwnd = moonui_native_hwnd(w);
    if (hwnd == NULL) {
      return -1;
    }
    return GetForegroundWindow() == hwnd ? 1 : 0;
  }
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

int moonui_native_snapshot_all(const char *dir, int dir_len) {
  TRACE("snapshot_all");
  /* 未实现：Windows 半的离屏取图是另一条活（PrintWindow/BitBlt 到 DIB 再编码
   * PNG，要自己接 GDI+ 或 WIC）。按 ABI 约定「没实现」返回 -3，不假装拍了
   * 一张空图——调用方据 -3 说"本平台没这条"。 */
  (void)dir;
  (void)dir_len;
  return -3;
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

int moonui_native_window_on_moved(moonui_ptr w,
                          moonui_closure_fn fn,
                          void *closure) {
  int slot;
  TRACE("window_on_moved");
  slot = moonui_native_take_slot((void *)(uintptr_t)w, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(moonui_native_hwnd(w), moonui_native_slot_moved_prop, slot);
  return 0;
}

/* ---- 窗口态（`T86②`，Windows 半）----
 *
 * SW_ 系列的那半照挂账时定的口径：真代码、只到 mingw 语法闸门（这一批 Windows
 * 的真跑统一欠账挂报告）。语义与 mac 半同一条"只在差异上动"：ShowWindow 是
 * 开关型动作，先问 IsIconic/IsZoomed，真的要变才调——程序重发同一条意图不让
 * 窗口抖一下。恢复那半走 SW_RESTORE：进最小化/最大化之前的样式由窗口系统自己
 * 记着（SW_RESTORE 的定义就是还原），我们不存第二份前置状态（全屏那半的
 * WINDOWPLACEMENT 账是它自己的形状，与这两条无关）。读回打包成位：bit0 =
 * IsIconic、bit1 = IsZoomed——"读当下态"而非推送式，持久化（`T86⑦`）问一次
 * 拿一份快照。 */

void moonui_native_window_set_minimized(moonui_ptr w, int minimized) {
  HWND hwnd = moonui_native_hwnd(w);
  TRACE("window_set_minimized");
  if (minimized != 0 && IsIconic(hwnd) == 0) {
    ShowWindow(hwnd, SW_MINIMIZE);
  } else if (minimized == 0 && IsIconic(hwnd) != 0) {
    ShowWindow(hwnd, SW_RESTORE);
  }
}

void moonui_native_window_set_maximized(moonui_ptr w, int maximized) {
  HWND hwnd = moonui_native_hwnd(w);
  TRACE("window_set_maximized");
  if (maximized != 0 && IsZoomed(hwnd) == 0) {
    ShowWindow(hwnd, SW_MAXIMIZE);
  } else if (maximized == 0 && IsZoomed(hwnd) != 0) {
    ShowWindow(hwnd, SW_RESTORE);
  }
}

int moonui_native_window_state(moonui_ptr w) {
  HWND hwnd = moonui_native_hwnd(w);
  int bits = 0;
  TRACE("window_state");
  if (hwnd != 0) {
    if (IsIconic(hwnd) != 0) {
      bits |= 1;
    }
    if (IsZoomed(hwnd) != 0) {
      bits |= 2;
    }
  }
  return bits;
}

/* ---- 控件 ---- */

/* 控件出生的公共路径：全部寄放在 park 名下（moonui_native_control_attach 时再搬进真
 * 窗口），统一 WS_CHILD|WS_VISIBLE。返回的 HWND 由调用方打记号。
 *
 * **WS_CLIPSIBLINGS 不可省**：它让一只子控件重画时把自己的**兄弟**按 z 序裁掉。
 * 少了它，z 序在下面的兄弟（kind 17 的空白 Panel Static、各种占位的空 Static）
 * 重画时会把整块矩形刷成自己的类底色，把压在它上面的标签/按钮整片盖住——现象
 * 就是"打开全空白，鼠标划过的地方才显形"（2026-10-22 lunamusic 真实现象：
 * 把 6 只大 Static 藏起来，内容当场全露出来）。
 *
 * **`WS_EX_TRANSPARENT` 只给"我这块矩形不归自己填"的窗口**（`T117` 起）。它
 * 与上面那位是一条账的两半：`WS_CLIPSIBLINGS` 让"我画的时候别碰兄弟"，这一位
 * 让"我不画的时候兄弟别停"。缺了它，一只**自己什么都不画**的子窗口（滚动视口
 * kind 15、透明 Panel）会留下一个谁都不管的洞：顶层窗口带 `WS_CLIPCHILDREN`，
 * 擦背景时跳过子窗口占的矩形；底下的 Panel 带 `WS_CLIPSIBLINGS`，画的时候又
 * 被上面这位裁掉。两边都不落笔，那块矩形就没有像素，DWM 直接把**后面的窗口**
 * 透出来——lunamusic 的播放列表里露出背后的终端、鼠标划过才补上，就是这里。
 *
 * **但它不能无条件加，那是 2026-10-23 当场咬回来的一口**。`WS_EX_TRANSPARENT`
 * 的语义不是"我透明"、而是"**把重画的裁剪顺序拧成先兄弟后我**"——于是这一只
 * 被排到所有兄弟**之后**再画。给一只真的透明窗口，兄弟先铺好、我再画（什么
 * 都不画），正好；可给一只**铺满整窗的不透明 Panel**，它就变成压在一切之上的
 * 最后一位，把标签、按钮、列表整片盖掉——现象是"打开一片蓝、鼠标放上去冒出几
 * 颗按钮、移开又没了、移动时内容一直在变"（owner 2026-10-23 的第二张截图）。
 * 而且越大的 Panel 盖得越狠，所以整窗那层先盖住全部内容。
 *
 * 结论：**只在确定这只窗口不填自己矩形时才加**。判据在调用方——
 *   - kind 15 滚动视口：永远不画，直接加（`moonui_native_scroll_proc` 里没有
 *     任何 WM_PAINT 落笔）。
 *   - kind 17 Panel：**运行期**才知道（`bg < 0` 是透明底板，`bg >= 0` 是不透明
 *     底板），所以建窗时先按默认（透明底板）挂上，由 `widget_set_style` 按底色
 *     有无翻这位（见那里的 `moonui_native_sync_transparent`）。
 *   - 其余控件（Label/Button/Checkbox/Edit/…）：系统自己填底色，**不加**。 */
static void moonui_native_sync_transparent(HWND hwnd, int transparent);

static HWND moonui_native_create_control(DWORD exstyle,
                                  LPCWSTR cls,
                                  LPCWSTR text,
                                  DWORD style) {
  TRACE("widget_create");
  if (moonui_native_park == 0) {
    return 0;
  }
  return CreateWindowExW(exstyle, cls, text,
                         WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | style, 0, 0,
                         0, 0, moonui_native_park, 0, GetModuleHandleW(0), 0);
}

/* `WS_EX_TRANSPARENT` 的开关（见 `moonui_native_create_control` 段注）。
 *
 * 为什么不在建窗时一次定死：Panel 的"画不画自己的底"由**底色有没有下发**决定，
 * 而底色是 `widget_set_style` 后来的事（lunamusic 里 Panel 常常先建出来、随后
 * 才拿到 `background=`）。建窗时按 kind 猜不行——同一只 kind 17 两种行为都有。
 *
 * 改了位要顺手失效一次：绘制顺序变了，不重画的话屏幕上还是按老顺序堆着的旧
 * 像素。`erase=TRUE` 让这块连带底下重铺一遍。 */
static void moonui_native_sync_transparent(HWND hwnd, int transparent) {
  LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  LONG_PTR want = transparent ? (ex | (LONG_PTR)WS_EX_TRANSPARENT)
                              : (ex & ~(LONG_PTR)WS_EX_TRANSPARENT);
  if (want == ex) {
    return;
  }
  SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
  moonui_native_invalidate(hwnd, 1);
}

/* ---- 透明标签与底下那层的配对重画（`T140`）----
 *
 * `T139` 让没底色的 Label 挂 `WS_EX_TRANSPARENT`：兄弟先铺底、标签最后只落
 * 文字（那块矩形里字和渐变共用同一份像素）。系统只兑现了这条约定的一半——
 * **底下那层重画时，它不会让上面那只标签跟着重画一遍**：像素被新底盖掉，字
 * 就没了，要等到别的什么原因把标签自己也失效一次才回来。
 *
 * 真窗量到的账：主控窗启动 6 秒后 `00:00` 那块亮像素是 0；强制全窗重画
 * （`RedrawWindow` + RDW_ALLCHILDREN）之后 442；单独重画一条脸面带
 * （`InvalidateRect` + `UpdateWindow`，`erase=FALSE`）又掉回 0，而只失效那只
 * 标签立刻回到 442。悬停时 Core 会把整棵树的样式重推一遍，脸面的渐变条带因此
 * 反复重画——`00:00` / `/ 00:00` / `立体声` / `状态: 就绪` / 标题这批字就是
 * 这样一批批掉下去的（owner 报的"鼠标划过就显示异常"）。
 *
 * 所以这里把账补成对称的：**谁画了底，谁就顺手把压在它上方、与它相交的透明
 * 标签一起失效一遍**。同一轮更新里 GDI 按 z 序自下而上落笔，标签自然排在底的
 * 后面，字重新落回自己那块像素上。
 *
 * 为什么不现找兄弟（`GetWindow(GW_HWNDPREV)` 一路扫）：悬停一次要重推两百来
 * 只控件的样式，每只都扫一遍整条 z 序就是 O(n²)。标签的数量远小于控件总数，
 * 记在一张表上逐个比矩形便宜得多。表由 `widget_set_style`（标签有无底色）与
 * `widget_destroy` 维护，死掉的句柄留到下一次配对时顺手摘掉。
 *
 * 显式给了底色的标签不登记：它自己就是底，系统本来就会管。 */
static HWND *moonui_native_overlays = 0;
static int moonui_native_overlay_len = 0;
static int moonui_native_overlay_cap = 0;

/* 登记（`on != 0`）/ 摘登记。重复登记不会进两条。 */
static void moonui_native_overlay_keep(HWND hwnd, int on) {
  int i;
  for (i = 0; i < moonui_native_overlay_len; i++) {
    if (moonui_native_overlays[i] == hwnd) {
      if (!on) {
        moonui_native_overlays[i] =
            moonui_native_overlays[--moonui_native_overlay_len];
      }
      return;
    }
  }
  if (!on) {
    return;
  }
  if (moonui_native_overlay_len == moonui_native_overlay_cap) {
    int cap = moonui_native_overlay_cap == 0 ? 8 : moonui_native_overlay_cap * 2;
    HWND *next =
        (HWND *)realloc(moonui_native_overlays, sizeof(HWND) * (size_t)cap);
    if (next == 0) {
      /* 分不出内存就退化成"这只标签不参与配对"：它自己画自己那次照旧正确，
       * 只是底重画时不再跟着重画（与改动前同一个现象，不是新错）。 */
      return;
    }
    moonui_native_overlays = next;
    moonui_native_overlay_cap = cap;
  }
  moonui_native_overlays[moonui_native_overlay_len++] = hwnd;
}

/* 测试脚手架：统计带 erase 的失效次数——"删除时内容闪一下"的直接量。
 * 带 erase 的 InvalidateRect 让系统在 WM_PAINT 之前先用控件类背景刷把整块
 * 擦白，重画慢一帧就是用户看到的闪。计数在 reset 后累加，probe 读回。 */
static int moonui_erase_invalidates = 0;
void moonui_native_erase_probe_reset(void) { moonui_erase_invalidates = 0; }
int moonui_native_erase_probe(void) { return moonui_erase_invalidates; }

/* 测试脚手架（`T140` 判据的口径）：累计"被一起重画的透明标签"次数。
 *
 * 为什么不再读更新区：`T318` 之后这两笔是**同一次调用里落完**的（见
 * `moonui_native_invalidate` 函数注），同步画过之后更新区自然就空了，
 * 再拿 `GetUpdateRect` 当"跟没跟着重画"的证据，验的是手段而不是结果。
 * 这里记的是结果本身——配对上几只就加几只。 */
static int moonui_overlay_pairs = 0;

/* 失效 `hwnd`，并联手失效压在它上面的透明标签（段注见上）。
 * `erase` 的语义与 `InvalidateRect` 同（`T126` 之后多数调用点用 0）。
 *
 * **失效之后还要把这两笔当场画掉**（`T318`）：只失效不画的话，"底"和"字"
 * 落在两次 `WM_PAINT` 里（实测还会跨两轮消息），中间那一格就是「新底色 +
 * 没有字」。列表行悬停时每行都要换底，人手划过的每一行都会闪一下空白，
 * 划得快就能同时看到好几行——owner 2026-11-18 的截图里连着五行只剩斑马底。
 * 这里把两笔收在同一条线程、同一次调用里：先 `UpdateWindow(hwnd)` 落底，
 * 再逐个把相交的标签当场画掉（投 `WM_PAINT`，理由见下面的落笔那一节），
 * GDI 的落笔顺序因此天然是"先底后字"，屏幕上不会留下半成品那一帧。
 *
 * 同步重绘只在**真有相交标签**时才做：按钮、标题、输入框这些身上没有透明
 * 标签的控件走不到这一段；每帧重推样式时也只有真换了色的那几只进来
 * （指纹短路在 `widget_set_style` 那一头）。 */
static void moonui_native_invalidate(HWND hwnd, int erase) {
  RECT me;
  int i;
  HWND par;
  HWND overlaps[8];
  int overlap_cnt = 0;
  if (hwnd == 0) {
    return;
  }
  if (erase) {
    moonui_erase_invalidates++;
  }
  /* 包装自己的底座：这一处就是被包装的那次调用本身，
   * det-ok(bare-invalidate): 包装函数内部的底座，没有更里一层可走。 */
  InvalidateRect(hwnd, 0, erase ? TRUE : FALSE);
  if (moonui_native_overlay_len == 0 || GetWindowRect(hwnd, &me) == 0) {
    return;
  }
  /* 自己就是一只文字层时不往外传染：两只标签互相拖进更新区没有任何画面上
   * 的收益（文字不改底下那层的像素），只是白费一次重画。 */
  for (i = 0; i < moonui_native_overlay_len; i++) {
    if (moonui_native_overlays[i] == hwnd) {
      /* `T329`：文字层自己被标脏时也要**当场落笔**。原来这里只失效不画，
       * 而 `present_subtree`（`T326③`）已经证明透明标签常常裁出空更新区；
       * 靠消息泵隔 8ms 补那一笔，点击换选中态时就会有一帧"底换了、字没到"。
       * 与 `present_subtree` 同一对动作：先走上面的包装底座标脏，再直投
       * `WM_PAINT`（`UpdateWindow` 对透明窗不发画，见下面配对那一支）。 */
      SendMessageW(hwnd, WM_PAINT, 0, 0);
      return;
    }
  }
  par = GetParent(hwnd);
  for (i = 0; i < moonui_native_overlay_len;) {
    HWND o = moonui_native_overlays[i];
    RECT r;
    RECT hit;
    if (!IsWindow(o)) {
      moonui_native_overlays[i] =
          moonui_native_overlays[--moonui_native_overlay_len];
      continue;
    }
    i++;
    /* 只跟同一只父窗下的标签配对。`hwnd` 自己就是那只父窗时也算同一层——
     * 顶层窗口整块失效时，它底下所有透明标签都在这次重画的地盘上。 */
    if (GetParent(o) != par && GetParent(o) != hwnd) {
      continue;
    }
    if (GetWindowRect(o, &r) == 0 || !IntersectRect(&hit, &me, &r)) {
      continue;
    }
    /* 被拖进来的那只标签：不能再走一次包装——包装会从它往外再找一遍邻居，
     * 两只标签互相拖进更新区没有画面上的收益，只是白费一次重画（见上段）。
     * det-ok(bare-invalidate): 包装内部的第二处，递归会退化成互相拖。 */
    InvalidateRect(o, 0, FALSE);
    if (overlap_cnt < 8) {
      overlaps[overlap_cnt++] = o;
    }
  }
  /* 同一次调用里落完两笔（`T318`，理由见函数注）。8 只是兜底：一只 Panel
   * 身上的标签通常 3～5 只（列表行 = 行号/标题/歌手/专辑/时长），超出的
   * 那几只照旧等各自的 WM_PAINT——不会漏画，只是不在这一个原子里。
   * det-ok(bare-update): 同步落笔就是本函数存在的理由，不是多余的底座。 */
  if (overlap_cnt > 0) {
    UpdateWindow(hwnd);
    for (i = 0; i < overlap_cnt; i++) {
      /* 这里投 `WM_PAINT` 而不是再叫一次 `UpdateWindow`（`T318` 实测）：对
       * 挂着 `WS_EX_TRANSPARENT` 的子窗口，`UpdateWindow` 与
       * `RedrawWindow(RDW_INVALIDATE | RDW_UPDATENOW)` 都返回"成功"，却连
       * 一次 `WM_PAINT` 都不发、更新区原封不动——三只标签里只有最后一只被
       * 真的画掉，前两只留到下一轮消息泵才补上，屏幕上正是那一格空行。
       *
       * `T329` 把"先问一句"去掉了：这一路配对上的 `overlaps[]` 全是登记过的
       * 透明标签，而透明标签的定位/重排会让 `InvalidateRect` 按可见区裁出
       * **空更新区**（`T326③` 实测：定位好的行标签一只更新区都没有）。于是
       * `GetUpdateRect` 那道门恰好把最需要画的那一批挡掉——点击换选中态时
       * 面板底色重铺、标签却没跟着落笔，屏幕上就是旧/新高亮那一行字没了。
       * `present_subtree` 早就按这个口径无条件投了，这里对齐同一条纪律；
       * 没有更新区时系统 STATIC 的 `BeginPaint` 是空转，不会画错。 */
      SendMessageW(overlaps[i], WM_PAINT, 0, 0);
    }
  }
  moonui_overlay_pairs += overlap_cnt;
}

/* T74 的滚动视口没有对应的标准控件：这里落一只剪裁容器——WS_CLIPCHILDREN
 * 让摆进去的子控件被容器矩形裁掉。真滚动在这只 HWND 上做：`set_content`
 * 按 axis 加 WS_VSCROLL / WS_HSCROLL、SetScrollInfo 给行程；滚动条通知与
 * 视口内滚轮由 `moonui_native_scroll_on_bar` 消费（改偏移动子控件），只有
 * 子控件（如 trackbar）发来的 WM_VSCROLL/WM_HSCROLL（lp≠0）才照旧转发父。 */
static LRESULT CALLBACK moonui_native_scroll_proc(HWND hwnd, UINT msg, WPARAM wp,
                                           LPARAM lp) {
  if (msg == WM_CTLCOLORSTATIC || msg == WM_CTLCOLORBTN) {
    /* 视口里的控件是**视口**的子窗口，文字色/底色问到这儿而不是顶层窗口
     * （见 moonui_native_ctlcolor）。不接这一手的话，滚动区里的 Label 会
     * 一律退回系统色——lunamusic 的播放列表整片在那儿。 */
    HBRUSH brush = 0;
    if (moonui_native_ctlcolor(wp, lp, &brush)) {
      return (LRESULT)(uintptr_t)brush;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_ERASEBKGND) {
    /* 视口带 WS_EX_TRANSPARENT，DefWindowProc 对它**不擦背景**（透明窗口
     * 语义：让兄弟先铺、自己不落笔）。平时没问题——视口只做占位；但滚动
     * 把子控件平移走后，它离开的那块必须有人擦，否则旧像素永久残留 =
     * 用户 2026-11-17 的"滚动残影"。所以这一件自己来：拿根窗口的底色
     * （标准窗 = COLOR_BTNFACE，正是视口该显示的色）铺满整块客户区。
     * WS_CLIPCHILDREN 让填充自动跳过仍在的子控件，不会盖住当前内容。 */
    RECT cr;
    int64_t rgb = moonui_native_window_bg_of(hwnd);
    COLORREF color;
    HBRUSH brush;
    HDC dc = (HDC)wp;
    if (rgb < 0) {
      color = GetSysColor(COLOR_BTNFACE); /* 沉浸式窗问不到，退回系统底色 */
    } else {
      color = RGB((int)(rgb & 0xFF), (int)((rgb >> 8) & 0xFF),
                  (int)((rgb >> 16) & 0xFF));
    }
    brush = CreateSolidBrush(color);
    if (brush != 0 && GetClientRect(hwnd, &cr) != 0) {
      FillRect(dc, &cr, brush);
      DeleteObject(brush);
    }
    return 1; /* 自己擦了，别让 DefWindowProc 再按透明语义跳过 */
  }
  if (msg == WM_NCPAINT) {
    /* 滚动条左缘那一列：主题画滚动条时没拿窗口底色铺底，留下 1px 纯白
     * （owner 2026-11-17 截图②"滚动条左边有一条白线"；真窗判据读到
     * 0xFFFFFF，而视口底色是 0xF0F0F0）。它落在**非客户区**，视口自己的
     * WM_ERASEBKGND 只填客户区，管不到这里。所以画完滚动条之后，用根窗口
     * 底色把客户区右缘那一列补上。只在带滚动条时做，别的时候 NC 一笔不动。 */
    LRESULT painted = DefWindowProcW(hwnd, msg, wp, lp);
    if ((GetWindowLongPtrW(hwnd, GWL_STYLE) & (WS_VSCROLL | WS_HSCROLL)) != 0) {
      RECT cr;
      if (GetClientRect(hwnd, &cr) != 0) {
        HDC ncdc = GetWindowDC(hwnd);
        if (ncdc != 0) {
          int64_t rgb = moonui_native_window_bg_of(hwnd);
          HBRUSH strip_brush =
              CreateSolidBrush(rgb < 0 ? GetSysColor(COLOR_BTNFACE)
                                       : moonui_native_colorref_of(rgb));
          if (strip_brush != 0) {
            RECT strip;
            strip.left = cr.right;
            strip.right = cr.right + 1;
            strip.top = cr.top;
            strip.bottom = cr.bottom;
            FillRect(ncdc, &strip, strip_brush);
            DeleteObject(strip_brush);
          }
          ReleaseDC(hwnd, ncdc);
        }
      }
    }
    return painted;
  }
  /* 视口自己的滚动条通知 / 视口内滚轮：先给滚动逻辑，消费掉就不转发。
   * `moonui_native_scroll_on_bar` 内部按 lp / 命中控件区分"自己这只滚动条"
   * 与"子 trackbar"，前者才算进滚动偏移。 */
  if ((msg == WM_VSCROLL || msg == WM_HSCROLL || msg == WM_MOUSEWHEEL ||
       msg == WM_MOUSEHWHEEL) &&
      moonui_native_scroll_on_bar(hwnd, msg, wp, lp)) {
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
       * GWLP_WNDPROC、不动类注册。
       *
       * `WS_EX_TRANSPARENT` 给它是对的（`T117`）：这只窗口**一点内容都不画**
       * （scroll_proc 里没有任何 WM_PAINT 落笔，STATIC 的类背景也碰不到它的
       * 绘制——它只做占位 + 裁剪矩形）。加上这个位，兄弟先铺满、它再画（什么
       * 也不画），它占的那块就不会是"谁都不落笔"的洞——那正是 lunamusic 播放
       * 列表里透出背后终端的现场。
       *
       * 这个位**只能在确定不填矩形的地方加**：它的实际语义是"排到兄弟之后再
       * 画"，给不透明的大 Panel 加就成了压在一切之上的覆盖层（见
       * `moonui_native_create_control` 段注）。 */
      HWND clip;
      clip = CreateWindowExW(WS_EX_TRANSPARENT, L"STATIC", L"",
                             WS_CHILD | WS_CLIPCHILDREN | WS_VISIBLE |
                                 WS_CLIPSIBLINGS,
                             0, 0, 0, 0, moonui_native_park, 0,
                             GetModuleHandleW(0), 0);
      if (clip != 0) {
        SetWindowLongPtrW(clip, GWLP_WNDPROC, (LONG_PTR)moonui_native_scroll_proc);
      }
      hwnd = clip;
      break;
    }
    case 16:
      /* 图像（`T86⑤`）：绘制归原生层（开工决策记在 TODO `T86⑤`）——STATIC 的
       * SS_BITMAP 位让控件显示 STM_SETIMAGE 塞进去的 HBITMAP；SS_CENTERIMAGE
       * 保平铺不拉伸（拉伸是 Core 排布局的事，不在这层猜）。 */
      hwnd = moonui_native_create_control(0, L"static", L"",
                                   SS_BITMAP | SS_CENTERIMAGE);
      break;
    case 17:
      /* 自绘面板（皮肤账的载体）：自家窗口类的子窗口，类背景 NULL、底色与
       * 圆角由 panel_proc 按 skin prop 画（见 moonui_native_panel_proc 段注）。
       * 挂接仍走 container_attach 的 kind 17 分支（子树平铺到 Panel 的父窗），
       * 这只窗口只负责"占住矩形 + 画自己的底"。
       *
       * 建出来先挂 `WS_EX_TRANSPARENT`：此刻样式还没下发，按 Panel 的默认语义
       * （没底色 = 透明底板）它就是"不填自己矩形"的那一类。等
       * `widget_set_style` 给了底色，`moonui_native_sync_transparent` 会把它摘掉
       * （见 create_control 段注：给不透明面板留着这个位就是让它盖住一切）。 */
      hwnd = moonui_native_create_control(WS_EX_TRANSPARENT,
                                          moonui_native_panel_class_name, L"", 0);
      break;
    case 18:
      /* 自定义绘制面（`T111`，§17 的 CustomWidget）：自家窗口类的子窗口
       * host——占住布局矩形、贴画布帧、接点击/焦点/捕获（过程见
       * moonui_native_custom_proc），没有 WS_TABSTOP：焦点默认不抢，
       * custom_set_focusable 声明过才加（与 mac 的 acceptsFirstResponder
       * 默认 NO 同一条）。 */
      hwnd = moonui_native_create_control(0, moonui_native_custom_class_name,
                                   L"", 0);
      break;
    default:
      break;
  }
  free(t);
  if (hwnd == 0) {
    return 0;
  }
  /* `T85②`：单行文本控件（kind 2/4）换子类过程，把 WM_IME_* 从焦点 EDIT 的
   * 窗口过程里分流出来（顶层窗口过程看不见它们的理由记在 IME 那节）。装不上
   * 就保持系统 EDIT 原样，控件照常工作，只是没有相位事件源。多行（kind 10）
   * 不走这里、在自己的创建入口装（`T90④`，见 moonui_native_multiline_new）。 */
  if (kind == 2 || kind == 4) {
    moonui_native_ime_subclass(hwnd);
  }
  /* `T115`①：按钮 / 菜单行换子类过程，皮肤通道给了底色时自己画平面脸
   * （理由与四态见 moonui_native_button_proc 那节）。没给底色的钮一律链回
   * 系统过程，外观与以前逐像素相同。 */
  if (kind == 1 || kind == 14) {
    moonui_native_button_subclass(hwnd);
  }
  if (!moonui_native_finish_new(hwnd, kind)) {
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
  /* 皮肤半（`T132`）：给了底色就自己画轨道；没给就保持系统原生外观。 */
  moonui_native_slider_subclass(hwnd);
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
  if (hwnd == 0) {
    return 0;
  }
  /* `T90④`：多行的组合相位与单行同一套（`T85②` 的子类过程）——系统 EDIT 过程在
   * ES_MULTILINE 下照样收 WM_IME_START/COMPOSITION/END 三类消息，子类过程不用
   * 分叉。多行不走 native_widget_new，所以在这里单独装一次。 */
  moonui_native_ime_subclass(hwnd);
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
  /* 从"透明标签"表里摘掉（`T140`）：句柄随后就没了，留着只会让下一次配对
   * 走一遍 `IsWindow` 兜底。 */
  moonui_native_overlay_keep(hwnd, 0);
  moonui_native_forget((void *)(uintptr_t)c, 0);
  moonui_native_unmark_all(hwnd); /* 顺带销毁 spinbox 的 updown、free 单选组的名单 */
  DestroyWindow(hwnd);
}

/* ---- 图像源（`T86⑤`，Windows 半：WIC 解码到 HBITMAP）----
 *
 * 解码归平台（开工决策记在 TODO `T86⑤`）：IWICImagingFactory 按次现建
 * （CoInitializeEx 已由文件面板那半在 init 时做过，STA），两条通道都是
 * "解码 → 32bpp PRGBA 格式转换器 → CreateDIBSection → CopyPixels →
 * STM_SETIMAGE"。整源替换：STM_SETIMAGE 返回旧图，旧的 DeleteObject——
 * STATIC 不接管 HBITMAP 的所有权，我们替调用方看守这一份。返回码：0 = 装上了；
 * -1 = 解码失败（路径不存在 / 数据不是平台认得的编码格式，§33 调用方错）；
 * -2 = 句柄不指图像控件（kind 记号不是 16）。这半只到 mingw 语法闸门，
 * 真跑欠账挂报告。 */

static HWND moonui_native_image_hwnd(moonui_ptr c) {
  HWND hwnd = moonui_native_hwnd(c);
  if (hwnd == 0 || moonui_native_kind_of_hwnd(hwnd) != 16) {
    return 0;
  }
  return hwnd;
}

/* 解码器 → HBITMAP。失败返回 0；中间每一步失败都把已经拿到的引用退干净。 */
static HBITMAP moonui_native_wic_bitmap_of(IWICImagingFactory *factory,
                                    IWICBitmapDecoder *decoder) {
  IWICBitmapFrameDecode *frame = 0;
  IWICFormatConverter *conv = 0;
  UINT w = 0;
  UINT h = 0;
  HDC hdc = 0;
  BITMAPINFO bi;
  BYTE *bits = 0;
  HBITMAP out = 0;
  if (decoder == 0) {
    return 0;
  }
  if (FAILED(decoder->lpVtbl->GetFrame(decoder, 0, &frame))) {
    return 0;
  }
  if (FAILED(factory->lpVtbl->CreateFormatConverter(factory, &conv))) {
    frame->lpVtbl->Release(frame);
    return 0;
  }
  if (FAILED(conv->lpVtbl->Initialize(conv, (IWICBitmapSource *)frame,
                                      &GUID_WICPixelFormat32bppPRGBA,
                                      WICBitmapDitherTypeNone, 0, 0.0,
                                      WICBitmapPaletteTypeCustom))) {
    conv->lpVtbl->Release(conv);
    frame->lpVtbl->Release(frame);
    return 0;
  }
  conv->lpVtbl->GetSize(conv, &w, &h);
  hdc = GetDC(0);
  if (hdc != 0 && w > 0 && h > 0) {
    ZeroMemory(&bi, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = (LONG)w;
    bi.bmiHeader.biHeight = -(LONG)h; /* 顶行在前，CopyPixels 的行序一致 */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    out = CreateDIBSection(hdc, &bi, DIB_RGB_COLORS, (void **)&bits, 0, 0);
    if (out != 0) {
      if (FAILED(conv->lpVtbl->CopyPixels(conv, 0, w * 4,
                                          (UINT)w * 4 * (UINT)h, bits))) {
        DeleteObject(out);
        out = 0;
      }
    }
    ReleaseDC(0, hdc);
  }
  conv->lpVtbl->Release(conv);
  frame->lpVtbl->Release(frame);
  return out;
}

static HBITMAP moonui_native_wic_decode_file(const WCHAR *path) {
  IWICImagingFactory *factory = 0;
  IWICBitmapDecoder *decoder = 0;
  HBITMAP out = 0;
  if (FAILED(CoCreateInstance(&CLSID_WICImagingFactory, 0, CLSCTX_INPROC_SERVER,
                              &IID_IWICImagingFactory, (void **)&factory))) {
    return 0;
  }
  if (FAILED(factory->lpVtbl->CreateDecoderFromFilename(
          factory, path, 0, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
          &decoder))) {
    factory->lpVtbl->Release(factory);
    return 0;
  }
  out = moonui_native_wic_bitmap_of(factory, decoder);
  decoder->lpVtbl->Release(decoder);
  factory->lpVtbl->Release(factory);
  return out;
}

static HBITMAP moonui_native_wic_decode_data(const BYTE *data, int len) {
  IWICImagingFactory *factory = 0;
  IWICBitmapDecoder *decoder = 0;
  HBITMAP out = 0;
  HGLOBAL h = 0;
  IStream *stream = 0;
  void *p;
  if (FAILED(CoCreateInstance(&CLSID_WICImagingFactory, 0, CLSCTX_INPROC_SERVER,
                              &IID_IWICImagingFactory, (void **)&factory))) {
    return 0;
  }
  h = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)len);
  if (h == 0) {
    factory->lpVtbl->Release(factory);
    return 0;
  }
  p = GlobalLock(h);
  if (p == 0) {
    GlobalFree(h);
    factory->lpVtbl->Release(factory);
    return 0;
  }
  memcpy(p, data, (size_t)len);
  GlobalUnlock(h);
  if (FAILED(CreateStreamOnHGlobal(h, TRUE, &stream))) {
    GlobalFree(h);
    factory->lpVtbl->Release(factory);
    return 0;
  }
  if (FAILED(factory->lpVtbl->CreateDecoderFromStream(
          factory, stream, 0, WICDecodeMetadataCacheOnDemand, &decoder))) {
    stream->lpVtbl->Release(stream);
    factory->lpVtbl->Release(factory);
    return 0;
  }
  out = moonui_native_wic_bitmap_of(factory, decoder);
  decoder->lpVtbl->Release(decoder);
  stream->lpVtbl->Release(stream);
  factory->lpVtbl->Release(factory);
  return out;
}

/* 装图：STATIC 不接管 HBITMAP，STM_SETIMAGE 返回的那份旧的在这里 DeleteObject。 */
static void moonui_native_image_install(HWND hwnd, HBITMAP hb) {
  HBITMAP prev;
  if (hb == 0) {
    return;
  }
  prev = (HBITMAP)(uintptr_t)SendMessageW(hwnd, STM_SETIMAGE, IMAGE_BITMAP,
                                   (LPARAM)(uintptr_t)hb);
  if (prev != 0 && prev != hb) {
    DeleteObject(prev);
  }
}

int moonui_native_image_set_path(moonui_ptr c, const char *path, int path_len) {
  HWND hwnd;
  LPWSTR wpath;
  HBITMAP hb;
  TRACE("image_set_path");
  hwnd = moonui_native_image_hwnd(c);
  if (hwnd == 0) {
    return -2;
  }
  wpath = moonui_native_utf16_of(path, path_len);
  if (wpath == 0) {
    return -1;
  }
  hb = moonui_native_wic_decode_file(wpath);
  free(wpath);
  if (hb == 0) {
    return -1;
  }
  moonui_native_image_install(hwnd, hb);
  return 0;
}

int moonui_native_image_set_data(moonui_ptr c, const char *data, int data_len) {
  HWND hwnd;
  HBITMAP hb;
  TRACE("image_set_data");
  hwnd = moonui_native_image_hwnd(c);
  if (hwnd == 0) {
    return -2;
  }
  if (data == 0 || data_len <= 0) {
    return -1;
  }
  hb = moonui_native_wic_decode_data((const BYTE *)data, data_len);
  if (hb == 0) {
    return -1;
  }
  moonui_native_image_install(hwnd, hb);
  return 0;
}

/* 图像探针（`T91⑤` Windows 半，adapter.h 有声明）：问 STATIC 自己——
 * STM_GETIMAGE 取回那只 HBITMAP，GetObject 量像素尺寸。打包与 mac 半同
 * 一套：低 8 位 = 有没有图，8..23 位 = 宽，24..39 位 = 高；-1 = 句柄不指
 * Image 控件。这只读不做——不量内容，只证"WIC 解码真出了位图、真装上了
 * STATIC"（真显那半由布局/重排通道的既有判据负责）。 */
int64_t moonui_native_image_probe(moonui_ptr c) {
  HWND hwnd;
  HBITMAP hb;
  BITMAP bm;
  TRACE("image_probe");
  hwnd = moonui_native_image_hwnd(c);
  if (hwnd == 0) {
    return -1;
  }
  hb = (HBITMAP)(uintptr_t)SendMessageW(hwnd, STM_GETIMAGE, IMAGE_BITMAP, 0);
  if (hb == 0) {
    return 0;
  }
  if (GetObjectW(hb, sizeof(bm), &bm) == 0) {
    return 0;
  }
  return (int64_t)1 | ((int64_t)(UINT16_MAX & bm.bmWidth) << 8) |
         ((int64_t)(UINT16_MAX & bm.bmHeight) << 32);
}

/* 设图像的适配模式（`T338`，adapter.h 契约）：Windows 半**全族显式缺席**，
 * 恒 -1。STATIC + SS_BITMAP | SS_CENTERIMAGE 是"原样显示塞进去的 HBITMAP"，
 * 没有任何缩放分支；要 fit 就得在 C 侧留一份源位图、按客户端矩形用 WIC scaler
 * 重解、窗口每缩一次重算——那是另一档工作量，等真需求按 T18 判据再谈。
 * Core 侧把这个 -1 译成 OperationFailed，调用面不按平台分叉。 */
int moonui_native_image_set_fit(moonui_ptr c, int fit) {
  TRACE("image_set_fit");
  (void)c;
  (void)fit;
  if (moonui_native_image_hwnd(c) == 0) {
    return -2;
  }
  return -1;
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

/* `T327`：把 `hwnd` 那块地按 z 序从下往上重铺一遍，再让 `hwnd` 落字。
 *
 * 为什么单立这条路：`T321` 的"沿 holder 链找画底的那只祖先"只在**底由祖先
 * 画**时成立。播放条的脸面是 `stack([gradient_panel, face_body])`——渐变条带
 * 是 `face_body` 的**兄弟**，标签的祖先链往上只剩纯容器，实测一级就到底
 * （`MoonuiWndClass`，`holder` 与 `GetParent` 都断在那里）。祖先链上找不到
 * 那只 Panel，`T321` 那一路就整段放弃：`SetWindowTextW` 后旧字留在原地，新字
 * 叠上去——`00:00 → 00:12` 糊成一团、`状态: 就绪 → 状态: 播放` 两串字压在一
 * 起（owner 2026-11-19 截图）。列表行、页签标题没这个现象，正是因为它们的
 * 底由祖先的 Panel 画，走的是 `T321` 那条。
 *
 * 做法：以顶层窗口为范围、以标签矩形为界做一次
 * `RedrawWindow(RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW)`——凡与这块
 * 地相交的子窗（含兄弟的渐变条带）一起失效并按 z 序重画，"先底后字"由绘制
 * 顺序保证。矩形只覆盖标签本身，GDI 会把它裁到这块地上，代价与一次小重铺
 * 相当；换文案不是高频动作（时间每秒一次、状态按事件）。
 *
 * 随后补一发 `InvalidateRect` + `WM_PAINT` 给标签自己：`WS_EX_TRANSPARENT`
 * 的子窗在 `UPDATENOW` 里不保证收到画消息（`T318` 实测），漏了它就只剩
 * "底被擦掉、字也没画"的一帧。 */
static void moonui_native_repaint_under(HWND hwnd) {
  HWND root;
  RECT r;
  if (hwnd == 0) {
    return;
  }
  root = GetAncestor(hwnd, GA_ROOT);
  if (root == 0 || root == hwnd) {
    return;
  }
  if (GetWindowRect(hwnd, &r) == 0) {
    return;
  }
  MapWindowPoints(HWND_DESKTOP, root, (POINT *)&r, 2);
  RedrawWindow(root, &r, 0,
               RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
  /* 标脏走包装而不是裸调 `InvalidateRect`（`T140` 纪律：产品路径的失效一律走
   * 包装）。文字层在包装里是早退的一支——失效自己、不往外配对，与裸调等价。 */
  moonui_native_invalidate(hwnd, 0);
  SendMessageW(hwnd, WM_PAINT, 0, 0);
}

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
  if (kind == 1 || kind == 14) {
    /* 平面钮（`T115`①）走自己的 button_proc 自绘脸；comctl32 v6 的主题按钮
     * 每收一次 WM_SETTEXT 都会画一遍**系统主题脸**（近白 #FDFDFD）盖掉我们
     * 那张皮肤脸，要等下一轮自绘 WM_PAINT 才恢复。refresh_bar 每拍对播放/
     * 模式两只钮下发**同一串**文案，于是它们间歇性闪白（owner 2026-11-19
     * 截图：拖动音量条时那两颗钮变白）——探针实测对一只正常钮连发 40 次
     * WM_SETTEXT，白像素从 0/20 涨到 10/20 且不再自恢复。mac 半的
     * NSButton setStringValue 对同串是幂等的，这里对齐那条语义：文本没变
     * 就不碰窗口，系统脸不会被无谓地画上去。真变了的那一次仍会走下面那句
     * SetWindowTextW（按钮_proc 的 WM_SETTEXT 分支随即把皮肤脸画回来）。 */
    int n = GetWindowTextLengthW(hwnd);
    if (n == text_len) {
      WCHAR *old = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
      if (old != 0) {
        old[0] = L'\0';
        GetWindowTextW(hwnd, old, n + 1);
        if (wcscmp(old, w) == 0) {
          free(old);
          free(w);
          return;
        }
        free(old);
      }
    }
  }
  SetWindowTextW(hwnd, w);
  free(w);
  /* 换文案要连旧字一起擦掉（`T321`，Windows 半）。透明背景的 Label（设了
   * 前景、没设底色 → `ctlcolor` 回 TRANSPARENT + NULL_BRUSH、挂
   * `WS_EX_TRANSPARENT`、登记进 overlay）是标准 STATIC：`SetWindowTextW` 后
   * 系统只让它在原矩形里 DrawText 落**新**字，不擦**旧**字——两组字错位叠印
   * 就是 owner 2026-11-19 看到的「切页签标题糊成一团」。mac 那半的
   * `NSTextField setStringValue:` 自带擦除，只有 Windows 有这条洞。
   *
   * 不能自己拿父底色 FillRect（会盖掉底下的渐变 / 图片 —— 见 T139/T140
   * 的注）：正解是让**画底的那层**重铺这块矩形、再由配对机制把这只标签
   * 「先底后字」当场画一遍，旧字随底一起被盖掉、新字落回原位。沿 holder
   * 链找第一只自己画底的祖先（Panel kind 17 或有底色的控件），对它走
   * `moonui_native_invalidate`（配对 + 同步落笔都在那一个函数里）。底色
   * 换文案不是高频动作，整块重铺一次可以接受。
   *
   * 链上找不到那只祖先时走 `moonui_native_repaint_under`（`T327`）：那种
   * 情形的底是**兄弟**画的（`stack([gradient_panel, ...])`），得连兄弟一起
   * 重铺才有得擦。 */
  if (kind == 0 && moonui_native_rgb_prop(hwnd, moonui_native_bg_prop) < 0) {
    HWND p = hwnd;
    int guard = 0;
    int repainted = 0;
    while (guard < 64) {
      HWND up = (HWND)(uintptr_t)GetPropW(p, moonui_native_holder_prop);
      if (up == 0) {
        up = GetParent(p);
      }
      if (up == 0 || up == p) {
        break;
      }
      p = up;
      /* kind 17 的 Panel 在 WM_PAINT 里自己铺底；有 bg 的控件也在自己的
       * 过程里画底。只有这两类重铺才真能盖掉标签矩形里的旧字。 */
      if (moonui_native_kind_of_hwnd(p) == 17 ||
          moonui_native_rgb_prop(p, moonui_native_bg_prop) >= 0) {
        moonui_native_invalidate(p, 0);
        repainted = 1;
        break;
      }
      guard += 1;
    }
    if (!repainted) {
      moonui_native_repaint_under(hwnd);
    }
  }
}

/* 占位提示（adapter.h）：只有单行 EDIT（kind 2 TextInput / kind 4
 * PasswordInput）有占位；空串即清。
 *
 * 文案存进 `moonui.placeholder` 这枚 prop，画法在 EDIT 的子类过程里
 * （`moonui_native_edit_paint_placeholder`，`T317`）。**不落 EM_SETCUEBANNER**：
 * 系统那条 cue 会在聚焦 / 重画的某些时机整条不画，而它是这个框唯一的提示
 * 来源（owner 2026-11-18 截图：点进搜索框后占位消失，框空着没有任何提示）。 */
void moonui_native_widget_set_placeholder(moonui_ptr c, const char *text, int text_len) {
  HWND hwnd = moonui_native_hwnd(c);
  char *old;
  char *copy = 0;
  int kind = moonui_native_kind_of(c);
  TRACE("widget_set_placeholder");
  if (kind != 2 && kind != 4) {
    return; /* Core 侧已按 kind 拦，这里再兜一道 */
  }
  if (text != 0 && text_len > 0) {
    copy = (char *)malloc((size_t)text_len + 1u);
    if (copy == 0) {
      return;
    }
    memcpy(copy, text, (size_t)text_len);
    copy[text_len] = '\0';
  }
  old = (char *)(uintptr_t)GetPropW(hwnd, moonui_native_placeholder_prop);
  if (copy != 0) {
    SetPropW(hwnd, moonui_native_placeholder_prop, (HANDLE)(uintptr_t)copy);
  } else {
    RemovePropW(hwnd, moonui_native_placeholder_prop);
  }
  if (old != 0) {
    free(old);
  }
  /* 换文案 / 撤文案都要重画这块（撤的时候旧的那行字得跟着走）。erase=FALSE：
   * 空字段那一帧本来就是我们整块自己落笔，不需要系统先垫一层白。 */
  moonui_native_invalidate(hwnd, 0);
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

/* ---- 不透明度（T84 动画通道）----
 *
 * 子窗口分层透明：WS_EX_LAYERED + SetLayeredWindowAttributes(LWA_ALPHA)。
 * 分层位 Win8 起子窗口才支持（挂账时说的"很麻烦的一档"——成本显著高于
 * mac 半的 NSView alphaValue，代价记在案）。
 *
 * **T89① 真跑实测改写了这条的产品语义（2026-10-22，owner 裁决"顶层生效 +
 * 控件级记平台限制"）**：本机（Win11 22631，RDP 会话）上 WS_EX_LAYERED 在
 * 子窗口上被系统整体拒绝——CreateWindowEx 带 WS_EX_LAYERED 报
 * ERROR_INVALID_PARAMETER、SetWindowLong 运行时置位被静默剥掉、
 * SetLayeredWindowAttributes 跟着失败（干净的最小复刻进程里同样，与 DPI
 * 感知无关；顶层窗口则完全正常）。所以这条 ABI 在 Windows 上的有效面是
 * **顶层窗口**：对窗（window_new 的那只 HWND）调，alpha 真生效；对控件
 * （子窗口）调，置位被系统剥掉、等于 no-op——控件级记为平台限制，等
 * §44 自绘/渲染器成熟后用"画布乘 alpha"覆盖。updown 同账那半保留：在
 * 支持子分层的环境里（物理 console 待验证）它仍是正身。
 * 千分比 0..1000 进，出界夹紧；全显（1000）时撤掉分层位恢复原生绘制
 * ——不给"只是路过 1.0"的树留下永久分层开销。
 * 样式那份（颜色/圆角/字体）照旧不读——除 opacity 外豁免不动。 */

/* 单只 HWND 的分层 alpha 收拾：置位/撤位 + LWA_ALPHA。alpha 随时可改
 * （不用动 frame），置位/撤位那次风格变化补一条 SWP_FRAMECHANGED 让
 * 非客户区重算。在子分层被系统剥掉的环境里，对子窗口的置位是静默 no-op
 * （见上面那段注）。 */
static void moonui_native_set_layered_alpha(HWND hwnd, int opacity) {
  LONG style;
  style = GetWindowLongW(hwnd, GWL_EXSTYLE);
  if (opacity >= 1000) {
    if ((style & WS_EX_LAYERED) != 0) {
      SetWindowLongW(hwnd, GWL_EXSTYLE, style & ~WS_EX_LAYERED);
      SetWindowPos(hwnd, 0, 0, 0, 0, 0,
                   SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_FRAMECHANGED);
    }
  } else {
    if ((style & WS_EX_LAYERED) == 0) {
      SetWindowLongW(hwnd, GWL_EXSTYLE, style | WS_EX_LAYERED);
      SetWindowPos(hwnd, 0, 0, 0, 0, 0,
                   SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_FRAMECHANGED);
    }
    SetLayeredWindowAttributes(hwnd, 0, (BYTE)((opacity * 255) / 1000),
                               LWA_ALPHA);
  }
}

void moonui_native_widget_set_opacity(moonui_ptr c, int opacity) {
  HWND hwnd;
  HWND updown;
  TRACE("widget_set_opacity");
  if (opacity < 0) {
    opacity = 0;
  }
  if (opacity > 1000) {
    opacity = 1000;
  }
  hwnd = moonui_native_hwnd(c);
  moonui_native_set_layered_alpha(hwnd, opacity);
  updown = moonui_native_updown_of(hwnd);
  if (updown != 0) {
    /* spinbox 的 updown 跟 edit 同账——visible/enabled 那两条的同一规则，
     * 不跟着走就会一个剩在窗口上不透明。 */
    moonui_native_set_layered_alpha(updown, opacity);
  }
}

/* ---- 皮肤通道的 Windows 落点（adapter.h 皮肤段的平台注）----
 *
 * 四处定点消费，与 mac 半同一批 kind：
 *   Panel(17)      → 底色 + 圆角（自绘，panel_proc 里画）
 *   Label(0)       → 文字色 + 字体 + 底色（WM_CTLCOLOR* 那条）
 *   Checkbox(3)    → 文字色 + 字体
 *   Button(1)/MenuRow(14) → 文字色 + 字体 + **平面底 + 圆角**（自绘，
 *                    button_proc 里画，四态）
 * 其余 kind 静默忽略。
 *
 * **Windows 与 mac 的实况差**（这决定了下面每条为什么这么写）：
 * - 系统控件的文字色走 `WM_CTLCOLORSTATIC` / `WM_CTLCOLORBTN` 这两条
 *   "问父窗口要画刷"的消息，所以颜色记在控件自己的属性表上、由**父窗口
 *   过程**读出来用（父过程 = 顶层窗口过程 / 滚动视口过程 / 单选组容器，
 *   三处都接了）。
 * - 字体走 `WM_SETFONT`：控件的文字度量随之变，`widget_minimum_size` 那条
 *   链要跟着问控件自己挂的字体（`moonui_native_text_extent_for`），否则
 *   样式改了字号、固有宽度还按消息字体算，按钮会被裁字。
 * - **按钮底色得自己画**（`T115`①）：comctl32 v6 的主题绘制会让
 *   `WM_CTLCOLORBTN` 对 push button 整条失效（系统照样画主题脸），所以
 *   Button / MenuRow 换了子类过程，给了底色时整张脸（正常 / 悬停 / 按下 /
 *   禁用四态 + 标题 + 焦点框）由 `moonui_native_button_paint` 画，圆角落成
 *   窗口区域。**没给底色的钮一律链回系统过程**——未用皮肤通道的窗口外观
 *   逐像素不变。为什么不是 `BS_OWNERDRAW` 记在 button_proc 段注（父窗口
 *   有三处、`BCM_GETIDEALSIZE` 会对 owner-draw 失答）。
 * - Checkbox(3) 不吃平面底那一层：勾选框由系统画，换掉脸就得连勾选态一起
 *   重画，那是另一笔账。它的文字色/字体照旧（显式底色仍走 CTLCOLOR，
 *   与 Label 同一条）。
 * - Label 的底色默认**透明**（`SetBkMode(TRANSPARENT)` + 空画刷）：与 mac 的
 *   NSTextField 默认不画底同一条；显式给过背景色才铺那块色。 */

/* 按 font_permille / weight 造一只 HFONT，字族取系统消息字体那个（与固有尺寸
 * 的度量基准同一族，量出来的宽才对得上画出来的字）。
 *
 * 字号单位是**逻辑像素 ×1000**（`§30`：公共 API 只有逻辑像素；mac 半的
 * `systemFontOfSize:` 收的也是这个数，那边 1 点就是 1 逻辑像素，所以两份 C
 * 从同一个数出发。本文件的 lfHeight 是**物理像素**，于是这里唯一一次换算
 * 是乘 `dpi/96`。
 *
 * 早先这里写的是 `pt * dpi / 72`（把千分比当"点"读），125% 屏上 10 逻辑像
 * 素的字被画成 16.7 物理像素——比该有的大三成：`状态: 就绪` 这类定宽标签
 * 直接溢出成省略号，`♪ 音乐窗` 顶穿 20 高的框，就是 owner 报的"文字过大，
 * 看不全 / 按钮显示省略号"（`T131`）。
 *
 * 两个参数都收 -1 = "这项不动"：负值时调用方已经把**上一次的值**填进来了
 * （见 widget_set_style 里读回 fontpt/weight 那两行），所以这里两个值都是
 * 已经落在 -1 或有效值上的"生效值"——font_permille < 0 表示字号回系统默认。
 * 失败返回 0（调用方保持原字体）。 */
static HFONT moonui_native_font_of(HWND hwnd, int font_permille, int weight) {
  NONCLIENTMETRICSW ncm;
  LOGFONTW lf;
  int dpi = moonui_native_dpi_of(hwnd);
  memset(&ncm, 0, sizeof(ncm));
  ncm.cbSize = (DWORD)sizeof(ncm);
  if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, (DWORD)sizeof(ncm), &ncm,
                            0) == 0) {
    return 0;
  }
  lf = ncm.lfMessageFont;
  /* 字体族（跨平台统一外观）：应用显式选了就填 lfFaceName，没选保持消息字体
   * 那一族（§32）。UTF-8 prop 转宽字符；名字过长按 LF_FACESIZE 截——CreateFont
   * 对找不到的族会自己回落到系统字体，这里不额外做字体存在性检查。 */
  {
    char *family =
        (char *)(uintptr_t)GetPropW(hwnd, moonui_native_family_prop);
    if (family != 0 && family[0] != '\0') {
      int w = MultiByteToWideChar(CP_UTF8, 0, family, -1, lf.lfFaceName,
                                  LF_FACESIZE);
      if (w <= 0) {
        lf.lfFaceName[0] = L'\0';
      }
    }
  }
  if (font_permille >= 0) {
    double px = (double)font_permille / 1000.0; /* 逻辑像素 */
    lf.lfHeight = -(LONG)((px * (double)dpi) / 96.0 + 0.5);
    if (lf.lfHeight == 0) {
      lf.lfHeight = -1;
    }
  }
  /* weight 通道只兑现 Regular/Bold 两档（与 mac 半注一致：Medium 平台退
   * Regular；mock 的 is_bold 判据也只认 Bold）。 */
  lf.lfWeight = (weight == 2) ? FW_BOLD : FW_NORMAL;
  return CreateFontIndirectW(&lf);
}

/* 这一种 kind 身上有文字吗——装默认字（`T313`）与"一屏几种字"探针共用一张
 * 名单，免得两处各写一套、哪天加了新控件只改一处。没有文字的：
 * Separator(5) / Slider(6) / Spinbox(7) / Progress(8) / VSeparator(13) /
 * Scroll(15) / Image(16) / Panel(17) / Custom(18)。 */
static int moonui_native_kind_has_text(int kind) {
  switch (kind) {
    case 0:  /* Label */
    case 1:  /* Button */
    case 2:  /* Entry */
    case 3:  /* Checkbox */
    case 4:  /* PasswordEntry */
    case 9:  /* ComboBox */
    case 10: /* MultilineEntry */
    case 11: /* RadioButtons */
    case 12: /* DatePicker */
    case 14: /* MenuRow */
      return 1;
    default:
      return 0;
  }
}

/* 建出来就装上系统消息字体（`T313`）。凡是有文字的 kind 都装；Slider /
 * Spinbox / Progress / Separator / Scroll / Image / Panel / Custom 没有文字，
 * 装了只会白造一只 HFONT。
 *
 * **为什么非装不可**（owner 2026-11-18 截图："一个界面上有各种各样的字体"）：
 * Win32 的 `Static`/`Button` 不给 `WM_SETFONT` 时用的是**类默认字体**，本机
 * 实测 `DEFAULT_GUI_FONT` 是 **SimSun（宋体）**；而造字（本函数上一节）与量宽
 * （`widget_minimum_size`）用的都是**消息字体**（中文 Win11 = Microsoft YaHei
 * UI）。于是同一屏上：下发过 font_size 的控件是雅黑，没下发的（侧栏那三个页
 * 签、`共 0 首`）是宋体——不止两族混排，量宽与画字还不是同一只字。
 * 装一只消息字体上去，族合一、尺也合一。
 *
 * 装的时候把 HFONT 记进 `moonui_native_font_prop`：销毁时由
 * `moonui_native_unmark_all` 还掉，与皮肤通道换字那条同一个所有权口径；
 * 之后 `widget_set_style` 换字也会按同一枚 prop 把这只还掉。 */
static void moonui_native_install_default_font(HWND hwnd, int kind) {
  HFONT font;
  if (!moonui_native_kind_has_text(kind)) {
    return;
  }
  font = moonui_native_font_of(hwnd, -1, -1);
  if (font == 0) {
    return; /* 系统答不出消息字体：保持类默认，与改动之前逐像素一致 */
  }
  SendMessageW(hwnd, WM_SETFONT, (WPARAM)font, MAKELPARAM(TRUE, 0));
  SetPropW(hwnd, moonui_native_font_prop, (HANDLE)(uintptr_t)font);
}

/* 从属性表读回"上一次下发的字号/字重"，-1 = 没设过（回系统默认）。 */
static int moonui_native_stored_permille(HWND hwnd, const WCHAR *prop) {
  HANDLE v = GetPropW(hwnd, prop);
  if (v == 0) {
    return -1;
  }
  return (int)(uintptr_t)v - 1;
}

/* 样式指纹：把 set_style 的五个入参 + 当前 DPI 拌成一个 64 位散列（FNV-1a），
 * 0 留给"还没下发过"（HWND 属性表的 0 就是这一项没有）。DPI 必须进指纹：
 * 字号是按千分比 + 当下 DPI 造 HFONT 的，换屏后同样的入参要按新 DPI 重造，
 * 只比五个入参会把那只字漏掉。碰撞按 2^-64 算——真撞了也只影响那一次重画，
 * 不改后端状态。 */
static int64_t moonui_native_style_fp(int64_t bg, int64_t fg,
                                      int radius_permille, int font_permille,
                                      int weight, int dpi) {
  uint64_t h = 1469598103934665603ULL;
  uint64_t v[6];
  int i;
  v[0] = (uint64_t)bg;
  v[1] = (uint64_t)fg;
  v[2] = (uint64_t)(int64_t)radius_permille;
  v[3] = (uint64_t)(int64_t)font_permille;
  v[4] = (uint64_t)(int64_t)weight;
  v[5] = (uint64_t)(int64_t)dpi;
  for (i = 0; i < 6; i++) {
    h ^= v[i];
    h *= 1099511628211ULL;
  }
  if (h == 0) {
    h = 1;
  }
  return (int64_t)h;
}

/* 测试脚手架：数"因为样式下发而失效的控件数"。同一份样式重复下发本来就该是
 * 0——大于 0 等于整树白重画一次，那正是删一行时用户看到的整片闪一下。 */
static int moonui_style_invalidates = 0;
void moonui_native_style_probe_reset(void) { moonui_style_invalidates = 0; }
int moonui_native_style_probe(void) { return moonui_style_invalidates; }

/* 把样式字段落到一只控件上。kind 决定消费面（见上面那段"三处定点消费"）。 */
int moonui_native_widget_set_style(moonui_ptr c,
                                   int64_t bg_rgb,
                                   int64_t fg_rgb,
                                   int radius_permille,
                                   int font_permille,
                                   int weight) {
  HWND hwnd = moonui_native_hwnd(c);
  int kind = moonui_native_kind_of(c);
  TRACE("widget_set_style");
  if (hwnd == 0) {
    return -1;
  }
  /* 同一份样式重复下发直接跳过（`T286` 之后 Core 每次 relayout 都会对整棵树
   * 重推一遍 apply_styles）：重建画刷 + 逐控件失效等于让几十只控件各重画一次，
   * 删一行触发的重排就是这样把"整片内容"闪一下的。指纹覆盖全部入参，五项全等
   * 时后端状态已经就是这一份，没有一笔要落。
   *
   * 唯一的例外是 Button/MenuRow 的圆角区域：它是窗口区域、跟窗口尺寸走，
   * 重排改了控件大小就得重落一次（否则 resize 后角落还是旧尺寸的圆角）。 */
  {
    int64_t fp = moonui_native_style_fp(bg_rgb, fg_rgb, radius_permille,
                                        font_permille, weight,
                                        moonui_native_dpi_of(hwnd));
    if ((int64_t)(intptr_t)GetPropW(hwnd, moonui_native_style_fp_prop) == fp) {
      if (kind == 1 || kind == 14) {
        moonui_native_button_apply_region(hwnd);
      }
      return 0;
    }
    SetPropW(hwnd, moonui_native_style_fp_prop, (HANDLE)(intptr_t)fp);
  }
  if (kind == 17) {
    /* Panel：底色 + 圆角，自绘（panel_proc）。任何一项变了都要失效一次，
     * 否则新颜色要等下一次别的原因重画才露面。
     *
     * `WS_EX_TRANSPARENT` 跟着底色走（`T117`，判据见 create_control 段注）：
     * 没底色 = 这块矩形不归自己填（透出父窗的底），要这个位去让兄弟先铺；
     * 有底色 = 自己填满，**必须摘掉**——留着它就是把自己排到所有兄弟之后画，
     * 变成盖住标签和按钮的覆盖层。 */
    moonui_native_set_rgb_prop(hwnd, moonui_native_bg_prop, bg_rgb);
    moonui_native_sync_transparent(hwnd, bg_rgb < 0);
    if (radius_permille >= 0) {
      SetPropW(hwnd, moonui_native_radius_prop,
               (HANDLE)(uintptr_t)(radius_permille + 1));
    } else {
      RemovePropW(hwnd, moonui_native_radius_prop);
    }
    /* 自己的底重画时，压在它上面的透明标签要跟着重画（`T140`）。 */
    moonui_style_invalidates += 1;
    moonui_native_invalidate(hwnd, 0);
    return 0;
  }
  if (moonui_native_is_slider(hwnd)) {
    /* 滑块（`T132`）：两格颜色都是自绘轨道要用的（语义见 slider_paint 段注），
     * 底色同时也是"是否自绘"的开关。圆角/字体在轨道条上没有消费面，照旧不读
     * ——§32 的豁免只破上面这几处。
     *
     * 判据是类名 + 记号（`T137`）：原先是 `kind == 6`，可 `moonui.kind` 属性
     * 存的是 kind+1，进程外读到 7、对照表里写 6，两边差一，这条分支等于
     * 永远不进——真把颜色喂进来时会被静默吞掉。 */
    moonui_native_set_rgb_prop(hwnd, moonui_native_fg_prop, fg_rgb);
    moonui_native_set_rgb_prop(hwnd, moonui_native_bg_prop, bg_rgb);
    moonui_style_invalidates += 1;
    moonui_native_invalidate(hwnd, 0);
    return 0;
  }
  if (kind == 0 || kind == 1 || kind == 3 || kind == 14) {
    /* Label / Button / Checkbox / MenuRow：文字色 + 字体。颜色记在 prop 上，
     * 由父窗口过程的 WM_CTLCOLOR* 分支取用（Win32 的文字色不是控件的属性）。
     *
     * Button(1) / MenuRow(14) 还多一层（`T115`①）：给了底色就由子类过程
     * **自己画**那张平面脸（系统主题脸不认底色，见 button_proc 段注），
     * 圆角同理落成窗口区域。Checkbox(3) 不吃这一层——它的勾选框由系统画，
     * 换掉脸就得连勾选态一起重画，那是另一笔账。 */
    HANDLE old_paint;
    moonui_native_set_rgb_prop(hwnd, moonui_native_fg_prop, fg_rgb);
    moonui_native_set_rgb_prop(hwnd, moonui_native_bg_prop, bg_rgb);
    /* 底色画刷跟着颜色走：换色要换刷、撤色要还刷，别让 WM_CTLCOLOR* 拿到
     * 一块上一版的旧色。 */
    old_paint = GetPropW(hwnd, moonui_native_bg_paint_prop);
    if (bg_rgb >= 0) {
      HBRUSH brush = CreateSolidBrush(moonui_native_colorref_of(bg_rgb));
      if (brush != 0) {
        SetPropW(hwnd, moonui_native_bg_paint_prop, (HANDLE)(uintptr_t)brush);
      }
    } else {
      RemovePropW(hwnd, moonui_native_bg_paint_prop);
    }
    if (old_paint != 0) {
      DeleteObject((HGDIOBJ)(uintptr_t)old_paint);
    }
    if (kind == 0) {
      /* Label 没有底色时**不能自己填这块矩形**（`T139`）：文字要站在底下那层
       * 上（脸面的渐变条带、深底可视窗）。可只靠 `WM_CTLCOLORSTATIC` 回
       * `TRANSPARENT` + 空画刷不够——那只让"字后面不刷色"，标签自己那块
       * 矩形仍然谁都不管：父窗带 `WS_CLIPCHILDREN` 跳过子控件，兄弟带
       * `WS_CLIPSIBLINGS` 又被这只标签裁掉，两边都不落笔，那块就是黑的
       * （脸面上 `00:00` / `立体声` / `状态: 就绪` 五块）。
       *
       * 缺的那一位是 `WS_EX_TRANSPARENT`：它把这只窗排到兄弟**之后**画，
       * 于是兄弟先把自己那块铺好（包括标签占的矩形），标签最后只落文字。
       * 与 `T117` 给透明 Panel 加的是同一位、同一条账（判据见
       * `moonui_native_create_control` 段注），只是这里买的不是"洞"而是
       * "文字底下的渐变"。显式给过底色的 Label 照旧走实色铺底，不加。 */
      moonui_native_sync_transparent(hwnd, bg_rgb < 0);
      /* 登记进"透明标签"表（`T140`）：它把字画在底下那层的像素上，所以底重画
       * 时得把它一起拖进更新区（见 `moonui_native_invalidate` 段注）。显式给了
       * 底色的标签自己就是底，系统照常管，不登记。 */
      moonui_native_overlay_keep(hwnd, bg_rgb < 0);
    }
    if (kind == 1 || kind == 14) {
      /* 圆角是窗口区域，不是笔画：每次样式下发都重落一次（撤掉底色 /
       * 撤掉圆角都要把区域摘干净，否则钮身上留着一个剪不掉的旧角）。 */
      if (radius_permille >= 0) {
        SetPropW(hwnd, moonui_native_radius_prop,
                 (HANDLE)(uintptr_t)(radius_permille + 1));
      } else {
        RemovePropW(hwnd, moonui_native_radius_prop);
      }
      moonui_native_button_apply_region(hwnd);
    }
    if (font_permille >= 0 || weight >= 0) {
      /* 两条字段是独立通道：这次只给了字重、上次给过字号时，新字体得是
       * "上次的字号 + 这次的字重"，不能把字号退回系统默认。所以先读回
       * 上一份，再用本次的非 -1 值覆盖。 */
      int pt = font_permille >= 0
                   ? font_permille
                   : moonui_native_stored_permille(hwnd,
                                                   moonui_native_fontpt_prop);
      int wt = weight >= 0
                   ? weight
                   : moonui_native_stored_permille(hwnd,
                                                   moonui_native_weight_prop);
      HFONT font = moonui_native_font_of(hwnd, pt, wt);
      if (font != 0) {
        HFONT old = (HFONT)(uintptr_t)GetPropW(hwnd, moonui_native_font_prop);
        SendMessageW(hwnd, WM_SETFONT, (WPARAM)font, MAKELPARAM(TRUE, 0));
        SetPropW(hwnd, moonui_native_font_prop, (HANDLE)(uintptr_t)font);
        if (font_permille >= 0) {
          SetPropW(hwnd, moonui_native_fontpt_prop,
                   (HANDLE)(uintptr_t)(font_permille + 1));
        }
        if (weight >= 0) {
          SetPropW(hwnd, moonui_native_weight_prop,
                   (HANDLE)(uintptr_t)(weight + 1));
        }
        if (old != 0) {
          DeleteObject(old); /* 上一份是我们造的，换掉就还 */
        }
      }
    }
    /* 重推样式用 erase=FALSE（`T126` 同款）：带 erase 的失效会让系统在
     * WM_PAINT 之前先用控件类背景刷把整块刷白，重画慢一帧就是用户看到的
     * "删除时内容闪一下"——删一行触发整树 relayout，几十只 Label/Button/
     * Checkbox 同时被擦白，输入框(kind 2)走 §32 豁免不失效，于是只有它和
     * "添加"按钮不闪（owner 2026-11-17 截图）。content 本身是透明标签 /
     * 自绘脸，会自己把字和脸画回来，不需要系统先垫一层白底；T140 的透明
     * 标签跟随靠的是 `overlay_keep` + 下面的失效传播，与 erase 位无关。 */
    moonui_style_invalidates += 1;
    moonui_native_invalidate(hwnd, 0);
    return 0;
  }
  /* 其余 kind：系统原生外观照旧（§32 的豁免只破上面这几处）。 */
  return 0;
}

/* 图标（adapter.h 皮肤通道，`T131`）：名字存进 `moonui.style.icon` 这只
 * prop（堆上的 NUL 结尾串，下一份 / 销毁时 free），绘制由
 * `moonui_native_draw_icon` 按名字取。`name` 为 NULL 或空串 = 摘掉图标，
 * 回文本外观（mac 半 `set_icon` 收 nil 同一条）。
 *
 * 名字**不校验**归这里：认不认得是画的那一步的事（画不成照旧回退文字），
 * 与 mac 半"取不到 SF Symbol 就保标题"同一条。因此这里只有内存失败一个
 * 错误出口。 */
int moonui_native_widget_set_icon(moonui_ptr c, const char *name, int name_len) {
  HWND hwnd = moonui_native_hwnd(c);
  char *old;
  char *copy = 0;
  if (hwnd == 0) {
    return -1;
  }
  old = (char *)(uintptr_t)GetPropW(hwnd, moonui_native_icon_prop);
  if (name != 0 && name_len > 0) {
    copy = (char *)malloc((size_t)name_len + 1u);
    if (copy == 0) {
      return -1;
    }
    memcpy(copy, name, (size_t)name_len);
    copy[name_len] = '\0';
  }
  if (copy != 0) {
    SetPropW(hwnd, moonui_native_icon_prop, (HANDLE)(uintptr_t)copy);
  } else {
    RemovePropW(hwnd, moonui_native_icon_prop);
  }
  if (old != 0) {
    free(old);
  }
  /* 图标换掉 = 这一笔要重画（标题让位给图，或反过来）。`erase=FALSE` 与
   * 皮肤样式那批同一条理由（`T126`）：擦底会带出一块与主题不合的灰。 */
  moonui_native_invalidate(hwnd, 0);
  return 0;
}

int moonui_native_widget_set_font_family(moonui_ptr c,
                                         const char *name,
                                         int name_len) {
  HWND hwnd = moonui_native_hwnd(c);
  char *old;
  char *copy = 0;
  int changed = 1;
  if (hwnd == 0) {
    return -1;
  }
  old = (char *)(uintptr_t)GetPropW(hwnd, moonui_native_family_prop);
  if (name != 0 && name_len > 0) {
    copy = (char *)malloc((size_t)name_len + 1u);
    if (copy == 0) {
      return -1;
    }
    memcpy(copy, name, (size_t)name_len);
    copy[name_len] = '\0';
  }
  /* 同一字族反复下发（每次 relayout 都走一遍 apply_styles）不重造：造字 +
   * WM_SETFONT 会让 STATIC 控件整块失效重画，删一行时整棵树重推，若每只控件
   * 都跟着闪一次就成了整窗闪。Changed detector 把这件事限制在字族真的变了
   * 的那一次（owner 2026-11-17 的"删除时内容闪一下"）。 */
  if (old != 0 && copy != 0 && strcmp(old, copy) == 0) {
    changed = 0;
  } else if (old == 0 && copy == 0) {
    changed = 0;
  }
  if (copy != 0) {
    SetPropW(hwnd, moonui_native_family_prop, (HANDLE)(uintptr_t)copy);
  } else {
    RemovePropW(hwnd, moonui_native_family_prop);
  }
  if (old != 0) {
    free(old);
  }
  if (!changed) {
    return 0;
  }
  /* 字族换了**或撤了**都要按当下 prop 重造一只 HFONT（`T314`）。
   *
   * 换族那条的旧账：只钉字族不钉字号（fontpt = -1）时，旧代码拿 pt<0 当
   * "没设过字号就不动"，结果是 prop 记着新族、HFONT 却是系统消息字体——
   * 量宽度按系统字体（缺中文字形），STATIC 画中文时系统另做字体链接换成
   * 中文字体，两把尺，末尾的"成"这类汉字就被裁掉（owner 2026-11-17 的
   * "已完成的成字显示不全"）。pt<0 不是"别造字"，而是"用系统默认字号造
   * 字"：`font_of` 在 pt<0 时保留 lfMessageFont 的尺寸、只填 face 名，正是
   * "只换族不换号"的语义。所以这里不要求 pt>=0。Core 在样式下发后统一
   * relayout，新字体量出来的固有尺寸那一轮就跟上。
   *
   * 撤族那条（copy==0，`set_font_family(None)`）也得重造：family prop 刚被
   * 摘掉，`font_of` 会落到消息字体那一族——不重造的话控件还挂着旧族的
   * HFONT，"能切过去、切不回来"，只有新建的控件才是系统字。 */
  if (moonui_native_kind_has_text(moonui_native_kind_of_hwnd(hwnd))) {
    int pt = moonui_native_stored_permille(hwnd, moonui_native_fontpt_prop);
    int wt = moonui_native_stored_permille(hwnd, moonui_native_weight_prop);
    HFONT font = moonui_native_font_of(hwnd, pt, wt);
    if (font != 0) {
      HFONT prev = (HFONT)(uintptr_t)GetPropW(hwnd, moonui_native_font_prop);
      SendMessageW(hwnd, WM_SETFONT, (WPARAM)font, TRUE);
      SetPropW(hwnd, moonui_native_font_prop, (HANDLE)(uintptr_t)font);
      if (prev != 0 && prev != font) {
        DeleteObject(prev);
      }
    }
  }
  moonui_native_invalidate(hwnd, 0);
  return 0;
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
  if (!moonui_native_is_slider(hwnd)) {
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

/* 一段窗口文本的度量（多行按行拆开：宽取最大行、高累加，libui 的 text.cpp
 * 同款；这里控件文本都是单行，多行的那条路留给 Label 里带 \n 的极端用法）。
 * 字体用控件自己挂的那只（WM_GETFONT）——皮肤通道换过字号之后，量出来的宽
 * 必须跟着画出来的字走，见 moonui_native_text_extent_font 的段注。
 * 返回最大行宽；`out_h` 非空时写回总高。 */
static int moonui_native_window_text_metrics(HWND hwnd, int *out_h) {
  int n;
  WCHAR *buf;
  int i;
  int line_start;
  int max_w = 0;
  int total_h = 0;
  HFONT font;
  if (out_h != 0) {
    *out_h = 0;
  }
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
  font = moonui_native_control_font(hwnd);
  line_start = 0;
  for (i = 0; i <= n; ++i) {
    if (i == n || buf[i] == L'\n') {
      int w;
      int h;
      WCHAR saved = buf[i];
      buf[i] = L'\0';
      moonui_native_text_extent_font(font, buf + line_start, &w, &h);
      buf[i] = saved;
      if (max_w < w) {
        max_w = w;
      }
      total_h += h;
      line_start = i + 1;
    }
  }
  if (out_h != 0) {
    *out_h = total_h;
  }
  free(buf);
  return max_w;
}

/* 只要宽的老调用面。 */
static int moonui_native_window_text_width(HWND hwnd) {
  return moonui_native_window_text_metrics(hwnd, 0);
}

int64_t moonui_native_widget_minimum_size(moonui_ptr c) {
  HWND hwnd = moonui_native_hwnd(c);
  int kind = moonui_native_kind_of(c);
  int w = 0;
  int h = 0;
  SIZE size;
  TRACE("widget_minimum_size");
  switch (kind) {
    case 0: { /* Label：文字宽 × 8 DLU 高（libui 的 label.cpp）。皮肤通道把字号
               * 推大之后固定 8 DLU 会小于行高，取两者大的那个——固有高不跟着
               * 长的话，§14 排出来的框会把字裁掉（宽已经跟着 WM_GETFONT 量了，
               * 高不跟就是同一把尺量两样东西）。
               *
               * 宽再垫 6px（`T131`）：`GetTextExtentPoint32` 给的是**步进之和**，
               * 系统 Static 居中绘制时用的是整串外接框，CJK 的字面两侧会探出
               * 步进之外；按步进排出来的框，`状态: 就绪` / `/ 00:00` 这类标签
               * 的两端各被裁掉两三个像素（owner 截图里的"文字过大，看不全"，
               * 字号改对之后剩下的就是这一档）。垫一点不改语义，只把框放宽到
               * 字面真的装得下。 */
      int text_h = 0;
      w = moonui_native_window_text_metrics(hwnd, &text_h);
      if (w > 0) {
        w += 6;
      }
      h = moonui_native_dlu_y(hwnd, 8);
      if (text_h > h) {
        h = text_h;
      }
      break;
    }
    case 1:
    case 14: /* Button / MenuRow：BCM_GETIDEALSIZE，拿不到退文字宽 + 2×SM_CXEDGE，
              * 高 14 DLU（libui 的 button.cpp）。平面钮（`T115`①）多一道下限：
              * 脸是我们自己画的，文字左右各让 6px，主题算出来的理想宽可能比
              * "文字 + 那两截内缩"窄，照它排会被 DT_END_ELLIPSIS 切掉尾巴。 */
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
      if (moonui_native_rgb_prop(hwnd, moonui_native_bg_prop) >= 0) {
        int text_h = 0;
        int text_w = moonui_native_window_text_metrics(hwnd, &text_h);
        if (w < text_w + 12) {
          w = text_w + 12;
        }
        if (h < text_h + 8) {
          h = text_h + 8;
        }
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
/* 搬家后的公共尾巴：发 ID、spinbox 的 updown 跟搬、z-order 插到末尾。
 * control_attach 与 container_attach 的 kind 17 分支共用——两条路最后都是
 * "落进某只顶层窗口的客户区"，收拾动作一模一样。 */
static void moonui_native_attach_tail(HWND parent, HWND hwnd) {
  HWND updown;
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
  /* SetParent 搬进新父窗后，控件不会自动在新位置重画——它以为自己已经画过
   * （在 park 里那次）。搬完失效一次，让它在下一个 WM_PAINT 重画。
   *
   * `erase=FALSE`（`T126`）：这里原来传 TRUE，等于让系统先拿**控件自己的**
   * 类背景刷把这块地刷一遍——Button/STATIC/Edit 的默认刷是近白的，于是整树
   * 重建时每只控件先白一下、再画皮肤色，叠起来就是整窗闪白。控件在
   * `WM_PAINT` 里本来就整块自绘（标准控件画脸、`T114`/`T115` 那批画皮肤底），
   * 先擦一遍只是多一层白。 */
  moonui_native_invalidate(hwnd, 0);
}

void moonui_native_control_attach(moonui_ptr window, moonui_ptr child) {
  HWND parent = moonui_native_hwnd(window);
  HWND hwnd = moonui_native_hwnd(child);
  TRACE("control_attach");
  /* 逻辑父先记：即使下面提前返回（已经挂在同一只窗下），holder 也是对的。 */
  SetPropW(hwnd, moonui_native_holder_prop, (HANDLE)(uintptr_t)parent);
  if (GetParent(hwnd) == parent) {
    return;
  }
  if (SetParent(hwnd, parent) == 0) {
    return;
  }
  moonui_native_attach_tail(parent, hwnd);
}

void moonui_native_container_attach(moonui_ptr container, moonui_ptr child) {
  HWND hwnd;
  HWND parent;
  int kind = moonui_native_kind_of(container);
  TRACE("container_attach");
  hwnd = moonui_native_hwnd(child);
  if (kind == 15) {
    /* 剪裁视口：子控件搬进视口本体。子窗口坐标本来就是父客户区坐标，Core
     * 侧已按视口平移过的矩形直接生效；WS_CLIPCHILDREN 负责裁掉视口外的
     * 部分。视口收子不走 attach_tail——剪裁容器里不发 ID、不排 Tab（滚动
     * 区里的控件不参与窗口的 Tab 序），一直如此。 */
    SetPropW(hwnd, moonui_native_holder_prop,
             (HANDLE)(uintptr_t)moonui_native_hwnd(container));
    if (GetParent(hwnd) == moonui_native_hwnd(container)) {
      return;
    }
    SetParent(hwnd, moonui_native_hwnd(container));
    /* 视口不收 `attach_tail`，但"搬完家要失效一次"这一半不能省（`T121`）：
     * 视口已经显示时（开机重建树、换曲库），搬进去的控件不会自己重画。
     * `erase=FALSE` 同 `attach_tail`（`T126`）：整树重建时别让系统先拿控件
     * 自己的近白类刷把视口里的每一行刷白再画。 */
    moonui_native_invalidate(hwnd, 0);
    return;
  }
  if (kind == 17) {
    /* Panel（皮肤账的载体）：mac 半是"子视图真挂进面板 view"，Windows 半
     * 没有对应物——Core 的 set_bounds 只对 Scroll 平移，Panel 子树推的仍是
     * **窗口绝对坐标**，搬进 Panel 的 STATIC 里会把这批坐标错读成 Panel 客
     * 户区坐标。所以这里把子控件平铺挂到 Panel 的父窗口（先序保证 Panel
     * 已先一步挂好），坐标即用；Panel 自己只是同层一块透明底板（kind 17
     * 不画背景，Windows 的样式消费欠着整批皮肤账）。 */
    parent = GetParent(moonui_native_hwnd(container));
    if (parent == 0) {
      return;
    }
    /* 逻辑父是 Panel 本身（不是它被平铺挂到的那只父窗）：垫 AA 底色要问
     * "Panel 底下画的是什么"，只有沿布局树才问得到（`T135`）。 */
    SetPropW(hwnd, moonui_native_holder_prop,
             (HANDLE)(uintptr_t)moonui_native_hwnd(container));
    if (GetParent(hwnd) == parent) {
      return;
    }
    if (SetParent(hwnd, parent) == 0) {
      return;
    }
    moonui_native_attach_tail(parent, hwnd);
    return;
  }
  /* 其余句柄进来不动，不猜。 */
}

void moonui_native_scroll_set_content(moonui_ptr scroll,
                               int axis,
                               int width,
                               int height) {
  HWND hwnd;
  RECT cr;
  LONG_PTR style;
  LONG_PTR want;
  int view;
  int content;
  int max_off;
  int off_x;
  int off_y;
  int cur;
  SCROLLINFO si;
  TRACE("scroll_set_content");
  hwnd = moonui_native_hwnd(scroll);
  if (hwnd == 0 || moonui_native_kind_of_hwnd(hwnd) != 15 ||
      GetClientRect(hwnd, &cr) == 0) {
    return;
  }
  if (width < 0) {
    width = 0;
  }
  if (height < 0) {
    height = 0;
  }
  /* 取判断用的视口尺寸：纵向滚动条只吃宽度、不碰高度，横向反之——
   * 所以用"与滚动方向垂直"的那一边判断溢出，加条后这一边不变，不会抖。 */
  style = GetWindowLongPtrW(hwnd, GWL_STYLE);
  want = style & ~(WS_VSCROLL | WS_HSCROLL);
  if (axis == 0) {
    /* 纵向：内容高 > 视口高才给条（与 mac 半"装得下就不画、不预留轨道"同款）。 */
    view = (int)(cr.bottom - cr.top);
    content = height;
    if (content > view) {
      want |= WS_VSCROLL;
    }
  } else if (axis == 1) {
    view = (int)(cr.right - cr.left);
    content = width;
    if (content > view) {
      want |= WS_HSCROLL;
    }
  } else {
    return;
  }
  /* style 变了要让系统重算非客户区（滚动条占的那格），SWP_FRAMECHANGED。 */
  if (want != style) {
    SetWindowLongPtrW(hwnd, GWL_STYLE, want);
    SetWindowPos(hwnd, 0, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOACTIVATE);
  }
  /* 行程 + 页 + 当前位置：Core 给的内容尺寸就是文档全长，视口客户区即页。
   * nMax 取 max(content-view, 0)，thumb 到最底刚好把内容末端推到视口底。 */
  if (GetClientRect(hwnd, &cr) == 0) {
    return;
  }
  si.cbSize = (UINT)sizeof(si);
  si.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
  si.nMin = 0;
  moonui_native_scroll_offset(scroll, &off_x, &off_y);
  if (axis == 0) {
    view = (int)(cr.bottom - cr.top);
    content = height;
    max_off = content - view;
    if (max_off < 0) {
      max_off = 0;
    }
    /* `nMax` 是**内容末位**（content-1），不是最大偏移——Win32 的判据是
     * `nMax - nMin + 1 <= nPage` 就藏条。写成 `content - view` 时这条变成
     * `content - view + 1 <= view`，要**超出将近两屏**滚动条才现身；而滚轮
     * 走的是同一份 SCROLLINFO，于是出现"能滚但没条"（owner 2026-11-17 截图
     * ①：13 条无条、15 条才有）。最大偏移仍由 `max_off` 管（见下 clamp）。 */
    si.nMax = content > 0 ? content - 1 : 0;
    si.nPage = (UINT)(view > 0 ? view : 1);
    cur = off_y;
    if (cur > max_off) {
      cur = max_off;
    }
    if (cur < 0) {
      cur = 0;
    }
    si.nPos = cur;
    if (cur != off_y) {
      /* 内容缩水把旧偏移挤出范围：把子控件搬回来补偿，别留半屏空白。 */
      moonui_native_scroll_shift_children(scroll, 0, off_y - cur);
      moonui_native_scroll_set_offset(scroll, off_x, cur);
      moonui_native_scroll_erase(hwnd); /* 补偿平移也要擦旧位置，同上 */
    }
  } else {
    view = (int)(cr.right - cr.left);
    content = width;
    max_off = content - view;
    if (max_off < 0) {
      max_off = 0;
    }
    si.nMax = content > 0 ? content - 1 : 0; /* 同上：末位，不是最大偏移 */
    si.nPage = (UINT)(view > 0 ? view : 1);
    cur = off_x;
    if (cur > max_off) {
      cur = max_off;
    }
    if (cur < 0) {
      cur = 0;
    }
    si.nPos = cur;
    if (cur != off_x) {
      moonui_native_scroll_shift_children(scroll, off_x - cur, 0);
      moonui_native_scroll_set_offset(scroll, cur, off_y);
      moonui_native_scroll_erase(hwnd); /* 补偿平移也要擦旧位置，同上 */
    }
  }
  SetScrollInfo(hwnd, axis == 0 ? SB_VERT : SB_HORZ, &si, TRUE);
}

int32_t moonui_native_scroll_has_vertical_scroller(moonui_ptr scroll) {
  HWND hwnd = moonui_native_hwnd(scroll);
  if (hwnd == 0 || moonui_native_kind_of_hwnd(hwnd) != 15) {
    return 0;
  }
  return (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_VSCROLL) != 0 ? 1 : 0;
}

/* 测试脚手架：读回某只窗口里 kind 15 视口的当前滚动偏移，pack2(y, x)
 * （低 32 = x、高 32 = y）。Windows 半专属，给真滚动判据对账"offset 真的
 * 归零了"而不只看子控件位置。
 *
 * 为什么按标题找而不是收句柄：测试侧的 `NativeHandle` 是 `{id, generation}`
 * 结构体，不是裸 HWND，直接当 `moonui_ptr` 传进 C 会读到一只不存在的窗口——
 * 探针会恒返回 0，判据就成了假绿（2026-11-17 当场撞到）。 */
static HWND moonui_native_find_window(const char *title, int title_len);

int64_t moonui_native_scroll_offset_of(const char *title, int title_len) {
  HWND win;
  HWND view = 0;
  HWND child;
  int x = 0;
  int y = 0;
  TRACE("scroll_offset_of");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -1;
  }
  for (child = GetWindow(win, GW_CHILD); child != 0;
       child = GetWindow(child, GW_HWNDNEXT)) {
    if (moonui_native_kind_of_hwnd(child) == 15) {
      view = child;
      break;
    }
  }
  if (view == 0) {
    return -1;
  }
  moonui_native_scroll_offset((moonui_ptr)(uintptr_t)view, &x, &y);
  return moonui_native_pack2(y, x);
}

static HWND moonui_native_find_window(const char *title, int title_len);

/* 测试脚手架：读滚动视口内某个客户区坐标**在屏幕上**呈现的像素。
 * 与 panel/button 那族走 WM_PRINTCLIENT 离屏重画不同，这里读屏幕 DC——
 * 残影是用户实际看到的那一点，离屏重画只会让视口重画、把残影擦掉，测不到。
 * 按窗口标题找顶层窗、再找它的 kind 15 直属视口（测试里的 NativeHandle
 * 是 id+generation，不是裸指针，不能在 C 侧直接当 HWND 用）。
 *   - 返回 0xRRGGBB（打包顺序与 set_style 收的那套一致，不翻转）。
 *   - 高 8 位（>> 56）是状态码：0 = 读到，1 = 没有这只窗口，
 *     2 = 窗口里没有 kind 15 视口，3 = 取 DC / 像素失败。 */
int64_t moonui_native_scroll_surface_pixel(const char *title, int title_len,
                                            int x, int y) {
  HWND win;
  HWND view = 0;
  HWND child;
  HDC dc;
  COLORREF c;
  TRACE("scroll_surface_pixel");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return (int64_t)1 << 56;
  }
  for (child = GetWindow(win, GW_CHILD); child != 0;
       child = GetWindow(child, GW_HWNDNEXT)) {
    if (moonui_native_kind_of_hwnd(child) == 15) {
      view = child;
      break;
    }
  }
  if (view == 0) {
    return (int64_t)2 << 56;
  }
  /* 视口带 WS_EX_TRANSPARENT、自己不画，GetDC(view) 读它自己的表面没有意义
   * （取不到有效像素）。残影是**用户看到的**那一点，所以读屏幕 DC：先把
   * 视口客户区坐标换成屏幕坐标，再从整个屏幕表面取色。 */
  {
    POINT p;
    p.x = x;
    p.y = y;
    if (ClientToScreen(view, &p) == 0) {
      return (int64_t)3 << 56;
    }
    x = p.x;
    y = p.y;
  }
  dc = GetDC(0);
  if (dc == 0) {
    return (int64_t)3 << 56;
  }
  c = GetPixel(dc, x, y);
  ReleaseDC(0, dc);
  if (c == CLR_INVALID) {
    return (int64_t)3 << 56;
  }
  return (int64_t)(c & 0xFF) << 16 | (int64_t)(c & 0xFF00) |
         (int64_t)((c >> 16) & 0xFF);
}

/* 测试脚手架：读滚动视口**客户区右缘外围**的屏幕像素。
 * dx 相对客户区右边：0 = 正文与滚动条交界那一列，+1 往滚动条里，-1 往正文里。
 * 用来钉"滚动条左边那条白线"——它是主题画滚动条时留下的、不是视口也不是
 * 任何子控件画的，只有读屏幕像素看得见。
 *   - 高 8 位状态码：0 = 读到，1 = 没有这只窗口，2 = 没有 kind 15 视口，
 *     3 = 取 DC / 像素失败。 */
int64_t moonui_native_scroll_edge_pixel(const char *title, int title_len, int dx,
                                        int y) {
  HWND win;
  HWND view = 0;
  HWND child;
  RECT cr;
  POINT p;
  HDC dc;
  COLORREF c;
  TRACE("scroll_edge_pixel");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return (int64_t)1 << 56;
  }
  for (child = GetWindow(win, GW_CHILD); child != 0;
       child = GetWindow(child, GW_HWNDNEXT)) {
    if (moonui_native_kind_of_hwnd(child) == 15) {
      view = child;
      break;
    }
  }
  if (view == 0) {
    return (int64_t)2 << 56;
  }
  if (GetClientRect(view, &cr) == 0) {
    return (int64_t)3 << 56;
  }
  p.x = cr.right + dx;
  p.y = y;
  if (ClientToScreen(view, &p) == 0) {
    return (int64_t)3 << 56;
  }
  dc = GetDC(0);
  if (dc == 0) {
    return (int64_t)3 << 56;
  }
  c = GetPixel(dc, p.x, p.y);
  ReleaseDC(0, dc);
  if (c == CLR_INVALID) {
    return (int64_t)3 << 56;
  }
  return (int64_t)(c & 0xFF) << 16 | (int64_t)(c & 0xFF00) |
         (int64_t)((c >> 16) & 0xFF);
}

/* 测试脚手架（`T319` 判据的辅助一条）：滚动之后**还有多少待画区留着**。
 *
 * 数的是视口本身（空出来的那条底色）与视口内每只可见直属子窗的更新区。0 = 那
 * 一帧的账已经平了；大于 0 说明还有几笔欠着，那几块屏幕上是空的，要等下一轮
 * 消息泵才补。
 *
 * **它分不出"画完了"和"根本没让画"**：没人标脏就没有欠账，读数也是 0。所以
 * `T319` 的主判据读的是 `paint_probe` 的"谁真收到过 WM_PAINT"，这条只负责
 * 补一句"落完笔之后别留欠账"。负控制里正是这个差别：把收笔短路之后这条仍读
 * 0，主判据却从 16 掉到 6。
 *
 * 为什么量更新区而不是屏幕像素：屏幕那条路要窗口真压在桌面最上层（本机开着
 * 一堆窗，读回来常是别人的像素）。
 *
 * 状态码走负数，正数才是计数：-2 = 没有这只窗口，-3 = 窗口里没有 kind 15 视口，
 * -4 = 取不到客户区。 */
int64_t moonui_native_scroll_blank_probe(const char *title, int title_len) {
  HWND win;
  HWND view = 0;
  HWND child;
  RECT cr;
  RECT r;
  TRACE("scroll_blank_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  for (child = GetWindow(win, GW_CHILD); child != 0;
       child = GetWindow(child, GW_HWNDNEXT)) {
    if (moonui_native_kind_of_hwnd(child) == 15) {
      view = child;
      break;
    }
  }
  if (view == 0) {
    return -3;
  }
  if (GetClientRect(view, &cr) == 0) {
    return -4;
  }
  {
    int64_t pending = GetUpdateRect(view, &r, FALSE) != 0 ? 1 : 0;
    for (child = GetWindow(view, GW_CHILD); child != 0;
         child = GetWindow(child, GW_HWNDNEXT)) {
      POINT p;
      int cw;
      int ch;
      if (IsWindowVisible(child) == 0) {
        continue;
      }
      if (GetWindowRect(child, &r) == 0) {
        continue;
      }
      cw = r.right - r.left;
      ch = r.bottom - r.top;
      p.x = r.left;
      p.y = r.top;
      if (ScreenToClient(view, &p) == 0) {
        continue;
      }
      /* 只算视口里看得见的：视口外的行本来就不该出现在屏幕上。 */
      if (p.x >= cr.right || p.y >= cr.bottom || p.x + cw <= cr.left ||
          p.y + ch <= cr.top) {
        continue;
      }
      if (GetUpdateRect(child, &r, FALSE) != 0) {
        pending += 1;
      }
    }
    return pending;
  }
}

void moonui_native_control_set_bounds(moonui_ptr child,
                                      int x,
                                      int y,
                                      int width,
                                      int height) {
  HWND hwnd = moonui_native_hwnd(child);
  HWND parent;
  TRACE("control_set_bounds");
  /* 真滚动：Core 给的 x/y 是**文档坐标**（视口不存偏移），但子控件挂在
   * 视口客户区里。落位时减掉视口当前偏移，屏幕位置才对得上"滚到哪儿"。
   * 重排 / 换内容时 Core 重发文档坐标，这一减让滚动位置自然保住，不用
   * Core 参与。只认直属父是 kind 15 视口的控件——窗口子树不滚。 */
  parent = GetParent(hwnd);
  if (parent != 0 && moonui_native_kind_of_hwnd(parent) == 15) {
    int ox = 0;
    int oy = 0;
    moonui_native_scroll_offset((moonui_ptr)(uintptr_t)parent, &ox, &oy);
    x -= ox;
    y -= oy;
  }
  /* z-order 原样保留：否则每次 resize 都会把控件重新排一遍，
   * Tab 顺序跟着布局抖动。 */
  TRACE_AT("bounds", hwnd);
  SetWindowPos(hwnd, 0, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOZORDER);
  /* spinbox 的 updown 不在布局树里，edit 挪到哪儿它跟到哪儿。 */
  moonui_native_spinbox_place_updown(hwnd);
}

void moonui_native_control_detach(moonui_ptr child) {
  HWND hwnd = moonui_native_hwnd(child);
  HWND updown;
  TRACE("control_detach");
  if (moonui_native_park == 0) {
    return;
  }
  updown = moonui_native_updown_of(hwnd);
  RemovePropW(hwnd, moonui_native_holder_prop);
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

/* ---- 异步替按的进度记录（`T304` / `T306`）----
 *
 * 三处替按——右键菜单（`T91①`）、自动关对话框、文件面板替按——是同一个形状：
 * 武装那一下只把参数记下来并返回 0，真正干活的是一条另起的线程，它自己找窗、
 * 量位置、投消息。此前这条线程的失败分支全是静默 `return`：找不到窗、拿到窗
 * 却拿不到菜单/按钮、点了没生效，外部表现一模一样，都只是「动作没发生」，连
 * 同一个 commit 的两次 attempt 都能一红一绿（`T304` 记的就是这个，只能靠复跑
 * 分辨）。`T305` 在菜单那处先把这套位补上，`T306` 把同一条记录推广到另外两处。
 *
 * 一只共享记录：`kind` 说明最近一次武装的是哪一处，`bits` 是它走到哪一步。
 * 本包的测试串行，武装时清零覆盖上一次。**位值不要随手改**——`native_test.mbt`
 * 有硬编码的数（负控制读回 65 = ARMED|DONE、点到了读回 16|64），改位序要同步改
 * 那边以及 `TODO.md` 里 `T304`/`T305` 的记录。
 *
 * 位语义在三种替按上的对应：
 *   TARGET  菜单窗 / 对话框 / 面板窗找到了
 *   PAYLOAD 拿到可操作的对象：菜单句柄 / 面板已导航到目标路径
 *   LOCATED 量到了要点的位置（只有菜单需要量矩形）
 *   ACTED   已投出那一击（点击 / BM_CLICK / 取消用的 WM_CLOSE）
 *   FALLBACK 主路径没成、靠兜底收的场——**这条最有价值**：判据本来是绿的，
 *           兜底把它救绿了，主路径坏了也看不出来。
 */
#define MOONUI_ARM_NONE 0
#define MOONUI_ARM_MENU 1   /* 右键菜单替按 */
#define MOONUI_ARM_DIALOG 2 /* 自动关对话框 */
#define MOONUI_ARM_FILE 3   /* 文件面板替按 */

#define MOONUI_ARM_ARMED 0x001    /* 线程已起来 / 装的那发已被认领 */
#define MOONUI_ARM_TARGET 0x002   /* 找到了目标窗 */
#define MOONUI_ARM_PAYLOAD 0x004  /* 拿到可操作的对象 */
#define MOONUI_ARM_LOCATED 0x008  /* 量到了要点的位置 */
#define MOONUI_ARM_ACTED 0x010    /* 已投出那一击 */
#define MOONUI_ARM_STOPPED 0x020  /* 被负控制叫停 */
#define MOONUI_ARM_DONE 0x040     /* 收工，无论成没成 */
#define MOONUI_ARM_SETUP 0x080    /* 武装阶段就失败（malloc / CreateThread） */
#define MOONUI_ARM_FALLBACK 0x100 /* 靠兜底收的场 */

static volatile LONG moonui_native_arm_kind = MOONUI_ARM_NONE;
static volatile LONG moonui_native_arm_bits = 0;

/* 武装：先清位再记 kind。顺序不能反——读回口可能正在读，先写 kind 会让「新
 * kind + 旧位」这种自相矛盾的组合露出去。 */
static void moonui_native_arm_begin(int kind) {
  InterlockedExchange(&moonui_native_arm_bits, MOONUI_ARM_ARMED);
  InterlockedExchange(&moonui_native_arm_kind, kind);
}

static void moonui_native_arm_mark(int bits) {
  InterlockedOr(&moonui_native_arm_bits, bits);
}

static int moonui_native_arm_read(void) {
  return (int)InterlockedCompareExchange(&moonui_native_arm_bits, 0, 0);
}

/* 读回口（`T306`）：kind 与位分开给，判据那边不用解位运算。 */
int moonui_native_arm_kind_state(void) {
  return (int)InterlockedCompareExchange(&moonui_native_arm_kind, 0, 0);
}

int moonui_native_arm_bits_state(void) {
  return moonui_native_arm_read();
}

/* 位掩码查询：判据拿它替代 MoonBit 侧的位运算，语义只在这里维护一份。 */
int moonui_native_arm_has(int mask) {
  return (moonui_native_arm_read() & mask) == mask;
}

/* 等这一轮收尾（DONE 位起来）或超时，返回最终位。武装与判据之间有时序：
 * 动作是替按线程做的、断言是主线程跑的，谁先到不保证。 */
int moonui_native_arm_wait(int wait_ms) {
  int waited = 0;
  while (waited < wait_ms) {
    if ((moonui_native_arm_read() & MOONUI_ARM_DONE) != 0) {
      break;
    }
    Sleep(10);
    waited += 10;
  }
  return moonui_native_arm_read();
}

/* 进度位的可读形态，给判据在红了之后把原因打进日志：`kind=file
 * armed|target|acted|done`。C 侧拼好、MoonBit 只负责打印，省得两边各写一份
 * 位名表（写歪了反而误导）。 */
moonbit_bytes_t moonui_native_arm_text(void) {
  static const char *kinds[] = {"none", "menu", "dialog", "file"};
  static const int bits[] = {MOONUI_ARM_ARMED,    MOONUI_ARM_TARGET,
                             MOONUI_ARM_PAYLOAD,  MOONUI_ARM_LOCATED,
                             MOONUI_ARM_ACTED,    MOONUI_ARM_STOPPED,
                             MOONUI_ARM_DONE,     MOONUI_ARM_SETUP,
                             MOONUI_ARM_FALLBACK};
  static const char *names[] = {"armed", "target", "payload", "located", "acted",
                                "stopped", "done", "setup", "fallback"};
  char buf[256];
  int k = (int)InterlockedCompareExchange(&moonui_native_arm_kind, 0, 0);
  int v = moonui_native_arm_read();
  int n = 0;
  size_t i;
  int first = 1;
  if (k < 0 || k > 3) {
    k = 0;
  }
  n += snprintf(buf + n, sizeof(buf) - (size_t)n, "kind=%s bits=", kinds[k]);
  if (v == 0) {
    n += snprintf(buf + n, sizeof(buf) - (size_t)n, "none");
  }
  for (i = 0; i < sizeof(bits) / sizeof(bits[0]); i++) {
    if ((v & bits[i]) != 0) {
      n += snprintf(buf + n, sizeof(buf) - (size_t)n, "%s%s", first ? "" : "|",
                    names[i]);
      first = 0;
    }
  }
  return moonui_native_bytes_of(buf);
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

/* 对话框里唯一那只按钮（`T306`）。有些版本的 Windows 把单按钮对话框的按钮
 * 建成别的控件 ID——本机 Win11 的 `MB_OK` 消息框就是 ID 2（`IDCANCEL`），
 * 于是按 `IDOK` 的 `SendDlgItemMessageW` 一直打在空气上，只能靠 `WM_CLOSE`
 * 兜底把窗关掉：判据是绿的，主路径其实从没生效过。
 * 只在「确实只有一只按钮」时返回它（多按钮时按错比按不动更糟），调用方拿
 * 不到就退到兜底关窗。 */
static BOOL CALLBACK moonui_native_button_scan_enum(HWND h, LPARAM lp) {
  HWND *only = (HWND *)(uintptr_t)lp;
  WCHAR cls[32];
  if (GetClassNameW(h, cls, 32) == 0) {
    return TRUE;
  }
  if (lstrcmpiW(cls, L"Button") != 0) {
    return TRUE;
  }
  if (*only == 0) {
    *only = h;
  } else {
    *only = (HWND)-1; /* 第二只起就记「不唯一」 */
  }
  return TRUE;
}

static HWND moonui_native_single_button(HWND dialog) {
  HWND only = 0;
  EnumChildWindows(dialog, moonui_native_button_scan_enum, (LPARAM)&only);
  return only == (HWND)-1 ? 0 : only;
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
    HWND button;
    moonui_native_arm_mark(MOONUI_ARM_TARGET);
    /* BM_CLICK 让按钮自己发出 WM_COMMAND/BN_CLICKED，对话框因此以那个控件 ID 收摊
     * ——答案是 MessageBox 自己给的，不是这里编的（和 mac 的 performClick: 同一个
     * 理由，也和 moonui_native_click_button_in_window 同一个理由）。
     * 先按装好的控件 ID 找；对不上时（`T306`：本机 Win11 的 `MB_OK` 把唯一那只
     * 按钮建成 ID 2）退到「只有一只按钮就按它」，仍按不到才走兜底关窗。 */
    button = GetDlgItem(dialog, d->id);
    if (button == 0) {
      button = moonui_native_single_button(dialog);
    }
    if (button != 0) {
      SendMessageW(button, BM_CLICK, 0, 0);
      moonui_native_arm_mark(MOONUI_ARM_ACTED);
    }
    /* 两级兜底。按下没生效时，WM_CLOSE 和 ESC 都会让 MessageBox 以 IDCANCEL 结束，
     * 于是调用方拿到"否"、断言红在那里。留着这段是因为脚手架坏掉的代价不该是
     * 一整轮挂住的测试。FALLBACK 位（`T306`）就是给这段留的痕迹：判据本来是绿的，
     * 是兜底把它救绿的——主路径坏了也能在这里看见。 */
    if (!moonui_native_dialog_gone(dialog)) {
      moonui_native_arm_mark(MOONUI_ARM_FALLBACK);
      PostMessageW(dialog, WM_CLOSE, 0, 0);
      if (!moonui_native_dialog_gone(dialog)) {
        PostMessageW(dialog, WM_KEYDOWN, VK_ESCAPE, 0);
      }
    }
  }
  /* 没找到对话框也照样收工：`armed|done` 是「这发根本没跑起来」的明确记号，
   * 与「点了但没生效」区分得开——这正是 `T304` 之前分不清的那两件事。 */
  moonui_native_arm_mark(MOONUI_ARM_DONE);
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
    /* 产品路径从来不装这发（`dismiss_after_ms` 恒 -1），这里也就没有账要记。 */
    return;
  }
  /* 认领即开账（`T306`）：真正的动作在下面那条线程里，判据要看它走到哪一步。 */
  moonui_native_arm_begin(MOONUI_ARM_DIALOG);
  index = moonui_native_dismiss_index;
  d = (MoonuiDismiss *)malloc(sizeof(*d));
  if (d == 0) {
    moonui_native_arm_mark(MOONUI_ARM_SETUP | MOONUI_ARM_DONE);
    return;
  }
  for (n = 0; caption[n] != L'\0'; ++n) {
  }
  d->caption = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
  if (d->caption == 0) {
    free(d);
    moonui_native_arm_mark(MOONUI_ARM_SETUP | MOONUI_ARM_DONE);
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
    moonui_native_arm_mark(MOONUI_ARM_SETUP | MOONUI_ARM_DONE);
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
    moonui_native_arm_mark(MOONUI_ARM_TARGET);
    if (a->accept) {
      /* 第一级投一条"按下回车"：它落在 Show 自己的模态循环里，由对话框的按键
       * 翻译变成"按下默认钮"，也就是真人敲回车那条提交路径——不赌 OK 钮是顶层
       * 对话框的直接子窗口（IFileDialog 的界面是 DirectUI 画的，按钮通常不是
       * 子窗口，SendDlgItemMessage 因此排在第二级）。投递而不是发送：按键翻译
       * 发生在消息循环里，SendMessage 绕过了它。 */
      PostMessageW(dialog, WM_KEYDOWN, VK_RETURN, 1);
      moonui_native_arm_mark(MOONUI_ARM_ACTED);
      if (!moonui_native_dialog_gone(dialog)) {
        /* 第二级是老式对话框形态的 OK 钮（控件 ID 固定是 IDOK）。BM_CLICK 让
         * 按钮自己发 BN_CLICKED，面板的提交路径因此真跑一遍——回来的路径是
         * 面板兑的，不是这里编的。 */
        SendDlgItemMessageW(dialog, IDOK, BM_CLICK, 0, 0);
        if (!moonui_native_dialog_gone(dialog)) {
          /* 到这里才是"主路径没成、靠强制关窗收场"（`T306`）：面板会以取消收摊，
           * 断言因此照样可能红，但至少日志能说清红在哪一步。 */
          moonui_native_arm_mark(MOONUI_ARM_FALLBACK);
          PostMessageW(dialog, WM_CLOSE, 0, 0);
          if (!moonui_native_dialog_gone(dialog)) {
            PostMessageW(dialog, WM_KEYDOWN, VK_ESCAPE, 0);
          }
        }
      }
    } else {
      /* 取消是关掉对话框：WM_CLOSE 让 Show 以 ERROR_CANCELLED 回来，和真人按
       * "取消"同一条路。这条是取消的**主**路径，不算兜底。 */
      PostMessageW(dialog, WM_CLOSE, 0, 0);
      moonui_native_arm_mark(MOONUI_ARM_ACTED);
      if (!moonui_native_dialog_gone(dialog)) {
        moonui_native_arm_mark(MOONUI_ARM_FALLBACK);
        PostMessageW(dialog, WM_KEYDOWN, VK_ESCAPE, 0);
      }
    }
    /* 兜底那一串只影响"脚手架坏掉之后多久变成红"：每一级要么让面板以某个答案
     * 收摊（绿的各归断言），要么交给下一级；连最后一级的 WM_CLOSE / ESC 都不起
     * 作用时才会挂住——那时取消路径也一起坏了，不是接受特有的风险。 */
  }
  /* 没找到面板窗也照样收工：`armed|done` 就是「这发根本没跑起来」。 */
  moonui_native_arm_mark(MOONUI_ARM_DONE);
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
    /* 产品路径从来不装这发，没有账要记。 */
    return;
  }
  moonui_native_arm_begin(MOONUI_ARM_FILE);
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
    moonui_native_arm_mark(MOONUI_ARM_PAYLOAD);
  }
  a = (MoonuiFileAnswer *)malloc(sizeof(*a));
  if (a == 0) {
    moonui_native_arm_mark(MOONUI_ARM_SETUP | MOONUI_ARM_DONE);
    return;
  }
  for (n = 0; caption[n] != L'\0'; ++n) {
  }
  a->caption = (WCHAR *)malloc(((size_t)n + 1u) * sizeof(WCHAR));
  if (a->caption == 0) {
    free(a);
    moonui_native_arm_mark(MOONUI_ARM_SETUP | MOONUI_ARM_DONE);
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
    moonui_native_arm_mark(MOONUI_ARM_SETUP | MOONUI_ARM_DONE);
    return;
  }
  /* 和 moonui_native_start_dismissor 同一行注释：主线程马上要进模态循环，不能 join；
   * CloseHandle 只关掉本线程自己的句柄，线程对象在它跑完之前都还在。 */
  CloseHandle(thread);
}

/* 8.3 短名 → 长名（T301）：IFileDialog 在部分环境（GitHub 的 hosted runner，
 * 用户目录落在 8.3 短名 `C:\Users\RUNNER~1\...`）会回短名，而应用侧
 * （@moonui.Fs::temp_dir() 等）拿到的是长名，两边逐字比对不上。
 *
 * GetLongPathNameW 要求路径**存在**；保存面板的目标文件可以还不存在，所以先试
 * 整条（open / folder 的结果都在），失败再退回"展开父目录 + 原样文件名"——父
 * 目录一定在（FOS_PATHMUSTEXIST）。全部失败就返回 0，调用方用原串。 */
static LPWSTR moonui_native_expand_long_path(LPWSTR p) {
  DWORD need;
  LPWSTR out = 0;
  if (p == 0) {
    return 0;
  }
  need = GetLongPathNameW(p, 0, 0);
  if (need > 0) {
    out = (LPWSTR)malloc((size_t)need * sizeof(WCHAR));
    if (out != 0) {
      if (GetLongPathNameW(p, out, need) == 0) {
        free(out);
        out = 0;
      }
    }
  }
  if (out != 0) {
    return out;
  }
  {
    WCHAR *slash = 0, *q;
    for (q = p; *q != L'\0'; ++q) {
      if (*q == L'\\' || *q == L'/') slash = q;
    }
    /* 分隔符必须在一个真目录后面（`C:\` 的 `\` 前面是 `:`，展开没有意义——
     * 那种路径整条已经试过了）。 */
    if (slash != 0 && slash > p + 1 && slash[-1] != L':') {
      size_t dirlen = (size_t)(slash - p);
      LPWSTR dir = (LPWSTR)malloc((dirlen + 1u) * sizeof(WCHAR));
      if (dir != 0) {
        memcpy(dir, p, dirlen * sizeof(WCHAR));
        dir[dirlen] = L'\0';
        need = GetLongPathNameW(dir, 0, 0);
        if (need > 0) {
          LPWSTR longdir = (LPWSTR)malloc((size_t)need * sizeof(WCHAR));
          if (longdir != 0) {
            if (GetLongPathNameW(dir, longdir, need) != 0) {
              size_t d2 = wcslen(longdir);
              size_t name_len = wcslen(slash + 1);
              out = (LPWSTR)malloc((d2 + 1u + name_len + 1u) * sizeof(WCHAR));
              if (out != 0) {
                memcpy(out, longdir, d2 * sizeof(WCHAR));
                out[d2] = L'\\';
                memcpy(out + d2 + 1, slash + 1, name_len * sizeof(WCHAR));
                out[d2 + 1u + name_len] = L'\0';
              }
            }
            free(longdir);
          }
        }
        free(dir);
      }
    }
  }
  return out;
}

/* 测试脚手架：把一条路径展开成 8.3 短名对应的长名，返回 UTF-8 字节串。
 *
 * `moonui_native_run_file_panel` 用上面那条 `moonui_native_expand_long_path` 处理
 * 面板结果，所以「路径是面板给的」这条判据的期望值必须做同一步才能逐字比
 * （T302：hosted runner 的用户目录落在 `C:\Users\RUNNER~1\...`，而
 * `@moonui.Fs::temp_dir()` 读的是环境变量 `TEMP` 的原值，天生是短名）。
 *
 * 展开失败（整条不存在且父目录也展开不了）原样返回——调用方拿到的还是原串，
 * 不会因为归一化把路径变成空串。这条脚手架在 CI 上是有区分力的：不展开时期望
 * 侧是短名、面板侧是长名，判据当场红。 */
moonbit_bytes_t moonui_native_long_path(const char *p, int len) {
  LPWSTR w, lp;
  char *u = 0;
  moonbit_bytes_t out;
  TRACE("long_path");
  w = moonui_native_utf16_of(p, len);
  if (w == 0) {
    return moonbit_make_bytes(0, 0);
  }
  lp = moonui_native_expand_long_path(w);
  u = moonui_native_utf8_of(lp != 0 ? lp : w);
  if (lp != 0) {
    free(lp);
  }
  free(w);
  if (u == 0) {
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_native_bytes_of(u);
  free(u);
  return out;
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
        LPWSTR lp = moonui_native_expand_long_path(p);
        char *u = moonui_native_utf8_of(lp != 0 ? lp : p);
        if (u != 0) {
          moonui_native_file_result = moonui_native_dup(u, (int)strlen(u));
          free(u);
        }
        if (lp != 0) {
          free(lp);
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
  if (e->immersive) {
    /* 沉浸式窗（`T116`）不要系统菜单条：客户区铺满整窗之后菜单条根本没地方
     * 摆，而 Win32 一旦 SetMenu 就会从客户区上方硬切一行出去。树本身留在
     * 进程级的 moonui_native_menu_tree 里，切回标准标题栏时照它重建。 */
    if (bar != 0) {
      DestroyMenu(bar);
    }
    return;
  }
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
  e->immersive = 0;
  e->drag_h = 0;
  e->corner_radius_pm = -1;
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
  e->immersive = 0;
  e->drag_h = 0;
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

/* ---- 控件级右键上下文菜单（`T86①`，Windows 半）----
 *
 * 树沿菜单栏那套读游标现建 popup（moonui_native_menu_build 建的是逐顶层
 * MF_POPUP 的树，这里只取第一个顶层的 popup 自身），TrackPopupMenuEx 用
 * TPM_RETURNCMD | TPM_NONOTIFY 在鼠标当下位置同步弹出：选中项的 id 由返回值
 * 给回，WM_COMMAND 那条路被 NONOTIFY 拦住——不会闯进菜单栏的命令路由，选中
 * 的闭包在弹出返回后当场调（选中语义沿 `T86①` 落地注记，同步解析）。建出的
 * popup 用完即拆。返回码：0 = 弹过；-1 = 树不合法；-2 = 没有活窗口可挂
 * （TrackPopupMenu 的 owner 必须是一只窗口）。这半只到 mingw 语法闸门。 */

/* 替按（`T91①`）选中的命令 id（带 MOONUI_MENU_ID_BASE），-1 = 没有替按选中。
 * 由替按旁观线程在弹出期间写入，show_context_menu 在 TrackPopupMenuEx 返回后
 * 读走。与 mac 半 `performActionForItemAtIndex` 同一条语义：替按直接指定选哪
 * 一项。为什么不只靠 PostMessage 的伪点击：菜单弹进触发窗口内部时，Windows
 * 菜单的光标跟踪会把伪点击当点空白（sel=0），判据随弹窗位置假红；伪点击仍保留，
 * 只用来让模态循环关掉菜单，选中项改由这里的 id 决定。 */
static volatile int moonui_native_menu_pick_id = -1;

int moonui_native_show_context_menu(const char *tree, int tree_len,
                             moonui_closure_id_fn fn, void *closure) {
  MoonuiTree t;
  HMENU popup;
  HMENU bar;
  HWND owner = 0;
  int i;
  int sel;
  TRACE("show_context_menu");
  moonui_native_menu_pick_id = -1;
  if (!moonui_native_inited) {
    return -2;
  }
  if (tree == 0 || tree_len < 5) {
    return -1;
  }
  for (i = 0; i < MOONUI_MENU_WINDOWS; ++i) {
    if (moonui_native_win_menu[i].hwnd != 0) {
      owner = moonui_native_win_menu[i].hwnd;
    }
  }
  if (owner == 0) {
    return -2;
  }
  moonui_native_tree_init(&t, tree, tree_len);
  bar = moonui_native_menu_build(&t);
  if (bar == 0 || t.bad) {
    if (bar != 0) {
      DestroyMenu(bar);
    }
    return -1;
  }
  popup = GetMenuItemCount(bar) > 0 ? GetSubMenu(bar, 0) : 0;
  if (popup == 0) {
    DestroyMenu(bar);
    return -1;
  }
  /* 弹在鼠标当下位置：TrackPopupMenuEx 的 x/y 与 GetCursorPos 同为屏幕坐标，
   * 直接传。此前写死 0,0，菜单恒落在主屏左上角、与触发它的按钮隔了整屏。*/
  /* `T315`：弹出前把 owner 提到前台，弹完再还一次（托盘菜单
   * `moonui_native_tray_show_menu` 的经典两步，逐字同款）。没有这一步时，
   * 窗口不在前台的弹出（替按/无焦点注入）会让 TrackPopupMenuEx 不进模态
   * 循环——菜单窗压根不创建，替按线程找 5s 找不到新 #32768 窗，进度位停在
   * armed|done、target/located/acted 全不亮（`T315` 偶发红的确切形态）。真人
   * 右键时窗口本是前台，这一步幂等无害。 */
  {
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(owner);
    sel = (int)TrackPopupMenuEx(popup,
                                TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                                pt.x, pt.y, owner, 0);
    PostMessageW(owner, WM_NULL, 0, 0);
  }
  DestroyMenu(bar);
  /* 替按（`T91①`）：旁观线程直接指定选中项的命令 id，覆盖模态循环返回值
   * （伪点击在菜单弹进窗口内部时只关菜单、不选中，会返回 0）。仍走同一条回调
   * 派发，判据验证的「选中项回调当场同步跑」不变。*/
  if (moonui_native_menu_pick_id >= 0) {
    sel = moonui_native_menu_pick_id;
    moonui_native_menu_pick_id = -1;
  }
  /* menu_append_item 装进去的命令 id 是 Core 的 id + MOONUI_MENU_ID_BASE，
   * TPM_RETURNCMD 给回的就是那个带基址的数，报给 Core 之前退掉基址。 */
  if (sel >= MOONUI_MENU_ID_BASE && fn != 0 && closure != 0) {
    fn(closure, sel - MOONUI_MENU_ID_BASE);
  }
  return 0;
}

/* ---- 上下文菜单的替按（`T91①` Windows 半的自动化入口）----
 *
 * mac 半的 auto_pick_context_menu 是在追踪循环里排一个延迟点击；Windows
 * 这边 TrackPopupMenuEx 的模态循环跑在调用线程上，替按走旁观线程：找本进程
 * 新出现的 #32768 菜单窗，GetMenuItemRect 量目标项的屏幕矩形，把一对
 * WM_LBUTTONDOWN/UP Post 进菜单窗（模态循环取得到的正是投递消息）。armed
 * 在弹出**之前**：调用方先装单、再右键、再 drain——drain 里的 step 会一直
 * 坐进模态循环，替按线程把它捞出来。
 * 返回 0 = 已武装；-1 = index 为负。武装只说明「线程起来了」，走到了哪一步
 * 要看 `moonui_native_menu_pick_state` 的进度位（`T304`）。
 *
 * `T305` 改了两处形状：①武装那一刻先给本进程已有的 #32768 窗拍一张快照，
 * 轮询只认不在快照里的窗——原来的「先 Sleep(ms) 再找第一个 #32768」认的是
 * 遇上的第一只，连续弹两次时会点在上一次的残窗上；②项矩形量不到时下一拍
 * 再试，而不是一次失败就静默放弃（那种失败在外部与「没点到」完全同形）。 */

/* 一只进程里同时存在的菜单窗不可能多过这个数；快照与扫描都用它当上限。 */
#define MOONUI_MENU_PICK_SNAP 8

/* 一组窗句柄。真实调用里装的是 HWND，判据那边装的是造出来的小整数——
 * 「是不是同一个」这个判定对两者是同一件事。 */
typedef struct {
  uintptr_t v[MOONUI_MENU_PICK_SNAP];
  int n;
} MoonuiMenuSet;

typedef struct {
  int ms;
  int index;
  int timeout;
  /* 武装那一刻本进程已有的 #32768 窗（上一轮弹出的残窗），见上面 ①。 */
  MoonuiMenuSet base;
} MoonuiMenuPick;

/* 进度位走上面那只共享记录（`T306` 把 `T304` 在这处先立的那套推广到三处）：
 * 菜单用到的四段分别是 TARGET（找到菜单窗）/ PAYLOAD（拿到 HMENU）/
 * LOCATED（量到项矩形）/ ACTED（投出点击），收尾一律 DONE。 */

/* 找窗窗口默认 5 秒（模态循环建窗得有一拍，冷机器更慢）。只给负控制留口子
 * ——`moonui_native_auto_pick_context_menu_within` 可以把它压到几百毫秒，
 * 这样「菜单窗永不出现」这条能当场验完，不必陪它空等满 5 秒。 */
#define MOONUI_MENU_PICK_TIMEOUT 5000

static BOOL CALLBACK moonui_native_menu_scan_enum(HWND hwnd, LPARAM lp) {
  MoonuiMenuSet *s = (MoonuiMenuSet *)(uintptr_t)lp;
  WCHAR cls[64];
  DWORD pid = 0;
  if (s->n >= MOONUI_MENU_PICK_SNAP) {
    return FALSE;
  }
  if (GetClassNameW(hwnd, cls, 64) == 0 || lstrcmpW(cls, L"#32768") != 0) {
    return TRUE;
  }
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == GetCurrentProcessId()) {
    s->v[s->n++] = (uintptr_t)hwnd;
  }
  return TRUE;
}

/* 从「现在扫到的窗」里挑第一只不在「武装时已有」里的，返回它的下标，没有
 * 给 -1。真实替按与判据出口（`moonui_native_menu_pick_new_index`）走的是
 * 这同一个函数，别复制成两份——那样判据验的就不是产品在跑的逻辑了。 */
static int moonui_menu_pick_first_new(const MoonuiMenuSet *base,
                                      const MoonuiMenuSet *now) {
  int i;
  int j;
  for (i = 0; i < now->n; i++) {
    int known = 0;
    for (j = 0; j < base->n; j++) {
      if (base->v[j] == now->v[i]) {
        known = 1;
        break;
      }
    }
    if (!known) {
      return i;
    }
  }
  return -1;
}

static DWORD WINAPI moonui_native_menu_pick_thread(LPVOID arg) {
  MoonuiMenuPick *p = (MoonuiMenuPick *)arg;
  MoonuiMenuSet now;
  HWND menu_win = 0;
  HMENU menu = 0;
  RECT rc;
  POINT pt;
  DWORD total = 0;
  DWORD budget;
  /* `T305` ②：从武装那一刻就开始看，而不是先盲睡 ms 再找——盲睡期间弹出
   * 的菜单若比 ms 慢，原实现整段预算就白花在睡眠上；反过来先睡再看，看到
   * 的也可能是上一次的残窗。改为「只认新出现的那只」后 ms 只当**最早可以
   * 点的时间**：不提前点，但找窗从第一拍就开始。
   * 预算 = 调用方给的延迟 + 找窗窗口，两段都要留。 */
  budget = (DWORD)p->ms + (DWORD)p->timeout;
  for (;;) {
    int hit;
    now.n = 0;
    EnumWindows(moonui_native_menu_scan_enum, (LPARAM)&now);
    hit = moonui_menu_pick_first_new(&p->base, &now);
    if (hit >= 0) {
      HWND w = (HWND)now.v[hit];
      if (w != menu_win) {
        /* 换了窗：上一只的 HMENU 不能再用（句柄会被系统复用）。 */
        menu_win = w;
        menu = 0;
      }
      moonui_native_arm_mark(MOONUI_ARM_TARGET);
      if (menu == 0) {
        menu = GetMenu(menu_win);
        if (menu == 0) {
          /* 某些构建上 GetMenu 对菜单窗给 0：MN_GETMENU（0x01E1）是菜单窗
           * 自己认的口子。 */
          menu = (HMENU)(uintptr_t)SendMessageW(menu_win, 0x01E1, 0, 0);
        }
        if (menu != 0) {
          moonui_native_arm_mark(MOONUI_ARM_PAYLOAD);
        }
      }
      /* 项矩形要等菜单窗排完版才量得到（模态循环建窗与排版不同拍），量不
       * 到就下一拍再试，而不是一次失败就放弃。 */
      if (menu != 0 && GetMenuItemRect(0, menu, p->index, &rc) != 0) {
        moonui_native_arm_mark(MOONUI_ARM_LOCATED);
        if (total >= (DWORD)p->ms) {
          /* 替按直接指定选中项的命令 id（`T91①`，与 mac 半 performAction
           * ForItemAtIndex 同语义）：按位置取 App 项的 id（菜单无分隔线，位置
           * 即 Core id），加上基址写成全局，由 show_context_menu 走真实回调。
           * 下面的伪点击只保留来关掉模态循环——菜单弹在触发窗口内部时它被
           * Windows 当点空白（不改选中），id 才是选中的最终裁决。*/
          int id = (int)GetMenuItemID(menu, p->index);
          if (id > 0) {
            moonui_native_menu_pick_id = id;
          }
          pt.x = (rc.left + rc.right) / 2;
          pt.y = (rc.top + rc.bottom) / 2;
          ScreenToClient(menu_win, &pt);
          PostMessageW(menu_win, WM_LBUTTONDOWN, MK_LBUTTON,
                       MAKELPARAM(pt.x, pt.y));
          PostMessageW(menu_win, WM_LBUTTONUP, 0, MAKELPARAM(pt.x, pt.y));
          moonui_native_arm_mark(MOONUI_ARM_ACTED);
          break;
        }
      }
    } else if (menu_win != 0) {
      /* 认下的窗已经不在了（菜单被关掉或重建）：忘掉它，重扫一轮再认。 */
      menu_win = 0;
      menu = 0;
    }
    if (total >= budget) {
      break;
    }
    Sleep(10);
    total += 10;
  }
  moonui_native_arm_mark(MOONUI_ARM_DONE);
  free(p);
  return 0;
}

/* 带窗口长度的那条定义在下面；这里先声明，避免包装函数用前未声明。 */
int moonui_native_auto_pick_context_menu_within(int ms, int index,
                                                int timeout_ms);

/* 与 `adapter.h` 里那条同形的入口：窗口长度用默认 5 秒。 */
int moonui_native_auto_pick_context_menu(int ms, int index) {
  return moonui_native_auto_pick_context_menu_within(ms, index,
                                                     MOONUI_MENU_PICK_TIMEOUT);
}

/* 与上一条同形，只把「等菜单窗出现」的窗口长度显式给出来。负控制（`T304`）
 * 用它把窗口压到几百毫秒：菜单窗永不出现时，进度位必须停在「已武装 + 已收
 * 尾」，与「点到了」明确可分。 */
int moonui_native_auto_pick_context_menu_within(int ms, int index,
                                                int timeout_ms) {
  MoonuiMenuPick *p;
  HANDLE th;
  TRACE("auto_pick_context_menu");
  if (index < 0) {
    return -1;
  }
  p = (MoonuiMenuPick *)malloc(sizeof(MoonuiMenuPick));
  if (p == 0) {
    return -1;
  }
  p->ms = ms < 0 ? 0 : ms;
  p->index = index;
  p->timeout = timeout_ms < 0 ? 0 : timeout_ms;
  /* 快照必须在**这次**弹出之前拍：调用方约定「先武装、再右键」，所以这里
   * 扫到的都是上一轮留下的残窗。放在武装线程上同步做，比让替按线程自己睡
   * 醒后再判断更早、也更确定。 */
  p->base.n = 0;
  EnumWindows(moonui_native_menu_scan_enum, (LPARAM)&p->base);
  moonui_native_arm_begin(MOONUI_ARM_MENU);
  th = CreateThread(0, 0, moonui_native_menu_pick_thread, p, 0, 0);
  if (th == 0) {
    free(p);
    moonui_native_arm_mark(MOONUI_ARM_SETUP | MOONUI_ARM_DONE);
    return -1;
  }
  CloseHandle(th);
  return 0;
}

/* 读回最新一次替按的进度位（`T304`，`T306` 起它就是共享记录的那只读回口）：
 * 调用方在 `clicked` 为空时先读它，才能分清「菜单没弹」「拿到窗拿不到菜单」
 * 「index 越界」「点到了没生效」。名字保留是因为 `native_test.mbt` 一直在调它。 */
int moonui_native_menu_pick_state(void) {
  return moonui_native_arm_read();
}

/* 判据出口（`T305`）：把「只认新窗」这条判定暴露成能造数的形状——每个句柄
 * 占 4 位、低位在前，最多 8 个，返回值是第一个新窗在 `now` 里的下标（没有给
 * -1）。真实调用走 `MoonuiMenuSet` 的数组形态，判定本体是同一个
 * `moonui_menu_pick_first_new`，所以这条判据验的就是产品在跑的逻辑；不同的
 * 只是把句柄塞进来的方式（测试用 0..15 的假值，真句柄是地址）。
 * 为什么非要有这个口：留一只 #32768 残窗挂在进程里再弹第二个菜单，在真窗
 * 测试里没法确定性地构造（`#32768` 是系统菜单类，应用注册不出来）。 */
int moonui_native_menu_pick_new_index(int base_packed, int base_n,
                                      int now_packed, int now_n) {
  MoonuiMenuSet base;
  MoonuiMenuSet now;
  int i;
  base.n = base_n < 0 ? 0 : (base_n > MOONUI_MENU_PICK_SNAP
                               ? MOONUI_MENU_PICK_SNAP
                               : base_n);
  now.n = now_n < 0 ? 0 : (now_n > MOONUI_MENU_PICK_SNAP
                             ? MOONUI_MENU_PICK_SNAP
                             : now_n);
  for (i = 0; i < base.n; i++) {
    base.v[i] = (uintptr_t)((base_packed >> (4 * i)) & 0xF);
  }
  for (i = 0; i < now.n; i++) {
    now.v[i] = (uintptr_t)((now_packed >> (4 * i)) & 0xF);
  }
  return moonui_menu_pick_first_new(&base, &now);
}

/* 等一下这一轮替按收尾（DONE 位置起来）或超时，返回最终进度位。武装与读
 * 之间有时序：ACTED 是投递那一刻置的，`clicked` 是模态循环消化消息时填
 * 的，两者谁先到不保证；要断言「点到了」就得先等 DONE。`T306` 起与
 * `moonui_native_arm_wait` 是同一件事，留这个名字给已有的判据。 */
int moonui_native_menu_pick_wait(int wait_ms) {
  return moonui_native_arm_wait(wait_ms);
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

/* 相对路径换成"exe 所在目录 + 原路径"；本来就是绝对路径、或拿不到 exe 路径时
 * 回 0（调用方保持原判）。只用 loop 拼串，不引 wchar 的字符串函数族。 */
static LPWSTR moonui_native_path_beside_exe(const WCHAR *path) {
  WCHAR exe[MAX_PATH];
  LPWSTR joined;
  DWORD n;
  size_t len;
  int cut;
  int k;
  if (path == 0 || path[0] == 0) {
    return 0;
  }
  if (path[0] == L'\\' || path[0] == L'/') {
    return 0; /* 根相对 / UNC */
  }
  if (path[1] == L':') {
    return 0; /* 已有盘符 */
  }
  n = GetModuleFileNameW(0, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return 0;
  }
  cut = -1;
  for (k = (int)n - 1; k >= 0; --k) {
    if (exe[k] == L'\\' || exe[k] == L'/') {
      cut = k;
      break;
    }
  }
  if (cut < 0) {
    return 0;
  }
  len = (size_t)cut + 1u + wcslen(path) + 1u;
  joined = (LPWSTR)malloc(len * sizeof(WCHAR));
  if (joined == 0) {
    return 0;
  }
  for (k = 0; k <= cut; ++k) {
    joined[k] = exe[k];
  }
  wcscpy(joined + cut + 1, path);
  return joined;
}

static void moonui_native_icon_apply(HWND hwnd) {
  if (hwnd == 0 || moonui_native_app_icon_big == 0) {
    return;
  }
  SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)moonui_native_app_icon_big);
  SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)moonui_native_app_icon_small);
  /* 类图标一起换掉（`T316`）。系统找"这只窗的图标"的顺序是
   * WM_GETICON(ICON_BIG) → 窗口类图标 → exe 文件图标；类图标在
   * `moonui_native_init` 里钉的是 `IDI_APPLICATION`——那只白色通用图标。
   * 前一条什么时候被跳过由系统说了算（任务栏按钮重建、Alt-Tab 缓存、
   * 最小化预览都各读各的），一被跳过就退到类图标，屏幕上就是 owner 截图里
   * 那个"任务栏没显示应用图标"。这里让兜底也落到应用图标上。
   * 类是我们自己注册的、全进程共用，逐窗口重设同一个值幂等。 */
  SetClassLongPtrW(hwnd, GCLP_HICON, (LONG_PTR)moonui_native_app_icon_big);
  SetClassLongPtrW(hwnd, GCLP_HICONSM, (LONG_PTR)moonui_native_app_icon_small);
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
  if (icon_big == 0) {
    /* 相对路径先按 CWD 找（`App::set_icon` 的约定），找不到再按 **exe 所在
     * 目录**找一次：启动目录不由应用决定，资源管理器双击 / 快捷方式 / IDE 的
     * run 配置都把 CWD 放在 exe 旁边，那儿没有仓库根的 `assets/`。没有这一格
     * 时"从别处启动"会一路升成 `OperationFailed` 把应用打死（本机实测
     * exit 127），而图标本身只是装饰——不该有这种后果。 */
    LPWSTR alt = moonui_native_path_beside_exe(path);
    if (alt != 0) {
      icon_big = (HICON)LoadImageW(NULL, alt, IMAGE_ICON, cx_big, cx_big,
                                   LR_LOADFROMFILE);
      icon_small = (HICON)LoadImageW(NULL, alt, IMAGE_ICON, cx_small, cx_small,
                                    LR_LOADFROMFILE);
      free(alt);
    }
  }
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

/* 应用显示名（`T205`）：Windows 没有应用菜单那顶（菜单栏是窗口自己的，应用
 * 不装就没有），任务栏/Alt-Tab 的分组名来自 exe，运行时改不了也没必要改。
 * 收下参数按成功返回——调用方一份代码两平台跑，mac 生效、这里无害。 */
int moonui_native_set_app_name(const char *name, int name_len) {
  (void)name;
  (void)name_len;
  TRACE("set_app_name");
  return 0;
}

/* 测试探针：按标题找回那只窗口，看它的图标是不是我们装的那只。两份账各一位
 * （`T316`）：
 *   位 0 = 窗口自己的 WM_SETICON 图标（WM_GETICON 读回的就是存进去的 HICON，
 *          指针相等即同一只）；
 *   位 1 = 窗口**类**图标（GCLP_HICON，系统的兜底顺序里排第二）。
 * 没装过应用图标（moonui_native_app_icon_big == 0）恒返回 0；装了但两份都没落
 * 到这只窗口也是 0。位 1 是这轮补的：类图标此前钉在 IDI_APPLICATION，系统一旦
 * 跳过 WM_SETICON 那条就退到"通用白窗口"，任务栏看不到应用图标。 */
static HWND moonui_native_find_window(const char *title, int title_len);
int moonui_native_window_icon_installed(const char *title, int title_len) {
  HWND win;
  HICON got_big;
  HICON got_small;
  HICON cls_big;
  HICON cls_small;
  int bits = 0;
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
    bits |= 1;
  }
  cls_big = (HICON)GetClassLongPtrW(win, GCLP_HICON);
  cls_small = (HICON)GetClassLongPtrW(win, GCLP_HICONSM);
  if (cls_big == moonui_native_app_icon_big ||
      (moonui_native_app_icon_small != 0 &&
       cls_small == moonui_native_app_icon_small)) {
    bits |= 2;
  }
  return bits;
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

/* 只给测试用（`T205`）：主菜单全部顶的标题。Windows 的菜单栏挂在每只窗口上、
 * 没有 mac 那种"进程级应用菜单"的概念，这条钉不了任何 Windows 侧的事实——
 * 恒返回空，判据（在 mac 那半）不跨平台引用它。 */
moonbit_bytes_t moonui_native_menu_tops_dump(void) {
  TRACE("menu_tops_dump");
  return moonbit_make_bytes(0, 0);
}

/* T205: Windows no-ops this probe, see moonui_native_menu_tops_dump. */
moonbit_bytes_t moonui_native_ls_name_dump(void) {
  TRACE("ls_name_dump");
  return moonbit_make_bytes(0, 0);
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
/* 同一颗事件里的修饰键（`T102` 第二十三刀）：moonui_native_mods_of_state
 * 的四位打包，与键盘那半同一张表（adapter.h 鼠标段）。 */
static int moonui_native_mouse_mods_val = 0;
/* 合成鼠标事件的修饰键覆盖（`T102` 第二十三刀）：-1 = 按 GetKeyState 读
 * 真键盘状态；>= 0 = 钩子按这个四位打包记账（合成消息改不了真键盘状态，
 * 测试靠这一格注入）。粘性直到再设，与 mac 半同一条契约。 */
static int moonui_native_synth_mouse_mods = -1;
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

/* 真滚动：视口自己的滚动条通知 / 视口内滚轮。返回 1 = 已消费（scroll_proc
 * 不再把消息转发给父窗口）。
 *
 * 两条来源要分清：
 *  - WM_VSCROLL / WM_HSCROLL 且 lp==0 → 标准滚动条（视口自己 WS_VSCROLL/
 *    WS_HSCROLL 的那根）发来的；lp≠0 是子 trackbar（slider）的，留给原转发路。
 *  - 滚轮 → 视口客户区里转的；换算复用 `wheel_delta_of`（与 Core Scroll 事件
 *    同一把尺：逻辑像素、正=往下/右读），再乘 dpi/96 落回物理像素。
 * 两边都走同一个"改 offset + 平移子控件 + 同步 SetScrollInfo"的收口，屏幕
 * 滚动与 Core 收到的 Scroll 事件是同一趟滚动的两面，不会各滚各的。 */
static int moonui_native_scroll_on_bar(HWND hwnd, UINT msg, WPARAM wp,
                                       LPARAM lp) {
  moonui_ptr scroll;
  int bar;
  int off_x;
  int off_y;
  int max_v = 0;
  int max_h = 0;
  SCROLLINFO si;
  RECT cr;
  int delta_x = 0;
  int delta_y = 0;
  int orig_x;
  int orig_y;
  int dpi;
  int logical_x = 0;
  int logical_y = 0;

  if (moonui_native_kind_of_hwnd(hwnd) != 15) {
    return 0;
  }
  scroll = (moonui_ptr)(uintptr_t)hwnd;
  bar = (msg == WM_VSCROLL || msg == WM_MOUSEWHEEL) ? SB_VERT : SB_HORZ;
  if ((msg == WM_VSCROLL || msg == WM_HSCROLL) && lp != 0) {
    return 0; /* 子 trackbar 的，不是我们这根滚动条 */
  }
  if (GetClientRect(hwnd, &cr) == 0) {
    return 0;
  }
  moonui_native_scroll_offset(scroll, &off_x, &off_y);
  orig_x = off_x;
  orig_y = off_y;

  if (msg == WM_VSCROLL || msg == WM_HSCROLL) {
    /* 标准滚动条的当前行程从 SCROLLINFO 读回：`nMax` 是内容末位（content-1），
     * 最大偏移 = nMax - nMin - nPage + 1 = content - view；步进用系统"一行"的
     * 像素高，翻页用视口尺寸。 */
    si.cbSize = (UINT)sizeof(si);
    si.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    if (GetScrollInfo(hwnd, bar, &si) == 0) {
      return 0;
    }
    max_v = si.nMax - (int)si.nMin - (int)si.nPage + 1;
    if (max_v < 0) {
      max_v = 0;
    }
    max_h = max_v;
    switch (LOWORD(wp)) {
      case SB_LINEUP:
        delta_y = -moonui_native_line_px();
        break;
      case SB_LINEDOWN:
        delta_y = moonui_native_line_px();
        break;
      case SB_PAGEUP:
        delta_y = -(int)si.nPage;
        break;
      case SB_PAGEDOWN:
        delta_y = (int)si.nPage;
        break;
      case SB_THUMBTRACK:
      case SB_THUMBPOSITION:
        /* 16 位位置够不了大文档：带 SIF_TRACKPOS 重读，拿完整 nTrackPos。 */
        si.fMask = SIF_TRACKPOS;
        if (GetScrollInfo(hwnd, bar, &si) != 0) {
          delta_y = si.nTrackPos - off_y;
        }
        break;
      case SB_TOP:
        delta_y = -off_y;
        break;
      case SB_BOTTOM:
        delta_y = max_v - off_y;
        break;
      default:
        return 0; /* SB_ENDSCROLL 等：不滚，但也不必再往上抛 */
    }
    if (bar == SB_HORZ) {
      delta_x = delta_y;
      delta_y = 0;
    }
  } else {
    /* 滚轮。换算成的逻辑增量既已按方向带符号（正=往下/右读），这里直接
     * 乘缩放落回物理，叠加到 offset 上。 */
    dpi = moonui_native_widget_dpi((moonui_ptr)(uintptr_t)hwnd);
    if (moonui_native_wheel_delta_of(msg, wp, dpi, &logical_x, &logical_y) !=
        0) {
      return 0; /* SPI 读不到 = 这一格没有出处，丢掉 */
    }
    delta_x = (logical_x * dpi + 48) / 96;
    delta_y = (logical_y * dpi + 48) / 96;
    /* 视口只按自己的 axis 滚：纵向视口吃 dy，横向吃 dx，另一半别乱动。 */
    if ((GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_VSCROLL) != 0) {
      delta_x = 0;
    } else if ((GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_HSCROLL) != 0) {
      delta_y = 0;
    }
  }

  if (delta_x == 0 && delta_y == 0) {
    return 1; /* 认得但没动（到边了 / 0 格），也别再转发 */
  }
  off_x += delta_x;
  off_y += delta_y;
  if (off_x < 0) {
    off_x = 0;
  }
  if (off_y < 0) {
    off_y = 0;
  }
  /* 上界用 SCROLLINFO 现读一次（滚轮路没在上面读过）：末位减页才是最大偏移。 */
  si.cbSize = (UINT)sizeof(si);
  si.fMask = SIF_RANGE | SIF_PAGE;
  if (GetScrollInfo(hwnd, bar, &si) != 0) {
    max_h = si.nMax - si.nMin - (int)si.nPage + 1;
    if (max_h < 0) {
      max_h = 0;
    }
  }
  if (bar == SB_VERT && off_y > max_h) {
    off_y = max_h;
  } else if (bar == SB_HORZ && off_x > max_h) {
    off_x = max_h;
  }
  /* 改 offset → 平移子控件 → 同步滚动条位置，三件事一次做完。
   * shift 用"旧 offset - 新 offset"（= -(新-旧)）：到边 clamp 后真正挪的是
   * 差分而非请求的 delta，与 set_bounds 的减法同一坐标空间。 */
  moonui_native_scroll_set_offset(scroll, off_x, off_y);
  moonui_native_scroll_shift_children(scroll, orig_x - off_x, orig_y - off_y);
  si.cbSize = (UINT)sizeof(si);
  si.fMask = SIF_POS;
  si.nPos = (bar == SB_VERT) ? off_y : off_x;
  SetScrollInfo(hwnd, bar, &si, TRUE);
  /* 平移后擦掉子控件离开的那块（残影根因，见 moonui_native_scroll_erase）。 */
  moonui_native_scroll_erase(hwnd);
  return 1;
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
            /* 修饰键当场记（`T102` 第二十三刀）：默认 GetKeyState（返回"正在
             * 处理的那条消息"时刻的状态，与消息同源）；测试的合成注入走
             * synth 覆盖（合成消息改不了真键盘状态）。 */
            moonui_native_mouse_mods_val =
                moonui_native_synth_mouse_mods >= 0
                    ? moonui_native_synth_mouse_mods
                    : moonui_native_mods_of_state();
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

/* 同一颗鼠标事件里的修饰键，四位打包（bit0 ctrl / bit1 alt / bit2 shift /
 * bit3 meta），与键盘那半 `moonui_native_key_modifiers` 同一张表。Windows 半
 * 从 GetKeyState 读（`T102` 第二十三刀）。 */
int moonui_native_mouse_mods(void) {
  TRACE("mouse_mods");
  return moonui_native_mouse_mods_val;
}

/* 合成鼠标事件的修饰键覆盖（mac 半同款，`T102` 第二十三刀）：-1 恢复读
 * GetKeyState，>= 0 钩子按这四位打包记账。 */
void moonui_native_synth_mouse_mods_set(int mods) {
  TRACE("synth_mouse_mods_set");
  moonui_native_synth_mouse_mods = mods;
}

/* 第二本账（`T102` 第十二刀）：Windows 的 target 本来就落在命中控件上，滚轮
 * 也报控件（WM_MOUSEWHEEL 走的是控件窗口过程），所以这里恒 0 —— MoonBit 侧
 * 只在它是自绘面时才改判，恒 0 即"不改判"，与改动前的行为一致。 */
moonui_ptr moonui_native_mouse_owner(void) {
  TRACE("mouse_owner");
  return 0;
}

int64_t moonui_native_mouse_pos(void) {
  TRACE("mouse_pos");
  return moonui_native_pack2(moonui_native_mouse_px, moonui_native_mouse_py);
}

int64_t moonui_native_mouse_delta(void) {
  TRACE("mouse_delta");
  return moonui_native_pack2(moonui_native_mouse_ldx, moonui_native_mouse_ldy);
}

/* ---- 触控板手势（`T100`，契约在 adapter.h 手势段；Windows 半 `T106`）----
 *
 * Win32 的手势口是 WM_GESTURE：lParam 是一只 HGESTUREINFO（GetGestureInfo
 * 解出 GESTUREINFO、CloseGestureInfo 收尾），dwID 分 GID_ZOOM / GID_ROTATE /
 * GID_PAN 等。这边接两支：
 *   - GID_ZOOM → kind 0（捏合）：ullArguments 是**自 GF_BEGIN 起的累计缩放比
 *     ×65536**（1.0 = 65536），ABI 要的是步进增量（"1 + d"），累计账在这里记、
 *     GF_BEGIN 时归零重起。
 *   - GID_ROTATE → kind 1（旋转）：ullArguments 是自 GF_BEGIN 起的累计角度
 *     ×100（1/100 度，winuser.h 的 GID_ROTATE_ANGLE_FROM_ARGUMENT 取低 32 位），
 *     换算成弧度在 C 里做完（adapter.h：与鼠标 delta 同一条"换算是 C 的事"），
 *     同样按步进增量报。
 * GID_PAN 不接：Win32 的 pan 是**连续**双指拖动，mac 的 swipe 是**离散**事件
 * ——把 pan 硬翻成 swipe 会把一条拖动报成几十次滑动，语义不对；Windows 因此
 * 恒不产 kind 2（平台差异记在 adapter.h），swipe 那支脚手架直走 dispatch 只
 * 验共享层翻译。相位三档沿 GF_BEGIN/GF_END（WM_GESTURE 没有 cancelled 档）。
 * SetGestureConfig 在建窗时逐窗口开 GID_ZOOM/GID_ROTATE（默认配置里旋转是关的）。
 * 手势是整窗的：WM_GESTURE 落到顶层窗口过程，命中反查按 ptsLocation（屏幕
 * 坐标）→ 客户区坐标走 ChildWindowFromPoint + owner 链，落空报窗口自己
 * （adapter.h 手势段 target 那条）。 */

static moonui_closure_fn moonui_native_gesture_fn = 0;
static void *moonui_native_gesture_closure = 0;
static moonui_ptr moonui_native_gesture_target_ptr = 0;
static int moonui_native_gesture_kind_code = 0;
static int moonui_native_gesture_phase_code = 1;
static int moonui_native_gesture_direction_code = 0;
static int64_t moonui_native_gesture_value_micro = 0;
/* 捏合/旋转的累计账：Win32 给的是自 GF_BEGIN 起的累计量，ABI 要步进增量。 */
static int64_t moonui_native_gesture_zoom_total_micro = 1000000;
static int moonui_native_gesture_zoom_open = 0;
static int64_t moonui_native_gesture_rotate_total_micro = 0;
static int moonui_native_gesture_rotate_open = 0;

static void moonui_native_gesture_drop_closure(void) {
  if (moonui_native_gesture_closure != 0) {
    moonbit_decref(moonui_native_gesture_closure);
    moonui_native_gesture_closure = 0;
  }
  moonui_native_gesture_fn = 0;
}

/* 与产品路径共用的派发体（脚手架走同一条，mac 半同形）。 */
static void moonui_native_gesture_dispatch(moonui_ptr target, int kind,
                                           int phase, int direction,
                                           int64_t value_micro) {
  if (moonui_native_gesture_fn == 0) {
    return;
  }
  moonui_native_gesture_target_ptr = target;
  moonui_native_gesture_kind_code = kind;
  moonui_native_gesture_phase_code = phase;
  moonui_native_gesture_direction_code = direction;
  moonui_native_gesture_value_micro = value_micro;
  moonui_native_gesture_fn(moonui_native_gesture_closure);
}

/* GF_* 旗标 → 相位档（began/changed/ended；WM_GESTURE 没有 cancelled）。 */
static int moonui_native_gesture_phase_of(DWORD flags) {
  if ((flags & GF_BEGIN) != 0) {
    return 0;
  }
  if ((flags & GF_END) != 0) {
    return 2;
  }
  return 1;
}

/* 屏幕坐标 → 命中的"我们的控件"或窗口自己（adapter.h target 那条）。 */
static moonui_ptr moonui_native_gesture_hit(HWND win, POINT screen) {
  POINT client = screen;
  HWND hit;
  HWND up;
  ScreenToClient(win, &client);
  hit = ChildWindowFromPoint(win, client);
  if (hit != 0 && hit != win) {
    for (up = hit; up != 0 && up != win; up = GetParent(up)) {
      if (moonui_native_owner_of(up) != 0) {
        return moonui_native_owner_of(up);
      }
    }
  }
  return (moonui_ptr)(uintptr_t)win;
}

/* 一条解析后的手势走产品路径：GID_ZOOM/GID_ROTATE 的 ullArguments 定点换算 →
 * 累计账 → 命中归属 → dispatch。WM_GESTURE 处理器从 GetGestureInfo 出来调它
 * （dwID/dwFlags/ullArguments/屏幕坐标四样都取自 GESTUREINFO）；测试替投也
 * 直接进它——SendMessage/PostMessage 投不进 WM_GESTURE（user32 只认真输入
 * 管线，SendMessageW 返回 0 且窗口过程一无所知，2026-10-22 最小窗口量过），
 * 所以替投从"解析后"这一步注入，定点换算与累计账两条仍在测试覆盖里。
 * 返回 1 = 认识并消化了这个手势。 */
static int moonui_native_gesture_deliver(HWND hwnd, UINT id, DWORD flags,
                                         DWORD64 ull, POINT screen) {
  int phase = moonui_native_gesture_phase_of(flags);
  if (id == GID_ZOOM) {
    int64_t total = ((int64_t)ull * 1000000) / 65536;
    int64_t step;
    if (phase == 0 || !moonui_native_gesture_zoom_open) {
      moonui_native_gesture_zoom_open = 1;
      moonui_native_gesture_zoom_total_micro = 1000000;
    }
    step = total - moonui_native_gesture_zoom_total_micro;
    moonui_native_gesture_zoom_total_micro = total;
    if (phase == 2) {
      moonui_native_gesture_zoom_open = 0;
    }
    moonui_native_gesture_dispatch(
        moonui_native_gesture_hit(hwnd, screen), 0, phase, 0, step);
  } else if (id == GID_ROTATE) {
    /* GID_ROTATE 的 ullArguments 是 1/100 度（低 32 位有符号）；换算弧度在
     * C 里做完，1e-6 定点报 ABI。 */
    int64_t hundredths =
        (int64_t)(LONG)(ull & 0xFFFFFFFF);
    int64_t total = hundredths * 31416 / 1800000;
    int64_t step;
    if (phase == 0 || !moonui_native_gesture_rotate_open) {
      moonui_native_gesture_rotate_open = 1;
      moonui_native_gesture_rotate_total_micro = 0;
    }
    step = total - moonui_native_gesture_rotate_total_micro;
    moonui_native_gesture_rotate_total_micro = total;
    if (phase == 2) {
      moonui_native_gesture_rotate_open = 0;
    }
    moonui_native_gesture_dispatch(
        moonui_native_gesture_hit(hwnd, screen), 1, phase, 0, step);
  } else {
    /* 其它手势（PAN/TWOFINGERTAP/…）不接。 */
    return 0;
  }
  return 1;
}

/* WM_GESTURE 的实体：解 GESTUREINFO，交 deliver。返回 1 = 消化了（调用方
 * 不用再传默认过程）。 */
static int moonui_native_gesture_handle(HWND hwnd, LPARAM lp) {
  GESTUREINFO gi;
  POINT pt;
  ZeroMemory(&gi, sizeof(gi));
  gi.cbSize = sizeof(gi);
  if (GetGestureInfo((HGESTUREINFO)lp, &gi) == 0) {
    return 0;
  }
  pt.x = (LONG)gi.ptsLocation.x;
  pt.y = (LONG)gi.ptsLocation.y;
  {
    int consumed = moonui_native_gesture_deliver(hwnd, gi.dwID, gi.dwFlags,
                                                 gi.ullArguments, pt);
    CloseGestureInfoHandle((HGESTUREINFO)lp);
    return consumed;
  }
}

int moonui_native_on_gesture(moonui_closure_fn fn, void *closure) {
  TRACE("on_gesture");
  moonui_native_gesture_drop_closure();
  moonui_native_gesture_fn = fn;
  moonui_native_gesture_closure = closure;
  if (closure != 0) {
    moonbit_incref(closure);
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

/* ---- 手势的测试替投（`T106`；与 mac 半同一套判据，路数不同）----
 *
 * Windows 量过的事实：WM_GESTURE 合成不进去——SendMessageW/PostMessageW 都
 * 被用户态拒收（返回 0，窗口过程一无所知；user32 只认真触控管线的投递），
 * 所以 zoom/rotate 的替投不走消息，改为像 mac 那三支一样从"解析后"注入：
 * 先把 value_micro 累成 GID_* 的 ullArguments 原始口径（zoom ×65536、rotate
 * 1/100 度，产品换算的逆运算），再直接进 moonui_native_gesture_deliver
 * ——定点换算、累计账、命中归属、dispatch 全条产品路径都被跑到，只有
 * GetGestureInfo 那只句柄留在真手指验证；swipe 在 Win32 没有对应物（pan 是
 * 连续拖动，语义不对），同样直走 deliver 只验共享层翻译。
 * 坐标口径同 click_button_in_window（客户区左上原点、物理像素）。 */

static int moonui_native_gesture_deliver_client(HWND win, POINT client,
                                                UINT id, DWORD flags,
                                                DWORD64 ull) {
  POINT screen = client;
  ClientToScreen(win, &screen);
  return moonui_native_gesture_deliver(win, id, flags, ull, screen);
}

static int moonui_native_gesture_scaffold_target(
    const char *title, int title_len, int x, int y, POINT *out_client) {
  HWND win = moonui_native_find_window(title, title_len);
  RECT rc;
  POINT pt;
  if (win == 0) {
    return -2;
  }
  if (!GetClientRect(win, &rc)) {
    return -3;
  }
  pt.x = x;
  pt.y = y;
  if (x < rc.left || x >= rc.right || y < rc.top || y >= rc.bottom) {
    return -3;
  }
  *out_client = pt;
  return 0;
}

int moonui_native_magnify_in_window(const char *title, int title_len, int x,
                                    int y, int64_t value_micro, int phase) {
  POINT client;
  int rc = moonui_native_gesture_scaffold_target(title, title_len, x, y, &client);
  HWND win;
  DWORD flags;
  static int64_t cum_micro = 1000000;
  if (rc != 0) {
    return rc;
  }
  win = moonui_native_find_window(title, title_len);
  if (phase == 0) {
    cum_micro = 1000000;
  }
  cum_micro += value_micro;
  flags = phase == 0 ? GF_BEGIN : (phase == 2 ? GF_END : 0);
  return moonui_native_gesture_deliver_client(win, client, GID_ZOOM, flags,
                                              (DWORD64)((cum_micro * 65536) /
                                                        1000000)) == 1
             ? 0
             : -4;
}

int moonui_native_rotate_in_window(const char *title, int title_len, int x,
                                   int y, int64_t value_micro, int phase) {
  POINT client;
  int rc = moonui_native_gesture_scaffold_target(title, title_len, x, y, &client);
  HWND win;
  DWORD flags;
  /* 产品侧换算的逆：micro 弧度 → 1/100 度。两个方向共用
   * "31416/1800000" 的比例因子，往返一致性由测试断言钉住。 */
  static int64_t cum_micro = 0;
  if (rc != 0) {
    return rc;
  }
  win = moonui_native_find_window(title, title_len);
  if (phase == 0) {
    cum_micro = 0;
  }
  cum_micro += value_micro;
  flags = phase == 0 ? GF_BEGIN : (phase == 2 ? GF_END : 0);
  return moonui_native_gesture_deliver_client(win, client, GID_ROTATE, flags,
                                              (DWORD64)((cum_micro * 1800000) /
                                                        31416)) == 1
             ? 0
             : -4;
}

int moonui_native_swipe_in_window(const char *title, int title_len, int x,
                                  int y, int direction) {
  POINT client;
  int rc = moonui_native_gesture_scaffold_target(title, title_len, x, y, &client);
  HWND win;
  moonui_ptr target;
  if (rc != 0) {
    return rc;
  }
  win = moonui_native_find_window(title, title_len);
  target = moonui_native_gesture_hit(win, client);
  moonui_native_gesture_dispatch(target, 2, 1, direction, 0);
  return 0;
}

/* ---- 平台 WebView（`T102` 第二十五刀，契约在 adapter.h WebView 段）----
 *
 * Windows 半如实缺席：没有 WebView 控件（widget_new 的 kind 19 没有分支，
 * 落 default 建不出控件，MoonBit 侧 register 就报 OperationFailed，走不到
 * 这里），所以五条口子全是缺席形状——监听报 -1（装不上静默，与 mac 半
 * "控件建不出来监听没有服务对象"同一条规矩的另一头：这边控件根本不存在，
 * 监听同样没有服务对象）、读回恒空、装载报 -2（平台没有桥）。真接要等
 * Windows 半选定宿主（WebView2 / MSHTML），到时在原位换成真实现，
 * MoonBit 侧不动。 */

int moonui_native_on_webview(moonui_closure_fn fn, void *closure) {
  (void)fn;
  (void)closure;
  TRACE("on_webview");
  return -1;
}

moonui_ptr moonui_native_webview_target(void) {
  TRACE("webview_target");
  return 0;
}

int moonui_native_webview_phase(void) {
  TRACE("webview_phase");
  return 0;
}

moonbit_bytes_t moonui_native_webview_detail(void) {
  TRACE("webview_detail");
  return moonbit_make_bytes(0, 0);
}

int moonui_native_webview_load(moonui_ptr w, const char *source,
                               int source_len, int is_html) {
  (void)w;
  (void)source;
  (void)source_len;
  (void)is_html;
  TRACE("webview_load");
  return -2;
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

int moonui_native_quit_requested(void) {
  return moonui_native_loop_ended;
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

/* ---- 输入法组合的真窗替投（`T90①` Windows 半）----
 *
 * 与 mac 半的 ime_compose/commit_in_window 同一套判据阶梯，路数不同：mac
 * 直接调 NSTextInputClient 那两个真方法；Windows 这边"输入法"是 IMM32 +
 * 系统键盘布局里的真 IME，脚手架替它经 ImmSetCompositionStringW(SCS_SETSTR)
 * 把组合串写进输入上下文——真 IME 随后自己发 WM_IME_STARTCOMPOSITION（切换
 * 沿）与 WM_IME_COMPOSITION(GCS_COMPSTR)，产品代码（EDIT 子类过程）在
 * **真消息**的处理间隙里当场经 ImmGetContext/ImmGetCompositionStringW 读回
 * 同一串：ImmGetContext 的"消息间隙"前提、GCS_COMPSTR 字节计数（快照多给
 * 一格 WCHAR 兜 NUL）都在这条真序列上过秤。实测注（2026-10-22）：写入是
 * 异步生效——Set 返回后立刻读回是 0 字节，得先泵一圈消息让 IME 处理掉，
 * 所以脚手架每步之后带一圈有界泵。
 * 上屏（commit）走 ImmNotifyIME(NI_COMPOSITIONSTR, CPS_COMPLETE)——真输入法
 * 定稿的同一入口：IME 发 WM_IME_COMPOSITION(GCS_RESULTSTR)，系统 EDIT 把
 * 结果串插进正文（EN_CHANGE 同步回流 Core）；text 空串 = 取消（CPS_CANCEL，
 * 组合撤掉不留痕）。WM_CHAR 兜底只在"系统没插"时补敲（正常不该走到）。
 * 顺带复证 T90③：每条 WM_IME_* 都过 CallWindowProcW 原过程，与 type_text
 * 的 WM_CHAR 通道并存不打架。
 * 返回码：0 成功；-1 编码失败；-2 找不到窗口；-3 命中处不是子窗口；
 * -4 命中的不是编辑控件；-5 拿不到输入上下文。 */

/* 定位 + 焦点：坐标命中必须是 kind 2/4/10 的编辑控件。 */
static int moonui_native_ime_scaffold_target(const char *title, int title_len,
                                             int x, int y, HWND *out) {
  POINT pt;
  HWND win;
  HWND hit;
  int kind;
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
  kind = moonui_native_kind_of_hwnd(hit);
  if (kind != 2 && kind != 4 && kind != 10) {
    return -4;
  }
  SetFocus(hit);
  *out = hit;
  return 0;
}

/* 有界消息泵：IME 对 ImmSetCompositionString/ImmNotifyIME 的反应是异步的
 * 一批投递消息，泵到队列空为止（带墙钟上限防挂）。 */
static void moonui_native_ime_pump(int budget_ms) {
  MSG msg;
  ULONGLONG deadline = GetTickCount64() + (ULONGLONG)budget_ms;
  while (GetTickCount64() < deadline) {
    if (!PeekMessageW(&msg, 0, 0, 0, PM_REMOVE)) {
      return;
    }
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
}

/* 等价于"输入法正在组合，组合串是 text"：串写进上下文，IME 自己发切换沿
 * 与进行通知（首步各一条，加深只一条进行——真输入法同一节拍）。 */
int moonui_native_ime_compose_in_window(const char *title, int title_len,
                                        int x, int y, const char *text,
                                        int text_len) {
  HWND edit;
  HIMC ctx;
  LPWSTR w;
  int rc;
  TRACE("ime_compose_in_window");
  rc = moonui_native_ime_scaffold_target(title, title_len, x, y, &edit);
  if (rc != 0) {
    return rc;
  }
  w = moonui_native_utf16_of(text, text_len);
  if (w == 0) {
    return -1;
  }
  ctx = ImmGetContext(edit);
  if (ctx == 0) {
    free(w);
    return -5;
  }
  ImmSetCompositionStringW(ctx, SCS_SETSTR, w,
                           (LONG)(lstrlenW(w) * sizeof(WCHAR)), 0, 0);
  ImmReleaseContext(edit, ctx);
  free(w);
  moonui_native_ime_pump(200);
  return 0;
}

/* 等价于"输入法上屏"：CPS_COMPLETE 定稿当前组合串（系统 EDIT 把结果串插进
 * 正文），text 空串 = 取消（CPS_CANCEL，不留痕）。 */
int moonui_native_ime_commit_in_window(const char *title, int title_len,
                                       int x, int y, const char *text,
                                       int text_len) {
  HWND edit;
  HIMC ctx;
  LPWSTR w;
  int before;
  int rc;
  TRACE("ime_commit_in_window");
  rc = moonui_native_ime_scaffold_target(title, title_len, x, y, &edit);
  if (rc != 0) {
    return rc;
  }
  w = moonui_native_utf16_of(text, text_len);
  if (w == 0) {
    return -1;
  }
  ctx = ImmGetContext(edit);
  if (ctx == 0) {
    free(w);
    return -5;
  }
  before = (int)GetWindowTextLengthW(edit);
  ImmNotifyIME(ctx, NI_COMPOSITIONSTR,
               lstrlenW(w) == 0 ? CPS_CANCEL : CPS_COMPLETE, 0);
  ImmReleaseContext(edit, ctx);
  moonui_native_ime_pump(200);
  if (lstrlenW(w) > 0 && (int)GetWindowTextLengthW(edit) == before) {
    /* 兜底：系统 EDIT 没走 GCS_RESULTSTR 插入（不该发生），按打字正门补敲，
     * 让"上屏全文"至少落进文本通道。 */
    int i;
    int len = lstrlenW(w);
    SendMessageW(edit, EM_SETSEL, (WPARAM)before, (LPARAM)before);
    for (i = 0; i < len; ++i) {
      SendMessageW(edit, WM_CHAR, (WPARAM)w[i], 1);
    }
  }
  free(w);
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
  /* 指针捕获（`T102` 第十三刀 / `T111`）：真手指按住时系统把后续移动/抬起
   * 投给捕获窗口、不再看坐标底下是谁，脚手架照这条路由——GetCapture 在手
   * （且是我们窗口树里的），跳过坐标命中直接投给它，坐标按它的客户区换算
   * （拖出控件时是负数，真人按住时系统给的正是这种数）。 */
  {
    HWND cap = GetCapture();
    if (cap != 0 && GetAncestor(cap, GA_ROOT) == win &&
        moonui_native_owner_of(cap) != 0) {
      hit = cap;
    } else {
      hit = ChildWindowFromPoint(win, pt);
    }
  }
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

/* 造一个"按住不放"的拖动（`T148`/`T149` Windows 半）：SendMessage 把鼠标
 * 三件套当场递进命中的轨道条自己的窗口过程——按下就地进拖动态、SetCapture
 * 在手，移动逐条推进。send_mouse_in_window 干不了这活：它的按下是"按下+抬起"
 * 一对（为的是 BN_CLICKED 那条账），造不出"按住"。
 *
 * kind_button 沿用 send_mouse_in_window 的编码子集（kind*8）：
 *   0 = 按下（在给定点）、1 = 抬起、2 = 移动、3 = 按下（**在拇指上**）。
 * kind 3 之所以单独存在：comctl 轨道条对**离拇指**的按下走"翻页"而不是
 * "跳到点击处再拖"（真机实测：点通道中段一下只进一格页步 200/1000，之后
 * 每条移动再进一格），要造"拖"必须按住拇指本尊——真手拖动也是抓着拇指走的。
 * kind 3 返回按下的拇指圆心 x（控件客户区物理像素），调用方可以顺手核对。
 *
 * 钩子看不见 SendMessage（与 click_custom_in_window 同一条边界）；changed
 * 回流走的是轨道条拖动中自己发给父窗口的 WM_HSCROLL——真人拖动同一条
 * 生产路径，钩子本来也不在这条路上。
 * 返回 0 = 已递进（kind 3 见上）；-2 窗口没找到；-3 点在客户区外；-4 命中
 * 处不是打了标记的控件；-5 编码不认识。返回码与 send_mouse_in_window 同形。 */
int64_t moonui_native_slider_drag_in_window(const char *title, int title_len,
                                            int kind_button, int x, int y) {
  HWND win;
  HWND hit;
  POINT pt;
  UINT msg;
  WPARAM wp;
  int kind = kind_button / 8;
  TRACE("slider_drag_in_window");
  if (kind_button < 0 || kind_button % 8 != 0 || kind > 3) {
    return -5;
  }
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  if (kind == 3) {
    /* 按住拇指：拇指框问轨道条自己（TBM_GETTHUMBRECT），圆心就在框中央。 */
    RECT thumb;
    RECT rc;
    int cx;
    int cy;
    HWND up;
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
    if (moonui_native_kind_of_hwnd(hit) != 6) {
      return -4;
    }
    ZeroMemory(&thumb, sizeof(thumb));
    SendMessageW(hit, TBM_GETTHUMBRECT, 0, (LPARAM)&thumb);
    if (thumb.right <= thumb.left) {
      return -1;
    }
    if (GetClientRect(hit, &rc) == 0) {
      return -1;
    }
    cx = (thumb.left + thumb.right) / 2;
    cy = (rc.bottom - rc.top) / 2;
    SendMessageW(hit, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(cx, cy));
    return cx;
  }
  pt.x = x;
  pt.y = y;
  /* 捕获在手（拖动进行中）时按 send_mouse_in_window 同一条路由：真手指
   * 按住时系统把后续移动/抬起投给捕获窗口、不看坐标底下是谁——这里也得
   * 这么走，否则落点会被拖动途中浮出来的 TBS_TOOLTIPS 提示挡一下（真机
   * 实测：移动到拇指附近那条 -4 就是它）。 */
  {
    HWND cap = GetCapture();
    if (cap != 0 && GetAncestor(cap, GA_ROOT) == win &&
        moonui_native_owner_of(cap) != 0) {
      hit = cap;
    } else {
      hit = ChildWindowFromPoint(win, pt);
    }
  }
  if (hit == 0) {
    return -3;
  }
  {
    HWND up;
    for (up = hit; up != 0 && up != win && moonui_native_owner_of(up) == 0;
         up = GetParent(up)) {
    }
    if (up == 0 || up == win || moonui_native_owner_of(up) == 0) {
      return -4;
    }
  }
  ClientToScreen(win, &pt);
  ScreenToClient(hit, &pt);
  switch (kind) {
    case 0:
      msg = WM_LBUTTONDOWN;
      wp = MK_LBUTTON;
      break;
    case 1:
      msg = WM_LBUTTONUP;
      wp = 0;
      break;
    default:
      msg = WM_MOUSEMOVE;
      wp = MK_LBUTTON;
      break;
  }
  SendMessageW(hit, msg, wp, MAKELPARAM(pt.x, pt.y));
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

/* ---- 托盘与通知（`T86⑥`，Windows 半）----
 *
 * Shell_NotifyIcon 那半照挂账口径：真代码、只到 mingw 语法闸门（Windows 这一批
 * 的真跑统一欠账挂报告）。托盘是进程级单例（一个应用一只 NOTIFYICONDATA）：
 *   - 图标：NOTIFYICONDATAW 的 NIM_ADD 起头、之后 NIM_MODIFY 换图；图标沿
 *     `moonui_set_app_icon` 的 stem 约定，这里补 ".ico"（LR_LOADFROMFILE 只认
 *     ICO，与窗口图标那条同一个形状）。uCallbackMessage 是 MOONUI_TRAY_MSG。
 *   - 菜单：树沿菜单栏那套读游标现建 popup 存着（与上下文菜单同一套"建→取
 *     第一个顶层的 popup"），park 窗口收 MOONUI_TRAY_MSG 的左键抬起时弹
 *     （moonui_native_tray_show_menu，TPM_RETURNCMD + SetForegroundWindow 的
 *     经典两步）。选中语义沿 `T86⑥` 落地注记同步解析；勾选态点击后不回推，
 *     下一次装树照新快照画（与 mac 半同一条缺席）。
 *   - 通知：NIF_INFO 气球（NIM_MODIFY 的 szInfoTitle/szInfo）——投递请求交给
 *     系统即返回 0（气球本身异步）；没装过托盘时 -1（气球的载体就是托盘图标，
 *     没有托盘没有气球）。
 * 闭包是进程一份，与菜单栏/上下文菜单那两份独立（各弹各的菜单不互相换回调）。
 * 返回码：0 = 装上了 / 交出去了；-1 = 图标读不出来 / 树不合法 / 没托盘；
 * -2 = 还没初始化。 */

static NOTIFYICONDATAW moonui_native_tray_data;
static int moonui_native_tray_added = 0;
static HMENU moonui_native_tray_menu = 0;
static moonui_closure_id_fn moonui_native_tray_fn = 0;
static void *moonui_native_tray_closure = 0;

static void moonui_native_tray_drop_closure(void) {
  if (moonui_native_tray_added != 0) {
    Shell_NotifyIconW(NIM_DELETE, &moonui_native_tray_data);
    if (moonui_native_tray_data.hIcon != 0) {
      DestroyIcon(moonui_native_tray_data.hIcon);
      moonui_native_tray_data.hIcon = 0;
    }
    moonui_native_tray_added = 0;
  }
  if (moonui_native_tray_menu != 0) {
    DestroyMenu(moonui_native_tray_menu);
    moonui_native_tray_menu = 0;
  }
  if (moonui_native_tray_closure != 0) {
    moonbit_decref(moonui_native_tray_closure);
    moonui_native_tray_closure = 0;
  }
  moonui_native_tray_fn = 0;
}

void moonui_native_tray_show_menu(HWND hwnd) {
  POINT pt;
  int sel;
  if (moonui_native_tray_menu == 0) {
    return;
  }
  if (!GetCursorPos(&pt)) {
    return;
  }
  /* 弹出前把 owner 提到前台（TrackPopupMenu 的经典前置），返回后再还一次——
   * 不提的话菜单在鼠标松开的那一下就自己关掉。 */
  SetForegroundWindow(hwnd);
  sel = (int)TrackPopupMenuEx(moonui_native_tray_menu,
                              TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                              pt.x, pt.y, hwnd, 0);
  PostMessageW(hwnd, WM_NULL, 0, 0);
  /* 装进去的命令 id 是 Core 的 id + MOONUI_MENU_ID_BASE（menu_append_item），
   * 报给 Core 之前退掉基址（与上下文菜单同一条）。 */
  if (sel >= MOONUI_MENU_ID_BASE && moonui_native_tray_fn != 0 &&
      moonui_native_tray_closure != 0) {
    moonui_native_tray_fn(moonui_native_tray_closure,
                          sel - MOONUI_MENU_ID_BASE);
  }
}

int moonui_native_tray_set_icon(const char *name, int name_len) {
  LPWSTR stem;
  size_t n;
  LPWSTR path;
  HICON icon;
  TRACE("tray_set_icon");
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
  icon = (HICON)LoadImageW(0, path, IMAGE_ICON, 16, 16, LR_LOADFROMFILE);
  free(path);
  if (icon == 0) {
    return -1;
  }
  ZeroMemory(&moonui_native_tray_data, sizeof(moonui_native_tray_data));
  moonui_native_tray_data.cbSize = sizeof(moonui_native_tray_data);
  moonui_native_tray_data.hWnd = moonui_native_park;
  moonui_native_tray_data.uID = 1;
  moonui_native_tray_data.uFlags = NIF_MESSAGE | NIF_ICON;
  moonui_native_tray_data.uCallbackMessage = MOONUI_TRAY_MSG;
  moonui_native_tray_data.hIcon = icon;
  if (moonui_native_tray_added == 0) {
    if (Shell_NotifyIconW(NIM_ADD, &moonui_native_tray_data) == 0) {
      DestroyIcon(icon);
      return -1;
    }
    moonui_native_tray_added = 1;
  } else if (Shell_NotifyIconW(NIM_MODIFY, &moonui_native_tray_data) == 0) {
    DestroyIcon(icon);
    return -1;
  }
  return 0;
}

int moonui_native_tray_set_menu(const char *tree, int tree_len,
                         moonui_closure_id_fn fn, void *closure) {
  MoonuiTree t;
  HMENU bar;
  HMENU popup;
  TRACE("tray_set_menu");
  if (!moonui_native_inited) {
    return -2;
  }
  if (tree == 0 || tree_len < 5) {
    return -1;
  }
  moonui_native_tree_init(&t, tree, tree_len);
  bar = moonui_native_menu_build(&t);
  if (bar == 0 || t.bad) {
    if (bar != 0) {
      DestroyMenu(bar);
    }
    return -1;
  }
  popup = GetMenuItemCount(bar) > 0 ? GetSubMenu(bar, 0) : 0;
  if (popup == 0) {
    DestroyMenu(bar);
    return -1;
  }
  /* popup 从 bar 里摘出来再拆 bar：SetMenu 把 bar 连根拆掉会带走 popup。 */
  if (RemoveMenu(bar, 0, MF_BYPOSITION) == 0) {
    DestroyMenu(bar);
    return -1;
  }
  DestroyMenu(bar);
  if (moonui_native_tray_menu != 0) {
    DestroyMenu(moonui_native_tray_menu);
  }
  moonui_native_tray_menu = popup;
  /* 只换回调，不动图标那半（闭包回收是"换一次松一次"，与菜单栏同一套）。 */
  if (moonui_native_tray_closure != 0) {
    moonbit_decref(moonui_native_tray_closure);
    moonui_native_tray_closure = 0;
  }
  moonui_native_tray_fn = fn;
  moonui_native_tray_closure = closure;
  if (closure != 0) {
    moonbit_incref(closure);
  }
  return 0;
}

int moonui_native_notify(const char *title, int title_len,
                  const char *body, int body_len) {
  LPWSTR wtitle;
  LPWSTR wbody;
  TRACE("notify");
  if (!moonui_native_inited) {
    return -2;
  }
  if (moonui_native_tray_added == 0) {
    return -1;
  }
  wtitle = moonui_native_utf16_of(title, title_len);
  wbody = moonui_native_utf16_of(body, body_len);
  if (wtitle == 0 || wbody == 0) {
    free(wtitle);
    free(wbody);
    return -1;
  }
  /* 气球文本各放 64/256 WCHAR（shell64.h 的 NOTIFYICONDATAW 定宽），截断就地
   * 做——文案比系统限宽长的部分不假装投出去。 */
  moonui_native_tray_data.uFlags = NIF_INFO;
  wcsncpy(moonui_native_tray_data.szInfoTitle, wtitle,
          (size_t)64 - 1);
  moonui_native_tray_data.szInfoTitle[64 - 1] = L'\0';
  wcsncpy(moonui_native_tray_data.szInfo, wbody, (size_t)256 - 1);
  moonui_native_tray_data.szInfo[256 - 1] = L'\0';
  moonui_native_tray_data.dwInfoFlags = NIIF_INFO;
  free(wtitle);
  free(wbody);
  if (Shell_NotifyIconW(NIM_MODIFY, &moonui_native_tray_data) == 0) {
    return -1;
  }
  return 0;
}

/* 托盘探针（`T91⑥` Windows 半，adapter.h 有声明）：Shell_NotifyIcon 没有
 * "读回来"的口子，这里读自己的 NOTIFYICONDATAW 副本与托盘菜单——判据
 * "set_icon/set_menu/notify 的调用真走到了系统"由三步成立：调用返回 0、
 * 副本上各字段非零/到位、NIM_ADD/MODIFY 真 returned TRUE（不成功早已 -1）。
 * 打包与 mac 半同套（低 8 位三个存在位：bit0 托盘装上、bit1 图标在、bit2
 * 菜单在；8..23 位 = 菜单项数），另多打包 Windows 专属两项（定宽截断的
 * 复核口，见 adapter.h 注）：24..31 位 = szInfoTitle 的字符数、
 * 32..39 位 = szInfo 的字符数。没初始化时返回 0。 */
int64_t moonui_native_tray_probe(void) {
  int64_t bits = 0;
  if (!moonui_native_inited) {
    return 0;
  }
  if (moonui_native_tray_added != 0) {
    bits |= 1;
  }
  if (moonui_native_tray_data.hIcon != 0) {
    bits |= 2;
  }
  if (moonui_native_tray_menu != 0) {
    bits |= 4;
    bits |= (int64_t)(UINT8_MAX &
                      GetMenuItemCount(moonui_native_tray_menu)) << 8;
  }
  bits |= (int64_t)(UINT8_MAX &
                    (unsigned)lstrlenW(moonui_native_tray_data.szInfoTitle))
          << 24;
  bits |= (int64_t)(UINT8_MAX &
                    (unsigned)lstrlenW(moonui_native_tray_data.szInfo)) << 32;
  return bits;
}

/* ---- 文件拖入（`T86③` 第一期档案）：Windows 半走 DragAcceptFiles/WM_DROPFILES ----
 *
 * owner 2026-10-22 裁决：第一期范围"只做外部文件拖入"正好是 DragAcceptFiles
 * + WM_DROPFILES 的全部语义，顶上这条便宜路径（IDropTarget 的 DoP/DragOver
 * 协议、格式协商仍是第二期的账）。窗口在建窗时 DragAcceptFiles(hwnd, TRUE)，
 * 拖入经 WM_DROPFILES 落到顶层窗口过程：DragQueryFileW 逐条读路径、UTF-8
 * 打包成 adapter.h 的布局（i32 count, count × (i32 字节数, 内容)，小端），
 * 快照写好后调闭包——target/paths 由 MoonBit 侧读口当场取，与 mac 半同一条
 * 契约。接受门与 mac 半同形：监听没装（drop_fn 为 0）时消息照到、事件不发。 */

static moonui_closure_fn moonui_native_drop_fn = 0;
static void *moonui_native_drop_closure = 0;
static moonui_ptr moonui_native_drop_target_ptr = 0;
static char *moonui_native_drop_paths_bytes = 0;
static int moonui_native_drop_paths_len = 0;
static int moonui_native_drop_last_ok = 0;

static void moonui_native_drop_drop_closure(void) {
  if (moonui_native_drop_closure != 0) {
    moonbit_decref(moonui_native_drop_closure);
    moonui_native_drop_closure = 0;
  }
  moonui_native_drop_fn = 0;
}

static void moonui_native_drop_notify(moonui_ptr target, char *bytes,
                                      int len) {
  if (moonui_native_drop_fn == 0) {
    free(bytes);
    return;
  }
  moonui_native_drop_target_ptr = target;
  free(moonui_native_drop_paths_bytes);
  moonui_native_drop_paths_bytes = bytes;
  moonui_native_drop_paths_len = len;
  moonui_native_drop_fn(moonui_native_drop_closure);
}

/* WM_DROPFILES 的实体：读 HDROP、打包、通知。通知成功置 last_ok（探针
 * bit2 的账）。 */
static void moonui_native_drop_take(HWND hwnd, HDROP drop) {
  UINT count;
  UINT i;
  UINT got;
  char *packed;
  int cap;
  int len;
  int count_ok = 0;
  count = DragQueryFileW(drop, 0xFFFFFFFF, 0, 0);
  if (count == 0 || moonui_native_drop_fn == 0) {
    DragFinish(drop);
    return;
  }
  /* 打包布局：4 + Σ(4 + 字节数)。容量先按最坏 (DragQueryFileW 报的字符数
   * ×3) 估一轮，写的时候再逐条校。 */
  cap = 16;
  for (i = 0; i < count; ++i) {
    cap += 4 + (int)DragQueryFileW(drop, i, 0, 0) * 4;
  }
  packed = (char *)malloc((size_t)cap);
  if (packed == 0) {
    DragFinish(drop);
    return;
  }
  len = 0;
#define MOONUI_PUT32(v)                    \
  do {                                     \
    if (len + 4 > cap) {                   \
      goto overflow;                       \
    }                                      \
    packed[len] = (char)((v) & 0xFF);      \
    packed[len + 1] = (char)(((v) >> 8) & 0xFF);   \
    packed[len + 2] = (char)(((v) >> 16) & 0xFF);  \
    packed[len + 3] = (char)(((v) >> 24) & 0xFF);  \
    len += 4;                              \
  } while (0)
  MOONUI_PUT32(0); /* 计数先占位，收尾回写 */
  for (i = 0; i < count; ++i) {
    UINT wchar_cap = DragQueryFileW(drop, i, 0, 0) + 1;
    WCHAR *w = (WCHAR *)malloc((size_t)wchar_cap * sizeof(WCHAR));
    char *u8;
    int n;
    if (w == 0) {
      continue;
    }
    got = DragQueryFileW(drop, i, w, wchar_cap);
    if (got == 0) {
      free(w);
      continue;
    }
    u8 = moonui_native_utf8_of(w);
    free(w);
    if (u8 == 0) {
      continue;
    }
    n = (int)strlen(u8);
    if (len + 4 + n > cap) {
      free(u8);
      goto overflow;
    }
    MOONUI_PUT32(n);
    memcpy(packed + len, u8, (size_t)n);
    len += n;
    free(u8);
    ++count_ok;
  }
  /* 回写计数（小端）。 */
  packed[0] = (char)(count_ok & 0xFF);
  packed[1] = (char)((count_ok >> 8) & 0xFF);
  packed[2] = (char)((count_ok >> 16) & 0xFF);
  packed[3] = (char)((count_ok >> 24) & 0xFF);
  if (count_ok > 0) {
    moonui_native_drop_notify((moonui_ptr)(uintptr_t)hwnd, packed, len);
    moonui_native_drop_last_ok = 1;
  } else {
    free(packed);
  }
  DragFinish(drop);
  return;
overflow:
  free(packed);
  DragFinish(drop);
}
#undef MOONUI_PUT32

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

moonui_ptr moonui_native_file_drop_target(void) {
  TRACE("file_drop_target");
  return moonui_native_drop_target_ptr;
}

moonbit_bytes_t moonui_native_file_drop_paths(void) {
  moonbit_bytes_t out;
  TRACE("file_drop_paths");
  if (moonui_native_drop_paths_bytes == 0) {
    return moonbit_make_bytes(0, 0);
  }
  out = moonbit_make_bytes(moonui_native_drop_paths_len, 0);
  if (moonui_native_drop_paths_len > 0) {
    memcpy(out, moonui_native_drop_paths_bytes,
           (size_t)moonui_native_drop_paths_len);
  }
  return out;
}

/* ---- 文件拖入的测试替投与探针（`T91③` Windows 半）----
 *
 * 本机 SDK 的 shellapi.h 不带 DROPFILES（DragQueryFileW 认的那只内存布局），
 * 自己摆一只同形的：DWORD pFiles + POINT + BOOL fNC + BOOL fWide，20 字节。 */
typedef struct {
  DWORD pFiles;
  POINT pt;
  BOOL fNC;
  BOOL fWide;
} MoonuiDropfiles;

/* 替投"松手那一刻"：把路径串（'\n' 分隔）拼成一只内存里的 DROPFILES
 * （fWide=1、双 NUL 收尾），SendMessage 当 HDROP 投给标题命中的那只顶层
 * 窗——DragQueryFileW 读的就是这只内存结构（标准测试形状，shell32 的
 * 读路径与真拖同一套）。探针三位与 mac 半同义：bit0 监听装着、
 * bit1 = 窗口真带 WS_EX_ACCEPTFILES（DragAcceptFiles 落没落由系统样式
 * 自己作证）、bit2 = 上一次替投真被接住。 */

int moonui_native_simulate_file_drop(const char *title, int title_len,
                              const char *paths, int paths_len) {
  HWND win;
  char *all;
  LPWSTR *list;
  int list_len = 0;
  int i;
  size_t wide_bytes = 0;
  MoonuiDropfiles *df;
  int offset;
  TRACE("simulate_file_drop");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  all = moonui_native_dup(paths, paths_len);
  if (all == 0) {
    return -1;
  }
  /* 拆行、逐条 UTF-16。路径里没有换行（测试自己的编码，同 mac 半）。 */
  list = (LPWSTR *)malloc(sizeof(LPWSTR) * (size_t)(paths_len + 1));
  if (list == 0) {
    free(all);
    return -1;
  }
  {
    char *cursor = all;
    while (*cursor != '\0') {
      char *nl = strchr(cursor, '\n');
      LPWSTR w;
      if (nl != 0) {
        *nl = '\0';
      }
      if (*cursor != '\0') {
        w = moonui_native_utf16_of(cursor, (int)strlen(cursor));
        if (w != 0) {
          list[list_len++] = w;
          wide_bytes += (wcslen(w) + 1) * sizeof(WCHAR);
        }
      }
      if (nl == 0) {
        break;
      }
      cursor = nl + 1;
    }
  }
  free(all);
  if (list_len == 0) {
    for (i = 0; i < list_len; ++i) {
      free(list[i]);
    }
    free(list);
    return -1;
  }
  /* DROPFILES 头（20 字节，fWide=1）+ 各条 wide 串 + 收尾双 NUL。 */
  /* 内存的 DROPFILES 要以 HGLOBAL（GMEM_MOVEABLE）为载体：
   * 处理体收尾的 DragFinish 对 HDROP 做的就是 GlobalFree——
   * 用 malloc/calloc 摆这只结构会在释放时扒坏堆（T91④
   * 真跑咬出）。 */
  {
    HGLOBAL glob = GlobalAlloc(GMEM_MOVEABLE,
                               sizeof(MoonuiDropfiles) + wide_bytes +
                                 sizeof(WCHAR) * 2);
    char *mem;
    if (glob == 0) {
      for (i = 0; i < list_len; ++i) {
        free(list[i]);
      }
      free(list);
      return -1;
    }
    mem = (char *)GlobalLock(glob);
    if (mem == 0) {
      GlobalFree(glob);
      for (i = 0; i < list_len; ++i) {
        free(list[i]);
      }
      free(list);
      return -1;
    }
    memset(mem, 0, sizeof(MoonuiDropfiles) + wide_bytes + sizeof(WCHAR) * 2);
    df = (MoonuiDropfiles *)mem;
    df->pFiles = sizeof(MoonuiDropfiles);
    df->fWide = TRUE;
    offset = (int)sizeof(MoonuiDropfiles);
    for (i = 0; i < list_len; ++i) {
      size_t n = (wcslen(list[i]) + 1) * sizeof(WCHAR);
      memcpy(mem + offset, list[i], n);
      offset += (int)n;
      free(list[i]);
    }
    free(list);
    GlobalUnlock(glob);
    moonui_native_drop_last_ok = 0;
    SendMessageW(win, WM_DROPFILES, (WPARAM)(uintptr_t)glob, 0);
  }
  return 0;
}

int64_t moonui_native_file_drop_probe(const char *title, int title_len) {
  HWND win;
  int64_t bits = 0;
  TRACE("file_drop_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  if (moonui_native_drop_fn != 0) {
    bits |= 1;
  }
  if ((GetWindowLongW(win, GWL_EXSTYLE) & WS_EX_ACCEPTFILES) != 0) {
    bits |= 2;
  }
  if (moonui_native_drop_last_ok != 0) {
    bits |= 4;
  }
  return bits;
}

/* ---- worker 与跨线程投递（`T85①`，adapter.h 的 worker 段注）----
 *
 * worker 是平台线程（CreateThread 一小段；为什么不是 MoonBit 侧一条、引用回收
 * 为什么统一在接收侧，都记在 adapter.h 的段注里）。一次投递一次线程，生命周期
 * 归 worker 自己：线程函数返回即退场，spawn 侧 CloseHandle 只释放句柄不终止
 * 线程——契约是 work 必须返回。没有挂起表、没有取消口，两支闭包的引用都在
 * spawn 侧 incref、在各自的执行点回收（work 那份由 worker 回收、land 那份由
 * 顶层窗口过程的 MOONUI_WORK_MSG 回收）；跨界递增递减的形状由 pthread 探针
 * 钉过（tests/ffi 的同形测试）。 */

typedef struct {
  moonui_closure_fn work_call;
  void *work_closure;
  moonui_closure_fn land_call;
  void *land_closure;
} MoonuiWorkerParams;

static DWORD WINAPI moonui_worker_main(LPVOID arg) {
  MoonuiWorkerParams *p = (MoonuiWorkerParams *)arg;
  moonui_closure_fn land_call;
  void *land_closure;
  p->work_call(p->work_closure);
  moonbit_decref(p->work_closure);
  land_call = p->land_call;
  land_closure = p->land_closure;
  free(p);
  /* 落地投回主线程：park 窗口收 MOONUI_WORK_MSG，顶层窗口过程在 UI 线程的
   * 消息泵里执行 land 闭包并回收 land 那份引用——落地动作是 MoonBit 侧的
   * app.post（排队、下一圈且排在事件前）。PostMessage 失败（队列满）时 land
   * 永远不会运行，这里就地退干净。 */
  if (moonui_native_park != 0 &&
      PostMessageW(moonui_native_park, MOONUI_WORK_MSG,
                   (WPARAM)(uintptr_t)land_call, (LPARAM)(uintptr_t)land_closure)) {
    return 0;
  }
  moonbit_decref(land_closure);
  return 0;
}

int moonui_native_worker_run(moonui_closure_fn work_call, void *work_closure,
                             moonui_closure_fn land_call, void *land_closure) {
  HANDLE thread;
  MoonuiWorkerParams *p;
  TRACE("worker_run");
  if (work_call == 0 || work_closure == 0 || land_call == 0 || land_closure == 0) {
    return -1;
  }
  /* 两支闭包都由这条机制看守（Win32 只收函数指针与裸指针，GC 看不见它们）：
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
  thread = CreateThread(0, 0, moonui_worker_main, p, 0, 0);
  if (thread == 0) {
    moonbit_decref(work_closure);
    moonbit_decref(land_closure);
    free(p);
    return -1;
  }
  CloseHandle(thread);
  return 0;
}


/* ---- 音频（lunamusic 第一期，adapter.h 音频段注）----
 *
 * 与 mac 半（AVAudioEngine）同职责分工，见文件头 MF include 那段的取舍：
 * `IMFSourceReader` 负责"认格式 + 解码 + 重采样到设备混音格式"，
 * WASAPI 共享模式负责出声，音量/归一化增益在软件侧乘。
 *
 * ## 线程模型
 *
 * COM 对象（reader / audio client）只归**一只引擎线程**所有——`IMFSourceReader`
 * 是 apartment 亲和的，在 UI 线程（STA）建出来再拿到 worker（MTA）里用是未定义
 * 行为。所以：
 *   - UI 线程只做两件事：往邮箱里放命令（`cmd_*` + `cmd_evt`）、读标量账
 *     （`loaded` / `position_ms` / `duration_ms` 这一批）。
 *   - 引擎线程取命令、开 reader / 开设备、按 WASAPI 缓冲泵数据。
 *   - `load` 与 `play` 是**同步**的（要如实把 -2 报给调用方），用一次
 *     `sync_evt` 等引擎线程回话，超时 5 秒按失败算——读取失败这种事必须当场
 *     分得清"文件坏了(-2)"和"这平台没接(-3)"，这是 `T38` 的错误码口径。
 *
 * 位置账：`pos_frames` 是"交出去的帧数"（含起播前那段静音预铺），
 * `padding` 是渲染端缓冲里还没播的帧数（`GetCurrentPadding`）——两者相减就是
 * 真正播出去的帧，按混音采样率折成毫秒。不用 `IAudioClock` 是因为它要对
 * QPC 频率做换算，多一层错源；这条账在 Seek 时把两个数一起归零即可。
 *
 * ## 为什么 ogg 在这侧仍然缺席
 *
 * Media Foundation 没有 Vorbis 解码器（Windows 10/11 都不带）。mac 半走
 * vendored stb_vorbis，Windows 这侧要用它得把 `stb_vorbis_unit.c` 也编进这条
 * 构建链——那是独立的一笔（`T326` 记了欠账），不影响 mp3/flac/wav/m4a/aac/
 * alac/aiff 这七种。ogg 文件在这侧如实报 -2（"这首歌读不出"），由应用逐首跳。 */

/* 闭包跨线程投递的那一块（`MOONUI_AUDIO_MSG` 的 lParam）。令牌用来作废
 * "换歌/停播之前排队、之后才执行"的那一发——app 侧收到过期的"播完"会让
 * 播放队列多跳一格。 */
typedef struct {
  moonui_closure_fn fn;
  void *closure;
  int token;
} MoonuiWaCall;

/* WASAPI 那一侧的输出描述。ready = 设备 + 客户端 + 渲染接口全齐。 */
typedef struct {
  int ready;
  WAVEFORMATEX *mix; /* GetMixFormat 给的，CoTaskMemFree 回收 */
  IAudioClient *client;
  IAudioRenderClient *render;
  UINT32 buf_frames;
  int dst_float; /* 设备混音格式是不是 IEEE float32 */
  int dst_ch;
  int dst_block; /* nBlockAlign */
  int src_float; /* 解码端产出的格式（我们逼它跟混音格式走） */
  int src_ch;
  int src_block;
} MoonuiWaOut;

static struct {
  volatile LONG inited; /* 0 = 没起，1 = 正在起，2 = 起好了 */
  volatile LONG mf_ok;  /* MFStartup 过了没 */
  CRITICAL_SECTION lock;
  HANDLE cmd_evt;  /* 有新命令（自动重置） */
  HANDLE sync_evt; /* 引擎线程对同步命令的回话（自动重置） */
  int sync_rc;
  volatile LONG quit;

  /* 邮箱：UI 线程写、引擎线程取。两者都在 lock 里动。 */
  int cmd_load;
  WCHAR *cmd_path;
  int cmd_play;
  int cmd_pause;
  int cmd_stop;
  int cmd_seek;
  int64_t cmd_seek_ms;

  /* 标量账：引擎线程写、UI 线程读（x64 上对齐的 64 位标量读是原子的，
   * 写侧不加锁——泵数据那一段每几毫秒就要更一次账，抢锁不值得）。 */
  volatile int64_t loaded;
  volatile int64_t playing;
  volatile int64_t at_eos;
  volatile int64_t duration_ms;
  volatile int64_t anchor_ms; /* 本次锚点的位置（起播/seek 的位置） */
  volatile int64_t pos_frames; /* 交出去的帧数累计 */
  volatile int64_t padding;    /* 缓冲里还没播的帧数 */
  volatile int64_t rate_hz;    /* 混音采样率 */
  volatile int64_t volume_pm;  /* 0..1000 */
  volatile int64_t gain_mdb;   /* `T170` 归一化增益 */
  volatile int64_t token;      /* load/stop 递增，作废已排队的回调 */

  /* 引擎线程独占（UI 线程不许碰） */
  IMFSourceReader *reader;
  int reader_eos;
  BYTE *stash; /* 一次读到的样本比缓冲空间大时，剩下的存这儿 */
  int stash_cap;
  int stash_len;
  int stash_off;
  MoonuiWaOut out;

  /* 播完回调（UI 线程写，引擎线程读快照） */
  moonui_closure_fn finished_fn;
  void *finished_closure;
} g_wa;

/* 引擎线程在 EOS 时投上来的那一发：核对令牌后执行闭包并回收。
 * 定义在窗口过程之后（那份要早于用到它的 wndproc 先声明），实现在本节末尾。 */
static LRESULT moonui_wa_on_deliver(LPARAM lp);

/*|
 * 设备混音格式是不是 IEEE float32：`WAVE_FORMAT_EXTENSIBLE` 的真实格式在
 * SubFormat 里，拿 MF 的 `MFAudioFormat_Float` 比（省掉 ksmedia.h 那层）。
 */
static int wa_fmt_is_float(const WAVEFORMATEX *f) {
  if (f == 0) {
    return 0;
  }
  if (f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    return 1;
  }
  if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      f->cbSize >= (WORD)(sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX))) {
    const WAVEFORMATEXTENSIBLE *e = (const WAVEFORMATEXTENSIBLE *)f;
    return IsEqualGUID(&e->SubFormat, &MFAudioFormat_Float) ? 1 : 0;
  }
  return 0;
}

/* WASAPI 的三条 GUID 在本翻译单元就地定义。
 *
 * 为什么不是直接写 `&moonui_clsid_mmdevenum`：mmdeviceapi.h / audioclient.h
 * 里它们是 `EXTERN_C const IID IID_IAudioClient;` 这种**纯声明**，定义本该由
 * `uuid.lib` 之类的导入库提供——实测（Windows SDK 10.0.26100）um/x64 下没有
 * 任何一只 .lib 带这三个符号，于是 LNK2019。`initguid.h` 也救不了：本文件在
 * `windows.h` 之后才 include 它，`guiddef.h` 早就按"只声明"那支展开过了。
 * 值逐字抄自两个头里的 `MIDL_INTERFACE(...)` / `DECLSPEC_UUID(...)`。
 *
 * （`IID_IMFMetadata` 不在这里——它在 mfuuid.lib 里有，链接清单已加。） */
static const GUID moonui_clsid_mmdevenum = {
    0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
static const GUID moonui_iid_mmdevenum = {
    0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
static const GUID moonui_iid_audioclient = {
    0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}};
static const GUID moonui_iid_audiorender = {
    0xF294ACFC, 0x3146, 0x4483, {0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}};

static void wa_release_unknown(void **pp) {  IUnknown *u = (IUnknown *)*pp;
  if (u != 0) {
    u->lpVtbl->Release(u);
  }
  *pp = 0;
}

/*|
 * 把解码端的输出格式钉成"设备混音格式的 PCM"：采样率与声道数跟混音格式走，
 * 采样格式 float32（`as_float`）或 16 位定点。
 *
 * 钉成混音格式是这条实现的核心简化：WASAPI 共享模式只接受设备混音格式，
 * 由 MF 的 Audio Resampler DSP 做重采样，泵数据那一段就只剩"搬运 + 乘增益"。
 * 两种采样格式都试一遍是因为混音格式通常 float32，但少数机器的端点配的是
 * 16 位定点——让解码端直接产出对味的那一种，转换矩阵就只有一种。
 */
static int wa_set_pcm_type(IMFSourceReader *r, const WAVEFORMATEX *mix,
                           int as_float) {
  IMFMediaType *t = 0;
  HRESULT hr;
  UINT32 ch = mix->nChannels;
  UINT32 rate = mix->nSamplesPerSec;
  UINT32 bits = as_float != 0 ? 32u : 16u;
  UINT32 block = ch * (bits / 8u);
  if (r == 0) {
    return -1;
  }
  if (FAILED(MFCreateMediaType(&t))) {
    return -1;
  }
  t->lpVtbl->SetGUID(t, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
  t->lpVtbl->SetGUID(t, &MF_MT_SUBTYPE,
                     as_float != 0 ? &MFAudioFormat_Float : &MFAudioFormat_PCM);
  t->lpVtbl->SetUINT32(t, &MF_MT_AUDIO_NUM_CHANNELS, ch);
  t->lpVtbl->SetUINT32(t, &MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
  t->lpVtbl->SetUINT32(t, &MF_MT_AUDIO_BITS_PER_SAMPLE, bits);
  t->lpVtbl->SetUINT32(t, &MF_MT_AUDIO_BLOCK_ALIGNMENT, block);
  t->lpVtbl->SetUINT32(t, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * block);
  /* 注意 `SetCurrentMediaType` 的第三个参数是保留位（`DWORD *pdwReserved`），
   * 必须显式传 0——只传两个参数会撞 C2198（这条踩过）。 */
  hr = r->lpVtbl->SetCurrentMediaType(r, MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0,
                                      t);
  t->lpVtbl->Release(t);
  return SUCCEEDED(hr) ? 0 : -1;
}

/*|
 * 读回解码端**实际**采用的格式（SetCurrentMediaType 成功不代表它完全照办：
 * 有些解码器把 16/32 位或声道数换成最近的可行配置）。泵数据按这份读数走。
 */
static void wa_read_src_format(MoonuiWaOut *o) {
  IMFMediaType *t = 0;
  UINT32 v = 0;
  GUID sub;
  o->src_float = 0;
  o->src_ch = 0;
  o->src_block = 0;
  if (g_wa.reader == 0 ||
      FAILED(g_wa.reader->lpVtbl->GetCurrentMediaType(
          g_wa.reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &t))) {
    return;
  }
  if (SUCCEEDED(t->lpVtbl->GetGUID(t, &MF_MT_SUBTYPE, &sub))) {
    o->src_float = IsEqualGUID(&sub, &MFAudioFormat_Float) ? 1 : 0;
  }
  if (SUCCEEDED(t->lpVtbl->GetUINT32(t, &MF_MT_AUDIO_NUM_CHANNELS, &v))) {
    o->src_ch = (int)v;
  }
  if (SUCCEEDED(t->lpVtbl->GetUINT32(t, &MF_MT_AUDIO_BLOCK_ALIGNMENT, &v))) {
    o->src_block = (int)v;
  }
  if (o->src_block <= 0 && o->src_ch > 0) {
    o->src_block = o->src_float != 0 ? o->src_ch * 4 : o->src_ch * 2;
  }
  t->lpVtbl->Release(t);
}

/* 软件增益：音量（千分位）× 归一化（milli-dB）。乘在样本上而不是走
 * `ISimpleAudioVolume`——后者动的是会话音量，会把"歌与歌之间的响度差"和
 * "用户拧的音量"混成一笔账（`T170` 要的正是前者）。 */
static float wa_gain(void) {
  double db = (double)g_wa.gain_mdb / 1000.0;
  double lin = pow(10.0, db / 20.0);
  double vol = (double)g_wa.volume_pm / 1000.0;
  return (float)(vol * lin);
}

/*|
 * 把解码端的样本搬进渲染缓冲，顺带乘增益。
 *
 * 四种组合（解码端 float/16 位 × 设备 float/16 位）都列出来而不是走一条
 * 浮点中间路径：中间路径每帧要多两次转换，而这段是音频回调里最热的循环。
 */
static void wa_copy_frames(BYTE *dst, const BYTE *src, int frames, float gain) {
  int n = frames * g_wa.out.src_ch;
  int i;
  if (g_wa.out.src_float != 0 && g_wa.out.dst_float != 0) {
    const float *sf = (const float *)src;
    float *df = (float *)dst;
    for (i = 0; i < n; i += 1) {
      df[i] = sf[i] * gain;
    }
  } else if (g_wa.out.src_float != 0) {
    const float *sf = (const float *)src;
    short *ds = (short *)dst;
    for (i = 0; i < n; i += 1) {
      float v = sf[i] * gain;
      if (v > 1.0f) {
        v = 1.0f;
      }
      if (v < -1.0f) {
        v = -1.0f;
      }
      ds[i] = (short)(v * 32767.0f);
    }
  } else if (g_wa.out.dst_float != 0) {
    const short *ss = (const short *)src;
    float *df = (float *)dst;
    for (i = 0; i < n; i += 1) {
      df[i] = ((float)ss[i] / 32768.0f) * gain;
    }
  } else {
    const short *ss = (const short *)src;
    short *ds = (short *)dst;
    for (i = 0; i < n; i += 1) {
      int v = (int)((float)ss[i] * gain);
      if (v > 32767) {
        v = 32767;
      }
      if (v < -32768) {
        v = -32768;
      }
      ds[i] = (short)v;
    }
  }
}

static void wa_close_out(void) {
  MoonuiWaOut *o = &g_wa.out;
  if (o->client != 0) {
    o->client->lpVtbl->Stop(o->client);
  }
  wa_release_unknown((void **)&o->render);
  wa_release_unknown((void **)&o->client);
  if (o->mix != 0) {
    CoTaskMemFree(o->mix);
    o->mix = 0;
  }
  o->ready = 0;
  o->buf_frames = 0;
}

static void wa_close_reader(void) {
  if (g_wa.reader != 0) {
    g_wa.reader->lpVtbl->Release(g_wa.reader);
    g_wa.reader = 0;
  }
  g_wa.reader_eos = 0;
  g_wa.stash_len = 0;
  g_wa.stash_off = 0;
}

/*|
 * 开设备与渲染端（共享模式）。失败返回 -1——调用方据此把 play 报成 -4
 * （"这台机器没有可用的输出端点"），而不是 -2（"文件打不开/解不了"）也不是
 * -3（"这平台没接"）。CI 的 Windows runner 上就是这一档：没有音频端点，
 * 这时解码照旧能用、时长照旧能读，只是出不了声——判据要能把这两件事分开，
 * 否则 runner 上会把"没有扬声器"误读成"解码坏了"（2026-11-20 的 CI 红）。
 */
static int wa_open_out(IMFSourceReader *r) {
  MoonuiWaOut *o = &g_wa.out;
  IMMDeviceEnumerator *enumr = 0;
  IMMDevice *dev = 0;
  int rc = -1;
  wa_close_out();
  if (FAILED(CoCreateInstance(&moonui_clsid_mmdevenum, 0, CLSCTX_ALL,
                             &moonui_iid_mmdevenum, (void **)&enumr))) {
    return -1;
  }
  if (FAILED(enumr->lpVtbl->GetDefaultAudioEndpoint(enumr, eRender, eConsole,
                                                    &dev))) {
    wa_release_unknown((void **)&enumr);
    return -1;
  }
  if (FAILED(dev->lpVtbl->Activate(dev, &moonui_iid_audioclient, CLSCTX_ALL, 0,
                                   (void **)&o->client))) {
    wa_release_unknown((void **)&dev);
    wa_release_unknown((void **)&enumr);
    return -1;
  }
  if (FAILED(o->client->lpVtbl->GetMixFormat(o->client, &o->mix))) {
    goto done;
  }
  /* 解码端先按混音格式出 float32，不行再退 16 位定点 */
  if (wa_set_pcm_type(r, o->mix, 1) == 0) {
    o->src_float = 1;
  } else if (wa_set_pcm_type(r, o->mix, 0) == 0) {
    o->src_float = 0;
  } else {
    goto done; /* 连混音格式都凑不出来：宁可不播，也别按错采样率放出来 */
  }
  wa_read_src_format(o);
  if (o->src_ch <= 0 || o->src_block <= 0) {
    goto done;
  }
  if (o->src_ch != (int)o->mix->nChannels) {
    goto done; /* 声道数没对上就不做矩阵混音——宁可如实失败 */
  }
  o->dst_float = wa_fmt_is_float(o->mix);
  o->dst_ch = (int)o->mix->nChannels;
  o->dst_block = (int)o->mix->nBlockAlign;
  if (o->dst_block <= 0) {
    goto done;
  }
  if (FAILED(o->client->lpVtbl->Initialize(o->client, AUDCLNT_SHAREMODE_SHARED, 0,
                                           0, 0, o->mix, 0))) {
    goto done;
  }
  if (FAILED(o->client->lpVtbl->GetBufferSize(o->client, &o->buf_frames)) ||
      o->buf_frames == 0) {
    goto done;
  }
  if (FAILED(o->client->lpVtbl->GetService(o->client, &moonui_iid_audiorender,
                                           (void **)&o->render))) {
    goto done;
  }
  o->ready = 1;
  g_wa.rate_hz = (int64_t)o->mix->nSamplesPerSec;
  rc = 0;
done:
  wa_release_unknown((void **)&dev);
  wa_release_unknown((void **)&enumr);
  if (rc != 0) {
    wa_close_out();
  }
  return rc;
}

/*|
 * 起播/复位前的那段静音预铺：WASAPI 起播时缓冲是空的，第一次 Start 前不铺
 * 数据会先来一下 underrun（听感上是"咔"）。铺满但**同时计入 `pos_frames`**
 * ——位置账是"交出去的帧减 padding"，静音也是交出去的，不记就会让前 20 毫秒
 * 位置往回跳。
 */
static void wa_preroll(void) {
  MoonuiWaOut *o = &g_wa.out;
  BYTE *p = 0;
  UINT32 pad = 0;
  if (o->ready == 0 || o->render == 0) {
    return;
  }
  if (o->client == 0 || FAILED(o->client->lpVtbl->GetCurrentPadding(o->client, &pad)) ||
      pad != 0) {
    return; /* 缓冲里还有东西（暂停续播）：不重复铺 */
  }
  if (FAILED(o->render->lpVtbl->GetBuffer(o->render, o->buf_frames, &p))) {
    return;
  }
  memset(p, 0, (size_t)o->buf_frames * (size_t)o->dst_block);
  o->render->lpVtbl->ReleaseBuffer(o->render, o->buf_frames, 0);
  g_wa.pos_frames += (int64_t)o->buf_frames;
}

/* 位置账（锁内调用）：交出去的帧 - 还没播的帧，按混音采样率折毫秒。 */
static int64_t wa_position_locked(void) {
  int64_t played;
  int64_t pos;
  int64_t rate = g_wa.rate_hz;
  if (g_wa.loaded == 0) {
    return -1;
  }
  if (rate <= 0) {
    rate = 48000;
  }
  played = g_wa.pos_frames - g_wa.padding;
  if (played < 0) {
    played = 0;
  }
  pos = g_wa.anchor_ms + played * 1000 / rate;
  if (g_wa.duration_ms > 0 && pos > g_wa.duration_ms) {
    pos = g_wa.duration_ms;
  }
  if (pos < 0) {
    pos = 0;
  }
  return pos;
}

static void wa_fire_finished(void);

/* 停掉渲染端并清空它的缓冲（seek / stop 用）。 */
static void wa_flush_client(void) {
  MoonuiWaOut *o = &g_wa.out;
  if (o->ready == 0 || o->client == 0) {
    return;
  }
  o->client->lpVtbl->Stop(o->client);
  o->client->lpVtbl->Reset(o->client);
}

/* 重排读端到 ms 并把位置账归零。playing 由调用方决定要不要重启。
 * 返回 0 = 挪到位；-1 = 还没装载（与 mac 半 `moonui_native_audio_seek_ms`
 * 未装载时返回 -1 同一档）。 */
static int wa_seek_locked(int64_t ms) {
  PROPVARIANT v;
  if (g_wa.reader == 0) {
    return -1;
  }
  if (ms < 0) {
    ms = 0;
  }
  if (g_wa.duration_ms > 0 && ms > g_wa.duration_ms) {
    ms = g_wa.duration_ms;
  }
  wa_flush_client();
  PropVariantInit(&v);
  v.vt = VT_I8;
  v.hVal.QuadPart = ms * 10000; /* 100ns 单位 */
  g_wa.reader->lpVtbl->SetCurrentPosition(g_wa.reader, &GUID_NULL, &v);
  PropVariantClear(&v);
  g_wa.reader_eos = 0;
  g_wa.stash_len = 0;
  g_wa.stash_off = 0;
  g_wa.pos_frames = 0;
  g_wa.padding = 0;
  g_wa.anchor_ms = ms;
  return 0;
}

/*|
 * 泵一轮：往渲染缓冲里填数据，填满返回 0（还有活儿），没得填返回 1
 * （缓冲满 / 没在播），让调用方去等命令或睡一会儿。
 *
 * EOS 的判定在这里：读端报 EOS 之后不再喂数据，等缓冲里剩下的播完
 * （padding 归零）才置停并回调——这样"播完"发生在声音真正结束的那一刻，
 * 而不是最后一帧被交出去的那一刻（差着一个缓冲深度，听感上会切掉尾巴）。
 */
static int wa_pump(void) {
  MoonuiWaOut *o = &g_wa.out;
  UINT32 pad = 0;
  UINT32 space;
  BYTE *dst = 0;
  UINT32 got = 0;
  int eos_now = 0;
  if (o->ready == 0 || g_wa.playing == 0) {
    return 1;
  }
  if (o->client == 0 ||
      FAILED(o->client->lpVtbl->GetCurrentPadding(o->client, &pad))) {
    return 1;
  }
  g_wa.padding = (int64_t)pad;
  if (g_wa.reader_eos != 0) {
    if (pad == 0) {
      /* 尾巴播完了：置停、位置钉在时长上、发一次播完 */
      wa_flush_client();
      g_wa.playing = 0;
      g_wa.at_eos = 1;
      g_wa.pos_frames = 0;
      g_wa.padding = 0;
      if (g_wa.duration_ms > 0) {
        g_wa.anchor_ms = g_wa.duration_ms;
      }
      wa_fire_finished();
    }
    return 1;
  }
  space = o->buf_frames - pad;
  if (space == 0) {
    return 1;
  }
  if (FAILED(o->render->lpVtbl->GetBuffer(o->render, space, &dst))) {
    return 1;
  }
  while (got < space) {
    /* 上一发没搬完的余量先补上 */
    if (g_wa.stash_len > 0) {
      int frames = g_wa.stash_len / o->src_block;
      UINT32 take = space - got;
      if ((UINT32)frames < take) {
        take = (UINT32)frames;
      }
      wa_copy_frames(dst + (size_t)got * (size_t)o->dst_block,
                     g_wa.stash + g_wa.stash_off, (int)take, wa_gain());
      g_wa.stash_off += (int)take * o->src_block;
      g_wa.stash_len -= (int)take * o->src_block;
      got += take;
      if (g_wa.stash_len <= 0) {
        g_wa.stash_len = 0;
        g_wa.stash_off = 0;
      }
      continue;
    }
    {
      DWORD flags = 0;
      IMFSample *sample = 0;
      IMFMediaBuffer *buf = 0;
      BYTE *data = 0;
      DWORD len = 0;
      DWORD cap = 0;
      HRESULT hr;
      hr = g_wa.reader->lpVtbl->ReadSample(
          g_wa.reader, (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, 0, &flags,
          0, &sample);
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR) != 0) {
        g_wa.reader_eos = 1;
        eos_now = 1;
        break;
      }
      if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
        if (sample != 0) {
          sample->lpVtbl->Release(sample);
        }
        g_wa.reader_eos = 1;
        eos_now = 1;
        break;
      }
      if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
        wa_read_src_format(o);
      }
      if (sample == 0) {
        continue; /* 只是 STREAMTICK 之类的空通知 */
      }
      if (FAILED(sample->lpVtbl->ConvertToContiguousBuffer(sample, &buf))) {
        sample->lpVtbl->Release(sample);
        continue;
      }
      if (FAILED(buf->lpVtbl->Lock(buf, &data, &cap, &len))) {
        buf->lpVtbl->Release(buf);
        sample->lpVtbl->Release(sample);
        continue;
      }
      {
        int frames = (int)(len / (DWORD)o->src_block);
        UINT32 take = space - got;
        if ((UINT32)frames < take) {
          take = (UINT32)frames;
        }
        if (take > 0) {
          wa_copy_frames(dst + (size_t)got * (size_t)o->dst_block, data,
                         (int)take, wa_gain());
          got += take;
        }
        if (take < (UINT32)frames) {
          /* 缓冲装不下这一发：剩下的存起来下一轮接着搬，别丢样本 */
          int rest = ((int)frames - (int)take) * o->src_block;
          if (rest > g_wa.stash_cap) {
            BYTE *nb = (BYTE *)realloc(g_wa.stash, (size_t)rest);
            if (nb != 0) {
              g_wa.stash = nb;
              g_wa.stash_cap = rest;
            } else {
              rest = 0; /* 内存不够就丢这一截，别把播放整个停掉 */
            }
          }
          if (rest > 0) {
            memcpy(g_wa.stash, data + (size_t)take * (size_t)o->src_block,
                   (size_t)rest);
            g_wa.stash_len = rest;
            g_wa.stash_off = 0;
          }
        }
      }
      buf->lpVtbl->Unlock(buf);
      buf->lpVtbl->Release(buf);
      sample->lpVtbl->Release(sample);
    }
  }
  if (got < space) {
    /* 没喂满（EOS 或读端这一轮没吐东西）：剩下的补静音，缓冲尾不留旧数据 */
    memset(dst + (size_t)got * (size_t)o->dst_block, 0,
           (size_t)(space - got) * (size_t)o->dst_block);
  }
  o->render->lpVtbl->ReleaseBuffer(o->render, space, 0);
  g_wa.pos_frames += (int64_t)space;
  g_wa.padding = (int64_t)pad;
  (void)eos_now;
  return 0;
}

/* ---- 引擎线程的命令执行 ---- */

static int wa_do_open_reader(const WCHAR *path, int64_t *dur) {
  IMFSourceReader *r = 0;
  PROPVARIANT v;
  *dur = -1;
  wa_close_reader();
  if (FAILED(MFCreateSourceReaderFromURL(path, 0, &r))) {
    return -2;
  }
  PropVariantInit(&v);
  if (SUCCEEDED(r->lpVtbl->GetPresentationAttribute(
          r, (DWORD)MF_SOURCE_READER_MEDIASOURCE, &MF_PD_DURATION, &v))) {
    if (v.vt == VT_UI8) {
      *dur = (int64_t)(v.hVal.QuadPart / 10000);
    } else if (v.vt == VT_I8) {
      *dur = (int64_t)(v.hVal.QuadPart / 10000);
    }
  }
  PropVariantClear(&v);
  g_wa.reader = r;
  g_wa.reader_eos = 0;
  return 0;
}

static void wa_do_load(WCHAR *path, int *rc_out) {
  int64_t dur = -1;
  int rc;
  wa_flush_client();
  rc = wa_do_open_reader(path, &dur);
  g_wa.loaded = rc == 0 ? 1 : 0;
  g_wa.playing = 0;
  g_wa.at_eos = 0;
  g_wa.duration_ms = dur;
  g_wa.anchor_ms = 0;
  g_wa.pos_frames = 0;
  g_wa.padding = 0;
  g_wa.gain_mdb = 0; /* 换歌增益归零（`T170` 口径，与 mac 半一致） */
  if (rc == 0) {
    /* 设备开不起来不算 load 失败：时长/元数据已经拿到了，只是放不出声。
     * 这时候 play 报 -4（"没有输出端点"），与"文件读不出"的 -2 分开钉——
     * 两者在 CI 上都会出现，混成一个码就分不清是机器没声卡还是文件坏了。 */
    (void)wa_open_out(g_wa.reader);
  }
  *rc_out = rc;
}

static int wa_do_play(void) {
  int rc = 0;
  int at_eos;
  if (g_wa.loaded == 0 || g_wa.reader == 0) {
    return -1;
  }
  if (g_wa.playing != 0) {
    return 0;
  }
  if (g_wa.out.ready == 0) {
    if (wa_open_out(g_wa.reader) != 0) {
      return -4; /* 没有可用的输出端点（无声卡的 runner / 独占被占） */
    }
  }
  at_eos = g_wa.at_eos;
  if (at_eos != 0) {
    /* 播完之后再点播放：从头来（mac 半把位置钉在时长上，再按播放没有反应；
     * 这侧做得更直白一点，与"用户点了播放就该有声音"一致）。 */
    wa_seek_locked(0);
    g_wa.at_eos = 0;
  }
  wa_preroll();
  if (FAILED(g_wa.out.client->lpVtbl->Start(g_wa.out.client))) {
    return -4; /* 设备在 Initialize 之后仍起不来，同属"端点不可用" */
  }
  g_wa.playing = 1;
  rc = 0;
  return rc;
}

static void wa_do_pause(void) {
  if (g_wa.out.ready == 0 || g_wa.out.client == 0) {
    return;
  }
  if (g_wa.playing == 0) {
    return;
  }
  g_wa.out.client->lpVtbl->Stop(g_wa.out.client);
  g_wa.playing = 0;
  /* 缓冲里的东西留着：续播时接着放，位置账靠 padding 自己冻住 */
}

static void wa_do_stop(void) {
  wa_flush_client();
  wa_close_reader();
  g_wa.loaded = 0;
  g_wa.playing = 0;
  g_wa.at_eos = 0;
  g_wa.duration_ms = -1;
  g_wa.anchor_ms = 0;
  g_wa.pos_frames = 0;
  g_wa.padding = 0;
}

static DWORD WINAPI wa_thread_main(LPVOID param) {
  (void)param;
  CoInitializeEx(0, COINIT_MULTITHREADED);
  for (;;) {
    int do_load, do_play, do_pause, do_stop, do_seek, quit;
    WCHAR *path = 0;
    int64_t seek_ms = 0;
    EnterCriticalSection(&g_wa.lock);
    quit = (int)g_wa.quit;
    do_load = g_wa.cmd_load;
    path = g_wa.cmd_path;
    g_wa.cmd_path = 0;
    g_wa.cmd_load = 0;
    do_play = g_wa.cmd_play;
    g_wa.cmd_play = 0;
    do_pause = g_wa.cmd_pause;
    g_wa.cmd_pause = 0;
    do_stop = g_wa.cmd_stop;
    g_wa.cmd_stop = 0;
    do_seek = g_wa.cmd_seek;
    seek_ms = g_wa.cmd_seek_ms;
    g_wa.cmd_seek = 0;
    LeaveCriticalSection(&g_wa.lock);
    if (quit != 0) {
      break;
    }
    if (do_load != 0) {
      int rc = -2;
      wa_do_load(path, &rc);
      free(path);
      EnterCriticalSection(&g_wa.lock);
      g_wa.sync_rc = rc;
      LeaveCriticalSection(&g_wa.lock);
      SetEvent(g_wa.sync_evt);
      continue;
    }
    if (do_stop != 0) {
      wa_do_stop();
      EnterCriticalSection(&g_wa.lock);
      g_wa.sync_rc = 0;
      LeaveCriticalSection(&g_wa.lock);
      SetEvent(g_wa.sync_evt);
      continue;
    }
    if (do_seek != 0) {
      int rc = wa_seek_locked(seek_ms);
      if (rc == 0 && g_wa.playing != 0) {
        if (g_wa.out.ready != 0) {
          wa_preroll();
          g_wa.out.client->lpVtbl->Start(g_wa.out.client);
        }
      }
      EnterCriticalSection(&g_wa.lock);
      g_wa.sync_rc = rc;
      LeaveCriticalSection(&g_wa.lock);
      SetEvent(g_wa.sync_evt);
      continue;
    }
    if (do_pause != 0) {
      wa_do_pause();
      EnterCriticalSection(&g_wa.lock);
      g_wa.sync_rc = 0;
      LeaveCriticalSection(&g_wa.lock);
      SetEvent(g_wa.sync_evt);
      continue;
    }
    if (do_play != 0) {
      int rc = wa_do_play();
      EnterCriticalSection(&g_wa.lock);
      g_wa.sync_rc = rc;
      LeaveCriticalSection(&g_wa.lock);
      SetEvent(g_wa.sync_evt);
      continue;
    }
    if (wa_pump() != 0) {
      WaitForSingleObject(g_wa.cmd_evt, 5);
    }
  }
  wa_flush_client();
  wa_close_reader();
  wa_close_out();
  CoUninitialize();
  return 0;
}

/*|
 * 一次性初始化：临界区、两只事件、引擎线程、MFStartup。
 *
 * `MFStartup` 在这里做（而不是线程里）是因为探针（`audio_probe`）跑在 UI
 * 线程上、也要用 `MFCreateSourceReaderFromURL`。返回 0 = 这侧根本没接
 * （MF 起不来），所有入口据此报 -3。
 */
static int wa_ensure(void) {
  if (InterlockedCompareExchange(&g_wa.inited, 1, 0) == 0) {
    InitializeCriticalSection(&g_wa.lock);
    g_wa.cmd_evt = CreateEventW(0, FALSE, FALSE, 0);
    g_wa.sync_evt = CreateEventW(0, FALSE, FALSE, 0);
    g_wa.volume_pm = 1000;
    g_wa.gain_mdb = 0;
    g_wa.duration_ms = -1;
    if (SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET))) {
      InterlockedExchange(&g_wa.mf_ok, 1);
      if (g_wa.cmd_evt != 0 && g_wa.sync_evt != 0 &&
          CreateThread(0, 0, wa_thread_main, 0, 0, 0) != 0) {
        /* 线程句柄不留：进程退出时由系统收，这里也没有 join 的语义 */
      }
    }
    InterlockedExchange(&g_wa.inited, 2);
  } else {
    while (InterlockedCompareExchange(&g_wa.inited, 2, 2) != 2) {
      Sleep(0);
    }
  }
  return g_wa.mf_ok != 0 ? 0 : -3;
}

/* 等引擎线程回话（同步命令）。超时按失败算：真到这一步说明读端卡死了。 */
static int wa_wait_sync(void) {
  DWORD w = WaitForSingleObject(g_wa.sync_evt, 5000);
  int rc;
  EnterCriticalSection(&g_wa.lock);
  rc = w == WAIT_OBJECT_0 ? g_wa.sync_rc : -2;
  LeaveCriticalSection(&g_wa.lock);
  return rc;
}

int moonui_native_audio_load(const char *path, int len) {
  WCHAR *w;
  int rc;
  TRACE("audio_load");
  if (path == 0 || len <= 0) {
    return -1;
  }
  rc = wa_ensure();
  if (rc != 0) {
    return rc; /* -3：MF 都没起来，这侧就是没接 */
  }
  w = moonui_native_utf16_of(path, len);
  if (w == 0) {
    return -1;
  }
  EnterCriticalSection(&g_wa.lock);
  /* 换歌作废已排队的播完回调（`T326` 令牌）：否则上一首的 EOS 投递会在新曲
   * 起播之后才执行，app 侧把"上一首播完"当成本曲播完，队列多跳一格。 */
  g_wa.token += 1;
  g_wa.sync_rc = -2;
  free(g_wa.cmd_path); /* 上一发没被取走的（不该有，兜底） */
  g_wa.cmd_path = w;
  g_wa.cmd_load = 1;
  LeaveCriticalSection(&g_wa.lock);
  SetEvent(g_wa.cmd_evt);
  rc = wa_wait_sync();
  return rc;
}

int moonui_native_audio_play(void) {
  int rc;
  TRACE("audio_play");
  rc = wa_ensure();
  if (rc != 0) {
    return rc;
  }
  EnterCriticalSection(&g_wa.lock);
  g_wa.sync_rc = -1;
  g_wa.cmd_play = 1;
  LeaveCriticalSection(&g_wa.lock);
  SetEvent(g_wa.cmd_evt);
  rc = wa_wait_sync();
  return rc;
}

int moonui_native_audio_pause(void) {
  int rc;
  TRACE("audio_pause");
  rc = wa_ensure();
  if (rc != 0) {
    return rc;
  }
  EnterCriticalSection(&g_wa.lock);
  g_wa.sync_rc = -1;
  g_wa.cmd_pause = 1;
  LeaveCriticalSection(&g_wa.lock);
  SetEvent(g_wa.cmd_evt);
  return wa_wait_sync();
}

int moonui_native_audio_stop(void) {
  int rc;
  TRACE("audio_stop");
  rc = wa_ensure();
  if (rc != 0) {
    return rc;
  }
  EnterCriticalSection(&g_wa.lock);
  g_wa.token += 1; /* 停播作废已排队的播完回调 */
  g_wa.sync_rc = -1;
  g_wa.cmd_stop = 1;
  LeaveCriticalSection(&g_wa.lock);
  SetEvent(g_wa.cmd_evt);
  return wa_wait_sync();
}

int64_t moonui_native_audio_position_ms(void) {
  int64_t pos;
  if (g_wa.inited != 2) {
    return -1;
  }
  EnterCriticalSection(&g_wa.lock);
  pos = wa_position_locked();
  LeaveCriticalSection(&g_wa.lock);
  return pos;
}

int64_t moonui_native_audio_duration_ms(void) {
  int64_t d;
  if (g_wa.inited != 2) {
    return -1;
  }
  EnterCriticalSection(&g_wa.lock);
  d = g_wa.loaded != 0 ? g_wa.duration_ms : -1;
  LeaveCriticalSection(&g_wa.lock);
  return d;
}

/* 重排播放位置。**同步等回话**：mac 半的 `moonui_ae_schedule` 在返回前就把
 * 位置账挪好了，这侧若只下发命令就返回，`seek → position_ms` 这一对在两平台
 * 语义分叉（Windows 读回旧位置，playbar 拖动会跳一下）。引擎线程做完
 * `wa_seek_locked` 才回话，返回值就是"真的挪到位了没有"。 */
int moonui_native_audio_seek_ms(int64_t ms) {
  int rc;
  rc = wa_ensure();
  if (rc != 0) {
    return rc;
  }
  EnterCriticalSection(&g_wa.lock);
  g_wa.sync_rc = -1;
  g_wa.cmd_seek_ms = ms;
  g_wa.cmd_seek = 1;
  LeaveCriticalSection(&g_wa.lock);
  SetEvent(g_wa.cmd_evt);
  return wa_wait_sync();
}

int moonui_native_audio_set_volume(int permille) {
  if (wa_ensure() != 0) {
    return -3;
  }
  if (permille < 0) {
    permille = 0;
  }
  if (permille > 1000) {
    permille = 1000;
  }
  g_wa.volume_pm = permille; /* 泵数据时按样本乘，见 wa_gain */
  return 0;
}

int moonui_native_audio_is_playing(void) {
  if (g_wa.inited != 2) {
    return 0;
  }
  return g_wa.playing != 0 ? 1 : 0;
}

/* 播放速率（`T171`）：**这一条仍然缺席**，与上面那批不同。
 *
 * 倍速要"保音高"，mac 半靠 `AVAudioUnitTimePitch` 一条现成的单元；这侧的
 * 对等物是 MF 的 `IMFRateControl`（只有少数源暴露）或自己写 WSOLA 重采样，
 * 两条都不是一行的事，而 WASAPI 共享模式的采样率又被设备混音格式钉死。
 * 所以如实报 -3、读回恒 1000：菜单项照旧能点、只是不起作用（`T171` 的取舍
 * 原文就是"比弹一个不支持更像一颗菜单项该有的分量"）。 */
int moonui_native_audio_set_rate(int permille) {
  (void)permille;
  return -3;
}

int moonui_native_audio_rate(void) {
  return 1000;
}

int moonui_native_audio_on_finished(moonui_closure_fn fn, void *closure) {
  if (wa_ensure() != 0) {
    return -3;
  }
  EnterCriticalSection(&g_wa.lock);
  if (g_wa.finished_closure != 0) {
    moonbit_decref(g_wa.finished_closure);
  }
  if (fn == 0) {
    g_wa.finished_fn = 0;
    g_wa.finished_closure = 0;
  } else {
    if (closure != 0) {
      moonbit_incref(closure);
    }
    g_wa.finished_fn = fn;
    g_wa.finished_closure = closure;
  }
  LeaveCriticalSection(&g_wa.lock);
  return 0;
}

int moonui_native_audio_clear_on_finished(void) {
  return moonui_native_audio_on_finished(0, 0);
}

/* 无缝播放（T168；Windows 空桩：全 -3——Media Foundation 的排段串联留
 * Windows 例行复验那批真做，MoonBit 侧静默退「播完回调→load→play」老路） */
int moonui_native_audio_prime(const char *path, int len) {
  (void)path;
  (void)len;
  return -3;
}

int moonui_native_audio_prime_clear(void) {
  return -3;
}

int moonui_native_audio_on_primed(moonui_closure_fn fn, void *closure) {
  (void)fn;
  (void)closure;
  return -3;
}

int moonui_native_audio_clear_on_primed(void) {
  return -3;
}

/* 音量归一化（T170；Windows 空桩：响度恒"测不出"——start 恒 -3 不回调、
 * MoonBit 侧把 0 哨兵外的收不到当未测；gain 直通空桩，set 记不住（恒 0
 * 读回）、返回 0 让 app 流程不报错。Media Foundation 的响度分析留 Windows
 * 例行复验那批真做） */
int moonui_native_audio_loudness_start(const char *path, int len) {
  (void)path;
  (void)len;
  return -3;
}

int moonui_native_audio_on_loudness(moonui_closure_id_fn fn, void *closure) {
  (void)fn;
  (void)closure;
  return -3;
}

int moonui_native_audio_clear_on_loudness(void) {
  return -3;
}

/* 归一化增益（`T170`）：与 mac 半同式同夹（±12000 milli-dB）。真正生效是在
 * `wa_gain` 里乘进样本——响度测不出（`loudness_start` 这侧仍缺席）时应用侧
 * 挂 0，等价直通。 */
int moonui_native_audio_set_track_gain(int millidb) {
  if (wa_ensure() != 0) {
    return 0;
  }
  if (millidb < -12000) {
    millidb = -12000;
  }
  if (millidb > 12000) {
    millidb = 12000;
  }
  g_wa.gain_mdb = millidb;
  return 0;
}

int moonui_native_audio_track_gain(void) {
  return (int)g_wa.gain_mdb;
}

/*|
 * 探针包的打包（布局与 mac 半 `moonui_native_probe_pack` 逐字节一致，
 * adapter.h 音频段与 lunamusic/probe.mbt 的解析共用一份口径）：
 *   [i32 title_len][title][i32 artist_len][artist][i32 album_len][album]
 *   [i64 duration_ms][i32 cover_len][cover][i32 lyrics_len][lyrics]
 * 封面与歌词这侧先留空（封面要走缩略图流、歌词在 MF 里没有统一键），
 * 长度 0 的字段解析侧本来就按"没有"处理。
 */
static moonui_ptr wa_probe_pack(const char *t, const char *a, const char *al,
                                int64_t dur) {
  int tlen = (int)strlen(t);
  int alen = (int)strlen(a);
  int allen = (int)strlen(al);
  size_t total = 4 + (size_t)tlen + 4 + (size_t)alen + 4 + (size_t)allen + 8 + 4 +
                 4;
  moonbit_bytes_t out;
  uint8_t *buf;
  size_t off = 0;
  int32_t w;
  buf = (uint8_t *)malloc(total);
  if (buf == 0) {
    return (moonui_ptr)moonbit_make_bytes(0, 0);
  }
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
  w = 0; /* 封面：这侧没有 */
  memcpy(buf + off, &w, 4);
  off += 4;
  w = 0; /* 歌词：这侧没有 */
  memcpy(buf + off, &w, 4);
  off += 4;
  out = moonbit_make_bytes((int)total, 0);
  memcpy(out, buf, total);
  free(buf);
  return (moonui_ptr)out;
}

/* 取一条字符串属性成 UTF-8（拿不到就给空串）。PROPVARIANT 由调用方清。 */
static char *wa_prop_utf8(const PROPVARIANT *v) {
  if (v->vt != VT_LPWSTR || v->pwszVal == 0) {
    return 0;
  }
  return moonui_native_utf8_of(v->pwszVal);
}

moonui_ptr moonui_native_audio_probe(const char *path, int len) {
  IMFSourceReader *r = 0;
  IMFMetadata *meta = 0;
  WCHAR *w;
  PROPVARIANT v;
  char *title = 0;
  char *artist = 0;
  char *album = 0;
  int64_t dur = -1;
  moonbit_bytes_t empty;
  TRACE("audio_probe");
  if (path == 0 || len <= 0) {
    return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出 */
  }
  if (wa_ensure() != 0) {
    return (moonui_ptr)moonbit_make_bytes(0, 0);
  }
  w = moonui_native_utf16_of(path, len);
  if (w == 0) {
    return (moonui_ptr)moonbit_make_bytes(0, 0);
  }
  /* 探针不碰引擎线程的状态：自己开一只 reader 读完就放，与 load 那条链
   * 完全解耦（`load` 正在播着的时候扫库/换歌也不会互相踩）。 */
  if (FAILED(MFCreateSourceReaderFromURL(w, 0, &r))) {
    free(w);
    return (moonui_ptr)moonbit_make_bytes(0, 0);
  }
  PropVariantInit(&v);
  if (SUCCEEDED(r->lpVtbl->GetPresentationAttribute(
          r, (DWORD)MF_SOURCE_READER_MEDIASOURCE, &MF_PD_DURATION, &v))) {
    if (v.vt == VT_UI8 || v.vt == VT_I8) {
      dur = (int64_t)(v.hVal.QuadPart / 10000);
    }
  }
  PropVariantClear(&v);
  /* 标签走 metadata provider（`MF_PD_*` 只有标题/作者，专辑在 WM/* 那一族） */
  if (SUCCEEDED(r->lpVtbl->GetServiceForStream(
          r, (DWORD)MF_SOURCE_READER_MEDIASOURCE, &MF_METADATA_PROVIDER_SERVICE,
          &IID_IMFMetadata, (void **)&meta)) &&
      meta != 0) {
    PropVariantInit(&v);
    if (SUCCEEDED(meta->lpVtbl->GetProperty(meta, L"Title", &v))) {
      title = wa_prop_utf8(&v);
    }
    PropVariantClear(&v);
    PropVariantInit(&v);
    if (SUCCEEDED(meta->lpVtbl->GetProperty(meta, L"Author", &v))) {
      artist = wa_prop_utf8(&v);
    }
    PropVariantClear(&v);
    PropVariantInit(&v);
    if (SUCCEEDED(meta->lpVtbl->GetProperty(meta, L"WM/AlbumTitle", &v))) {
      album = wa_prop_utf8(&v);
    }
    PropVariantClear(&v);
    meta->lpVtbl->Release(meta);
  }
  r->lpVtbl->Release(r);
  free(w);
  if (title == 0 && artist == 0 && album == 0 && dur < 0) {
    empty = moonbit_make_bytes(0, 0);
  } else {
    empty = (moonbit_bytes_t)wa_probe_pack(title != 0 ? title : "",
                                           artist != 0 ? artist : "",
                                           album != 0 ? album : "", dur);
  }
  free(title);
  free(artist);
  free(album);
  return (moonui_ptr)empty;
}

/*|
 * 播完：把 {fn, 环境, 令牌} 包一块投回 UI 线程。闭包在这里 incref、由
 * `moonui_wa_on_deliver` 在执行后 decref——与 `T85①` worker 落地那条
 * 投递纪律逐字相同（Win32 只看得见裸指针，GC 看不见）。
 */
static void wa_fire_finished(void) {
  MoonuiWaCall *c;
  moonui_closure_fn fn;
  void *closure;
  int token;
  EnterCriticalSection(&g_wa.lock);
  fn = g_wa.finished_fn;
  closure = g_wa.finished_closure;
  token = (int)g_wa.token;
  if (fn == 0 || closure == 0) {
    LeaveCriticalSection(&g_wa.lock);
    return;
  }
  moonbit_incref(closure);
  LeaveCriticalSection(&g_wa.lock);
  if (moonui_native_park == 0) {
    moonbit_decref(closure); /* 还没 init：没人收这一发 */
    return;
  }
  c = (MoonuiWaCall *)malloc(sizeof(MoonuiWaCall));
  if (c == 0) {
    moonbit_decref(closure);
    return;
  }
  c->fn = fn;
  c->closure = closure;
  c->token = token;
  if (PostMessageW(moonui_native_park, MOONUI_AUDIO_MSG, 0, (LPARAM)c) == 0) {
    moonbit_decref(closure);
    free(c);
  }
}

static LRESULT moonui_wa_on_deliver(LPARAM lp) {
  MoonuiWaCall *c = (MoonuiWaCall *)(uintptr_t)lp;
  if (c == 0) {
    return 0;
  }
  EnterCriticalSection(&g_wa.lock);
  if ((int)g_wa.token == c->token && g_wa.finished_fn == c->fn) {
    LeaveCriticalSection(&g_wa.lock);
    c->fn(c->closure);
  } else {
    LeaveCriticalSection(&g_wa.lock); /* 令牌过期：换歌/停播在排队之后发生了 */
  }
  moonbit_decref(c->closure);
  free(c);
  return 0;
}

/* 频谱与均衡器：Windows 半在这两样上是空实现（FP4 之前 Media Foundation 只
 * 做播放）。band_count = 0 让 MoonBit 侧把 EQ 面板画成"本平台没有"，而不是
 * 画一排拖了没反应的假滑块。 */
int moonui_native_audio_level(int band) {
  (void)band;
  return 0;
}

int moonui_native_audio_eq_band_count(void) {
  return 0;
}

int moonui_native_audio_eq_set_band(int band, int gain_mdb) {
  (void)band;
  (void)gain_mdb;
  return -3;
}

int moonui_native_audio_eq_band_gain(int band) {
  (void)band;
  return 0;
}

int moonui_native_audio_eq_set_enabled(int on) {
  (void)on;
  return -3;
}

int moonui_native_audio_eq_enabled(void) {
  return 0;
}

/* ---- 输出设备（T169；Windows 空桩：列表 [0][-1]、set 返 -3）---- */
moonui_ptr moonui_native_audio_output_list(void) {
  static const unsigned char empty[8] = {0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF};
  moonbit_bytes_t packed = moonbit_make_bytes(8, 0);
  memcpy(packed, empty, 8); /* [int32 count=0][int32 current=-1] */
  return (moonui_ptr)packed;
}

int moonui_native_audio_output_set(int index) {
  (void)index;
  return -3;
}

/* ---- 媒体键/全局热键/正在播放（T181；Windows 空桩：全 -3——WM_APPCOMMAND
 * 留 Windows 例行复验那批真做）---- */
int moonui_native_media_keys_set(moonui_closure_id_fn fn, void *closure) {
  (void)fn;
  (void)closure;
  return -3;
}

int moonui_native_hotkeys_set(moonui_closure_id_fn fn, void *closure) {
  (void)fn;
  (void)closure;
  return -3;
}

int moonui_native_now_playing_set(const char *title, int title_len,
                                  const char *artist, int artist_len,
                                  int64_t elapsed_ms, int64_t duration_ms,
                                  int playing) {
  (void)title;
  (void)title_len;
  (void)artist;
  (void)artist_len;
  (void)elapsed_ms;
  (void)duration_ms;
  (void)playing;
  return -3;
}

int moonui_native_media_probe(int code) {
  (void)code;
  return -1;
}

int moonui_native_hotkey_probe(int code) {
  (void)code;
  return -1;
}

int moonui_native_hotkey_probe_id(int id) {
  (void)id;
  return -1;
}

/* ---- 目录行走（lunamusic 第一期，`T202`；契约与打包布局见 adapter.h）----
 * FindFirstFileW/FindNextFileW 直写——与 mac 半的 readdir 同形状：只列**直接**
 * 子项、上报**绝对路径**、不排序不递归（递归策略与排序在 MoonBit 侧的
 * `Fs::walk`）。路径 UTF-8→UTF-16 走本文件同一把尺（`moonui_native_utf16_of`，
 * `T19` 那颗空串坑已在那边填掉），子项拼回用 `moonui_native_utf8_of`。
 * FindFirstFileW 的序就是目录序，与 readdir 一样无序——调用方要确定性排序，
 * 那是 `Fs::walk` 收口的职责，不在 C 里重排。 */
moonui_ptr moonui_native_walk_dir(const char *path, int len) {
  LPWSTR wpath;
  LPWSTR pattern;
  wchar_t *cursor;
  HANDLE find;
  WIN32_FIND_DATAW wfd;
  char **names = 0;
  size_t *name_lens = 0;
  int count = 0;
  int cap = 0;
  int i;
  int need_sep;
  size_t total;
  uint8_t *buf;
  moonbit_bytes_t out;
  TRACE("walk_dir");
  if (path == 0 || len <= 0) {
    return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 读不出 */
  }
  wpath = moonui_native_utf16_of(path, len);
  if (wpath == 0) {
    return (moonui_ptr)moonbit_make_bytes(0, 0);
  }
  need_sep = 1;
  {
    int n = 0;
    while (wpath[n] != L'\0') {
      ++n;
    }
    if (n > 0 && (wpath[n - 1] == L'\\' || wpath[n - 1] == L'/')) {
      need_sep = 0;
    }
  }
  pattern = (LPWSTR)malloc((wcslen(wpath) + 4u) * sizeof(WCHAR));
  if (pattern == 0) {
    free(wpath);
    return (moonui_ptr)moonbit_make_bytes(0, 0);
  }
  cursor = pattern;
  wcscpy(cursor, wpath);
  cursor += wcslen(wpath);
  if (need_sep) {
    *cursor++ = L'\\';
  }
  *cursor++ = L'*';
  *cursor = L'\0';
  find = FindFirstFileW(pattern, &wfd);
  free(pattern);
  if (find == INVALID_HANDLE_VALUE) {
    free(wpath);
    return (moonui_ptr)moonbit_make_bytes(0, 0); /* 空包 = 打不开 */
  }
  do {
    LPWSTR wchild;
    char *u;
    size_t ulen;
    if (wfd.cFileName[0] == L'.' &&
        (wfd.cFileName[1] == L'\0' ||
         (wfd.cFileName[1] == L'.' && wfd.cFileName[2] == L'\0'))) {
      continue;
    }
    wchild = (LPWSTR)malloc((wcslen(wpath) + 2u + wcslen(wfd.cFileName) + 1u) *
                            sizeof(WCHAR));
    if (wchild == 0) {
      continue;
    }
    cursor = wchild;
    wcscpy(cursor, wpath);
    cursor += wcslen(wpath);
    if (need_sep) {
      *cursor++ = L'\\';
    }
    wcscpy(cursor, wfd.cFileName);
    u = moonui_native_utf8_of(wchild);
    free(wchild);
    if (u == 0) {
      continue;
    }
    ulen = strlen(u);
    if (count == cap) {
      int ncap = cap > 0 ? cap * 2 : 16;
      char **nn = (char **)realloc(names, (size_t)ncap * sizeof(char *));
      size_t *nl;
      if (nn == 0) {
        free(u);
        continue;
      }
      names = nn;
      nl = (size_t *)realloc(name_lens, (size_t)ncap * sizeof(size_t));
      if (nl == 0) {
        free(u);
        continue;
      }
      name_lens = nl;
      cap = ncap;
    }
    names[count] = u;
    name_lens[count] = ulen;
    ++count;
  } while (FindNextFileW(find, &wfd));
  FindClose(find);
  free(wpath);
  total = 4;
  for (i = 0; i < count; ++i) {
    total += 4 + name_lens[i];
  }
  if (total > (size_t)INT32_MAX) {
    for (i = 0; i < count; ++i) {
      free(names[i]);
    }
    free(names);
    free(name_lens);
    return (moonui_ptr)moonbit_make_bytes(0, 0);
  }
  buf = (uint8_t *)malloc(total);
  if (buf == 0) {
    for (i = 0; i < count; ++i) {
      free(names[i]);
    }
    free(names);
    free(name_lens);
    return (moonui_ptr)moonbit_make_bytes(0, 0);
  }
  {
    size_t off = 0;
    int32_t packed_count = (int32_t)count;
    memcpy(buf + off, &packed_count, 4);
    off += 4;
    for (i = 0; i < count; ++i) {
      int32_t nlen = (int32_t)name_lens[i];
      memcpy(buf + off, &nlen, 4);
      off += 4;
      if (nlen > 0) {
        memcpy(buf + off, names[i], (size_t)nlen);
        off += (size_t)nlen;
      }
      free(names[i]);
    }
    free(names);
    free(name_lens);
  }
  out = moonbit_make_bytes((int)total, 0);
  memcpy(out, buf, total);
  free(buf);
  return (moonui_ptr)out;
}
#else
/* 非 Windows 宿主：本翻译单元什么也不定义，只留一个 typedef，免得空翻译单元
 * 触发 C99 的诊断。Cocoa 那份实现在 ../native-macos/adapter_native.m，
 * 两个文件提供同一套 adapter.h 契约。 */
typedef int moonui_native_adapter_host_not_windows_t;
#endif /* _WIN32 */

/* ---- 画布（§52 分期④，`T98` 的 Windows 半）：GDI+ 光栅化 + AlphaBlend 上屏 ----
 *
 * 一只画布 = 一段离屏位图帧的生命周期（与 mac 半的 MoonuiCanvas 同形）：
 * begin_frame 开一张物理像素位图（这里是一张 32bpp 顶行在前的 DIB section，
 * GDI+ 经 GdipCreateBitmapFromScan0 直画进 DIB 的位面，零拷贝），各绘制函数
 * 经 GDI+ flat API 画上去，present / present_view 把帧记到目标 HWND 的属性
 * 表上（moonui.canvas 那条 prop）并 InvalidateRect——WM_PAINT 时
 * AlphaBlend（AC_SRC_OVER | AC_SRC_ALPHA，源是预乘）贴进客户区。
 *
 * 内存布局对齐：DIB 的 32bpp BI_RGB 位面在内存里是 B,G,R,A（小端 ARGB），
 * 与 GDI+ 的 PixelFormat32bppPARGB（预乘）与 AlphaBlend 的 AC_SRC_ALPHA
 * 源要求三者同一种字节序，所以"画"（GDI+）、"读"（read_pixel/探针）与
 * "贴"（GDI）全在同一块缓冲上，谁也不换算。read_pixel 的对外口径照 mac：
 * 返回 0xRRGGBB、预乘展开、alpha=0 报 -1。
 *
 * 坐标不翻：GDI+ 世界坐标本来就是左上原点、y 向下，与 DrawList/UI 惯用
 * 同向——mac 半开帧时的 CTM 翻转（CG 原生 y 向上）在这边整条不需要。
 *
 * GDI+ 运行时进程级一次（GdiplusStartup），懒启动：canvas_create 与
 * measure_text 都可能发生在 moonui_native_init 之后任意时刻，而 terminate
 * 之后仍可能有别的画布活着（MoonBit 侧 custom_canvases 不随 terminate 清），
 * 所以不随 init/terminate 起停、跟进程一命。 */

typedef struct {
  int w;
  int h;
  int row_bytes;
  unsigned char *data; /* DIB 位面（借住在 dib 名下，别 free 它） */
  HDC blit_dc;         /* present 用的源 DC：dib 选在它上面 */
  HBITMAP dib;
  HBITMAP dib_old;
  GpBitmap *bmp; /* 包住 data 的 GDI+ 位图（不复制 scan0） */
  GpGraphics *gfx;
  HWND window; /* attach_window 记的宿主窗（borrowed，见 canvas_prop 注） */
  HWND view;   /* present_view 最后一次贴的视图（borrowed） */
  /* 投影状态（adapter.h：状态不是一次性格式，直到 restore/blur=0 清零）。
   * GDI+ 没有内建投影——fill_rect / fill_linear 画形状之前先把同形状的
   * 素色块糊进一张临时位图、三次盒式模糊后按 (dx,dy) 叠上来（与 CG 的
   * "影子在形状底下"同序）。线/弧/多边形不带影：全仓没有带影的住户，
   * 不为不存在的调用先付复杂度。 */
  int shadow_on;
  int shadow_dx;
  int shadow_dy;
  int shadow_blur_permille;
  int64_t shadow_rgb;
  /* save/restore 的状态令牌栈：GdipRestoreGraphics 要的是 GdipSaveGraphics
   * 递回来的那一枚（不是"弹最近一枚"的隐式栈），配方里的 save/restore
   * 严格配对、LIFO，这里存令牌即可。 */
  GraphicsState states[16];
  int state_top;
} MoonuiCanvas;

static int moonui_native_gdiplus_ready = 0;
static ULONG_PTR moonui_native_gdiplus_token = 0;

static void moonui_native_ensure_gdiplus(void) {
  MoonuiGdiplusStartupInput input;
  if (moonui_native_gdiplus_ready) {
    return;
  }
  memset(&input, 0, sizeof(input));
  input.GdiplusVersion = 1;
  if (GdiplusStartup(&moonui_native_gdiplus_token, &input, 0) == MOONUI_GDIP_OK) {
    moonui_native_gdiplus_ready = 1;
  }
}

static MoonuiCanvas *moonui_canvas_of(moonui_ptr p) {
  if (p == 0) {
    return 0;
  }
  return (MoonuiCanvas *)(uintptr_t)p;
}

/* 换帧/销毁共用：GDI+ 的对象先走（它还引用着 scan0），再收 GDI 的 DC 与 DIB。 */
static void moonui_canvas_drop_frame(MoonuiCanvas *c) {
  if (c->gfx != 0) {
    GdipDeleteGraphics(c->gfx);
    c->gfx = 0;
  }
  if (c->bmp != 0) {
    GdipDisposeImage((GpImage *)c->bmp);
    c->bmp = 0;
  }
  if (c->blit_dc != 0) {
    if (c->dib_old != 0) {
      SelectObject(c->blit_dc, c->dib_old);
      c->dib_old = 0;
    }
    DeleteDC(c->blit_dc);
    c->blit_dc = 0;
  }
  if (c->dib != 0) {
    DeleteObject(c->dib);
    c->dib = 0;
  }
  c->data = 0;
  c->w = 0;
  c->h = 0;
  c->row_bytes = 0;
}

/* 0xRRGGBB + alpha(0..255) → GDI+ 的 0xAARRGGBB（ARGB）。 */
static ARGB moonui_canvas_argb(int64_t rgb, int alpha) {
  int a = alpha;
  if (a < 0) {
    a = 0;
  }
  if (a > 255) {
    a = 255;
  }
  return (ARGB)(((ARGB)(unsigned)a << 24) | (ARGB)(rgb & 0xFFFFFF));
}

/* 圆角矩形路径：口径照 mac 半的 moonui_canvas_rounded_path——半径钳到
 * [0, min(w,h)/2]，r<0.5 走直角矩形，"半宽即正圆"走整椭圆（四段弧拼的
 * 接点留 1px 抗锯齿缝，mac 侧实测过）。角度体系两边同根：0° = 三点钟、
 * 顺时针为正（GDI+ 与我们的位图坐标同为 y 向下，不需要任何翻转）。 */
static GpPath *moonui_canvas_rounded_path(int x, int y, int w, int h,
                                          double radius) {
  double r = radius;
  GpPath *path = 0;
  if (r < 0) {
    r = 0;
  }
  if (r > (double)w / 2.0) {
    r = (double)w / 2.0;
  }
  if (r > (double)h / 2.0) {
    r = (double)h / 2.0;
  }
  if (GdipCreatePath(MOONUI_GDIP_FILLMODE_WINDING, &path) != MOONUI_GDIP_OK) {
    return 0;
  }
  if (r < 0.5) {
    GdipAddPathRectangle(path, (REAL)x, (REAL)y, (REAL)w, (REAL)h);
    return path;
  }
  if (r >= (double)w / 2.0 - 0.001 && r >= (double)h / 2.0 - 0.001) {
    GdipAddPathEllipse(path, (REAL)x, (REAL)y, (REAL)w, (REAL)h);
    return path;
  }
  GdipAddPathLine(path, (REAL)(x + r), (REAL)y, (REAL)(x + w - r), (REAL)y);
  GdipAddPathArc(path, (REAL)(x + w - 2 * r), (REAL)y, (REAL)(2 * r),
                 (REAL)(2 * r), 270.0f, 90.0f);
  GdipAddPathLine(path, (REAL)(x + w), (REAL)(y + r), (REAL)(x + w),
                  (REAL)(y + h - r));
  GdipAddPathArc(path, (REAL)(x + w - 2 * r), (REAL)(y + h - 2 * r),
                 (REAL)(2 * r), (REAL)(2 * r), 0.0f, 90.0f);
  GdipAddPathLine(path, (REAL)(x + w - r), (REAL)(y + h), (REAL)(x + r),
                  (REAL)(y + h));
  GdipAddPathArc(path, (REAL)x, (REAL)(y + h - 2 * r), (REAL)(2 * r),
                 (REAL)(2 * r), 90.0f, 90.0f);
  GdipAddPathLine(path, (REAL)x, (REAL)(y + h - r), (REAL)x, (REAL)(y + r));
  GdipAddPathArc(path, (REAL)x, (REAL)y, (REAL)(2 * r), (REAL)(2 * r),
                 180.0f, 90.0f);
  GdipClosePathFigure(path);
  return path;
}

/* 三次盒式模糊（高斯近似，running-sum、O(面元) 与半径无关），算法与 mac 半
 * 同一份：每轮先水平后垂直，两块紧凑缓冲 ping-pong，三轮后结果在 bufs[0]。
 * 这里对 (x0,y0)-(x1,y1) 那块**原地**糊（stride 是宿主缓冲的行距，宿主可以
 * 是画布帧也可以是投影的临时位图），越界钳制归调用方。 */
static void moonui_canvas_box_blur(unsigned char *base, int stride, int x0,
                                   int y0, int x1, int y1, int r) {
  int W;
  int H;
  int win;
  int i;
  int j;
  int k;
  unsigned char *bufs[2];
  if (base == 0 || r <= 0) {
    return;
  }
  W = x1 - x0;
  H = y1 - y0;
  if (W <= 0 || H <= 0) {
    return;
  }
  win = 2 * r + 1;
  bufs[0] = (unsigned char *)calloc((size_t)W * (size_t)H * 4, 1);
  bufs[1] = (unsigned char *)calloc((size_t)W * (size_t)H * 4, 1);
  if (bufs[0] == 0 || bufs[1] == 0) {
    free(bufs[0]);
    free(bufs[1]);
    return;
  }
  for (j = 0; j < H; j++) {
    memcpy(bufs[0] + (size_t)j * W * 4,
           base + (size_t)(y0 + j) * stride + (size_t)x0 * 4, (size_t)W * 4);
  }
  /* 三轮，每轮固定：水平 bufs[0]→bufs[1]，垂直 bufs[1]→bufs[0]——
   * 结果永远落在 bufs[0]，不用换手。 */
  for (k = 0; k < 3; k++) {
    uint8_t *in = bufs[0];
    uint8_t *out = bufs[1];
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
    /* 垂直 pass：读 bufs[1]，写回 bufs[0]（每轮收尾都在 bufs[0]）。 */
    in = bufs[1];
    out = bufs[0];
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
        sr += in[(size_t)(rj * W + i) * 4 + 0];
        sg += in[(size_t)(rj * W + i) * 4 + 1];
        sb += in[(size_t)(rj * W + i) * 4 + 2];
        sa += in[(size_t)(rj * W + i) * 4 + 3];
        if (j - win >= 0) {
          int lj2 = j - win;
          if (lj2 < 0) {
            lj2 = 0;
          }
          sr -= in[(size_t)(lj2 * W + i) * 4 + 0];
          sg -= in[(size_t)(lj2 * W + i) * 4 + 1];
          sb -= in[(size_t)(lj2 * W + i) * 4 + 2];
          sa -= in[(size_t)(lj2 * W + i) * 4 + 3];
        }
        out[(size_t)(j * W + i) * 4 + 0] = (uint8_t)(sr / win);
        out[(size_t)(j * W + i) * 4 + 1] = (uint8_t)(sg / win);
        out[(size_t)(j * W + i) * 4 + 2] = (uint8_t)(sb / win);
        out[(size_t)(j * W + i) * 4 + 3] = (uint8_t)(sa / win);
      }
    }
  }
  for (j = 0; j < H; j++) {
    memcpy(base + (size_t)(y0 + j) * stride + (size_t)x0 * 4,
           bufs[0] + (size_t)j * W * 4, (size_t)W * 4);
  }
  free(bufs[0]);
  free(bufs[1]);
}

/* 投影的"先画影再画形"：同形状素色块（影色、不透明）画进一张形状尺寸的
 * 临时 PARGB 位图 → 三次盒式模糊 → 按 (dx,dy) 预乘叠回主帧。CG 的影是
 * 状态、形状之外的软边由模糊出——这里同一根尺。失败静默（影是修饰，不
 * 值得让填充跟着红）。 */
static void moonui_canvas_shadow_for_rect(MoonuiCanvas *c, int x, int y, int w,
                                          int h, double radius) {
  GpBitmap *sbmp = 0;
  GpGraphics *sgfx = 0;
  GpPath *path = 0;
  GpBrush *brush = 0;
  unsigned char *bits;
  int blur_r;
  if (c == 0 || c->gfx == 0 || !c->shadow_on || w <= 0 || h <= 0) {
    return;
  }
  bits = (unsigned char *)calloc((size_t)w * (size_t)h * 4, 1);
  if (bits == 0) {
    return;
  }
  if (GdipCreateBitmapFromScan0(w, h, w * 4, MOONUI_GDIP_PIXFMT_PARGB, bits,
                                &sbmp) != MOONUI_GDIP_OK) {
    free(bits);
    return;
  }
  if (GdipGetImageGraphicsContext((GpImage *)sbmp, &sgfx) != MOONUI_GDIP_OK) {
    GdipDisposeImage((GpImage *)sbmp);
    free(bits);
    return;
  }
  path = moonui_canvas_rounded_path(0, 0, w, h, radius);
  if (path != 0 && GdipCreateSolidFill(moonui_canvas_argb(c->shadow_rgb, 255),
                                       &brush) == MOONUI_GDIP_OK) {
    GdipFillPath(sgfx, brush, path);
    GdipDeleteBrush(brush);
  }
  if (path != 0) {
    GdipDeletePath(path);
  }
  blur_r = c->shadow_blur_permille / 1000;
  if (blur_r > 0) {
    moonui_canvas_box_blur(bits, w * 4, 0, 0, w, h, blur_r);
  }
  GdipDrawImageRectI(c->gfx, (GpImage *)sbmp, x + c->shadow_dx,
                     y + c->shadow_dy, w, h);
  GdipDeleteGraphics(sgfx);
  GdipDisposeImage((GpImage *)sbmp);
  free(bits);
}

/* 度量用的 1×1 上下文：measure_text 不带画布参数，GDI+ 却要 graphics 才能
 * 量——进程级缓存一只（位图引用的 bits 必须活得和位图一样长，static）。 */
static GpGraphics *moonui_canvas_measure_graphics(void) {
  static GpGraphics *gfx = 0;
  static GpBitmap *bmp = 0;
  static BYTE bits[4];
  if (gfx == 0) {
    if (GdipCreateBitmapFromScan0(1, 1, 4, MOONUI_GDIP_PIXFMT_PARGB, bits,
                                  &bmp) == MOONUI_GDIP_OK) {
      GdipGetImageGraphicsContext((GpImage *)bmp, &gfx);
    }
  }
  return gfx;
}

/* 一只字族扛不扛得住界面上的字：拿 GDI 直接问字形表。
 *
 * GDI+ 的 DrawString/MeasureString **不做字体回退**（mac 的
 * NSAttributedString 自动回退），选错族就是豆腐块，所以这一问是判据不是优化。
 * 探针取"中文，"三枚汉字 + 全角逗号：缺任何一个都说明这族只管拉丁。 */
static int moonui_canvas_family_covers_cjk(const WCHAR *face) {
  static const WCHAR probe_text[] = {0x4E2D, 0x6587, 0xFF0C, 0};
  LOGFONTW lf;
  HFONT font;
  HDC dc;
  HGDIOBJ old;
  WORD glyphs[3];
  int i;
  int ok = 0;
  memset(&lf, 0, sizeof(lf));
  lstrcpynW(lf.lfFaceName, face, LF_FACESIZE);
  lf.lfHeight = -12;
  lf.lfCharSet = DEFAULT_CHARSET;
  font = CreateFontIndirectW(&lf);
  if (font == 0) {
    return 0;
  }
  dc = CreateCompatibleDC(0);
  if (dc != 0) {
    old = SelectObject(dc, font);
    if (GetGlyphIndicesW(dc, probe_text, 3, glyphs,
                         GGI_MARK_NONEXISTING_GLYPHS) != GDI_ERROR) {
      ok = 1;
      for (i = 0; i < 3; i++) {
        if (glyphs[i] == 0xFFFF) { /* 缺字形的哨兵值 */
          ok = 0;
        }
      }
    }
    SelectObject(dc, old);
    DeleteDC(dc);
  }
  DeleteObject(font);
  return ok;
}

/* 造一只字族，没有就 0（名字不成族时 GDI+ 也回 0 而不会给半成品）。 */
static GpFontFamily *moonui_canvas_try_family(const WCHAR *name) {
  GpFontFamily *f = 0;
  if (GdipCreateFontFamilyFromName(name, 0, &f) != MOONUI_GDIP_OK) {
    return 0;
  }
  return f;
}

/* 自绘面的字族：**跟随系统 UI 字体**（`T313`），不再写死微软雅黑。
 *
 * 三端同一条口径：native 半边的控件用系统字体（Windows 是消息字体 / mac 是
 * systemFontOfSize / GTK 是主题字体），自绘半边跟着走，一屏才只有一种字。
 * owner 2026-11-18 的截图就是这么来的——原生控件是 `Microsoft YaHei UI`、
 * 自绘面是 `Microsoft YaHei`，字重字宽都对不上，"看着像两种字"。
 *
 * 两条兜底，顺序不能反：
 * ① 系统那族缺汉字（英文系统上的消息字体是 Segoe UI）→ 退中文 Windows 的
 *    界面字体 `Microsoft YaHei UI`，再退旧名 `Microsoft YaHei`。GDI+ 不回退，
 *    这一退是"别画豆腐块"的唯一保险（用 `moonui_canvas_family_covers_cjk` 判）。
 * ② 连雅黑都拿不到（非中文亚洲系统、精简镜像）→ GDI+ 通用无衬线，最后一线。
 *
 * **剩下的不一致照实说**：系统 UI 字体是纯拉丁族时（英文系统），原生控件与
 * 自绘面会分家——控件走系统族（GDI 自己会做字体链接，汉字落到 宋体/雅黑），
 * 画布只能用雅黑一族（否则豆腐块）。要严格同族得应用自己钉一族：
 * `app.set_font_family(Some("Microsoft YaHei UI"))`（`T314` 的应用级 API），
 * 控件与画布两半都跟。 */
/* 应用级字族覆盖（`T314`）：`App::set_font_family` 经 native-common 推来的
 * UTF-8 族名，"" = 跟随系统（上面那段 `T313` 的口径）。进程一份——所有窗口
 * 共用同一份底样式，所以"当前族"也就一个值。 */
static char moonui_canvas_family_override[128];

int moonui_native_set_canvas_font_family(const char *name, int name_len) {
  int n = 0;
  if (name != 0 && name_len > 0) {
    n = name_len;
    if (n >= (int)sizeof(moonui_canvas_family_override)) {
      n = (int)sizeof(moonui_canvas_family_override) - 1;
    }
    memcpy(moonui_canvas_family_override, name, (size_t)n);
  }
  moonui_canvas_family_override[n] = '\0';
  return 0;
}

/* 自绘面的字族：**应用选了就跟应用（`T314`）、没选就跟系统（`T313`）**。
 *
 * 缓存按"当前请求"失效：覆盖串变了就重造一只。旧的那只**不删**——画布
 * 手里可能还攥着按它造的 `GpFont`（`font_of` 每次现造、够用即删，但同一帧
 * 里可能有一只在用），`GdipDeleteFontFamily` 会让那些 font 变悬空。切字体
 * 是低频操作（一次会话几回），进程级的这点泄漏换"不崩"。
 *
 * 应用选了一个本机没有的族时不报错：`moonui_canvas_try_family` 拿不到就回 0，
 * 落回下面那条系统链——传错名字是"没有那一族"，不是失败。
 */
static GpFontFamily *moonui_canvas_font_family(void) {
  static GpFontFamily *family = 0;
  static char built_for[sizeof(moonui_canvas_family_override)];
  static int tried = 0;
  if (tried && strcmp(built_for, moonui_canvas_family_override) == 0) {
    return family;
  }
  tried = 1;
  family = 0;
  /* GDI+ 的 flat API 契约要求先 `GdiplusStartup`。正常路径是
   * `canvas_create` 先起，可 `T313` 的"一种字"探针会在**没有任何画布**的
   * 窗口上问这一族——这里幂等补一次，免得探针依赖"谁先建了画布"这种
   * 不成文的顺序。（实测本机 GDI+ 对未 Startup 的 CreateFontFamily 也会
   * 自己兜住，但那是实现细节，不是契约。） */
  moonui_native_ensure_gdiplus();
  if (moonui_canvas_family_override[0] != '\0') {
    WCHAR want[LF_FACESIZE];
    want[0] = L'\0';
    if (MultiByteToWideChar(CP_UTF8, 0, moonui_canvas_family_override, -1, want,
                            LF_FACESIZE) > 0) {
      family = moonui_canvas_try_family(want);
    }
  }
  if (family == 0) {
    NONCLIENTMETRICSW ncm;
    memset(&ncm, 0, sizeof(ncm));
    ncm.cbSize = (DWORD)sizeof(ncm);
    if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, (DWORD)sizeof(ncm), &ncm,
                              0) != 0 &&
        ncm.lfMessageFont.lfFaceName[0] != L'\0' &&
        moonui_canvas_family_covers_cjk(ncm.lfMessageFont.lfFaceName)) {
      family = moonui_canvas_try_family(ncm.lfMessageFont.lfFaceName);
    }
    if (family == 0) {
      family = moonui_canvas_try_family(L"Microsoft YaHei UI");
    }
    if (family == 0) {
      family = moonui_canvas_try_family(L"Microsoft YaHei");
    }
    if (family == 0) {
      GdipGetGenericFontFamilySansSerif(&family);
    }
  }
  memset(built_for, 0, sizeof(built_for));
  strncpy(built_for, moonui_canvas_family_override, sizeof(built_for) - 1u);
  return family;
}

/* 度量/绘制共用的字体（调用方 GdipDeleteFont）。字号按"物理像素"契约
 * （adapter.h：font_permille/1000；MOONUI_GDIP_UNIT_PIXEL 不再让 GDI+ 按 DPI 抬一档），
 * weight 2=Bold，0/1=Regular（Medium 平台可退 Regular）。失败返回 0。 */
static GpFont *moonui_canvas_font_of(int font_permille, int weight) {
  GpFontFamily *family = moonui_canvas_font_family();
  GpFont *font = 0;
  int style = (weight == 2) ? MOONUI_GDIP_FONTSTYLE_BOLD : 0;
  if (family == 0) {
    return 0;
  }
  if (GdipCreateFont(family, (REAL)((double)font_permille / 1000.0),
                     style, MOONUI_GDIP_UNIT_PIXEL, &font) != MOONUI_GDIP_OK) {
    return 0;
  }
  return font;
}

moonui_ptr moonui_canvas_create(void) {
  MoonuiCanvas *c;
  TRACE("canvas_create");
  moonui_native_ensure_gdiplus();
  c = (MoonuiCanvas *)calloc(1, sizeof(MoonuiCanvas));
  if (c == 0) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)c;
}

/* T190 P1：测试专用钩子（与 mac 半同形）。Windows 无 Metal，backend 直接忽略，
 * 退化为普通画布创建——只为在链接期提供符号，不影响任何生产路径。 */
moonui_ptr moonui_canvas_create_with_backend(int backend) {
  (void)backend;
  return moonui_canvas_create();
}

int moonui_canvas_destroy(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_destroy");
  if (c == 0) {
    return -1;
  }
  /* 摘掉可能还挂在窗口上的 prop（borrowed 指针不能比画布活得久） */
  if (c->window != 0) {
    RemovePropW(c->window, moonui_native_canvas_prop);
  }
  if (c->view != 0) {
    RemovePropW(c->view, moonui_native_canvas_prop);
  }
  moonui_canvas_drop_frame(c);
  free(c);
  return 0;
}

int moonui_canvas_begin_frame(moonui_ptr canvas, int w, int h) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  BITMAPINFO bi;
  HDC screen;
  void *bits = 0;
  TRACE("canvas_begin_frame");
  if (c == 0 || w <= 0 || h <= 0) {
    return -1;
  }
  moonui_native_ensure_gdiplus();
  moonui_canvas_drop_frame(c);
  /* 32bpp 顶行在前的 DIB：位面即 BGRA 预乘，行距 = w*4（无对齐残边，
   * read_pixel 与 GDI+ 的 scan0 布局同一把尺）。 */
  memset(&bi, 0, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h; /* 负数 = 顶行在前（与 mac calloc 的行序一致） */
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  screen = GetDC(0);
  c->dib = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, 0, 0);
  ReleaseDC(0, screen);
  if (c->dib == 0 || bits == 0) {
    moonui_canvas_drop_frame(c);
    return -1;
  }
  /* CreateDIBSection 的位面不保证清零（mac 侧是 calloc），帧的语义是
   * "新帧不留底"，这里自己清。 */
  memset(bits, 0, (size_t)w * (size_t)h * 4);
  c->data = (unsigned char *)bits;
  c->w = w;
  c->h = h;
  c->row_bytes = w * 4;
  c->blit_dc = CreateCompatibleDC(0);
  if (c->blit_dc == 0) {
    moonui_canvas_drop_frame(c);
    return -1;
  }
  c->dib_old = (HBITMAP)SelectObject(c->blit_dc, c->dib);
  if (GdipCreateBitmapFromScan0(w, h, c->row_bytes, MOONUI_GDIP_PIXFMT_PARGB,
                                (BYTE *)c->data, &c->bmp) != MOONUI_GDIP_OK ||
      c->bmp == 0) {
    moonui_canvas_drop_frame(c);
    return -1;
  }
  if (GdipGetImageGraphicsContext((GpImage *)c->bmp, &c->gfx) != MOONUI_GDIP_OK ||
      c->gfx == 0) {
    moonui_canvas_drop_frame(c);
    return -1;
  }
  GdipSetSmoothingMode(c->gfx, MOONUI_GDIP_SMOOTH_ANTIALIAS);
  GdipSetTextRenderingHint(c->gfx, MOONUI_GDIP_TEXTHINT_ANTIALIAS);
  /* 新帧不带旧影：投影状态随帧清零（mac 侧每次 begin_frame 换上下文同理） */
  c->shadow_on = 0;
  return 0;
}

int moonui_canvas_end_frame(moonui_ptr canvas) {
  TRACE("canvas_end_frame");
  if (moonui_canvas_of(canvas) == 0) {
    return -1;
  }
  /* 位图就是帧（与 mac 同口径），存在性收口。 */
  return 0;
}

int moonui_canvas_save(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  GraphicsState state;
  TRACE("canvas_save");
  if (c == 0 || c->gfx == 0) {
    return -1;
  }
  if (GdipSaveGraphics(c->gfx, &state) != MOONUI_GDIP_OK) {
    return -1;
  }
  /* 令牌压栈（见 struct 段注）：restore 按配对弹。 */
  if (c->state_top >= (int)(sizeof(c->states) / sizeof(c->states[0]))) {
    return -1;
  }
  c->states[c->state_top] = state;
  c->state_top++;
  return 0;
}

int moonui_canvas_restore(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_restore");
  if (c == 0 || c->gfx == 0 || c->state_top <= 0) {
    return -1;
  }
  c->state_top--;
  if (GdipRestoreGraphics(c->gfx, c->states[c->state_top]) != MOONUI_GDIP_OK) {
    return -1;
  }
  return 0;
}

int moonui_canvas_clip_rect(moonui_ptr canvas, int x, int y, int w, int h) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_clip_rect");
  if (c == 0 || c->gfx == 0 || w <= 0 || h <= 0) {
    return -1;
  }
  /* CombineModeIntersect：与现有裁剪区相交（CG 的 ClipToRect 同语义——
   * 滚动视口那批用法嵌套裁剪才能对）。 */
  if (GdipSetClipRectI(c->gfx, x, y, w, h, MOONUI_GDIP_COMBINE_INTERSECT) != MOONUI_GDIP_OK) {
    return -1;
  }
  return 0;
}

int moonui_canvas_translate(moonui_ptr canvas, int dx, int dy) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_translate");
  if (c == 0 || c->gfx == 0) {
    return -1;
  }
  /* MOONUI_GDIP_MATRIX_APPEND = 乘在现有变换之后（作用在用户空间），与 CG 的
   * TranslateCTM 同一笔账；这里只有平移，两种序实际等价，先写死语义。 */
  if (GdipTranslateWorldTransform(c->gfx, (REAL)dx, (REAL)dy,
                                  MOONUI_GDIP_MATRIX_APPEND) != MOONUI_GDIP_OK) {
    return -1;
  }
  return 0;
}

int moonui_canvas_fill_rect(moonui_ptr canvas, int x, int y, int w, int h,
                            int radius_permille, int64_t rgb, int alpha) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  GpPath *path;
  GpBrush *brush;
  TRACE("canvas_fill_rect");
  if (c == 0 || c->gfx == 0 || w <= 0 || h <= 0) {
    return -1;
  }
  moonui_canvas_shadow_for_rect(c, x, y, w, h,
                               (double)radius_permille / 1000.0);
  path = moonui_canvas_rounded_path(x, y, w, h,
                                    (double)radius_permille / 1000.0);
  if (path == 0) {
    return -1;
  }
  if (GdipCreateSolidFill(moonui_canvas_argb(rgb, alpha), &brush) == MOONUI_GDIP_OK) {
    GdipFillPath(c->gfx, brush, path);
    GdipDeleteBrush(brush);
  }
  GdipDeletePath(path);
  return 0;
}

int moonui_canvas_blur_region(moonui_ptr canvas, int x, int y, int w, int h,
                              int radius_permille) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  int r;
  int x0;
  int y0;
  int x1;
  int y1;
  TRACE("canvas_blur_region");
  if (c == 0 || c->data == 0 || w <= 0 || h <= 0) {
    return -1;
  }
  r = (int)((double)radius_permille / 1000.0);
  if (r < 0) {
    r = 0;
  }
  if (r == 0) {
    return 0; /* 恒等（与 mac 同口径） */
  }
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
  moonui_canvas_box_blur(c->data, c->row_bytes, x0, y0, x1, y1, r);
  return 0;
}

int moonui_canvas_stroke_rect(moonui_ptr canvas, int x, int y, int w, int h,
                              int radius_permille, int64_t rgb,
                              int width_permille) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  GpPath *path;
  GpPen *pen;
  TRACE("canvas_stroke_rect");
  if (c == 0 || c->gfx == 0 || w <= 0 || h <= 0) {
    return -1;
  }
  path = moonui_canvas_rounded_path(x, y, w, h,
                                    (double)radius_permille / 1000.0);
  if (path == 0) {
    return -1;
  }
  if (GdipCreatePen1(moonui_canvas_argb(rgb, 255),
                     (REAL)((double)width_permille / 1000.0), MOONUI_GDIP_UNIT_PIXEL,
                     &pen) == MOONUI_GDIP_OK) {
    GdipDrawPath(c->gfx, pen, path);
    GdipDeletePen(pen);
  }
  GdipDeletePath(path);
  return 0;
}

int moonui_canvas_fill_linear(moonui_ptr canvas, int x, int y, int w, int h,
                              moonui_ptr stops, int n) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  int64_t *raw;
  REAL *positions;
  ARGB *colors;
  GpRectF rect;
  GpLineGradient *brush = 0;
  int i;
  int j;
  int ok = 0;
  TRACE("canvas_fill_linear");
  if (c == 0 || c->gfx == 0 || stops == 0 || n < 2 || w <= 0 || h <= 0) {
    return -1;
  }
  raw = (int64_t *)(uintptr_t)stops;
  positions = (REAL *)calloc((size_t)n, sizeof(REAL));
  colors = (ARGB *)calloc((size_t)n, sizeof(ARGB));
  if (positions == 0 || colors == 0) {
    free(positions);
    free(colors);
    return -1;
  }
  /* pos 千分 → 0..1，按 pos 升序排（adapter.h：序随意、实现侧排）——
   * 插入排序，n 是渐变端点数（个位数），不值得引快排。 */
  for (i = 0; i < n; i++) {
    double p = (double)raw[i * 2] / 1000.0;
    if (p < 0) {
      p = 0;
    }
    if (p > 1) {
      p = 1;
    }
    {
      int64_t rgb = raw[i * 2 + 1];
      REAL pos = (REAL)p;
      ARGB col = moonui_canvas_argb(rgb, 255);
      j = i - 1;
      while (j >= 0 && positions[j] > pos) {
        positions[j + 1] = positions[j];
        colors[j + 1] = colors[j];
        j--;
      }
      positions[j + 1] = pos;
      colors[j + 1] = col;
    }
  }
  rect.X = (REAL)x;
  rect.Y = (REAL)y;
  rect.Width = (REAL)w;
  rect.Height = (REAL)h;
  if (GdipCreateLineBrushFromRect(&rect, colors[0], colors[n - 1],
                                  MOONUI_GDIP_LINEAR_VERTICAL, MOONUI_GDIP_WRAP_CLAMP,
                                  &brush) == MOONUI_GDIP_OK) {
    if (GdipSetLinePresetBlend(brush, colors, positions, n) == MOONUI_GDIP_OK) {
      /* 先影后形（与 fill_rect 同一笔账），再把渐变锁在矩形里：
       * brush 的色带沿 rect 的 y 展开，FillRectangle 只画矩形自身，
       * 裁剪这一步省了——画的就是 (x,y,w,h)。 */
      moonui_canvas_shadow_for_rect(c, x, y, w, h, 0.0);
      GdipFillRectangleI(c->gfx, (GpBrush *)brush, x, y, w, h);
      ok = 1;
    }
    GdipDeleteBrush((GpBrush *)brush);
  }
  free(positions);
  free(colors);
  return ok ? 0 : -1;
}

int moonui_canvas_shadow(moonui_ptr canvas, int dx, int dy,
                         int blur_permille, int64_t rgb) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_shadow");
  if (c == 0) {
    return -1;
  }
  if (blur_permille <= 0) {
    c->shadow_on = 0; /* 清零口（adapter.h 的状态语义） */
    return 0;
  }
  c->shadow_on = 1;
  c->shadow_dx = dx;
  c->shadow_dy = dy;
  c->shadow_blur_permille = blur_permille;
  c->shadow_rgb = rgb;
  return 0;
}

int moonui_canvas_line(moonui_ptr canvas, int x0, int y0, int x1, int y1,
                       int64_t rgb, int width_permille) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  GpPen *pen;
  TRACE("canvas_line");
  if (c == 0 || c->gfx == 0) {
    return -1;
  }
  if (GdipCreatePen1(moonui_canvas_argb(rgb, 255),
                     (REAL)((double)width_permille / 1000.0), MOONUI_GDIP_UNIT_PIXEL,
                     &pen) == MOONUI_GDIP_OK) {
    GdipDrawLineI(c->gfx, pen, x0, y0, x1, y1);
    GdipDeletePen(pen);
  }
  return 0;
}

int moonui_canvas_stroke_arc(moonui_ptr canvas, int cx, int cy, int r,
                             int start_deg_permille, int sweep_deg_permille,
                             int64_t rgb, int width_permille) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  GpPath *path;
  GpPen *pen;
  double a0;
  double sweep;
  double dth;
  double th;
  double span;
  long n;
  long i;
  TRACE("canvas_stroke_arc");
  if (c == 0 || c->gfx == 0) {
    return -1;
  }
  if (r <= 0 || width_permille <= 0) {
    return -1;
  }
  if (sweep_deg_permille == 0) {
    return 0; /* 进度 0% 是正常状态，不是错误 */
  }
  /* 与 mac 半同一根尺：角度直接定义在 y 向下的屏幕坐标系里（点 =
   * cx + r·cosθ, cy + r·sinθ），按 ~5° 采样成折线再一次性描出——
   * 不用 GdipDrawArc 的同款理由：省一层角度翻转的镜像坑，负扫角原样
   * 保号（GDI+ 的 AddArc 与 CG 的 AddArc 一样会把负 delta 补成 2π）。
   * |扫过| ≥ 360 画整圈。 */
  a0 = (double)start_deg_permille / 1000.0 * 3.14159265358979323846 / 180.0;
  sweep = (double)sweep_deg_permille / 1000.0 * 3.14159265358979323846 / 180.0;
  if (sweep >= 2.0 * 3.14159265358979323846 - 0.001) {
    sweep = 2.0 * 3.14159265358979323846;
  } else if (sweep <= -2.0 * 3.14159265358979323846 + 0.001) {
    sweep = -2.0 * 3.14159265358979323846;
  }
  span = sweep;
  if (span < 0) {
    span = -span;
  }
  n = (long)(span / (3.14159265358979323846 / 36.0)); /* 每 ~5° 一段 */
  if (n < 2) {
    n = 2;
  }
  if (n > 720) {
    n = 720;
  }
  dth = sweep / (double)n;
  if (GdipCreatePath(MOONUI_GDIP_FILLMODE_WINDING, &path) != MOONUI_GDIP_OK) {
    return -1;
  }
  /* 折线接龙：AddPathLine 逐段首尾相接（起段 v0→v1，其后 v_i→v_{i+1}），
   * 段与段共点才连得成一条——两个点写一样就是零长度段，什么都描不出。 */
  {
    double x0 = cx + (double)r * cos(a0);
    double y0 = cy + (double)r * sin(a0);
    double x1;
    double y1;
    for (i = 1; i <= n; i++) {
      th = a0 + dth * (double)i;
      x1 = cx + (double)r * cos(th);
      y1 = cy + (double)r * sin(th);
      GdipAddPathLine(path, (REAL)x0, (REAL)y0, (REAL)x1, (REAL)y1);
      x0 = x1;
      y0 = y1;
    }
  }
  if (GdipCreatePen1(moonui_canvas_argb(rgb, 255),
                     (REAL)((double)width_permille / 1000.0), MOONUI_GDIP_UNIT_PIXEL,
                     &pen) == MOONUI_GDIP_OK) {
    GdipDrawPath(c->gfx, pen, path);
    GdipDeletePen(pen);
  }
  GdipDeletePath(path);
  return 0;
}

int moonui_canvas_fill_polygon(moonui_ptr canvas, moonui_ptr points, int n,
                               int64_t rgb, int alpha) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  int32_t *raw;
  GpPath *path;
  GpBrush *brush;
  int i;
  TRACE("canvas_fill_polygon");
  if (c == 0 || c->gfx == 0 || points == 0 || n < 3) {
    return -1;
  }
  raw = (int32_t *)(uintptr_t)points;
  if (GdipCreatePath(MOONUI_GDIP_FILLMODE_WINDING, &path) != MOONUI_GDIP_OK) {
    return -1;
  }
  /* 首尾相连：GdipAddPathLine 逐段接龙（v0→v1 起，其后 v_i→v_{i+1}），
   * ClosePathFigure 把最后一点连回第一点（调用方两种写法画出来一样，
   * 与 mac 的口径同）。绕向用非零（FillModeWinding）——even-odd 会让
   * 自交多边形挖洞。 */
  for (i = 0; i + 1 < n; i++) {
    GdipAddPathLine(path, (REAL)raw[i * 2], (REAL)raw[i * 2 + 1],
                    (REAL)raw[(i + 1) * 2], (REAL)raw[(i + 1) * 2 + 1]);
  }
  GdipClosePathFigure(path);
  if (GdipCreateSolidFill(moonui_canvas_argb(rgb, alpha), &brush) == MOONUI_GDIP_OK) {
    GdipFillPath(c->gfx, brush, path);
    GdipDeleteBrush(brush);
  }
  GdipDeletePath(path);
  return 0;
}

int64_t moonui_canvas_measure_text(const char *utf8, int len,
                                   int font_permille, int weight) {
  GpFont *font;
  GpRectF layout;
  GpRectF bounds;
  INT fitted = 0;
  INT lines = 0;
  GpGraphics *gfx;
  int chars;
  LPWSTR w;
  TRACE("canvas_measure_text");
  if (utf8 == 0 || len <= 0) {
    return -1;
  }
  moonui_native_ensure_gdiplus();
  gfx = moonui_canvas_measure_graphics();
  font = moonui_canvas_font_of(font_permille, weight);
  w = moonui_native_utf16_of(utf8, len);
  if (gfx == 0 || font == 0 || w == 0) {
    if (font != 0) {
      GdipDeleteFont(font);
    }
    free(w);
    return -1;
  }
  chars = (int)lstrlenW(w);
  layout.X = 0.0f;
  layout.Y = 0.0f;
  layout.Width = 1000000.0f; /* 布局框只管"不折行"，宽度本身不进账 */
  layout.Height = 1000000.0f;
  if (GdipMeasureString(gfx, w, chars, font, &layout, 0, &bounds, &fitted,
                        &lines) != MOONUI_GDIP_OK) {
    GdipDeleteFont(font);
    free(w);
    return -1;
  }
  GdipDeleteFont(font);
  free(w);
  /* (w<<32)|h，四舍五入（mac 同口径）。 */
  return ((int64_t)(bounds.Width + 0.5f) << 32) |
         (int64_t)(bounds.Height + 0.5f);
}

int moonui_canvas_draw_text(moonui_ptr canvas, const char *utf8, int len,
                            int x, int y, int font_permille, int weight,
                            int64_t rgb) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  GpFont *font;
  GpBrush *brush = 0;
  GpRectF layout;
  int chars;
  LPWSTR w;
  TRACE("canvas_draw_text");
  if (c == 0 || c->gfx == 0 || utf8 == 0 || len <= 0) {
    return -1;
  }
  font = moonui_canvas_font_of(font_permille, weight);
  w = moonui_native_utf16_of(utf8, len);
  if (font == 0 || w == 0) {
    if (font != 0) {
      GdipDeleteFont(font);
    }
    free(w);
    return -1;
  }
  if (GdipCreateSolidFill(moonui_canvas_argb(rgb, 255), &brush) != MOONUI_GDIP_OK) {
    GdipDeleteFont(font);
    free(w);
    return -1;
  }
  chars = (int)lstrlenW(w);
  layout.X = (REAL)x; /* y 是顶边（adapter.h）：布局框从 (x,y) 起 */
  layout.Y = (REAL)y;
  layout.Width = 1000000.0f;
  layout.Height = 1000000.0f;
  GdipDrawString(c->gfx, w, chars, font, &layout, 0, brush);
  GdipDeleteBrush(brush);
  GdipDeleteFont(font);
  free(w);
  return 0;
}

int moonui_canvas_draw_image(moonui_ptr canvas, const char *bytes, int len,
                             int x, int y, int w, int h) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  HBITMAP hbm;
  BITMAP bm;
  GpBitmap *img = 0;
  TRACE("canvas_draw_image");
  if (c == 0 || c->gfx == 0 || bytes == 0 || len <= 0 || w <= 0 || h <= 0) {
    return -1;
  }
  /* 解码归平台（沿 T86⑤ 的约定）：WIC 解到 32bpp 预乘、顶行在前的
   * DIB——正好是 GDI+ PARGB 的 scan0 布局，GdipCreateBitmapFromScan0
   * 包一层直接画，缩放到目标矩形。 */
  hbm = moonui_native_wic_decode_data((const BYTE *)bytes, len);
  if (hbm == 0) {
    return -1;
  }
  if (GetObjectW(hbm, sizeof(bm), &bm) == 0 || bm.bmWidth <= 0 ||
      bm.bmHeight <= 0 || bm.bmBits == 0) {
    DeleteObject(hbm);
    return -1;
  }
  if (GdipCreateBitmapFromScan0(bm.bmWidth, bm.bmHeight, bm.bmWidthBytes,
                                MOONUI_GDIP_PIXFMT_PARGB,
                                (BYTE *)bm.bmBits, &img) != MOONUI_GDIP_OK) {
    DeleteObject(hbm);
    return -1;
  }
  GdipDrawImageRectI(c->gfx, (GpImage *)img, x, y, w, h);
  GdipDisposeImage((GpImage *)img);
  DeleteObject(hbm);
  return 0;
}

int64_t moonui_canvas_read_pixel(moonui_ptr canvas, int x, int y) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  const unsigned char *px;
  unsigned char r;
  unsigned char g;
  unsigned char b;
  unsigned char a;
  TRACE("canvas_read_pixel");
  if (c == 0 || c->data == 0) {
    return -1;
  }
  if (x < 0 || y < 0 || x >= c->w || y >= c->h) {
    return -1;
  }
  px = c->data + (size_t)y * (size_t)c->row_bytes + (size_t)x * 4;
  b = px[0]; /* DIB 位面是 B,G,R,A（见本节头注） */
  g = px[1];
  r = px[2];
  a = px[3];
  if (a == 0) {
    return -1;
  }
  /* 预乘展开（mac 同口径）：不透明像素逐位精确，半透明按 a 归一。 */
  return ((int64_t)((r * 255) / a) << 16) | ((int64_t)((g * 255) / a) << 8) |
         (int64_t)((b * 255) / a);
}

int moonui_canvas_attach_window(moonui_ptr canvas, moonui_ptr window) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  HWND hwnd;
  TRACE("canvas_attach_window");
  if (c == 0) {
    return -1;
  }
  hwnd = (HWND)(uintptr_t)window;
  if (hwnd == 0 || !IsWindow(hwnd)) {
    return -1;
  }
  c->window = hwnd;
  return 0;
}

/* 把当前帧预乘混进 dc 的客户区（WM_PAINT 的公共尾巴：顶层窗口的 present
 * 与 kind 18 自绘面的 present_view 共用）。帧与客户区不等大时拉伸
 * （mac 的 layer gravity=resize 同一口径）。 */
static int moonui_native_canvas_paint_layer(HWND hwnd, HDC dc) {
  MoonuiCanvas *c =
      (MoonuiCanvas *)(uintptr_t)GetPropW(hwnd, moonui_native_canvas_prop);
  RECT rc;
  BLENDFUNCTION blend;
  if (c == 0 || c->data == 0 || c->blit_dc == 0 || dc == 0) {
    return 0;
  }
  if (GetClientRect(hwnd, &rc) == 0 || rc.right <= 0 || rc.bottom <= 0) {
    return 0;
  }
  blend.BlendOp = AC_SRC_OVER;
  blend.BlendFlags = 0;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA; /* 源是预乘，逐像素 alpha 走这条 */
  AlphaBlend(dc, 0, 0, rc.right, rc.bottom, c->blit_dc, 0, 0, c->w, c->h,
             blend);
  return 1;
}

int moonui_canvas_present(moonui_ptr canvas) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  TRACE("canvas_present");
  if (c == 0 || c->window == 0 || c->data == 0) {
    return -1;
  }
  SetPropW(c->window, moonui_native_canvas_prop, (HANDLE)c);
  moonui_native_invalidate(c->window, 0);
  return 0;
}

int moonui_canvas_present_view(moonui_ptr canvas, moonui_ptr view) {
  MoonuiCanvas *c = moonui_canvas_of(canvas);
  HWND hwnd;
  TRACE("canvas_present_view");
  if (c == 0 || c->data == 0) {
    return -1;
  }
  hwnd = (HWND)(uintptr_t)view;
  if (hwnd == 0 || !IsWindow(hwnd)) {
    return -1;
  }
  SetPropW(hwnd, moonui_native_canvas_prop, (HANDLE)c);
  c->view = hwnd; /* 销毁时摘 prop 用（见 canvas_destroy） */
  moonui_native_invalidate(hwnd, 0);
  return 0;
}

/* ---- 自定义绘制面（`T101`/`T111`）：宿主子窗口 + 槽位 + 探针 ----
 *
 * 宿主是 moonui_native_custom_class_name 那只子窗口（过程见
 * moonui_native_custom_proc）：占住布局矩形、WM_PAINT 贴画布帧、点击/
 * 焦点/捕获各就各位。这一节是 ABI 的四件：槽位登记、焦点 opt-in、像素
 * 探针、合成点击——返回码与 mac 半的 adapter_native.m 同一套阶梯。 */

/* 根窗口客户区坐标 → 那个位置上的自绘面（kind 18）。空白处 / 别的控件
 * 都报 0；命中判据用 kind 记号而不是类名，与 focus_widget_in_window 同
 * 一把尺（类名会撞 STATIC，记号只在我们打的窗口上）。 */
static HWND moonui_native_custom_hit(HWND win, int x, int y) {
  POINT pt;
  HWND hit;
  HWND up;
  pt.x = x;
  pt.y = y;
  hit = ChildWindowFromPoint(win, pt);
  if (hit == 0) {
    return 0;
  }
  for (up = hit; up != 0 && up != win; up = GetParent(up)) {
    if (moonui_native_kind_of_hwnd(up) == 18) {
      return up;
    }
  }
  return 0;
}

/* T256：合成点击的回退命中——找 kind 17 的面板。Windows 半把 Panel 的子树
 * 平铺到父窗（孩子是兄弟、不是子窗口），所以只能从命中窗口往上找；且必须
 * 真的装过 customclick 槽位才算可点面，免得把一块纯装饰底板当成 Click 源、
 * 把既有"点空白处报 -4"的负控制吃掉。像素探针不认这一档（它只读画布帧）。 */
static HWND moonui_native_panel_hit(HWND win, int x, int y) {
  POINT pt;
  HWND hit;
  HWND up;
  pt.x = x;
  pt.y = y;
  hit = ChildWindowFromPoint(win, pt);
  if (hit == 0) {
    return 0;
  }
  for (up = hit; up != 0 && up != win; up = GetParent(up)) {
    if (moonui_native_kind_of_hwnd(up) == 17 &&
        GetPropW(up, moonui_native_slot_customclick_prop) != 0) {
      return up;
    }
  }
  return 0;
}

/* 根客户区坐标换算到目标窗口的客户区（两个空间都要过屏幕一站）。 */
static LPARAM moonui_native_local_lparam(HWND win, HWND target, int x, int y) {
  POINT pt;
  pt.x = x;
  pt.y = y;
  ClientToScreen(win, &pt);
  ScreenToClient(target, &pt);
  return MAKELPARAM((WORD)(unsigned)pt.x, (WORD)(unsigned)pt.y);
}

int moonui_native_custom_on_clicked(moonui_ptr c, moonui_closure_fn fn,
                                    void *closure) {
  HWND hwnd = moonui_native_hwnd(c);
  int kind;
  int slot;
  TRACE("custom_on_clicked");
  /* T256：面板（kind 17）与自绘面（kind 18）共用"按下并原地抬起算一次"的
   * 派发形状，Click 源都挂在这条槽位上。mac 半的 MoonuiClickPanel 已随
   * T256 落地，Windows 半此前只认 18，共享层给 Panel 装回调时一律被拒：
   * 六条建 Panel 的真窗判据当场抛错、跳过 terminate，全局句柄表留下 5 个
   * 孤儿，后面 33 条以 native_live_handles() 收尾的判据连锁红（2026-11-11）。 */
  if (hwnd == 0) {
    return -1;
  }
  kind = moonui_native_kind_of_hwnd(hwnd);
  if (kind != 18 && kind != 17) {
    return -1;
  }
  slot = moonui_native_take_slot((void *)(uintptr_t)c, fn, closure);
  if (slot < 0) {
    return -1;
  }
  moonui_native_set_slot_prop(hwnd, moonui_native_slot_customclick_prop, slot);
  return 0;
}

/* 焦点 opt-in（`T102` 第十一刀）：自绘面没有"天生可聚焦"的原生属性，这里
 * 同时做两件事——记 focusable 标志（过程在按下那一刻按它决定要不要
 * SetFocus 自己）与拨 WS_TABSTOP（Tab 链）。默认全关：只画东西的面不该
 * 挤进焦点体系（mac 的 acceptsFirstResponder 默认 NO 同一条理由）。 */
int moonui_native_custom_set_focusable(moonui_ptr c, int on) {
  HWND hwnd = moonui_native_hwnd(c);
  LONG_PTR style;
  TRACE("custom_set_focusable");
  if (hwnd == 0 || moonui_native_kind_of_hwnd(hwnd) != 18) {
    return -1;
  }
  if (on) {
    SetPropW(hwnd, moonui_native_custom_focusable_prop, (HANDLE)1);
  } else {
    RemovePropW(hwnd, moonui_native_custom_focusable_prop);
  }
  style = GetWindowLongPtrW(hwnd, GWL_STYLE);
  if (on) {
    SetWindowLongPtrW(hwnd, GWL_STYLE, style | WS_TABSTOP);
  } else {
    SetWindowLongPtrW(hwnd, GWL_STYLE, style & ~(LONG_PTR)WS_TABSTOP);
  }
  return 0;
}

/* 读自绘面当前帧的一个像素：0xRRGGBBAA（预乘原值，与 mac 的 probe 同一
 * 口径——不透明帧上就是 0xRRGGBBFF）。读的是画布缓冲而不是屏幕：诚实
 * 边界与 mac 一致（证明"帧里有这些像素"，不证明合成器扫屏）。 */
int64_t moonui_native_custom_probe(const char *title, int title_len, int x, int y) {
  HWND win;
  HWND face;
  MoonuiCanvas *c;
  POINT pt;
  const unsigned char *px;
  TRACE("custom_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -1;
  }
  face = moonui_native_custom_hit(win, x, y);
  if (face == 0) {
    return -2; /* 空白处或别的控件 */
  }
  c = (MoonuiCanvas *)(uintptr_t)GetPropW(face, moonui_native_canvas_prop);
  if (c == 0 || c->data == 0) {
    return -3; /* 面在、但还没 present 过 */
  }
  pt.x = x;
  pt.y = y;
  ClientToScreen(win, &pt);
  ScreenToClient(face, &pt);
  if (pt.x < 0 || pt.y < 0 || pt.x >= c->w || pt.y >= c->h) {
    return -2;
  }
  px = c->data + (size_t)pt.y * (size_t)c->row_bytes + (size_t)pt.x * 4;
  /* DIB 位面是 B,G,R,A（见画布节头注），对外换成 RGBA 打包 */
  return ((int64_t)px[2] << 24) | ((int64_t)px[1] << 16) |
         ((int64_t)px[0] << 8) | (int64_t)px[3];
}

/* 自绘面「补底」的像素判据（`T311`，判定见 `moonui_native_custom_fill_under`）。
 *
 * 为什么不直接读屏幕：屏幕这块原本是什么色由环境决定（桌面、背后的窗口），
 * 判据拿不到稳定期望——2026-11-17 那个 bug 的现场恰好就是"背后窗口的一张
 * 快照"，读屏幕等于把别人的界面当期望值。换成**离屏重画**：自己开一张填满
 * 哨兵色（洋红）的 DIB、把 `WM_PRINTCLIENT` 打给这块面，再读回那一点。
 * 补底真发生过 ⇒ 哨兵被底下那块底色盖掉；没发生 ⇒ 读回哨兵本身。
 *
 * 与 `moonui_native_custom_probe` 的分工：那条读**画布帧**（"这张位图里有什么"），
 * 这条读**合成之后**的结果（"这块面显示出来是什么"）。画布帧可以整块透明，
 * 面显示出来却不该是脏的——两者的差别正好是这一层。
 *
 * 坐标口径同 custom_probe（根窗口客户区、物理像素）。返回 0xRRGGBB；
 * -1 找不到窗口 / -2 这一处不是自绘面 / -3 取图失败。命中哨兵本身就是
 * "没补底"，判据的期望是底下那块底色的值。 */
int64_t moonui_native_custom_under_probe(const char *title, int title_len,
                                         int x, int y) {
  HWND win;
  HWND face;
  POINT pt;
  RECT fr;
  BITMAPINFO bi;
  void *bits = 0;
  HDC mem;
  HBITMAP dib;
  HBITMAP old;
  int w;
  int h;
  int64_t out = -3;
  TRACE("custom_under_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -1;
  }
  face = moonui_native_custom_hit(win, x, y);
  if (face == 0) {
    return -2; /* 空白处或别的控件 */
  }
  if (GetClientRect(face, &fr) == 0) {
    return -3;
  }
  w = fr.right - fr.left;
  h = fr.bottom - fr.top;
  if (w <= 0 || h <= 0) {
    return -3;
  }
  pt.x = x;
  pt.y = y;
  ClientToScreen(win, &pt);
  ScreenToClient(face, &pt);
  if (pt.x < 0 || pt.y < 0 || pt.x >= w || pt.y >= h) {
    return -2;
  }
  memset(&bi, 0, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h; /* 顶行在前，与画布节同一把尺 */
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  mem = CreateCompatibleDC(0);
  if (mem == 0) {
    return -3;
  }
  dib = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, 0, 0);
  if (dib == 0 || bits == 0) {
    DeleteDC(mem);
    return -3;
  }
  old = (HBITMAP)SelectObject(mem, dib);
  {
    /* 哨兵：B,G,R,A = FF,00,FF,FF。整块铺满，面里任何一点没被补底都留得住。 */
    unsigned char *p = (unsigned char *)bits;
    int total = w * h;
    int i;
    for (i = 0; i < total; i++) {
      p[i * 4 + 0] = 0xFF;
      p[i * 4 + 1] = 0x00;
      p[i * 4 + 2] = 0xFF;
      p[i * 4 + 3] = 0xFF;
    }
  }
  SendMessageW(face, WM_PRINTCLIENT, (WPARAM)mem, PRF_CLIENT);
  {
    const unsigned char *px = (const unsigned char *)bits +
                              (size_t)pt.y * (size_t)w * 4 + (size_t)pt.x * 4;
    out = ((int64_t)px[2] << 16) | ((int64_t)px[1] << 8) | (int64_t)px[0];
  }
  SelectObject(mem, old);
  DeleteObject(dib);
  DeleteDC(mem);
  return out;
}

/* 点自定义面：SendMessage 造一对按下/抬起，走的是面自己的窗口过程——
 * "按下并原地抬起才发 Click"那条判据真跑一遍（mac 那半直调 mouseDown:/
 * mouseUp: 同一条路：钩子看不见 SendMessage，探针只归面）。 */
int moonui_native_click_custom_in_window(const char *title, int title_len, int x,
                                         int y) {
  HWND win;
  HWND face;
  LPARAM lp;
  TRACE("click_custom_in_window");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  face = moonui_native_custom_hit(win, x, y);
  if (face == 0) {
    face = moonui_native_panel_hit(win, x, y);
  }
  if (face == 0) {
    return -4; /* 空白处或别的控件 */
  }
  lp = moonui_native_local_lparam(win, face, x, y);
  SendMessageW(face, WM_LBUTTONDOWN, MK_LBUTTON, lp);
  SendMessageW(face, WM_LBUTTONUP, 0, lp);
  return 0;
}

/* 按住自定义面不抬（`T102` 第十三刀的测试入口）：真手指按下的等价物是
 * SendMessage 下去 WM_LBUTTONDOWN——过程的 SetCapture 在返回时已经生效，
 * 测试可以在"按住"这个状态下继续投移动/抬起（经 send_mouse_in_window，
 * 那边的 GetCapture 路由会跟着捕获走）。Windows 半专属（mac 的等价入口
 * 归 T103 那批补）。 */
int moonui_native_press_custom_in_window(const char *title, int title_len,
                                         int x, int y) {
  HWND win;
  HWND face;
  TRACE("press_custom_in_window");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  face = moonui_native_custom_hit(win, x, y);
  if (face == 0) {
    return -4;
  }
  SendMessageW(face, WM_LBUTTONDOWN, MK_LBUTTON,
               moonui_native_local_lparam(win, face, x, y));
  return 0;
}

/* 控件分层 alpha 读回探针（`T89①` 真跑判据，adapter.h 有声明）：给真窗
 * 测试对账 set_opacity 的落点——置位时 alpha 字节、撤位（1000/出界夹到
 * 1000）时 -1。命中走 ChildWindowFromPoint，与自绘面那批探针同一把尺。
 * 负坐标 = 问顶层窗口自己——T89① 真跑实测（2026-10-22，Win11 22631
 * RDP 会话）：WS_EX_LAYERED 在子窗口上被系统整体拒绝（创建报
 * ERROR_INVALID_PARAMETER、SetWindowLong 运行时置位被静默剥掉、
 * SetLayeredWindowAttributes 跟着失败），顶层窗口则完全正常；产品语义
 * 因此收在"顶层生效"（见 set_layered_alpha 的注），负坐标是顶层路径
 * 的读回口。Windows 半专属。 */
int moonui_native_widget_alpha_probe(const char *title, int title_len,
                                     int x, int y) {
  HWND win;
  HWND target;
  POINT pt;
  LONG style;
  BYTE alpha;
  DWORD flags;
  TRACE("widget_alpha_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  if (x < 0 || y < 0) {
    /* 负坐标 = 问顶层窗口自己（T89① 的产品语义在 Windows 落在顶层：
     * 子窗口分层被系统剥掉，见 set_layered_alpha 的注）。 */
    target = win;
  } else {
    pt.x = x;
    pt.y = y;
    target = ChildWindowFromPoint(win, pt);
    if (target == 0) {
      return -3;
    }
  }
  style = GetWindowLongW(target, GWL_EXSTYLE);
  if ((style & WS_EX_LAYERED) == 0) {
    return -1;
  }
  if (GetLayeredWindowAttributes(target, 0, &alpha, &flags) == 0) {
    return -3;
  }
  return (int)alpha;
}

/* 子控件兄弟裁剪读回探针（2026-10-22 lunamusic"整窗空白"那条的判据）：
 * 逐只直接子窗口看 WS_CLIPSIBLINGS 在不在一份。缺这一位的子控件重画时会把
 * 自己的整块矩形刷成类底色，压在上面的兄弟（标签/按钮）整片被盖掉——现象是
 * "打开全空白，鼠标划过的地方才显形"。
 *
 * 返回通道走 out 参数太笨（adapter.h 那排探针都是一进一出），这里把"扫过几
 * 只 / 缺几只"打包进返回值：`(缺少数 << 32) | (扫过数)`，全齐时高 32 位为
 * 0。测试靠这两档同时钉住"探针真的扫到了控件"（低 32 位非零）与"一只都不
 * 许缺"（高 32 位为 0）——只判高 32 位的话，扫到 0 只也满足，等于空转。 */
int64_t moonui_native_panel_class_style_probe(void) {
  WNDCLASSW wc;
  if (GetClassInfoW(GetModuleHandleW(0), moonui_native_panel_class_name,
                    &wc) == 0) {
    return -2;
  }
  return (int64_t)wc.style;
}

int64_t moonui_native_clipsiblings_probe(const char *title, int title_len) {
  HWND win;
  HWND child;
  int64_t scanned = 0;
  int64_t missing = 0;
  TRACE("clipsiblings_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  child = GetWindow(win, GW_CHILD);
  while (child != 0) {
    scanned += 1;
    if ((GetWindowLongW(child, GWL_STYLE) & WS_CLIPSIBLINGS) == 0) {
      missing += 1;
    }
    child = GetWindow(child, GW_HWNDNEXT);
  }
  return (missing << 32) | scanned;
}

/* 一只子窗口"整块矩形归不归自己填"。`WS_EX_TRANSPARENT` 该不该挂就认这个
 * （见 create_control 段注）。判据取自**它实际画不画**，不按 kind 表拍脑袋：
 *   15 滚动视口  ：过程里没有 WM_PAINT，永远不画。
 *   17 面板      ：按底色——`bg < 0` 是透明底板，什么都不画。
 *   11 单选容器  ：类背景 NULL，过程只有转发，永远不画。
 *   18 自绘面    ：贴了画布帧才画（没帧时 DefWindowProc 也没有类背景可刷）。
 *   其余         ：系统控件，自己的类背景填满，算"会画"。 */
static int moonui_native_paints_nothing(HWND hwnd) {
  int kind = moonui_native_kind_of_hwnd(hwnd);
  if (kind == 15) {
    return 1;
  }
  if (kind == 17) {
    return moonui_native_rgb_prop(hwnd, moonui_native_bg_prop) < 0;
  }
  if (kind == 11) {
    return 1;
  }
  if (kind == 18) {
    return GetPropW(hwnd, moonui_native_canvas_prop) == 0;
  }
  return 0;
}

/* `WS_EX_TRANSPARENT` 的双向读回探针（`T117` 的判据）。
 *
 * 为什么单开一条而不是并进 `clipsiblings_probe`：那两位管的是两件事
 * （"我画时别碰兄弟" / "我不画时兄弟别停"），一条探针打包四档读起来没法诊断。
 *
 * **两个方向都要查**，这是 2026-10-23 当场挨的那一口教出来的：第一版判据是
 * "所有子窗口都得带这个位"，结果铺满整窗的不透明 Panel 也被送到了最后画，
 * 变成盖住一切的覆盖层（打开一片蓝、鼠标划过冒出几颗按钮）。所以判据从
 * 单向改成双向——`hole`（不画却没带 = 会留洞）与 `overlay`（会画却带了 =
 * 压住兄弟）**都必须是 0**。任一个方向单独为零都说明不了问题。
 *
 * 打包：`(overlay << 48) | (hole << 32) | (first_hole_kind << 16) | scanned`，
 * 每档 16 位（子窗口数量级是几百，够）。`first_hole_kind` 记"第一只留洞的子窗口
 * 的 kind + 1"，纯粹为了红的时候能一眼看出是哪种控件——判据只认 `hole` 与
 * `overlay` 两档。`-2` = 窗口名找不到。 */
int64_t moonui_native_transparent_probe(const char *title, int title_len) {
  HWND win;
  HWND child;
  int64_t scanned = 0;
  int64_t hole = 0;
  int64_t overlay = 0;
  int64_t first_hole_kind = 0;
  TRACE("transparent_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  child = GetWindow(win, GW_CHILD);
  while (child != 0) {
    int paints_nothing = moonui_native_paints_nothing(child);
    int flagged =
        (GetWindowLongW(child, GWL_EXSTYLE) & WS_EX_TRANSPARENT) != 0;
    scanned += 1;
    if (paints_nothing && !flagged) {
      if (hole == 0) {
        first_hole_kind = moonui_native_kind_of_hwnd(child) + 1;
      }
      hole += 1;
    } else if (!paints_nothing && flagged) {
      overlay += 1;
    }
    child = GetWindow(child, GW_HWNDNEXT);
  }
  return (overlay << 48) | (hole << 32) | (first_hole_kind << 16) | scanned;
}

/* 透明标签的联动失效读回探针（`T140` 的判据，格式在 adapter.h）。
 *
 * 为什么量更新区而不是像素：`WM_PRINTCLIENT` / `PrintWindow` 都是离屏重画，
 * 走的正是"应用自己那份"绘制顺序，把"这一轮有没有轮到标签"这件事整个抹平了
 * ——2026-10-28 之前那一批真窗读数（`PrintWindow` 数亮像素）在两种构建上会
 * 在 0 与 442 之间跳，正是这个原因。更新区是系统自己记的账：底失效之后标签
 * 那一格脏没脏，一读就知道，不看绘制路径、不看前后缓冲。
 *
 * `T318` 之后"脏没脏"这条读数**恒为 0**：底失效时顺手把标签也画掉了，更新区
 * 自然空。所以判据改成读 `moonui_overlay_pairs` 的增量（位 10）——配对上了
 * 就是"这一轮轮到了标签"，那是比"脏着"更靠前的同一个事实，且不受同步落笔
 * 影响。位 9 保留读回（`dirty_after`），留着给以后诊断用，判据不再断言。
 *
 * 样本：第一只带 `WS_EX_TRANSPARENT` 的直属子窗口（= 无底标签），配一只与它
 * 相交、自己会画底、同父的兄弟。清场用 `ValidateRect` 而不是 `UpdateWindow`：
 * 判据只对更新区负责，不该顺带依赖标签过程有没有调 `BeginPaint`。 */
int64_t moonui_native_overlay_probe(const char *title, int title_len) {
  HWND win;
  HWND child;
  HWND label = 0;
  HWND base = 0;
  RECT lr;
  RECT br;
  RECT hit;
  int64_t scanned = 0;
  int64_t flagged = 0;
  int64_t packed;
  int64_t dirty_before = 0;
  int64_t dirty_after = 0;
  int64_t paired_now = 0;
  TRACE("overlay_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return 1;
  }
  child = GetWindow(win, GW_CHILD);
  while (child != 0) {
    scanned += 1;
    if ((GetWindowLongW(child, GWL_EXSTYLE) & WS_EX_TRANSPARENT) != 0) {
      flagged += 1;
      if (label == 0) {
        label = child;
      }
    }
    child = GetWindow(child, GW_HWNDNEXT);
  }
  if (label == 0) {
    return 2 | (flagged << 16) | ((int64_t)moonui_native_overlay_len << 32) |
           (scanned << 48);
  }
  if (GetWindowRect(label, &lr) != 0) {
    child = GetWindow(win, GW_CHILD);
    while (child != 0) {
      if (child != label && GetParent(child) == GetParent(label) &&
          !moonui_native_paints_nothing(child) &&
          GetWindowRect(child, &br) != 0 &&
          IntersectRect(&hit, &lr, &br) != 0) {
        base = child;
        break;
      }
      child = GetWindow(child, GW_HWNDNEXT);
    }
  }
  if (base == 0) {
    return 3 | (flagged << 16) | ((int64_t)moonui_native_overlay_len << 32) |
           (scanned << 48);
  }
  /* 清场：标签手里可能还攥着上一轮留下的脏格，那不是这次判据的答案。 */
  ValidateRect(label, 0);
  if (GetUpdateRect(label, 0, FALSE) != 0) {
    dirty_before = 1;
  }
  /* 走产品路径失效那只底（悬停重推样式也走这一条），看标签跟不跟。 */
  {
    int pairs_before = moonui_overlay_pairs;
    moonui_native_invalidate(base, 0);
    if (moonui_overlay_pairs > pairs_before) {
      paired_now = 1;
    }
  }
  if (GetUpdateRect(label, 0, FALSE) != 0) {
    dirty_after = 1;
  }
  /* 收尾：先画底再画标签，与同一轮 GDI 的落笔顺序一致，画面也是补好的样子；
   * 万一标签过程没在 `WM_PAINT` 里 `BeginPaint`，`ValidateRect` 兜一次，免得
   * 把脏区留给后面的断言。 */
  UpdateWindow(base);
  UpdateWindow(label);
  ValidateRect(label, 0);
  packed = ((int64_t)moonui_native_overlay_len << 32) | (scanned << 48);
  packed |= flagged << 16;
  packed |= dirty_before << 8;
  packed |= dirty_after << 9;
  packed |= (int64_t)paired_now << 10;
  return packed;
}

/* 沉浸式标题栏读回探针（`T116` 的判据，格式在 adapter.h）。
 *
 * 为什么不读 `e->immersive` 了事：那一位只证明"我们记下了"，证明不了系统
 * 真的把标题栏摘了。风格位、菜单条、客户区与外框同不同块，这三样全在 HWND
 * 自己身上，是系统给的答案。
 *
 * 位 5（`T124`）是另一路问法：真屏面上客户区顶上那点像素，在"点一下窗口"
 * （= 一对 WM_NCACTIVATE）前后是不是**一样**。判据用差分不认颜色——认颜色
 * 得先知道这只窗的顶条是什么色，而探针不是皮肤的一部分。
 *
 * 为什么非读真表面不可：`moonui_native_panel_probe` 那族走 WM_PRINTCLIENT，
 * `PrintWindow` 也是离屏重画，画的全是"应用自己那份客户区"——系统盖上去的
 * 那条标题栏根本不在图里。这个缺陷因此躲过了既有每一个探针，直到 2026-10-26
 * 拿 GetWindowDC 直接读窗口表面才现形。 */
int64_t moonui_native_immersive_probe(const char *title, int title_len) {
  HWND win;
  RECT wr;
  RECT cr;
  POINT origin;
  int64_t bits = 0;
  int nl;
  int nt;
  int nr;
  int nb;
  COLORREF warm[3];
  COLORREF after[3];
  HDC dc;
  int i;
  int cx;
  int cy;
  TRACE("immersive_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return (int64_t)1 << 4;
  }
  if ((GetWindowLongW(win, GWL_STYLE) & WS_CAPTION) != 0) {
    bits |= 1;
  }
  if (GetMenu(win) != 0) {
    bits |= 2;
  }
  /* 先空跑一遍激活切换把"刚显示还没画"的那点噪声抖掉，再量第二遍：第一遍
   * 的像素可能是无效区，拿它当基线会把"补画"误判成"被盖"。 */
  SendMessageW(win, WM_NCACTIVATE, (WPARAM)FALSE, 0);
  SendMessageW(win, WM_NCACTIVATE, (WPARAM)TRUE, 0);
  if (GetClientRect(win, &cr) != 0 && cr.right > 16 && cr.bottom > 1) {
    dc = GetWindowDC(win);
    if (dc != 0) {
      cx = cr.right / 2;
      cy = 1;
      warm[0] = GetPixel(dc, 4, cy);
      warm[1] = GetPixel(dc, cx, cy);
      warm[2] = GetPixel(dc, cr.right - 5, cy);
      ReleaseDC(win, dc);
      SendMessageW(win, WM_NCACTIVATE, (WPARAM)FALSE, 0);
      SendMessageW(win, WM_NCACTIVATE, (WPARAM)TRUE, 0);
      dc = GetWindowDC(win);
      if (dc != 0) {
        after[0] = GetPixel(dc, 4, cy);
        after[1] = GetPixel(dc, cx, cy);
        after[2] = GetPixel(dc, cr.right - 5, cy);
        ReleaseDC(win, dc);
        for (i = 0; i < 3; i++) {
          if (warm[i] != after[i]) {
            bits |= 1 << 5;
          }
        }
      }
    }
  }
  if (GetWindowRect(win, &wr) != 0 && GetClientRect(win, &cr) != 0) {
    origin.x = 0;
    origin.y = 0;
    ClientToScreen(win, &origin);
    nl = origin.x - wr.left;
    nt = origin.y - wr.top;
    nr = wr.right - (origin.x + (cr.right - cr.left));
    nb = wr.bottom - (origin.y + (cr.bottom - cr.top));
    if (nl == 0 && nt == 0 && nr == 0 && nb == 0) {
      bits |= 4;
    }
    bits |= ((int64_t)(nl & 0xFF) << 16) | ((int64_t)(nt & 0xFF) << 24) |
            ((int64_t)(nr & 0xFF) << 32) | ((int64_t)(nb & 0xFF) << 40);
  }
  return bits;
}

/* 占位提示的像素探针（`T220`，只 Windows 测试用，声明在 native_test.mbt）：
 * 按窗口标题 + 客户区坐标找到那只单行 EDIT（kind 2/4），WM_PRINTCLIENT 离屏
 * 重画一遍，数与底色不一致的像素。cue banner 真画出来 = 灰字一大把异色像素；
 * 没画 = 0。与 panel/button 探针同一条取舍：WM_PRINTCLIENT 与 WM_PAINT 共用
 * 同一个绘制函数，cue banner 是 comctl6 的 EDIT 在自己的绘制路径里画的，所以
 * 离屏重画画的就是屏幕上那只 EDIT 会画的东西。插入光标由系统直接画在屏幕上、
 * 不进 WM_PRINTCLIENT，聚焦态的读数不受它污染。
 * 返回：异色像素数；负数是台阶码——-1 没有这只窗口、-2 坐标命中的不是
 * EDIT（kind 2/4）、-3 取不到客户区/位图。 */
int64_t moonui_native_edit_probe(const char *title, int title_len, int x,
                                 int y) {
  HWND win;
  HWND edit = 0;
  HWND up;
  POINT pt;
  RECT rc;
  HDC screen_dc;
  HDC mem_dc;
  BITMAPINFO bi;
  void *bits = 0;
  HBITMAP bmp;
  HGDIOBJ old;
  int w;
  int h;
  int i;
  int j;
  int diff = 0;
  const unsigned char *px;
  const unsigned char *bgp;
  TRACE("edit_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -1;
  }
  pt.x = x;
  pt.y = y;
  for (up = ChildWindowFromPoint(win, pt); up != 0 && up != win;
       up = GetParent(up)) {
    int k = moonui_native_kind_of_hwnd(up);
    if (k == 2 || k == 4) {
      edit = up;
      break;
    }
  }
  if (edit == 0) {
    return -2;
  }
  if (GetClientRect(edit, &rc) == 0) {
    return -3;
  }
  w = rc.right - rc.left;
  h = rc.bottom - rc.top;
  if (w <= 8 || h <= 8) {
    return -3;
  }
  screen_dc = GetDC(0);
  if (screen_dc == 0) {
    return -3;
  }
  mem_dc = CreateCompatibleDC(screen_dc);
  if (mem_dc == 0) {
    ReleaseDC(0, screen_dc);
    return -3;
  }
  memset(&bi, 0, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  bmp = CreateDIBSection(screen_dc, &bi, DIB_RGB_COLORS, &bits, 0, 0);
  if (bmp == 0 || bits == 0) {
    if (bmp != 0) {
      DeleteObject(bmp);
    }
    DeleteDC(mem_dc);
    ReleaseDC(0, screen_dc);
    return -3;
  }
  old = SelectObject(mem_dc, bmp);
  SendMessageW(edit, WM_PRINTCLIENT, (WPARAM)mem_dc, PRF_CLIENT);
  px = (const unsigned char *)bits;
  /* 底色取 (3,3)：四角留 3px，避开主题边框的抗锯齿圈。 */
  bgp = px + (size_t)3 * (size_t)(w * 4) + (size_t)3 * 4;
  for (j = 0; j < h; ++j) {
    for (i = 0; i < w; ++i) {
      const unsigned char *p = px + (size_t)j * (size_t)(w * 4) + (size_t)i * 4;
      if (abs(p[0] - bgp[0]) > 4 || abs(p[1] - bgp[1]) > 4 ||
          abs(p[2] - bgp[2]) > 4) {
        ++diff;
      }
    }
  }
  SelectObject(mem_dc, old);
  DeleteObject(bmp);
  DeleteDC(mem_dc);
  ReleaseDC(0, screen_dc);
  return (int64_t)diff;
}

/* 皮肤通道的像素读回（Panel 底色 + 圆角那条）。
 *
 * 为什么读像素而不是读 prop：prop 只能证明"值到了属性表"，证明不了"画出来
 * 的是那个东西"。圆角这一项尤其如此——半径记在 prop 上、画的时候走 GDI+
 * 路径，中间任何一环（类背景刷把角刷平、WM_PAINT 没接、GDI+ 没起来）都会
 * 让"记的值"和"看到的"分家。所以这里走 WM_PRINTCLIENT：让面板把**它自己
 * 那份画法**画进一张离屏位图，再从中取四角与中心。面板的 WM_PAINT 与
 * WM_PRINTCLIENT 共用 moonui_native_panel_paint，所以这就是屏幕上那份画。
 *
 * 坐标 (x,y) 是**根窗口客户区**坐标（与 widget_alpha_probe / custom_probe
 * 同一口径），可以落在面板内部的任意一点；四个角取面板客户区的
 * (r, r) / (W-1-r, r) / (r, H-1-r) / (W-1-r, H-1-r)，r = max(1, 半径像素/8)
 * ——半径 R 的圆弧圆心在 (R,R)，角点 (t,t) 到它的距离是 √2·(R−t)，t < 0.293R
 * 时已在圆外（被切掉）。R/8 稳稳落在那块里且离边界大半个半径，抗锯齿抹不
 * 回去；中心一定是不透明的面色。
 *
 * 打包（每通道 16 位，BGR 顺序，与画布探针同一套）：
 *   位 0..47   中心像素 B,G,R
 *   位 48      中心像素是不是"面色的实色"（1 = 与下发色逐位相同）
 *   位 49..52  四角各 1 位：1 = 那个角**不是**面色（= 被圆角切掉/被抹过）
 *              顺序 左上 / 右上 / 左下 / 右下
 *   位 56..63  状态：0 = 成功，1 = 找不到窗口，2 = 坐标处不是 Panel，
 *              3 = 面板宽高非正
 * 负控制判据：直角面板（半径 0）四角全 0；圆角面板四角全 1。 */
int64_t moonui_native_panel_probe(const char *title, int title_len, int x,
                                  int y) {
  HWND win;
  HWND panel = 0;
  HWND up;
  POINT pt;
  RECT rc;
  HDC screen_dc;
  HDC mem_dc;
  BITMAPINFO bi;
  void *bits = 0;
  HBITMAP bmp;
  HGDIOBJ old;
  int w;
  int h;
  int radius;
  int inset;
  int64_t bg;
  int64_t status = 0;
  int64_t packed = 0;
  int center_solid = 0;
  TRACE("panel_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return (int64_t)1 << 56;
  }
  pt.x = x;
  pt.y = y;
  for (up = ChildWindowFromPoint(win, pt); up != 0 && up != win;
       up = GetParent(up)) {
    if (moonui_native_kind_of_hwnd(up) == 17) {
      panel = up;
      break;
    }
  }
  if (panel == 0) {
    return (int64_t)2 << 56;
  }
  if (GetClientRect(panel, &rc) == 0) {
    return (int64_t)3 << 56;
  }
  w = rc.right - rc.left;
  h = rc.bottom - rc.top;
  if (w <= 0 || h <= 0) {
    return (int64_t)3 << 56;
  }
  bg = moonui_native_rgb_prop(panel, moonui_native_bg_prop);
  radius = moonui_native_radius_px(panel);
  screen_dc = GetDC(0);
  if (screen_dc == 0) {
    return (int64_t)3 << 56;
  }
  mem_dc = CreateCompatibleDC(screen_dc);
  if (mem_dc == 0) {
    ReleaseDC(0, screen_dc);
    return (int64_t)3 << 56;
  }
  memset(&bi, 0, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h; /* 负数 = 自上而下，行序与屏幕同向 */
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  bmp = CreateDIBSection(screen_dc, &bi, DIB_RGB_COLORS, &bits, 0, 0);
  if (bmp == 0 || bits == 0) {
    if (bmp != 0) {
      DeleteObject(bmp);
    }
    DeleteDC(mem_dc);
    ReleaseDC(0, screen_dc);
    return (int64_t)3 << 56;
  }
  old = SelectObject(mem_dc, bmp);
  SendMessageW(panel, WM_PRINTCLIENT, (WPARAM)mem_dc, PRF_CLIENT);
  {
    const unsigned char *px = (const unsigned char *)bits;
    unsigned char cb = (unsigned char)((uint32_t)bg & 0xFFu);
    unsigned char cg = (unsigned char)(((uint32_t)bg >> 8) & 0xFFu);
    unsigned char cr = (unsigned char)(((uint32_t)bg >> 16) & 0xFFu);
    /* B,G,R 三个分量各自对不上的位，宁严勿宽：圆角那圈抗锯齿一定混过色。 */
    int cx = w / 2;
    int cy = h / 2;
    const unsigned char *c = px + (size_t)cy * (size_t)(w * 4) +
                             (size_t)cx * 4;
    packed = (int64_t)c[0] | ((int64_t)c[1] << 8) | ((int64_t)c[2] << 16);
    center_solid = (c[0] == cb && c[1] == cg && c[2] == cr) ? 1 : 0;
    /* 取角点的位置要落在圆角**被切掉的那块**里。半径 R 的圆弧圆心在 (R,R)，
     * 角上一点 (t,t) 到这个圆心的距离是 √2·(R−t)：它在圆外（= 被切掉）当且
     * 仅当 t < R·(1−1/√2) ≈ 0.293R。所以取 R/8：r=12 时是 1 到 2 个像素，
     * 离边界还有大半个半径，抗锯齿不会把它抹回面色；R/2 那种取法是错的
     * ——(0.5R,0.5R) 距圆心 0.71R，还在圆**里面**，永远读到面色。 */
    inset = radius / 8;
    if (inset < 1) {
      inset = 1;
    }
    if (inset > w / 2 - 1) {
      inset = w / 2 - 1;
    }
    if (inset > h / 2 - 1) {
      inset = h / 2 - 1;
    }
    {
      int xs[2];
      int ys[2];
      int i;
      int j;
      int idx = 0;
      int bits4 = 0;
      xs[0] = inset;
      xs[1] = w - 1 - inset;
      ys[0] = inset;
      ys[1] = h - 1 - inset;
      /* 逐角：行 0 = 上（TL, TR），行 1 = 下（BL, BR）。位 49..52 同序。 */
      for (j = 0; j < 2; ++j) {
        for (i = 0; i < 2; ++i) {
          const unsigned char *p =
              px + (size_t)ys[j] * (size_t)(w * 4) + (size_t)xs[i] * 4;
          if (!(p[0] == cb && p[1] == cg && p[2] == cr)) {
            bits4 |= 1 << idx;
          }
          idx += 1;
        }
      }
      packed |= ((int64_t)bits4) << 49;
    }
    packed |= ((int64_t)center_solid) << 48;
  }
  SelectObject(mem_dc, old);
  DeleteObject(bmp);
  DeleteDC(mem_dc);
  ReleaseDC(0, screen_dc);
  packed |= status << 56;
  return packed;
}

/* 平面钮的像素读回（`T115`① 的判据）。
 *
 * 与 Panel 那条同一个理由：要证的是"画出来的样子"，属性表证明不了。按钮的
 * 这一笔尤其如此——改之前 prop 上**一直**有底色，画的却始终是系统主题脸，
 * 读 prop 的判据从头到尾是绿的。
 *
 * 判据不取单点：按钮正中间是标题（字色与面色不同），单点取样随时可能落在
 * 一个字上。改成数"整块矩形里有多少像素正好是下发的那份底色"——平面钮的
 * 脸占绝大部分，主题脸则一个都没有；这个比例对标题长短、对齐、字号都不敏感。
 * 角点取样与 Panel 探针同一把尺（R/8，落在 0.293R 那条切线内侧）。
 *
 * 打包：
 *   位 0..23   中心像素 B,G,R（对照用，不进主判据）
 *   位 40..47  正好是下发底色的像素百分比（0..100）
 *   位 48      左上角是不是**不是**面色（1 = 被圆角切掉了）
 *   位 50..53  此刻的画态（0 正常 / 1 悬停 / 2 按下 / 3 禁用），供断言对照
 *   位 56..63  状态：0 成功 / 1 找不到窗口 / 2 坐标处不是 Button|MenuRow /
 *              3 宽高非正或取图失败
 *
 * 负控制两端：平面钮的覆盖率很高（>90），没给底色的钮在本探针上根本走不到
 * （位 40..47 与 48 全 0，因为 bg < 0 时那段不填）；直角钮位 48 = 0、
 * 圆角钮位 48 = 1。 */
/* 字体族探针（跨平台统一外观判据）：按标题+坐标找控件，回传两件事——
 * 低 8 位：family prop 记着期望字族（1/0）；次 8 位：HFONT 的 lfFaceName
 * 与该期望字族相同（1/0）。两段合起来区分"只存了 prop 没造字"的假绿。 */
int64_t moonui_native_font_family_probe(const char *title, int title_len, int x,
                                        int y) {
  HWND win = moonui_native_find_window(title, title_len);
  HWND ctl = 0;
  HWND up;
  POINT pt;
  char *expect;
  HFONT font;
  LOGFONTW lf;
  WCHAR want[80];
  int64_t out = 0;
  if (win == 0) return (int64_t)1 << 56;
  pt.x = x;
  pt.y = y;
  for (up = ChildWindowFromPoint(win, pt); up != 0 && up != win;
       up = GetParent(up)) {
    int k = moonui_native_kind_of_hwnd(up);
    if (k == 0 || k == 1 || k == 3 || k == 14) {
      ctl = up;
      break;
    }
  }
  if (ctl == 0) return (int64_t)2 << 56;
  expect = (char *)(uintptr_t)GetPropW(ctl, moonui_native_family_prop);
  if (expect == 0 || expect[0] == '\0') return 0;
  out |= 1;
  font = (HFONT)SendMessageW(ctl, WM_GETFONT, 0, 0);
  if (font == 0) return out;
  if (GetObjectW(font, (int)sizeof(lf), &lf) == 0) return out;
  if (MultiByteToWideChar(CP_UTF8, 0, expect, -1, want, 80) <= 0) return out;
  if (wcscmp(lf.lfFaceName, want) == 0) out |= (int64_t)1 << 8;
  return out;
}

/* ---- "一屏只有一种字"探针（`T313`）----
 *
 * owner 2026-11-18 问"为什么一个界面上有各种各样的字体"。查下来不是应用给了
 * 几种字，而是**没下发过字号的控件根本没字体**：`WM_GETFONT` 是空的，Win32
 * 就按类默认字体（`DEFAULT_GUI_FONT` = 宋体）画，而量宽用的是消息字体（雅黑
 * UI）。修法是建控件时就装上消息字体（`moonui_native_install_default_font`）。
 *
 * 判据必须落在"控件自己那只字"上：读应用下发的样式永远看不出这件事——样式
 * 里本来就什么都没有，绿得毫无信息量。所以这里扫整窗的文字类子控件，数
 * `WM_GETFONT` 给出的 face 名有几种。
 *
 * 打包：
 *   位 0..7    文字类子控件数（数到了几只，防"一只都没扫到"的假绿）
 *   位 8..15   不同 face 名个数（空字体记作特殊名 `<none>`，也算一种）
 *   位 16      自绘面选的字族 == 系统消息字体族（1/0）——**只在位 25 为 1 时
 *              才是产品契约**，见下
 *   位 24      自绘面选的字族能扛 CJK（1/0）——三端都成立的契约
 *   位 25      系统消息字体自己能扛 CJK（1/0）——"同族"那条的前提
 *   位 56..63  0 成功 / 1 找不到窗口
 *
 * 为什么要把"同族"拆成三份账：英文 Windows 的消息字体是 Segoe UI，纯拉丁族，
 * 而 GDI+ 的 DrawString 不做字体回退——画布这时**必须**退到雅黑一族，两半本来
 * 就不可能同族。把"同族"当成无条件契约，判据在中文 Windows 上绿、在 runner
 * （英文 Windows Server）上红（run `44258328850` 两条 `0 != 1`），红的是判据
 * 不是产品。所以：位 24 恒须为 1；位 16 只在位 25 为 1 时须为 1。
 *
 * 负控制：给任一控件显式钉别的字族（`font_family("Arial")`）→ 位 8..15 变成
 * 2；位 24 在把画布字族写死成别的拉丁族时会变 0。 */
typedef struct {
  WCHAR names[16][LF_FACESIZE];
  int distinct;
  int count;
} MoonuiFontScan;

static BOOL CALLBACK moonui_native_font_scan_proc(HWND hwnd, LPARAM lp) {
  MoonuiFontScan *s = (MoonuiFontScan *)(uintptr_t)lp;
  WCHAR name[LF_FACESIZE];
  HFONT font;
  LOGFONTW lf;
  int i;
  if (s == 0 || !moonui_native_kind_has_text(moonui_native_kind_of_hwnd(hwnd))) {
    return TRUE;
  }
  s->count += 1;
  font = (HFONT)SendMessageW(hwnd, WM_GETFONT, 0, 0);
  if (font == 0) {
    lstrcpynW(name, L"<none>", LF_FACESIZE);
  } else if (GetObjectW(font, (int)sizeof(lf), &lf) == 0) {
    lstrcpynW(name, L"<?>", LF_FACESIZE);
  } else {
    lstrcpynW(name, lf.lfFaceName, LF_FACESIZE);
  }
  for (i = 0; i < s->distinct; ++i) {
    if (lstrcmpiW(s->names[i], name) == 0) {
      return TRUE;
    }
  }
  if (s->distinct < 16) {
    lstrcpynW(s->names[s->distinct], name, LF_FACESIZE);
    s->distinct += 1;
  }
  return TRUE;
}

int64_t moonui_native_single_font_probe(const char *title, int title_len) {
  HWND win = moonui_native_find_window(title, title_len);
  MoonuiFontScan scan;
  WCHAR canvas_name[LF_FACESIZE];
  NONCLIENTMETRICSW ncm;
  GpFontFamily *family;
  int64_t out = 0;
  if (win == 0) {
    return (int64_t)1 << 56;
  }
  memset(&scan, 0, sizeof(scan));
  EnumChildWindows(win, moonui_native_font_scan_proc, (LPARAM)(uintptr_t)&scan);
  out |= (int64_t)(scan.count > 255 ? 255 : scan.count);
  out |= (int64_t)(scan.distinct > 255 ? 255 : scan.distinct) << 8;
  canvas_name[0] = L'\0';
  family = moonui_canvas_font_family();
  if (family != 0) {
    GdipGetFamilyName(family, canvas_name, 0 /* LANG_NEUTRAL */);
  }
  memset(&ncm, 0, sizeof(ncm));
  ncm.cbSize = (DWORD)sizeof(ncm);
  if (canvas_name[0] != L'\0' &&
      SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, (DWORD)sizeof(ncm), &ncm,
                            0) != 0 &&
      ncm.lfMessageFont.lfFaceName[0] != L'\0') {
    if (lstrcmpiW(canvas_name, ncm.lfMessageFont.lfFaceName) == 0) {
      out |= (int64_t)1 << 16;
    }
    /* 位 25：系统消息字体自己能不能扛 CJK。英文 Windows 上是 Segoe UI——纯
     * 拉丁族，一个汉字字形都没有。**这一位是"同族"那条判据的前提**：前提不
     * 成立时"画布与消息字体同族"根本不是产品契约，而是"中文系统上恰好如此"。
     * runner（英文 Windows Server）上就栽在这儿：本机中文系统两条绿，runner
     * 上 0 != 1。 */
    if (moonui_canvas_family_covers_cjk(ncm.lfMessageFont.lfFaceName)) {
      out |= (int64_t)1 << 25;
    }
  }
  /* 位 24：画布那族真能扛 CJK——这条才是三端都成立的契约（GDI+ 不做字体
   * 回退，选错族就是豆腐块）。 */
  if (canvas_name[0] != L'\0' && moonui_canvas_family_covers_cjk(canvas_name)) {
    out |= (int64_t)1 << 24;
  }
  return out;
}

/* ---- 应用级切换字体探针（`T314`）----
 *
 * `App::set_font_family` 的一条调用要同时改**两半**：原生控件的 HFONT（走
 * per-widget 的 family prop）与自绘面（走进程级的画布字族覆盖）。两条账由
 * 不同的代码路径推到后端，只测一半会留下"换了字体但列表还是旧字"这种半绿。
 *
 * 打包：
 *   位 0     自绘面当前字族名 == name（1/0）
 *   位 8     坐标处文字控件的 HFONT face 名 == name（1/0）
 *   位 16    找到窗口
 *   位 17    坐标处找到文字控件
 *
 * 负控制天然两端：默认（跟随系统）时两段都必须是 0，`set_font_family(Some)`
 * 之后两段都必须是 1，切回 `None` 又都回到 0——`0 -> 1 -> 0` 这个形状证明
 * 两段都在真读当下的字，不是把常量抄一遍。 */
int64_t moonui_native_font_switch_probe(const char *title, int title_len,
                                        int x, int y, const char *name,
                                        int name_len) {
  HWND win;
  HWND ctl = 0;
  HWND up;
  POINT pt;
  WCHAR want[LF_FACESIZE];
  WCHAR got[LF_FACESIZE];
  GpFontFamily *family;
  HFONT font;
  LOGFONTW lf;
  int64_t out = 0;
  int n;
  if (name == 0 || name_len <= 0) {
    return 0;
  }
  memset(want, 0, sizeof(want));
  n = MultiByteToWideChar(CP_UTF8, 0, name, name_len, want, LF_FACESIZE - 1);
  if (n <= 0) {
    return 0;
  }
  want[n] = L'\0';
  /* ① 自绘面 */
  got[0] = L'\0';
  family = moonui_canvas_font_family();
  if (family != 0) {
    GdipGetFamilyName(family, got, 0);
    if (lstrcmpiW(got, want) == 0) {
      out |= 1;
    }
  }
  /* ② 控件：按窗口局部坐标找文字类控件，读它当下挂的 HFONT */
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return out;
  }
  out |= (int64_t)1 << 16;
  pt.x = x;
  pt.y = y;
  for (up = ChildWindowFromPoint(win, pt); up != 0 && up != win;
       up = GetParent(up)) {
    if (moonui_native_kind_has_text(moonui_native_kind_of_hwnd(up))) {
      ctl = up;
      break;
    }
  }
  if (ctl == 0) {
    return out;
  }
  out |= (int64_t)1 << 17;
  font = (HFONT)SendMessageW(ctl, WM_GETFONT, 0, 0);
  if (font == 0 || GetObjectW(font, (int)sizeof(lf), &lf) == 0) {
    return out;
  }
  if (lstrcmpiW(lf.lfFaceName, want) == 0) {
    out |= (int64_t)1 << 8;
  }
  return out;
}

int64_t moonui_native_button_probe(const char *title, int title_len, int x,
                                   int y) {
  HWND win;
  HWND btn = 0;
  HWND up;
  POINT pt;
  RECT rc;
  HDC screen_dc;
  HDC mem_dc;
  BITMAPINFO bi;
  void *bits = 0;
  HBITMAP bmp;
  HGDIOBJ old;
  int w;
  int h;
  int radius;
  int inset;
  int64_t bg;
  int64_t packed = 0;
  int state;
  TRACE("button_probe");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return (int64_t)1 << 56;
  }
  pt.x = x;
  pt.y = y;
  for (up = ChildWindowFromPoint(win, pt); up != 0 && up != win;
       up = GetParent(up)) {
    int k = moonui_native_kind_of_hwnd(up);
    if (k == 1 || k == 14) {
      btn = up;
      break;
    }
  }
  if (btn == 0) {
    return (int64_t)2 << 56;
  }
  if (GetClientRect(btn, &rc) == 0) {
    return (int64_t)3 << 56;
  }
  w = rc.right - rc.left;
  h = rc.bottom - rc.top;
  if (w <= 0 || h <= 0) {
    return (int64_t)3 << 56;
  }
  bg = moonui_native_rgb_prop(btn, moonui_native_bg_prop);
  radius = moonui_native_radius_px(btn);
  state = moonui_native_button_state(btn);
  screen_dc = GetDC(0);
  if (screen_dc == 0) {
    return (int64_t)3 << 56;
  }
  mem_dc = CreateCompatibleDC(screen_dc);
  if (mem_dc == 0) {
    ReleaseDC(0, screen_dc);
    return (int64_t)3 << 56;
  }
  memset(&bi, 0, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h; /* 负数 = 自上而下，行序与屏幕同向 */
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  bmp = CreateDIBSection(screen_dc, &bi, DIB_RGB_COLORS, &bits, 0, 0);
  if (bmp == 0 || bits == 0) {
    if (bmp != 0) {
      DeleteObject(bmp);
    }
    DeleteDC(mem_dc);
    ReleaseDC(0, screen_dc);
    return (int64_t)3 << 56;
  }
  old = SelectObject(mem_dc, bmp);
  SendMessageW(btn, WM_PRINTCLIENT, (WPARAM)mem_dc, PRF_CLIENT);
  {
    const unsigned char *px = (const unsigned char *)bits;
    /* 面色的判据**不取某一个点**：按钮中间是标题（字色与面色不同），
     * 单点取样随时可能落在一个字上。改成数"整块矩形里有多少像素正好是
     * 下发的那份底色"——平面钮的脸占绝大部分（90% 以上），主题脸则一个
     * 都没有。这个比例对标题长短、对齐方式、字号都不敏感。 */
    const unsigned char *c =
        px + (size_t)(h / 2) * (size_t)(w * 4) + (size_t)(w / 2) * 4;
    int64_t total = (int64_t)w * (int64_t)h;
    int64_t hit = 0;
    int ys;
    int xs;
    packed = (int64_t)c[0] | ((int64_t)c[1] << 8) | ((int64_t)c[2] << 16);
    if (bg >= 0) {
      unsigned char cb = (unsigned char)((uint32_t)bg & 0xFFu);
      unsigned char cg = (unsigned char)(((uint32_t)bg >> 8) & 0xFFu);
      unsigned char cr = (unsigned char)(((uint32_t)bg >> 16) & 0xFFu);
      for (ys = 0; ys < h; ++ys) {
        const unsigned char *row = px + (size_t)ys * (size_t)(w * 4);
        for (xs = 0; xs < w; ++xs) {
          const unsigned char *p = row + (size_t)xs * 4;
          if (p[0] == cb && p[1] == cg && p[2] == cr) {
            hit += 1;
          }
        }
      }
      if (total > 0) {
        packed |= ((hit * 100 / total) & 0xFF) << 40;
      }
      /* 角点取样同 Panel 探针：R/8 落在被圆角切掉的那一块里。圆角在
       * WM_PRINTCLIENT 这条路里也画得出来，因为脸本来就是**圆角路径**填充
       * （不只是 SetWindowRgn 剪一刀），两条路看到的是同一个形状。 */
      inset = radius / 8;
      if (inset < 1) {
        inset = 1;
      }
      if (inset > w / 2 - 1) {
        inset = w / 2 - 1;
      }
      if (inset > h / 2 - 1) {
        inset = h / 2 - 1;
      }
      {
        const unsigned char *p =
            px + (size_t)inset * (size_t)(w * 4) + (size_t)inset * 4;
        if (!(p[0] == cb && p[1] == cg && p[2] == cr)) {
          packed |= (int64_t)1 << 48;
        }
      }
    }
    packed |= ((int64_t)state) << 50;
  }
  SelectObject(mem_dc, old);
  DeleteObject(bmp);
  DeleteDC(mem_dc);
  ReleaseDC(0, screen_dc);
  return packed;
}

/* ---- 显示后重画探针（`T121`）----
 * 给 Windows 真窗测试用：按标题找到顶层窗，把**每只后代**登记进一张表（装一只
 * 只数 `WM_PAINT` 的子类过程），随后可以问三个数：
 *   - total  ：登记了几只（`EnumChildWindows` 扫到的后代总数）；
 *   - painted：登记之后真收到过 `WM_PAINT` 的只数；
 *   - limbo  ：既没画过、此刻也没有非空失效区（`GetUpdateRect`）的只数。
 *
 * limbo 就是 `T121` 的症状：控件搬进窗口时窗口还藏着（`set_content` 在 `show`
 * 之前），attach 打的那次失效没有变成 `WM_PAINT`，显示之后也没人补一次，于是
 * 它停在"以为自己画过"的状态——用户看到打开时缺几块、鼠标划过才补出来。
 * 判据因此分两个时刻：`show` 一返回取一次（limbo 必须 0，此时多数还是 pending），
 * 泵一批消息之后再取一次（painted 必须等于 total）。
 *
 * 只数"收到 `WM_PAINT`"，不数"画对了什么"：像素对账另有各控件自己的探针（面板
 * 底色、按钮平面底那几条）。打包 `(limbo << 32) | (painted << 16) | total`，
 * 找不着窗返回 -2。表在 `end` 里复位，所以每条测试自己 begin/end。
 *
 * mac 半没有对应物：NSView 的重画由 Cocoa 的 display 周期统一驱动，不存在
 * "子窗口挂着失效率、主循环却没补画"这个中间态。 */
typedef struct {
  HWND hwnd;
  WNDPROC old;
  int painted;
} MoonuiPaintProbeEntry;

static MoonuiPaintProbeEntry *moonui_paint_entries = 0;
static int moonui_paint_entry_count = 0;
static int moonui_paint_entry_cap = 0;

static MoonuiPaintProbeEntry *moonui_paint_entry_of(HWND hwnd) {
  int i;
  for (i = 0; i < moonui_paint_entry_count; i += 1) {
    if (moonui_paint_entries[i].hwnd == hwnd) {
      return &moonui_paint_entries[i];
    }
  }
  return 0;
}

static void moonui_paint_probe_restore(void) {
  int i;
  for (i = 0; i < moonui_paint_entry_count; i += 1) {
    if (IsWindow(moonui_paint_entries[i].hwnd) != 0) {
      SetWindowLongPtrW(moonui_paint_entries[i].hwnd, GWLP_WNDPROC,
                        (LONG_PTR)moonui_paint_entries[i].old);
    }
  }
  if (moonui_paint_entries != 0) {
    free(moonui_paint_entries);
  }
  moonui_paint_entries = 0;
  moonui_paint_entry_count = 0;
  moonui_paint_entry_cap = 0;
}

static LRESULT CALLBACK moonui_paint_probe_proc(HWND hwnd, UINT msg, WPARAM wp,
                                                LPARAM lp) {
  MoonuiPaintProbeEntry *e = moonui_paint_entry_of(hwnd);
  if (e == 0) {
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  if (msg == WM_PAINT) {
    e->painted += 1;
  }
  return CallWindowProcW(e->old, hwnd, msg, wp, lp);
}

static BOOL CALLBACK moonui_paint_probe_visit(HWND hwnd, LPARAM lp) {
  MoonuiPaintProbeEntry *e;
  (void)lp;
  if (moonui_paint_entry_of(hwnd) != 0) {
    return TRUE;
  }
  if (moonui_paint_entry_count == moonui_paint_entry_cap) {
    int cap = moonui_paint_entry_cap == 0 ? 32 : moonui_paint_entry_cap * 2;
    MoonuiPaintProbeEntry *grown = (MoonuiPaintProbeEntry *)realloc(
        moonui_paint_entries, (size_t)cap * sizeof(MoonuiPaintProbeEntry));
    if (grown == 0) {
      return TRUE;
    }
    moonui_paint_entries = grown;
    moonui_paint_entry_cap = cap;
  }
  e = &moonui_paint_entries[moonui_paint_entry_count];
  e->hwnd = hwnd;
  e->painted = 0;
  e->old = (WNDPROC)SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                                      (LONG_PTR)moonui_paint_probe_proc);
  moonui_paint_entry_count += 1;
  return TRUE;
}

int moonui_native_paint_probe_begin(const char *title, int title_len) {
  HWND win;
  TRACE("paint_probe_begin");
  moonui_paint_probe_restore();
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  EnumChildWindows(win, moonui_paint_probe_visit, 0);
  return moonui_paint_entry_count;
}

int64_t moonui_native_paint_probe_report(const char *title, int title_len) {
  HWND win;
  int i;
  int total;
  int64_t painted = 0;
  int64_t limbo = 0;
  RECT r;
  TRACE("paint_probe_report");
  win = moonui_native_find_window(title, title_len);
  if (win == 0) {
    return -2;
  }
  total = moonui_paint_entry_count;
  for (i = 0; i < moonui_paint_entry_count; i += 1) {
    HWND hwnd = moonui_paint_entries[i].hwnd;
    if (IsWindow(hwnd) == 0) {
      continue;
    }
    if (moonui_paint_entries[i].painted > 0) {
      painted += 1;
      continue;
    }
    if (GetUpdateRect(hwnd, &r, FALSE) == 0) {
      limbo += 1;
    }
  }
  return (limbo << 32) | (painted << 16) | (int64_t)total;
}

void moonui_native_paint_probe_end(const char *title, int title_len) {
  (void)title;
  (void)title_len;
  TRACE("paint_probe_end");
  moonui_paint_probe_restore();
}

/* 把登记过的后代的待画队列抹平（`ValidateRect`），让每只都回到"以为自己画过"
 * 的状态——控件在 park 里或上一轮显示期真画过一次时就是这个状态，而这台
 * Windows 上"藏在父窗里的失效区"实测会一直挂到显示之后（见 `T121` 的量测），
 * 所以只有从这里起手，判据才能单独咬住"`ShowWindow` 自己有没有补齐整棵树"
 * 这一条。 */
int moonui_native_paint_probe_validate(const char *title, int title_len) {
  int i;
  int cleared = 0;
  (void)title;
  (void)title_len;
  TRACE("paint_probe_validate");
  for (i = 0; i < moonui_paint_entry_count; i += 1) {
    HWND hwnd = moonui_paint_entries[i].hwnd;
    if (IsWindow(hwnd) == 0) {
      continue;
    }
    ValidateRect(hwnd, 0);
    cleared += 1;
  }
  return cleared;
}


