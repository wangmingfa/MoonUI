# MoonUI 设计文档

> 这份文档是 MoonUI 的设计初稿，2026-10-07 定稿，之后一直是**编号引用的基准**：`README.md`、`TODO.md` 和代码注释里的 `§14`、`§32`、`§47 风险 1`、`§48-09~11` 全部指向本文的小节号。所以不要重排已有编号，新增内容往末尾追加小节。
>
> 本文只写"要建成什么样"。当前进度与实测事实看 `README.md`，下一步做什么看 `TODO.md`。正文保持原稿措辞，落地时被工具链实测改掉的地方统一记在文末[附录](#附录落地时对本文的八处修正)。

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

**落地（`T101`，2026-10-20）**：这一节的前半兑现了——`WidgetKind::Custom` + `Widget::custom(size, paint)`，尺寸由应用声明、点击与别的控件同一条订阅口子；但绘制**不是**把一支 `Renderer` 塞进控件（那会让 Core 依赖后端包，方向反过来）。Core 只产出**纯数据的绘制清单**（`DrawList` / `DrawCmd`，§18 那几个 `draw_rect()`/`draw_text()`/`draw_line()` 正是它现在的命令），由后端用自己那支画笔重放：mac 原生后端画进位图贴到控件自己的 `layer`，自绘后端画进窗口帧，MockBackend 记账。于是 §18 里"CustomWidget → Renderer → SDL3/GPU"那条竖线，实际形状是"CustomWidget → DrawList → 各后端各自重放"——Renderer 这个类型名还没有必要存在。清单坐标是**控件局部逻辑像素**，逻辑→物理只换一次、归后端。TreeView / DataGrid / CodeEditor / Terminal / FileView 这批住户当时都还没建（`T107`）；其中 `DataGrid` 与 `TreeView` 已由 `T102` 的头两刀交付（见后两段），CodeEditor / Terminal / FileView 仍在 `T102` 里。

**首批住户（`T107`，2026-10-21）**：`packages/widgets/` 立起来了，头两位住户 `ProgressRing` / `Sparkline` 用现有命令就画得出——环是 72 段 `Line` 拼的（每 5°，8px 线宽下接缝缺口 <0.1px），折线本来就是 `Line` 的语义。这条顺序是有意的：先让真实控件把需求顶出来，再决定动哪条 ABI；顶出来的缺口只有一处、而且很具体——§18 的 `draw_path()` 在 `DrawCmd` 里没有对应物（面积图要闭合多边形填充、环想要一段弧），挂 `T109`。包本身只 import Core（`scripts/test-local.sh` 有一道 grep 闸门钉着），所以同一份配方在原生后端、自绘后端与 mock 上都成立。**`T109` 第一刀（2026-10-21）已落 `StrokeArc`**：环从 72 段 `Line` 切到两条弧命令，包因此不再 import `@math`——反过来证明"先用现有命令顶、顶不住才动 ABI"这条路走通了；`draw_path()` 剩下的 `FillPolygon`（面积图）已由 `T109` 第二刀补上（真实住户 `Sparkline::area~` 顶出来的）。

**第一位"数据型"住户（`T102` 第一刀，2026-10-21）**：`DataGrid`——这是本节"自绘面能撑起多复杂的控件"的第一次真考。表头、斑马、选中、分隔线都只是矩形与直线，真正的两笔账在别处：①**虚拟化**在自绘面上换了载体——`VirtualList` 省的是句柄（视口内建、窗外 `close_tree`），自绘面只有一个原生对象，省的是**这一帧的命令**，窗口起点仍是 `floor(偏移 / 行高)`，滚到第 500 行时前 499 行零命令；②**文字**要量：放得下就直接画，放不下才二分求"前缀 + 省略号"并夹在该列里（`clip_rect` 配 `save`/`restore` 三条命令，够宽就夹等于把命令数翻四倍）。这一刀同样没动 ABI——顺带证明 `T109` 缺的"路径类命令"对表格**不是刚需**：列表格要的是矩形、直线和裁剪，不是多边形。 **第三刀（2026-10-21，`DataGrid` 自适应列宽）**：列宽不再只能是固定值——`auto_width` 打开后每列取"自然宽"（表头与该列最宽的一格取较宽者，再加左右内边距）与声明宽（当下限）的较大者，装得下按自然宽排布、装不下按比例压缩，同样**一条 ABI 都没动**。这一刀顺带补上"自绘表格"与原生表格之间一处一直存在的差距：原生表格的列宽多半是按内容定的，而自绘面此前只能写死。代价写明在段注里：自然宽要量全表，所以结果缓存在状态里、只在数据变了之后重量，每帧只做纯算术。 **第四刀（2026-10-21，`DataGrid` 横向滚动与列命中）**：表格能横着滚了——固定宽模式下总列宽超过控件宽时 `set_h_offset` 横着滚，**滚出视野的列整列不发命令**（与纵向的窗口化同一条：看不见的就不画），分列线也跟着偏移走、落在控件外的那些不画。配套两个把手：`column_at(x)` 把控件局部 x 换算成列号（滚过去之后换算跟着走），`scroll_to_column(col)` 把某列滚进视野——它们是下一刀"点表头排序"的前置，排序要的就是"落点属于哪一列"。这一刀还定下一条边界：**自适应模式下横向偏移恒为 0**（列被压进可用宽，本来就没有可滚的余量），两种模式是互斥的两条路——"我要一屏看到所有列" vs "我给每列定好了宽"。

**`T109` 第二刀（2026-10-21，`FillPolygon` 与面积图）**：这一刀把 §18 的 `draw_path()` 补齐到"填充"那一半——闭合多边形填充。它的形状是**被真实住户顶出来的**：`Sparkline::area~`（面积图）这条需求早就在那儿等着，`T107` 那句"别在没有真实住户的时候先做"不是推诿，是排序原则。

这一刀有三条值得记下来的决定：

①**点数组过 C ABI 走「小端 int32 顶点表 + 长度」**——`FillLinear` 的 stops 已经趟过同一形状（`#borrow(stops)` + `Bytes` + n × 16 字节），多边形是每点两个 int32（n × 8 字节）。MoonBit 的 `Int32::to_int64` 是**符号扩展**、`>>` 是**算术右移**，所以负坐标打包出来正是 int32 的小端表示（`-5` → `FB FF FF FF`）——这两条是打包正确的前提，不是可以想当然的地方。

②**顶点不足三个不进清单**——判据放在 `DrawList` 这一层而不是各后端：放行的话，三条后端各判一遍"点够不够"，漏一处就在那条后端上画出一条退化多边形（一条线 / 一个点），而那看着还挺像"画了个东西"。同理**轮廓不必重复首点**（最后一点自动连回第一点），这条约定要验的是"调用方两种写法画出来完全一样"。

③**"闭合"这件事在填充上验不出来**——CG 的 `FillPath` 会把开放路径自动闭合成路径，所以去掉 `ClosePath` 是个**等价变换**（负控制全绿，不是判据没区分力）。真正能验的只有"两种写法一样"，那才是"首尾相连"这条约定的可验形式。

顺带记一条这一刀又踩了的坑：改 `.m` 之后 `moon test` **不重链**，测试跑的还是旧 exe——第一版负控制（顶点 y 翻方向）全绿就是这么来的。解法仍是**两样都清**（`_build/prebuild/adapter_native.o` **与** `_build/native/debug/test/backends/native-macos/*.exe`），判据全绿之前先 `ls -la` 看产物时间戳。

**第五刀（2026-10-21，`DataGrid` 排序与表头指示）**：表格能按列排了——`sort_by_column(col)` 排、同列再点翻方向，表头画出方向箭头（▲ 升 / ▼ 降），`clear_sort()` 回原序。这一刀最有意思的地方不在画法（还是 `text` + `text`，箭头是个字形），而在**三条排序纪律**：①**排序不改动数据**——数据行号必须在排序前后都稳定（`set_cell(row, col)` 按数据行号写格子，重排 `rows` 的话同一 `row` 会指向另一条数据，写错格子还查不出来），所以另存一份"显示位置 → 数据行号"的映射；②**排序必须稳定**——`Array::sort_by` 本身不稳定，同价的两行换位置是用户看得见的抖动，所以比较函数在键相等时按原行号兜底，降序也不能"排完再反转"（反转会把同键行的次序也反过来），只能把方向算进比较里；③**文本列按字典序、不是短 lex**——这一处踩到了 MoonBit 标准库的坑：`impl Compare for String` 是**长度优先**，`"9" < "10"` 成立，短 lex 下 9 → 10 → 100 **恰好与数值序一致**，两个口径混在一起根本看不出差别，所以显式用 `String::lexical_compare`（逐码元比，"10" < "100" < "9"）。数字列要调用方显式声明 `numeric`——自动探测不可靠（"1e5" 算不算数？"" 算不算？），与 `right~` 同一条理由；数值列里有一格解析不出来，那一格退回字典序（不当 0：那会把 "--" 和真正的 0 混成一堆）。这一刀顺带定下一条边界：**表头点击归应用层**——`Click` 事件不带坐标、`MouseDown` 才带，而 mac 半的自绘面只派发 `Click`，控件包内拿不到落点，做不了"点表头排序"；能提供的只有 `column_at` + `header_height` 这对把手（上一刀备好的 `column_at` 正好派上用场）。

**第六刀（2026-10-21，`DataGrid` 行号口径统一）**：这一刀没有新画法，是给第五刀**擦屁股**的——修一个第五刀引入的回归。

回归的形状值得记一笔：**排序把"第几行"劈成了两个意思**。第五刀之前，显示位置与数据行号恒等（没有排序，两者本来就是同一个数），所以哪个 API 用哪个口径都无所谓；排序一来，两者分家了，而公开 API 一半用数据行号（`cell` / `set_cell` / `select_row` / `selected`——`select_row` 拿 `rows.length()` 判界，明摆着是数据行号）、一半用显示位置（绘制里的选中比较、`row_at(y)` 的返回值）。结果就是排序之后：选中高亮到另一条数据、点一行拿到的是别的行的号、滚到某行滚去了另一条。

教训是**口径要挑一个，并且全部公开 API 都用它**。这一刀定的口径是**数据行号**（与 `TreeView` 的"选中按 id 记而不是行号"同一条理由：行号会随视图变，按身份记才不会指错东西）。显示位置只在包内活着，包内配两个互逆的映射（`grid_data_row_at` / `grid_view_pos_of`）负责翻译。三处跟着改：高亮比的是数据行号、`row_at` 返回数据行号、`scroll_to_row` 滚到那条数据**当前所在的位置**（滚到"第 row 个显示位置"会让调用方以为滚到了某条数据、其实滚去了另一条）。

顺带记一条**判据设计**上的坑，比实现本身更值得记：这条判据第一次写的时候用了三行数据、正文高 72px（3 × 24）——正文刚好填满可视区，**偏移上限是 0，根本滚不动**，于是"滚到那条数据"怎么滚都是 0。判据红在 `0 != 24`，看着像实现错，其实是数据没留余量。**判据的数据集本身也要设计**：能滚动的数据集得比可视区多一行。另一条：滚动的上限会夹（滚到显示位置 3 要偏移 72，但"最后一行贴底"的上限是 24），这是正确行为，期望值得按夹法算而不是按算术值。

**第七刀（2026-10-22，`T110`）：自绘面拿到带坐标的左键 + 表头点击的默认接线**——这一刀解的是第五刀记下的那个卡点，同样**一条 ABI 都没动**（C 侧一个字没改）。第五刀说"表头点击归应用层"，理由是 `Click(EventTarget, MouseButton)` **不带坐标**、`MouseDown` 才带，而自绘面此前只经 `mouseUp:` 回流一条 `Click`——控件拿不到"点在哪"。

这条卡点**只在原生后端成立**：进程级鼠标监听（adapter.h 鼠标段）早就收全了 kind 0/1（左键按下/抬起）并带着客户区坐标，缺的是 MoonBit 侧的**翻译层**——原生后端闭包里那句"左键不翻译"（注释写着"原生后端的左键消费者是控件回调发的 `Click`，补这两条会改变原生后端的行为"）把两支挡掉了。这一刀把那句话**改窄**了：不是"左键不翻译"，而是"左键**只对自绘面**翻译"。这里有两条值得记下来的决定：

①**"只对自绘面"不是偷懒，是必须的**——原生控件的左键消费者是控件回调发的 `Click`，补上 `MouseDown` 会改变既有行为，**长按识别账（§32 / `T86⑧`）也吃 `MouseDown(Left)`**，一并会动。所以原生后端多了一张自绘面登记表（`NativeBackend.custom_faces`），"是不是自绘面"这件事只有后端知道（`create_widget` 的 kind 是它自己收到的），C 侧的 kind 表在另一层，不为这一条开口子。登记表必须**跟销毁同步销账**——句柄表会复用 id，销晚了后来新建的控件就会"继承"自绘面身份。

②**默认接线放在控件里是对的**——`DataGrid` 订阅自己的 `MouseDown`，减 `frame().origin` 换算成控件局部（Core 的鼠标事件一律是**窗口/父局部**坐标），落在表头那一行就按那一列排序（表头高随表头字号变，判据走表自己的账）。这解开了第五刀"控件包拿不到 `App`"那个说法里的真问题：拿不到 `App` 的是**事件循环**，但"订阅自己收到的事件"不需要 `App`——`Widget::on_any` 就在控件身上。同列再点翻方向，与 `sort_by_column` **同一条口径**（两处各写一遍的话，改了一处忘了另一处，"点表头"与"调 API"会给出两种结果，而用户分不出这两个入口）。

顺带记一条这一刀踩到的坑（形态与 `T101` 那次不同）：真窗判据第一版写成"点一次就该拿到 `MouseDown` + `MouseUp` + `Click`"，实测**只有前两条**。原因不是实现错，是 **AppKit 的"激活点击"**——测试进程不是前台应用时，左键**首击**被系统当激活点击消费掉：那一击走完监听（`MouseDown`/`MouseUp` 照旧到，因为监听挂在 NSApp 派发路径上、在消费之前）却不进 view 的 `mouseUp:`，所以没有 `Click`。`T101` 记过这个坑，但当时只说"首击会被吞"，这一刀实测确认了**首击有 Down+Up 无 Click、第二击才三条齐全**。这与 `T101` 那次"读像素读早了"是**两类**问题：那次是"帧还没落地"，这次是"**事件被系统吃掉了**"——判据写"一次点击应该产生哪些事件"之前，得先确认这一次点击真的完整走完了 AppKit 的派发路径。

**第八刀（2026-10-21，`T102`）：滚轮的默认接线**——接第七刀的下半段，同样**一条 ABI 都没动**（C 侧一个字没改）。形状只有一句话：`DataGrid` 与 `TreeView` 各自订阅自己的 `Scroll`，把增量加到自己那笔偏移账上、按既有的夹法夹住、变了就 `repaint()`。三条更容易写错的细节记在这里：

①**"滚轮事件本身齐不齐"要按后端分开说**，不能一句"后端已经报给控件了"带过。`backends/native-common/backend.mbt` 的 kind 4 分支确实把滚轮翻成了 `Scroll(LogicalPoint)`，但 target 的来源是 `mouse_target_widget` 查 `live_widgets` 得到的句柄——而 mac 的 C 侧在滚轮这一支**恒报窗口自己**（`adapter_native.m` 的 `if (owner == nil || wheel)`，注释是"滚轮恒报窗口自己，2026-10-18"），于是查不到控件、`drop_target_window` 落回窗口，`Scroll` 的 target 是窗口；`App::dispatch` 对窗口目标只走 `Window::handle_event`（Resize / ScaleChanged / Close），不再下发给控件。**Windows 半不同**（滚轮 PostMessage 给 `ChildWindowFromPoint` 命中的子窗口、owner 在钩子里反查得到），**自绘后端也不同**（`translate_mouse` 已按坐标命中改写）。所以这一刀只改控件包就能让 mock / 自绘 / Windows 三处生效，mac 原生后端那一段的 target 缺口留给下一刀（扩 ABI 把 `hitTest` 已算出的 owner 报出来，或 MoonBit 侧几何命中——后者缺 widget → window 归属，不推荐）。

②**单位与方向都照 C 侧的既有约定，不在控件里再造一份**。`Scroll` 的 `LogicalPoint` 已是**逻辑像素**（C 侧把行轮/精确滚动换算完），所以 `offset += dy` 就是对的，乘行高等于把一次一格变成一次半屏；方向"正 = 往下读 / 往右读"也是同一段的约定（mac 的旗标翻转与 Windows 的负号换算都在 C 侧做完了）。附带的好处是：**控件不需要知道"点在哪"**——`Scroll` 不带位置点，而"这一发归哪张表"由 target 决定，控件只管把增量记进自己的账。

③**纵向与横向是两笔账，必须各夹各的**。`grid_clamp_offset`（"最后一行贴底"那条上限）只管纵向，`grid_clamp_h_offset` 只管横向；混成一本的话横向滚会把表往下拖，而"横滚到底再把纵滚拉回顶"这类操作在用户手上会变成两种偏移互相污染。判据因此专门留了一条"纯横滚后纵向必须纹丝不动"。

判据设计上这一刀又踩到两个老坑的新形态，值得留给后来者：**其一，控件被父容器拉伸后，画的时候高度不是声明高度**——第一版把表直接交给 `win.set_content`，画出来 `env.height()` 是窗口高度，正文比总数据还高，上限被夹成 0，"offset 变了、正文没动"；改成 `Widget::column(b, 0.0, [wg])` 让表保持声明尺寸才让判据真正可观测。**其二，横向滚动的存在会改变"可视正文条数"**——固定宽三列超过控件宽时，横向 0 下只有前两列在视野内，按"每行三格"数下标会在第三条上取到一列以右的空位；判据要按**可见列数**取，或者干脆按内容取而不是按下标取。

**第九刀（2026-10-21，`T102`）：正文拖行重排**——同样没动 ABI。`DataGrid` 在 `MouseDown(Left)` 落下时按控件局部 y 算出按下的是哪一条数据、在 `MouseMove` 里过 4px 阈值才进入拖拽并更新插入间隙、在 `MouseUp(Left)` 提交 `grid_move_row`；公开面同时给一条 `move_row(from, to)` 让程序化重排走同一份实现。判据在 mock 上钉了五件事：单击不重排、微动 1px 不重排（钉阈值）、拖到表尾落点线画在 gap 上且重排成 `b,c,d,a`、选中跟着同一条数据走到新行号、排序激活时不接。五条负控制（不重排、去阈值、选中不跟、排序照接、gap 不修正）各自红在对应那条。

三处形状上的判断值得记：

①**拖拽重排与排序是两种不同的"顺序"**。排序只改 `sort_order`（显示顺序），`rows` 与数据行号不动——这是第五刀定下的口径，`set_cell(row, col)` 才能在排序前后都写对格子。拖行重排改的是**数据顺序本身**，挪完之后行号按新顺序重编，外部留着的旧行号会指向另一条数据。两者混在一张表上会互相打脸：排序激活时拖动，抬起后排序立刻把数据重排回去，用户看到的是"拖了没反应"。所以这一刀**排序激活时不接拖拽**（`state.sort_col < 0` 才记起点），而不是"拖完顺手清排序"——后者会在用户不知情时丢掉排序状态。

②**"拖"与"点"要靠阈值分开，而且必须有一条判据真的钉住它**。第一版判据只写了"单击不重排"，但单击路径里根本没有 `MouseMove`，把阈值改成 0 它照样绿——判据是空的。补上"按下→挪 1px→抬起"这一步之后，去阈值才真的红（红在"没过阈值却画了落点线"）。这是第 3.3 节"负控制绿不等于判据有效"的又一例：判据挂在一条**走不到被测分支**的路径上，等于没测。

③**插入间隙 ≠ 目标下标**。`gap` 是"插到第 gap 个显示位置之前"，而"把第 from 行移到下标 to"是移除之后的下标——`gap > from` 时要减一。实现里最初的写法在 `i == to` 处先 push 待移行、再 push 原行，结果行落在目标前一位（判据报 `b,c,a,d` 而不是 `b,c,d,a`）；改成按**输出位置** `next.length() == to` 决定落地时机才对。这条 bug 是被判据抓出来的，不是被负控制——说明"断言具体行内容"比"断言 offset 变了"值钱。

已知缺口（记在 `T102`）：原生后端只在**命中控件**时把 `MouseMove` 报给控件，所以指针拖出控件边界后表收不到移动、也收不到抬起，拖拽会停在最后一帧。要修得在 C 侧拖动期间做指针捕获（或由 Core 在按下时订阅整窗移动），属于 ABI/事件路由那一层，不在这一刀。（**第十三刀已还**，见下。）

**第十刀（2026-10-21，`T102`）：键盘导航**——同样没动 ABI，`KeyDown(EventTarget, KeyPress)` 与键名词表（`adapter.h` 的 `Up` / `Down` / `Home` / `End` / `PageUp` / `PageDown`）都在。`DataGrid` 在同一个 `on_any` 上再接一支：修饰键全松的方向键 / `Home` / `End` / `PageUp` / `PageDown` 在**显示顺序**上移动选中，`selected` 仍存数据行号（进出各翻译一次），`PageUp` / `PageDown` 的步幅是 `floor(正文高 / 行高)`（至少 1），目标夹到 `[0, n-1]`。三处判断值得记：

①**"移动光标"与"翻视口"是两件事**。每按一次都 `scroll_to_row` 会把选中行钉在视口顶部、屏幕整行翻，读起来像翻页而不是移动光标；桌面表格的惯例是"光标在视口内走，走到边上才把视口推一格"。所以新加的 `grid_keep_visible` 只在该行看不见时才改偏移，且只滚到"刚好露出"（上方越界对齐顶边、下方越界对齐底边）。判据专门钉了这一条：走到下标 2（底边正好等于正文高）时偏移必须还是 0，再下一行才变 24。

②**没有选中时 `cur = -1` 不能落进夹法**。第一版把"未知键"也交给统一的夹法处理，而 `-1` 一夹就成 0——按任意键都会选中第一行。修法是把"这个键算不算导航键"（`handled`）与"目标位置"分开记，未知键整段不执行。判据用"清掉选中后按 `q`"钉住；负控制把那层守卫去掉，红在 `0 != -1`。

③**接不接修饰键要一次定清楚**。`Shift+Down` 将来是扩选区间、`Ctrl` / `Alt` / `Meta` 各有别的语义，所以只接全松；`Enter` / 空格是"激活行"，这张表还没有行激活的概念，一并让出去。判据里 `Shift+Down` 在最后一行时"不动"看不出区别，真正的判别项是 `Ctrl+Home`（不接 → 仍是 4，接了就回 0）。

**这一刀的真窗缺口（比前几刀更硬）**：mac 侧 `MoonuiCustomView` 的 `acceptsFirstResponder` 返回 `NO`（注释是"首版不抢焦点：自定义面还没有键盘语义"），`mouseDown:` 也不 `makeFirstResponder`，Core 只有 `set_focus_chain`、**没有** `request_focus`。于是**真窗上自绘面根本收不到 `KeyDown`**，本刀交付的是控件侧接线与 mock 判据。让它生效要单独开一刀做"自绘面焦点 opt-in"：不能把 `acceptsFirstResponder` 直接改 `YES`（所有自绘面都会挤进 Tab 链、打断文本框输入），得由 `Widget::custom` 侧声明、C 侧按声明回答。Windows 半同待核实（自绘面子窗口走 `WM_SETFOCUS`，同样没有开关）。记在 `T102`。

**第十一刀（2026-10-21，`T102`）：自绘面的键盘焦点 opt-in**——还上一段记的缺口，也是 `T102` 系列里第一刀动 C 的。形状是一条**逐控件**的开关，不是全局策略：`Widget::custom(size, paint, focusable~=false)` 把声明经 `Backend::set_custom_focusable(handle, on)` 交给后端；mac 半给 `MoonuiCustomView` 加一个默认 `NO` 的字段，`acceptsFirstResponder` 按它回答、`mouseDown:` 只在开着时 `makeFirstResponder:` 自己；Windows 半没有自绘面可设，**如实报 -2**；canvas 后端还没有键盘路由，空操作。`DataGrid` 建起来就传 `focusable=true`。三件事值得记：

①**默认必须是关，而且"关"要有可观测的后果**。自绘面是裸 `NSView`，恒 `YES` 会把每一块"只画点东西"的面塞进焦点体系，还会在点击时从文本框手里抢走焦点——这是用户能直接感知的破坏。所以判据不只钉"声明了能收键"，还钉"没声明的面点它也不抢"：真窗里先放一块没声明的面、点一下、再发一颗键，键必须仍然没人接。

②**C 侧只认自绘面，别的句柄返回成功但不做事**。`set_custom_focusable` 在 mac 上先判 `isKindOfClass:[MoonuiCustomView class]`；不是自绘面就按 Core 的契约当空操作（返回 0），避免这条被误用到原生控件上、又因为"调用没报错"而看不出误用。Windows 的 `-2` 同理：**平台缺席要能被调用方看见**，而不是静默成功。

③**一条打不红的负控制揭穿了 `acceptsFirstResponder` 的真实地位**。把它改成恒 `NO`，真窗判据照样绿：`-makeFirstResponder:` 在这条路上不问它，键的归属也是监听里按 firstResponder 反查的。真正让键到达面的是 `mouseDown:` 里那次 `makeFirstResponder:`。所以 `acceptsFirstResponder` 目前只是**语义声明**（AppKit 自发的焦点转移——系统 Tab、`selectNextKeyView:`——才看它），这条判据覆盖不到那条路径，将来要验"Tab 落在表上"得补一条真按 Tab 的判据。把这条写进文档，比让一个永远绿的负控制伪装成"已覆盖"更诚实。

**第十二刀（2026-10-21，`T102`）：mac 原生后端的滚轮改判给自绘面**——还的是第八刀记下的"默认接在真窗上只有 Windows 与自绘后端能用"。三件事值得记：

①**target 与 owner 要分成两本账，且只能加读口、不能改既有那支**。mac 半对滚轮**恒报窗口**（2026-10-18 的决定：滚轮是整窗手势，`NSScrollView` 自己吃掉滚动），而自绘后端（`backends/canvas-macos`）反过来靠"target == 窗口指针"认窗——把 `mouse_target` 改给控件会让它整条事件丢掉。所以 ABI 上**加一支读口**（`moonui_native_mouse_owner`）：监听里 `hitTest` 的 owner 本来就算出来了、只是被丢弃，另存一本账的成本只有一次赋值。MoonBit 侧只对**自绘面**换收件人，原生控件与窗口空白仍归窗口（"滚轮调音量"那类整窗手势依赖它们）；Windows 半如实报 0——那边 target 本来就落在控件上，恒 0 即行为一个字节不变。

②**判据要能区分"换收件人"与"多派一份"**。面收到 `Scroll` 还不够，同一颗滚轮必须"窗口一条都没有"；再补一条"同一窗口里滚按钮仍归窗口"，才把"只对自绘面开"钉住。两条负控制各只红对应那一段：去掉 `is_custom_face` 守卫 → 按钮被改判给自己；owner 读口恒 0 → 面收不到、窗口收到。

③**合成事件丢了 identity——脚手架问题会伪装成实现 bug**。`send_mouse_in_window` 用 CGEvent 转 NSEvent 投送，合成的滚轮**没有 windowNumber**，监听里 `locationInWindow` 不是请求点，`hitTest` 打不中面 → owner 报 0；第一版判据因此红在"面收不到"，看起来像实现漏了一条支。修法是投送侧把 owner 直接登记、监听只在 `[e window] == nil` 时接住（真事件都带 window）。这与第十一刀的"陈旧产物"是同一类教训：**先确认判据用的是真事件还是脚手架，再判断红的是谁**。

**第十三刀（2026-10-21，`T102`）：自绘面的指针捕获**——还第九刀记的缺口，ABI 一位没动，只动 mac 监听那一段。形状是"按下那一刻把收件人钉住"：监听里 `hitTest` 出 owner 之后，若这颗是 `LeftMouseDown` 且 owner 是 `MoonuiCustomView`，就把 owner retain 进一本 `moonui_native_mouse_capture`；此后同一扇窗的 `LeftMouseDragged` / `LeftMouseUp` 不再看 hitTest，收件人恒是这本账里的面；抬起那一颗**投完**才清（顺序反了就成了"抬起不给自己"）。三件事值得记：

①**捕获只对自绘面开，且绑在"同一扇窗"上**。原生控件（按钮、文本框）的按下/抬起配对本就由 AppKit 的 tracking loop 管住，再插一杠会把它们的行为改掉；拖到别的窗口上的那一串也不属于这块面（`[e window] == [capture window]` 才认），否则一面之内的拖动会吃掉另一个窗口的事件。C 侧只在这一处动 retain/release：换面时先 release 再 retain，拆监听/收尾时清 nil，免得"按下期间控件被拆"留下悬空指针。

②**捕获是"换收件人"，不是"多派一份"**。判据因此不能只看"面收到了"：拖到邻居按钮上时，面必须收到 `MouseMove`（坐标是**按钮中心**，不是按下点——证明坐标仍按当前位置算）、按钮必须**一条都没有**。再加一条"抬起之后再拖到按钮上就归按钮"，把"抬起清捕获"钉住：捕获泄漏的话这条会反向红，而只看"面收到抬起"是看不出来的。

③**脚手架的配套抬起会把捕获提前放掉**。`send_mouse_in_window` 投按下那一颗时会往 NSApp 队列里补一颗配套的抬起（喂会自跑 tracking 循环的控件）；判据若在"按下"与"拖出"之间 `scaffold_drain`，等于替用户松了手，捕获立刻被清、后面的移动就按 hitTest 走。第一版判据正是这么写的，红得像实现漏了；改成三颗连续投、末尾一次排空，并如实把末尾那颗配套抬起（落在按下点、也归面）写进判据才稳定。这是第十二刀③的同一类教训的另一面：**合成事件的行为约束也是判据的一部分**。

④**那颗配套抬起还会按真实光标重算坐标**——它出队时 AppKit 用的是当前鼠标位置，不是我们给的合成点，同一份代码两次跑能给出不同落点。第一版把它钉成"落在按下点"后，机器上鼠标动一下判据就红。最终把它从判据里摘出去：只钉我们投的前两颗（坐标由我们决定），按钮那侧只按"落在按钮中心的事件数"数。**判据只能钉自己能控制输入的东西**，脚手架自带的那颗不在其中。

诚实边界：合成事件只有按下/拖拽/抬起三颗，"真手指拖出**窗口**之后 AppKit 还把拖拽送进进程监听"这一半钉不住，归 `§51` 手测；Windows 半没有对应实现（kind 18 自绘面在 `widget_new` 里本就没有分支），缺口照旧记在 `T102`。

**第十四刀（2026-10-21，`T102`）：排序交给调用方（`on_sort` 回调）**——纯 MoonBit 侧，`DataGrid::new` 多一个 `on_sort~ : ((Int32, Bool) -> Unit)?`。给了之后表不再自己比，表头点击与 `sort_by_column` 都只把"哪一列、哪个方向"报出去（同列翻方向、换列回升序的口径与内置排序共用一套），显示顺序就是 `rows` 的顺序，箭头照这次请求画；不给时行为不变。为什么要有这条路：内置比较只有字典序与数值序，而列表实际要排的常常是表看不见的键（热度、最近播放、服务端顺序、"回到原始顺序"）。两件事值得记：

①**"表不排"要落成一条真的分支，不能只靠"回调存在时跳过比较"**。`set_rows` 会把排序标记置脏，`grid_rebuild_sort` 若照旧走内置比较，调用方排好的顺序会被表的字典序再排一遍——而它用什么键排的表并不知道。判据因此把数据选成"调用方要的顺序与字典序**相反**"：只看"请求收到了"证明不了表真的没排。

②**回调要在收尾之前调**。回调里多半同步 `set_rows` 换了数据；先调回调、再清脏标记重建显示顺序，新数据才不会在下一帧被当成"还没排过"。**函数类型作为可选参数时，调用侧要写 `Some(fn ...)`**——函数字面量不会自动包成 `Some`，漏了会报一条把人往类型声明上引的 mismatch。

**第十五刀（2026-10-21，`T102`）：复制 / 粘贴的默认接线（`⌘C` / `⌘V`）**——纯 MoonBit 侧，没动 ABI。`Backend` 上本来就有 `set_clipboard_text` / `clipboard_text`，缺的只是控件把它们接到键盘上：`on_any` 的 `KeyDown` 最前面加两支（`c` / `v` + `meta` 或 `ctrl`、**不带** `alt`/`shift` → 复制 / 粘贴），其余键照旧落到导航那条分支。表是只读的，所以两边形状不一样：**复制**是表能独立完成的事（选中行按数据列序拼 TSV、`\t` 分列、结尾 `\n`，写进系统剪贴板，Excel / 飞书表格认这个形状），**粘贴**只能是请求（`on_paste` 收到 `(选中的数据行号, 全文)`，改哪一格 / 换整行由调用方定）。三件事值得记：

①**没选中行时不要写剪贴板**。写个空串进去会把用户刚复制的东西冲掉，这是"看起来无害"的一类错——所以 `copy_selected` 先看 `selected`，没有就报 `false` 什么都不做。粘贴那侧同理：没回调、没选中、剪贴板 `None` 或 `""`，四条边界都不回调。

②**复制取的是选中那条数据，不是显示位置**。排序激活后显示位置与数据行号是两回事（`sort_order` 存在的理由），所以复制必须走 `selected`（数据行号）而不是"第 n 个可见行"。判据因此专门在降序之后复制数据行 0，钉 `"a\t1\n"`。

③**`⌘` 与 `Ctrl` 都认，`Alt`/`Shift` 一个都不接**。前一半是"三个后端同一张表"的可移植性，后一半是"别抢应用层的别的命令"（`⌘⇧C` 在很多应用里另有含义）。判据里 `⌘⇧C` / `⌘⌥C` 必须让剪贴板一位不变——只测正向的话，"修饰键判断写宽了"看不出来。

诚实边界：格子里本身带 `\t` 或换行的行，复制出去会被粘贴方切错；这里**不做转义**（转义会在对方那里留下一串没人认的引号），这类列不该拿它去复制。

**第十六刀（2026-10-21，`T102`）：拖表头列边界调列宽**——纯 MoonBit 侧，一条 ABI 没动（宽度本来就是表自己画出来的）。状态里多一份**稀疏覆盖账** `col_widths`（`0.0` = 该列没手动调过，回落 `columns` 的声明宽），绘制、命中、横向上限与边界判定四处读同一份账；表头按下**先判边界（±4px）再判列**。三件事值得记：

①**用"按下时的宽 + 位移"，不是每帧加增量**。增量口径把帧率算进结果——同样拖 100 像素，事件多的那台机器拖得更宽；而且往回去拖回不到原位。判据因此专门"拖 +30 再拖回"钉宽度必须精确回到 60，而不是某个累加值。下限 24 同理：往左拖过头夹住，而不是让列消失。

②**边界优先于排序**。两列之间那条缝同时属于"第 i 列的边缘"和"第 i+1 列的列头"，按列判的话用户永远调不动，拖完还会顺手把表排一遍。判据同时钉"宽变了"与 `sort_column() == -1`。

③**自适应模式下不接，也不要假装接了**。那里列宽由"自然宽压进可用宽"决定，`grid_layout_widths` 根本不读手动账——拖了看不见变化。所以边界按下什么都不做（连排序也不做），`set_column_width` 同样早退。**这一道守卫目前没有外部可观测面**：把守卫关掉，判据不会红（只是白污染一份账、并让后续移动事件被 resize 支吞掉），所以它的负控制如实记为"试过、不变红"，没有算进"两条负控制"里。

诚实边界：调宽是会话内的账（`columns` 不跟着改，重建 `DataGrid` 就回去），持久化归调用方；真窗上还没有"指针在缝上变 resize 光标"（后端没有设置光标形状的口子）；双击缝"自动最合适宽"要复用自适应那套自然宽度量，留到有真实需求时再接。

**第十七刀（2026-10-21，`T102`）：右键菜单**——同样纯 MoonBit 侧。`show_context_menu`、`Menu`、`MenuItem` 在 Core 里早就有（`Widget::set_context_menu` 就是它的包装），缺的只是表自己接一条默认的。`new` 加 `context_menu~ : Bool = true`，打开时多挂一段 `on_any` 认右键按下。三件事值得记：

①**右键先选中指针下那一行**。菜单里「复制」取的是 `selected`——不先选中，它复制的是上一次选中的那一行（或干脆置灰），用户按在哪一行就复制哪一行才是他要的；标准表格也这么做。表头与正文空白处**不改选中而菜单照弹**：那两处没有"哪一行"，顺手清掉用户原来的选中是意外。

②**菜单每次右键现造，不是装一份再改置灰**。`set_context_menu` 的订阅落在 `new` 之外，「改置灰」与「弹菜单」两段订阅的先后由调用方决定——复用同一份就得赌这个顺序，赌错时菜单里还是上一次的状态。现造一份的代价是每次右键几个对象，与"菜单里显示错的东西"相比便宜。

③**置灰按此刻状态算，两个入口共用一份语义**。复制要 `selected >= 0`，粘贴还要 `paste_hook is Some(_)`（没去处就置灰——点亮了却什么都不发生比置灰更糟）。两个条目的回调直接调第十五刀的那两个内部函数，于是右键、`⌘C/⌘V`、公开方法三条入口逐字一致，不会出现"菜单复制的是显示行、键盘复制的是数据行"这种分叉。

诚实边界：菜单只有「复制 / 粘贴」——"删除行 / 插入行 / 隐藏列"都要表知道语义，归调用方 `set_context_menu` 自己装；`show_context_menu` 没有坐标参数，菜单位置由后端定（弹在右下角时可能盖住表格，是后端弹窗的通用行为）；**别和 `set_context_menu` 同时开**，两段订阅各弹一次。

**第十八刀（2026-10-21，`T102`）：按需取行（懒加载 / 分页数据源）**——同样纯 MoonBit 侧。虚拟化早就是"只画窗口里那几行"，所以缺的不是画得少，而是**表可以比手里的数据更长**：`total_rows` 声明数据源的总行数，`on_fetch` 报 `(起始数据行号, 还差几行)`，调用方取回来 `set_rows` 追加。四件事值得记：

①**滚动范围按声明总数、不是已加载条数**。不这么改的话上限只到"已加载的最后一行"，用户永远滚不到还没取的那部分——懒加载就退化成"分批加载完才知道有多长"。声明值比已加载条数小时**不起作用**（取两者较大者）：把已经拿到的行藏到滚动范围外，比"声明值暂时不准"糟得多。

②**请求在绘制里核，不在滚动入口核**。窗口不只由滚动改变——首帧布局、改尺寸、数据到达都会改变"这一屏需要到第几行"。只在 `set_offset` / 滚轮那几处核，首帧就会停在半屏空板上。放在绘制里每帧核一次的代价由上界挡住：`fetch_upto` 只在"要得更多了"时推进，`set_rows` 把它收回到新的已加载条数（于是"请求 100 只给 40"之后还能补问）。

③**差额是整个缺口，不是一页**。拖到底时窗口在位置 500、手里 100 条，就要 `(100, 400)`。表不知道分页大小，报"我还差这么多"才是诚实的；一次取多少由调用方按数据源决定。

④**未加载段只画底色与分隔线**。什么都不画（连格子都没有）会让滚到底的用户以为表坏了；画空文字格子又像是"这一行真的是空的"。底色 + 分隔线读作"这段还没内容"，与空表格的 `empty_text` 是两件事——后者只在总行数为 0 时出现。

诚实边界：本地排序只排**已加载**那一段（要全量排序用 `on_sort` 让服务端排）；方向键 / 拖拽重排 / 右键选行都停在已加载边界（滚轮与 `set_offset` 才能越过并触发取数）；未加载段没有"加载中"文案或转圈；请求了没来不会自动重试，直到窗口要得更多或调用方 `set_rows`。

**第十九刀（2026-10-21，`T102`）：逐行行高**——纯 MoonBit 侧。绘制本来就是按行循环，缺的是"每行多高"这个量。四件事值得记：

①**行高按数据行号、不按显示位置**。行高是**内容**的属性（"这一行是两行文字"），排序只改显示顺序，高矮该跟着那条数据一起走。于是一份"显示顺序下的行首前缀和"（`grid_row_tops`）成了唯一几何来源，按布局版本缓存（换数据 / 排序 / 改行高 / 改总数都 +1）。

②**同一套算术原来在四五处各写一遍**——绘制循环、`grid_max_offset`、`grid_first_row`、`row_at`、拖拽落点、拖拽起点、右键选行、`scroll_to_row`、`grid_keep_visible`、懒加载的窗口末行，全是 `(y - hh + eff) / row_height` 的 floor。变高之后每一处都得改成前缀和查找，于是这一刀先把它们收成 `grid_view_pos_at`（控件局部 y）与 `grid_view_pos_at_content`（内容坐标 y）两个入口，各处的"行高算术"只剩这一份。均匀行高时二分与 `floor(y / h)` 逐位一致，所以不用这个能力时几何一分不变——这也是它的安全网：既有 42 条判据一条没改都仍然成立。

③**表不自己量文字**。折行规则、字段语义表都不知道（"备注"要折三行、"状态"只占一行），量出来是猜；行高由调用方给。代价是"内容变了行高要跟着变"是调用方的事（`set_row_heights`）。

④**换行高要重夹偏移**。原来滚到 48（总高 120、正文 72），换回全 24 后总高 96、上限 24——不重夹就停在空屏上。`set_row_heights` / `set_total_rows` 都在改完账之后走一次 `grid_effective_offset`。

诚实边界：懒加载下未加载那一段按统一行高算（那些行还没有内容），`set_rows` 带上来时重算；行高是会话内的账，持久化归调用方；没有"拖行边界改行高"的手势（要命中行边界 + 指针形状，且与拖拽重排的按下区域打架）；没有自动折行 / 自动量高。


**第二十刀（2026-10-21，`T102`）：非字符串单元格（勾选框 / 色块 / 进度条）**——纯 MoonBit 侧，三种画法全是既有命令（`FillRect` / `StrokeRect` / `Line` / `Text`），一条 ABI 没动。四件事值得记：

①**画法按列声明、不按格**。`GridCellKind` 挂在 `GridColumn` 上：一列通常装同一种东西（"完成"列全是勾、"标签颜色"列全是色块），按格声明等于让调用方在每一行重复同一个决定；"这一列到底是什么"本来也只有调用方知道，与 `numeric~` 同一条理由。格里的值**仍是字符串**，`kind` 只决定怎么读、怎么画——于是复制 / 粘贴 / 排序 / 自适应宽度一个字都没改，这是"画法变、数据不变"的边界。

②**认不出就不画，不猜**。`Check` 用白名单（`true` / `1` / `yes` / `y` / `✓`）而不是"非空即真"：`"false"` 画成勾是这类控件最常见的错，宁可让认不出的值显示成空框。`Swatch` 认 `#RRGGBB` / `RRGGBB` / `0xRRGGBB` / 十进制，认不出**一条命令都不发**——黑色是一个真实的颜色，画它等于撒谎。`Bar` 认 `0.42` 与 `42%`，**夹到 0..1**（`150%` 画满、负数画空），否则条会越出格子。

③**条的读数字画在条上方**。只有条没有数，用户读不出 73% 还是 74%；文字与条共享行高（文字用"行高 − 条高 − 空隙"居中），三者都不依赖列的左右对齐——对齐是给文字用的。

④**自适应宽度要认 kind**。`grid_natural_widths` 给 `Check` / `Swatch` / `Bar` 分别加 14 / 20 / 40 的下限：图形格子的"自然宽"不是文字的度量值，量出来是 0 的话自适应会把勾压成一条缝。

诚实边界：`kind` 是会话内的列声明（`GridColumn` 不可变，换画法要重建表）；勾选框**只读**，点击不改值（行内编辑那一刀还没开）；`Swatch` 不认颜色名与带 alpha 的 `#RRGGBBAA`；`Bar` 只认一个数，没有目标值 / 第二段复合条。


**第二十一刀（2026-10-21，`T102`）：多选**——纯 MoonBit 侧，一条 ABI 没动：扩选用的是 `KeyPress` 里早就有的 `shift`，高亮仍是既有的 `FillRect`。四件事值得记：

①**选择模型是"集合 + 头 + 固定端"，不是"锚点 + 区间"**。区间表达不了 `⌘A`、`select_rows([...])`、`toggle_row` 造出来的不连续集合，也表达不了"头掉了该落到哪儿"；集合是唯一真值，区间剥掉修饰键之后由它算出来。`selected` 因此从"唯一选中行"降格成集合里的**头**——最后被点/被挪到的那一行，扩选往它这边长，粘贴落在这儿。`sel_anchor` 是按下第一颗 `Shift+方向键` 时的头，**不跟着头挪**——跟着挪的话区间会缩成"永远两行"，这是最容易写错、也最容易在判据里看不出来的一处。

②**键位跟着桌面表格的惯例分两层**：不带修饰的方向键**折叠回单行**（多选之后按一下 `Down`，只剩新落点，否则"我刚才选的那一片怎么还在"会成为常态）；带 `Shift` 的才是扩选。没有选中时第一颗 `Shift+方向键` 等同普通选中——"空集合往上扩"没有意义。

③**复制按显示顺序，不按集合的存储顺序**。集合只在需要时（复制、对外快照）按 `grid_view_order` 排一遍：用户看到从上到下，粘出来就该是那个顺序。排序只改显示顺序、集合存的是数据行号，所以"排序之后高亮仍钉在同几条数据上"与"复制出来是屏幕顺序"这两件事同时成立。

④**行号会变的两个地方都要改号**：拖行重排（`grid_remap_row`——被挪的那条换成目标、被挤开的各移一格，与 `grid_move_row` 搬 `rows` 是同一套账，含头与固定端，并去重）；`set_rows` 少了行（`grid_prune_selection` **只剔越界的**，头掉了落到最后一个留下的行——多选里少几行，剩下的几行仍然是用户选过的，一股脑清空是过度反应）。

诚实边界：**鼠标修饰键点击没做**——`MouseDown` 事件里没有修饰键字段，`⌘/Ctrl+点击`、`Shift+点击` 要扩事件 ABI 才能做，当前点击一律按单行选中（落在集合内才保留集合）；全选只覆盖已加载的行；集合是会话内的账；`TreeView` 没有多选。


**第一位"层级型"住户（`T102` 第二刀，2026-10-21）**：`TreeView`。树与表在屏幕上的差别只有三样——缩进多少、有没有箭头、点哪儿折叠——所以这一刀没有新画法，把力气全花在**结构**上：①嵌套的树先**扁平化**成一维可见行（`depth` / `expanded` / `leaf` 在那一刻算好并缓存），因为绘制与命中都只认行号，而重算只发生在换数据 / 展开 / 收起这几个显式口子上；②于是虚拟化直接复用上一刀的窗口算术，"一万个节点滚到底"与"二十个节点"发的命令数一样多；③缩进参考线**按窗口内最大深度**铺而不是全表——按全表铺会让浅层那一段悬着几条空线，而"每行记祖先还有没有兄弟再画 `├─`"要贵得多，只换来几个像素的美观，不值；④参考线的层次是"底色 → 选中底色 → 参考线 → 文字"，比表格的竖分列线难一层：那条可以最后画，这条最后画会割穿字。跟上一刀一样，一条 ABI 没动——`T109` 对树也不是刚需（箭头用 `▸`/`▾` 字形，不画三角形）。顺带把两处重复的省略算术收进包内 `text_fit.mbt`：单元格与树行文案本来就该是同一套"量 → 省略 → 夹住"。

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

**兑现情况（2026-10-21）**：这一节的五个命令里，`draw_rect()` / `draw_text()` / `draw_image()` / `draw_line()` 都有对应物（`DrawCmd` 的 `FillRect`/`StrokeRect`/`Text`/`Image`/`Line`），`draw_path()` 也补了一半——**`StrokeArc` 已由 `T109` 第一刀落地**（标量参数、不动数组，最便宜的那笔：`DrawCmd::StrokeArc` + `DrawList::stroke_arc` + `Painter::stroke_arc` + `replay` 一臂 + 画布 ABI 与两份 C，Windows 半如实 `-2`）。**`FillPolygon` 已由 `T109` 第二刀落地**（面积图那个真实住户顶出来的）：点数组过 C ABI 走「小端 int32 顶点表 + 长度」那条路——`FillLinear` 的 stops 已经趟过同一形状，多边形是每点两个 int32。`StrokePolyline` 仍挂着（**无真实住户**：折线现在用 `n-1` 条 `Line` 拼是 `Line` 的本义，不算绕路）。

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

**现状（2026-10-30，`T188`）**：Core 与后端都**零 async 依赖**；全仓唯一用
`moonbitlang/async` 的地方是 `examples/lunamusic-shell/online_lyrics.mbt`
（在线取词的 HTTP 那半），而且是在 **worker 线程**里起事件循环，结果经
`app.post` 回主循环——不是主循环自己跑 async。

文件 IO 也**不走** `moonbitlang/async/fs`，尽管它能力齐全。理由与取舍写在
`examples/lunamusic/DESIGN.md` 的「C-07 补记」，含一份 `/tmp` 里的探针实测
（`ExternalEventLoop` 在本仓可用、读档留在主线程、`None` 可夹成帧预算、跨线程
唤醒可截断 `poll`）。真挡住它的只剩两条：`async fn` **沿调用链传染**
（`library_load` / `write_tags` / `export_m3u` 一路到 `launch` 到 `main`，
机械但成片），以及 `App::step` 得自己实现一个 `ExternalEventLoop` 把两套唤醒
时刻表（`post_after` 的 500ms 心跳 + 33ms 频谱链）并进一个 `poll`。所以现在不做，
换过去的真收益只有 Windows 非 ASCII 路径（记在 `TODO.md` 的 `T189`），而那条
要等真迁移才拿得到。此前"wasm-gc 会碎"的说法已实测纠正：没有任何门禁跑
`--target wasm-gc`，删那 4 处 `options(targets:)` 是 ~5 行。

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

## 五十二、自绘后端与画布 ABI（Backend #2，2026-10-17 起）

§51 预留的"自绘后端"从图纸变实物。动机：原生控件后端（§32）保系统外观，
样式消费是定点破开的补丁（Panel/Label/Button 三处，见皮肤通道），到不了
像素级复刻；自绘后端把"画什么"整条收进框架，绚丽视觉（渐变/阴影/圆角/
自绘滑条/图标）从"求系统开恩"变成"照参数画"。

### 52.1 渲染层选型

不用 Skia（GB 级源码 + depot_tools 构建链 + 违反 T82 的零第三方依赖纪律），
不用 nanovg（GPU-only，无头 CI 测不了，上游弃维护），用**平台 2D API**：

- mac：CoreGraphics（渐变/阴影/路径/抗锯齿文本/CoreText 全套，系统自带）
- Windows：Direct2D（对应物，同样系统自带；欠账到 Windows 批再落）
- 未来 Linux：Cairo/SDL 视情况，只是第三个适配器，架构不变

MoonBit 侧看到的只是一套 `moonui_canvas_*` C ABI（adapter.h），平台实现
互不可见——与现有 `moonui_native_*` 适配器同一形状。

### 52.2 画布 ABI（adapter.h 新段，约 20 条）

状态模型：一只上下文 = 一扇窗的一帧。坐标物理像素（§30 的既有口径，
Scale 换算归平台实现侧）；颜色沿皮肤通道的 0xRRGGBB 打包；错误走返回码，
不跨 C 帧 raise。

```c
/* 帧生命周期 */
moonui_ptr moonui_canvas_create(void);              /* 进程级画布工厂 */
int moonui_canvas_attach_window(moonui_ptr, moonui_ptr w); /* 绑窗口 */
int moonui_canvas_begin_frame(moonui_ptr, int w, int h);   /* 开帧（客户区物理尺寸） */
int moonui_canvas_end_frame(moonui_ptr);            /* 收帧（flush） */

/* 状态栈（与 CG save/restore 同构） */
int moonui_canvas_save(moonui_ptr);
int moonui_canvas_restore(moonui_ptr);
int moonui_canvas_clip_rect(moonui_ptr, int x, int y, int w, int h);
int moonui_canvas_translate(moonui_ptr, int dx, int dy);

/* 形状 */
int moonui_canvas_fill_rect(moonui_ptr, int x, int y, int w, int h,
                            int radius_permille, int64_t rgb);
int moonui_canvas_stroke_rect(moonui_ptr, int x, int y, int w, int h,
                              int radius_permille, int64_t rgb, int width_permille);
int moonui_canvas_fill_linear(moonui_ptr, int x, int y, int w, int h,
                              int64_t stops, int n); /* stops: [pos千分,rgb] 对的打包 */
int moonui_canvas_shadow(moonui_ptr, int dx, int dy,
                         int blur_permille, int64_t rgb); /* 设后一次 fill 生效 */
int moonui_canvas_line(moonui_ptr, int x0, int y0, int x1, int y1,
                       int64_t rgb, int width_permille);

/* 文本（度量与绘制同一套参数，保证量出来的就是画出来的） */
int64_t moonui_canvas_measure_text(const char *utf8, int len,
                                   int font_permille, int weight);
int moonui_canvas_draw_text(moonui_ptr, const char *utf8, int len,
                            int x, int y, int font_permille, int weight, int64_t rgb);

/* 图像（解码归平台，沿 T86⑤ 的既有约定） */
int moonui_canvas_draw_image(moonui_ptr, const char *bytes, int len,
                             int x, int y, int w, int h);
```

减法纪律：第一版**不做**路径/贝塞尔/径向渐变/图层合成——常见音乐客户端复刻需要
的图形元素（圆角矩形、线性渐变、投影、文本、图标位图）全部在上述集合里。
要加再说，ABI 只许加法（既有教训：adapter.h 从 47 条涨到现在没有断过）。

### 52.3 MoonBit 侧 API

新包 `packages/moonui-canvas`（Core 不动——`Canvas` 是 Backend 的实现
细节向上暴露的薄门面，Core 的 `Backend` trait 一字不改）：

```moonbit
// 用法：自绘后端的 App 在 Frame 事件里拿到画布
app.on_frame(win, fn(ctx : Canvas) {
  ctx.fill_rect(x, y, w, h, radius=Some(8.0), color=cm_red())
  ctx.text("标题", x, y, size=16.0, weight=Bold, color=cm_ink())
})
```

逻辑像素进（`Canvas` 内部按窗口 Scale 换物理，§30 口径），`Option` 参数
表达"这项不画"，不搞标志位。

### 52.4 自绘后端结构（backends/canvas-macos）

- 控件记账：沿 MockBackend 的形状（style/bounds/text/value 全在 MoonBit
  侧的记录里，`Backend` trait 的读写口操作记录，不出像素）
- 帧循环：`request_redraw`（§31 既有契约）触发 → `poll_event` 吐 `Frame`
  → Core 调 paint 回调 → `end_frame` flush
- 绘制顺序：消费 `set_paint_order`（T29 既有）那张表，自绘没有 z-order 猜谜
- 无头测试：CG 的 bitmap context 渲染成字节，断言用**录制式**（画布调用
  序列逐条比）+ 位图哈希（同机自比，跨机不比——字体度量随系统漂）

### 52.5 分期

1. **画布 ABI + mac CG 实现 + 录制式单测**（ABI 落 adapter.h，实现落
   adapter_native.m，tests 过门禁）——2026-10-17 完成
2. **canvas-macos 后端四件套**：Panel/Label/图标钮/Slider——先让
   `examples/hello` 在自绘后端上跑起来，与原生后端同一棵 Core 树
   ——2026-10-17 完成。落了三层：canvas-common 的绘制配方层
   （Painter trait + RecordCanvas 录制式判据，纯 MoonBit 进 wasm 门）；
   canvas-macos 的 CanvasPainter（逻辑→物理换算，§30）与
   CanvasBackend（窗口/事件复用 NativeBackend，控件只记账；
   poll_event 开头收脏帧整画整贴，`examples/hello-canvas-native`
   与原生后端同树跑通）。欠账：自绘控件没有命中测试，鼠标事件
   仍报到窗口；其余 kind 画占位面——都排给分期③
3. **lunamusic 切自绘后端**：滑条/播放条换自绘脸，对照常见音乐客户端截图逐区校
4. **Windows（Direct2D）**：有 Windows 机器再说，ABI 已钉住不改

---

## 附录：落地时对本文的八处修正

正文保持原稿措辞不改，以下修正以各条落日当天的实测为准（前五条 2026-10-08 补）：

1. **§4 的配置文件名。** `moon.mod.json` / `moon.pkg.json` 是旧的 JSON 形态；当前工具链用 TOML 的 `moon.mod` / `moon.pkg`，native FFI 按包配 `options("native-stub": [...])`，`link` 只在可执行包里生效、不顺着 import 传下来。
2. **§4 的目录树是建议，不是现状。** 仓库里只有已经存在的东西才有目录；三处有意偏差（`Backend` trait 留在 Core 因为拆包会成环、`packages/widgets/` 暂不建、五个 Demo 的代码留在 Core）的理由写在 README「目录」那一节。
3. **§50 那段示例编不过，两处。** `trait` 不是类型、也没有 `dyn`，所以后端在编译期随 `App[B]` 选定，构造控件必须显式交后端；`fn { }` 的无参写法已废弃。原稿里的 `@moonui.Label::new(...)` 同理要改成 `Widget::label(backend, ...)`。
4. **§34/§35 的构建路径。** libui-ng 没有 CMake 工程，也不发布预编译包，所以「CMake」与「prebuilt/」两条都不成立；实际是 meson + ninja 从固定提交现编（`scripts/build-libui.ps1`），产物不入库。`moon build` 一键跨平台仍然没做到，这一条还欠着。
5. **§47 的六条风险里，第 1、2、6 条已经变成框架内的可判定错误**，靠的是句柄表 + generation（§6）与「`terminate()` 前提是句柄表归零」；第 4 条 UTF-8/UTF-16 由 C Adapter 统一。第 3 条只落地了一半：`App::post`（§27）有队列、有测试，任务在下一轮循环且排在原生事件之前执行，但队列本身没有跨线程保护，也还没有真的 worker 往里投。

6. **§14 的"布局节点不占原生对象"对 `Scroll` 不再成立**（2026-10-14，`T74`）。`Scroll` 现在占用一个原生对象（kind 15）：布局上视口先入 `Placed`、子树照常绝对坐标排；写回后端时子树坐标按最近滚动祖先的视口原点平移成文档区坐标，滚动容器在原生侧裁剪并出滚动条（macOS 两侧都是 NSScrollView + 翻转 documentView；libui 的 Windows 半先落剪裁容器、滚动条在 `T75`）。其余布局节点（Row/Column/Padding/Spacer/Center/Stack/Grid）仍是纯布局节点，"叶子的原生父级是窗口 contentView"多了一类例外——滚动子树的原生父级是视口容器。

7. **§21 与 §51 的 Backend 编号（2026-10-15，`T82`）。** 应 owner 重构决定删 libui 后端、框架收敛到原生后端单后端：`backends/libui-{common,macos,windows}` 三包、`third-party/libui` vendored 拷贝、`scripts/build-libui.sh`/.ps1、六份 `examples/*-libui` 壳整体删除；ABI 头 `adapter.h` 移居 `backends/native-common/`（它从头就是纯 `moonui_*` 声明，libui 类型一个不漏——正文本就守着这条），前台门 `packages/moonui-app` 缩成 `new_app()` 三步糖直接返回 `App[NativeBackend]`。正文 §21（libui-ng Backend）、§42/§51 里 Backend #1/#2 的编号按原稿措辞保留，读作史注——当下树里唯一的真后端是 §51 "Native Widgets" 那一支的直写实现（Backend #2 的名分由原生后端顶了，正文里 #2 写的 SDL3 那个名字从未实现）；§21 提的"libui-ng 只是第一个 Backend"由删除变成了已发生的历史。Backend trait 与 Mock 一字未动——"Backend 永远不能反向决定 MoonUI API"（§51 的技术原则）原样成立，删一个 Backend 恰是那条原则的实证。另：第 4 条修正里的 `scripts/build-libui.ps1` 与 meson + ninja 现编路径随删除退场，读第 4 条时以本条为准。

8. **worker 与跨线程投递（2026-10-15，`T85①`）。** 第 5 条修正里"§47 风险 3 只落地了一半"的那半收口：`App::post`（§27）的队列依旧只被 UI 线程碰，跨线程的收口是平台层的投递原语（`moonui_worker_run`，adapter.h 的 worker 段注）——worker 线程跑完 work 闭包后，C 把落地闭包投回主线程，主循环泵消息时它在 **UI 线程**执行，落地动作是 `app.post(...)`：外来投递经投递原语变成了 UI 线程投递，队列依旧无锁。任务撤回不需要区分"是谁投的"：落进来的是一条普通排队任务，撤回它走 Core 的 `post_task`/`cancel_task`（句柄从 1 起，0 是"从未分配"的哨兵；已执行、已取消、循环已收尾后再取消都是幂等空操作）。worker 为什么是平台线程而不是 MoonBit 侧一条：MoonBit 侧没有线程 API，native 运行时也没有跨线程形态的文档承诺——跨线程调用闭包与跨界递增递减由 pthread 探针（tests/ffi）在本工具链（moon 0.1.20261012）上钉过，引用回收统一在接收侧；引用账不新增并发回收形态，"跨线程取消口"与"一次投递一条线程"的线程池形状都没有——前者因为撤回窗口盖在"排队到执行"这一段（由 Core 句柄覆盖），后者留给真要用它的那天。`T85②` 的输入法组合相位（`Event` 加 `ImeStart`/`ImeCompose`/`ImeEnd` 三变体，既有变体与语义一字未动）不是对本文的修正，是新事件源接进既有路由——只许加法的那条红线在 event.mbt 的变体注释里记账。

9. **§51 的 Backend #2 有了具体设计（2026-10-17，皮肤通道收尾时立项）。** 原稿把 Backend #2 写作 SDL3，从未实现；现按 §52 落为**自绘后端 + 画布 ABI**：渲染层选平台 2D API（mac=CoreGraphics、Windows=Direct2D）而不是 Skia/nanovg——Skia 是 GB 级构建链且违反 `T82` 定下的零第三方依赖纪律，nanovg GPU-only 无头 CI 测不了，平台 2D API 零新依赖、能力等价（渐变/阴影/路径/文本全有）。读 §21/§51 的 Backend 编号时：#1（libui）已删，#2 名分由原生后端顶着，自绘后端按本条与 §52 读作 #3。

另外，原稿「项目定位」里那行中文名在 2026-10-08 决定不再使用，本文正文不再出现它，仓库其余文件也已清理干净。
