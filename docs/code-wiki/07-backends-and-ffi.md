# 07 后端与 FFI

相关目录：

- [backends/native-common](../../backends/native-common)
- [backends/native-windows](../../backends/native-windows)
- [backends/native-macos](../../backends/native-macos)
- [backends/canvas-common](../../backends/canvas-common)
- [backends/canvas-macos](../../backends/canvas-macos)
- [prebuild-link.js](../../prebuild-link.js)

## 7.1 三层结构

```
MoonBit Core（逻辑像素、句柄、事件、布局）
        │  trait Backend（静态分发）
        ▼
native-common（MoonBit）      canvas-common（MoonBit，纯绘制配方）
  backend.mbt  Backend 实现      painter.mbt  Painter trait + 配方
  ffi.mbt      extern "c"        widgets.mbt  WidgetKind → 配方
  canvas.mbt   Canvas 封装
  adapter.h    C ABI 头
        │  moonui_native_* / moonui_canvas_*
        ▼
native-windows/adapter_native.c   native-macos/adapter_native.m
  Win32 直写                        Cocoa 直写
```

四条硬规矩（写在 [adapter.h](../../backends/native-common/adapter.h) 头注）：

1. **ABI 只有 `moonui_*`**：第三方的 `HWND`、`NSView*`、libui 类型一个都不许出现在头里。
2. **指针用 `uintptr_t` 进出，0 表示无**；句柄的 `id + generation` 账本只在 MoonBit 的 `HandleTable`，C 侧不另开一份。
3. **字符串入 C 用 (UTF-8 指针, 字节数)**，MoonBit 的 `Bytes` 不保证 NUL 结尾，C 自己复制；**出 C 用 `moonbit_bytes_t`**，GC 回收，MoonBit 不需要 free。
4. **C 侧只讲物理像素**，DPI 数学只在 MoonBit 的 `Scale`；C 只报 DPI 值。

## 7.2 `native-common`

### 7.2.1 `ffi.mbt`

唯一允许出现平台函数名的 MoonBit 文件。模式：

```moonbit
extern "c" fn c_window_new(title : Bytes, title_len : Int32, width : Int32, height : Int32) -> Int64
  = "moonui_native_window_new"
```

要点：

- 包级 `let handles : @moonui.HandleTable`：原生初始化是**进程级单例**，一次 init、一个事件循环，所以句柄表也放在包级而不是 backend 实例里。
- `unpack2(v : Int64) -> (Int32, Int32)`：C 一次返回两个整数时打包，高 32 位是第一个，低 32 位是第二个；用算术移位拆，负坐标（窗口位置可以为负）能正确还原。
- `#borrow(...)` 标注借用的 `Bytes` 参数，避免不必要的复制。
- Canvas 相关 `moonui_canvas_*` 也在这里声明；Windows 半第一期整体缺席（C 返回 -2），声明照常存在，不链接不炸。

### 7.2.2 `backend.mbt`

`NativeBackend` 字段与职责（[backend.mbt#L15](../../backends/native-common/backend.mbt#L15)）：

| 字段 | 作用 |
| --- | --- |
| `queue : Array[Event]` | 原生事件入队，`poll_event` 排空 |
| `live_windows` / `live_widgets` | 存活对象，用于退出审计与批量清理 |
| `wait_budget_ms` | 事件等待预算；`-1` = 一直等（产品语义：空闲 GUI 不自己退出），测试用有限值 |
| `loop_ended` | 原生循环结束（quit） |
| `initialized` | init 幂等标志 |
| `ime_installed` / `mouse_installed` / `drag_installed` / `gesture_installed` / `key_installed` | 进程级监听是否已装；装不上静默缺席，不挡开窗 |
| `last_focus` | 焦点账：每圈问 `focused_control`，变了才推 `Focus`/`Blur` |
| `theme_base` | 最近一次 `set_theme_base`；用于区分"继承"与"显式"样式，保原生外观 |
| `live_dispatch` | 实时通道回调（live resize/move 同步派发） |
| `live_redraws` | 逐窗 live redraw 开关；**缺席 = 开** |
| `custom_canvases` / `custom_faces` | 自绘面（`Custom`）的位图画布与登记 |

`NativeBackend::new()` 创建空队列、`wait_budget_ms = -1`。`for_testing()` 换成有限等待预算，供真窗口测试用。

`Backend` 实现里的通用翻译：

- `poll_event`：先排 `queue`，再调 C 泵；空则按 `wait_budget_ms` 等待。
- 事件入队前把物理坐标除以 `window_scale`。
- 失败统一转 `UiError`；`moonui_native_last_error()` 取原因。
- 菜单点击通过 `moonui_closure_id_fn` 桥接，id 是 Core 分配的菜单项编号。

### 7.2.3 `canvas.mbt`

```moonbit
pub(all) struct Canvas { ptr : Int64 }   // 0 = 无效
```

- `moonui_canvas_create/destroy/begin_frame/end_frame/save/restore/clip_rect/translate/fill_rect/...`
- 第一期只做**离屏位图帧**：`begin_frame(w, h)` 开物理像素位图，各 `canvas_*` 往上画，`read_pixel` 供测试断言；上屏 attach 由 canvas-macos 使用。
- 全物理像素；逻辑换算在调用方（`CanvasPainter`）。
- 颜色、半径、线宽的 `*_permille` 参数是千分比整数，避免浮点 ABI。

## 7.3 平台 adapter

### 7.3.1 `native-windows/adapter_native.c`

- Win32 直写：窗口（`CreateWindowExW`、DPI 感知）、原生控件（按钮、编辑框、trackbar、progress、combobox、日期选择器等）、菜单（`HMENU`）、托盘（`Shell_NotifyIconW`）、剪贴板、通用对话框、GDI 绘制。
- 每只窗口一个消息循环入口；自定义消息把事件推回 MoonBit。
- 用户拖动产生的 `Moved` 与 Core 自己 `set_position` 的 `Moved` 要区分：后者抑制（`suppress_resize` 同款约定）。
- 失败通过 `moonui_native_last_error()` 返回 UTF-8 字符串。

### 7.3.2 `native-macos/adapter_native.m`

- Cocoa 直写：`NSWindow`、`NSView` 子类、`NSButton`/`NSTextField`/`NSSlider`/`NSProgressIndicator`/`NSPopUpButton`/`NSDatePicker`、`NSMenu`、`NSStatusItem`、`NSPasteboard`、`NSOpenPanel`/`NSSavePanel`、`NSImage`。
- 自绘窗口按钮（交通灯）位置可调（`set_traffic_light_position`），配合沉浸式标题栏。
- 输入法组合来自 field editor 的标记串；键盘、鼠标、文件拖入、触控板手势是**进程级监听**，装一次。
- 画布：`moonui_canvas_attach_window` + `present` 把位图贴到窗口的 `NSView` 上。

### 7.3.3 两平台必须一致的行为

- 逻辑坐标、事件顺序、句柄生命周期与 `MockBackend` 可逐值比对。
- `Moved` 只报用户拖动；`Resize` 在 live resize 期间可走实时通道。
- `request_redraw` 后必须至少一条 `Frame`（自绘后端强制）。
- 不支持的能力必须返回错误或明确缺席，不能假装成功。

## 7.4 链接：`prebuild-link.js`

### 为什么需要

`moon.pkg` 的 `link` 只在被链接的可执行包里生效，库包声明的不顺 import 传播；`moon.pkg` 也不能按宿主 OS 分支。于是用 moon 的 `--moonbit-unstable-prebuild`：构建前跑一次脚本，向 stdout 输出 JSON，其中 `link_configs` 挂到指定包并**顺 import 传播**给所有下游可执行包。

### 它做什么

1. 用 `MOON_HOST_OS`（兜底 `process.platform`）判断宿主；
2. 按宿主编译对应 adapter：
   - macOS：`cc -c -Wall -Wextra -x objective-c -Ibackends/native-macos -Ibackends/native-common -I~/.moon/include`，产物 `_build/prebuild/adapter_native.o`，再 `ar rcs` 成 `libadapter_native.a`；
   - Windows：`cl /utf-8 /c /I...`，产物 `_build/prebuild/adapter_native.obj`；
3. **mtime 缓存**：源文件或 `adapter.h` 更新才重编；
4. 输出**唯一一份** `link_configs`，挂在 `username/MoonUI/backends/native-common` 上：
   - macOS：`-lobjc -framework Cocoa -framework UserNotifications -framework AVFoundation -framework CoreMedia -framework Accelerate -Wl,-no_warn_duplicate_libraries` + `libadapter_native.a`
   - Windows：`-link user32.lib kernel32.lib gdi32.lib comctl32.lib uxtheme.lib comdlg32.lib ole32.lib oleaut32.lib oleacc.lib uuid.lib advapi32.lib shell32.lib` + `adapter_native.obj`

### 为什么挂在 `native-common` 而不是平台包

测试二进制住在后端包里。配置若挂在 `native-macos` / `native-windows`，moon 会对"包库 + 测试可执行"各应用一次，adapter 对象被链接两遍，撞重复符号。挂 `native-common` 后，所有下游（示例壳、测试二进制）只沿 import 链拿到一份。

### 运维含义

- 所有 `moon` 命令**必须在仓库根**执行（脚本里是相对路径）。
- PATH 里要有 `node`；Windows 还要有 MSVC 环境（`cl`），macOS 要有 `cc` / `ar`。
- `moon check` 与 wasm 目标不跑 prebuild，所以不需要 C 工具链。
- 打开 `MOONUI_NATIVE_TRACE=1` 会给 C 侧加 `-DMOONUI_TRACE`，每次 FFI 调用即时 `fflush`，用于定位"死在哪一次调用"。

## 7.5 自绘后端

### 7.5.1 `canvas-common`

纯 MoonBit，**零 C、零 FFI**，所以 wasm 也能编译。

```moonbit
pub(open) trait Painter {
  // 基本图元：save/restore/clip/translate/fill_rect/stroke_rect/fill_linear/
  // shadow/line/stroke_arc/fill_polygon/blur_region/text/image
}
```

- 配方（`paint_panel`、`paint_gradient_panel`、`paint_frosted_panel`、`paint_label`、`paint_slider`、`paint_text_input`、`paint_icon_button`、`paint_menu_row`、`paint_separator`、`replay` 等）只依赖 `Painter`。
- `RecordCanvas`：录制式实现，用来断言"画了什么、按什么参数画"，无需屏幕。
- `widgets.mbt` 按 `WidgetKind` 分派到配方。

### 7.5.2 `canvas-macos`

`CanvasBackend`（[backend.mbt#L16](../../backends/canvas-macos/backend.mbt#L16)）**包住** `NativeBackend`：

- 窗口、事件循环、剪贴板/对话框/菜单/托盘全部复用原生后端；自绘后端只接管"控件"。
- `create_widget` 不创建 `NSView`，而是开一条记账 `CwRec`：kind、text、bounds、visible、enabled、bg/bg_gradient、fg、radius、backdrop_blur、font_size、bold、checked、min/max/value、selected、icon、image、`scroll_parent`、`draw`。
- 句柄表把 `NativeHandle ↔ 记账索引` 映射，`ptr` 存索引 + 基数 `0x7F0000000000`，与堆指针不撞。
- 任何记账变动把全窗标脏。

帧循环（[frame.mbt](../../backends/canvas-macos/frame.mbt)）：

```
repaint(wi)
  scale = inner.window_scale(handle)
  pw/ph = round(logical × scale)
  canvas = 缓存 ?: canvas_create + canvas_attach_window
  canvas_begin_frame(canvas, pw, ph)
  paint_panel(窗口底，主题背景或默认色)
  从 paint order 尾部到头逐条：
    滚动偏移 → 窗口绝对坐标
    若在 Scroll 内 → save/clip/restore（errdefer 保证配对）
    按 kind 选配方绘制；已销毁句柄跳过
  canvas_end_frame + canvas_present
  dirty = false
```

方向很关键：Core 的 paint order 是**顶层在前**（`L[0]` 最上），即时模式里后画在上，所以画布**从尾往头**画；正着画会把底层画到最上，毛玻璃面板会盖住自己的子项。

鼠标：自绘控件没有原生对象，C 只报到窗口；`CanvasBackend` 自己装鼠标闭包，做命中测试、合成 `MouseDown`/`MouseUp`/`Click`/`MouseMove`/悬停。左键的按下/抬起只对自绘面翻译，原生控件仍走原生回调。

滚动：Core 把 Scroll 文档区子树按**文档坐标**推下来，画布按窗口绝对坐标画，需要沿 `scroll_parent` 链把每层 Scroll 的视口原点加回去，并裁剪到最近视口。

### 7.5.3 当前覆盖面

第一期只保证"画得出来"：有真配方的 kind 是 `Panel`、`Label`、`Button`、`Slider`，其余画占位圆角面。后续按分期扩展配方覆盖面。

## 7.6 接一个新平台（如 Linux）的检查表

1. 新建 `backends/native-linux`：`adapter_native.c`（GTK3 直写）、`moon.pkg`（不声明 `native-stub`）、`native_test.mbt`。
2. `prebuild-link.js` 加 Linux 分支：编译 adapter、给 `pkg-config gtk+-3.0` 那串链接参数，仍然挂在 `native-common`。
3. 实现 `adapter.h` 全部条目；不一致的地方优先改 C，不改 MoonBit。
4. 用 `MockBackend` 已写好的断言逐条对齐语义（句柄、坐标、事件顺序、窗口态）。
5. 不需要改 Core，也不需要改 `native-common` 的 `backend.mbt` / `ffi.mbt`。

下一篇：[08 组件与示例](08-components-and-examples.md)。
