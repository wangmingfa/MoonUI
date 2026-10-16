// Playground 双档的黑盒判据（`demo_playground.mbt` 的 Demo 本体随包判据）：
// 全部走公开 API（`@moonui.` 前缀）在 MockBackend 上无头判定——
// 硬判据①解析→构树→与手构树逐位同值（dump_layout 逐行相等 + 样式账逐位）；
// 硬判据②错误显式报错带位置（四条负控制）；硬判据③空/空白描述显式缺席；
// 面板闭环的 Mock 判据（命中反查选中账、面板读回账、改值→描述变→重建→新
// 参数生效）。同款 Backends 两只并排（各自全新句柄表）——dump 里的句柄 id
// 是全局序，两只全新后端同序构树才逐字符可比（判据的构造账注释见各块）。

///|
/// 判据助手：子树种类清单（AST 半的覆盖检查用）。
fn pg_kinds(node : @moonui.PlayNode, out : Array[String]) -> Unit {
  out.push(node.kind)
  for k in node.children {
    pg_kinds(k, out)
  }
}

///|
fn pg_contains(xs : Array[String], want : String) -> Bool {
  for x in xs {
    if x == want {
      return true
    }
  }
  false
}

///|
/// 矩形中心点（命中反查判据按中心投点——frame.contains 边界语义不猜）。
fn pg_center(f : @moonui.LogicalRect) -> @moonui.LogicalPoint {
  @moonui.LogicalPoint(
    f.origin.x + f.size.width / 2.0,
    f.origin.y + f.size.height / 2.0,
  )
}

///|
/// 硬判据①（dump 半）：解析→构树→与 MoonBit 脸手构树**逐位同值**——
/// 两只全新 Mock 后端各自构同一棵树（种类盖通用构造族 9 个、嵌套
/// children、四向参数），dump_layout 逐字符相等。句柄序是判据的构造账：
/// DSL 构树 children 按声明顺序递归构，与手构数组字面量的求值序同账，
/// 两只全新后端的句柄 id 同序——dump 里的 id 列因此逐行可比。
test "DSL 构树与手构树逐位同值：dump 逐行相等（T83脸·硬判据①dump半）" {
  let desc = "Column(8, [\n  Text(\"Hello\").font_size(18),\n  Padding(12, [Row(4, [Button(\"Click\"), CheckBox(\"启用\", true)])]),\n  Row(8, [Slider(0, 100), ProgressBar(), ComboBox([\"标准\"]), RadioButtons([\"渠道一\"]), MenuRow(\"原生控件\", false)]),\n])"
  // DSL 半：解析→构树→摆上窗口→dump
  let b1 = @moonui.MockBackend::new()
  @moonui.Backend::init(b1)
  let app1 = @moonui.App::new(b1)
  let win1 = app1.create_window("DSL树", @moonui.LogicalSize(800.0, 600.0))
  win1.set_content(@moonui.PlayNode::build(b1, @moonui.PlayNode::parse(desc)))
  let dsl_dump = win1.dump_layout()
  // 手构半：同一棵树按 MoonBit 脸手写（T83 的形状公约——身份参数走构造、
  // 外观走链），摆上另一只窗口→dump
  let b2 = @moonui.MockBackend::new()
  @moonui.Backend::init(b2)
  let app2 = @moonui.App::new(b2)
  let win2 = app2.create_window("手构树", @moonui.LogicalSize(800.0, 600.0))
  win2.set_content(
    @moonui.Widget::column(b2, 8.0, [
      @moonui.Widget::label(b2, "Hello").font_size(18.0),
      @moonui.Widget::padding(
        b2,
        @moonui.EdgeInsets::all(12.0),
        @moonui.Widget::row(b2, 4.0, [
          @moonui.Widget::button(b2, "Click"),
          @moonui.Widget::checkbox(b2, "启用", true),
        ]),
      ),
      @moonui.Widget::row(b2, 8.0, [
        @moonui.Widget::slider(b2, 0, 100),
        @moonui.Widget::progress(b2),
        @moonui.Widget::combobox(b2, ["标准"]),
        @moonui.Widget::radio_buttons(b2, ["渠道一"]),
        @moonui.Widget::menu_row(b2, "原生控件", false),
      ]),
    ]),
  )
  let hand_dump = win2.dump_layout()
  // 逐位同值：dump 逐字符相等（种类/句柄序/frame/spacing/insets/文本/
  // 命中标记全在逐行账里——mock 度量确定性，同树同账）
  assert_eq(dsl_dump, hand_dump)
  @moonui.Backend::terminate(b1)
  @moonui.Backend::terminate(b2)
  assert_eq(b1.live(), 0)
  assert_eq(b2.live(), 0)
}

///|
/// 硬判据①（链半）：11 条外观链逐位同值——单节点盖满 11 条，dump 相等之外
/// 再断样式账逐位（dump 不显样式字段，样式账靠这条兜底；margin 的消费账
/// 非零值进 dump 逐行账，dump 相等本身含它）。
test "DSL 外观链 11 条逐位同值：样式账逐位（T83脸·硬判据①链半）" {
  let desc = "Text(\"账\").font_size(18).font_weight(Bold).foreground(#C81E1E).background(#F4F5F7).opacity(0.5).radius(8).width(120).height(40).min_width(80).max_width(240).margin(8)"
  let b1 = @moonui.MockBackend::new()
  @moonui.Backend::init(b1)
  let app1 = @moonui.App::new(b1)
  let win1 = app1.create_window("DSL链", @moonui.LogicalSize(400.0, 300.0))
  win1.set_content(@moonui.PlayNode::build(b1, @moonui.PlayNode::parse(desc)))
  let dsl_dump = win1.dump_layout()
  let dsl_style = match win1.content() {
    Some(root) => root.style()
    None => {
      assert_true(false) // unreachable
      None
    }
  }
  let b2 = @moonui.MockBackend::new()
  @moonui.Backend::init(b2)
  let app2 = @moonui.App::new(b2)
  let win2 = app2.create_window("手构链", @moonui.LogicalSize(400.0, 300.0))
  win2.set_content(
    @moonui.Widget::label(b2, "账")
    .font_size(18.0)
    .font_weight(@moonui.FontWeight::Bold)
    .foreground(@moonui.Color::rgb(200, 30, 30))
    .background(@moonui.Color::rgb(244, 245, 247))
    .opacity(0.5)
    .radius(8.0)
    .width(120.0)
    .height(40.0)
    .min_width(80.0)
    .max_width(240.0)
    .margin(@moonui.EdgeInsets::all(8.0)),
  )
  let hand_dump = win2.dump_layout()
  assert_eq(dsl_dump, hand_dump)
  let hand_style = match win2.content() {
    Some(root) => root.style()
    None => {
      assert_true(false) // unreachable
      None
    }
  }
  // 样式账逐位：11 条链的字段全部 Some 且同值（描述账 = 控件账）
  assert_eq(hand_style, dsl_style)
  assert_eq(
    hand_style,
    Some(
      @moonui.style(
        font_size=Some(18.0),
        font_weight=Some(@moonui.FontWeight::Bold),
        foreground=Some(@moonui.Color::rgb(200, 30, 30)),
        background=Some(@moonui.Color::rgb(244, 245, 247)),
        opacity=Some(0.5),
        radius=Some(8.0),
        width=Some(120.0),
        height=Some(40.0),
        min_width=Some(80.0),
        max_width=Some(240.0),
        margin=Some(@moonui.EdgeInsets::all(8.0)),
      ),
    ),
  )
  @moonui.Backend::terminate(b1)
  @moonui.Backend::terminate(b2)
  assert_eq(b1.live(), 0)
  assert_eq(b2.live(), 0)
}

///|
/// 解析账的形状判据：AST（种类×构造参数×链）逐字段断——值档按文法定稿表
/// 钉形状（四值 insets 的字段序、margin 单值形、字符串数组形）。
test "DSL 解析账：AST 形状（种类×构造参数×链）" {
  let ast = @moonui.PlayNode::parse("CheckBox(\"启用\", true).font_size(14)")
  assert_eq(ast.kind, "CheckBox")
  assert_eq(ast.params, [
    @moonui.PlayValue::Str("启用"),
    @moonui.PlayValue::Bool(true),
  ])
  assert_eq(ast.children, [])
  assert_eq(ast.chains.length(), 1)
  assert_eq(ast.chains[0].name, "font_size")
  assert_eq(ast.chains[0].value, @moonui.PlayValue::Num(14.0))
  // 四值 insets（字段序 top,end,bottom,start）与 margin 单值形
  let ast2 = @moonui.PlayNode::parse(
    "Padding(16, 0, 16, 0, [Text(\"x\").margin(8)])",
  )
  assert_eq(ast2.kind, "Padding")
  assert_eq(ast2.params, [@moonui.PlayValue::NumList([16.0, 0.0, 16.0, 0.0])])
  assert_eq(ast2.children.length(), 1)
  assert_eq(ast2.children[0].kind, "Text")
  assert_eq(ast2.children[0].chains[0].value, @moonui.PlayValue::NumList([8.0]))
  // 嵌套 children 递归（数组按声明顺序）
  let ast3 = @moonui.PlayNode::parse(
    "Row(4, [Text(\"a\"), Column(0, [Text(\"b\")])])",
  )
  assert_eq(ast3.kind, "Row")
  assert_eq(ast3.params, [@moonui.PlayValue::Num(4.0)])
  assert_eq(ast3.children.length(), 2)
  assert_eq(ast3.children[0].kind, "Text")
  assert_eq(ast3.children[1].kind, "Column")
  assert_eq(ast3.children[1].children[0].kind, "Text")
  // ProgressBar 的空括号
  let ast4 = @moonui.PlayNode::parse("ProgressBar()")
  assert_eq(ast4.kind, "ProgressBar")
  assert_eq(ast4.params, [])
}

///|
/// 面板缝合法判据：解析账 → 序列化成描述 → 再解析 → 构树 dump 逐字符相等
/// （序列化输出闭合于文法——重建走的就是这条往返）；顺带钉 DEFAULT 描述的
/// 单行规范形（面板改值后描述变的形状就在这条措辞上）。
test "DSL 往返：序列化再解析构树同值（面板缝合法判据）" {
  let ast1 = @moonui.PlayNode::parse(@moonui.PLAYGROUND_DEFAULT_DESC)
  let text2 = ast1.to_dsl()
  assert_eq(
    text2, "Column(12, [Text(\"Playground\").font_size(18).font_weight(Bold).foreground(#30343C), Row(8, [Button(\"点我\"), CheckBox(\"启用\", true), ComboBox([\"标准\", \"兼容\"]), RadioButtons([\"渠道一\", \"渠道二\"]), MenuRow(\"原生控件\", false)]), Row(8, [Slider(0, 100), ProgressBar()]), Padding(16, [Text(\"内缩区\").background(#F4F5F7).radius(8).opacity(0.9).margin(8)])])",
  )
  let b1 = @moonui.MockBackend::new()
  @moonui.Backend::init(b1)
  let app1 = @moonui.App::new(b1)
  let win1 = app1.create_window("往返甲", @moonui.LogicalSize(900.0, 640.0))
  win1.set_content(
    @moonui.PlayNode::build(
      b1,
      @moonui.PlayNode::parse(@moonui.PLAYGROUND_DEFAULT_DESC),
    ),
  )
  let dump1 = win1.dump_layout()
  let b2 = @moonui.MockBackend::new()
  @moonui.Backend::init(b2)
  let app2 = @moonui.App::new(b2)
  let win2 = app2.create_window("往返乙", @moonui.LogicalSize(900.0, 640.0))
  win2.set_content(@moonui.PlayNode::build(b2, @moonui.PlayNode::parse(text2)))
  let dump2 = win2.dump_layout()
  assert_eq(dump1, dump2)
  @moonui.Backend::terminate(b1)
  @moonui.Backend::terminate(b2)
  assert_eq(b1.live(), 0)
  assert_eq(b2.live(), 0)
}

///|
/// 硬判据②：错误显式报错带位置（§33 不静默）——四条负控制逐条断全文：
/// 未知种类、缺括号（children 必需）、缺参数（点名种类与参数名）、链名
/// 不存在。位置形状 = 第几个记号 + 字符偏移。
test "DSL 错误报告显式带位置（§33·四条负控制）" {
  let msgs : Array[String] = []
  // ① 未知种类 Foo
  try {
    let _ = @moonui.PlayNode::parse("Foo(\"x\")")
    msgs.push("no error")
  } catch {
    e => msgs.push(e.message())
  }
  // ② 缺括号：Row 的 children 必需—— Ident 顶到 `[` 的位置
  try {
    let _ = @moonui.PlayNode::parse("Row(8, Label(\"x\"))")
    msgs.push("no error")
  } catch {
    e => msgs.push(e.message())
  }
  // ③ 缺参数：Slider 只给了 min——缺 max
  try {
    let _ = @moonui.PlayNode::parse("Slider(8)")
    msgs.push("no error")
  } catch {
    e => msgs.push(e.message())
  }
  // ④ 链名不存在：font_sz 不在 11 条链的白名单里
  try {
    let _ = @moonui.PlayNode::parse("Text(\"x\").font_sz(18)")
    msgs.push("no error")
  } catch {
    e => msgs.push(e.message())
  }
  assert_eq(msgs, [
    "操作失败：playground DSL：第 1 个记号（偏移 0）：未知种类 Foo",
    "操作失败：playground DSL：第 5 个记号（偏移 7）：缺少 `[`（Row 的 children——收到 Label）",
    "操作失败：playground DSL：第 4 个记号（偏移 8）：缺少参数 max（Slider）",
    "操作失败：playground DSL：第 6 个记号（偏移 10）：链名不存在 font_sz",
  ])
}

///|
/// 硬判据③：空描述与空白描述的显式缺席——两份输入同一条缺席报错，
/// 不许静默解析成空树。
test "空描述与空白描述显式缺席（§33·缺席判据③）" {
  let msgs : Array[String] = []
  try {
    let _ = @moonui.PlayNode::parse("")
    msgs.push("no error")
  } catch {
    e => msgs.push(e.message())
  }
  try {
    let _ = @moonui.PlayNode::parse("  \n\t ")
    msgs.push("no error")
  } catch {
    e => msgs.push(e.message())
  }
  assert_eq(msgs, [
    "操作失败：playground DSL：空描述（显式缺席——要构树请给一段种类调用）",
    "操作失败：playground DSL：空描述（显式缺席——要构树请给一段种类调用）",
  ])
}

///|
/// 面板闭环 Mock 判据·命中反查选中账：真命中（按选中控件 frame 中心投点，
/// `Window::widget_at`——`T86①` 右键命中反查同族）→ 选中账；未命中显式记
/// 状态且选中不变；面板区域的点击显式点名不进选中账。
test "PlaygroundDemo：命中反查选中账（Mock判据·选中）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.PlaygroundDemo::demo(
    app, "Row(8, [Button(\"点我\"), CheckBox(\"启用\", true)])",
  )
  assert_eq(demo.selected_kind(), None)
  match demo.window().content() {
    None => assert_true(false) // unreachable
    Some(root) => {
      // 真命中：Button 叶子（内容根 = root.children[0]，Button 是它的第 0 格）。
      // 读 frame 在 select 之前——select_at 每次都重建整棵内容根，旧树引用
      // 随 close_tree 归账（§8），判据每次重建后重新取窗内容。
      let btn = root.children()[0].children()[0]
      demo.select_at(pg_center(btn.frame()))
      assert_eq(demo.selected_kind(), Some("Button"))
      assert_eq(demo.status_line(), "已选中 Button")
    }
  }
  // 未命中：投到窗内容树外的角落——显式记状态、选中不变
  demo.select_at(@moonui.LogicalPoint(899.0, 639.0))
  assert_eq(
    demo.status_line(),
    "未命中：点击没有落进内容树控件（选中不变）",
  )
  assert_eq(demo.selected_kind(), Some("Button"))
  // 面板区域的点击（重建后的面板第 0 行是 Label 叶子）：显式点名不进选中账
  match demo.window().content() {
    None => assert_true(false) // unreachable
    Some(root) => {
      let pnl = root.children()[1]
      demo.select_at(pg_center(pnl.children()[0].frame()))
    }
  }
  assert_eq(demo.status_line(), "未命中：面板区域点击不进选中账")
  assert_eq(demo.selected_kind(), Some("Button"))
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 面板闭环 Mock 判据·面板读回账：选中控件当下的可改参数逐行读回（panel_rows
/// 与面板显示共用一套账）+ 控件样式账读回（描述账 = 控件账同值）；缺席链读
/// None（显式缺席）。
test "PlaygroundDemo：面板读回账（Mock判据·读回）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.PlaygroundDemo::demo(
    app, "Text(\"Hello\").font_size(18).foreground(#C81E1E)",
  )
  match demo.window().content() {
    None => assert_true(false) // unreachable
    Some(root) => {
      // 描述根是 Text——内容根就是这只 Label 叶子
      let leaf = root.children()[0]
      demo.select_at(pg_center(leaf.frame()))
      assert_eq(demo.selected_kind(), Some("Text"))
      assert_eq(demo.chain_value("font_size"), Some("18"))
      assert_eq(demo.chain_value("foreground"), Some("#C81E1E"))
      assert_eq(demo.chain_value("font_weight"), None)
      assert_eq(demo.panel_rows(), [
        "选中：Text", "text=Hello", "font_size=18", "foreground=#C81E1E", "状态：已选中 Text",
      ])
      // 控件样式账读回：读回值与描述账同值（面板读回账的树半）
      match demo.selected_widget() {
        Some(w) =>
          assert_eq(
            w.style(),
            Some(
              @moonui.style(
                font_size=Some(18.0),
                foreground=Some(@moonui.Color::rgb(200, 30, 30)),
              ),
            ),
          )
        None => assert_true(false) // unreachable
      }
    }
  }
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 面板闭环 Mock 判据·改值→描述变→重建→新参数生效：面板改一条链值 → 描述
/// 变（规范措辞逐字符断）→ 选中按路径幸存 → 样式账与 frame 账生效（mock
/// 度量确定性：font_size 24 → "Hello" 5 码元 × 8 × 2 + 8 = 88 宽、20 × 2 =
/// 40 高）；无效值显式挡下（描述不变、状态行点名收到什么）；text 参数改值
/// 同账；用户路径（重建后的面板输入框派 `Input`）与程序路径共账。
test "PlaygroundDemo：面板改值→描述变→重建→新参数生效（Mock判据·闭环）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.PlaygroundDemo::demo(app, "Text(\"Hello\").font_size(18)")
  match demo.window().content() {
    None => assert_true(false) // unreachable
    Some(root) => {
      let leaf = root.children()[0]
      demo.select_at(pg_center(leaf.frame()))
      assert_eq(demo.selected_kind(), Some("Text"))
    }
  }
  // 改值 → 描述变（面板改值 = 改描述）→ 选中幸存 → 状态行显式
  demo.panel_edit_chain("font_size", "24")
  assert_eq(demo.description(), "Text(\"Hello\").font_size(24)")
  assert_eq(demo.selected_kind(), Some("Text"))
  assert_eq(demo.status_line(), "已改 font_size=24")
  // 新参数生效：样式账 Some(24) + frame 账（mock 度量确定性逐位断）
  match demo.selected_widget() {
    Some(w) => {
      match w.style() {
        Some(s) => assert_eq(s.font_size, Some(24.0))
        None => assert_true(false) // unreachable
      }
      let f = w.frame()
      assert_eq(f.size.width, 88.0)
      assert_eq(f.size.height, 40.0)
    }
    None => assert_true(false) // unreachable
  }
  // 无效值显式挡下：描述不变、状态行点名收到什么（§33 不静默）
  demo.panel_edit_chain("font_size", "24x")
  assert_eq(
    demo.status_line(),
    "改值未生效：font_size 的值是数字（收到 24x）",
  )
  assert_eq(demo.description(), "Text(\"Hello\").font_size(24)")
  // text 参数改值同账
  demo.panel_edit_text("明")
  assert_eq(demo.description(), "Text(\"明\").font_size(24)")
  assert_eq(demo.status_line(), "已改 text=明")
  // 用户路径共账：重建后的面板 font_size 行是 TextInput（真控件），派
  // `Input` 走同一条编辑账。面板列的结构：[选中 Label, text 行, font_size
  // 行, 状态 Label]，font_size 行 = [Label, TextInput]。
  match demo.window().content() {
    None => assert_true(false) // unreachable
    Some(root) => {
      let pnl = root.children()[1]
      let input = pnl.children()[2].children()[1]
      assert_eq(input.kind(), @moonui.WidgetKind::TextInput)
      let _ = input.fire(@moonui.Event::Input(input.target(), "30"))
      assert_eq(demo.description(), "Text(\"明\").font_size(30)")
      assert_eq(demo.status_line(), "已改 font_size=30")
      assert_eq(demo.chain_value("font_size"), Some("30"))
    }
  }
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 双壳共用描述的完整闭环：PLAYGROUND_DEFAULT_DESC 解析账盖 10 个种类
/// （ProgressBar 之外全齐——头注记案的缺席形状不在描述里）、选中 Button 走
/// 枚举链的 ComboBox 半（font_weight 换 Medium）、选中"内缩区"走 margin 的
/// 四值编辑（单值形 → 四值形）——描述变、读回变、状态行显式。
test "PlaygroundDemo：默认描述全种类闭环（Mock判据·双壳描述）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.PlaygroundDemo::demo(app, @moonui.PLAYGROUND_DEFAULT_DESC)
  // 解析账的种类覆盖（AST 半）
  let kinds : Array[String] = []
  pg_kinds(@moonui.PlayNode::parse(@moonui.PLAYGROUND_DEFAULT_DESC), kinds)
  for
    kind in [
      "Column", "Text", "Row", "Button", "CheckBox", "ComboBox", "RadioButtons",
      "MenuRow", "Slider", "ProgressBar", "Padding",
    ] {
    assert_true(pg_contains(kinds, kind))
  }
  match demo.window().content() {
    None => assert_true(false) // unreachable
    Some(root) => {
      // 选中 Text("Playground")（内容根 Column 的 children[0]——font_weight /
      // foreground 链在这只节点上；Button 无链，编辑缺席半在面板读回块已判）
      let head = root.children()[0].children()[0]
      demo.select_at(pg_center(head.frame()))
      assert_eq(demo.selected_kind(), Some("Text"))
      // 枚举链的编辑（程序路径）——描述变、读回变、状态行显式
      demo.panel_edit_chain("font_weight", "Medium")
      assert_eq(demo.chain_value("font_weight"), Some("Medium"))
      assert_eq(demo.status_line(), "已改 font_weight=Medium")
      // 枚举链的非法值显式挡下
      demo.panel_edit_chain("font_weight", "Fat")
      assert_eq(
        demo.status_line(),
        "改值未生效：font_weight 的值是 Regular/Medium/Bold（收到 Fat）",
      )
      assert_eq(demo.chain_value("font_weight"), Some("Medium"))
    }
  }
  // 选中"内缩区"（重建后的内容根：children[3] 是 Padding，单孩子是 Text）——
  // margin 单值形读回、四值形编辑
  match demo.window().content() {
    None => assert_true(false) // unreachable
    Some(root) => {
      let inset = root.children()[0].children()[3].children()[0]
      demo.select_at(pg_center(inset.frame()))
    }
  }
  assert_eq(demo.selected_kind(), Some("Text"))
  assert_eq(demo.chain_value("margin"), Some("8"))
  demo.panel_edit_chain("margin", "8,0,8,0")
  assert_eq(demo.chain_value("margin"), Some("8,0,8,0"))
  assert_eq(demo.status_line(), "已改 margin=8,0,8,0")
  // 面板行读回含 text 参数与四值 margin（面板读回账逐行断）
  assert_eq(demo.panel_rows(), [
    "选中：Text", "text=内缩区", "background=#F4F5F7", "radius=8", "opacity=0.9",
    "margin=8,0,8,0", "状态：已改 margin=8,0,8,0",
  ])
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}
