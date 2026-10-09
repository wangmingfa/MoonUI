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

#ifdef __cplusplus
}
#endif

#endif /* MOONUI_LIBUI_ADAPTER_H */
