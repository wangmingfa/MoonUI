///|
/// 组件画册（§49 的第六个 Demo）：把 0.1 的基础控件与布局节点、0.2 的九种
/// 原生控件与八个组合组件做成一页可点的目录。
///
/// 形状参考 Element UI 的组件文档页：左栏是组件清单，右栏同时给**示例代码**
/// 与**真实控件**。它要证的不是"还有第六种界面能拼出来"，而是另一件事：
/// 公开 API 对一个从零开始的用户是否自解释——每一段示例代码就写在旁边，
/// 读者对照着看，代码和真控件不许对不上。
///
/// 技术上的关键选择：切换组件时**整棵内容树重建**（`Window::set_content`
/// 关旧树、挂新树），而不是"右侧一个容器、往里换内容"——Core 还没有
/// "从父级摘下单个控件"的 API（§8 的所有权注记），而整树重建正是 Todo /
/// File Manager 已经用熟的路子，句柄一个不漏地回收由 `set_content` 保证。
/// 状态（点击计数、回显文案、开关）放在 Gallery 结构体里而不是树里，
/// 树是耗材，状态不是。
///
/// 与其他五个 Demo 同一条约定：写在库里（而不是只在某个例子里），让它
/// 有可回归的载体——mock 后端跑断言，真后端开真窗口，同一份代码。

///|
pub struct Gallery[B] {
  backend : B
  window : Window[B]
  /// 当前展示的组件页（`section_names()` 的下标）。
  mut current : Int32
  /// 已经构建过内容树（`demo` 里第一次 `refresh` 之前 select 是空转）。
  mut built : Bool
  // 各组件页的活状态。树每次切换都重建，状态放这里才活得过重建。
  /// Button 页：点击计数。
  mut clicks : Int32
  /// TextInput 页：最近一次输入的全文。
  mut echo : String
  /// Checkbox 页：被控文本是否启用。
  mut extra_enabled : Bool
  // 0.2 批各页的活状态，同一规矩：树是耗材，状态放这里才活得过重建。
  /// Slider 页：当前值。
  mut slider_value : Int32
  /// Spinbox 页：当前值。
  mut spin_value : Int32
  /// Progress 页：当前进度（0..100；-1 只在按下"不定进度"那一下出现）。
  mut progress_value : Int32
  /// ComboBox 页：选中下标。
  mut combo_selected : Int32
  /// PasswordInput 页：最近一次输入的全文（回显只报长度，不回明文）。
  mut pwd_echo : String
  /// Multiline 页：最近一次输入的全文。
  mut multiline_echo : String
  /// RadioButtons 页：选中下标。
  mut radio_btn_selected : Int32
  /// DatePicker 页：当前日期时间文本（"YYYY-MM-DD HH:MM:SS"）。
  mut date_text : String
  /// RadioGroup 页：选中下标。
  mut group_selected : Int32
  /// Tabs 页：当前页下标（换页走整树重建，下标得存这里）。
  mut tabs_current : Int32
  /// Steps 页：当前步下标。
  mut steps_current : Int32
  /// Alert 页：当前情绪（0..3 对应 Info / Success / Warning / Error）。
  mut alert_idx : Int32
  /// Breadcrumb 页：最近一次点的段（-1 = 没点过）。
  mut crumb_at : Int32
  /// Pagination 页：当前页码。
  mut page_now : Int32
  /// Rate 页：当前分值。
  mut rate_value : Int32
}

///|
/// 画册目录：左栏清单与右栏内容一一对应。增删组件时这里与
/// `gallery_code` / `gallery_demo` 一起动，`gallery_test.mbt`
/// 用长度钉住"目录不悄悄变"。
pub fn Gallery::section_names() -> Array[String] {
  [
    "Label 文本", "Button 按钮", "TextInput 输入框", "Checkbox 勾选框",
    "Row / Column 行列", "Padding / Center / Spacer", "Grid 网格", "Stack 层叠",
    "Scroll 滚动", "Slider 滑块", "Spinbox 数字输入", "Progress 进度条",
    "ComboBox 下拉选择", "PasswordInput 密码框", "Multiline 多行文本",
    "Separator 分隔线", "RadioButtons 单选钮", "DatePicker 日期时间", "RadioGroup 单选组",
    "Tabs 页签", "Steps 步骤条", "Alert 提示", "Card 卡片", "Breadcrumb 面包屑",
    "Pagination 分页", "Rate 评分",
  ]
}

///|
pub fn[B] Gallery::window(self : Gallery[B]) -> Window[B] {
  self.window
}

///|
pub fn[B] Gallery::current(self : Gallery[B]) -> Int32 {
  self.current
}

///|
pub fn[B] Gallery::click_count(self : Gallery[B]) -> Int32 {
  self.clicks
}

///|
pub fn[B] Gallery::echo_text(self : Gallery[B]) -> String {
  self.echo
}

///|
/// 组建画册：一只 960x480 的窗口，左清单右详情。构建完即 `show()`，
/// 真后端上 `app.run()` 进循环，mock 后端上直接断言。
///
/// 高度 480（2026-10-14 由 640 调小）：26 行 MenuRow 在 2x 屏上约 570 逻辑
/// 像素，640 逻辑高的窗恰好装得下，左栏的 Scroll（T74）无事可滚——不出
/// 滚动条、滚轮也无反应，看起来像坏了。480 让左栏必然溢出，真滚动条常驻。
pub fn[B : Backend] Gallery::demo(app : App[B]) -> Gallery[B] raise UiError {
  let window = app.create_window(
    "MoonUI 组件画册",
    LogicalSize(960.0, 480.0),
  )
  let g : Gallery[B] = {
    backend: app.backend(),
    window,
    current: 0,
    built: false,
    clicks: 0,
    echo: "",
    extra_enabled: true,
    slider_value: 20,
    spin_value: 3,
    progress_value: 0,
    combo_selected: 0,
    pwd_echo: "",
    multiline_echo: "",
    radio_btn_selected: 0,
    date_text: "2026-10-12 08:30:00",
    group_selected: 0,
    tabs_current: 0,
    steps_current: 0,
    alert_idx: 0,
    crumb_at: -1,
    page_now: 1,
    rate_value: 3,
  }
  g.refresh()
  window.show()
  g
}

///|
/// 切到某个组件页。越界的下标夹到 0；与当前页相同则不动（侧栏点击
/// 自己那一页不该重建树）。重建发生在事件回调里也是安全的：旧树的
/// 控件在 `set_content` 里整棵关闭，`fire` 对已关闭控件有闸门。
pub fn[B : Backend] Gallery::select(
  self : Gallery[B],
  index : Int32,
) -> Unit raise UiError {
  let n = Gallery::section_names().length()
  let i = if index < 0 || index >= n { 0 } else { index }
  if self.built && i == self.current {
    return
  }
  self.current = i
  if self.built {
    self.refresh()
  }
}

///|
/// 侧栏一组：一行一项的扁平菜单（macOS 设置那种"一行一个文本、选中高亮"的
/// 菜单感），不再是"一堆按钮"。每一项是一只 `MenuRow`——叶子控件、可点
/// （`on_click`）、选中态走 `checked` 通道（`menu_row` 构造时按 `selected` 设好）。
/// 选中高亮由后端画（原生后端是圆角强调色底，mock 不画但 `checked` 可读回），
/// 所以这里不再用 `●`/`○` 前缀表达选中——前缀是"按钮网格"时代的补丁，扁平菜单
/// 有真正的选中态了。
fn[B : Backend] Gallery::sidebar_group(
  self : Gallery[B],
  from : Int32,
  to : Int32,
) -> Widget[B] raise UiError {
  let b = self.backend
  let names = Gallery::section_names()
  let items : Array[Widget[B]] = []
  for i = from; i < to; i = i + 1 {
    let row = Widget::menu_row(b, names[i], i == self.current)
    let _ = row.on_click(fn() raise UiError { self.select(i) })
    items.push(row)
  }
  Widget::column(b, 2.0, items)
}

///|
/// 重建整棵内容树并挂回窗口。整棵树的形状：
///
/// ```text
/// Padding(16)
/// └ Row(12)
///   ├ 侧栏 Column(6)：「组件目录」头 + 横线 + 分组小标题 + 两列按钮网格
///   ├ VSeparator  ← 左右分界的那根线
///   └ 右栏 Column(8)：标题 + 横线 + 说明 + 代码 + 横线 + 效果（expand）
/// ```
fn[B : Backend] Gallery::refresh(self : Gallery[B]) -> Unit raise UiError {
  let b = self.backend
  // 左栏是 macOS 设置那种"一行一项"的扁平菜单：按目录的三段分成三组，每组
  // 一个小标题加一列 MenuRow（9 + 9 + 8）。单列 26 行装不进 480 高的窗，
  // 所以左栏整体包进竖向 Scroll（T74）：装不下的部分出真滚动条。
  let sidebar_list = Widget::column(b, 6.0, [
    Widget::label(b, "组件目录"),
    Widget::separator(b),
    Widget::label(b, "布局基础"),
    self.sidebar_group(0, 9),
    Widget::label(b, "原生控件"),
    self.sidebar_group(9, 18),
    Widget::label(b, "组合组件"),
    self.sidebar_group(18, 26),
  ])
  let sidebar = Widget::scroll(b, Axis::Vertical, sidebar_list)
  // 右栏同理：长代码页（示例代码 + 效果）也可能超过一屏，装不下的往下滚。
  let pane_body = self.build_pane(self.current)
  pane_body.set_expand(true)
  let pane = Widget::scroll(b, Axis::Vertical, pane_body)
  // 右栏吃行里剩下的全部宽度（expand 在 Row 里是主轴弹性），交叉轴（高度）
  // 由弹性项规则铺满行高——不标的话 Scroll 按内容宽度收口，右侧留白。
  pane.set_expand(true)
  let content = Widget::padding(
    b,
    EdgeInsets::all(16.0),
    Widget::row(b, 12.0, [sidebar, Widget::vseparator(b), pane]),
  )
  self.window.set_content(content)
  self.built = true
}

///|
/// 右栏一页：标题 + 说明 + 示例代码（一行一个 Label，跨平台最稳的
/// 多行文本——真后端的多行排版是 §20 的事）+ 真控件区，节与节之间
/// 用横线隔开——和左栏之间那根竖线一起，把"目录 | 内容"的两栏感立起来。
fn[B : Backend] Gallery::build_pane(
  self : Gallery[B],
  index : Int32,
) -> Widget[B] raise UiError {
  let b = self.backend
  let name = Gallery::section_names()[index]
  let code_lines : Array[Widget[B]] = []
  for line in gallery_code(index) {
    code_lines.push(Widget::label(b, line))
  }
  let code_block = Widget::column(b, 2.0, code_lines)
  let code_section = Widget::column(b, 4.0, [
    Widget::label(b, "示例代码："),
    code_block,
  ])
  let demo_section = Widget::column(b, 4.0, [
    Widget::label(b, "效果："),
    self.build_demo(index),
  ])
  Widget::column(b, 10.0, [
    Widget::label(b, "组件：" + name),
    Widget::label(b, gallery_blurb(index)),
    Widget::separator(b),
    code_section,
    Widget::separator(b),
    demo_section,
  ])
}

///|
/// 每页的一句话说明。
fn gallery_blurb(index : Int32) -> String {
  match index {
    0 => "只读文本。文案用 set_text 改，改了自动触发重排"
    1 => "按钮。on_click 订阅点击；set_enabled 控制可用性"
    2 => "单行输入框。on_input 每次文本变化都带全文回来"
    3 => "勾选框。on_change 订阅切换，checked 读回状态"
    4 => "两个方向的线性容器，spacing 只加在相邻子项之间"
    5 => "内边距、居中、弹性占位——三个纯装饰的布局节点"
    6 => "均匀网格。列数固定，子项按行填入"
    7 => "层叠容器：子项共用原点，数组靠后的画在上层"
    8 =>
      "滚动视口。内容按完整尺寸摆放，裁剪与滚动条属于后端"
    9 =>
      "滑块。范围建时定死，拖动产生 Change，值由 value() 回读"
    10 => "数字输入框。带上下箭头，行为同滑块"
    11 => "进度条。set_value 0–100，传 -1 进不定进度"
    12 => "下拉选择。选项建时定死，selected() 读回下标"
    13 =>
      "密码输入框。内容以圆点遮盖显示，文本通道与 TextInput 同一条"
    14 => "多行文本域。编辑产生 Input，每次带全文回来"
    15 => "分隔线。纯装饰，没有文案与交互"
    16 => "单选组。一组互斥的选项，一个原生控件"
    17 => "日期时间选择。值是 \"YYYY-MM-DD HH:MM:SS\" 文本"
    18 =>
      "RadioGroup：单选钮加一条当前选中的说明（组合组件）"
    19 =>
      "Tabs：页签头加分隔线加当前页，换页走整树重建（组合组件）"
    20 => "Steps：步骤条，圆点跟 current 走（组合组件）"
    21 =>
      "Alert：带情绪图标的提示条，set_type 原地换情绪（组合组件）"
    22 => "Card：标题 + 分隔线 + 内容（组合组件）"
    23 =>
      "Breadcrumb：除当前页外每段可点，点哪段回调哪个下标（组合组件）"
    24 =>
      "Pagination：页码平铺，当前页与边界禁用（组合组件）"
    _ => "Rate：点星打分，程序设值不回声（组合组件）"
  }
}

///|
/// 每页的示例代码（按行存，展示时一行一个 Label）。
/// 这里的代码就是教用户写的代码——必须与真控件区用的是同一套 API。
fn gallery_code(index : Int32) -> Array[String] {
  match index {
    0 =>
      [
        "let text = Widget::label(app.backend(), \"一段普通文本\")", "text.set_text(\"改文案\")  // 自动触发重排",
      ]
    1 =>
      [
        "let button = Widget::button(app.backend(), \"点我\")", "button.set_enabled(false)  // 禁用",
        "let _ = button.on_click(fn() raise UiError {", "  count = count + 1", "})",
      ]
    2 =>
      [
        "let input = Widget::text_input(app.backend(), \"\")", "let _ = input.on_input(fn(text) raise UiError {",
        "  echo.set_text(\"回显：\" + text)", "})",
      ]
    3 =>
      [
        "let box = Widget::checkbox(app.backend(), \"启用\", true)", "let _ = box.on_change(fn() raise UiError {",
        "  target.set_enabled(box.checked())", "})",
      ]
    4 =>
      [
        "Widget::row(b, 8.0, [label_a, label_b, label_c])", "Widget::column(b, 8.0, [row_1, row_2])",
      ]
    5 =>
      [
        "Widget::padding(b, EdgeInsets::all(16.0), child)", "Widget::center(b, child)",
        "Widget::row(b, 0.0, [left, Widget::spacer(b), right])",
      ]
    6 => ["Widget::grid(b, 3, 8.0, [", "  a, b, c,", "  d, e, f,", "])"]
    7 =>
      [
        "Widget::stack(b, [", "  Widget::label(b, \"底层\"),", "  Widget::button(b, \"浮在上层\"),",
        "])",
      ]
    8 =>
      [
        "Widget::scroll(b, Vertical, tall_column)", "// 内容按完整尺寸摆放；裁剪与滚动条由后端提供",
      ]
    9 =>
      [
        "let slider = Widget::slider(b, 0, 100)", "let _ = slider.on_change(fn() raise UiError {",
        "  readout.set_text(slider.value().to_string())", "})",
      ]
    10 =>
      [
        "let spin = Widget::spinbox(b, 0, 10)", "// 值通道与滑块同一条：set_value / value",
      ]
    11 =>
      [
        "let bar = Widget::progress(b)", "bar.set_value(30)  // 0..100；传 -1 进不定进度",
      ]
    12 =>
      [
        "let combo = Widget::combobox(b, [\"北京\", \"上海\"])", "combo.set_selected(1)  // 读写都是下标",
      ]
    13 =>
      [
        "let pwd = Widget::password_input(b, \"\")", "// 显示层由系统画圆点，文本通道与 TextInput 同一条",
      ]
    14 =>
      [
        "let area = Widget::multiline(b, \"\")", "let _ = area.on_input(fn(text) raise UiError { ... })",
      ]
    15 => ["Widget::separator(b)"]
    16 =>
      [
        "let radio = Widget::radio_buttons(b, [\"红\", \"绿\", \"蓝\"])", "radio.set_selected(0)",
      ]
    17 =>
      [
        "let picker = Widget::date_picker(b)", "picker.set_datetime_text(\"2026-10-12 08:30:00\")",
      ]
    18 =>
      [
        "let group = RadioGroup::new(b, [\"苹果\", \"香蕉\"], 0)", "let _ = group.on_change(fn(i) { ... })",
      ]
    19 =>
      [
        "let tabs = Tabs::new(b, [\"水果\"], [body])", "tabs.on_change(fn(i) raise UiError {",
        "  window.set_content(tabs.view())  // 换页整树重建", "})",
      ]
    20 =>
      [
        "let steps = Steps::new(b, [\"下单\", \"付款\"], 0)", "steps.set_current(1)  // 圆点原地重画，不重建树",
      ]
    21 =>
      [
        "let alert = Alert::new(b, AlertInfo, \"标题\", \"说明\")", "alert.set_type(AlertWarning)  // 原地换情绪",
      ]
    22 =>
      [
        "let card = Card::new(b, \"标题\", [child])", "card.set_title(\"新标题\")  // 标题原地改",
      ]
    23 =>
      [
        "let bc = Breadcrumb::new(b, [\"首页\", \"详情\"])", "let _ = bc.on_navigate(fn(i) { ... })",
      ]
    24 =>
      [
        "let pg = Pagination::new(b, 45, 10)", "pg.set_page(2)  // 程序设值夹紧、不回调",
      ]
    _ =>
      ["let rate = Rate::new(b, 5, 0)", "let _ = rate.on_change(fn(v) { ... })"]
  }
}

///|
/// 每页的真控件区。与 `gallery_code` 成对：示例代码写什么，这里就真用什么。
fn[B : Backend] Gallery::build_demo(
  self : Gallery[B],
  index : Int32,
) -> Widget[B] raise UiError {
  let b = self.backend
  match index {
    0 => {
      let plain = Widget::label(b, "一段普通文本")
      let mut_text = Widget::label(b, "我会变")
      let btn = Widget::button(b, "改文案")
      let _ = btn.on_click(fn() raise UiError {
        mut_text.set_text("文案改了（set_text 自动重排）")
      })
      Widget::column(b, 8.0, [plain, mut_text, btn])
    }
    1 => {
      let counter = Widget::label(
        b,
        "点击次数：" + self.clicks.to_string(),
      )
      let btn = Widget::button(b, "点我")
      let _ = btn.on_click(fn() raise UiError {
        self.clicks = self.clicks + 1
        counter.set_text("点击次数：" + self.clicks.to_string())
      })
      let disabled = Widget::button(b, "禁用的按钮")
      disabled.set_enabled(false)
      Widget::column(b, 8.0, [counter, btn, disabled])
    }
    2 => {
      let input = Widget::text_input(b, "")
      let echo = Widget::label(
        b,
        if self.echo == "" {
          "回显：（等待输入）"
        } else {
          "回显：" + self.echo
        },
      )
      let _ = input.on_input(fn(text) raise UiError {
        self.echo = text
        echo.set_text("回显：" + text)
      })
      Widget::column(b, 8.0, [input, echo])
    }
    3 => {
      let victim = Widget::label(b, "被勾选框控制的文本")
      victim.set_enabled(self.extra_enabled)
      let box = Widget::checkbox(b, "启用上面的文本", self.extra_enabled)
      let _ = box.on_change(fn() raise UiError {
        self.extra_enabled = box.checked()
        victim.set_enabled(box.checked())
      })
      Widget::column(b, 8.0, [victim, box])
    }
    4 => {
      let r = Widget::row(b, 8.0, [
        Widget::label(b, "左"),
        Widget::label(b, "中"),
        Widget::label(b, "右"),
      ])
      let c = Widget::column(b, 4.0, [
        Widget::label(b, "第一行"),
        Widget::label(b, "第二行"),
      ])
      Widget::column(b, 8.0, [r, c])
    }
    5 => {
      let padded = Widget::padding(
        b,
        EdgeInsets::all(16.0),
        Widget::button(b, "四周 16 点内边距"),
      )
      let centered = Widget::center(b, Widget::label(b, "我在正中"))
      let spaced = Widget::row(b, 0.0, [
        Widget::label(b, "贴左"),
        Widget::spacer(b),
        Widget::label(b, "贴右"),
      ])
      Widget::column(b, 8.0, [padded, centered, spaced])
    }
    6 =>
      Widget::grid(b, 3, 8.0, [
        Widget::label(b, "1"),
        Widget::label(b, "2"),
        Widget::label(b, "3"),
        Widget::label(b, "4"),
        Widget::label(b, "5"),
        Widget::label(b, "6"),
        Widget::label(b, "7"),
        Widget::label(b, "8"),
        Widget::label(b, "9"),
      ])
    7 =>
      Widget::stack(b, [
        Widget::label(b, "底层文本"),
        Widget::button(b, "浮在上层的按钮"),
      ])
    8 => {
      let rows : Array[Widget[B]] = []
      for i = 1; i <= 12; i = i + 1 {
        rows.push(Widget::label(b, "第 " + i.to_string() + " 行"))
      }
      Widget::scroll(b, Vertical, Widget::column(b, 4.0, rows))
    }
    9 => {
      let slider = Widget::slider(b, 0, 100)
      slider.set_value(self.slider_value)
      let readout = Widget::label(
        b,
        "当前值：" + self.slider_value.to_string(),
      )
      let _ = slider.on_change(fn() raise UiError {
        // 通知不带内容（§48-16），值回读原生控件
        self.slider_value = slider.value()
        readout.set_text("当前值：" + self.slider_value.to_string())
      })
      Widget::column(b, 8.0, [slider, readout])
    }
    10 => {
      let spin = Widget::spinbox(b, 0, 10)
      spin.set_value(self.spin_value)
      let readout = Widget::label(
        b,
        "当前值：" + self.spin_value.to_string(),
      )
      let _ = spin.on_change(fn() raise UiError {
        self.spin_value = spin.value()
        readout.set_text("当前值：" + self.spin_value.to_string())
      })
      Widget::column(b, 8.0, [spin, readout])
    }
    11 => {
      let bar = Widget::progress(b)
      bar.set_value(self.progress_value)
      let readout = Widget::label(
        b,
        "当前进度：" + self.progress_value.to_string() + "%",
      )
      let plus = Widget::button(b, "进度 +10")
      let _ = plus.on_click(fn() raise UiError {
        // 超过 100 回到 0，让按钮永远按得下去
        self.progress_value = if self.progress_value + 10 > 100 {
          0
        } else {
          self.progress_value + 10
        }
        bar.set_value(self.progress_value)
        readout.set_text(
          "当前进度：" + self.progress_value.to_string() + "%",
        )
      })
      Widget::column(b, 8.0, [readout, bar, plus])
    }
    12 => {
      let options = ["北京", "上海", "广州"]
      let combo = Widget::combobox(b, options)
      combo.set_selected(self.combo_selected)
      let readout = Widget::label(b, "当前：" + options[self.combo_selected])
      let _ = combo.on_change(fn() raise UiError {
        self.combo_selected = combo.selected()
        readout.set_text("当前：" + options[self.combo_selected])
      })
      Widget::column(b, 8.0, [combo, readout])
    }
    13 => {
      let input = Widget::password_input(b, "")
      let readout = Widget::label(
        b,
        if self.pwd_echo == "" {
          "密码长度：（等待输入）"
        } else {
          "密码长度：" + self.pwd_echo.length().to_string()
        },
      )
      let _ = input.on_input(fn(text) raise UiError {
        self.pwd_echo = text
        // 回显只报长度，不回明文——密码框的示范就该这样写
        readout.set_text("密码长度：" + text.length().to_string())
      })
      Widget::column(b, 8.0, [input, readout])
    }
    14 => {
      let area = Widget::multiline(b, self.multiline_echo)
      let readout = Widget::label(
        b,
        if self.multiline_echo == "" {
          "字符数：（等待输入）"
        } else {
          "字符数：" + self.multiline_echo.length().to_string()
        },
      )
      let _ = area.on_input(fn(text) raise UiError {
        self.multiline_echo = text
        readout.set_text("字符数：" + text.length().to_string())
      })
      Widget::column(b, 8.0, [area, readout])
    }
    15 =>
      Widget::column(b, 8.0, [
        Widget::label(b, "上面一段"),
        Widget::separator(b),
        Widget::label(b, "下面一段"),
      ])
    16 => {
      let options = ["红", "绿", "蓝"]
      let radio = Widget::radio_buttons(b, options)
      radio.set_selected(self.radio_btn_selected)
      let readout = Widget::label(
        b,
        "当前：" + options[self.radio_btn_selected],
      )
      let _ = radio.on_change(fn() raise UiError {
        self.radio_btn_selected = radio.selected()
        readout.set_text("当前：" + options[self.radio_btn_selected])
      })
      Widget::column(b, 8.0, [radio, readout])
    }
    17 => {
      let picker = Widget::date_picker(b)
      picker.set_datetime_text(self.date_text)
      let readout = Widget::label(b, "当前：" + self.date_text)
      let _ = picker.on_change(fn() raise UiError {
        self.date_text = picker.datetime_text()
        readout.set_text("当前：" + self.date_text)
      })
      Widget::column(b, 8.0, [picker, readout])
    }
    18 => {
      let group = RadioGroup::new(
        b,
        ["苹果", "香蕉", "樱桃"],
        self.group_selected,
      )
      group.on_change(fn(i) { self.group_selected = i })
      group.view()
    }
    19 => {
      let tabs = Tabs::new(b, ["水果", "蔬菜"], [
        fn() raise UiError { Widget::label(b, "苹果页") },
        fn() raise UiError { Widget::label(b, "菠菜页") },
      ])
      tabs.select(self.tabs_current)
      tabs.on_change(fn(i) raise UiError {
        self.tabs_current = i
        // 换页整树重建（§8 没有摘除 API），树是耗材、下标不是
        self.refresh()
      })
      tabs.view()
    }
    20 => {
      let steps = Steps::new(
        b,
        ["下单", "付款", "发货", "收货"],
        self.steps_current,
      )
      let next = Widget::button(b, "下一步")
      let _ = next.on_click(fn() raise UiError {
        // 越界由 set_current 自己夹
        self.steps_current = self.steps_current + 1
        steps.set_current(self.steps_current)
      })
      Widget::column(b, 8.0, [steps.view(), next])
    }
    21 => {
      let alert = Alert::new(
        b,
        alert_type_of(self.alert_idx),
        "订单已提交",
        "我们会尽快发货",
      )
      let cycle = Widget::button(b, "换一种情绪")
      let _ = cycle.on_click(fn() raise UiError {
        self.alert_idx = (self.alert_idx + 1) % 4
        alert.set_type(alert_type_of(self.alert_idx))
      })
      Widget::column(b, 8.0, [alert.view(), cycle])
    }
    22 => {
      let card = Card::new(b, "订单详情", [
        Widget::label(b, "商品：MoonBit 语录"),
        Widget::label(b, "金额：42"),
      ])
      let rename = Widget::button(b, "改标题")
      let _ = rename.on_click(fn() raise UiError {
        card.set_title("会员详情")
      })
      Widget::column(b, 8.0, [card.view(), rename])
    }
    23 => {
      let items = ["首页", "组件", "画册"]
      let bc = Breadcrumb::new(b, items)
      let where_label = Widget::label(
        b,
        if self.crumb_at < 0 {
          "（没点过）"
        } else {
          "去往：" + items[self.crumb_at]
        },
      )
      bc.on_navigate(fn(i) raise UiError {
        self.crumb_at = i
        where_label.set_text("去往：" + items[i])
      })
      Widget::column(b, 8.0, [bc.view(), where_label])
    }
    24 => {
      let pg = Pagination::new(b, 45, 10)
      pg.set_page(self.page_now)
      pg.on_change(fn(p) { self.page_now = p })
      pg.view()
    }
    _ => {
      let rate = Rate::new(b, 5, self.rate_value)
      rate.on_change(fn(v) { self.rate_value = v })
      Widget::column(b, 8.0, [
        rate.view(),
        Widget::label(b, "点星打分；程序设值（set_value）不回声"),
      ])
    }
  }
}

///|
/// Alert 页当前情绪：alert_idx 0..3 轮转，越界当 Error。
fn alert_type_of(index : Int32) -> AlertType {
  match index {
    0 => AlertInfo
    1 => AlertSuccess
    2 => AlertWarning
    _ => AlertError
  }
}
