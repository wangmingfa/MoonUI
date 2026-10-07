# MoonUI

MoonBit 的 GUI 框架。目标不是"libui-ng 的 MoonBit 绑定"，而是让 MoonBit 能写桌面应用的那层框架：布局、事件、控件、主题、HiDPI、菜单与对话框都在 Core 里定义，具体 GUI 库的差异留在 Backend 实现侧。

## 现在能用什么

0.1 阶段交付的是**后端无关的第一层**，全部有测试覆盖：

| 层 | 内容 |
| --- | --- |
| Core 类型 | `UiError`、几何（逻辑/物理像素、`Scale`）、`Event`、`Style`/`Theme` |
| 布局 | Row / Column / Padding / Spacer / Center / Stack / Grid / Scroll |
| 生命周期 | `NativeHandle` + 句柄表（generation 防悬垂）、`App` 事件主循环 |
| 界面对象 | `Window`、`Widget`（Label / Button / TextInput / Checkbox） |
| 平台能力接口 | 剪贴板、对话框、菜单栏 + 快捷键、`Backend` trait |
| 无障碍视图 | Role / Label / Description / State / Actions 的推导与声明（§32） |
| 示例 | §49 五个 Demo：Hello / Counter / Login / Todo / File Manager，含无头 runner |
| 测试后端 | `MockBackend`：无头跑完整事件循环与布局数值 |

真实后端（libui-ng）尚未接入：native FFI 最小闭环已经在 `probe/` 里用自写 C stub 验证过，但接入 libui-ng 需要先有 CMake 和它的源码。

## 跑起来

```sh
moon check --deny-warn          # 警告在本项目里是错误
moon test                       # native：Core + MockBackend + FFI 探针
moon test --target wasm         # 同一层在 wasm 上也要过（§47：Core 不得依赖任何 GUI 库）
moon run cmd/main               # §49 五个 Demo 的无头输出，含布局与无障碍视图
```

## 代码长什么样

```moonbit nocheck
///|
fn build(app : @MoonUI.App[@MoonUI.MockBackend]) -> Unit raise @MoonUI.UiError {
  let backend = app.backend()
  let message = @MoonUI.Widget::label(backend, "Hello MoonUI")
  let button = @MoonUI.Widget::button(backend, "Click Me")
  let _ = button.on_click(fn() raise @MoonUI.UiError {
    message.set_text("Clicked!")
  })
  let window = app.create_window("MoonUI", @MoonUI.LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  window.set_content(@MoonUI.Widget::column(backend, 16.0, [message, button]))
  window.show()
}
```

这段是编译过的：`MoonUI_test.mbt` 里有一条 blackbox 测试按原样跑它，`_doccheck/` 是同一份代码的独立包验证。

与设计文档 §50 的期望形态差两处，都是当前工具链逼出来的：`trait` 不是类型、也没有 `dyn`，所以后端在编译期随 `App[B]` 选定，构造控件必须显式交后端；`fn { }` 的无参写法已废弃。

## 约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。
- Core 不缓存窗口与控件状态，原生层是唯一事实来源；例外只有 min/max 约束、菜单勾选状态和快捷键表。
- 纯布局节点不占原生对象，叶子的原生父级只有窗口（§14）。
- 事件优先：`on_click` 只是 `Event::Click` 的过滤器糖，路由与派发在 `App` 一处完成（§10）。
- 无障碍视图是推导出来的，不是另登一份名册：Actions 来自事件订阅，State 来自原生层；纯布局节点只有显式声明 Role 才进视图（§32）。
