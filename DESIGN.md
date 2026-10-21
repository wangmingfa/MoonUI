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
