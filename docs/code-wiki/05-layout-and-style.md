# 05 布局与样式

相关源码：[widget.mbt](../../packages/moonui/widget.mbt)、[layout.mbt](../../packages/moonui/layout.mbt)、[style.mbt](../../packages/moonui/style.mbt)、[theme.mbt](../../packages/moonui/theme.mbt)、[geometry.mbt](../../packages/moonui/geometry.mbt)。

## 5.1 几何：逻辑像素

| 类型 | 用途 |
| --- | --- |
| `LogicalPoint` / `LogicalSize` / `LogicalRect` | 公共 API 与布局的唯一单位 |
| `PhysicalPoint` / `PhysicalSize` / `PhysicalRect` | 只出现在后端与 C ABI |
| `Scale` | `x` / `y` 缩放；`Scale::one()`、`Scale::of_dpi(dpi)` |
| `EdgeInsets` | `top` / `end` / `bottom` / `start`，`horizontal()`、`vertical()`、`add()`、`all()`、`symmetric()` |
| `BoxConstraints` | `min` / `max`；`tight`、`loose`、`unbounded`、`constrain` |
| `Color` / `Gradient` | `rgb`/`rgba`、`blend`、`luminance`、`readable_foreground`；渐变端点插值 `at(t)` |

换算规则：**逻辑 × Scale = 物理**。后端拿到原生事件（物理坐标）后先除 Scale 再 `poll_event`；Core 给的 `set_widget_bounds` 是逻辑矩形，后端自己乘。`Window::physical_size` 是唯一直接把物理尺寸暴露给应用的便利方法。

## 5.2 控件模型

`Widget[B]` 是**一个结构体 + 一个 `WidgetKind` 枚举**，不是类继承：

```moonbit
pub(all) enum WidgetKind {
  // 原生控件（native-backed）
  Label | Button | TextInput | MultilineEntry | Checkbox | PasswordInput
  | Slider | Spinbox | Progress | ComboBox | RadioButtons | DatePicker
  | Separator | VSeparator | MenuRow | Image | Custom
  // 布局节点（layout-only，is_layout_only() == true）
  Row | Column | Padding | Spacer | Center | Stack | Grid | Sized
}
```

区分两类节点的判据是**是否拥有原生对象**：

| | 原生控件 | 布局节点（layout-only） |
| --- | --- | --- |
| `handle` | `Some` | `None` |
| 创建 | `Backend::create_widget` | 不创建 |
| 几何 | `set_widget_bounds` | 只参与计算 |
| 样式下发 | `set_widget_style` | 只参与层叠 |
| 典型 | `Button`、`TextInput`、`Progress` | `Row`、`Padding`、`Spacer`、`Sized` |
| 例外 | `Panel`、`Scroll` 是真实容器，拥有原生对象，但布局上也是容器 | — |

`is_layout_only()` 的实现见 [widget.mbt#L76-L88](../../packages/moonui/widget.mbt#L76-L88)：只有上表 8 个变体返回 `true`。

`Custom` 很特殊：它有原生对象（宿主视图），但内容由 `DrawList` 自绘。

## 5.3 构造与挂接

常用构造器（全部 `pub fn[B : Backend] Widget::...`，返回 `Self[B] raise UiError`）：

```moonbit
Widget::label(backend, "text")
Widget::button(backend, "OK")
Widget::text_input(backend, "")
Widget::checkbox(backend, "Remember", false)
Widget::slider(backend, min, max)
Widget::progress(backend)
Widget::column(backend, spacing, [children])
Widget::row(backend, spacing, [children])
Widget::padding(backend, EdgeInsets::all(12.0), child)
Widget::center(backend, child)
Widget::stack(backend, [bg, fg])
Widget::grid(backend, columns, spacing, [children])
Widget::scroll(backend, Axis::Vertical, child)
Widget::panel(backend, child)
Widget::sized(backend, width?, height?, child)
Widget::spacer(backend)
Widget::custom(backend, LogicalSize(w, h), paint)
```

挂接：

- `parent.add_child(child)` — 把子控件加进布局节点或容器。
- `Widget::set_text` / `set_checked` / `set_value` / `set_selected` — 属性修改；文本变化会 `mark_needs_layout`，因为固有尺寸可能变了。
- 同一个控件只能属于一棵树（`parent` 只能设一次），重复挂接报错。
- 替换整棵树用 `Window::set_content(root)`。

## 5.4 布局输入：`LayoutSpec`

`Widget::to_layout_spec`（[widget.mbt#L1414](../../packages/moonui/widget.mbt#L1414)）把控件树投影成纯数据 `LayoutSpec`，布局引擎不再看 `Widget`：

```moonbit
pub(all) enum LayoutSpec {
  Leaf(LeafSpec)        // 原生控件叶子
  Row(LineSpec)         // 横排
  Column(LineSpec)      // 竖排
  Padding(PaddingSpec)  // 内缩
  Spacer                // 弹性空白
  Center(CenterSpec)    // 居中
  Stack(StackSpec)      // 叠放
  Grid(GridSpec)        // 等宽网格
  Scroll(ScrollSpec)    // 滚动视口
  Panel(PanelSpec)      // 原生面板容器
  Sized(SizedSpec)      // 固定宽/高
  Unbounded(LayoutSpec) // 解除约束
  Expand(LayoutSpec)    // 占满可用
}
```

关键字段：

| 类型 | 字段 |
| --- | --- |
| `LeafSpec` | `id : Int32`、`intrinsic : LogicalSize`、`expand : Bool`、`fill_cross : Bool` |
| `LineSpec` | `axis : Axis`、`spacing : Double`、`children : Array[LayoutSpec]` |
| `PaddingSpec` | `insets`、`child` |
| `CenterSpec` | `child` |
| `StackSpec` | `children` |
| `GridSpec` | `columns : Int32`、`spacing`、`children` |
| `ScrollSpec` | 内容与视口信息 |
| `PanelSpec` | `id`、`insets`、`child` |
| `SizedSpec` | `width : Double?`、`height : Double?`、`child` |

`LeafSpec.intrinsic` 来自 `Backend::widget_intrinsic_size`（文字尺寸、控件自然尺寸）。这是布局过程中唯一一次跨 FFI 的测量；之后所有几何计算在 MoonBit 内完成，Mock 与真后端走同一套算法。

## 5.5 布局算法

入口：

```moonbit
pub fn measure(spec : LayoutSpec, c : BoxConstraints) -> LogicalSize
pub fn layout(spec : LayoutSpec, frame : LogicalRect, out : Array[Placed]) -> Unit
```

`layout` 把叶子矩形写进 `out`，顺序为**先序**，与绘制顺序一致。`Placed` 只有 `id` 与 `frame`。

### 各节点语义

| 节点 | measure | layout |
| --- | --- | --- |
| `Leaf` | `expand` → `c.max`；否则固有尺寸夹进约束 | 直接写入 `frame` |
| `Row` / `Column` | 主轴求和 + 间距，交叉轴取最大；有弹性项则主轴取上限 | 固定项按固有尺寸，剩余空间**均分**给 `Spacer` / `expand` / `Expand`；弹性项铺满交叉轴 |
| `Padding` | 子项在收紧（只减上限）的约束下测量，再加内缩 | 子项矩形按 insets 内缩 |
| `Spacer` | 零尺寸，但计入弹性项 | 不产生 `Placed` |
| `Center` | 子项在无界约束下测量 | 子项按自身尺寸放到父矩形中心 |
| `Stack` | 各子项在**同一约束**下测量，取宽高最大值 | 各子项同原点；数组靠后的在上层 |
| `Grid` | `columns` 至少 1，行优先流动；最后一行可不满 | 等宽列 + `spacing` |
| `Scroll` | 视口主轴可无限，交叉轴受约束 | 视口矩形给 `Placed`，内容按滚动偏移摆放 |
| `Panel` | 子项在内缩约束下测量 | **先写面板自身矩形**（背景/圆角画在这块原生视图上），子树在内缩矩形里摆放 |
| `Sized` | 用指定宽/高收紧约束 | 子项拿整个 frame |
| `Unbounded` | 去掉约束测量 | 原样摆放 |
| `Expand` | 按父约束测量 | 占满 frame |

### 两条容易踩的规则

1. **`Row` 里的 `expand` 叶子在交叉轴不能按 `c.max` 记账**：Column 给子项的主轴约束是无限，若不回退到固有交叉尺寸，一个 expand 标签会把整行量成无限高（lunamusic 表头实案，见 [layout.mbt#L319-L331](../../packages/moonui/layout.mbt#L319-L331)）。
2. **空间不足时不压缩固定项**：弹性项得 0，固定项保持固有尺寸，宁可溢出。这是"可预测"优先于"自动收缩"的取舍。

## 5.6 样式：`Style`

```moonbit
pub(all) struct Style {
  width : Double?
  height : Double?
  min_width : Double?
  max_width : Double?
  margin : EdgeInsets?
  padding : EdgeInsets?
  background : Color?
  background_gradient : Gradient?
  foreground : Color?
  font_size : Double?
  font_weight : FontWeight?
  radius : Double?
  opacity : Double?
  backdrop_blur : Double?
}
```

- 每个字段都是 `Option`，**`None` 表示"这一层不表态"**。
- `Style::layer(over)`：`over` 中非 `None` 的字段覆盖 `self`，其余保留。这是"不做 CSS"能成立的核心机制。
- `Style::effective_padding()`：未设置按零。
- `Style::empty()`：全 `None`。

### 层叠顺序

```
App::style_base（主题默认样式）
  → 祖先链（由外向内，每层 layer）
    → 控件自身 style
      → 悬停样式（仅当 hovered）
```

实现在 [widget.mbt#L1144](../../packages/moonui/widget.mbt#L1144) 的 `resolved_style`：

```moonbit
let inherited = match self.parent { Some(p) => p.resolved_style(base), None => base }
let merged = inherited.layer(own)
```

注意：`apply_styles` 对每个节点都从同一个 `base` 开始算（每个节点自己沿 parent 链解析），**不是**逐层累加往下传，否则祖先覆盖会被叠两遍。

### 样式下发时机

`Window::relayout` 在**布局之前**调用 `apply_styles`：后端测量文字用的是这份样式下的字号。顺序反了，这一版矩形会按上一版字号算，表现为截字或空隙。

`set_style` 会 `mark_needs_layout`；文本变化同理。**真原生后端有意不应用 `Style` 的颜色/字号**（§32 保留原生外观，`T30` 豁免），但 `opacity` 单独走 `set_widget_opacity` 通道，是这条豁免下的例外（`T84`）。

## 5.7 主题与配色

```moonbit
pub(all) enum Theme { Light, Dark, System }
pub(all) struct Palette { background, surface, text, accent, border }
```

- `Theme::System` 不是第三种配色，而是"等后端报告"的占位；`Theme::resolve(system)` 落到 Light/Dark，系统也报 `System` 时按 Light 兜底。
- `Theme::default_style(system)`：默认背景 `surface`、前景 `text`。前景缺省时按底色亮度推导（`Color::readable_foreground`），自定义深色背景不会出现白字白底。
- `App::set_theme(t)` 影响所有窗口：重算 `style_base`（`App::style_base()`）、`refresh_style_base`、再重排。
- 系统主题变化由后端发 `Event::ThemeChanged`；若 App 强制了 Light/Dark，重算结果是同一个值，只是一次幂等重排。

## 5.8 自定义绘制

`Widget::custom(backend, size, paint)` 接受 `fn(DrawList, PaintEnv)` 风格的绘制函数。`DrawList` 是纯数据：

```moonbit
pub(all) enum DrawCmd {
  FillRect(...) | StrokeRect(...) | FillLinear(...) | Shadow(...)
  | Line(...) | StrokeArc(...) | FillPolygon(...) | BlurRegion(...)
  | Text(...) | Image(...)
  | Save | Restore | ClipRect(...) | Translate(...)
}
```

- 坐标是**控件局部逻辑坐标**；后端负责平移与缩放。
- `PaintEnv` 提供 `size` 与 `measure_text(text, size, bold)`，绘制代码不应自己猜字宽。
- `Widget::repaint()` 让自绘后端下帧重绘；原生后端对 `Custom` 的支持取决于后端实现。
- 可复用绘制配方放在 `backends/canvas-common`（`painter.mbt` / `widgets.mbt`），`packages/widgets` 的组件只依赖 `DrawList` 与 `PaintEnv`，两边都能用。

下一篇：[06 事件、动画与无障碍](06-events.md)。
