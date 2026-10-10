/* MoonUI 的 libui-ng C Adapter（设计文档 §5、§20，开发顺序 §48 第 03/09/10 步）。
 *
 * 这一层之上只有 MoonBit，之下只有 libui-ng：libui 的类型、宏、HWND 一个都不
 * 许漏进 adapter.h。换后端时 MoonBit 侧只认这套 moonui_* 名字，这就是 §5 里
 * "隐藏第三方 API / 统一 ABI / 统一生命周期" 的具体形状。
 *
 * 实现按平台分家，目录名对称：../libui-windows/adapter.c 是 Win32 那份，
 * ../libui-macos/adapter_macos.m 是 Cocoa 那份，将来 unix（GTK3）那半叫
 * ../libui-linux/。每个目录各 include 本文件、各带自己那套链接配置；本目录只有
 * 声明加共享的 ffi.mbt/backend.mbt，既没有 C 也没有 link，所以换平台不动 MoonBit。
 *
 * ABI 约定（§29）：
 *   - 指针一律 uintptr_t 进出，0 = 没有这个东西；
 *   - 进 C 的字符串是 (UTF-8 指针, 字节数) 两个参数——MoonBit 的 Bytes 不保证
 *     以 NUL 结尾，所以 C 侧自己复制一份再交给 libui；
 *   - 出 C 的字符串是 moonbit_bytes_t，由 GC 回收，MoonBit 侧不需要 free；
 *   - 一次要回两个整数（尺寸、位置）时打包成一个 int64：高 32 位放前一个、
 *     低 32 位放后一个。MoonBit 侧用算术移位拆，负数符号能正确还原。
 * 单位约定：这一层只讲物理像素。逻辑像素的换算全部集中在 MoonBit 的 `Scale`
 * 里（§30 "只允许这一处换算"），所以 C 侧不做任何 DPI 数学，只报 DPI 值。
 * 句柄的 id + generation 账本在 MoonBit 的 HandleTable 里（§6/§7），C 侧不另开
 * 一份，因此 C 侧调用必须按"先 child 后 window"的顺序被使用——这条约束由
 * Backend 实现来保证，不在这里做第二套防御。
 */
#ifndef MOONUI_LIBUI_ADAPTER_H
#define MOONUI_LIBUI_ADAPTER_H

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

/* 初始化。成功返回 0；失败返回非 0，原因用 moonui_last_error() 取。
 * libui 的初始化是进程级的，所以这一对是幂等的单例：重复 init 直接返回成功，
 * 没初始化过的 terminate 是空操作。 */
int moonui_init(void);

/* 失败原因（UTF-8）。成功之后调用返回空 bytes。 */
moonbit_bytes_t moonui_last_error(void);

/* 收尾。注销所有还在 C 侧持有的闭包，然后释放 GUI 库的全局状态。
 * 前提是所有控件和窗口已经销毁干净——libui 在退出时审计自己的分配表，
 * 发现泄漏就直接 DebugBreak。 */
void moonui_terminate(void);

/* ---- 窗口（§12）---- */
/* 宽高是窗口客户区的物理像素（libui 的 uiNewWindow 就是这个语义）。 */
moonui_ptr moonui_window_new(const char *title, int title_len, int width,
                             int height);
void moonui_window_show(moonui_ptr w);
void moonui_window_hide(moonui_ptr w);
/* 销毁窗口。§14 的布局在 MoonUI 这一侧，窗口不持有 child 的所有权，
 * 所以 child 必须已经全部销毁——DestroyWindow 会连带销毁还挂着的子窗口，
 * 之后再 destroy 一次就是野句柄。 */
void moonui_window_destroy(moonui_ptr w);

void moonui_window_set_title(moonui_ptr w, const char *title, int title_len);
/* 客户区尺寸，物理像素。libui 自己会算回外层窗口尺寸。 */
void moonui_window_set_content_size(moonui_ptr w, int width, int height);
/* 打包 (width, height)。 */
int64_t moonui_window_content_size(moonui_ptr w);
/* 窗口外层左上角，屏幕物理像素坐标（Win32 的语义，不是客户区）。 */
void moonui_window_set_position(moonui_ptr w, int x, int y);
/* 打包 (x, y)。 */
int64_t moonui_window_position(moonui_ptr w);
void moonui_window_set_resizable(moonui_ptr w, int resizable);
void moonui_window_set_fullscreen(moonui_ptr w, int fullscreen);

/* 窗口当下的 DPI（96 = 100%）。取不到（系统太老）时返回 96，不返回 0：
 * 0 会让 MoonBit 侧的换算变成无穷大。 */
int moonui_window_dpi(moonui_ptr w);
/* 进程级 DPI，只在窗口还没建出来时给 screen_size 当换算基准。 */
int moonui_system_dpi(void);
/* 主屏工作区（不含任务栏），打包 (width, height)，物理像素。 */
int64_t moonui_screen_work_area(void);
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
int64_t moonui_window_screen_origin(moonui_ptr w);
int64_t moonui_window_screen_size(moonui_ptr w);
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
int moonui_system_theme(void);

/* 注册"用户点关闭按钮"回调。成功返回 0，槽位用满返回 -1。
 * 回调只做一件事：把 Close 事件放进队列。返回给 libui 的一律是 0，也就是
 * 否决 libui 自己销毁窗口的路径——销毁顺序由 Core 决定（先内容树后窗口），
 * libui 的默认行为是先拆窗口，那会让 Core 读到已经没了的原生对象。 */
int moonui_window_on_closing(moonui_ptr w, moonui_closure_fn fn, void *closure);
/* 注册"客户区尺寸变了"回调（同上，返回 0 表示装上了）。
 * libui 在程序化 SetContentSize 时不会触发它，所以 Core 自己发起的改尺寸
 * 不会回声成一条 Resize 事件。 */
int moonui_window_on_resized(moonui_ptr w, moonui_closure_fn fn, void *closure);

/* ---- 控件（§13）----
 * kind：0=Label 1=Button 2=TextInput 3=Checkbox。Row/Column 这类纯布局节点
 * 不会走到这里（§14）。返回 0 表示这个 kind 不支持或分配失败。 */
moonui_ptr moonui_widget_new(int kind, const char *text, int text_len);
/* 销毁控件，并松开 C 侧替它看守的所有闭包。必须在所属窗口销毁之前调用。 */
void moonui_widget_destroy(moonui_ptr c);

/* 文案读写。四种控件在 Win32 里都是窗口文本（libui 自己的 getter 也只是
 * SendMessage(WM_GETTEXT)），所以这里统一走 Win32：一套代码覆盖四种控件，
 * 也不用替 libui 的 uiFreeText 记账。 */
void moonui_widget_set_text(moonui_ptr c, const char *text, int text_len);
moonbit_bytes_t moonui_widget_text(moonui_ptr c);

/* 勾选态。只有 Checkbox 有意义，Core 侧已经按 kind 拦住别的控件。 */
void moonui_widget_set_checked(moonui_ptr c, int checked);
int moonui_widget_checked(moonui_ptr c);

/* 可见/可用：直接 ShowWindow / EnableWindow。不走 uiControlShow 那条，
 * 因为 libui 那两个入口是按"控件在自己的容器树里"设计的，而 §14 的控件
 * 是 MoonUI 自己挂的，libui 的 visible/enabled 记账在这里是多余的第二套状态。 */
void moonui_widget_set_visible(moonui_ptr c, int visible);
int moonui_widget_visible(moonui_ptr c);
void moonui_widget_set_enabled(moonui_ptr c, int enabled);
int moonui_widget_enabled(moonui_ptr c);

/* 固有尺寸，打包 (width, height)，物理像素。
 * 取的是 libui 自己的最小尺寸（label 用文本 extent、button 用
 * BCM_GETIDEALSIZE 否则回落 DLU 换算），不是这里重新量一遍——自己量迟早
 * 和原生控件的真实外观分叉（§18 "字体度量属于原生层"）。 */
int64_t moonui_widget_minimum_size(moonui_ptr c);
/* 控件所属窗口的 DPI；还没挂进窗口时退回进程 DPI。 */
int moonui_widget_dpi(moonui_ptr c);
/* 相对父窗口客户区的左上角，打包 (x, y)，物理像素。 */
int64_t moonui_widget_origin(moonui_ptr c);
/* 控件外框尺寸，打包 (width, height)，物理像素。 */
int64_t moonui_widget_size(moonui_ptr c);

/* 注册点击回调（只有 Button 会真的收到 BN_CLICKED）。成功返回 0，槽满 -1。
 * C 侧会 incref closure，所以 MoonBit 不必再替它看守生命周期。 */
int moonui_widget_on_clicked(moonui_ptr c, moonui_closure_fn fn, void *closure);

/* 注册"输入框里的字变了"（只有 TextInput 会真的收到）。签名与 on_clicked 完全
 * 一致，包括"回调不带文字"这一点：文字由 MoonBit 回读 moonui_widget_text，C 侧只
 * 报"出事了"——libui 的 f(uiEntry*, void*) 里那个 sender 因此被 trampoline 丢掉。
 * 程序化 set_text 不该回声成一条 Input：Win32 那份 libui 自己用 inhibitChanged 挡
 * 住了（windows/entry.cpp:68,75），darwin 那份靠 setStringValue: 不发
 * controlTextDidChange: ——mac 那半两边都由测试钉住（macos_test 的"真打字进 Input"
 * 把脚手架换成 setStringValue: 就红）。 */
int moonui_widget_on_text_changed(moonui_ptr c, moonui_closure_fn fn,
                                  void *closure);

/* 注册"勾选框被点了"（只有 Checkbox 会真的收到；报的是"被点了一下"，勾选态由
 * MoonBit 读 moonui_widget_checked，和文字那条同一个理由）。 */
int moonui_widget_on_toggled(moonui_ptr c, moonui_closure_fn fn,
                             void *closure);

/* ---- 控件摆放（§14）----
 * attach 只负责"挂进窗口"：把 HWND 搬到目标窗口，分配控件 ID，插到 z-order
 * 末尾（z-order 就是 Tab 顺序，所以插入顺序 = 焦点顺序）。矩形由
 * moonui_control_set_bounds 单独给——Core 的调用顺序就是先 attach 再布局。 */
void moonui_control_attach(moonui_ptr window, moonui_ptr child);
/* x/y 是窗口客户区坐标，单位物理像素。z-order 不动：否则每次 resize 都会
 * 把控件重新排一遍，Tab 顺序跟着布局抖动。 */
void moonui_control_set_bounds(moonui_ptr child, int x, int y, int width,
                               int height);
/* 摘下来：挂到一个自建的隐藏窗口上，控件因此不再显示，消息也进不了任何
 * libui 窗口的方法（WM_COMMAND 是发给父窗口的）。ID 清零，重新 attach 时
 * 会重新分配并插到 z-order 末尾。 */
void moonui_control_detach(moonui_ptr child);
/* 提到父窗口子窗口列表的最上层（§14 的 Stack：数组靠后的画在上层）。
 * SetWindowPos 会连带重排 Tab 链——原生层只有一份顺序，层叠和焦点是同一个东西，
 * 所以"既要视觉顺序又要声明顺序"在这里做不到，只能由 Core 选一头（见 raise_widget）。 */
void moonui_control_raise(moonui_ptr child);
/* 控件在父窗口子窗口列表里的位置，0 = 最上层（和 EnumChildWindows 的返回顺序
 * 同向）。不在任何父窗口的子列表里时返回 -1。测试断言层叠用。 */
int moonui_control_z_index(moonui_ptr child);

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
moonbit_bytes_t moonui_clipboard_text(void);
int moonui_clipboard_set_text(const char *text, int text_len);

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
int moonui_dialog_message(const char *title, int title_len, const char *text,
                          int text_len);
int moonui_dialog_confirm(const char *title, int title_len, const char *text,
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
int moonui_open_file(const char *title, int title_len);
int moonui_save_file(const char *title, int title_len, const char *default_name,
                     int default_name_len);
int moonui_select_folder(const char *title, int title_len);
moonbit_bytes_t moonui_file_dialog_path(void);

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
int moonui_set_menu_bar(const char *tree, int tree_len, moonui_closure_id_fn fn,
                        void *closure);

/* 把 Core 改掉的勾选态推给当下那棵原生菜单。§25 里 Checkbox/Radio 的状态只存在
 * Core——libui 那侧没有可靠的读回接口，"同组互斥"又是 Core 的规则——所以后端不可能
 * 自己发现该显示什么，只能由 Core 在点击之后逐项推过去
 * （`App::click_menu_item` → `Backend::set_menu_item_checked`）。Radio 因此是整组一起
 * 推，不只是被点的那一项。
 * 0 = 改到了；-1 = 这个 id 不在当前那棵菜单里（没装过，或装的树里没有它）。
 * 禁用项也允许改：置灰的菜单项照样要显示着勾。 */
int moonui_menu_item_set_checked(int id, int checked);

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
 *   词表以外的键（修饰键自己、输入法、媒体键）不产事件：moonui_key_name() 给空
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
 * 了不建 accelerator table，组合只出现在标题文本里，派发只有 Core 一条路。这条规则的
 * 两边同异由真窗口测试各自钉（mac 钉"⌘Q 只响一次且是 MenuSelect"，Windows 钉
 * "⌃S 只响一次且是 KeyDown"），"认领"到底覆盖了哪些组合也在测试里量，不在这里预言。 */
/* 装那份进程级键盘监听。0 = 装上了（重复调用只换回调，监听还是那一份）；
 * -1 = 槽位用满。 */
int moonui_on_key(moonui_closure_fn fn, void *closure);
/* 当下这颗键归属的那个"我们的对象"：焦点控件是我们的控件就报控件，不是就报事件所属
 * 的那只我们的窗口，两个都不是（例如另一个进程的键）报 0，MoonBit 侧据此丢弃事件。 */
moonui_ptr moonui_key_target(void);
/* 1 = 按下，0 = 抬起。 */
int moonui_key_is_down(void);
/* 修饰键位，见上面那套编码。 */
int moonui_key_modifiers(void);
/* 键名，UTF-8，见那张词表。空 bytes = 这颗键不在词表里，不该产事件。 */
moonbit_bytes_t moonui_key_name(void);

/* 焦点（§32）。不带回调，由 MoonBit 每圈事件循环问一次：这只窗口当下把焦点给了哪个
 * 我们的控件；没有（焦点在窗口自己、在 libui 内部的辅助 view、或那个原生对象我们没
 * 记过）报 0。
 * 为什么是问而不是报：两边都没有一个既及时又不侵入的"焦点变了"来源——mac 只有
 * NSWindowDidUpdateNotification（打字时每颗键都来一遍），Windows 得给每个控件挂
 * WM_KILLFOCUS/WM_SETFOCUS，两条都回到按控件乘那笔账。问还有第二个好处："上一次是
 * 谁"只有 MoonBit 记得住，去重因此发生在推事件那一步，程序自己改焦点不会多出事件
 * （真窗口测试钉这条），而 mac 读的是那只窗口自己的 firstResponder（AppKit 每只窗口
 * 各存一份），它不表示"整个应用此刻在听键盘的那只"——那是 [NSApp keyWindow] 的事。 */
moonui_ptr moonui_focused_control(moonui_ptr w);

/* ---- 事件循环（§10）---- */
void moonui_main_steps(void);
/* 走一步。返回 0 表示循环已经结束（收到 WM_QUIT）；返回 1 只说明"这一步没结束"，
 * 处理了一条消息和队列本来就空着都是 1，所以调用方要自己问还剩不剩。 */
int moonui_main_step(int wait);
/* 队列里还有消息可取吗（PeekMessage + PM_NOREMOVE，只探测不取）。 */
int moonui_messages_pending(void);
/* 等消息，最多 ms 毫秒。返回 1 = 有新消息，0 = 超时。
 * 注意"新"是相对上次唤醒算的：队列里有积压时它照样报超时，所以这个返回值
 * 只能当唤醒用，判断有没有活要干得靠 moonui_messages_pending。 */
int moonui_wait_messages(int ms);
/* 单调时钟，毫秒。给 poll_event 的等待预算当墙钟截止点：预算的含义是
 * "最多等这么久"，不是"最多空转这么多轮"。 */
int64_t moonui_time_ms(void);
void moonui_quit(void);

/* ---- 测试脚手架 ----
 * 产品路径不需要这两条：真实点击由 libui 的 WM_COMMAND 路由送进来，
 * 关闭由标题栏按钮。 */

/* 等价于"用户在窗口客户区的 (x, y) 处按了一下鼠标"。
 *
 * libui 没有合成点击的 API，所以这里按窗口标题找回真 HWND，对坐标做命中测试，
 * 再对命中的真按钮发 BM_CLICK——BN_CLICKED/WM_COMMAND 的路由和人手点击走的是
 * 同一条路，于是 §48 的回调链路是被真实验证的，不是被 mock 出来的。
 * 按坐标而不是"取第一个按钮"是为了让布局结果本身参与验证：控件没摆到
 * MoonUI 以为的矩形上就命中不到。
 * 返回 0 表示消息已发出；-1 编码失败，-2 找不到窗口，-3 命不中任何子窗口，
 * -4 命中的不是按钮（含命中空白处）。 */
int moonui_click_button_in_window(const char *title, int title_len, int x,
                                  int y);

/* 等价于"用户点了标题匹配窗口的关闭按钮"：PostMessage 一条 WM_CLOSE。
 * 返回 0 = 已投递（消息在之后的事件循环里才被处理），-1 编码失败，
 * -2 找不到窗口。 */
int moonui_request_window_close(const char *title, int title_len);

/* 这里没有"量一次 Tab 方向"的脚手架：合成 VK_TAB 要先让进程拿到前台，
 * 而前台归属是这台机器的用户状态，量出来的落点跟着激活时序漂。层叠的代价
 * 只需要"绘画顺序和 Tab 顺序是同一条原生子窗口列表"这一条事实，它是 Win32
 * 的定义；列表本身的方向由 moonui_control_z_index 在测试里钉住。 */

/* 等价于"用户在窗口客户区 (x, y) 处那个输入框里打出 text"。
 *
 * 按坐标命中再判种类，和 click_button_in_window 同一个理由：控件没摆到 MoonUI
 * 以为的矩形上就命不中，布局因此参与验证。两份共同的三步是：命中、把插入点放到
 * 文末、然后走各自平台上"真人打字"的那条路。中间那步不放不行——控件里的初始文字
 * 前面会变成新字的落点，而"往哪儿插"是测试自己定的前提，不该跟着默认选中区漂：
 *   - Windows：EM_SETSEL 到末尾，再逐字符 SendMessage(WM_CHAR)。edit 自己的窗口
 *     过程处理 WM_CHAR 并对外发 EN_CHANGE，这正是 TranslateMessage 之后真人按键的
 *     落点；不用 EM_REPLACESEL（跳过字符处理，不是打字），也不用 SetWindowText
 *     （libui 自己把它抑制掉了，见上面 on_text_changed 那段）。
 *   - macOS：makeFirstResponder: 之后问窗口要那只共享 field editor，把选中区收到
 *     末尾，再 insertText: 整串。于是文本系统改内容、发 NSTextDidChangeNotification，
 *     NSControl 转成 controlTextDidChange:，libui 的 onChanged: 因此和真人敲键盘同路；
 *     不用 setStringValue:（那是程序赋值，也正是"程序改文案不该回声成 Input"那条
 *     要测的东西，macos_test 里换掉它就红）。
 *     mac 实测的一个坑：窗口一显示 AppKit 就把可编辑框选成初始 first responder，
 *     field editor 已经作为**它的子视图**在编辑了，所以 hitTest: 命中的往往是
 *     NSTextView 而不是 NSTextField——命中后要往上退到包住它的那只文本框，退不出
 *     才算命不中（-4），不许越过 contentView，否则标题栏那只 NSTextField 会被误认。
 * 一条通知覆盖多少个码元是两边真正不一样的地方，而且两边都按各自的真值在断言：
 * Windows 逐字符发，打 N 个码元来 N 条；macOS 整串一次 insertText:（相当于输入法
 * 成串上屏）只来 1 条。MoonBit 侧不需要知道，分叉留在 C（T18 的形状）。
 * 返回 0 = 文字已进到控件里；-1 编码失败（mac：标题或文字；Windows：文字），
 * -2 找不到窗口，-3 命不中子控件，-4 命中的不是输入框（mac 含"往上退也退不到"），
 * -5 命中了但拿不到可编辑的文本栈（只读框 / 设不上焦点 / 没有 field editor）。 */
int moonui_type_text_in_window(const char *title, int title_len, int x, int y,
                               const char *text, int text_len);

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
int moonui_auto_dismiss_dialog(int ms, int index);

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
int moonui_auto_answer_file_dialog(int ms, const char *path, int path_len,
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
int moonui_menu_click_item(int id);

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
moonbit_bytes_t moonui_menu_dump(void);

/* 等价于"用户在键盘上按了（或抬起了）一颗键"。
 *
 * mac 造的是一条**真 NSEvent** 并交给 [NSApp sendEvent:]，于是进程内监听、上面那条
 * "菜单收不收这组"的判断、first responder 的后续处理全被真跑一遍；Windows 往当下有
 * 焦点的那个控件 PostMessage 一条 WM_KEYDOWN/WM_KEYUP，消息要等事件循环取出来时才
 * 触发 WH_GETMESSAGE 那份 hook——和真键盘同一条路。两边都不是"把回调调一遍"。
 *
 * 归属靠的是焦点而不是坐标，所以调用方要先让焦点落在想按的那个控件上（下一条脚手架
 * 干这件事）；没落上时事件照样产，只是 target 变成窗口自己，测试里那就是一条假绿。
 * key/mods 用键盘那一节的词表和编码；down 非 0 = 按下，0 = 抬起。
 * 返回 0 = 已派发（被菜单认领的组合照样返回 0，只是那条走的是 MenuSelect——只有 mac
 * 有这一档，见上面），-1 = 编码失败，-2 = 找不到窗口，-3 = 这只窗口里没有我们的控件
 * 拿着焦点，-4 = 键不在词表里。跑回调的时机两边不同：mac 当场，Windows 要等下一次取
 * 消息，所以那边的测试先 step 再断言。 */
int moonui_send_key_in_window(const char *title, int title_len,
                              const char *key, int key_len, int mods, int down);

/* 等价于"用户把焦点挪到客户区 (x, y) 处那个控件上"。
 *
 * mac 是 makeFirstResponder:（编辑框要先往上退到包住它的那只文本框，和
 * type_text_in_window 同一个走法；AppKit 会自己换成 field editor），Windows 是对命中
 * 的 HWND 调 SetFocus。按坐标而不是"取第几只控件"，理由和 click_button_in_window
 * 一样：布局摆错了这里就命不中。
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
int moonui_focus_widget_in_window(const char *title, int title_len, int x,
                                  int y);

#ifdef __cplusplus
}
#endif

#endif /* MOONUI_LIBUI_ADAPTER_H */
