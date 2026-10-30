///|
/// 伴窗的顶条（Luna那四只窗——播放列表 / 均衡器 / 歌词秀 / 桌面歌词——
/// 顶上都有同一条：皮肤色底、上缘一条亮线、标题居左、右侧一颗关闭方块）。
///
/// 主控那条是自绘的沉浸式标题栏（红绿灯浮在上面，见 app 的 title_bar），
/// 这里这条是伴窗用的：高度固定 20，跟主控的 34 不是一回事——原版伴窗的标
/// 题条也确实更窄。
///
/// 为什么需要它：伴窗原来没有标题条，四只窗摆在一起像四个网页面板，跟主控
/// 那种"一整块皮肤"完全不是一个观感。加一条同色系的窄条，一排窗读起来才像
/// 同一个程序。
pub(all) struct CmStrip[B] {
  root : @moonui.Widget[B]
  title : @moonui.Widget[B]
  /// 关闭方块。mac 上不建（系统红绿灯已经有关闭），所以是 `Option`。
  close : @moonui.Widget[B]?
}

///|
/// `actions` 是顶条右侧的动作按钮（`T161`：歌词秀那颗「搜索歌词」）。空表时
/// 树与加这个参数之前逐位一样，所以另外三只窗不用改。
///
/// 按钮**不参与** `close` 字段：那是"那颗 ✕ 在不在"的账（mac 上没有），
/// 动作按钮是两个宿主都有的。
pub fn[B : @moonui.Backend] CmStrip::new(
  b : B,
  title : String,
  on_close : () -> Unit,
  actions~ : Array[(String, () -> Unit)] = [],
) -> CmStrip[B] raise @moonui.UiError {
  let lbl = @moonui.Widget::label(b, title)
    .foreground(cm_text_light())
    .font_size(10.0)
    .font_weight(Bold)
  // 动作按钮：尺寸照既有规约走 `sized`（只写 `.width()` 不参与布局，
  // `ui_playbar.mbt` 那条教训）。
  //
  // 底色不能再跟顶条同色（`T164`③）：深蓝底上压一行浅字，和标题那一格长得
  // 一模一样，owner 在真窗上读成"这就是个标签，点不动"。换成 `cm_btn_bg`
  // （走带小钮那一档，比顶条亮一档、比脸面暗一档），它在这条深带上是一块
  // **凸起的脸**；再挂一条悬停抬到强调色，指针扫过去整块变色——"能按"的
  // 两个信号就齐了。✕ 那颗不改：它靠形状（方块 ✕）已经读得出是按钮，而动
  // 作钮只有一行字。
  let action_btns : Array[@moonui.Widget[B]] = []
  for (text, on_click) in actions {
    let btn = @moonui.Widget::button(b, text)
    cm_btn_skin(btn, cm_btn_bg(), cm_text_light(), 9.0)
    let _ = btn.set_hover_style(
      Some(@moonui.style(background=Some(cm_accent()))),
    )
    let _ = btn.with_on_click(fn() { on_click() })
    action_btns.push(
      cm_strip_cell(
        b,
        Some(56.0),
        @moonui.Widget::sized(b, None, Some(cm_strip_row_h()), btn),
      ),
    )
  }
  // 顶条右侧那颗 ✕ 是 Windows 的做法（无边框窗没有系统按钮）。mac 的沉浸式
  // 标题栏自带红绿灯，再画一颗就是两个关闭按钮——所以整颗不建，同时左侧让
  // 出红绿灯的位置（整簇约 52pt，留 62 才不叠标题）。
  let mac = b.host_platform() == Macos
  if mac {
    let cells : Array[@moonui.Widget[B]] = [
      @moonui.Widget::sized(b, Some(62.0), None, @moonui.Widget::spacer(b)),
      cm_strip_title_cell(b, lbl),
      @moonui.Widget::spacer(b).with_expand(true),
    ]
    for a in action_btns {
      cells.push(a)
    }
    let row = @moonui.Widget::row(b, 6.0, cells)
    let padded = @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(3.0, 6.0),
      row,
    )
    let mid = @moonui.Widget::panel(b, padded).background(cm_titlebar_bg())
    let root = cm_band(b, cm_strip_h(), mid)
    return { root, title: lbl, close: None, }
  }
  let close = @moonui.Widget::button(b, "✕")
  cm_btn_skin(close, cm_titlebar_bg(), cm_text_light(), 9.0)
  let _ = close.with_on_click(fn() { on_close() })
  let cells : Array[@moonui.Widget[B]] = [
    cm_strip_title_cell(b, lbl),
    @moonui.Widget::spacer(b).with_expand(true),
  ]
  for a in action_btns {
    cells.push(a)
  }
  cells.push(
    cm_strip_cell(
      b,
      Some(18.0),
      @moonui.Widget::sized(b, None, Some(13.0), close),
    ),
  )
  let row = @moonui.Widget::row(b, 6.0, cells)
  let padded = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(3.0, 6.0),
    row,
  )
  let mid = @moonui.Widget::panel(b, padded).background(cm_titlebar_bg())
  let root = cm_band(b, cm_strip_h(), mid)
  { root, title: lbl, close: Some(close), }
}

///|
/// 顶条内容行的行高：条高扣掉上下两条 1px 倒角与 3pt 上下内缩（`cm_band` +
/// `symmetric(3.0, …)` 那两笔），22 - 2 - 6 = 14。
///
/// 单独成式而不是散在各处：`Sized` 的定高决定 `row` 的交叉轴可用高，写错一格
/// 整排字就跟着偏。
fn cm_strip_row_h() -> Double {
  cm_strip_h() - 8.0
}

///|
/// 顶条里的一格：锁宽、锁**行高**、子项在格里居中。
///
/// 为什么必须锁高再加 `Center`：`layout_line` 把 Row 的固定子项按自己量出来的
/// 尺寸摆在 `frame.origin` 上（交叉轴左上对齐，不做居中），所以一颗 13pt 高的
/// 标签放进 14pt 高的行里会贴行顶，看着比中线高一截。`Center` 能把子项摆到
/// 格子的正中，但它要先拿到格子的高——`sized` 的定高正是那份高（`Center` 的
/// 摆放读的是传进来的 frame，不是子项的测量值）。
///
/// 不锁高只靠 `Center` 是不行的：`measure_sized` 把 `None` 那一维透传给子项的
/// 测量值，而 `Center` 量的是子项固有尺寸，格子就又变成"和字一样高"，居中等于
/// 没做。
fn[B : @moonui.Backend] cm_strip_cell(
  b : B,
  width : Double?,
  child : @moonui.Widget[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  @moonui.Widget::sized(
    b,
    width,
    Some(cm_strip_row_h()),
    @moonui.Widget::center(b, child),
  )
}

///|
/// 顶条标题那一格：宽度由内容定（三只伴窗的字数不同），竖向居中。
fn[B : @moonui.Backend] cm_strip_title_cell(
  b : B,
  lbl : @moonui.Widget[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  cm_strip_cell(b, None, lbl)
}

///|
/// 伴窗顶条的高度（上下 1px 倒角 + 中间 18pt 内容）。
///
/// 22 而不是 20：mac 的沉浸式标题栏下红绿灯（13pt 圆钮）浮在这条上面，20
/// 太挤，按钮会压到条的下缘。
pub fn cm_strip_h() -> Double {
  22.0
}

///|
/// 伴窗外壳 = 顶条 + 内容区（四边留 pad，透出皮肤的脸面色）。
/// 返回整窗根：底色是脸面蓝，内容自己决定里面是浅色卡片还是深色槽。
pub fn[B : @moonui.Backend] cm_window_shell(
  b : B,
  strip : @moonui.Widget[B],
  body : @moonui.Widget[B],
  pad : Double,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::all(pad),
    @moonui.Widget::sized(b, None, None, body).with_expand(true),
  )
  let col = @moonui.Widget::column(b, 0.0, [
    strip,
    @moonui.Widget::sized(b, None, None, inner).with_expand(true),
  ])
  let root = @moonui.Widget::panel(b, col)
  let _ = root.set_style(Some(@moonui.style(background=Some(cm_page_bg()))))
  root
}
