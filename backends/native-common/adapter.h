/* MoonUI 的原生后端 C ABI 头（设计文档 §5、§20；`T82` 起从 backends/libui-common
 * 移居本目录——2026-10-15 应 owner 重构决定删 libui 后端、框架收敛到原生后端单
 * 后端，这份头跟着它唯一的住户走）。
 *
 * 这一层之上只有 MoonBit，之下只有平台原生 API（macOS 直写 AppKit、Windows 直写
 * Win32）：第三方的类型、宏、HWND 一个都不许漏进 adapter.h。MoonBit 侧只认这套
 * moonui_native_* 名字（链接符号与 ffi.mbt 的 extern 同名；`T82` 起 libui 那代
 * 裸名 moonui_* 已全部退场），这就是 §5 里"隐藏第三方 API / 统一 ABI / 统一
 * 生命周期"的具体形状。
 *
 * 实现按平台分家，目录名对称：../native-windows/adapter_native.c 是 Win32 那份，
 * ../native-macos/adapter_native.m 是 Cocoa 那份。两份各 include 本文件；链接配置
 * 由 prebuild-link.js 在构建期注入（挂在 ../native-common 上顺 import 传播），本
 * 目录只有声明加共享的 ffi.mbt/backend.mbt，既没有 C 也没有 link，所以换平台不动
 * MoonBit。
 *
 * ABI 约定（§29）：
 *   - 指针一律 uintptr_t 进出，0 = 没有这个东西；
 *   - 进 C 的字符串是 (UTF-8 指针, 字节数) 两个参数——MoonBit 的 Bytes 不保证
 *     以 NUL 结尾，所以 C 侧自己复制一份再交给平台 API；
 *   - 出 C 的字符串是 moonbit_bytes_t，由 GC 回收，MoonBit 侧不需要 free；
 *   - 一次要回两个整数（尺寸、位置）时打包成一个 int64：高 32 位放前一个、
 *     低 32 位放后一个。MoonBit 侧用算术移位拆，负数符号能正确还原。
 * 单位约定：这一层只讲物理像素。逻辑像素的换算全部集中在 MoonBit 的 `Scale`
 * 里（§30 "只允许这一处换算"），所以 C 侧不做任何 DPI 数学，只报 DPI 值。
 * 句柄的 id + generation 账本在 MoonBit 的 HandleTable 里（§6/§7），C 侧不另开
 * 一份，因此 C 侧调用必须按"先 child 后 window"的顺序被使用——这条约束由
 * Backend 实现来保证，不在这里做第二套防御。
 *
 * 史注：本头原为 libui-ng 后端所写（§48 第 03/09/10 步），正文里提到 libui 的
 * 语义注记（uiNewWindow、分配审计之类）讲的是 ABI 条目的起源与行为约束，实现者
 * 现在是两份直写平台 API 的 adapter——史注保留，条目一个未动。
 */
#ifndef MOONUI_NATIVE_ADAPTER_H
#define MOONUI_NATIVE_ADAPTER_H

#include <stdint.h>

#include <moonbit.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uintptr_t moonui_ptr;

/* MoonBit 闭包：FuncRef 桥的 C 侧形态，唯一参数是闭包本身。 */
typedef void (*moonui_closure_fn)(void *closure);

/* 带一个 id 的 MoonBit 闭包：菜单栏点击回调的形态，id 是 Core 分配的菜单项编号。 */
typedef void (*moonui_closure_id_fn)(void *closure, int id);

/* 初始化。成功返回 0；失败返回非 0，原因用 moonui_native_last_error() 取。
 * libui 的初始化是进程级的，所以这一对是幂等的单例：重复 init 直接返回成功，
 * 没初始化过的 terminate 是空操作。 */
int moonui_native_init(void);

/* 失败原因（UTF-8）。成功之后调用返回空 bytes。 */
moonbit_bytes_t moonui_native_last_error(void);

/* 收尾。注销所有还在 C 侧持有的闭包，然后释放 GUI 库的全局状态。
 * 前提是所有控件和窗口已经销毁干净——libui 在退出时审计自己的分配表，
 * 发现泄漏就直接 DebugBreak。 */
void moonui_native_terminate(void);

/* ---- 窗口（§12）---- */
/* 宽高是窗口客户区的物理像素（libui 的 uiNewWindow 就是这个语义）。 */
moonui_ptr moonui_native_window_new(const char *title, int title_len, int width,
                             int height);
void moonui_native_window_show(moonui_ptr w);
void moonui_native_window_hide(moonui_ptr w);
/* 销毁窗口。§14 的布局在 MoonUI 这一侧，窗口不持有 child 的所有权，
 * 所以 child 必须已经全部销毁——DestroyWindow 会连带销毁还挂着的子窗口，
 * 之后再 destroy 一次就是野句柄。 */
void moonui_native_window_destroy(moonui_ptr w);

void moonui_native_window_set_title(moonui_ptr w, const char *title, int title_len);
/* 客户区尺寸，物理像素。libui 自己会算回外层窗口尺寸。 */
void moonui_native_window_set_content_size(moonui_ptr w, int width, int height);
/* 打包 (width, height)。 */
int64_t moonui_native_window_content_size(moonui_ptr w);
/* 客户区最小尺寸（§12），物理像素；width/height 传 0 = 清掉限制。
 *
 * 这是**系统级**钳位，不是 Core 侧的记账：Core 的夹紧只挡程序化改尺寸，用户
 * 拖窗格根本不经过 Core（Resize 事件是"已经拖完了"的回报）。mac 落
 * NSWindow.contentMinSize，Win32 落 WM_GETMINMAXINFO 的 ptMinTrackSize——
 * 两边都把"客户区"当下限口径，和 set_content_size 同一套换算。 */
void moonui_native_window_set_min_size(moonui_ptr w, int width, int height);
/* 读回最小尺寸，打包 (width, height)。真窗口测试用：断言"设了真的到了原生层"，
 * 而不是只信 setter 没报错。 */
int64_t moonui_native_window_min_size(moonui_ptr w);
/* 当下是不是在**用户拖拽改尺寸**的会话里（mac 的 NSWindow.inLiveResize、Win32 的
 * WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE 之间）。实时重排（live redraw）只认拖拽：
 * 程序化改尺寸不算——Core 的 set_size 自己当场重排，mac 那侧还另有
 * suppress_resize 挡回声。返回 1/0。 */
int moonui_native_window_in_live_resize(moonui_ptr w);
/* 窗口外层左上角，屏幕物理像素坐标（Win32 的语义，不是客户区）。 */
void moonui_native_window_set_position(moonui_ptr w, int x, int y);
/* 打包 (x, y)。mac 半要拿"当下真在哪"：拖标题栏时 NSWindow.frame 是旧值（窗由
 * WindowServer 移动、AppKit 缓存不同步），那边的实现会问 WindowServer（见
 * adapter_native.m 的 moonui_native_server_frame 段注）。 */
int64_t moonui_native_window_position(moonui_ptr w);
/* 测试缝（只给真窗口测试用）：模拟"WindowServer 把窗挪走了、AppKit 没有通知"
 * 的外部移动——也就是用户拖动的中途态。绕过回声抑制、不登记位置，后续由
 * mac 的拖动期轮询从 WindowServer 发现并补报 Moved。Windows 半是空操作
 * （那侧 WM_MOVE 在拖动循环里连续发，没有这个中间态）。 */
void moonui_native_window_move_external(moonui_ptr w, int x, int y);
/* 测试缝（只给真窗口测试用）：喂一拍"合成拖动"——模拟用户拖着标题栏走到
 * (x, y)，走**鼠标增量预测**路径（mac 的方案 B：拖动期位置 = 锚点+鼠标位移，
 * 不问 WindowServer）。mac 半把预测原点给成 (x, y)、真把窗挪过去（同拖动的
 * 1:1 形态），并**同步**走一拍拖动期轮询（发现→补报→吸附联动在返回前落定，
 * 不等定时器）；不读真实鼠标、不因松手把预测关掉。Windows 半退化成一次外部
 * 移窗（那侧 WM_MOVE 在拖动循环里同步发，没有"中途无通知"的中间态）。
 * x/y 口径同 set_position：物理像素。 */
void moonui_native_window_drag_step(moonui_ptr w, int x, int y);
void moonui_native_window_set_resizable(moonui_ptr w, int resizable);
void moonui_native_window_set_fullscreen(moonui_ptr w, int fullscreen);
/* 标题栏样式（§12）。immersive = 1 时 mac 走 fullSizeContentView + 透明标题栏 +
 * 隐藏标题文字（内容铺满、红绿灯浮在内容上）；immersive = 0 切回标准。Windows
 * 没有红绿灯，这条在那侧是空操作（留这条是为了跨平台 API 一致）。 */
void moonui_native_window_set_titlebar_style(moonui_ptr w, int immersive);
/* 读回标题栏样式，打包成位：bit0 = fullSizeContentView、bit1 = 标题栏透明、
 * bit2 = 标题文字隐藏。三条都置位 = 沉浸式。Windows 没有红绿灯，恒返回 0。
 * 这条是给真窗口测试用的：断言"设成 Immersive 后原生层真的变了"，而不是只信
 * setter 没报错。 */
int moonui_native_window_titlebar_style(moonui_ptr w);
/* 红绿灯位置（§12）。x/y 是**关闭按钮左上角**相对**窗口左上角**的物理像素
 * （和 moonui_window_set_position 同一个口径：客户区左上、物理像素）。mac 把
 * 三个红绿灯整簇挪过去，并在 resize 时重新断言（AppKit 会在 resize 时把它们
 * 摆回默认位）；Windows 没有红绿灯，是空操作。 */
void moonui_native_window_set_traffic_light_position(moonui_ptr w, int x, int y);
/* 读回红绿灯位置，打包 (x, y)，物理像素，口径同 setter。Windows 没有红绿灯，
 * 恒 (0,0)。 */
int64_t moonui_native_window_traffic_light_position(moonui_ptr w);

/* 离屏取证（开发用）：把本进程所有窗口的内容各写一张 PNG 到 dir，文件名取
 * 窗口标题。走视图自绘通道（cacheDisplayInRect:），不需要屏幕录制权限——
 * screencapture 在沙箱/无头环境里拿到的是全黑，这条能拿到真像素。
 * 同一趟还写一份 views.txt（原生视图树的类名/frame/隐藏/翻转）：像素只说
 * "看不见"，这份账才说"谁把它放到了哪儿、挂没挂上"。
 * 返回写成功的张数；dir 建不出来/没有窗口 → 0。Windows 半恒 -3（未实现）。 */
int moonui_native_snapshot_all(const char *dir, int dir_len);

/* 窗口当下的 DPI（96 = 100%）。取不到（系统太老）时返回 96，不返回 0：
 * 0 会让 MoonBit 侧的换算变成无穷大。 */
int moonui_native_window_dpi(moonui_ptr w);
/* 进程级 DPI，只在窗口还没建出来时给 screen_size 当换算基准。 */
int moonui_native_system_dpi(void);
/* 主屏工作区（不含任务栏），打包 (width, height)，物理像素。 */
int64_t moonui_native_screen_work_area(void);
/* 这只窗口**当下所在那块屏**的工作区（去掉任务栏 / Dock），物理像素，分两条打包：
 * `moonui_window_screen_origin` 给 (x, y)，`moonui_window_screen_size` 给 (width, height)。
 * 上面那条 `moonui_screen_work_area` 只能量主屏（mac 的 `[NSScreen mainScreen]`、
 * Win32 的 `SPI_GETWORKAREA` 按定义都是主屏），所以副屏上的窗口拿到的是别人的数——
 * `Window::center` 就是这么把副屏上的窗口摆回主屏的（TODO `T42`）。
 *
 * **坐标空间就是本后端 `moonui_window_position` / `_set_position` 用的那一个**，
 * 这一条是这两句存在的理由：读数只有用摆位那套坐标才摆得回去，而两个平台那套坐标
 * 本身不同（libui 的 darwin 版按**窗口当下**那块屏的 visibleFrame 翻 y，所以那儿的
 * y=0 就是"该屏可见区的上边"，origin.y 恒为 0；Win32 是虚拟屏幕的绝对坐标，副屏在
 * 主屏右边时 rcWork.left 就是一个非零的绝对 x）。所以这里钉的是"同一个后端内自洽"，
 * 不是"两平台报出同一个几何"——`Window::center` 拿到的 origin/size 只用于把它自己
 * 那块屏的可用矩形算出一个摆位点，算完就交给同后端的 set_position。
 *
 * 兜底：窗口还没上屏（mac 的 `[window screen]` 为 nil）或查询失败时，退回**主屏**
 * 的工作区，和上面那条同值。为什么不返回 0 尺寸：`LogicalRect::center` 遇到
 * "窗口比屏还大"会把偏移夹成 0，于是 0 尺寸把窗口堆到左上角，看起来像"居中成功了
 * 但位置怪"，而真实症状是没读到屏。 */
int64_t moonui_native_window_screen_origin(moonui_ptr w);
int64_t moonui_native_window_screen_size(moonui_ptr w);
/* 系统外观：1 = 深色，0 = 浅色。读不到一律返回 0（当浅色），不设错误码：
 * 两侧的"读不到"都不是失败，而是这个平台上没有深色这个东西——Win32 上 Windows 7
 * 没有 AppsUseLightTheme 这个值，mac 上 NSApp 还没建出来时没有 effectiveAppearance。
 * 猜错的代价是配色跟着浅色走，和"根本没接"一模一样；把它变成错误反而会让
 * App::palette 在老系统上直接 raise。
 * mac 读的是 `NSApp.effectiveAppearance.name` 里有没有 "Dark"（DarkAqua、VibrantDark、
 * 高对比度那几支深色名都含 Dark，浅色的 Aqua / VibrantLight 都不含），也就是**原生控件
 * 接下来会按哪套画**；没设过 NSApp.appearance 时它就是桌面设置，所以和
 * `defaults read -g AppleInterfaceStyle` 对得上。Windows 读的是
 * HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme
 * （0 = 深色；键或值不在 = 浅色），那是桌面的设置本身。 */
int moonui_native_system_theme(void);

/* 宿主血统（§12 窗口装饰分叉）：1 = macOS，2 = Windows。编译期常量意义上的
 * 读数——同一个二进制只可能跑在一个宿主上，没有"读不到"这一支，但将来加了
 * 新宿主而共享层还没跟上时可能拿到别的数，共享层一律降级成 `Unknown`。
 * mac 有红绿灯、Windows 没有，界面据此决定窗口控制按钮要不要自绘。 */
int moonui_native_host_platform(void);

/* ---- 进程级偏好读数（`T87`②/③）----
 * 两条都是"读当下偏好"的快照式读口（`T86`② `window_state` 读回同一条纪律）：
 * 不推送、不订阅，问一次拿一份；进程级的（与外观/剪贴板同族），一个 MoonUI
 * 句柄都不占。读不到一律返回 0（偏好关），不设错误码——外观那条入口的
 * "读不到就当浅色"同一条绕行：老系统没有这个偏好就不是失败，猜错的代价是
 * 动画照跑/主题照旧，和"根本没接"语义一致；两条目前都没有失败形态可报。
 * mac 半走 NSWorkspace 的两条可访问性 BOOL 读口；Windows 半走
 * SystemParametersInfo 的两条查询（见各自实现的段注）。 */
/* 1 = 系统"减少动态效果"开着（`T87`③——动画的退场闸门：开着时泵把激活账
 * 当圈推精确落点、不跑中间帧，语义在 `app.mbt` 的 `pump_animations`）。 */
int moonui_native_prefers_reduced_motion(void);
/* 1 = 系统"增强对比度"开着（`T87`②）。首版只做读口；消费点（主题读数档
 * ——按偏好换一套配色）第二版接，首版不接主题（主题账 §15/`T40` 不夹带）。 */
int moonui_native_prefers_high_contrast(void);

/* 注册"用户点关闭按钮"回调。成功返回 0，槽位用满返回 -1。
 * 回调只做一件事：把 Close 事件放进队列。返回给 libui 的一律是 0，也就是
 * 否决 libui 自己销毁窗口的路径——销毁顺序由 Core 决定（先内容树后窗口），
 * libui 的默认行为是先拆窗口，那会让 Core 读到已经没了的原生对象。 */
int moonui_native_window_on_closing(moonui_ptr w, moonui_closure_fn fn, void *closure);
/* 注册"客户区尺寸变了"回调（同上，返回 0 表示装上了）。
 * libui 在程序化 SetContentSize 时不会触发它，所以 Core 自己发起的改尺寸
 * 不会回声成一条 Resize 事件。 */
int moonui_native_window_on_resized(moonui_ptr w, moonui_closure_fn fn, void *closure);
/* 注册"窗口被用户拖到新位置"回调（同上，返回 0 表示装上了）。
 * 程序化 set_window_position 时由两侧各自把回声挡掉（mac 走 suppress_move、
 * Win32 走 inhibit prop），所以 Core 自己发起的搬窗不会回声成一条 Moved 事件——
 * 吸附联动搬邻居时也不会递归触发。 */
int moonui_native_window_on_moved(moonui_ptr w, moonui_closure_fn fn, void *closure);

/* ---- 控件（§13）----
 * kind：0=Label 1=Button 2=TextInput 3=Checkbox 4=PasswordInput
 * 5=Separator 13=VSeparator（竖向，同一实现的另一个方向）
 * 15=Scroll（T74 起滚动视口占用一个原生对象）
 * 17=Panel（皮肤账的自绘面：占一个原生对象的容器，背景/圆角走
 * widget_set_style，子树挂进它——与 Scroll 同一条认领规则）。
 * Row/Column 这类纯布局节点不会走到这里（§14）。其余叶子（Slider 等）
 * 各有专属构造入口（见下节），不走这条。返回 0 表示这个 kind 不支持或
 * 分配失败。 */
moonui_ptr moonui_native_widget_new(int kind, const char *text, int text_len);
/* 销毁控件，并松开 C 侧替它看守的所有闭包。必须在所属窗口销毁之前调用。 */
void moonui_native_widget_destroy(moonui_ptr c);

/* 样式下发（§15/§16 的皮肤通道）：Core 沿层叠算好的生效值整份推过来。
 * 各字段是独立通道，-1（字段的"未设置"哨兵）表示这一项不动、保持上次的值：
 *   bg_rgb / fg_rgb：0xRRGGBB 打包色（不透明）
 *   radius_permille：圆角半径，逻辑点 × 1000
 *   font_permille：字号，点 × 1000；weight：0=Regular 1=Medium 2=Bold
 * 平台各按 kind 决定消费面（mac：Panel 画 layer 底+圆角，Label 用
 * setTextColor/setFont，Button 用 attributed title+layer 底；§32 对这三处
 * 定点豁免——原生控件保持系统外观的规矩不破，破的只是"样式完全不生效"
 * 这条）。不认识的 kind 静默忽略，返回 0。 */
int moonui_native_widget_set_style(moonui_ptr c,
                                   int64_t bg_rgb,
                                   int64_t fg_rgb,
                                   int radius_permille,
                                   int font_permille,
                                   int weight);
/* 图标（皮肤账）：按钮换图形图标。name 是平台系统图标集的名字（mac =
 * SF Symbols 名，如 "play.fill"）；平台给不出就保持文本外观，返回 0。 */
int moonui_native_widget_set_icon(moonui_ptr c, const char *name, int name_len);

/* ---- 画布（§52，自绘后端的绘制通道；2026-10-17 第一期）----
 * 一只上下文 = 一段离屏位图的生命周期：begin_frame 按物理尺寸开一张
 * RGBA 位图，各绘制函数往上面画，read_pixel 供测试断言像素，end_frame
 * 收帧（第一期里位图就是帧，不上屏——上屏的 attach 在 canvas-macos
 * 后端那一批再进 ABI）。挂到真窗口渲染是 52.5 分期②的账。
 *
 * 口径：
 *   - 坐标/尺寸一律物理像素（§30，Scale 换算归实现侧）；
 *   - 颜色 0xRRGGBB 打包进 int64（与皮肤通道同一口径）；alpha 走独立 int
 *     参数（0..255，T98② 毛玻璃起）——位图本就是 RGBA 预乘，只是第一期
 *     没透明色需求才恒 255；
 *   - permille = 逻辑值 × 1000（radius、blur、font、stroke width 同此）；
 *   - weight：0=Regular 1=Medium 2=Bold（与皮肤通道同档，Medium 平台可退 Regular）；
 *   - stops（渐变端点）按 16 字节/端点打包：[int64 pos_permille][int64 rgb]，
 *     pos 千分 0..1000，序随意（实现侧按 pos 排）；
 *   - 渐变方向第一期只做垂直从上到下（fill_linear 的 x/w 限定裁剪域，
 *     色带沿 y 展开）——常见音乐客户端复刻够用，方向参数等要斜的再说；
 *   - shadow 是**状态**不是一次性格式：设了之后所有填充都带影，直到
 *     save/restore 出界或再调一次 blur=0 清零（与 CG 的状态栈同构）。
 * 返回码：0 成功；-1 参数错（空上下文/空指针/非正尺寸）；-2 平台缺席
 * （Windows 半第一期整体 -2）；-3 本期未实现（预留）。 */
moonui_ptr moonui_canvas_create(void);
int moonui_canvas_destroy(moonui_ptr canvas);
int moonui_canvas_begin_frame(moonui_ptr canvas, int w, int h);
int moonui_canvas_end_frame(moonui_ptr canvas);
int moonui_canvas_save(moonui_ptr canvas);
int moonui_canvas_restore(moonui_ptr canvas);
int moonui_canvas_clip_rect(moonui_ptr canvas, int x, int y, int w, int h);
int moonui_canvas_translate(moonui_ptr canvas, int dx, int dy);
/* 圆角矩形填充：radius_permille < 0 时当 0（直角）。alpha 0..255（255=不透明）。 */
int moonui_canvas_fill_rect(moonui_ptr canvas, int x, int y, int w, int h,
                            int radius_permille, int64_t rgb, int alpha);
/* 区域模糊（T98② 毛玻璃的"毛"）：对位图里 (x,y,w,h) 那块做原地高斯近似
 * 模糊（三次盒式，O(W·H) 与半径无关），半径取 radius_permille/1000 物理
 * 像素。模糊的是"栏后面已画上去的内容"，不是栏自己——毛玻璃配方先调它
 * 再叠半透底。越界钳到缓冲内；radius_permille=0 是恒等。 */
int moonui_canvas_blur_region(moonui_ptr canvas, int x, int y, int w, int h,
                              int radius_permille);
/* 圆角矩形描边。width_permille 是描边宽。 */
int moonui_canvas_stroke_rect(moonui_ptr canvas, int x, int y, int w, int h,
                              int radius_permille, int64_t rgb,
                              int width_permille);
/* 垂直线性渐变填充（上→下），stops 见上面那段。 */
int moonui_canvas_fill_linear(moonui_ptr canvas, int x, int y, int w, int h,
                              moonui_ptr stops, int n);
/* 投影状态（CG 的状态栈语义，见上面那段）。 */
int moonui_canvas_shadow(moonui_ptr canvas, int dx, int dy,
                         int blur_permille, int64_t rgb);
int moonui_canvas_line(moonui_ptr canvas, int x0, int y0, int x1, int y1,
                       int64_t rgb, int width_permille);
/* 文本度量与绘制同一套参数（量出来的就是画出来的）。y 是顶边；
 * 度量返回 (w<<32)|h 打包的 int64，物理像素。 */
int64_t moonui_canvas_measure_text(const char *utf8, int len,
                                   int font_permille, int weight);
int moonui_canvas_draw_text(moonui_ptr canvas, const char *utf8, int len,
                            int x, int y, int font_permille, int weight,
                            int64_t rgb);
/* 位图绘制：bytes 是平台认得的图像编码（沿 T86⑤ 的解码约定）。 */
int moonui_canvas_draw_image(moonui_ptr canvas, const char *bytes, int len,
                             int x, int y, int w, int h);
/* 读一个像素（测试断言用）：rgba 位图里的 (x,y)，返回 0xRRGGBB；
 * 越界/半透明像素按预乘展开，alpha=0 返回 -1。 */
int64_t moonui_canvas_read_pixel(moonui_ptr canvas, int x, int y);
/* 上屏（§52.5 分期②）：把画布挂到一只原生窗口上（window 是
 * moonui_native_window_new 返回的句柄；挂上时把 contentView 转成
 * layer-backed），present 把当前帧位图翻成 CGImage 贴进该 layer。
 * 一帧一贴：present 不清画布，重画靠再一轮 begin_frame。 */
int moonui_canvas_attach_window(moonui_ptr canvas, moonui_ptr window);
int moonui_canvas_present(moonui_ptr canvas);

/* 文案读写。四种老控件在 Win32 里都是窗口文本（libui 自己的 getter 也只是
 * SendMessage(WM_GETTEXT)），所以这里统一走 Win32：一套代码覆盖四种控件，
 * 也不用替 libui 的 uiFreeText 记账。MultilineEntry / DatePicker 也走这对
 * 入口，按 kind 记号各译各的（multiline 在 mac 是 NSTextView 不是
 * NSTextField，datepicker 的值是 struct tm），MoonBit 侧只有 text 一条通道。 */
void moonui_native_widget_set_text(moonui_ptr c, const char *text, int text_len);
moonbit_bytes_t moonui_native_widget_text(moonui_ptr c);

/* 勾选态。只有 Checkbox 有意义，Core 侧已经按 kind 拦住别的控件。 */
void moonui_native_widget_set_checked(moonui_ptr c, int checked);
int moonui_native_widget_checked(moonui_ptr c);

/* 可见/可用：直接 ShowWindow / EnableWindow。不走 uiControlShow 那条，
 * 因为 libui 那两个入口是按"控件在自己的容器树里"设计的，而 §14 的控件
 * 是 MoonUI 自己挂的，libui 的 visible/enabled 记账在这里是多余的第二套状态。 */
void moonui_native_widget_set_visible(moonui_ptr c, int visible);
int moonui_native_widget_visible(moonui_ptr c);
void moonui_native_widget_set_enabled(moonui_ptr c, int enabled);
int moonui_native_widget_enabled(moonui_ptr c);

/* 控件不透明度（T84 动画通道，§32 豁免破的正是这一条）。opacity 是千分比
 * 0..1000——这一层只有整数，Core 的 0..1.0 Double 在 MoonBit 侧乘 1000 换算。
 * 这是动画逐帧推进的值（激活期每帧一条、退场帧推精确落点），所以单独一条
 * ABI，不塞进"整张样式重排才推一次"的通道；样式那份照走 §32 豁免不动
 * （颜色/圆角第一版仍不读）。
 * 平台分法见两份实现：mac 半落到 NSView alphaValue（便宜）；Windows 半是
 * 子窗口分层透明（WS_EX_LAYERED + SetLayeredWindowAttributes(LWA_ALPHA)，
 * Win8 起子窗口才支持——挂账时说的"很麻烦的一档"，成本显著高于 mac 半）。
 * 1000 = 全显，那侧撤掉分层位恢复原生绘制。出界的值两侧都夹进 0..1000。
 * 没有读回口：透明度的唯一事实来源是 Core 的 shown 账（动画泵推进），
 * 回读只是把同一份数据搬两次——与样式同一条理由。 */
void moonui_native_widget_set_opacity(moonui_ptr c, int opacity);

/* ---- 无障碍语义下发（§32 / T41）----
 * Core 在每次重排里随样式把语义一并推下来。role 是 packages/moonui
 * access AccessRole 的声明序号：0=Text 1=Button 2=CheckBox 3=TextBox
 * 4=Group 5=List 6=ListItem 7=Window。state 打包：bit0=visible、
 * bit1=enabled、bits2-3=checked（0=无此态、1=未勾、2=已勾）。
 * Windows 那侧收到后只注记 role/label/description，state 刻意不覆盖——
 * MSAA 标准代理对真实 HWND 本来就动态算这三个位，注记成快照反而在
 * show 之前定格 INVISIBLE、点勾选框后不跟随（T58 真跑定的案）。 */
int moonui_native_set_widget_accessibility(moonui_ptr c, int role,
                                    const char *label, int label_len,
                                    const char *desc, int desc_len,
                                    int state);

/* 固有尺寸，打包 (width, height)，物理像素。
 * 取的是 libui 自己的最小尺寸（label 用文本 extent、button 用
 * BCM_GETIDEALSIZE 否则回落 DLU 换算），不是这里重新量一遍——自己量迟早
 * 和原生控件的真实外观分叉（§18 "字体度量属于原生层"）。 */
int64_t moonui_native_widget_minimum_size(moonui_ptr c);
/* 控件所属窗口的 DPI；还没挂进窗口时退回进程 DPI。 */
int moonui_native_widget_dpi(moonui_ptr c);
/* 相对父窗口客户区的左上角，打包 (x, y)，物理像素。 */
int64_t moonui_native_widget_origin(moonui_ptr c);
/* 控件外框尺寸，打包 (width, height)，物理像素。 */
int64_t moonui_native_widget_size(moonui_ptr c);

/* 注册点击回调（只有 Button 会真的收到 BN_CLICKED）。成功返回 0，槽满 -1。
 * C 侧会 incref closure，所以 MoonBit 不必再替它看守生命周期。 */
int moonui_native_widget_on_clicked(moonui_ptr c, moonui_closure_fn fn, void *closure);

/* 注册"输入框里的字变了"（只有 TextInput 会真的收到）。签名与 on_clicked 完全
 * 一致，包括"回调不带文字"这一点：文字由 MoonBit 回读 moonui_widget_text，C 侧只
 * 报"出事了"——libui 的 f(uiEntry*, void*) 里那个 sender 因此被 trampoline 丢掉。
 * 程序化 set_text 不该回声成一条 Input：Win32 那份 libui 自己用 inhibitChanged 挡
 * 住了（windows/entry.cpp:68,75），darwin 那份靠 setStringValue: 不发
 * controlTextDidChange: ——mac 那半两边都由测试钉住（macos_test 的"真打字进 Input"
 * 把脚手架换成 setStringValue: 就红）。 */
int moonui_native_widget_on_text_changed(moonui_ptr c, moonui_closure_fn fn,
                                  void *closure);

/* 注册"勾选框被点了"（只有 Checkbox 会真的收到；报的是"被点了一下"，勾选态由
 * MoonBit 读 moonui_widget_checked，和文字那条同一个理由）。 */
int moonui_native_widget_on_toggled(moonui_ptr c, moonui_closure_fn fn,
                             void *closure);

/* ---- 扩展控件（§13 的 0.2 批）----
 *
 * 九种新叶子分两类。PasswordInput / Separator 与老四种同形（构造参数只有文案，
 * 文本/可见/可用/摆放走上面那套通用入口），kind 编码 4/5 进 moonui_widget_new。
 * 其余七种（Slider 6 / Spinbox 7 / Progress 8 / ComboBox 9 / MultilineEntry 10 /
 * RadioButtons 11 / DatePicker 12）构造入口分开：Slider / Spinbox 的范围是
 * 构造参数（libui 的 uiNewSlider/uiNewSpinbox 没有事后设范围的入口，Spinbox
 * 连改都没有），其余虽然无参，但 C 侧要顺手把 kind 记到原生对象上（mac 用关联
 * 对象、Windows 用 SetPropW，与 owner 反查同一套手法），下面的通用属性入口
 * 靠这份记号分派到具体的 libui 类型——libui 没有按 uiControl 统一的
 * set_value / append，两份 C 只能把 (kind, ptr) → 具体类型这步自己写。
 *
 * kind 记号是**一次写下、之后只读**的，不会和 MoonBit 侧分叉：Core 在创建
 * 时决定种类，属性调用的合法性由 Core 按 WidgetKind 拦在前头（widget.mbt 的
 * check_value_kind / check_selected_kind），C 侧的 dispatch 只是实现手段。
 * 记号不存在（老控件、或指针不是我们的控件）时通用属性入口一律按"无此属性"
 * 处理：数值读写报 0 / 不动，条目读写不动——不猜。 */

/* 构造：Slider / Spinbox 带范围；其余无参。都返回 0 表示分配失败。 */
moonui_ptr moonui_native_slider_new(int min, int max);
moonui_ptr moonui_native_spinbox_new(int min, int max);
moonui_ptr moonui_native_progress_new(void);
moonui_ptr moonui_native_combobox_new(void);
moonui_ptr moonui_native_radio_new(void);
moonui_ptr moonui_native_multiline_new(void);
moonui_ptr moonui_native_datepicker_new(void);

/* 只有 Slider 有意义（libui 没有 uiSpinboxSetRange）。 */
void moonui_native_slider_set_range(moonui_ptr c, int min, int max);

/* 通用属性，按 kind 记号分派：
 *   set_value / value —— Slider、Spinbox、Progress（0..100，-1 = 不定进度）；
 *   append_option —— ComboBox、RadioButtons，追加到列表末尾；
 *   set_selected / selected —— 同上，选中下标（-1 = 没选中，libui 的哨兵）。 */
void moonui_native_widget_set_value(moonui_ptr c, int v);
int moonui_native_widget_value(moonui_ptr c);
void moonui_native_widget_append_option(moonui_ptr c, const char *text, int text_len);
void moonui_native_widget_set_selected(moonui_ptr c, int index);
int moonui_native_widget_selected(moonui_ptr c);
/* 内缩（Padding 控件的内衬，物理像素四个方向：top、end、bottom、start——
 * 端到端按 Apple 语言的字段序）。 */
void moonui_native_widget_set_insets(moonui_ptr c, int top, int end,
                              int bottom, int start);

/* 多行文本与日期文本都在下面那对通用文案入口里按 kind 分派：multiline 在 mac
 * 上是 NSScrollView 包 NSTextView（不是 NSTextField），datepicker 的值根本
 * 不是文本（是 struct tm），所以 moonui_widget_set_text / _text 按记号各译
 * 各的，MoonBit 侧仍然只有 text 一条通道。 */

/* 日期时间：值为 "YYYY-MM-DD HH:MM:SS" 文本，由 C 侧与各自平台的 struct tm
 * 互转（libui 的 uiDateTimePickerTime/SetTime）。set 返回 0 = 解析成功；
 * -1 = 格式不对；-2 = 句柄不指日期控件。 */
int moonui_native_datepicker_set_text(moonui_ptr c, const char *text, int text_len);
moonbit_bytes_t moonui_native_datepicker_text(moonui_ptr c);

/* 回调，与 on_clicked 同一套槽位机制；通知一律不带内容，值由 MoonBit 回读
 * （§48-16）。返回 0 = 装上，-1 = 槽满。 */
int moonui_native_slider_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure);
int moonui_native_spinbox_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure);
int moonui_native_combobox_on_selected(moonui_ptr c, moonui_closure_fn fn,
                                void *closure);
int moonui_native_radio_on_selected(moonui_ptr c, moonui_closure_fn fn,
                             void *closure);
int moonui_native_multiline_on_changed(moonui_ptr c, moonui_closure_fn fn,
                                void *closure);
int moonui_native_datepicker_on_changed(moonui_ptr c, moonui_closure_fn fn,
                                 void *closure);

/* ---- 控件摆放（§14）----
 * attach 只负责"挂进窗口"：把 HWND 搬到目标窗口，分配控件 ID，插到 z-order
 * 末尾（z-order 就是 Tab 顺序，所以插入顺序 = 焦点顺序）。矩形由
 * moonui_control_set_bounds 单独给——Core 的调用顺序就是先 attach 再布局。 */
void moonui_native_control_attach(moonui_ptr window, moonui_ptr child);
/* T74：挂进容器控件。目前唯一的容器是滚动视口的文档区——child 的坐标在
 * Core 侧已平移成文档区坐标（原点 = 视口左上角），C 侧只管挂接，不再动。 */
void moonui_native_container_attach(moonui_ptr container, moonui_ptr child);
/* T74：滚动视口的滚动行程。axis 0=Vertical 1=Horizontal（与布局的 Axis
 * 编码一致），宽高是物理像素。视口自己的矩形走 moonui_control_set_bounds。 */
void moonui_native_scroll_set_content(moonui_ptr scroll, int axis, int width,
                               int height);
/* x/y 是窗口客户区坐标，单位物理像素。z-order 不动：否则每次 resize 都会
 * 把控件重新排一遍，Tab 顺序跟着布局抖动。 */
void moonui_native_control_set_bounds(moonui_ptr child, int x, int y, int width,
                               int height);
/* 摘下来：挂到一个自建的隐藏窗口上，控件因此不再显示，消息也进不了任何
 * libui 窗口的方法（WM_COMMAND 是发给父窗口的）。ID 清零，重新 attach 时
 * 会重新分配并插到 z-order 末尾。 */
void moonui_native_control_detach(moonui_ptr child);
/* 提到父窗口子窗口列表的最上层（§14 的 Stack：数组靠后的画在上层）。
 * SetWindowPos 会连带重排 Tab 链——原生层只有一份顺序，层叠和焦点是同一个东西，
 * 所以"既要视觉顺序又要声明顺序"在这里做不到，只能由 Core 选一头（见 raise_widget）。 */
void moonui_native_control_raise(moonui_ptr child);
/* 控件在父窗口子窗口列表里的位置，0 = 最上层（和 EnumChildWindows 的返回顺序
 * 同向）。不在任何父窗口的子列表里时返回 -1。测试断言层叠用。 */
int moonui_native_control_z_index(moonui_ptr child);

/* ---- 剪贴板（§23 / §48-19）----
 * libui-ng 不管剪贴板：ui.h 里一个剪贴板入口都没有，所以这两条是两份 C 各自直接
 * 打平台的——Win32 用 OpenClipboard/EmptyClipboard/SetClipboardData(CF_UNICODETEXT)，
 * Cocoa 用 NSPasteboard 的 generalPasteboard。两条都不带句柄参数（剪贴板是进程级
 * 的，不属于任何窗口），因此不进句柄表：读写剪贴板一个原生对象都不建。
 *
 * 读：只认文本。剪贴板空着、或里面是图片之类的非文本内容 → 空 bytes，MoonBit 侧
 * 变成 None。读路径故意没有错误码：Win32 上"打不开剪贴板"意味着别的进程正开着它，
 * 那是暂时的，对调用方和"现在没有文本"是同一个回答；要把这两种分开就得给 §23 的
 * get_text 加一条纯失败的通道，而它没有这个形态。写路径必须分成败——复制没成功
 * 却报"已复制"是用户最难发现的那类错（§33）。
 * 写：0 = 成功；-1 = 拿不到剪贴板（Win32 OpenClipboard 失败 / mac clearContents
 * 返回 NO，通常是另一个进程正开着它）；-2 = 拿住了但没写进去（GlobalAlloc、
 * SetClipboardData 失败 / mac setString:forType: 返回 NO）。 */
moonbit_bytes_t moonui_native_clipboard_text(void);
int moonui_native_clipboard_set_text(const char *text, int text_len);

/* ---- 对话框（§24 / §48-18）----
 * libui 只帮上一半：`uiMsgBox`（`ui.h:2020`）返回 void——它内部明明拿到了用户的
 * 选择（mac 侧 NSAlert 的 result、Windows 侧 MessageBox 的返回值），但没有对外送，
 * 而 §24 的 `confirm` 要的正是这个选择。所以两份 C 都不走 uiMsgBox，各自直接打
 * 平台的原生入口：Cocoa 用 `NSAlert`，Win32 用 `MessageBoxW`。`message` 跟着用
 * 同一套（少一个按钮），不另开第二条原生路径——一个能力两份实现没有好处，而
 * uiMsgBox 连"用户是不是按了确定"都答不了。
 *
 * 都不带窗口句柄：§24 的门面是全局形态（`app.confirm(...)`），Core 没有"这个
 * 对话框属于哪个窗口"的概念；不传句柄也就不进句柄表，和剪贴板同一个理由——
 * 弹一个对话框一个 MoonUI 句柄都不建。两份实现都自己按 modal 跑（mac 是
 * NSAlert 的 runModal，Windows 是 MessageBoxW 的任务模态循环），都不挂到某个
 * 父窗口上，所以 Core 只应在事件循环内调用它们（`dialog.mbt` 的契约）。
 *
 * 按钮的文字是后端的决定，不是 Core 的：契约只区分"确定"和"是/否"这两种形态，
 * 没给标题留参数。Windows 上这两个形态由 MB_OK / MB_YESNO 交给系统本地化；
 * mac 的 AppKit 没有公开"本地化的 是/否 按钮对"，所以标题写死在 Cocoa 那份里。
 * 返回码两边同一套：`message` 的 0 = 用户按了确定；`confirm` 的 1 = 选了"是"、
 * 0 = 选了"否"或把面板关掉（关掉就是没同意，§24 的"取消返回 false"）；
 * -1 = 文案没能交给系统（mac：UTF-8 解不开；Windows：WideCharToMultiByte 失败），
 * -2 = 对话框没弹出来。这两个负数都是真失败，MoonBit 侧变成 `OperationFailed`，
 * 不许和"用户答了否"混在一起（dialog.mbt：取消和失败是两条不同的路）。 */
int moonui_native_dialog_message(const char *title, int title_len, const char *text,
                          int text_len);
int moonui_native_dialog_confirm(const char *title, int title_len, const char *text,
                          int text_len);

/* ---- 文件对话框（§24 / §48-18）----
 * libui 在这件事上只帮一半：`uiOpenFile` / `uiSaveFile`（`ui.h:1975` / `ui.h:2004`）
 * 会开面板，但路径落在 libui 自己进程全局的字符串里，"用户取消"和"没弹出来"都是
 * 同一个 NULL——§24 的契约要的正是"取消和失败是两条路"（dialog.mbt），而选文件夹
 * 连入口都没有。所以两份 C 都不走 libui，各自直接打平台的原生入口：Cocoa 用
 * `NSOpenPanel` / `NSSavePanel`（NSOpenPanel 是 NSSavePanel 的子类，canChooseFiles
 * / canChooseDirectories 切三种形态），Win32 用 `IFileDialog`（CLSID_FileOpenDialog
 * / CLSID_FileSaveDialog，FOS_PICKFOLDERS 切文件夹形态）。
 *
 * 都不带窗口句柄（§24 的门面是全局形态，`app.open_file(...)`），不进句柄表，和
 * 剪贴板 / 对话框同一个理由：弹一次面板一个 MoonUI 句柄都不建。两份实现都自己
 * 按 modal 跑（mac 是 runModal，Windows 是 IFileDialog::Show 自己的模态循环），
 * 所以和对话框一样只能从 handler 里调。
 *
 * 返回码两边同一套：1 = 用户选了东西（路径用 moonui_file_dialog_path 取走）；
 * 0 = 用户取消；-1 = 标题或默认名不是合法 UTF-8；-2 = 面板没能弹出来（AppKit /
 * COM 失败）。取消是 0 而不是空路径："选了个空路径"不是用户做得出来的事，真拿到
 * 空就说明面板状态不对，那属于 -2。取消和失败分开，理由同对话框那段。
 *
 * 路径和返回码拆成两条调用，是因为 MoonBit 的 native FFI 每个函数只有单个返回值
 * （顶部 ABI 约定）。getter 是"取走"语义：每打开一次面板先把上次的结果清掉，
 * 取走之后内部也清空——结果只在 open/save/select_folder 返回 1 之后有意义，
 * 取消或失败之后取到的是空 bytes。default_name 只有 save_file 用：面板打开时
 * 文件名栏里预填的字，open / select_folder 没有这个形态。 */
int moonui_native_open_file(const char *title, int title_len);
int moonui_native_save_file(const char *title, int title_len, const char *default_name,
                     int default_name_len);
int moonui_native_select_folder(const char *title, int title_len);
moonbit_bytes_t moonui_native_file_dialog_path(void);

/* ---- 菜单栏（§25 / §48-20）----
 * libui 的菜单 API 在两个平台都撑不住 §25 的契约，所以整棵原生菜单是两份 C 自己
 * 搭的，libui 只留下"主菜单归谁"这一层：
 *   - darwin：`uiNewWindow` 会调 `uiprivFinalizeMenus()`（`darwin/window.m:438`），
 *     此后 `uiNewMenu` 和加条目一律 `uiprivUserBug`，也就是当场终止进程
 *     （`darwin/menu.m:339` / `:268`）——而 §25 的 `app.set_menubar` 是运行时随时
 *     可以再调一次的。`uiMenuItemSetChecked` 更干脆，入参看都不看、只翻当前态
 *     （`darwin/menu.m:252`）。
 *   - windows：窗口过程把不认识的 `WM_COMMAND` 交给 `runMenuEvent`，那里对未知 id
 *     `uiprivImplBug`（`windows/menu.cpp:296`）= `DebugBreak()`。我们的 id 是 Core 的
 *     编号，libui 的账本里没有，于是"另装一份自己的菜单"会把进程点死。
 * 两边都改打原生入口：Cocoa 往 `[NSApp mainMenu]` 追加 NSMenu——索引 0 是 `uiInit`
 * 自己建的应用菜单（`darwin/main.m:128`），我们只往后加，并且加了几顶自己记一份名单，
 * 拆旧、查 id、出快照都按名单在**主菜单里**认，不数"索引 1 往后"（那靠的是别人的顺序）；
 * Win32 给每个活窗口 `CreateMenu` 一份自己的 HMENU 再 `SetMenu`，和 libui 自己"逐窗口
 * 一份"的做法同形（`windows/window.cpp:554`），所以装菜单要兼顾两头：给当下所有活窗口
 * 各装一棵，并且记住这棵树，让之后新建的窗口也拿到它。
 *
 * Win32 那一头多一个必须算对的东西：菜单位占的是窗口的客户区，`SetMenu` 之后客户区矮掉
 * 一行，而 Core 记的是"客户区 = 我要的那个尺寸"。两种装序分开处理（`adapter.c` 的
 * `moonui_window_new` 与 `moonui_menu_apply`）：
 *   - 建窗口时就已经有一棵树 → `uiNewWindow` 最后一个参数给 1，让 libui 自己把那一行算进
 *     外框。它每次换算都现量当下挂着的那棵（`windows/winutil.cpp:80-106`：
 *     `AdjustWindowRectEx` 再补一次 `WM_NCCALCSIZE`），所以这一头什么都不用再补。
 *   - 事后才装（§25 的运行时路径）→ libui 当时按"没有菜单位"算的外框，事后并不知道。
 *     装完把外框补回来：补多少不抄 `SM_CYMENU`（不同 DPI、不同菜单字体下它不等于实际行
 *     高），而是摘掉量一次客户区、挂上再量一次，差值才是那一行真正占掉多少。补的那一步
 *     走 libui 自己的 `uiWindowSetContentSize`，它把 `changingSize` 立起来
 *     （`windows/window.cpp:368-375`），于是这次换算不会冒出一条 Core 没要求的尺寸变化。
 * 之后每次 `moonui_window_set_content_size` 都得再上这一行（只有事后才装的那些窗口上非
 * 0），拆掉菜单时跟着归零，否则 Core 读到的窗口高度、以及按这个高度摆下去的控件矩形会
 * 整体偏矮。已知的一处不完美：libui 的 `ensureMinimumWindowSize`（`window.cpp:573-586`）
 * 和 `WM_GETMINMAXINFO` 用的还是建窗口时那一位 `w->hasMenubar`，所以事后才装的窗口，
 * 最小尺寸的下限少一行菜单——这条挂在 `T45` 真跑时量。
 *
 *
 * 整棵一次装完，没有增量修改的入口：§25 的契约本来就是"换一份菜单栏"，而要改条目
 * 顺序或嵌套，重建比维护两套记账便宜。重复调用 = 先把旧的拆干净再装新的，这一步不许
 * 省——mac 的主菜单是进程全局的，留着上一棵就在同一处叠了两份。
 *
 * 整棵树打包成一段字节传进来（`tree`/`tree_len` 是任意字节，不必 NUL 结尾），因为
 * MoonBit 侧手上是引用语义的对象树，C 侧要的是"这一棵长什么样"的完整快照，而递归的
 * struct 过不了 native FFI、一次调用过一根 Bytes 可以。布局（整数一律小端 i32；
 * 字符串 = i32 字节数 + UTF-8 内容，不带 NUL）：
 *   tree = u8 version(=1), i32 menu_count, menu_count × menu
 *   menu = i32 label_len, label, i32 node_count, node_count × node
 *   node = u8 kind
 *          0 可点项： i32 label_len, label, i32 id,
 *                     u8 role(0=Normal 1=Check 2=Radio), u8 checked,
 *                     u8 enabled, u8 has_shortcut,
 *                     has_shortcut 非 0 时再接 u8 mods(bit0 ctrl, bit1 alt,
 *                     bit2 shift, bit3 meta), i32 key_len, key
 *          1 分隔线： 没有后续字段
 *          2 子菜单： i32 label_len, label, i32 node_count, node_count × node
 *                     （递归，和 menu 同一套条目）
 * id 是 Core 在整棵菜单栏里分配的唯一编号，原样放进原生对象（mac 的 `NSMenuItem.tag`；
 * Win32 的命令 id，加一个基址避开 libui 自己那些 id），点击回调再把它送回去。
 * checked/enabled 只是安装那一刻的快照，之后的变化走下面那条推。
 *
 * 返回码两边同一套：0 = 整棵装好；-1 = 树不合法（版本号不对、长度越界、kind 未知），
 * 此时旧的菜单一动不动地留着——装了一半的菜单栏比装不上更难查；-2 = 还没
 * `moonui_init`（mac 的主菜单在那之后才存在）。MoonBit 侧把任何负数变成
 * `OperationFailed`。
 *
 * 点击回调只报"哪一项被点了"，报的是原生派发这件事本身发生了：和控件那几个回调
 * 同一个理由，"这一项现在勾着没"由 MoonBit 读 Core 的状态，不让 C 再送一份可能
 * 过期的副本。closure 由 C 侧 incref 看守（全局一份，重装和 `moonui_terminate`
 * 时松开），不占控件回调那张槽位表——菜单栏全局只有一个。
 *
 * 快捷键的显示是两边真正分叉的地方，而各自都是那个平台的正确做法：
 *   - mac：字母/数字/空格/回车/Tab/Esc/退格/删除 映射成 `keyEquivalent`，修饰键
 *     **照字面**映射（ctrl→⌃、alt→⌥、shift→⇧、meta→⌘），不做"mac 上把 Ctrl 当成
 *     Cmd 用"那种替换。理由是显示和派发必须同源：`Shortcut::meta("q")` 在 Core 匹配
 *     的就是 ⌘，这里偷偷换成 ⌃ 的话，菜单上写着 ⌘Q、按下去却什么都不动。功能键和
 *     方向键在 NSMenuItem 上没有可靠的对应形态（`keyEquivalent` 收不下它们），只能
 *     整个不显示——显示不出来的组合不假装有。
 *     `T39` 接 mac 的按键源时这条兑现了：装了 `keyEquivalent` 之后 AppKit 自己就会
 *     派发这组按键，同一组合于是既有 AppKit 的菜单动作、又有 Core 的 KeyDown 匹配。
 *     处理写在下面键盘那一节——被菜单认领的组合两侧都不产 KeyDown/KeyUp。
 *   - Windows：把组合的文本用 \t 拼在标题后面显示（"Quit\tCtrl+q"），不建 accelerator
 *     table——§26 的派发在 Core 的事件循环里，不在 Win32 的加速键表里。
 * 同理，radio 的原生外观也不同：mac 显示勾（AppKit 的圆点只给同一 action 的分组，
 * 而互斥是 Core 算的），Windows 用 MFT_RADIOCHECK 的圆点（它打在 fType 里，不是状态位）。
 * 外观不同、语义相同：两者
 * 表示的都是 Core 推过来的 `checked`。 */
int moonui_native_set_menu_bar(const char *tree, int tree_len, moonui_closure_id_fn fn,
                        void *closure);

/* 把 Core 改掉的勾选态推给当下那棵原生菜单。§25 里 Checkbox/Radio 的状态只存在
 * Core——libui 那侧没有可靠的读回接口，"同组互斥"又是 Core 的规则——所以后端不可能
 * 自己发现该显示什么，只能由 Core 在点击之后逐项推过去
 * （`App::click_menu_item` → `Backend::set_menu_item_checked`）。Radio 因此是整组一起
 * 推，不只是被点的那一项。
 * 0 = 改到了；-1 = 这个 id 不在当前那棵菜单里（没装过，或装的树里没有它）。
 * 禁用项也允许改：置灰的菜单项照样要显示着勾。 */
int moonui_native_menu_item_set_checked(int id, int checked);

/* 应用图标（§26）。name 是不带扩展名的 stem：mac 侧补 .png、Windows 侧补 .ico，
 * 调用方一份路径两平台通用，路径相对进程 CWD 解析。
 * 0 = 装上了；-1 = 文件读不出来（路径不对或格式不受支持）；-2 = 还没初始化。 */
int moonui_native_set_app_icon(const char *name, int name_len);

/* 测试探针：当前进程是否已经装上过图标（0/1）。mock 之外的两份 C adapter 都给。
 * 仅 Windows 的那条近亲是下面的 window_icon_installed。 */
int moonui_native_app_icon_present(void);

/* 测试探针（仅 macOS）：最后一次装上的图标里，内容占画布的千分比。
 * 805 = 已经按 macOS 图标网格留白（824/1024），1000 = 满幅；-1 = 还没装过。
 * 为什么要有它：Dock 把图标当整块画布摆，满幅图会比邻居大一圈——这条把
 * "留白生效了"变成可断言的事实，而不是看截图猜。 */
int moonui_native_app_icon_content_permille(void);

/* ---- 键盘与焦点（§10 的 KeyDown/KeyUp、§26 的快捷键、§32 的 focused）----
 *
 * 形状和控件那三条回调不同：**监听整个进程一份**，不是每个控件一份。理由是控件的
 * view / HWND 都是 libui 建的：mac 这边不能给别人的 view 换 -keyDown:，Windows 那边
 * 给每个控件挂一次子类过程既费槽位也没好处（同一时刻只可能有一个控件收键）。按控件
 * 数乘的那笔代价因此不存在，`T39` 挂账时问的"要不要先把槽位表按种类分池"也不用付——
 * 96 格装的还是"每窗口 2 格 + 每控件 1 格 + 全局这一格"。
 *
 * 通知不带内容、内容回读，和 widget_on_text_changed 同一条约定（§48-16）：回调只说
 * "有一颗键出事了"，MoonBit 当场读下面四条快照。快照在调闭包之前写好、闭包返回之后
 * 没人再动，所以一次通知配一次读，中间插不进第二颗键。
 *
 * 归属怎么认：建窗口和建控件时，在原生对象上反记一笔"这是哪个 moonui_ptr"（mac 用
 * objc_setAssociatedObject 的 ASSIGN 策略，Windows 用 SetPropW），原生对象销毁时这条
 * 跟着没。按键和焦点都靠这一次反查认人，C 侧不另开一张活对象表——那份账 MoonBit 的
 * HandleTable 已经有了，两处记就一定分叉。
 *
 * 键名词表（两份 C 必须给同一套字符串，Core 的 Shortcut 是按字符串精确匹配的，
 * 这里不另立第二个名字空间，用的就是 event.mbt 那套）：
 *   字母、数字一律小写（"q"、"7"）——Shift 走修饰键位，不把字母变大写，否则同一个
 *   组合在两边会读出两个键名；
 *   空格 "Space"、回车 "Enter"、Tab "Tab"、Esc "Escape"、退格 "Backspace"、
 *   删除 "Delete"、方向 "Up"/"Down"/"Left"/"Right"、"Home"/"End"/"PageUp"/
 *   "PageDown"/"Insert"（Insert 只有 Windows 的键盘真有）、功能键 "F1".."F12"。
 *   词表以外的键（修饰键自己、输入法、媒体键）不产事件：moonui_native_key_name() 给空
 *   bytes，MoonBit 据此丢掉。
 * 归一化各自的位置：mac 先取 charactersIgnoringModifiers 的第一个码元，是字母/数字/
 * 空格就用它，其余查 keyCode 表；Windows 查 VK_* 表。同一个物理键在两边给出同一个
 * 字符串，这就是这条 ABI 的全部承诺。修饰键位 = bit0 ctrl、bit1 alt、bit2 shift、
 * bit3 meta，和上面 §25 那棵树里组合那一栏同一个编码。
 *
 * mac 一条必须在这里写死的规则（上面 §25 那段预告的就是它）：装了 keyEquivalent 之后
 * AppKit 自己就派发这组键，于是同一个 ⌘Q 既有菜单动作、又有 Core 的 KeyDown 匹配，
 * 处理函数跑两遍。监听因此在触发回调之前先问主菜单"这一组你收不收"——判据是照
 * keyEquivalent + keyEquivalentModifierMask 精确匹配整棵树（含子菜单、含禁用项，
 * 因为收不收是 AppKit 的事，我们只判断形状对得上对得上就不报给 Core），收就不产
 * KeyDown/KeyUp，让 MenuSelect 那条路走；不收才报。**Windows 没有这个问题**：§25 定
 * 了不建 accelerator table，组合只出现在标题文本里，派发只有 Core 一条路。这条规则
 * 的验证现状（`T96`① 撤过、`T103` 写回）：mac 由
 * `backends/native-macos/native_test.mbt` 的「⌘Q 被菜单认领只响一次且是
 * MenuSelect，KeyUp 不漏」钉住——真 NSEvent 经 `sendEvent:` 走完整条监听 + 主菜单
 * 认领 + 吞键状态机；这条真跑顺带咬出一个老 bug：`keyEquivalentModifierMask` 是
 * 旗标巨值，和四位打包直接比永远不等，⌘Q 的认领自移植以来从未匹配成功（双发），
 * 修在 `moonui_native_flags_of_mods`。Windows 有键注入脚手架可钉"⌃S 只响一次且是
 * KeyDown"，真窗断言仍欠（`T103` 尾）。 */
/* 装那份进程级键盘监听。0 = 装上了（重复调用只换回调，监听还是那一份）；
 * -1 = 槽位用满或监听没装上（mac 的 `addLocalMonitorForEventsMatchingMask:`
 * 返 nil 也走这一支，`T96②`）。 */
int moonui_native_on_key(moonui_closure_fn fn, void *closure);
/* 当下这颗键归属的那个"我们的对象"：焦点控件是我们的控件就报控件，不是就报事件所属
 * 的那只我们的窗口，两个都不是（例如另一个进程的键）报 0，MoonBit 侧据此丢弃事件。 */
moonui_ptr moonui_native_key_target(void);
/* 1 = 按下，0 = 抬起。 */
int moonui_native_key_is_down(void);
/* 修饰键位，见上面那套编码。 */
int moonui_native_key_modifiers(void);
/* 键名，UTF-8，见那张词表。空 bytes = 这颗键不在词表里，不该产事件。 */
moonbit_bytes_t moonui_native_key_name(void);

/* 焦点（§32）。不带回调，由 MoonBit 每圈事件循环问一次：这只窗口当下把焦点给了哪个
 * 我们的控件；没有（焦点在窗口自己、在 libui 内部的辅助 view、或那个原生对象我们没
 * 记过）报 0。
 * 为什么是问而不是报：两边都没有一个既及时又不侵入的"焦点变了"来源——mac 只有
 * NSWindowDidUpdateNotification（打字时每颗键都来一遍），Windows 得给每个控件挂
 * WM_KILLFOCUS/WM_SETFOCUS，两条都回到按控件乘那笔账。问还有第二个好处："上一次是
 * 谁"只有 MoonBit 记得住，去重因此发生在推事件那一步，程序自己改焦点不会多出事件
 * （真窗口测试钉这条），而 mac 读的是那只窗口自己的 firstResponder（AppKit 每只窗口
 * 各存一份），它不表示"整个应用此刻在听键盘的那只"——那是 [NSApp keyWindow] 的事。 */
moonui_ptr moonui_native_focused_control(moonui_ptr w);

/* ---- 鼠标与滚动（§10 的 MouseDown / MouseUp / MouseMove / Scroll / DoubleClick）----
 *
 * 和键盘同一条形状：监听整个进程一份，通知不带内容，四样当场读回
 * （target / kind_button / pos / delta）。`T39` 挂账时预言的"鼠标是按控件数乘槽位
 * 的第一次"没有发生：不给 libui 建的每只 view 挂 NSTrackingArea，也不逐控件子类化收
 * WM_MOUSEMOVE——移动和滚动都由那一份进程级监听拿到，控件是靠**坐标反查**认出来的
 * （mac `-[NSView hitTest:]`、Windows `ChildWindowFromPoint`），命中的那个原生对象再
 * 顺着建对象时反记的 owner 认出它是我们的哪个控件，和键盘的焦点反查同一张表。
 * 96 格因此还是"每窗口 2 格 + 每控件 1 格 + 全局键盘 1 格 + 全局鼠标 1 格"，
 * `T38` 里"最可能先撞满槽位"那一格跟着作废。
 *
 * 命中为什么在 C 不在 Core，三条都是当前树的现状：①Core 的树里**布局节点没有矩形**
 * ——`packages/moonui/layout.mbt` 的 `layout` 只给叶子（T74 后还包括滚动视口）
 * 往 out 里放 `Placed`，`do_layout` 也只给这些项写回 bounds，Column/Row 在
 * Core 里没有 frame，一个点落在它们身上问不出答案；②Core 的 frame 是"没滚动的布局"
 * 的绝对坐标（T74 之后只在写回后端时按视口平移，Core 自己存的仍是视口前的），
 * 原生命中拿到的是用户
 * 眼睛看到的那一层；③`Event::DoubleClick(EventTarget)` 不带点，Core 要命中只能自己
 * 再存一份"上一条 MouseDown 落在哪儿"，那是把原生已经知道的东西抄一遍。命中在 C 还有
 * 一笔顺带的收入：控件没摆到 Core 以为的矩形上，命中的就是 contentView / 父窗口，这条
 * 事件在 target 那一步被丢掉，测试立刻红——和 click_button_in_window 同一个理由。
 *
 * kind 与 button 打包成一个 int：`kind * 8 + button`。
 *   kind 0 = 按下、1 = 抬起、2 = 移动或拖拽、3 = 双击、4 = 滚轮；
 *   （2026-10-17 §52 分期③）mac 半的监听 mask 另含 LeftMouseDown /
 *   LeftMouseUp，编码 kind 0 button 0（左键按下）/ kind 1 button 0（左键
 *   抬起），且**空白处也报窗口**——自绘后端的命中测试靠它们（自绘控件没有
 *   原生对象，空白即整窗）。原生后端的 MoonBit 闭包不翻译这两个编码，行为
 *   不变；Windows 半这两颗走 `WM_LBUTTONDOWN`/`WM_LBUTTONUP`，本就有。
 *   button 0 = Left、1 = Right、2 = Middle、3 = Extra1、4 = Extra2，和
 *   `packages/moonui/event.mbt` 里 `MouseButton` 的声明顺序一字不差。
 * kind 2 的 button 是"按住哪颗在拖"；kind 4 的 button 位无意义、恒
 * 0，因为 `Event::Scroll` 里没有键这一栏。kind 2 在 mac 上只来自 `*MouseDragged`：
 * 没按住键的纯光标移动要窗口 `acceptsMouseMovedEvents = YES` 才产出，而 libui 的
 * darwin 实现从来没设过那一句，打开它是改产品行为，跟着 hover/leave 那一格走。
 * 两边在这一档上有两个真差别：一是 Windows 连没按住键的纯移动也照样投
 * `WM_MOUSEMOVE`，同样一只手在窗口里抖一下，Core 收到的 `MouseMove` 条数比 mac 多；
 * 二是 Win32 的一条 `WM_MOUSEMOVE` 不带"哪颗键"，只能从 `MK_LBUTTON` 那一组标志读，
 * 没键按着时它们是空的、读回 0，于是"没人拖着"和"左键拖着"是同一个数（mac 由事件类型
 * 自己说，分得开）。第二条撞在谁身上？没有人——`Event::MouseMove` 根本没有键这一栏，
 * Core 拿不到这个歧义，所以两边都不许在这里补断言，把它当成"两边报的是同一个 0"就行。
 * 第一条撞在谁身上？也没人：Core 现在没有任何一处消费 `MouseMove`（Demo 里没画光标），
 * 所以条数差暂时只影响"队列里多几条要抽干"，测试按各侧的真值断言条数。
 * 第二次按下**只产 kind 3，不再产 kind 0**：Win32 的 `WM_LBUTTONDBLCLK` 本来就取代了
 * 第二颗 `WM_LBUTTONDOWN`，mac 的那一次是同一个 `NSLeftMouseDown` 带 `clickCount>=2`。
 * **抬起那一颗两边不等价**，这是继 ⌘Q 之后第二条平台差异，各侧的测试按各侧的真值断言：
 * mac 的本地监听会被控件自己的 tracking loop 绕过（`NSEvent.h` 明写嵌套循环不收监听；
 * adapter_macos.m 的「鼠标与滚动」那一节第 4 条有本机的实测），所以落在会自跑的控件
 * （NSButton 这一类）上的按下，那颗配套的抬起永远不报给 Core；落在不自跑的控件（label
 * 那一类）上时抬起照常在下一圈派发。Win32 的 `WH_GETMESSAGE` 钩子在消息离开队列之前
 * 就能看到它，两种控件都报两条。人手点击不受这条影响（`Click` 走的是 libui 自己的
 * `uiButtonOnClicked`），死的只有"抬起也报给 Core"这一档，而它现在没有 Core 侧消费者。
 * `Click` 不在这条 ABI 里——它还是 libui 自己的 `uiButtonOnClicked` 发的。总账两边
 * 不一样，这是实测订正过的（T53 真跑）：mac 是 kind 0 一条 + kind 3 一条，共 2 条
 * Click 配 1 条 DoubleClick（NSButton 的 action 在按下那颗上，第二次照样触发）；Win32
 * 是 kind 3 的四条消息里**两颗 up 各报一条 BN_CLICKED**——BUTTON 类带 CS_DBLCLKS，
 * BS_PUSHBUTTON 把 WM_LBUTTONDBLCLK 也当作一次按下，BN_DBLCLK 那一档只有 radio/
 * groupbox 那些样式才有，pushbutton 上不存在——加上 kind 0 的一条，共 3 条 Click 配
 * 1 条 DoubleClick。人手"点一下再双击"在 Core 看到的就是 3 条，各侧测试按各自真值断言。
 *
 * 两个坐标口径分开读，这一格最容易写错，负控制钉的就是它：
 *   pos —— **物理像素**，原点是客户区（mac 的 contentView、Win32 的 client area）左上角、
 *     y 向下：和 `moonui_widget_origin` 报的是同一个空间、和 `moonui_click_button_in_window`
 *     收的是同一套数。除回逻辑值是 MoonBit 的事，除的是**命中那只控件**的
 *     `moonui_widget_dpi`（控件自己问不到就按父窗口，还没挂进窗口退回进程 DPI）。
 *     §30 那句"鼠标的点是物理的、适配器入队前要除以该窗口的 Scale"落的正是这里。
 *   delta —— **已经是逻辑像素**，MoonBit 不许再除一次。两边的原生单位本来都不是像素：
 *     mac 的 `scrollingDeltaX/Y` 在 `hasPreciseScrollingDeltas` 时已经是点，逐行的滚轮
 *     （那个旗标为 0 时读回来的两个数就是行数）要乘 `CGEventSourceGetPixelsPerLine(NULL)`
 *     才换成点——本机实测 10.0，别把它当常数写死。AppKit 自己不做这次乘法，实测过：
 *     写 3 行进、读回 3.000 行。Windows 给的是 `WHEEL_DELTA` 的格数，乘
 *     `SPI_GETWHEELSCROLLLINES`（横向是 `SPI_GETWHEELSCROLLCHARS`）换成行、乘消息字体的
 *     `tmHeight` 换成像素、再除以 (dpi/96) 才是逻辑像素。三步都在 C 里做完，因为用的那几个数只在各自平台存在。
 *     Windows 那一侧有两条设置是让这条链走到头的：SPI 报回 -1 原话是"一格滚一页"，
 *     "一页"归收件控件自己定，没有出处的数就不许乘出一个有出处的像素，于是那份实现
 *     把整条滚动事件丢掉而不是猜；报回 0 是有意义的（用户选了"滚动鼠标时不滚动"），
 *     换算出来就是 0。
 *   方向：正 = 往下读 / 往右读（滚动偏移增大，内容在屏幕上往左上走）。mac 必须按
 *     `isDirectionInvertedFromDevice` 决定是否取反——AppKit 对 `NSScrollWheel` 已经照
 *     系统"自然滚动"的偏好翻过一次（NSEvent.h 的原话是 inverted according to the user's
 *     preferences … compensate by multiplying -1 if needed），所以这里读那个旗标而不是
 *     猜一个方向；真手指和这条约定的对应关系本机自动化量不到（合成事件进的是同一个监听），
 *     由下面那条脚手架反向钉住往返，剩下那一半要人在 examples 里看一眼。
 *
 * target 只认**我们的控件**：命中的对象往上退到第一个打过 owner 标记的原生对象（mac 的
 * superview 链、Windows 的 GetParent 链），退不到报 0，MoonBit 据此丢掉整条事件。这里
 * 不猜"那应该是窗口自己吧"：Core 现在没有任何一处消费落在空白处的鼠标事件（§32 的
 * focused 改由点击驱动是 `T41` 那一格），猜来的那条只是往 target 的 id 空间里多塞一个
 * 窗口。落在控件之间空隙上的滚轮因此没有收件人，那是同一格欠账——视口在 Core 里还不是
 * 一个有原生对象的东西。
 *
 * 悬停通道（皮肤账那批）给"移动"破了一条口子：kind 2 = 移动、kind 5 = cursor
 * 离开窗口。这两支在空白处**报窗口自己**（MoonBit 侧认得出那是 unhover），
 * 其余 kind 空白处照旧整条丢弃。离开窗口用 kind 5 而不是词表里的 kind 3：
 * kind 3 留给双击（Windows 的 WM_*BUTTONDBLCLK 一直报 kind 3），mac 原来拿
 * kind 3 当"离开"是悬停通道那批的临时占位，`T98①` 双击进这条 ABI 时让出来、
 * 离开挪到词表外的 kind 5（两个 MoonBit 闭包的"移动/离开"判定同步从 ==3 改
 * 成 ==5）。
 *
 * 滚轮/中键/双击（`T98①`）：mac 半的监听 mask 现含 ScrollWheel / OtherMouseDown /
 * OtherMouseUp，左键 clickCount>=2 报 kind 3（第二次按下不再产 kind 0，与
 * Windows 同一条）。滚轮/中键/双击在空白处**报窗口自己**（自绘后端的命中测试
 * 靠坐标反查，空白即整窗）；原生后端的闭包对这三类编码不翻译（滚轮归
 * NSScrollView 自己、中键/双击无原生消费者），行为不变。 */
/* 装那份进程级鼠标监听。0 = 装上了（重复调用只换回调，监听还是那一份）；
 * -1 = 槽位用满或者平台没给挂上。 */
int moonui_native_on_mouse(moonui_closure_fn fn, void *closure);
/* 当下这次鼠标事件命中的那个"我们的控件"，见上面 target 那段。 */
moonui_ptr moonui_native_mouse_target(void);
/* kind * 8 + button，见上面那套编码。 */
int moonui_native_mouse_kind_button(void);
/* 客户区左上角为原点的物理像素，两个 int32 打包（高 32 位是 x）。 */
int64_t moonui_native_mouse_pos(void);
/* 滚动增量，逻辑像素，两个 int32 打包（高 32 位是 dx）；kind 不是 4 时是 0。
 * 两平台都实现（`T98①` 起 mac 半补上）：Windows 从 WHEEL_DELTA 格数换算，
 * mac 从 scrollingDeltaX/Y（hasPreciseScrollingDeltas 时已是点，逐行滚轮乘
 * CGEventSourceGetPixelsPerLine 换点）换算，方向按 isDirectionInvertedFromDevice
 * 取反。换算全在 C 里做完，MoonBit 不许再除一次。 */
int64_t moonui_native_mouse_delta(void);

/* ---- 事件循环（§10）---- */
void moonui_native_main_steps(void);
/* 走一步。返回 0 表示循环已经结束（收到 WM_QUIT）；返回 1 只说明"这一步没结束"，
 * 处理了一条消息和队列本来就空着都是 1，所以调用方要自己问还剩不剩。 */
int moonui_native_main_step(int wait);
/* 队列里还有消息可取吗（PeekMessage + PM_NOREMOVE，只探测不取）。 */
int moonui_native_messages_pending(void);
/* 等消息，最多 ms 毫秒。返回 1 = 有新消息，0 = 超时。
 * 注意"新"是相对上次唤醒算的：队列里有积压时它照样报超时，所以这个返回值
 * 只能当唤醒用，判断有没有活要干得靠 moonui_messages_pending。 */
int moonui_native_wait_messages(int ms);
/* 单调时钟，毫秒。给 poll_event 的等待预算当墙钟截止点：预算的含义是
 * "最多等这么久"，不是"最多空转这么多轮"。 */
int64_t moonui_native_time_ms(void);
void moonui_native_quit(void);

/* ---- 测试脚手架（两平台真窗测试共用的投递与探针；逐条正文标明哪半有实现）----
 * 投递一律走真事件而不是"把回调调一遍"：Windows 发对应的原生消息、mac 造真
 * NSEvent 交给 `[NSApp sendEvent:]`，于是监听、菜单认领、控件自己的 action 都被
 * 真跑一遍。`T103`（2026-10-20）起 mac 补齐了键盘与坐标点击这一组——下面四条
 * 现在两平台都有实现，`T96`① 撤下的 ⌘Q 判据随 `send_key_in_window` 写回键盘段注。
 * 产品路径不需要这一节：真实点击由控件自己的 action 路由送进来，关闭由标题栏按钮。 */

/* 等价于"用户在窗口客户区的 (x, y) 处按了一下鼠标"。
 *
 * 两平台都按窗口标题找回真窗口、对坐标做命中测试，再让命中的按钮走自己的
 * action 路由：Windows 发 BM_CLICK（BN_CLICKED/WM_COMMAND 那条），mac 调
 * `-[NSButton performClick:]`——合成的 mouseDown 会让按钮进 tracking 嵌套循环
 * 等一颗不在队列里的抬起，当场挂死（`T103` 真跑量出来的；与鼠标段那条"嵌套
 * 循环不收监听"是同一个 AppKit 事实）。于是 §48 的回调链路是被真实验证的，
 * 不是被 mock 出来的。
 * 按坐标而不是"取第一个按钮"是为了让布局结果本身参与验证：控件没摆到
 * MoonUI 以为的矩形上就命中不到。
 * 返回 0 表示消息已发出；-1 编码失败，-2 找不到窗口，-3 命不中任何子窗口，
 * -4 命中的不是按钮（含命中空白处）。 */
int moonui_native_click_button_in_window(const char *title, int title_len, int x,
                                  int y);

/* 等价于"用户点了标题匹配窗口的关闭按钮"：PostMessage 一条 WM_CLOSE。
 * 返回 0 = 已投递（消息在之后的事件循环里才被处理），-1 编码失败，
 * -2 找不到窗口。 */
int moonui_native_request_window_close(const char *title, int title_len);

/* 等价于"用户在客户区 (x, y) 处按了一下右键（按下+抬起一对）"。**只 mac 有**
 * （`T91①` 补的）：Windows 那侧右键投递走 `send_mouse_in_window` 的同一颗
 * 消息，坐标/编码不必再来一套。
 *
 * 为什么不是 `send_mouse_in_window` 的 mac 半：那条的契约含左键按下/抬起与
 * 双击，而 AppKit 的按钮/滚动条在合成的 mouseDown 里会开 tracking 嵌套循环
 * 等一颗**不在队列里**的抬起（`T103` 量到的同一件事），要先把抬起 postEvent
 * 排进队列才敢发按下——一整条泵消息的时序账。右键菜单这条测试只需要"一组
 * 真 NSEvent 进 sendEvent:"：右键按下在默认的 NSView 上不开循环，进程级鼠标
 * 监听（`on_mouse`）在 sendEvent 里同步跑掉，于是 target/位置/kind 全是原生
 * 给的，不是把回调调一遍。左键那一半的 mac 投递仍是欠账（挂在 `T91①` 尾）。
 *
 * 坐标口径同 click_button_in_window（客户区左上原点、物理像素）；命中不到
 * （点在客户区外）报 -3。**编辑中的文本控件上方别用这条**：NSTextView 的
 * 默认 rightMouseDown: 会弹它自己的系统菜单（一层同步追踪循环），测试会挂
 * 在那儿——adapter.h 文件拖入段记的 field editor 边界是同一个 AppKit 事实。
 * 返回 0 = 一对已派发（监听在本次调用里跑完）；-1 造不出事件，-2 找不到窗口，
 * -3 点在客户区外。 */
int moonui_native_right_click_in_window(const char *title, int title_len, int x,
                                 int y);

/* 这里没有"量一次 Tab 方向"的脚手架：合成 VK_TAB 要先让进程拿到前台，
 * 而前台归属是这台机器的用户状态，量出来的落点跟着激活时序漂。层叠的代价
 * 只需要"绘画顺序和 Tab 顺序是同一条原生子窗口列表"这一条事实，它是 Win32
 * 的定义；列表本身的方向由 moonui_control_z_index 在测试里钉住。 */

/* 等价于"用户在窗口客户区 (x, y) 处那个输入框里打出 text"（两平台都有实现；
 * mac 半由 `T103` 补上，段头同证）。
 *
 * 按坐标命中再判种类，和 click_button_in_window 同一个理由：控件没摆到 MoonUI
 * 以为的矩形上就命不中，布局因此参与验证。三步是：命中、把插入点放到文末、
 * 然后走"真人打字"的那条路。中间那步不放不行——控件里的初始文字前面会变成
 * 新字的落点，而"往哪儿插"是测试自己定的前提，不该跟着默认选中区漂：
 * Windows 是 EM_SETSEL 到末尾，再逐字符 SendMessage(WM_CHAR)。edit 自己的窗口
 * 过程处理 WM_CHAR 并对外发 EN_CHANGE，这正是 TranslateMessage 之后真人按键的
 * 落点；不用 EM_REPLACESEL（跳过字符处理，不是打字）。mac 是
 * makeFirstResponder: 让控件拿到共享 field editor、先把插入点收到文末（不收的话
 * field editor 初始的全选态会把预置文字整串替换掉——`T103` 真跑咬出），再
 * insertText: 整串一次；通知粒度因此是"一次 Input 带整串"，与 Windows 的逐字符
 * 不同，测试按各侧真值断言。
 * 返回 0 = 文字已进到控件里；-1 编码失败，-2 找不到窗口，-3 命不中子控件，
 * -4 命中的不是输入框，-5 命中了但拿不到可编辑的文本栈。 */
int moonui_native_type_text_in_window(const char *title, int title_len, int x, int y,
                               const char *text, int text_len);

/* 等价于"用户在窗口客户区 (x, y) 处给出一次鼠标动作"：kind_button 是上面那套打包，
 * x/y 是那个空间里的物理像素，dx/dy 是 Core 该看到的那两个逻辑像素（非滚轮时给 0,0）。
 * 参数这一侧不打包——只有返回值才需要挤进一个 Int64，进来从来都是两个 Int。
 *
 * delta 为什么给"Core 该看到的数"而不是"原生那一格的数"：产品路径上这两个数隔着各
 * 平台一次换算（mac 的旗标取反，Windows 的格→行→像素→除以 dpi）。脚手架要是也从原生
 * 那一格给，测试断的只剩"我们把同一个换算写了两遍、并且两遍写得很一致"；从反方向给
 * （C 内部按同一个旗标把数送成原生事件），往返自逆就把"换算只做一次、方向不漂"钉住了：
 * 旗标读反、多除一次 Scale、符号丢在某一支，都红在这里。仍然钉不住的是"真手指往下推到
 * 底是不是正"，那一半自动化拿不到，要人在 examples 里用眼睛对。
 *
 * 投递走真事件，不是"把回调调一遍"。**mac 半还没实现**（`T91①` 复验时按实测订正：
 * 这段头注早先写的 mac 走法（`+[NSEvent mouseEventWithType:]` + `sendEvent:`、
 * 滚轮的 `CGEventCreateScrollWheelEvent`）是 libui 时代的记录，全仓
 * `moonui_native_send_mouse_in_window` 只有 Windows 一份定义）。`T91①` 只补了右键
 * 那一支单列的 `right_click_in_window`——右键在默认 NSView 上不开 tracking 循环，
 * 一对 `+[NSEvent mouseEventWithType:]` 加 `sendEvent:` 就够。左键按下/抬起与双击
 * 要**先把配套的抬起排进队列**（`postEvent:atStart:NO`）再发按下：会自跑的控件
 * （NSButton、滚动条）在 `trackMouse:` 里从队列取那一颗，取不到就出不来，测试表现
 * 为挂住而不是红——这半仍是欠账，挂在这条的 mac 侧。
 * Windows 给命中的控件 `PostMessageW` 一条对应的鼠标消息（双击那颗用
 * `WM_(L|R)BUTTONDBLCLK`，滚轮用 `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL`），同一个
 * `WH_GETMESSAGE` 钩子看得见它，`DefWindowProc` 也照常处理；lParam 两个空间按文档分开——
 * 非滚轮是收件控件自己的客户区，滚轮是屏幕坐标，投出去之前换一次，钩子读回来时换回来。
 * 按下和双击在这边同样要配一颗抬起，但配的是 `BN_CLICKED`：按钮给父窗口发那条通知的
 * 一步在 `WM_*BUTTONUP` 上，少了它 `uiButtonOnClicked` 这条 Click 在测试里永远不出现。
 * 命中测试的理由和上面两条一样：摆错了就命不中，返回值当场报回去。Windows 的投递是
 * 异步的，调用返回时钩子必然还一口都没咬，"有没有被监听认领"在那边比不出结果，所以
 * 那边没有这一比（将来 mac 半补上时才需要它：事件被别的进程窗口挡住要被报成 -1，
 * 不是假绿成"已送达"）。
 * 返回 0 = 已送达；-1 = 标题编码失败、原生造不出事件、或者 PostMessage 失败，
 * -2 = 找不到窗口，-3 = 命不中子控件，-4 = 命中的不是我们的控件
 * （含落在空白处），-5 = kind 或 button 不在这套编码里、或者滚轮两轴同时非 0，什么都没发生。
 *
 * 钉不住的三条，都记在这里而不是等下一个人重新发现：①"真手指往下推到底是不是正"；
 * ②自然滚动旗标为 1 的那一支——本机读到的是 0（系统设置里自然滚动关着），于是
 * "反向给数"和"读回时取反"两步都是空操作，往返断言在两种旗标下都成立，但只有开着那一档
 * 的机器才真能钉住它。改这两支之前先想想有没有一台旗标为 1 的机器在跑这条测试。
 * ③Windows 那一侧滚轮的**量级**：mac 的事件带得动任意整数像素（逐行换算不过去就走
 * 像素单位），往返能把请求里那个数原样读回来；Windows 的原生单位是 `WHEEL_DELTA` 的格，
 * 一格等于多少逻辑像素取决于三个测试侧问不到的数（一格几行、消息字体的行高、这只窗口的
 * dpi），四舍五入之后几乎不可能正好还原请求值，所以那边的 Scroll 用例只钉方向和
 * "这一格走没走"。量级那一半归 `T53` 那台机器——改换算之前先在那边看一眼实际读数。 */
int moonui_native_send_mouse_in_window(const char *title, int title_len,
                                int kind_button, int x, int y, int dx, int dy);

/* 等价于"用户在 ms 毫秒之后按下了下一个对话框里的第 index 个按钮"（0 起算）。
 *
 * 上一条是必须的而不是偷懒：§24 的对话框是同步阻塞的（`Backend::confirm` 要当场
 * 返回用户的选择），真窗口测试若不在调用之前把"用户会按哪个"安排好，调用方就永远
 * 回不来。装好之后由对话框自己认领（一次性的：认领它的同时把装好的参数清空），
 * mac 在 NSAlert 的 runModal 之前往当前 runloop 的 NSModalPanelRunLoopMode 里挂
 * 一只 NSTimer，Windows 起一条 helper 线程等 `#32770` 出现再按控件 ID 点它。
 * 点的是真按钮（`performClick:` / `BM_CLICK`），于是回答来自原生对话框自己的
 * modal session，不是脚手架直接改返回值——和 click_button_in_window 同一个理由。
 *
 * 只有两种按钮形态可点：`message` 一只（index 只能是 0），`confirm` 两只
 * （0 = 是，1 = 否）。越界的 index 在这里就报回去，不许留到运行时"什么也没按下"
 * ——那是一条挂住的测试，而不是一条红的。
 * 返回 0 = 已装好（下一个对话框会认领它）；-1 = index 越界。
 * 要是装好之后一直没有对话框来认领，这发就留在进程里，下一个对话框会被它按掉。 */
int moonui_native_auto_dismiss_dialog(int ms, int index);

/* 等价于"用户在 ms 毫秒之后点了上下文菜单的第 index 项"（0 起算；-1 = 点空白
 * 把它关掉）。上下文菜单的展示同样是同步阻塞的（`popUpMenuPositioningItem:` /
 * `TrackPopupMenuEx` 的 TPM_RETURNCMD），不先安排"用户选哪个"，调用方就永远
 * 回不来——和上面那条对话框替按是同一个形状。
 *
 * mac 把定时器挂进 `NSEventTrackingRunLoopMode`（菜单追踪循环就跑在那档；只挂
 * 默认档的定时器在追踪期间永远不 fire），到点对**正在追踪的那只 NSMenu** 调
 * `performActionForItemAtIndex:`（走 item 自己的 target/action → Core 的菜单
 * 语义），再 `cancelTracking` 结束循环。装好之后由下一个上下文菜单认领（一次
 * 性的：认领时把参数清空）。index 越界时只 cancel、不派发——写错的脚手架红在
 * "没收到回调"的断言上，不变成一条挂住的测试。
 * Windows 半的等价物随 `T91①` 的 Win 侧一起补（TPM_RETURNCMD + 一条按坐标
 * 发的鼠标消息）。
 * 返回 0 = 已装好；-1 = index 小于 -1（写下不存在的值）。 */
int moonui_native_auto_pick_context_menu(int ms, int index);

/* 等价于"用户在 ms 毫秒之后对下一个文件面板按 接受 / 取消，并且面板已经停在
 * path 上"。和上一条是同一个问题的两个形状：文件面板也是同步阻塞的（§24 的
 * open_file 要当场给路径），不先安排"用户怎么答"就永远不会返回。
 *
 * 差别只在选项：对话框的选项是"第几只按钮"，文件面板的选项是"接受还是取消 +
 * 接受时面板停在哪条路径上"。路径必须由脚手架给——真面板的当前位置是"用户上次
 * 去过哪"的进程全局状态，测试里不可复现。按下的必须是真按钮（Windows 是导航到
 * path 再点 IDOK，走的是 IFileDialog::SetFileName 的全路径形态），返回的路径
 * 也必须是原生对话框自己的答案（GetResult），不是脚手架编的——和
 * click_button_in_window 同一条理由。
 *
 * 接受这一支在 mac 上做不到，当场报 -2：macOS 15.6 的打开 / 保存面板跑在系统 XPC
 * 服务里（com.apple.appkit.xpc.openAndSavePanelService），放行 OK 的代码长在服务
 * 进程里，客户端这侧 [panel ok:] 是个桩（AppKit 自己的日志 "-[NSSavePanel ok:] :
 * not implemented"，抛 NSGenericException）；兜底的 cancel: / stopModalWithCode: /
 * endSheet:returnCode: 能把 modal 结束但拿回来 [panel URL] 是 nil——选中的东西只活
 * 在服务里，只有服务自己结束会话才送得回客户端；合成按键也到不了服务进程。真人在
 * 真 App 里按 OK 的产品路径不受影响，死的只有"自动化替按"这一条（证据是
 * 2026-10-09 一串带看门狗的探针，结论抄在 TODO 的 T21 那行）。
 *
 * accept = 0（取消）时 path 允许为空；accept 非 0 时 path 为空一律在装的那一步报
 * -1——面板停在哪儿都不知道的"接受"不可复现，与"越界的按钮 index"同一条规矩：写错
 * 的脚手架要红在断言上，不要变成一条挂住的测试。ms 为负按 0 算。
 * 返回 0 = 已装好（下一个文件面板认领它）；-1 = 接受但 path 为空；
 * -2 = 本平台不支持替按接受（当前只有 mac）。和上一条一样：一直没面板来认领就留在
 * 进程里，下一个面板会被它答掉。 */
int moonui_native_auto_answer_file_dialog(int ms, const char *path, int path_len,
                                   int accept);

/* 等价于"用户在原生菜单里点了 id 这一项"：mac 走 `performActionForItemAtIndex:`，
 * Windows 给目标窗口 `SendMessageW` 一条 `WM_COMMAND`（`lParam=0`、`HIWORD(wParam)=0`，
 * 也就是菜单自己发上来的那个形状）。选 SendMessage 而不是 PostMessage 是因为下面那条
 * "回调在本次调用里已经跑过"：投递的那一条要等下一次循环才醒，脚手架就没法当场报这句。
 * 于是原生派发、点击回调、`MenuSelect` 事件、handler 改完勾选态再推回原生这一整条链路
 * 是被真窗口跑过的，不是 mock 出来的——和 `moonui_click_button_in_window` 同一条理由。
 *
 * 禁用项必须不派发，而两边原来的位置不一样：mac 的 `performActionForItemAtIndex:`
 * 自己就尊重 `isEnabled`，Windows 这条消息却绕过置灰直接进窗口过程。所以 Windows 那份
 * 在发之前先查条目自己的 `MF_GRAYED`/`MF_DISABLED` 位，命中禁用就报 -2、什么都不发——
 * 两边报回同一套码，测试钉住的才是同一件事。
 * 返回 0 = 已派发（回调在本次调用里已经跑过），-1 = 当下这棵菜单里没有这个 id，
 * -2 = 有这一项但它是禁用的、什么都没发生。Windows 那边还有第三种 -1：没有活窗口也就没
 * 有地方可问，和"没这一项"是同一条返回值，所以那边的测试要先开着窗口再问 -1。 */
int moonui_native_menu_click_item(int id);

/* 原生菜单当下的快照，用来验证"Core 那棵树"和"装进系统的那棵树"是同一份东西。
 * 五个 getter（顶层标题、某项的文案/勾选/可用/在不在）在这里塌成一根文本，是因为要验的
 * 本来就是整棵树的形状：逐个问既放不下子菜单的嵌套，也要两份 C 各维护五条形状相同的
 * 入口。格式两边必须一模一样（这根文本就是给两个平台对拍用的），而且只被测试断言、
 * 永远不解析回去：
 *   顶层菜单之间用 ";" 相连，每个顶层 = label{条目,条目,…}
 *   条目：分隔线 = "-"
 *         可点项 = "#<id>:<role><check><enabled>:<label>:<sc>"
 *                  role = n/c/r（Normal/Check/Radio）；
 *                  check = "+" 勾着、"-" 没勾（只对 c/r），n 恒为 "."；
 *                  enabled = e/d；
 *                  sc = 这一项当下携带的组合，"." 表示没有，否则是修饰键字母
 *                       （固定顺序 C=ctrl、A=alt、S=shift、M=meta，一个都没有时
 *                       写 "-"）紧跟键名：字母小写、数字原样，键名一律用 Core
 *                       自己那套词（event.mbt）——空格/回车/Tab/Esc/退格 分别写
 *                       `Space`/`Enter`/`Tab`/`Escape`/`Backspace`，其余键原样。
 *                       这一栏读的是**原生项自己的状态**（mac 的 keyEquivalent +
 *                       keyEquivalentModifierMask，Windows 标题里 \t 之后那段），
 *                       所以它证明的是"组合真的落到了菜单项上"。上面那条 mac 不认
 *                       功能键的分叉在这里看得见：同一个 `Shortcut::new("F5")`，
 *                       mac 报 "."，Windows 报 "-F5"——测试因此只用两边都认的组合。
 *         子菜单 = "+<label>{…}"，里面递归用同一套
 * label 原样照抄，所以测试里的标签不许含 ";"、"{"、"}"、","、":"、"-" 打头这些
 * 结构字符（这根快照只给人和测试读，产品路径没有人解析它；Windows 为了填 `<sc>`
 * 会把自己标题里 \t 之后那段拆出来，那属于脚手架）。
 *
 * 两边都从**真正挂在系统上的那棵**读，而不是从自己记的那份名单读：mac 走
 * `[NSApp mainMenu]`、按"是不是我们追加的那几顶"筛（`uiInit` 建的应用菜单在索引 0，
 * 不属于 §25 那棵树，所以这里不数索引），Windows 走活窗口的 `GetMenu`。理由是这根
 * 快照要钉的正是"装上了"：只抄名单的话，`addItem:` / `SetMenu` 那一步整段删掉也能绿。
 * Windows 因此没有活窗口时读不出东西，报空——那边的测试会开一只真窗口，顺带把
 * "菜单位挤出来的那一行高有没有补回去"一起量了（见 `moonui_set_menu_bar` 那段）。
 * 只覆盖我们自己那部分；没装过菜单时返回空 bytes。 */
moonbit_bytes_t moonui_native_menu_dump(void);

/* 等价于"用户在键盘上按了（或抬起了）一颗键"。
 *
 * Windows 往当下有焦点的那个控件 PostMessage 一条 WM_KEYDOWN/WM_KEYUP，消息要等
 * 事件循环取出来时才触发 WH_GETMESSAGE 那份 hook——和真键盘同一条路，不是"把回调
 * 调一遍"。mac 造一条真 NSEvent（KeyDown/KeyUp）交给 `[NSApp sendEvent:]`——
 * 进程内监听、主菜单"收不收这组"的判断、first responder 的后续处理全被真跑一遍，
 * 而且**同步完成**（`T103` 补上，2026-10-20）。mac 的前提比 Windows 多一条：窗口
 * 得是 key、焦点得落在我们的控件上（监听按 `[NSApp keyWindow]` 的 firstResponder
 * 解析归属），前置不满足时如实报 -3，不造一条"归窗口自己"的假绿事件。
 *
 * 归属靠的是焦点而不是坐标，所以调用方要先让焦点落在想按的那个控件上（下一条脚手架
 * 干这件事）；没落上时事件照样产，只是 target 变成窗口自己，测试里那就是一条假绿。
 * key/mods 用键盘那一节的词表和编码；down 非 0 = 按下，0 = 抬起。
 * 返回 0 = 已派发，-1 = 编码失败，-2 = 找不到窗口，-3 = 这只窗口里没有我们的控件
 * 拿着焦点，-4 = 键不在词表里。跑回调要等下一次取消息，测试先 step 再断言。 */
int moonui_native_send_key_in_window(const char *title, int title_len,
                              const char *key, int key_len, int mods, int down);

/* 等价于"用户把焦点挪到客户区 (x, y) 处那个控件上"（两平台都有实现；mac 半由
 * `T103` 补上，走 makeFirstResponder:，判据同样用回读）。
 *
 * Windows 是对命中的 HWND 调 SetFocus。按坐标而不是"取第几只控件"，理由和
 * click_button_in_window 一样：布局摆错了这里就命不中。
 * 为什么不开"按一次 Tab"的脚手架：Tab 的落点是 z-order 里的下一个，而 §14 的 z-order
 * 就是 Tab 顺序——那要合成 VK_TAB，得先让进程拿到前台，而前台归属是这台机器的用户
 * 状态，量出来的落点跟着激活时序漂（上面那条"这里没有量 Tab 的脚手架"说的就是它）。
 * 返回 0 = 焦点已给出去，-1 = 编码失败，-2 = 找不到窗口，-3 = 命不中子控件，
 * -4 = 命中了但焦点没落到我们的控件上。判据是回读（跟 moonui_focused_control 同一个）：
 * 命中的不是我们的控件（窗口里的空白处就是这一档），或者原生答应了却没给——本机实测
 * label 的 makeFirstResponder: 返回 YES，而 firstResponder 顺着 responder chain 落回窗口
 * 自己。两边同一套码：mac 原来那条"是我们的控件但拿不了焦点"的 -5 删了，因为回读分不出
 * "命中的不是我们的控件"和"是我们的控件却没拿到"，Windows 的禁用控件也是同一档。
 * Windows 那一边"点在客户区的空白处"能不能落到 -4 还有一层没定：命中的很可能是那只列自己
 * 的 container 窗口，而列是 Core 创建的控件、HWND 上打过标记，于是往上退那一步当场就命中，
 * 返回值改由"容器 HWND 能不能拿焦点"说了算——那句不在文档里，归 TODO `T46` 量（mac 的空白处
 * 是实测 -4）。 */
int moonui_native_focus_widget_in_window(const char *title, int title_len, int x,
                                  int y);

/* 等价于"用户把文件拖进窗口客户区然后松手"（`T91③`）。**只 mac 有**：Windows
 * 半的 IDropTarget 整条还缺席（`T91` 的 Win 侧账），没有可替的东西。
 *
 * 真拖一次要有人按住鼠标从 Finder 拖进来，自动化做不到；这条替投的是"松手那一
 * 刻"：造一只真的唯一名 NSPasteboard、写进 file URL 对象，再走 destination 自己
 * 用的打包/通知路（`performDragOperation:` 只比它多一步取 pasteboard）。于是
 * "路径 → UTF-8 → i32 打包 → MoonBit 侧 unpack"的往返是真的被跑过的，不是把
 * 回调调一遍。`paths` 以 '\n' 分隔（测试自己的编码——路径里没有换行）。
 * 返回 0 = 已投递（监听没装时静默不产事件，与产品路径一致）；-1 = 没有路径或
 * 编码不了；-2 = 找不到窗口。 */
int moonui_native_simulate_file_drop(const char *title, int title_len,
                              const char *paths, int paths_len);

/* 拖入这条链的三个事实（`T91③` 的判据，位打包）：
 * 低 3 位 = bit0 监听装着（destination 的接受门）、bit1 窗口登记了 file URL 这一
 * 档拖入类型、bit2 上一次替投真被接住；-2 = 找不到窗口。 */
int64_t moonui_native_file_drop_probe(const char *title, int title_len);

/* "拖到这个点上，这次拖拽由谁接？"（`T91③` 的 field editor 拦截边界）：
 * 1 = 命中的是编辑中的 field editor（NSTextView 自己就是 NSDraggingDestination，
 * AppKit 在它那一层就停住了，窗口的 destination 不会被叫）；0 = 命中的是我们的
 * 非文本控件或窗口本体（递退到窗口这一层）；-2 = 找不到窗口，-3 = 点在客户区外。
 * 这条只回答"谁接"，不模拟拖拽本身——真机的光标形状与接受动画仍要人眼。 */
int moonui_native_drag_hit_probe(const char *title, int title_len, int x, int y);

/* 测试探针（`T65` 的登记表推路）：按标题找回那只窗口，读回它的 WM_SETICON 图标、
 * 和已装的那两只比指针。1 = 推到了；0 = 没装过或没推到这只窗口（类图标的兜底
 * 不会误报，比对的是 HICON 原值）；-2 = 找不到窗口。**只 Windows 有**：mac 的图标
 * 挂在 NSApp 上、没有逐窗口的对应物（§26），macos_test 那侧不引用它。 */
int moonui_native_window_icon_installed(const char *title, int title_len);

/* "这只图像控件里真装着一张图吗、那张图多大"（`T91⑤` 的判据）。
 *
 * `image_set_path` / `image_set_data` 的返回码只说明"装上了"，装进去的是不是真位图、
 * 像素尺寸对不对，得问原生控件自己：mac 读 NSImageView.image 的各 rep 的
 * pixelsWide/pixelsHigh（取最大那份，走 init 的多帧图也一样）；Windows 半要在
 * `T91⑤` 的 Win 侧一起补（读 STM_GETIMAGE 的那只 HBITMAP，GetObject 拿尺寸）。
 * 打包成 i64 的三段（与 pack2 的邻居同一套挤法，避免为一条测试探针新增 out 参数）：
 * 低 8 位 = 有没有图（0/1），8..23 位 = 像素宽，24..39 位 = 像素高。
 * -1 = 句柄不指图像控件（kind 记号不是 16）。 */
int64_t moonui_native_image_probe(moonui_ptr c);

/* 托盘当下长什么样（`T91⑥` 的判据）：位打包，低 8 位是三个存在位
 * （bit0 = NSStatusItem 建起来了、bit1 = 图标真装在按钮上、bit2 = 菜单真挂上去了），
 * 8..23 位 = 顶层菜单项数（没挂菜单时 0）。
 * 托盘是进程级单例，不进句柄表，所以这里没有入参；没初始化时返回 0。
 * 只覆盖 mac 半——Windows 的 NIF_ 读回要在 `T91⑥` 的 Win 侧一起补（Shell_NotifyIcon
 * 没有"读回来"的口子，得靠自己的 NOTIFYICONDATAW 副本，欠账同批）。 */
int64_t moonui_native_tray_probe(void);

/* Core 声明的焦点链（§48-16 的 `T29` 第二格，`T66`）：整份替换，一次一整棵树。
 * `ids` 是空格分隔的十进制 owner 指针（MoonBit 的 FFI 过不来数组，文本序列化，
 * 菜单树同一招）；空串 = 清空这只窗口的链。之后这只窗口的 Tab 遍历按链走
 * （Shift 反向、链尾回链头），不再跟 z-order——含 Stack 的树里两者分道。
 * 事件流不动：Core 照旧在按下那一刻的持有者身上看到 KeyDown/KeyUp。
 * 返回 0 = 收下，-1 = 窗口不真（Windows：不在登记表；mac：换不出 NSWindow），
 * -2 = 链里有 owner 换不出控件（mac 侧独有，整份丢弃不半推），-3 = 文本解析失败。
 * 两侧的接线法各按平台：Windows 在键盘钩子里拦 VK_TAB 按链 SetFocus；mac 把
 * 声明序装进每只 view 的 nextKeyView 接成环（关掉 autorecalc 让它不被 AppKit
 * 重算盖掉），空串在 Windows 清回 z-order 序、在 mac 交还 autorecalc。 */
int moonui_native_set_focus_chain(moonui_ptr window, const char *ids, int ids_len);

/* ---- worker 与跨线程投递（`T85①`，§27 / §47 风险 3）----
 *
 * §27 的任务队列住在 MoonBit 侧（Core 的 `App.posted`），只被 UI 线程碰；跨线程
 * 的收口是**这条 ABI**：worker 线程跑完任务闭包后，C 把落地闭包投回主线程，主
 * 循环泵消息时（Win32 的 WM_APP 由 GetMessage/PeekMessage 取出、Cocoa 的主队列
 * block 由 nextEventMatchingMask 的 runloop 泵运走）落地回调在 **UI 线程**执行——
 * 落地动作是 MoonBit 侧的 `app.post(...)`，于是外来投递经投递原语变成了 UI 线程
 * 投递，队列依旧无锁（§47 风险 3 的记账：不加锁，靠投递原语收口）。
 *
 * worker 为什么不是 MoonBit 侧一条（`T18` 的形状判据）：MoonBit 侧没有线程 API，
 * native 运行时也没有跨线程形态的文档承诺——所以 worker 是平台线程（mac 半
 * pthread_create 一小段、Win32 半 CreateThread 一小段，两份 C 同形各一遍），线程
 * 起不来时零分叉地失败。跨线程调用 MoonBit 闭包走 FuncRef+closure trampoline
 * （tests/ffi 的 store_callback 那套 incref 看守），"闭包跨线程回来仍是活体"与
 * "跨线程 decref"都由 2026-10-15 的 pthread 探针在本工具链（moon 0.1.20261012）
 * 上钉过；引用回收统一在接收侧（worker 只 decref work 闭包自己那份），不新增
 * 并发回收形态。
 *
 * 两支闭包的契约：
 *   - work 闭包在 worker 线程执行，**不许 raise**（异常跨 C 帧未定义——控件回调
 *     那几条同一条纪律），worker 侧失败由调用方在闭包内部兜住；
 *   - land 闭包在 UI 线程执行，同样不许 raise，它的职责只是落地（MoonBit 侧把
 *     `land` 排进 §27 的任务队列，任务本体失败仍走既有语义——run_posted 的 raise
 *     结束循环），不许在原生回调栈里直接碰控件树；
 *   - work 必须返回（不返回 = 线程与两份引用一起泄漏），一次投递一次线程。
 * 返回 0 = 线程起了（落地一定会发生或进程退出）；-1 = 参数残缺或线程起不来，
 * 什么都没发生。 */
int moonui_native_worker_run(moonui_closure_fn work_call, void *work_closure,
                      moonui_closure_fn land_call, void *land_closure);

/* ---- 输入法组合事件源（`T85②`，§32 的组合相位通知）----
 *
 * 形状沿进程级键盘监听那套：**监听进程一份**（组合相位一次只属于焦点所在的
 * 一只文本控件，按控件乘槽位没有收益），通知不带内容，相位/target/组合串三样
 * 当场读回——快照在调闭包之前写好、闭包返回之后没人再动，一次通知配一次读。
 *
 * 相位编码：0 = 组合开始、1 = 组合进行、2 = 组合结束。开始通知**不带组合串**
 * （与 Win32 的 WM_IME_STARTCOMPOSITION 对齐——它同样不带内容；mac 半从标记串
 * 从无到有的切换沿推这条，串跟在同一条序列的下一条通知上）；进行通知携带当下
 * 的组合串（mac 半是 field editor 标记串的子串，Win32 半是 WM_IME_COMPOSITION
 * 的 GCS_COMPSTR）；结束通知不带组合串（上屏的全文随既有文本变化通道走，即
 * §32 的原生红利，Core 收 `Input`）。组合中的 target 是正在组合的那只我们的
 * 文本控件，反查不到（已销毁、或焦点不在我们的控件上）报 0，MoonBit 侧据此
 * 丢弃——悬垂组合命中死控件由句柄表的 generation 自动挡住（`T49`/`T57`）。
 *
 * 平台分法见两份实现：mac 半从 field editor 的标记串（NSTextView.markedRange）
 * 从文本变更观察里推相位；Win32 半在创建文本控件时换上子类过程，把
 * WM_IME_STARTCOMPOSITION / WM_IME_COMPOSITION / WM_IME_ENDCOMPOSITION 从焦点
 * EDIT 的窗口过程里分流出来（组合消息进的是焦点窗口的过程，顶层窗口过程
 * 看不见它们）。读组合串要过 IMM 的 ImmGetCompositionStringW，链接时那侧要补
 * -limm32（`T85②` 的 Windows 真跑欠账一并挂）。 */
/* 装那份进程级组合监听。0 = 装上了（重复调用只换回调，监听还是那一份）；
 * -1 = 槽位用满。 */
int moonui_native_on_ime(moonui_closure_fn fn, void *closure);
/* 组合当下的 target：正在组合的那只我们的文本控件；反查不到报 0。 */
moonui_ptr moonui_native_ime_target(void);
/* 组合相位，见上面那套编码。 */
int moonui_native_ime_phase(void);
/* 当下的组合串，UTF-8。开始/结束通知是空 bytes，进行通知是标记串子串。 */
moonbit_bytes_t moonui_native_ime_text(void);

/* ---- 控件级右键上下文菜单（`T86①`）----
 * 与 `moonui_set_menu_bar` 共用打包/派发底座：整棵树打包成同一段字节传进来
 * （布局见菜单栏那段，一字不差），读坏报 -1、旧状态一动不动。展示在鼠标当下
 * 的位置（右键按到的那只控件上方——上下文菜单的标准位置就是按下点），展示
 * 这一步同步阻塞：mac 半 `popUpMenuPositioningItem:`、Windows 半
 * `TrackPopupMenuEx(TPM_RETURNCMD|TPM_NONOTIFY)`，用户选完或点空白才返回，
 * 所以选中的解析发生在同步嵌套循环内——点击回调按菜单栏同一个签名
 * （`moonui_closure_id_fn`）带 Core 的条目 id 报回来，勾选态的更新照 §25 的
 * 契约改在 Core（`MenuBar::click` 那一条），回调里的异常由闭包内部兜住
 * （异常跨 C 帧未定义，worker 同一条纪律）。
 * 两处与本头既有条目的刻意不同，都记在这里：①上下文菜单的选中不回流成事件
 * 队列（菜单栏的选中沿 `moonui_on_key` 那批的 Event 契约走 MenuSelect），
 * 因为它的条目不属于安装的菜单栏、MenuSelect 的按菜单栏路由接不住它们——
 * 同步解析的语义沿 T22 现账；②点击后的勾选态**不回推原生**：弹窗是一次性的，
 * 下一次展示按 Core 的新快照画（菜单栏的勾选回推走 `moonui_menu_item_set_checked`，
 * 因为它的条目常驻屏幕）。回调是进程一份的独立槽位，与菜单栏那份互不覆盖。
 * 返回码两边同一套：0 = 弹过（用户选了或点了空白关掉）；-1 = 树不合法；
 * -2 = 没有可以弹菜单的窗口（mac 连 keyWindow 都没有 / Windows 没有活窗口）。 */
int moonui_native_show_context_menu(const char *tree, int tree_len,
                            moonui_closure_id_fn fn, void *closure);

/* ---- 窗口态（`T86②`）----
 * 两条 setter 加一条读回。语义两边都是"只在差异上动"：mac 半
 * miniaturize:/zoom:、Windows 半 ShowWindow 的 SW_ 系列，它们本身是开关型
 * 动作（zoom 字面义就是 toggle），先问当下态、真的要变才调——程序重发同一条
 * 意图不让窗口抖一下。恢复那半各走各的恢复路径（deminiaturize:/SW_RESTORE），
 * "进最大化之前是什么样"由窗口系统自己记着，这层不存第二份前置状态。
 * 读回打包成位：bit0 = 最小化（mac 的 isMiniaturized、Win32 的 IsIconic）、
 * bit1 = 最大化（isZoomed/IsZoomed）。读回口径是"读当下态"而非推送式——
 * 批三的窗口持久化（`T86⑦`）要的是"存档时刻窗口是什么态"，问一次拿一份
 * 快照正合适；原生层是唯一事实来源，MoonBit 侧不缓存。Windows 半照这一批的
 * 口径只到 mingw 语法闸门，真跑欠账挂报告。 */
void moonui_native_window_set_minimized(moonui_ptr w, int minimized);
void moonui_native_window_set_maximized(moonui_ptr w, int maximized);
int moonui_native_window_state(moonui_ptr w);

/* ---- 文件拖入（`T86③` 第一期档案）----
 * 只做"外部文件拖入"这一档（形状判据"拖入文件路径事件"），控件间拖动与
 * 数据格式打包是第二期的账（`T86③` 分期）。形状沿键盘/鼠标/组合那套共同
 * 约定：监听进程一份、通知不带内容、target/paths 当场读回——快照在调闭包
 * 之前写好、闭包返回之后没人再动，一次通知配一次读。
 * mac 半是 NSDraggingDestination：窗口自己接文件 URL 的拖入（没有更深的 view
 * 认文件 URL 时拖拽递退到窗口这一层），拖进来的路径数组原样打包成一段字节：
 *   paths = i32 count, count × (i32 字节数, UTF-8 内容)（整数一律小端 i32，
 *   与菜单树同一套 "i32 长度 + 内容"）
 * Windows 半欠 IDropTarget（两份 C 的大账，挂账口径），三条入口保 ABI 完整地
 * 缺席：监听返回 -1（MoonBit 侧静默缺席、不挡开窗）、target 恒 0、路径恒空。
 * DragAcceptFiles/WM_DROPFILES 那条便宜的路径要不要顶上，随 IDropTarget 的账
 * 一起定（欠账挂报告）。
 * 已知边界记在这里：编辑中的文本控件上方拖拽可能被 field editor 拦住
 * （NSTextView 自己实现了拖拽 destination），真拖验证欠账挂在 `T86③` 的
 * 报告里。 */
int moonui_native_on_file_drop(moonui_closure_fn fn, void *closure);
/* 接住拖入的那只"我们的窗口"，反查不到（另一个进程的窗口）报 0，MoonBit 侧
 * 据此丢弃整条事件。 */
moonui_ptr moonui_native_file_drop_target(void);
/* 拖入的路径数组，按上面的打包布局。空 bytes = 没有路径（反查不到 target 的
 * 那一条本来就不该产事件，这里是双保险）。 */
moonbit_bytes_t moonui_native_file_drop_paths(void);

/* ---- 图像控件与资源加载（`T86⑤`）----
 * 开工决策（记在 TODO `T86⑤`）：解码归平台（mac 半 NSImage 的两条 initWith、
 * Windows 半 WIC 解码到 HBITMAP），不走纯 MoonBit 解码器——MoonBit 侧 inflate
 * 是一整块新地基，平台解码 mac 半二十行，§15 零分叉优先在这里让位；绘制归
 * 原生 Image view（mac 半 NSImageView、Windows 半 SS_BITMAP 的 STATIC 只到
 * mingw 语法闸门），MoonBit 侧零解码、平台侧零自绘。
 * kind 编码：Image = 16，进 `moonui_widget_new` 的通用构造（构造参数只有文案，
 * 图像控件的文案恒空）。两条加载通道都是**整源替换**：后一次调用覆盖前一次，
 * 没有"清空图像源"的第三条（装空路径/空数据按解码失败报 -1）。
 * 返回码两边同一套：0 = 装上了；-1 = 解码失败（路径不存在、数据不是平台认得
 * 的编码格式，§33 的调用方错）；-2 = 句柄不指图像控件（kind 记号不是 16）。 */
int moonui_native_image_set_path(moonui_ptr c, const char *path, int path_len);
int moonui_native_image_set_data(moonui_ptr c, const char *data, int data_len);

/* ---- 系统托盘与通知（`T86⑥`）----
 * 托盘是进程级单例（一个应用一只 NSStatusItem / 一只 NOTIFYICONDATAW），不进
 * 句柄表：装一只托盘一个 MoonUI 句柄都不建，与剪贴板/对话框同一条理由。图标
 * 参数沿 `moonui_set_app_icon` 的 stem 约定（mac 半补 ".png" 画在状态条上、
 * Windows 半补 ".ico" 走 LoadImageW）。菜单沿 `moonui_set_menu_bar` 同一份
 * 打包树建（共用读游标/填充底座），可点项指向托盘自己的回调槽位（独立于
 * 菜单栏与上下文菜单那两份）：mac 半 AppKit 点击自动弹（同步阻塞）、Windows
 * 半 park 窗口收托盘回调消息的左键抬起弹（TPM_RETURNCMD）。选中的解析同
 * `moonui_show_context_menu`：同步嵌套循环内、勾选态不回推（下一次装树照新
 * 快照画），缺席的理由与那条一致。
 * 图标这条先装也行（起 NSStatusItem）、菜单这条先装也行（空图标的菜单托盘
 * 照在，图标随后补）。
 * 通知走现代的 UNUserNotificationCenter（NSUserNotification 自 10.14 起已
 * 废弃，查证记在 `T86⑥` 的报告里）。通知中心只对打进 bundle 的应用有连接：
 * 无 bundle 的进程（CLI、测试二进制）问 bundleIdentifier 就返回 -3，不做无
 * 把握的投递。授权是异步请求（第一版不等待、不挂点击动作——点击动作欠账），
 * add 那一发照投，未授权的那次失败由 completion 吞掉：投递是异步的，返回码
 * 只表达"投递请求交出去了"。Windows 半是 NIF_INFO 气球（NIM_MODIFY 的
 * szInfoTitle/szInfo，定宽就地截断），气球的载体就是托盘图标，没装过托盘报
 * -1；这半照这一批的口径只到 mingw 语法闸门。
 * 返回码两边同一套：0 = 装上了 / 投递请求交出去了；-1 = 图标读不出来 /
 * 树不合法 / 文案没能交给系统（含没托盘）；-2 = 还没初始化；-3 = 通知在这个
 * 进程形态下不可用（无 bundle）。 */
int moonui_native_tray_set_icon(const char *name, int name_len);
int moonui_native_tray_set_menu(const char *tree, int tree_len,
                        moonui_closure_id_fn fn, void *closure);
int moonui_native_notify(const char *title, int title_len, const char *body,
                 int body_len);

/* ---- 音频（lunamusic，`DESIGN.md examples/lunamusic` C-04；
 * 解码与元数据解析都归原生层，MoonBit 侧零解码——与 Image 的 T86⑤ 先例同形。
 * 一次只装一首歌：播放器是进程级单例，load 新歌即换掉旧的。
 * mac 半 2026-10-18 起是 **AVAudioEngine**（AVAudioPlayerNode → AVAudioUnitEQ
 * → mainMixerNode），因为均衡器与频谱都要挂在链路上，AVAudioPlayer 是黑盒，
 * 给不出这两样；Windows 半（Media Foundation）只有播放这一段（FP4 的档），
 * 均衡器与频谱在那侧恒为空实现（见下面那两段的注释）。
 * 返回码统一：0 = 成功；-1 = 参数残缺/没装歌；-2 = 底层调用失败
 * （文件打不开、解码不了——调用方退回文件名兜底，DESIGN.md C-10 风险 4）；
 * -3 = 本平台未实现（共享层映射 Unsupported）。 */
int     moonui_native_audio_load(const char *path, int len);
int     moonui_native_audio_play(void);
int     moonui_native_audio_pause(void);
int     moonui_native_audio_stop(void);      /* 停并卸载 */
int64_t moonui_native_audio_position_ms(void);
int64_t moonui_native_audio_duration_ms(void); /* 没装歌/读不出返 -1 */
int     moonui_native_audio_seek_ms(int64_t ms);
int     moonui_native_audio_set_volume(int permille); /* 0..1000 */
int     moonui_native_audio_is_playing(void);   /* 0/1；没装歌 0 */

/* 自然播完回调（不含手动 stop/pause）。回调投回 **UI 线程** 执行（worker 的
 * T85① 同一条投递纪律：跨线程闭包 incref/decref 配对，投递原语收口）；重复
 * 调用只换回调（旧闭包 decref）。传 fn = NULL 撤回调。返回 0 = 收下。 */
int moonui_native_audio_on_finished(moonui_closure_fn fn, void *closure);
/* 撤播完回调（等价 on_finished(NULL)——MoonBit 侧传不出 NULL 闭包，单开一条）。 */
int moonui_native_audio_clear_on_finished(void);

/* ---- 频谱与均衡器（lunamusic 第二期；Luna那两块招牌零件）----
 * 频谱：装歌播放期间，mac 半在 mainMixerNode 的输出上装一条 1024 点 tap，
 * vDSP 实数 FFT 后按对数分成 **16 段**能量（60Hz→14kHz）。`audio_level(band)`
 * 回读该段的 0..1000 千分位；band 越界、没在播都返回 0（没在播时每读衰减
 * 15%，条子自然落回）。未实现的一侧（Windows）：band_count 记 0、level 恒 0。
 *
 * 均衡器：**10 段参量滤波**，中心频率固定在 60/170/310/600/1K/3K/6K/12K/
 * 14K/16K，增益单位 **milli-dB**（±12000 = ±12dB，0 = 平直）。预设（流行/
 * 摇滚/古典…）不做在 C 里——那是一张 MoonBit 侧的表，调这些 ABI 逐段落。
 * 未实现的一侧：`eq_band_count` 返 0，set_* 返 -3，enabled 恒 0。 */
int     moonui_native_audio_level(int band);          /* 0..1000；越界/未实现 0 */
int     moonui_native_audio_eq_band_count(void);      /* 10；未实现 0 */
int     moonui_native_audio_eq_set_band(int band, int gain_mdb);
int     moonui_native_audio_eq_band_gain(int band);   /* 读回 milli-dB */
int     moonui_native_audio_eq_set_enabled(int on);   /* 0/1；旁路开关 */
int     moonui_native_audio_eq_enabled(void);         /* 0/1 */

/* 元数据探针：不装歌、不动播放器，只读文件。返回打包字节（moonbit_bytes_t，
 * GC 回收，与字符串出参同一条约定），读不出元数据返回 **空包（0 字节）**——调用方
 * 退回文件名（DESIGN.md C-10 风险 4）。打包布局（小端、字节为界，无对齐垫）：
 *   [int32 title_len ][title_len 字节 UTF-8]
 *   [int32 artist_len][artist_len 字节 UTF-8]
 *   [int32 album_len ][album_len 字节 UTF-8]
 *   [int64 duration_ms]
 *   [int32 cover_len ][cover_len 字节 PNG]（0 = 没有封面）
 * 长度全部按字节数记，字符串不补 NUL。读不出返回 **空包（0 字节）**——不许返
 * NULL：MoonBit 包装函数拿返回值直接 .length()，NULL 会在那里解引用空指针
 * 闪退（2026-10-16 选目录闪退案的修法）。mac 半走 AVAsset 的常见元数据
 * （title/artist/albumItem/artworkItem），给不了的字段长度记 0。 */
moonui_ptr moonui_native_audio_probe(const char *path, int len);

/* ---- 目录行走（lunamusic 第一期，DESIGN.md C-05 的扫描半）----
 * 列一个目录的**直接**子项（绝对路径数组，文件与子目录都给；调用方的
 * MoonBit 侧做白名单过滤与递归——C 只干 readdir 这一件真阻塞的事）。
 * 打包布局（小端、字节为界）：
 *   [int32 count] 后跟 count 个 [int32 len][len 字节 UTF-8 绝对路径]
 * 出参是 moonbit_bytes_t（GC 回收，与字符串出参同一条约定）；打不开的目录
 * 返回**空包（0 字节）**（调用方当空目录处理——扫描逐项隔离失败，不阻塞，
 * C-10 风险 4）。不许返 NULL：MoonBit 包装函数拿返回值直接 .length()，NULL
 * 会在那里解引用空指针闪退（2026-10-16 选目录闪退案的修法）。
 * 为什么住在 adapter 而不是应用的 native-stub：仓库唯一的 C 编译通道就是
 * prebuild 的两份平台 adapter（T82 起没有第二个 C 编译形态）；这项不是 GUI
 * 能力，但与音频同一批落地、同一套打包/回收约定。Windows 半 FP4 前恒 NULL。 */
moonui_ptr moonui_native_walk_dir(const char *path, int len);

#ifdef __cplusplus
}
#endif

#endif /* MOONUI_NATIVE_ADAPTER_H */
