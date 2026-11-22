///|
/// 自绘控件套件的第一批判据（`T350`）：令牌、按钮、勾选框、开关、单选组。
///
/// 口径与 `widgets_test.mbt` 一致：全部跑在 `MockBackend` 上，断言的是"这一帧
/// 收到了什么命令、按什么参数"（像不像归后端，画了什么归这里）。交互一律用
/// `Widget::fire` 直接投事件——不用开事件循环，也就不会随泵的节拍漂。
///
/// mock 的文本度量是定死的（每字符 8 × 字号/12、粗体 ×1.25），所以下面那些
/// 尺寸期望值可以写死；换字体系统不会让这些判据变红。

///|
/// 取一条命令里的填充矩形（没有就失败）。
fn ui_test_fill(
  dl : @moonui.DrawList,
) -> (Double, Double, Double, Double, Double, Int32) {
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(x, y, w, h, r, rgb, _) => return (x, y, w, h, r, rgb)
      _ => ()
    }
  }
  abort("清单里没有填充矩形")
}

///|
/// 清单里第一条文本命令（没有就失败）。
fn ui_test_text(dl : @moonui.DrawList) -> (String, Double, Double, Int32) {
  for cmd in dl.commands() {
    match cmd {
      @moonui.Text(t, x, y, _, _, rgb) => return (t, x, y, rgb)
      _ => ()
    }
  }
  abort("清单里没有文本")
}

///|
/// 清单一共几条命令、其中填充几条、描边几条、线段几条——"画了几笔"这类判据
/// 只数个数，不逐条比参数。
fn ui_test_count(dl : @moonui.DrawList) -> (Int32, Int32, Int32, Int32) {
  let mut all = 0
  let mut fills = 0
  let mut strokes = 0
  let mut lines = 0
  for cmd in dl.commands() {
    all = all + 1
    match cmd {
      @moonui.FillRect(_, _, _, _, _, _, _) => fills = fills + 1
      @moonui.StrokeRect(_, _, _, _, _, _, _) => strokes = strokes + 1
      @moonui.Line(_, _, _, _, _, _) => lines = lines + 1
      _ => ()
    }
  }
  (all, fills, strokes, lines)
}

///|
test "UiTheme：深浅两族的悬停方向相反，混色在端点上精确" {
  let l = @widgets.UiTheme::light()
  let d = @widgets.UiTheme::dark()
  // 两族的底色本来就该站在亮度轴的两端
  assert_true(@widgets.ui_luminance(l.bg) > 0.9)
  assert_true(@widgets.ui_luminance(d.bg) < 0.15)
  // 浅色悬停"暗一格"、深色悬停"亮一格"——这是两族唯一不能共用的方向
  assert_true(
    @widgets.ui_luminance(l.surface_hover) < @widgets.ui_luminance(l.surface),
  )
  assert_true(
    @widgets.ui_luminance(d.surface_hover) > @widgets.ui_luminance(d.surface),
  )
  // 混色的端点必须精确（端点都不准，令牌里的过渡档就全歪一格）
  assert_eq(@widgets.ui_mix(0x000000, 0xFFFFFF, 0.0), 0x000000)
  assert_eq(@widgets.ui_mix(0x000000, 0xFFFFFF, 1.0), 0xFFFFFF)
  assert_eq(@widgets.ui_mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
  assert_eq(@widgets.ui_mix(0x101010, 0x202020, 0.5), 0x181818)
  // 越界夹住，不产生"比两端更极端"的颜色
  assert_eq(@widgets.ui_mix(0x101010, 0x202020, -3.0), 0x101010)
  assert_eq(@widgets.ui_mix(0x101010, 0x202020, 7.0), 0x202020)
  // 主按钮的字色跟着主色的亮度走：深蓝配白字
  let light_btn = @widgets.UiTheme::from_palette(@moonui.Theme::light_palette())
  assert_eq(light_btn.accent, 0x265CD0)
  assert_eq(light_btn.on_accent, 0xFFFFFF)
  assert_eq(light_btn.bg, 0xF8F8FA)
  // 反过来：浅黄主色配深字（否则白字糊在黄底上）
  let yellow = @widgets.UiTheme::from_palette(@moonui.Palette::{
    background: @moonui.Color::rgb(255, 255, 255),
    surface: @moonui.Color::rgb(255, 255, 255),
    text: @moonui.Color::rgb(20, 20, 20),
    accent: @moonui.Color::rgb(255, 224, 102),
    border: @moonui.Color::rgb(210, 210, 210),
  })
  assert_true(@widgets.ui_luminance(yellow.on_accent) < 0.2)
  // 三档尺寸：高度与内缩逐档递进，字号只有大小两档
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiSmall).height, 28.0)
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiMedium).height, 32.0)
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiLarge).height, 40.0)
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiMedium).font, 13.0)
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiLarge).font, 15.0)
}

///|
test "UiButton：按文案量宽，主按钮是主色底 + 白字" {
  let b = mock()
  let btn = @widgets.UiButton(b, "保存")
  let w = btn.widget()
  // mock 度量：2 字 × 8 × (13/12) × 1.25(粗) = 21.6667；加两侧 14 内缩是
  // 49.6667，仍小于"两倍高"的最小宽 64，所以宽取 64
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(64.0, 32.0))
  assert_eq(w.kind(), @moonui.WidgetKind::Custom)
  let dl = place(b, w)
  let (fx, fy, fw, fh, fr, frgb) = ui_test_fill(dl)
  assert_eq((fx, fy, fw, fh), (0.0, 0.0, 64.0, 32.0))
  assert_eq(fr, 8.0)
  assert_eq(frgb, 0x2B6CF0) // 浅色令牌的 accent
  let (text, _, _ty, rgb) = ui_test_text(dl)
  assert_eq(text, "保存")
  assert_eq(rgb, 0xFFFFFF) // on_accent
  // 主按钮没有描边：一条填充 + 一行字，就这两笔
  let (all, fills, strokes, _) = ui_test_count(dl)
  assert_eq((all, fills, strokes), (2, 1, 0))
}

///|
test "UiButton：悬停/按下各换一档底，禁用不再回调" {
  let b = mock()
  let btn = @widgets.UiButton(b, "保存")
  let w = btn.widget()
  let mut hits = 0
  btn.on_click(fn() { hits = hits + 1 })
  let dl0 = place(b, w)
  let target = @moonui.EventTarget::of(w.handle().unwrap())
  // 悬停：底换成 accent_hover
  let _ = w.fire(@moonui.MouseEnter(target))
  let (_, _, _, _, _, hover_rgb) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(hover_rgb, 0x1E5FD9)
  // 按下：底换成 accent_active
  let _ = w.fire(
    @moonui.MouseDown(
      target,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(1.0, 1.0),
      @moonui.Mods::none(),
    ),
  )
  let (_, _, _, _, _, down_rgb) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(down_rgb, 0x1750BE)
  // 抬起 + 点击：回调一次；指针还停在上面，所以底色是悬停那一档
  let _ = w.fire(
    @moonui.MouseUp(
      target,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(1.0, 1.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  assert_eq(hits, 1)
  let (_, _, _, _, _, still_hover) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(still_hover, 0x1E5FD9)
  // 指针离开：底色回到静息的 accent
  let _ = w.fire(@moonui.MouseLeave(target))
  let (_, _, _, _, _, rest_rgb) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(rest_rgb, 0x2B6CF0)
  // 空格也算一次（自绘面没有系统按钮的键盘翻译，这条是自己接的）
  let _ = w.fire(
    @moonui.KeyDown(target, @moonui.KeyPress::{
      key: " ",
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
    }),
  )
  assert_eq(hits, 2)
  // 禁用：底色退到淡主色，点击与空格都不再进去
  btn.set_enabled(false)
  let (_, _, _, _, _, disabled_rgb) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(disabled_rgb, @widgets.ui_mix(0x2B6CF0, 0xFFFFFF, 0.72))
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  let _ = w.fire(
    @moonui.KeyDown(target, @moonui.KeyPress::{
      key: " ",
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
    }),
  )
  assert_eq(hits, 2)
  let _ = dl0
}

///|
test "UiButton：改文案按新字宽重算尺寸，幽灵档没有底" {
  let b = mock()
  let btn = @widgets.UiButton(b, "好", kind=@widgets.UiGhost)
  let w = btn.widget()
  // 1 字与最小宽：还是 64（"好"撑不满两倍高）
  assert_eq(w.intrinsic_size().width, 64.0)
  // 7 个字：7 × 8 × (13/12) × 1.25 = 75.83；加两侧内缩 103.83，超过最小宽
  btn.set_label("保存并关闭窗口")
  assert_true(w.intrinsic_size().width > 100.0)
  let _ = w.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(400.0, 60.0),
    ),
  )
  let dl = b.drawn(w.handle().unwrap()).unwrap()
  // 幽灵档静息：没有填充、没有描边，只有一行字
  let (all, fills, strokes, _) = ui_test_count(dl)
  assert_eq((all, fills, strokes), (1, 0, 0))
}

///|
test "UiCheckbox：勾选画勾、未选只描边，点击翻面并回调" {
  let b = mock()
  let cb = @widgets.UiCheckbox(b, "记住我", checked=true)
  let w = cb.widget()
  // 方框 18 + 间距 8 + 三字 26 = 52，高取档高 32
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(52.0, 32.0))
  let events : Array[Bool] = []
  cb.on_change(fn(v) { events.push(v) })
  let dl = place(b, w)
  // 选中：方框底 + 两段勾 + 一行字 = 4 笔，没有描边
  let (all, fills, strokes, lines) = ui_test_count(dl)
  assert_eq((all, fills, strokes, lines), (4, 1, 0, 2))
  let (fx, fy, fw, fh, _, frgb) = ui_test_fill(dl)
  assert_eq((fx, fy, fw, fh), (0.0, 7.0, 18.0, 18.0))
  assert_eq(frgb, 0x2B6CF0)
  // 点击→取消勾选：方框换成面色 + 描一圈边，勾消失
  let target = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  assert_false(cb.checked())
  assert_eq(events, [false])
  let dl2 = b.drawn(w.handle().unwrap()).unwrap()
  let (all2, fills2, strokes2, lines2) = ui_test_count(dl2)
  assert_eq((all2, fills2, strokes2, lines2), (3, 1, 1, 0))
  // 程序设值不回声
  cb.set_checked(true)
  assert_eq(events, [false])
  assert_true(cb.checked())
}

///|
test "UiCheckbox：禁用后点击不翻面" {
  let b = mock()
  let cb = @widgets.UiCheckbox(b, "同意", enabled=false)
  let w = cb.widget()
  let _ = place(b, w)
  let target = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  assert_false(cb.checked())
}

///|
test "UiToggle：钮贴左/贴右，点一下翻面" {
  let b = mock()
  let tg = @widgets.UiToggle(b, "同步")
  let w = tg.widget()
  // 轨道高 22、宽 38.5；文案两字 17.33 + 间距 8 → 总宽 63.83，高取 32
  assert_eq(w.intrinsic_size().height, 32.0)
  assert_true(near(w.intrinsic_size().width, 38.5 + 8.0 + 17.333333))
  let dl = place(b, w)
  // 静息：轨道 + 钮影 + 钮 + 一行字
  let (all, fills, _, _) = ui_test_count(dl)
  assert_eq((all, fills), (4, 3))
  // 钮在左：圆心 x = 半径 9 + 2 = 11，填充矩形的左边界是 11 - 9 = 2
  let (kx, _, kw, _, _, _) = ui_test_last_fill(dl)
  assert_true(near(kx + kw / 2.0, 11.0))
  let target = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  assert_true(tg.checked())
  // 钮在右：圆心 x = 38.5 − 9 − 2 = 27.5
  let dl2 = b.drawn(w.handle().unwrap()).unwrap()
  let (kx2, _, kw2, _, _, _) = ui_test_last_fill(dl2)
  assert_true(near(kx2 + kw2 / 2.0, 27.5))
}

///|
/// 清单里最后一条填充矩形（开关的钮是最后画的那个圆）。
fn ui_test_last_fill(
  dl : @moonui.DrawList,
) -> (Double, Double, Double, Double, Double, Int32) {
  let mut out : (Double, Double, Double, Double, Double, Int32)? = None
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(x, y, w, h, r, rgb, _) =>
        out = Some((x, y, w, h, r, rgb))
      _ => ()
    }
  }
  match out {
    Some(v) => v
    None => abort("清单里没有填充矩形")
  }
}

///|
test "UiRadioGroup：点行换选中，旧行的点消失；程序设值不回声" {
  let b = mock()
  let g = @widgets.UiRadioGroup(b, ["小", "中", "大"], selected=0)
  let root = g.view()
  let _ = root.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(200.0, 200.0),
    ),
  )
  assert_eq(g.selected(), 0)
  assert_eq(g.selected_text(), "小")
  let changes : Array[Int32] = []
  g.on_change(fn(i) { changes.push(i) })
  let rows = root.children()
  assert_eq(rows.length(), 3)
  // 第 0 行：环 + 实心点 + 文案 = 3 笔
  let h0 = rows[0].handle().unwrap()
  let (all0, fills0, strokes0, _) = ui_test_count(b.drawn(h0).unwrap())
  assert_eq((all0, fills0, strokes0), (3, 1, 0))
  // 第 1 行：只有环 + 文案
  let h1 = rows[1].handle().unwrap()
  let (all1, fills1, _, _) = ui_test_count(b.drawn(h1).unwrap())
  assert_eq((all1, fills1), (2, 0))
  // 点第 1 行：换选中、回调一次、两行都重画
  let _ = rows[1].fire(
    @moonui.Click(@moonui.EventTarget::of(h1), @moonui.MouseButton::Left),
  )
  assert_eq(g.selected(), 1)
  assert_eq(changes, [1])
  let (all0b, fills0b, _, _) = ui_test_count(b.drawn(h0).unwrap())
  assert_eq((all0b, fills0b), (2, 0)) // 旧行的点没了
  let (_, fills1b, _, _) = ui_test_count(b.drawn(h1).unwrap())
  assert_eq(fills1b, 1) // 新行的点出来了
  // 再点同一行：值没变，不回调
  let _ = rows[1].fire(
    @moonui.Click(@moonui.EventTarget::of(h1), @moonui.MouseButton::Left),
  )
  assert_eq(changes, [1])
  // 程序设值：不回调
  g.set_selected(2)
  assert_eq(g.selected(), 2)
  assert_eq(g.selected_text(), "大")
  assert_eq(changes, [1])
}
