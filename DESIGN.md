# MoonUI 设计文档

> 这份文档是 MoonUI 的设计初稿，2026-10-07 定稿，之后一直是**编号引用的基准**：`README.md`、`TODO.md` 和代码注释里的 `§14`、`§32`、`§47 风险 1`、`§48-09~11` 全部指向本文的小节号。所以不要重排已有编号，新增内容往末尾追加小节。
>
> 本文只写"要建成什么样"。当前进度与实测事实看 `README.md`，下一步做什么看 `TODO.md`。正文保持原稿措辞，落地时被工具链实测改掉的地方统一记在文末[附录](#附录落地时对本文的五处修正)。

## 项目定位

MoonUI 是一个基于 MoonBit 的跨平台 GUI Framework。

目标是在 Windows、macOS、Linux 上提供统一、现代、易用的 MoonBit GUI 开发体验。

MoonUI 不应该被设计成某一个 C GUI 库的简单 Binding，而应该建立一套独立于底层 GUI 实现的 MoonBit API。

- 项目名称：MoonUI
- Slogan：MoonUI — GUI, the MoonBit way.
- 核心理念：用 MoonBit 编写 GUI，而不是让 MoonBit 开发者编写 C GUI。

最终希望达到：

```text
MoonBit Application
        │
        ▼
    MoonUI API
        │
        ▼
    MoonUI Core
        │
        ▼
   Backend Interface
        │
   ┌────┴────┐
   ▼         ▼
libui-ng    SDL3
   │         │
   ▼         ▼
Native      Custom
Widgets     Rendering
   │         │
   └────┬────┘
        ▼
Windows / macOS / Linux
```

## 一、项目目标

MoonUI 第一阶段的目标不是打造一个完整的 Flutter/Qt 替代品，而是验证：

- MoonBit 是否能够通过 C FFI 构建高质量桌面 GUI。
- C GUI 库能否被安全、优雅地封装成 MoonBit API。
- MoonBit 是否能够承担跨平台桌面应用开发。
- 建立一套与底层 GUI Backend 解耦的 API。
- 后续可以增加 SDL3/GPU 等自绘 Backend，而不破坏公共 API。

长期目标：

- 一个真正 MoonBit-native 的跨平台 GUI Framework。

## 二、设计原则

1. **MoonBit First**

   MoonUI API 必须首先考虑 MoonBit 的语言特性，而不是简单翻译 C API。

   错误：

   ```text
   C API
     ↓
   MoonBit 一比一 Binding
   ```

   正确：

   ```text
   C API
     ↓
   C Adapter
     ↓
   MoonBit FFI
     ↓
   MoonUI API
   ```

2. **Backend Independent**

   MoonUI Core 不能依赖具体 GUI 库。

   核心层不能出现：`uiButton`、`uiWindow`、`GtkWidget`、`SDL_Window`、`HWND`、`NSWindow`。

   这些全部应该隐藏在 Backend 内部。

3. **Native First**

   第一阶段优先使用 Native Widget。

   第一 Backend：libui-ng

   以后可以增加：SDL3、原生 Win32、原生 Cocoa、GTK、GPU Renderer。

4. **Custom Rendering**

   不能让 MoonUI 永远受 Native Widget 限制。

   后期应该支持：Custom Widget、Canvas、Custom Renderer、GPU Rendering。

5. **生命周期安全**

   C 指针不能直接暴露给 MoonBit 用户。

   统一抽象：

   ```text
   MoonBit Object
         ↓
   External Object
         ↓
   Native Handle
         ↓
     C Object
   ```

6. **Event First**

   GUI 的核心是事件。

   需要统一设计：Event、Callback、Event Handler、Event Loop、UI Thread。

7. **Progressive Complexity**

   简单程序应该简单：

   ```text
   Button("Hello")
   ```

   复杂程序再逐渐暴露：Widget、Layout、Style、Renderer、Backend、NativeHandle。

## 三、整体架构

MoonUI 分成四层。

**Layer 1：Public API**

用户直接使用：App、Window、Button、Label、TextInput、Checkbox、List、Tree、Table、Menu、Dialog、Image、ScrollView。

**Layer 2：MoonUI Core**

负责：Widget、Layout、Event、Style、Theme、Lifecycle、State。

**Layer 3：Backend Interface**

定义：create_window、destroy_window、create_widget、set_property、event handling、clipboard、dialog、menu、rendering。

**Layer 4：Native Backend**

例如：libui-ng、SDL3、Win32、Cocoa、GTK。

整体结构：

```text
Application
    │
    ▼
MoonUI Public API
    │
    ▼
MoonUI Core
    │
    ▼
Backend Interface
    │
┌───┴────┐
▼        ▼
libui    SDL3
│        │
▼        ▼
Native   Custom
Widget   Renderer
```

## 四、项目目录

建议项目结构：

```text
moonui/
│
├── README.md
├── LICENSE
├── moon.mod.json
│
├── packages/
│   │
│   ├── moonui/
│   │   ├── app.mbt
│   │   ├── window.mbt
│   │   ├── widget.mbt
│   │   ├── event.mbt
│   │   ├── layout.mbt
│   │   ├── style.mbt
│   │   ├── theme.mbt
│   │   └── error.mbt
│   │
│   ├── widgets/
│   │   ├── button.mbt
│   │   ├── label.mbt
│   │   ├── text_input.mbt
│   │   ├── checkbox.mbt
│   │   ├── radio.mbt
│   │   ├── slider.mbt
│   │   ├── progress.mbt
│   │   ├── image.mbt
│   │   ├── list.mbt
│   │   ├── tree.mbt
│   │   ├── table.mbt
│   │   ├── tabs.mbt
│   │   └── scroll.mbt
│   │
│   ├── backend/
│   │   ├── backend.mbt
│   │   ├── renderer.mbt
│   │   └── native.mbt
│   │
│   └── platform/
│       ├── platform.mbt
│       └── native.mbt
│
├── backends/
│   │
│   ├── libui/
│   │   ├── ffi.mbt
│   │   ├── adapter.c
│   │   ├── adapter.h
│   │   └── moon.pkg.json
│   │
│   └── sdl3/
│       ├── ffi.mbt
│       ├── adapter.c
│       ├── adapter.h
│       └── moon.pkg.json
│
├── examples/
│   ├── hello/
│   ├── counter/
│   ├── form/
│   ├── todo/
│   └── file-manager/
│
├── tests/
│
└── scripts/
    ├── build-libui.sh
    ├── build-libui.ps1
    └── build-sdl3.sh
```

## 五、FFI 架构

MoonUI 不直接 Binding 第三方 C API。

推荐：

```text
MoonBit
   │
   ▼
MoonUI FFI
   │
   ▼
MoonUI C Adapter
   │
   ▼
Third-party C Library
```

例如：

```text
MoonBit
   │
   ▼
moonui_button_new()
   │
   ▼
uiNewButton()
   │
   ▼
libui-ng
```

C Adapter 的职责：

- 隐藏第三方 API。
- 统一 ABI。
- 统一生命周期。
- 统一 Callback。
- 转换错误。
- 处理字符串。
- 处理平台差异。

## 六、Native Handle

MoonUI 内部应该定义统一的 Native Handle。

概念：

```text
MoonUI Widget
     │
     ▼
NativeHandle
     │
     ▼
   void*
     │
     ▼
Native Object
```

MoonBit 层不要暴露：`uiButton*`、`GtkWidget*`、`SDL_Window*`、`HWND`。

用户只看到：Button、Window、Widget。

## 七、External Object

C GUI Object 生命周期必须交给 MoonBit 管理。

例如：

```text
Button
  │
  ▼
External Object
  │
  ▼
uiButton*
```

销毁：

```text
MoonBit Object 生命周期结束
         │
         ▼
     Finalizer
         │
         ▼
  moonui_button_destroy()
         │
         ▼
    uiButton destroy
```

同时提供必要的显式 destroy，但普通用户不应该依赖手动内存管理。

## 八、Ownership

需要明确：Owned、Borrowed、Shared。

例如：

```text
Window
  │
  └── owns
        │
        └── Root Widget
                │
                ├── Button
                ├── Label
                └── TextInput
```

调用：

```text
window.set_content(button)
```

之后 Widget 的所有权关系必须明确，避免：

```text
Window
   ↓
dangling pointer
```

## 九、Callback

Callback 是 MoonUI 最重要的 FFI 部分之一。

典型流程：

```text
C Native Widget
      │
      ▼
  C callback
      │
      ▼
   userdata
      │
      ▼
MoonUI trampoline
      │
      ▼
MoonBit closure
```

例如：

```moonbit nocheck
button.on_click(fn {
    println("clicked")
})
```

不能简单把 closure 当作临时变量传给 C。

MoonUI 必须保证：

```text
Widget
  │
  └── EventHandlers
        ├── on_click
        ├── on_change
        ├── on_focus
        └── ...
```

## 十、Event 系统

统一定义事件模型。

例如：

```text
Event
  ├── Click
  ├── Change
  ├── Input
  ├── Focus
  ├── Blur
  ├── Close
  ├── Resize
  ├── KeyDown
  ├── KeyUp
  ├── MouseDown
  ├── MouseUp
  ├── MouseMove
  └── ...
```

同时提供高级 API：

```text
button.on_click(...)
input.on_change(...)
window.on_close(...)
window.on_resize(...)
```

底层最终都可以统一进入 Event 系统。

## 十一、App

App 是 GUI 生命周期和 Event Loop 的核心。

需要提供：

```text
App::new()
app.run()
app.quit()
app.post(...)
app.is_running()
```

概念：

```text
App
 │
 ├── Event Loop
 ├── Windows
 ├── Backend
 └── UI Thread
```

基本用法：

```moonbit nocheck
import {
  "moonbit-community/moonui" @moonui
}

fn main {
  let app = @moonui.App::new()

  ...

  app.run()
}
```

## 十二、Window

Window API：

```text
Window::new(
  title,
  width,
  height,
)
```

需要支持：

```text
show()
hide()
close()

set_title()
set_size()

set_min_size()
set_max_size()

center()

set_resizable()
set_fullscreen()
```

事件：`on_close()`、`on_resize()`、`on_focus()`。

## 十三、Widget

所有 GUI 元素都应该抽象成 Widget。

基础概念：

```text
Widget
  │
  ├── Button
  ├── Label
  ├── TextInput
  ├── Checkbox
  ├── Slider
  ├── Image
  ├── Container
  ├── ScrollView
  ├── List
  ├── Tree
  └── ...
```

Widget 基础能力：visible、enabled、width、height、position、style、parent、children、event handlers。

## 十四、Layout

不要直接照搬 libui-ng Layout API。

MoonUI 应该建立自己的 Layout 系统。

第一阶段：Row、Column、Stack、Grid、Center、Padding、Spacer、Scroll。

例如：

```moonbit nocheck
Column(
  spacing=16,
  children=[
    Label("Username"),
    TextInput(),
    Button("Login"),
  ],
)
```

另一个例子：

```moonbit nocheck
Row(
  spacing=8,
  children=[
    Button("Login"),
    Button("Cancel"),
  ],
)
```

## 十五、Style

第一版不要做成 CSS。

可以定义：Style

包含：

```text
width
height

margin
padding

background
foreground

font
font_size
font_weight

border
radius

opacity
```

例如：

```moonbit nocheck
button.set_style(
  Style(
    padding=EdgeInsets::all(12),
    radius=8,
  )
)
```

## 十六、Theme

支持：Light、Dark、System。

例如：

```moonbit nocheck
app.set_theme(Theme::System)
```

后期支持：

```text
Theme
  │
  ├── Colors
  ├── Fonts
  ├── Spacing
  ├── Radius
  └── Component styles
```

## 十七、Native Widget 和 Custom Widget

MoonUI 不应该要求所有组件都是 Native Widget。

分为：

```text
Widget
  │
  ├── NativeWidget
  │
  └── CustomWidget
```

Native Widget：Button、TextInput、Checkbox、ComboBox。

Custom Widget：TreeView、DataGrid、CodeEditor、Terminal、FileView。

这样可以兼顾：Native UX、Custom UI、High Performance。

## 十八、Renderer

后期定义：Renderer

负责：

```text
draw_rect()
draw_text()
draw_image()
draw_line()
draw_path()
```

结构：

```text
CustomWidget
      │
      ▼
   Renderer
      │
   ┌──┴──┐
   ▼     ▼
  SDL3   GPU
```

这样可以实现真正的自绘 GUI。

## 十九、Backend

Backend 是 MoonUI 最核心的抽象。

概念：

```text
Backend
  │
  ├── create_app
  ├── create_window
  ├── create_widget
  ├── destroy_widget
  ├── set_property
  ├── event handling
  ├── clipboard
  ├── dialog
  ├── menu
  └── rendering
```

第一 Backend：LibUIBackend

第二 Backend：SDL3Backend

未来：Win32Backend、CocoaBackend、GTKBackend。

## 二十、libui-ng Backend

第一阶段使用 libui-ng。

主要用于：Window、Button、Label、TextInput、Checkbox、Slider、ProgressBar、ComboBox、Tab、Group、Scroll、Box。

结构：

```text
MoonUI
   │
   ▼
LibUIBackend
   │
   ▼
C Adapter
   │
   ▼
libui-ng
```

注意：

- libui-ng 只是 Backend，不是 MoonUI 的公共 API。

## 二十一、SDL3 Backend

第二阶段引入 SDL3。

SDL3 负责：Window、Keyboard、Mouse、Input、Display、Clipboard、Rendering。

MoonUI 自己负责：Widget、Layout、Event、Theme、Component、Rendering abstraction。

结构：

```text
MoonUI
   │
   ▼
SDL3 Backend
   │
   ├── Window
   ├── Input
   └── Renderer
          │
          ▼
         GPU
```

## 二十二、Native API

需要提供少量平台 API：

```text
Platform::current()
```

例如：Windows、MacOS、Linux。

必要时提供：

```text
Window::native_handle()
```

但是 Native API 必须单独放在：

```text
moonui/platform
```

而不是污染核心 API。

## 二十三、Clipboard

统一：

```text
Clipboard::get_text()
Clipboard::set_text()
```

以后：

```text
Clipboard::get_image()
Clipboard::set_image()
```

## 二十四、Dialog

统一：

```text
Dialog::message()
Dialog::confirm()

Dialog::open_file()
Dialog::save_file()
Dialog::select_folder()
```

例如：

```moonbit nocheck
match Dialog::confirm("Delete this file?") {
  true => delete_file()
  false => ()
}
```

## 二十五、Menu

支持：Menu、MenuItem、Separator、Submenu。

支持：Checkbox、Radio、Shortcut。

例如：

```moonbit nocheck
Menu::new([
  MenuItem::new("New"),
  MenuItem::new("Open"),
  Separator,
  Submenu::new("View", [
    MenuItem::checkbox("Sidebar"),
    MenuItem::checkbox("Toolbar"),
  ]),
])
```

## 二十六、Shortcut

统一快捷键：Shortcut

例如：`Ctrl + S`、`Ctrl + Shift + P`、`Cmd + S`。

提供：`app.register_shortcut(...)`。

## 二十七、Thread Model

MoonUI 必须明确 UI Thread。

原则：

- 所有 Widget 操作默认在 UI Thread。

后台任务：

```text
Worker
  │
  ▼
app.post()
  │
  ▼
UI Thread
```

例如：

```moonbit nocheck
worker {
  let data = load_data()

  app.post(fn {
    list.set_items(data)
  })
}
```

不能允许：

```text
Worker Thread
    │
    └──直接操作 Widget
```

## 二十八、Async

未来支持：async

典型流程：

```moonbit nocheck
async fn load_data() {
  let data = await load()

  app.post(fn {
    list.set_items(data)
  })
}
```

## 二十九、字符串处理

C FFI 必须重点处理：

```text
MoonBit String
    ↕
UTF-8
    ↕
UTF-16
```

尤其是 Windows。

MoonUI C Adapter 应该尽可能统一：UTF-8。

平台差异全部隐藏在 C Adapter。

## 三十、HiDPI

必须从第一版考虑。

区分：Logical Pixels、Physical Pixels。

例如：

```text
800 logical px
```

在 Retina / HiDPI：

```text
1600 physical px
```

MoonUI API 默认使用 Logical Pixel。

## 三十一、Image

Image API：

```text
Image::load()
Image::from_bytes()
Image::from_file()
```

第一阶段：PNG、JPEG、WebP。

以后：SVG。

## 三十二、Accessibility

虽然第一版不必完整实现，但架构必须预留：

```text
Accessibility
  │
  ├── Role
  ├── Label
  ├── Description
  ├── State
  └── Actions
```

## 三十三、错误处理

C API 常见：NULL、-1、false。

不要直接暴露给 MoonBit。

统一转换成：UiError

例如：

```text
InitializationFailed
BackendUnavailable
InvalidHandle
OperationFailed
Unsupported
```

## 三十四、构建系统

开发环境：

```text
MoonBit
+
C Adapter
+
CMake / Meson
+
libui-ng
```

最终用户不应该手动安装：libui、SDL、CMake。

最终应该做到：

```text
moon build
```

即可完成对应平台构建。

## 三十五、预编译依赖

可以考虑提供：

```text
prebuilt/
  windows-x64/
  windows-arm64/

  macos-x64/
  macos-arm64/

  linux-x64/
  linux-arm64/
```

这样降低用户构建门槛。

## 三十六、平台支持

第一阶段：Windows x64、macOS x64、macOS ARM64、Linux x64。

第二阶段：Windows ARM64、Linux ARM64。

## 三十七、测试

测试分为三层。

**第一层：** MoonBit Unit Test

测试：Layout、Event、Style、Theme、State。

**第二层：** FFI Test

测试：

```text
C → MoonBit
MoonBit → C
Callback
Lifecycle
Ownership
```

**第三层：** Integration Test

测试：App、Window、Button、Input、Dialog、Menu。

## 三十八、CI

使用 GitHub Actions。

矩阵：Windows、macOS、Linux。

架构：x64、ARM64。

每次提交：

```text
moon test
moon build
FFI test
Integration test
```

## 三十九、MVP

MoonUI 0.1 只实现：

```text
App
Window

Label
Button
TextInput
Checkbox

Row
Column
Padding
Spacer

Click
Change
Close
Resize

Theme

Clipboard

Dialog
```

目标：

可以完整实现：Hello World、Counter、Login、Todo。

## 四十、0.2

增加：Menu、Toolbar、Tabs、ScrollView、Image、List、ComboBox、Slider、ProgressBar、Shortcut、File Dialog。

## 四十一、0.3

增加：TreeView、Table、DataGrid、Canvas、CustomWidget、Animation、Dark Mode、Theme System。

## 四十二、0.4

加入：SDL3 Backend

形成：

```text
MoonUI
   │
   ├── libui-ng
   │
   └── SDL3
```

## 四十三、0.5

开始完善：Custom Renderer、GPU、Text Rendering、Image Rendering、Animation、Virtualized List。

## 四十四、1.0

目标：

```text
Windows
macOS
Linux

Native Widgets
Custom Widgets
GPU Rendering

Layout
Event
Theme
Animation

Clipboard
Menu
Dialog
Shortcut

HiDPI
Accessibility
Keyboard
Mouse
Touch
```

## 四十五、最终能力

最终 MoonUI 应该能够开发：Todo App、Editor、Terminal、File Manager、IDE、Database Client、HTTP Client、Developer Tools。

尤其可以支持类似：

```text
Mo 文件管理器
```

这种应用。

## 四十六、完整架构图

最终：

```text
                            MoonUI
                               │
              ┌────────────────┴────────────────┐
              │                                 │
         MoonUI Core                       MoonUI Widgets
              │                                 │
    ┌─────────┼─────────┐             ┌─────────┼─────────┐
    │         │         │             │         │         │
  Event     Layout    Theme         Input     Table     Tree
    │         │         │             │
    └─────────┼─────────┴─────────────┘
              │
      Backend Interface
              │
      ┌───────┴────────┐
      │                │
 Native Backend    Custom Backend
      │                │
   libui-ng           SDL3
      │                │
      │          ┌─────┴─────┐
      │          │           │
      │       Renderer     Input
      │          │
      │          ▼
      │         GPU
      │
┌─────┼─────┐
▼     ▼     ▼
Windows macOS Linux
```

## 四十七、最重要的技术风险

1. **C Callback 生命周期**

   这是最高优先级的问题。

   必须解决：

   ```text
   C callback
       ↓
   userdata
       ↓
   MoonBit closure
       ↓
   GC / lifetime
   ```

2. **Native Object 生命周期**

   必须防止：dangling pointer、double free、use-after-free。

3. **Thread**

   明确：UI Thread、Worker Thread。

4. **String**

   明确：UTF-8、UTF-16。

5. **HiDPI**

   明确：Logical Pixel、Physical Pixel。

6. **Backend 泄漏**

   MoonUI Core 绝对不能出现：libui、GTK、SDL、Win32、Cocoa。

## 四十八、第一阶段开发顺序

建议严格按照以下顺序（`§48-NN` 就是这里那一格的编号）：

```text
01  创建 MoonUI Repository

02  MoonBit C FFI 最小验证

03  C Adapter

04  NativeHandle

05  External Object

06  C Callback / Trampoline

07  Lifecycle

08  App

09  Window

10  Widget

11  Label

12  Button

13  TextInput

14  Row

15  Column

16  Event

17  Theme

18  Dialog

19  Clipboard

20  Menu

21  HiDPI

22  Windows CI

23  macOS CI

24  Linux CI

25  MoonUI 0.1
```

## 四十九、第一阶段最重要的 Demo

不要一开始做复杂 Demo。

- 第一个 Demo：Hello MoonUI
- 第二个：Counter
- 第三个：Login
- 第四个：Todo
- 第五个：File Manager

如果 File Manager 能够使用 MoonUI 完成基本界面，就证明框架已经开始具备实际开发价值。

## 五十、核心 API 示例

最终希望用户看到的是这样的 MoonBit 代码（这是**期望形态**，当前工具链下不能原样编译，两处差异见附录；编译过的实际写法在 README「API 长什么样」那一节）：

```moonbit nocheck
import {
  "moonbit-community/moonui" @moonui
}

fn main {
  let app = @moonui.App::new()

  let message = @moonui.Label::new("Hello MoonUI")

  let button = @moonui.Button::new("Click Me")

  button.on_click(fn {
    message.set_text("Clicked!")
  })

  let content = @moonui.Column(
    spacing=16,
    children=[
      message,
      button,
    ],
  )

  let window = @moonui.Window::new(
    title="MoonUI",
    width=800,
    height=600,
  )

  window.set_content(content)
  window.show()

  app.run()
}
```

## 五十一、核心定位

MoonUI 最终不是：

```text
libui-ng for MoonBit
```

而应该是：

```text
MoonBit GUI Framework
```

libui-ng 只是：

```text
MoonUI Backend #1
```

SDL3 是：

```text
MoonUI Backend #2
```

未来甚至可以：

```text
MoonUI Native
MoonUI SDL
MoonUI GPU
```

最终形成：

```text
MoonUI
  │
  ├── Native Widgets
  ├── Custom Widgets
  ├── Layout
  ├── Event
  ├── Theme
  ├── Rendering
  └── Platform
```

项目最核心的一句话可以定义为：

```text
MoonUI = A cross-platform GUI framework designed for MoonBit.
```

而整个项目最重要的技术原则是：

```text
MoonBit API 是第一公民。
C 只是实现手段。
libui-ng 只是第一个 Backend。
Backend 永远不能反向决定 MoonUI API。
```

---

## 附录：落地时对本文的五处修正

正文保持原稿措辞不改，以下五处以本机 `moon 0.1.20260920` 的实测为准（2026-10-08 补）：

1. **§4 的配置文件名。** `moon.mod.json` / `moon.pkg.json` 是旧的 JSON 形态；当前工具链用 TOML 的 `moon.mod` / `moon.pkg`，native FFI 按包配 `options("native-stub": [...])`，`link` 只在可执行包里生效、不顺着 import 传下来。
2. **§4 的目录树是建议，不是现状。** 仓库里只有已经存在的东西才有目录；三处有意偏差（`Backend` trait 留在 Core 因为拆包会成环、`packages/widgets/` 暂不建、五个 Demo 的代码留在 Core）的理由写在 README「目录」那一节。
3. **§50 那段示例编不过，两处。** `trait` 不是类型、也没有 `dyn`，所以后端在编译期随 `App[B]` 选定，构造控件必须显式交后端；`fn { }` 的无参写法已废弃。原稿里的 `@moonui.Label::new(...)` 同理要改成 `Widget::label(backend, ...)`。
4. **§34/§35 的构建路径。** libui-ng 没有 CMake 工程，也不发布预编译包，所以「CMake」与「prebuilt/」两条都不成立；实际是 meson + ninja 从固定提交现编（`scripts/build-libui.ps1`），产物不入库。`moon build` 一键跨平台仍然没做到，这一条还欠着。
5. **§47 的六条风险里，第 1、2、6 条已经变成框架内的可判定错误**，靠的是句柄表 + generation（§6）与「`terminate()` 前提是句柄表归零」；第 4 条 UTF-8/UTF-16 由 C Adapter 统一。第 3 条只落地了一半：`App::post`（§27）有队列、有测试，任务在下一轮循环且排在原生事件之前执行，但队列本身没有跨线程保护，也还没有真的 worker 往里投。

另外，原稿「项目定位」里那行中文名在 2026-10-08 决定不再使用，本文正文不再出现它，仓库其余文件也已清理干净。
