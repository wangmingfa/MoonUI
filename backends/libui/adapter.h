/* MoonUI 的 libui-ng C Adapter（设计文档 §5、§20，开发顺序 §48 第 03 步）。
 *
 * 这一层之上只有 MoonBit，之下只有 libui-ng：libui 的类型、宏、HWND 一个都不
 * 许漏进 adapter.h。换后端时 MoonBit 侧只认这套 moonui_* 名字，这就是 §5 里
 * "隐藏第三方 API / 统一 ABI / 统一生命周期" 的具体形状。
 *
 * ABI 约定（§29）：
 *   - 指针一律 uintptr_t 进出，0 = 没有这个东西；
 *   - 进 C 的字符串是 (UTF-8 指针, 字节数) 两个参数——MoonBit 的 Bytes 不保证
 *     以 NUL 结尾，所以 C 侧自己复制一份再交给 libui；
 *   - 出 C 的字符串是 moonbit_bytes_t，由 GC 回收，MoonBit 侧不需要 free。
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
 * 前提是所有控件已经销毁干净——libui 在退出时审计自己的分配表，
 * 发现泄漏就直接 DebugBreak。 */
void moonui_terminate(void);

/* ---- 窗口（§12）---- */
moonui_ptr moonui_window_new(const char *title, int title_len, int width,
                             int height);
void moonui_window_show(moonui_ptr w);
void moonui_window_hide(moonui_ptr w);
/* 销毁窗口。§14 的布局在 MoonUI 这一侧，窗口不持有 child 的所有权，
 * 所以 child 必须已经全部销毁——DestroyWindow 会连带销毁还挂着的子窗口，
 * 之后再 destroy 一次就是野句柄。 */
void moonui_window_destroy(moonui_ptr w);

/* ---- 控件摆放（§14）----
 * 把控件的 HWND 搬进窗口客户区，并按 MoonUI 算好的矩形定位。x/y 是窗口
 * 客户区坐标，单位物理像素（逻辑像素的换算在 MoonBit 的 Scale 里，§30）。
 * 不使用 libui 的容器布局：纯布局节点因此可以真的不占原生对象。 */
void moonui_control_attach(moonui_ptr window, moonui_ptr child, int x, int y,
                           int width, int height);

/* ---- 按钮（§13）---- */
moonui_ptr moonui_button_new(const char *text, int text_len);
void moonui_button_set_text(moonui_ptr b, const char *text, int text_len);
/* 当前文案（UTF-8）。libui 这里返回的是它自己分配的一份拷贝，
 * 契约要求调用方 uiFreeText()，所以拷进 bytes 之后立刻还掉。 */
moonbit_bytes_t moonui_button_text(moonui_ptr b);
/* 注册点击回调。成功返回 0；回调槽用满返回 -1。
 * C 侧会 incref closure，所以 MoonBit 不必再替它看守生命周期。 */
int moonui_button_on_clicked(moonui_ptr b, moonui_closure_fn fn, void *closure);
/* 销毁按钮，并松开它占用的闭包引用。必须在所属窗口销毁之前调用。 */
void moonui_button_destroy(moonui_ptr b);

/* ---- 事件循环（§10）---- */
void moonui_main_steps(void);
int moonui_main_step(int wait);
void moonui_quit(void);

/* 测试脚手架：等价于"用户在窗口客户区的 (x, y) 处按了一下鼠标"。
 *
 * libui 没有合成点击的 API，所以这里按窗口标题找回真 HWND，对坐标做命中测试，
 * 再对命中的真按钮发 BM_CLICK——BN_CLICKED/WM_COMMAND 的路由和人手点击走的是
 * 同一条路，于是 §48-06 的回调链路是被真实验证的，不是被 mock 出来的。
 * 按坐标而不是"取第一个按钮"是为了让布局结果本身参与验证：控件没摆到
 * MoonUI 以为的矩形上就命中不到。
 * 返回 0 表示消息已发出；-1 编码失败，-2 找不到窗口，-3 命不中任何子窗口，
 * -4 命中的不是按钮（含命中空白处）。 */
int moonui_click_button_in_window(const char *title, int title_len, int x,
                                  int y);

#ifdef __cplusplus
}
#endif

#endif /* MOONUI_LIBUI_ADAPTER_H */
