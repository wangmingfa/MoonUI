///|
/// 自绘 UI 套件的真窗口画册（`T352`）：`moon run examples/ui-kit-native`。
///
/// 这一页把 `packages/widgets/ui_*` 一批自绘控件按"能一起用"的顺序摆一遍：
/// 按钮 / 勾选框 / 开关 / 单选 / 分段 / 页签 / 进度 / 角标 / 输入框 / 数字框 /
/// 滑块 / 卡片 / 提示条 / 步骤条 / 面包屑 / 分页 / 评分 / 骨架屏 / 轻提示，
/// 末尾还有四只更早的住户（环 / 折线 / 树 / 表格）——`T361` 之后它们也吃同一
/// 套令牌。
/// 每组的交互都真的接上了旁边的读数——不是为了"能点"，而是为了让人一眼看出
/// "这套控件的状态是活的"：
/// - 主按钮点一下，底部状态行报次数；
/// - 勾上「禁用主按钮」，那颗按钮当场变灰且点不动（`set_enabled` 走同一条色账）；
/// - 分段控件换一档，进度条跟着变（同一个 `set_value`，与值域无关）；
/// - 数字框打字的合法值也直接推给进度条（范围外的半成品在失焦时洗回）；
/// - 滑块拖动 / 左右键 / Home·End 改值，底部状态行跟着报数；
/// - 面包屑点项、步骤条点节点、评分点星、分页翻页，底部都各报一条。
///
/// 令牌从 `UiTheme::light()` 起手；底部那颗「切到深色」会把每只控件逐个推一份
/// `UiTheme::dark()`（每只都实现了 `set_theme`，尺寸按新字号重算），不重造控件树。

///|
/// 一节小标题 + 内容。标题用 Core 的 Label（原生 Static）——画册里正好能看出
/// "系统原生字"与"自绘控件"并排时是什么关系。
fn[B : @moonui.Backend] kit_section(
  b : B,
  title : String,
  body : @moonui.Widget[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  let head = @moonui.Widget::label(b, title)
  head.set_style(
    Some(
      @moonui.style(
        font_size=Some(12.0),
        font_weight=Some(@moonui.FontWeight::Bold),
        foreground=Some(@moonui.Color::rgb(107, 114, 128)),
      ),
    ),
  )
  @moonui.Widget::column(b, 8.0, [head, body])
}

///|
/// 换主题时把画册自己那几只原生 Label 的字色也推一遍。
///
/// 控件换的是自己的自绘字色；小标题与状态行是 Core 的原生 Static，不吃
/// `UiTheme`。这一步属于**画册**的窗口配色，不是控件 API 的一部分。
fn[B] kit_recolor_label(
  w : @moonui.Widget[B],
  color : @moonui.Color,
) -> Unit raise @moonui.UiError {
  if w.kind() == @moonui.WidgetKind::Label {
    w.set_style(
      Some(
        @moonui.style(
          font_size=Some(12.0),
          font_weight=Some(@moonui.FontWeight::Bold),
          foreground=Some(color),
        ),
      ),
    )
  }
  for child in w.children() {
    kit_recolor_label(child, color)
  }
}

///|
fn main raise {
  let app = @moonui-app.new_app()
  app.set_icon("assets/logo/moonui")
  let b = app.backend()
  let win = app.create_window(
    "MoonUI 自绘控件套件",
    @moonui.LogicalSize(760.0, 840.0),
  )
  let t = @widgets.UiTheme::light()
  let status = @moonui.Widget::label(
    b, "点一下里面的东西，这里会说话",
  )

  // —— 按钮：四档 + 一颗禁用 ——
  let ok = @widgets.UiButton(b, "保存", theme=t, app=Some(app))
  let cancel = @widgets.UiButton(
    b,
    "取消",
    theme=t,
    kind=@widgets.UiButtonKind::UiSecondary,
    app=Some(app),
  )
  let more = @widgets.UiButton(
    b,
    "更多",
    theme=t,
    kind=@widgets.UiButtonKind::UiGhost,
    app=Some(app),
  )
  let del = @widgets.UiButton(
    b,
    "删除",
    theme=t,
    kind=@widgets.UiButtonKind::UiDanger,
    app=Some(app),
  )
  let off = @widgets.UiButton(
    b,
    "禁用档",
    theme=t,
    enabled=false,
    app=Some(app),
  )
  let mut hits = 0
  ok.on_click(fn() raise @moonui.UiError {
    hits = hits + 1
    status.set_text("保存被点了 " + hits.to_string() + " 次")
  })
  cancel.on_click(fn() raise @moonui.UiError {
    status.set_text("取消（次按钮）")
  })
  more.on_click(fn() raise @moonui.UiError {
    status.set_text("更多（幽灵按钮）")
  })
  del.on_click(fn() raise @moonui.UiError {
    status.set_text("删除（危险按钮）")
  })
  let buttons = @moonui.Widget::row(b, 10.0, [
    ok.widget(),
    cancel.widget(),
    more.widget(),
    del.widget(),
    off.widget(),
  ])

  // —— 勾选框 / 开关 / 单选 ——
  let disable_ok = @widgets.UiCheckbox(
    b,
    "禁用主按钮",
    theme=t,
    app=Some(app),
  )
  disable_ok.on_change(fn(v) raise @moonui.UiError {
    ok.set_enabled(!v)
    status.set_text(if v { "主按钮已禁用" } else { "主按钮可用了" })
  })
  let auto_save = @widgets.UiToggle(
    b,
    "自动保存",
    theme=t,
    checked=true,
    app=Some(app),
  )
  auto_save.on_change(fn(v) raise @moonui.UiError {
    status.set_text(if v { "自动保存：开" } else { "自动保存：关" })
  })
  let size = @widgets.UiRadioGroup(
    b,
    ["紧凑", "标准", "宽松"],
    selected=1,
    theme=t,
    horizontal=true,
    app=Some(app),
  )
  size.on_change(fn(i) raise @moonui.UiError {
    status.set_text(
      "行距：" + size.selected_text() + "（第 " + i.to_string() + " 档）",
    )
  })
  let choices = @moonui.Widget::row(b, 24.0, [
    @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(6.0, 0.0),
      disable_ok.widget(),
    ),
    @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(6.0, 0.0),
      auto_save.widget(),
    ),
  ])

  // —— 分段 / 页签 ——
  let level = @widgets.UiSegmented(
    b,
    ["低", "中", "高"],
    selected=1,
    theme=t,
    app=Some(app),
  )
  let bar = @widgets.UiProgress(b, value=0.5, theme=t, width=260.0)
  level.on_change(fn(i) raise @moonui.UiError {
    let v = match i {
      0 => 0.2
      1 => 0.5
      _ => 0.85
    }
    bar.set_value(v)
    status.set_text("档位：" + ["低", "中", "高"][i])
  })
  let tabs = @widgets.UiTabs(
    b,
    ["概览", "明细", "设置"],
    theme=t,
    app=Some(app),
  )
  tabs.on_change(fn(i) raise @moonui.UiError {
    status.set_text("切到页签：" + ["概览", "明细", "设置"][i])
  })

  // —— 进度与角标 ——
  let bar2 = @widgets.UiProgress(
    b,
    value=1.0,
    theme=t,
    width=260.0,
    tone=@widgets.UiTone::UiSuccess,
  )
  let tag_controls = [
    @widgets.UiTag(b, "新", tone=@widgets.UiTone::UiAccent, theme=t),
    @widgets.UiTag(b, "已完成", tone=@widgets.UiTone::UiSuccess, theme=t),
    @widgets.UiTag(b, "待审", tone=@widgets.UiTone::UiWarning, theme=t),
    @widgets.UiTag(b, "失败", tone=@widgets.UiTone::UiDanger, theme=t),
    @widgets.UiTag(b, "草稿", tone=@widgets.UiTone::UiNeutral, theme=t),
  ]
  let tags = @moonui.Widget::row(
    b,
    8.0,
    tag_controls.map(fn(tag) { tag.widget() }),
  )

  // —— 不定进度：把 App 交给控件，它自己按帧推相位，不用外部定时器 ——
  let busy = @widgets.UiProgress(
    b,
    theme=t,
    width=220.0,
    indeterminate=true,
    app=Some(app),
  )
  let busy_toggle = @widgets.UiButton(b, "停住", theme=t, app=Some(app))
  busy_toggle.on_click(fn() raise @moonui.UiError {
    let running = !busy.indeterminate()
    busy.set_indeterminate(running)
    busy_toggle.set_label(if running { "停住" } else { "继续" })
    status.set_text(if running { "跑马灯继续" } else { "跑马灯已停" })
  })
  let busy_row = @moonui.Widget::row(b, 12.0, [
    busy.widget(),
    busy_toggle.widget(),
  ]).cross_align(@moonui.CrossAlign::Center)

  // —— 输入 ——
  let name = @widgets.UiTextInput(
    b,
    placeholder="项目名",
    theme=t,
    width=240.0,
  )
  name.on_input(fn(s) raise @moonui.UiError {
    status.set_text("正在输入：" + s)
  })
  let pw = @widgets.UiTextInput::password(
    b,
    placeholder="口令",
    theme=t,
    width=180.0,
  )
  let spin = @widgets.UiSpinbox(
    b,
    value=50,
    min=0,
    max=100,
    theme=t,
    width=150.0,
  )
  spin.on_change(fn(v) raise @moonui.UiError {
    bar2.set_value(v.to_double() / 100.0)
    bar2.set_tone(
      if v >= 80 {
        @widgets.UiTone::UiSuccess
      } else if v >= 40 {
        @widgets.UiTone::UiAccent
      } else {
        @widgets.UiTone::UiDanger
      },
    )
    status.set_text("数值：" + v.to_string())
  })
  let inputs = @moonui.Widget::row(b, 12.0, [
    name.view(),
    pw.view(),
    spin.view(),
  ]).cross_align(@moonui.CrossAlign::Center)

  // —— 自绘滑块（`T358`）：轨道/钮/焦点环全走 DrawList，拖动按位移重算 ——
  // 按下后坐标归起点控件是平台层的指针捕获（Windows/mac 现成），这里不碰 Core。
  let slider = @widgets.UiSlider(
    b,
    value=35.0,
    width=260.0,
    theme=t,
    app=Some(app),
  )
  slider.on_change(fn(v) raise @moonui.UiError {
    status.set_text("滑块：" + v.to_string())
  })

  // —— 第三档（`T360`）：六只组合组件 + 骨架屏 + 轻提示 ——
  // 这八只都是纯新增：不动老控件，也不碰 Core 与平台层。
  let crumb = @widgets.UiBreadcrumb(
    b,
    ["首页", "组件", "第三档"],
    theme=t,
  )
  let steps = @widgets.UiSteps(
    b,
    ["填写", "校验", "提交", "完成"],
    current=1,
    theme=t,
    width=380.0,
  )
  let rate = @widgets.UiRate(b, value=3, theme=t)
  let pager = @widgets.UiPagination(b, total=12, current=4, theme=t)
  let alert = @widgets.UiAlert(
    b,
    "壳、字、轨道全走令牌，换主题不用重造控件树。",
    title="第三档已落地",
    tone=@widgets.UiTone::UiSuccess,
    theme=t,
    width=380.0,
    closable=true,
  )
  let skel = @widgets.UiSkeleton(
    b,
    width=300.0,
    lines=3,
    theme=t,
    app=Some(app),
  )
  let card_body = @moonui.Widget::column(b, 6.0, [
    @moonui.Widget::label(b, "卡片标题"),
    @moonui.Widget::label(
      b, "外层铺边色、内层铺面色，两层同心圆角。",
    ),
  ])
  card_body.set_style(Some(@moonui.style(width=Some(240.0))))
  let card = @widgets.UiCard(b, card_body, theme=t)
  let toast = @widgets.UiToast(
    b,
    "已保存到本地",
    theme=t,
    width=380.0,
    duration_ms=0,
  )
  crumb.on_select(fn(i) raise @moonui.UiError {
    status.set_text("面包屑：" + crumb.item(i))
  })
  steps.on_change(fn(i) raise @moonui.UiError {
    status.set_text(
      "步骤：" + (i + 1).to_string() + " / " + steps.count().to_string(),
    )
  })
  rate.on_change(fn(v) raise @moonui.UiError {
    status.set_text("评分：" + v.to_string() + " 星")
  })
  pager.on_change(fn(p) raise @moonui.UiError {
    status.set_text("第 " + p.to_string() + " 页")
  })
  alert.on_close(fn() raise @moonui.UiError {
    status.set_text(
      "提示条回调响了（控件仍在，摘不摘由调用方定）",
    )
  })

  // —— 老住户（`T107` / `T102` 那批）：现在也吃同一套令牌 ——
  // 这四只早于 `ui_*` 落地，颜色原本各写各的；`T361` 给它们加了 `theme`，
  // 摆进同一页才看得出"一套视觉"是什么意思（环的轨道 = 进度的槽、表格的表头
  // 底 = 分段的槽，选中行 = 角标的淡底）。
  let ring = @widgets.ProgressRing(b, 0.72, size=64.0, theme=Some(t))
  let spark = @widgets.Sparkline(
    b,
    [3.0, 5.0, 4.0, 7.0, 6.0, 9.0, 8.0, 11.0],
    width=180.0,
    height=44.0,
    baseline=true,
    area=true,
    theme=Some(t),
  )
  let legacy_root = @widgets.TreeNode(1, "src", children=[
    @widgets.TreeNode(2, "widgets", detail="6 项", children=[
      @widgets.TreeNode(4, "ui_button.mbt"),
      @widgets.TreeNode(5, "ui_card.mbt"),
    ]),
    @widgets.TreeNode(3, "moonui", detail="12 项"),
  ])
  let tree = @widgets.TreeView(
    b,
    legacy_root,
    width=200.0,
    height=96.0,
    show_root=true,
    expanded=[1, 2],
    theme=Some(t),
  )
  tree.select_id(4)
  let grid_cols : Array[@widgets.GridColumn] = [
    @widgets.GridColumn("文件", 110.0),
    @widgets.GridColumn("改过", 52.0, kind=@widgets.GridCellKind::Check),
    @widgets.GridColumn("进度", 60.0, kind=@widgets.GridCellKind::Bar),
  ]
  let grid = @widgets.DataGrid(
    b,
    grid_cols,
    rows=[
      ["ui_button.mbt", "true", "0.8"],
      ["ui_card.mbt", "", "0.4"],
      ["ui_alert.mbt", "true", "1.0"],
    ],
    width=240.0,
    height=96.0,
    theme=Some(t),
  )
  grid.select_row(0)
  let legacy_row = @moonui.Widget::row(b, 16.0, [
    ring.widget(),
    spark.widget(),
    tree.widget(),
    grid.widget(),
  ]).cross_align(@moonui.CrossAlign::Start)

  // —— 整树换主题：十只控件就地换令牌，不重造控件树 ——
  // 这一键同时是判据：任何一只漏了 set_theme，切到深色后它就会在深底上
  // 顶着浅色字/浅色轨道，一眼看得出。
  let mut dark = false
  let theme_btn = @widgets.UiButton(b, "切到深色", theme=t, app=Some(app))

  let foot = @moonui.Widget::row(b, 12.0, [theme_btn.widget(), status]).cross_align(
    @moonui.CrossAlign::Center,
  )

  let root = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::all(22.0),
    @moonui.Widget::column(b, 18.0, [
      kit_section(
        b, "按钮（主 / 次 / 幽灵 / 危险 / 禁用）", buttons,
      ),
      kit_section(b, "勾选 · 开关 · 单选", choices),
      kit_section(b, "单选组（横排）", size.view()),
      kit_section(
        b,
        "分段控件 + 进度",
        @moonui.Widget::row(b, 16.0, [level.widget(), bar.widget()]).cross_align(
          @moonui.CrossAlign::Center,
        ),
      ),
      kit_section(
        b,
        "页签条 + 进度（成功档）",
        @moonui.Widget::column(b, 10.0, [tabs.view(), bar2.widget()]),
      ),
      kit_section(b, "角标（五种语义色）", tags),
      kit_section(b, "不定进度（自驱帧链）", busy_row),
      kit_section(b, "输入框 / 密码框 / 数字框", inputs),
      kit_section(
        b,
        "自绘滑块（拖动 / 方向键 / Home·End）",
        slider.widget(),
      ),
      kit_section(
        b,
        "面包屑 + 步骤条",
        @moonui.Widget::column(b, 12.0, [crumb.widget(), steps.widget()]),
      ),
      kit_section(
        b,
        "评分（悬停预览 / 点击 / 方向键）+ 分页",
        @moonui.Widget::row(b, 40.0, [rate.widget(), pager.widget()]).cross_align(
          @moonui.CrossAlign::Center,
        ),
      ),
      kit_section(
        b,
        "提示条（可关）+ 轻提示",
        @moonui.Widget::column(b, 10.0, [alert.widget(), toast.widget()]),
      ),
      kit_section(
        b,
        "卡片（Panel 两层壳）+ 骨架屏（脉动）",
        @moonui.Widget::row(b, 20.0, [card.widget(), skel.widget()]).cross_align(
          @moonui.CrossAlign::Start,
        ),
      ),
      kit_section(
        b, "老住户接令牌：环 / 折线 / 树 / 表格", legacy_row,
      ),
      foot,
    ]),
  )
  let bg = @moonui.Widget::panel(b, root)
  bg.set_style(Some(@moonui.style(background=Some(@widgets.ui_color(t.bg)))))
  theme_btn.on_click(fn() raise @moonui.UiError {
    dark = !dark
    let nt = if dark {
      @widgets.UiTheme::dark()
    } else {
      @widgets.UiTheme::light()
    }
    ok.set_theme(nt)
    cancel.set_theme(nt)
    more.set_theme(nt)
    del.set_theme(nt)
    off.set_theme(nt)
    disable_ok.set_theme(nt)
    auto_save.set_theme(nt)
    size.set_theme(nt)
    level.set_theme(nt)
    tabs.set_theme(nt)
    bar.set_theme(nt)
    bar2.set_theme(nt)
    busy.set_theme(nt)
    busy_toggle.set_theme(nt)
    for tag in tag_controls {
      tag.set_theme(nt)
    }
    name.set_theme(nt)
    pw.set_theme(nt)
    spin.set_theme(nt)
    slider.set_theme(nt)
    crumb.set_theme(nt)
    steps.set_theme(nt)
    rate.set_theme(nt)
    pager.set_theme(nt)
    alert.set_theme(nt)
    skel.set_theme(nt)
    card.set_theme(nt)
    toast.set_theme(nt)
    // 老住户（`T361`）：四只都收 `UiTheme?`，这里传的就是整套令牌
    ring.set_theme(Some(nt))
    spark.set_theme(Some(nt))
    tree.set_theme(Some(nt))
    grid.set_theme(Some(nt))
    theme_btn.set_label(if dark { "切到浅色" } else { "切到深色" })
    theme_btn.set_theme(nt)
    // 画册自己的窗口底与原生 Label：控件不管这两样，得由宿主一起换
    bg.set_style(Some(@moonui.style(background=Some(@widgets.ui_color(nt.bg)))))
    kit_recolor_label(root, @widgets.ui_color(nt.text_muted))
    status.set_text(
      if dark {
        "整套令牌已切到深色"
      } else {
        "整套令牌已切到浅色"
      },
    )
  })
  win.set_content(bg)
  win.show()
  println(
    "真窗口已打开：自绘控件套件（按钮/勾选/开关/单选/分段/页签/进度/角标/输入）。关窗口退出。",
  )
  app.run()
  println("  循环结束：保存被点了 " + hits.to_string() + " 次")
}
