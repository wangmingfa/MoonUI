///|
/// 自绘后端（canvas-macos）的原生 kind 配方画册（`T372`）：
/// `moon run examples/kinds-canvas-native` 开一扇 420×660 的自绘窗。
///
/// 这一页只摆 **Core 的原生 kind**（不是 `packages/widgets` 的 ui_* 自绘面），
/// 让 backends/canvas-common 新落的配方逐个上屏：勾选框三态、进度条 0/50/100
/// 与不定进度、口令掩码、数字框步进区、单选选中行，末尾一只 Scroll 视口——
/// 滚动内容必须看得见（Scroll 自己不能画面，否则逆序绘制会把它盖掉）。

///|
fn[B : @moonui.Backend] section_head(
  b : B,
  text : String,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let w = @moonui.Widget::label(b, text)
  w.set_style(
    Some(
      @moonui.style(
        font_size=Some(12.0),
        font_weight=Some(@moonui.FontWeight::Bold),
        foreground=Some(@moonui.Color::rgb(107, 114, 128)),
      ),
    ),
  )
  w
}

///|
fn main raise {
  let b = @canvas-macos.CanvasBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let win = app.create_window(
    "MoonUI 原生控件配方画册（自绘后端）",
    @moonui.LogicalSize(440.0, 980.0),
  )

  let title = @moonui.Widget::label(b, "自绘后端：原生 kind 配方")
  title.set_style(
    Some(
      @moonui.style(
        font_size=Some(18.0),
        font_weight=Some(@moonui.FontWeight::Bold),
      ),
    ),
  )

  // —— 勾选框：选中 / 未选 / 禁用 ——
  let cb_on = @moonui.Widget::checkbox(b, "已勾选", true)
  let cb_off = @moonui.Widget::checkbox(b, "未勾选", false)
  let cb_disabled = @moonui.Widget::checkbox(b, "禁用项", true)
  cb_disabled.set_enabled(false)

  // —— 进度条：0 / 50 / 100 / 不定进度 ——
  // Sized 是布局容器（无值/文本通道）：先设值再包一层固定宽高。
  let bar0_inner = @moonui.Widget::progress(b)
  bar0_inner.set_value(0)
  let bar0 = @moonui.Widget::sized(b, Some(360.0), Some(10.0), bar0_inner)
  let bar50_inner = @moonui.Widget::progress(b)
  bar50_inner.set_value(50)
  let bar50 = @moonui.Widget::sized(b, Some(360.0), Some(10.0), bar50_inner)
  let bar100_inner = @moonui.Widget::progress(b)
  bar100_inner.set_value(100)
  let bar100 = @moonui.Widget::sized(b, Some(360.0), Some(10.0), bar100_inner)
  let bar_busy_inner = @moonui.Widget::progress(b)
  bar_busy_inner.set_value(-1)
  let bar_busy = @moonui.Widget::sized(
    b,
    Some(360.0),
    Some(10.0),
    bar_busy_inner,
  )

  // —— 口令 / 数字框 / 单选 / 文本框 / 滑条 ——
  let pw_inner = @moonui.Widget::password_input(b, "moonui2026")
  pw_inner.set_placeholder("口令")
  let pw = @moonui.Widget::sized(b, Some(360.0), Some(28.0), pw_inner)
  let spin_inner = @moonui.Widget::spinbox(b, 0, 100)
  spin_inner.set_value(50)
  let spin = @moonui.Widget::sized(b, Some(360.0), Some(28.0), spin_inner)
  // 单选是"一个原生控件画一整列"：高度得自己给（三行 × 24）
  let radio_inner = @moonui.Widget::radio_buttons(b, ["低", "中", "高"])
  radio_inner.set_selected(1)
  let radio = @moonui.Widget::sized(b, Some(360.0), Some(72.0), radio_inner)
  let text_inner = @moonui.Widget::text_input(b, "")
  text_inner.set_placeholder("搜索")
  let text = @moonui.Widget::sized(b, Some(360.0), Some(28.0), text_inner)
  let slider_inner = @moonui.Widget::slider(b, 0, 100)
  slider_inner.set_value(50)
  let slider = @moonui.Widget::sized(b, Some(360.0), Some(24.0), slider_inner)

  // —— 下拉 / 多行 / 日期 ——
  let combo_inner = @moonui.Widget::combobox(b, ["低", "中", "高"])
  combo_inner.set_selected(1)
  let combo = @moonui.Widget::sized(b, Some(360.0), Some(28.0), combo_inner)
  let multiline = @moonui.Widget::sized(
    b,
    Some(360.0),
    Some(80.0),
    @moonui.Widget::multiline(b, "第一行\n第二行\n第三行"),
  )
  let date_inner = @moonui.Widget::date_picker(b)
  date_inner.set_datetime_text("2026-11-24")
  let date = @moonui.Widget::sized(b, Some(360.0), Some(28.0), date_inner)

  // —— 交互接线：画册原来只画不接，点哪儿都没反应；这里把能点响的都接上 ——
  // 勾选：点一下翻一下（禁用的那只故意不接，点它仍无反应，当作负例）。
  let _ = cb_on.on_click(fn() raise @moonui.UiError {
    cb_on.set_checked(!cb_on.checked())
  })
  let _ = cb_off.on_click(fn() raise @moonui.UiError {
    cb_off.set_checked(!cb_off.checked())
  })
  // 单选 / 下拉：`Click` 只带目标、不带行号，画册用"点一下轮换一项"演示。
  let _ = radio_inner.on_click(fn() raise @moonui.UiError {
    radio_inner.set_selected((radio_inner.selected() + 1) % 3)
  })
  let _ = combo_inner.on_click(fn() raise @moonui.UiError {
    combo_inner.set_selected((combo_inner.selected() + 1) % 3)
  })
  // 日期：弹层还没做（另起一刀），先按预置三档轮换，点一下看得出来。
  let dates = ["2026-11-24", "2026-11-25", "2026-11-26"]
  let date_i = [0]
  let _ = date_inner.on_click(fn() raise @moonui.UiError {
    date_i[0] = (date_i[0] + 1) % dates.length()
    date_inner.set_datetime_text(dates[date_i[0]])
  })

  // —— Scroll：30 行，视口只有 160 高 ——
  let rows : Array[@moonui.Widget[@canvas-macos.CanvasBackend]] = []
  for i in 0..<30 {
    rows.push(@moonui.Widget::label(b, "滚动行 \{i + 1} / 30"))
  }
  let scroll = @moonui.Widget::scroll(
    b,
    @moonui.Vertical,
    @moonui.Widget::column(b, 4.0, rows),
  )

  let root = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::all(20.0),
    @moonui.Widget::column(b, 10.0, [
      title,
      section_head(b, "勾选框"),
      cb_on,
      cb_off,
      cb_disabled,
      section_head(b, "进度"),
      bar0,
      bar50,
      bar100,
      bar_busy,
      section_head(b, "口令 / 数字 / 单选"),
      pw,
      spin,
      radio,
      section_head(b, "文本 / 滑条"),
      text,
      slider,
      section_head(b, "下拉 / 多行 / 日期"),
      combo,
      multiline,
      date,
      section_head(b, "滚动视口（内容必须可见）"),
      @moonui.Widget::sized(b, None, Some(140.0), scroll),
    ]),
  )
  win.set_content(root)
  win.show()
  println(
    "自绘 kind 配方画册已开窗：勾选框三态 / 进度 0·50·100·不定 / 口令掩码 / 数字框 / 单选 / 下拉 / 多行 / 日期 / 滚动视口",
  )
  app.run()
}
