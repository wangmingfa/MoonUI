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

///|
/// 造一条按下-松开的鼠标序列（同一个点），返回点击的次数由调用方断言。
///
/// 分段控件与页签条都按"按下与松手在同一格才算"的规矩，所以判定必须是
/// **一对**事件；只投 `Click` 的话正好绕过它们唯一的那条判定链。
fn ui_test_press_release(
  w : @moonui.Widget[@moonui.MockBackend],
  x : Double,
  y : Double,
) -> Unit raise @moonui.UiError {
  let t = @moonui.EventTarget::of(w.handle().unwrap())
  let p = @moonui.LogicalPoint(x, y)
  let _ = w.fire(
    @moonui.MouseDown(t, @moonui.MouseButton::Left, p, @moonui.Mods::none()),
  )
  let _ = w.fire(
    @moonui.MouseUp(t, @moonui.MouseButton::Left, p, @moonui.Mods::none()),
  )
}

///|
test "UiSegmented：三格等宽、选中块落在第二格，按下松手同格才换选" {
  let b = mock()
  let seg = @widgets.UiSegmented(b, ["日", "周", "月"])
  let w = seg.widget()
  // 每格最小 56（单字撑不满），两侧各 3：总宽 3×56 + 6 = 174，高 32
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(174.0, 32.0))
  assert_eq(seg.selected(), 0)
  let changes : Array[Int32] = []
  seg.on_change(fn(i) { changes.push(i) })
  let dl = place(b, w)
  // 槽（1）+ 选中块（1）+ 三格文案（3）= 5 笔；其中填充 2 笔
  let (all, fills, _, _) = ui_test_count(dl)
  assert_eq((all, fills), (5, 2))
  // 第一格的选中块：x = 留白 3，y = 3，宽 56，高 32 − 6
  let (fx, fy, fw, fh, _, _) = ui_test_last_fill_first_thumb(dl)
  assert_eq((fx, fy, fw, fh), (3.0, 3.0, 56.0, 26.0))
  // 点第二格中间（3 + 56 + 28 = 87）→ 换选并回调
  ui_test_press_release(w, 87.0, 16.0)
  assert_eq(seg.selected(), 1)
  assert_eq(changes, [1])
  let (tx, _, _, _, _, _) = ui_test_last_fill_first_thumb(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(tx, 59.0) // 3 + 56
  // 同格再点：不回调
  ui_test_press_release(w, 87.0, 16.0)
  assert_eq(changes, [1])
  // 按下第一格、松手在第三格：不算换选（这是"按下即时生效"会误触的那条）
  let t = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(
    @moonui.MouseDown(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(30.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = w.fire(
    @moonui.MouseUp(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(145.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(seg.selected(), 1)
  assert_eq(changes, [1])
  // 程序设值不回声，越界夹住
  seg.set_selected(9)
  assert_eq(seg.selected(), 2)
  assert_eq(changes, [1])
}

///|
/// 第二条填充矩形（分段控件的选中块；第一条是凹槽底）。
fn ui_test_last_fill_first_thumb(
  dl : @moonui.DrawList,
) -> (Double, Double, Double, Double, Double, Int32) {
  let mut seen = 0
  let mut out : (Double, Double, Double, Double, Double, Int32)? = None
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(x, y, w, h, r, rgb, _) => {
        seen = seen + 1
        if seen == 2 {
          out = Some((x, y, w, h, r, rgb))
        }
      }
      _ => ()
    }
  }
  match out {
    Some(v) => v
    None => abort("清单里没有第二条填充")
  }
}

///|
test "UiTabs：底线 + 选中项下面的主色条，换成第二页时条跟着挪" {
  let b = mock()
  let tabs = @widgets.UiTabs(b, ["概览", "明细"])
  let w = tabs.view()
  // 两字 17.33 + 两侧 14 = 45.33 一拍；总宽 90.67
  assert_true(near(w.intrinsic_size().width, 90.666666))
  assert_eq(w.intrinsic_size().height, 32.0)
  let changes : Array[Int32] = []
  tabs.on_change(fn(i) { changes.push(i) })
  let dl = place(b, w)
  // 底线（1）+ 两块文案（2）+ 指示条（1）= 4 笔；只有指示条那 1 笔是填充
  let (all, fills, _, _) = ui_test_count(dl)
  assert_eq((all, fills), (4, 1))
  let (ix, iy, iw, ih, _, irgb) = ui_test_fill(dl)
  // 指示条：两端各内缩 10，宽 45.33 − 20 = 25.33，落在底线那 2px 上
  assert_eq((ix, iy, ih), (10.0, 30.0, 2.0))
  assert_true(near(iw, 25.333333))
  assert_eq(irgb, 0x2B6CF0)
  // 点第二页
  ui_test_press_release(w, 68.0, 16.0)
  assert_eq(tabs.selected(), 1)
  assert_eq(changes, [1])
  let (ix2, _, _, _, _, _) = ui_test_fill(b.drawn(w.handle().unwrap()).unwrap())
  assert_true(near(ix2, 45.333333 + 10.0))
}

///|
test "UiProgress：轨道整条、进度随值，越界与 NaN 都夹住" {
  let b = mock()
  let bar = @widgets.UiProgress(b, value=0.5, width=200.0, thickness=8.0)
  let w = bar.widget()
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(200.0, 8.0))
  let dl = place(b, w)
  let (all, fills, _, _) = ui_test_count(dl)
  assert_eq((all, fills), (2, 2))
  // 第二条是进度：宽 = 200 × 0.5
  let (px, py, pw, ph, pr, prgb) = ui_test_last_fill(dl)
  assert_eq((px, py, pw, ph, pr), (0.0, 0.0, 100.0, 8.0, 4.0))
  assert_eq(prgb, 0x2B6CF0)
  // 0 只画轨道
  bar.set_value(0.0)
  let (all0, fills0, _, _) = ui_test_count(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq((all0, fills0), (1, 1))
  // 极小的值也要看得见（至少 2px）
  bar.set_value(0.0005)
  let (_, _, pw2, _, _, _) = ui_test_last_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(pw2, 2.0)
  // 越界与 NaN
  bar.set_value(1.8)
  assert_eq(bar.value(), 1.0)
  bar.set_value(0.0 / 0.0)
  assert_eq(bar.value(), 0.0)
}

///|
test "UiTag：淡底 + 同色字，换文案重算宽度、换语义色换两格颜色" {
  let b = mock()
  let tag = @widgets.UiTag(b, "新")
  let w = tag.widget()
  // UiSmall：字号 12 → 单字 8 宽，加两侧 16 = 24；高 = 12 + 10 = 22
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(24.0, 22.0))
  let dl = place(b, w)
  let (fx, fy, fw, fh, fr, frgb) = ui_test_fill(dl)
  assert_eq((fx, fy, fw, fh, fr), (0.0, 0.0, 24.0, 22.0, 11.0))
  // 浅色令牌的 accent 淡底：往白里混 0.88
  assert_eq(frgb, @widgets.ui_mix(0x2B6CF0, 0xFFFFFF, 0.88))
  let (text, _, _, trgb) = ui_test_text(dl)
  assert_eq(text, "新")
  assert_eq(trgb, 0x2B6CF0)
  // 换文案：三字 → 24 + 16 = 40
  tag.set_text("已完成")
  assert_eq(w.intrinsic_size().width, 40.0)
  // 换语义色：底与字各换一格
  tag.set_tone(@widgets.UiTone::UiDanger)
  let dl2 = b.drawn(w.handle().unwrap()).unwrap()
  let (_, _, _, _, _, frgb2) = ui_test_fill(dl2)
  assert_eq(frgb2, @widgets.ui_mix(0xE5484D, 0xFFFFFF, 0.88))
  let (_, _, _, trgb2) = ui_test_text(dl2)
  assert_eq(trgb2, 0xE5484D)
}

///|
test "UiTextInput：三层壳（Sized→Panel→Panel→编辑框），边框四档只换一格颜色" {
  let b = mock()
  let input = @widgets.UiTextInput(b, placeholder="请输入")
  let root = input.view()
  assert_eq(root.kind(), @moonui.WidgetKind::Sized)
  let shell = root.children()[0]
  assert_eq(shell.kind(), @moonui.WidgetKind::Panel)
  let inner = shell.children()[0]
  assert_eq(inner.kind(), @moonui.WidgetKind::Panel)
  let field = inner.children()[0]
  assert_eq(field.kind(), @moonui.WidgetKind::TextInput)
  // 静息：外层涂 border
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0xDBDFE6)),
  )
  // 悬停：border_strong
  let ft = @moonui.EventTarget::of(field.handle().unwrap())
  let _ = field.fire(@moonui.MouseEnter(ft))
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0xC2C8D2)),
  )
  // 焦点：accent（焦点压过悬停）
  let _ = field.fire(@moonui.Focus(ft))
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0x2B6CF0)),
  )
  // 失焦：落回悬停那一档
  let _ = field.fire(@moonui.Blur(ft))
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0xC2C8D2)),
  )
  // 禁用：退到 surface_active，且编辑框本身也被禁用
  input.set_enabled(false)
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0xE7EAEF)),
  )
  assert_false(field.enabled())
}

///|
test "UiTextInput：文本读写走原生编辑框，内容变化回传全文" {
  let b = mock()
  let input = @widgets.UiTextInput(b, text="a")
  assert_eq(input.text(), "a")
  input.set_text("abc")
  assert_eq(input.text(), "abc")
  let seen : Array[String] = []
  input.on_input(fn(t) { seen.push(t) })
  let ft = @moonui.EventTarget::of(input.field().handle().unwrap())
  let _ = input.field().fire(@moonui.Input(ft, "abcd"))
  assert_eq(seen, ["abcd"])
  // 密码档：同一只控件，编辑框换种类
  let pw = @widgets.UiTextInput::password(b, text="hunter2")
  assert_eq(pw.field().kind(), @moonui.WidgetKind::PasswordInput)
  assert_eq(pw.text(), "hunter2")
}

///|
test "UiSpinbox：步进夹在范围内、打字能改值、失焦把半成品洗回值" {
  let b = mock()
  let spin = @widgets.UiSpinbox(b, value=9, min=0, max=10, step=1, width=140.0)
  let root = spin.view()
  assert_eq(spin.value(), 9)
  assert_eq(spin.input().text(), "9")
  let _ = root.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(300.0, 60.0),
    ),
  )
  let stepper = root.children()[1]
  let sf = stepper.frame()
  assert_eq(sf.size.width, 22.0)
  let changes : Array[Int32] = []
  spin.on_change(fn(v) { changes.push(v) })
  // 点上半 → +1
  let st = @moonui.EventTarget::of(stepper.handle().unwrap())
  let top = @moonui.LogicalPoint(sf.origin.x + 10.0, sf.origin.y + 8.0)
  let _ = stepper.fire(
    @moonui.MouseDown(st, @moonui.MouseButton::Left, top, @moonui.Mods::none()),
  )
  assert_eq(spin.value(), 10)
  assert_eq(changes, [10])
  // 到顶再点：值不变、不回调
  let _ = stepper.fire(
    @moonui.MouseDown(st, @moonui.MouseButton::Left, top, @moonui.Mods::none()),
  )
  assert_eq(changes, [10])
  // 点下半 → −1
  let bottom = @moonui.LogicalPoint(sf.origin.x + 10.0, sf.origin.y + 24.0)
  let _ = stepper.fire(
    @moonui.MouseDown(
      st,
      @moonui.MouseButton::Left,
      bottom,
      @moonui.Mods::none(),
    ),
  )
  assert_eq(spin.value(), 9)
  assert_eq(changes, [10, 9])
  // 打字：合法的跟着改值
  let ft = @moonui.EventTarget::of(spin.input().field().handle().unwrap())
  let _ = spin.input().field().fire(@moonui.Input(ft, "7"))
  assert_eq(spin.value(), 7)
  assert_eq(changes, [10, 9, 7])
  // 打字：越界与非法一律不动值
  let _ = spin.input().field().fire(@moonui.Input(ft, "99"))
  assert_eq(spin.value(), 7)
  let _ = spin.input().field().fire(@moonui.Input(ft, "abc"))
  assert_eq(spin.value(), 7)
  let _ = spin.input().field().fire(@moonui.Input(ft, "-"))
  assert_eq(spin.value(), 7)
  // 失焦：把框里的半成品洗回当下的值
  let _ = spin.input().field().fire(@moonui.Blur(ft))
  assert_eq(spin.input().text(), "7")
  // 程序设值：夹住、不回调
  spin.set_value(42)
  assert_eq(spin.value(), 10)
  assert_eq(changes, [10, 9, 7])
}

///|
/// `T353`：次级档的 1px 边改成"两层填充"之后，四档的可见圆角才真正同源。
///
/// 老做法是 `StrokeRect`（路径 + 画笔）：描边路径本身内缩 0.5、半径减 0.5，
/// 再经"逻辑→物理 int"与千分比两次取整，四角的可见弧比同半径的实心块长出
/// 约 2px——截图上一排按钮里"取消"的角明显比"保存/删除"圆。这条判据钉的是
/// "一笔描边都没有，两层填充的几何严丝合缝"，而不是某个像素读数。
test "UiButton：次级档的边是两层填充，圆角与实心档同一套算术" {
  let b = mock()
  let btn = @widgets.UiButton(
    b,
    "取消",
    kind=@widgets.UiButtonKind::UiSecondary,
  )
  let dl = place(b, btn.widget())
  let fills : Array[(Double, Double, Double, Double, Double, Int32)] = []
  let mut strokes = 0
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(x, y, w, h, r, rgb, _) =>
        fills.push((x, y, w, h, r, rgb))
      @moonui.StrokeRect(_, _, _, _, _, _, _) => strokes = strokes + 1
      _ => ()
    }
  }
  assert_eq(fills.length(), 2)
  assert_eq(strokes, 0)
  // 外层整块涂边色（半径 = 档半径 8），内层内缩 1px 涂面色（半径 = 7）
  assert_eq(fills[0], (0.0, 0.0, 64.0, 32.0, 8.0, 0xDBDFE6))
  assert_eq(fills[1], (1.0, 1.0, 62.0, 30.0, 7.0, 0xFFFFFF))
  // 主按钮照旧是一层：这条改动只碰"有边的那一档"
  let primary = @widgets.UiButton(b, "保存")
  let dl2 = place(b, primary.widget())
  let (_, fills2, strokes2, _) = ui_test_count(dl2)
  assert_eq((fills2, strokes2), (1, 0))
}

///|
/// `T353`：自绘外壳里那层原生编辑框必须摘掉自带的边框，否则"圆角边里套
/// 一圈系统方边"（截图里的双层框）。
///
/// 这条在 mock 上只能断言"语义到了后端"（mock 没有原生边框可摘），真机上
/// 摘没摘干净归真窗截图那条账；另一半是**口子只对编辑框开**——给标签摘边
/// 要明确报错，而不是静默通过变成"谁都能改原生外观"。
test "UiTextInput：编辑框摘掉原生自带边框，这条口子只对编辑框开" {
  let b = mock()
  let input = @widgets.UiTextInput(b, placeholder="项目名")
  let field = input.field()
  assert_eq(field.kind(), @moonui.WidgetKind::TextInput)
  assert_true(b.widget(field.handle().unwrap()).frameless)
  // 密码档同一条通道
  let pw = @widgets.UiTextInput::password(b, text="x")
  assert_true(b.widget(pw.field().handle().unwrap()).frameless)
  // 其它种类：报错，不静默
  let label = @moonui.Widget::label(b, "x")
  let err : String? = try {
    label.set_frameless(true)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(err, Some("不支持的操作：该控件没有自带边框可摘"))
  b.terminate()
}

///|
/// 反复取同一只自绘面的绘制清单：`place` 会把控件挂进一只新 Row，同一只控件
/// 挂两次 Core 会报"已被其他容器持有"；这里直接给自定义面一次布局机会。
fn ui_test_redraw(
  b : @moonui.MockBackend,
  w : @moonui.Widget[@moonui.MockBackend],
) -> @moonui.DrawList raise @moonui.UiError {
  let _ = w.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(400.0, 300.0),
    ),
  )
  let h = match w.handle() {
    Some(h) => h
    None => abort("控件没有原生句柄")
  }
  match b.drawn(h) {
    Some(dl) => dl
    None => abort("自定义绘制面一次都没画过")
  }
}

///|
/// `T357`：整树换主题不能靠重造控件——十只控件都得有 `set_theme`，而且换完
/// 当帧画出来的颜色真的来自新令牌。漏一只，画册切到深色时它就会顶着浅色。
fn ui_test_has_fill(dl : @moonui.DrawList, rgb : Int32) -> Bool {
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(_, _, _, _, _, c, _) => if c == rgb { return true }
      _ => ()
    }
  }
  false
}

///|
test "自绘套件：十只控件都能就地换整套令牌（T357）" {
  let b = mock()
  let l = @widgets.UiTheme::light()
  let d = @widgets.UiTheme::dark()

  // 主色块：按钮、勾选框、开关、单选圆点
  let btn = @widgets.UiButton(b, "保存", theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, btn.widget()), l.accent))
  btn.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, btn.widget()), d.accent))

  let chk = @widgets.UiCheckbox(b, "启用", checked=true, theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, chk.widget()), l.accent))
  chk.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, chk.widget()), d.accent))

  let tgl = @widgets.UiToggle(b, "自动", checked=true, theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, tgl.widget()), l.accent))
  tgl.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, tgl.widget()), d.accent))

  let rad = @widgets.UiRadioGroup(b, ["甲", "乙"], selected=0, theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, rad.rows[0]), l.accent))
  rad.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, rad.rows[0]), d.accent))

  // 条带：分段铺槽色，页签的选中指示条走主色
  let seg = @widgets.UiSegmented(b, ["低", "高"], theme=l)
  assert_true(
    ui_test_has_fill(ui_test_redraw(b, seg.widget()), l.surface_sunken),
  )
  seg.set_theme(d)
  assert_true(
    ui_test_has_fill(ui_test_redraw(b, seg.widget()), d.surface_sunken),
  )

  let tab = @widgets.UiTabs(b, ["甲", "乙"], theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, tab.view()), l.accent))
  tab.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, tab.view()), d.accent))

  // 进度与角标：一个换轨道色，一个换淡底
  let bar = @widgets.UiProgress(b, value=0.5, theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, bar.widget()), l.track))
  bar.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, bar.widget()), d.track))

  let tag = @widgets.UiTag(b, "新", theme=l)
  assert_true(
    ui_test_has_fill(
      ui_test_redraw(b, tag.widget()),
      l.tone_surface(@widgets.UiTone::UiAccent),
    ),
  )
  tag.set_theme(d)
  assert_true(
    ui_test_has_fill(
      ui_test_redraw(b, tag.widget()),
      d.tone_surface(@widgets.UiTone::UiAccent),
    ),
  )

  // 输入两层壳：外层边色、内层面色都要换
  let input = @widgets.UiTextInput(b, theme=l)
  let shell = input.view().children()[0]
  let inner = shell.children()[0]
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(l.border)),
  )
  assert_eq(
    inner.style().unwrap().background,
    Some(@widgets.ui_color(l.surface)),
  )
  input.set_theme(d)
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(d.border)),
  )
  assert_eq(
    inner.style().unwrap().background,
    Some(@widgets.ui_color(d.surface)),
  )

  let spin = @widgets.UiSpinbox(b, value=1, theme=l)
  let spin_shell = spin.view().children()[0].children()[0]
  assert_eq(
    spin_shell.style().unwrap().background,
    Some(@widgets.ui_color(l.border)),
  )
  spin.set_theme(d)
  assert_eq(
    spin_shell.style().unwrap().background,
    Some(@widgets.ui_color(d.border)),
  )
}

///|
/// 换主题时按文案量出来的固有尺寸必须一起重算：字号从 13 变 15（大档），
/// 文案宽度跟着变；只换色不换尺寸会得到"深色的字挤在浅色的框里"。
test "set_theme 同步重算按文案量的尺寸（T357）" {
  let b = mock()
  let l = @widgets.UiTheme::light()
  let d = @widgets.UiTheme::dark()
  let rad = @widgets.UiRadioGroup(b, ["甲", "乙"], selected=0, theme=l)
  let h0 = ui_test_fill(ui_test_redraw(b, rad.rows[0])).3
  rad.set_theme(d, size=@widgets.UiLarge)
  let h1 = ui_test_fill(ui_test_redraw(b, rad.rows[0])).3
  // 大档字号 15 vs 13：圆环直径随字号变大（不是只把颜色换成深色）
  assert_true(h1 > h0)
  // 换回中档浅色：尺寸与颜色都回到起点，没有累积漂移
  rad.set_theme(l, size=@widgets.UiMedium)
  assert_eq(ui_test_fill(ui_test_redraw(b, rad.rows[0])).3, h0)
  assert_true(ui_test_has_fill(ui_test_redraw(b, rad.rows[0]), l.accent))
}

///|
/// `T357`：不定档不是"画一段假进度"，而是控件自己有一条帧链。相位函数是纯的
/// （逐拍可断言），链在关档后自己收（不留空转定时器），亮条在槽里来回走。
test "UiProgress 不定档：相位来回、帧链推进、关掉自动收链（T357）" {
  // 纯相位：0 → 1 → 0，端点精确（PingPong 取模的边界最容易写错一拍）
  assert_eq(@widgets.ui_progress_phase(0), 0.0)
  assert_eq(@widgets.ui_progress_phase(450), 0.5)
  assert_eq(@widgets.ui_progress_phase(900), 1.0)
  assert_eq(@widgets.ui_progress_phase(1800), 0.0)
  assert_true(@widgets.ui_progress_phase(225) > 0.24)
  assert_true(@widgets.ui_progress_phase(225) < 0.26)
  assert_true(@widgets.ui_progress_phase(1350) > 0.49)
  assert_true(@widgets.ui_progress_phase(1350) < 0.51)

  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let now : Array[Int32] = [0]
  app.set_anim_clock(fn() { now[0] })
  let bar = @widgets.UiProgress(
    b,
    value=0.4,
    width=200.0,
    indeterminate=true,
    app=Some(app),
  )
  assert_true(bar.indeterminate())
  let dl0 = ui_test_redraw(b, bar.widget())
  // 轨道 + 一段短亮条（不是确定性进度的 40% 长条）
  assert_eq(ui_test_count(dl0).1, 2)
  let x0 = ui_test_last_fill(dl0).0
  // 第一拍立即点火，相位从 16ms 那一档起步
  assert_true(app.step())
  assert_true(bar.phase() > 0.0)
  assert_true(bar.phase() < 0.1)
  // 推进到接近折返点：亮条走到最右端附近
  let mut n = 0
  while n < 55 {
    now[0] = now[0] + 16
    let _ = app.step()
    n = n + 1
  }
  assert_true(bar.phase() > 0.9)
  let dl1 = ui_test_redraw(b, bar.widget())
  // 亮条的位置真的变了（两份清单里第二笔填充的 x 不同）
  assert_true(ui_test_last_fill(dl1).0 != x0)
  // 关档：相位归零、下一拍链自己收掉，绝不空转
  bar.set_indeterminate(false)
  assert_false(bar.indeterminate())
  assert_eq(bar.phase(), 0.0)
  now[0] = now[0] + 16
  let _ = app.step()
  assert_false(bar.ticking())
  // 确定性那一档照旧：值 0.4 → 80px 的那一截
  let dl2 = ui_test_redraw(b, bar.widget())
  assert_eq(ui_test_last_fill(dl2).2, ui_test_fill(dl2).2 * 0.4)
  @moonui.Backend::terminate(b)
}

///|
/// 颜色是否严格落在两端之间（端点不算）：动画中间帧的抓手。逐通道比较，
/// 不用亮度——两个深蓝的亮度差可能被取整抹平。
fn ui_test_between_color(c : Int32, a : Int32, z : Int32) -> Bool {
  let mut strict = false
  for shift in [16, 8, 0] {
    let v = (c >> shift) & 255
    let lo = if a < z { (a >> shift) & 255 } else { (z >> shift) & 255 }
    let hi = if a < z { (z >> shift) & 255 } else { (a >> shift) & 255 }
    if v < lo || v > hi {
      return false
    }
    if v > lo && v < hi {
      strict = true
    }
  }
  strict
}

///|
/// `T357`：hover/press 不再硬切——Core 的帧链推 0..1 强度，绘制端按强度混色。
/// 端点与旧版逐位相同（前面那 79 条判据就是回归网），中间帧必须真的落在两端
/// 之间；反向要能从当下值续跑，不是先跳回静息再重播。
test "UiButton：三态过渡走帧链，中间帧是混色、反向从当下续跑（T357）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let now : Array[Int32] = [0]
  app.set_anim_clock(fn() { now[0] })
  let l = @widgets.UiTheme::light()
  let btn = @widgets.UiButton(b, "保存", theme=l, app=Some(app))
  let w = btn.widget()
  let c0 = ui_test_fill(ui_test_redraw(b, w)).5
  assert_eq(c0, l.accent)

  let target = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(@moonui.MouseEnter(target))
  let _ = app.step()
  let c1 = ui_test_fill(ui_test_redraw(b, w)).5
  assert_true(ui_test_between_color(c1, l.accent, l.accent_hover))
  // 十拍到 160ms：落在精确的 hover 端点
  let mut n = 0
  while n < 9 {
    now[0] = now[0] + 16
    let _ = app.step()
    n = n + 1
  }
  let c2 = ui_test_fill(ui_test_redraw(b, w)).5
  assert_eq(c2, l.accent_hover)

  // 反向：第一帧应落在 hover→静息之间，而不是直接跳回静息
  let _ = w.fire(@moonui.MouseLeave(target))
  let _ = app.step()
  let c3 = ui_test_fill(ui_test_redraw(b, w)).5
  assert_true(ui_test_between_color(c3, l.accent, l.accent_hover))
  assert_true(c3 != c0)
  n = 0
  while n < 9 {
    now[0] = now[0] + 16
    let _ = app.step()
    n = n + 1
  }
  assert_eq(ui_test_fill(ui_test_redraw(b, w)).5, l.accent)

  // 关掉 App 的调用方仍是硬切：mock 判据不用开时钟
  let plain = @widgets.UiButton(b, "保存", theme=l)
  let pw = plain.widget()
  let _ = pw.fire(
    @moonui.MouseEnter(@moonui.EventTarget::of(pw.handle().unwrap())),
  )
  assert_eq(ui_test_fill(ui_test_redraw(b, pw)).5, l.accent_hover)
  @moonui.Backend::terminate(b)
}

///|
/// 造一个只带 key 的按键事件（修饰键全关），判据里方向键用。
fn ui_test_key(k : String) -> @moonui.KeyPress {
  @moonui.KeyPress::{
    key: k,
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
}

///|
/// `T357`：分段与页签共用 `ui_strip_watch`，于是左右键换档也一次到位——
/// 首尾环绕、同一格不重复回调（与点击共用 `ui_strip_commit`）。
test "Segmented / Tabs：左右键换档、首尾环绕（T357）" {
  let b = mock()
  let seg = @widgets.UiSegmented(b, ["低", "中", "高"], selected=1)
  let w = seg.widget()
  let t = @moonui.EventTarget::of(w.handle().unwrap())
  let seen : Array[Int32] = []
  seg.on_change(fn(i) { seen.push(i) })
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(seg.selected(), 2)
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(seg.selected(), 0)
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Left")))
  assert_eq(seg.selected(), 2)
  // 无关按键不进这条链
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Enter")))
  assert_eq(seg.selected(), 2)
  assert_eq(seen, [2, 0, 2])

  let tabs = @widgets.UiTabs(b, ["甲", "乙", "丙"], selected=0)
  let tw = tabs.view()
  let tt = @moonui.EventTarget::of(tw.handle().unwrap())
  let _ = tw.fire(@moonui.KeyDown(tt, ui_test_key("Left")))
  assert_eq(tabs.selected(), 2)
  let _ = tw.fire(@moonui.KeyDown(tt, ui_test_key("Right")))
  assert_eq(tabs.selected(), 0)
}

///|
/// `T357`：滚轮落在输入框或步进器上都推一步；负增量往回走，range 外夹住不回调。
test "UiSpinbox：滚轮上滚加、下滚减，越界不回调（T357）" {
  let b = mock()
  let spin = @widgets.UiSpinbox(b, value=5, min=0, max=10, step=2)
  let seen : Array[Int32] = []
  spin.on_change(fn(v) { seen.push(v) })
  let field = spin.input().field()
  let ft = @moonui.EventTarget::of(field.handle().unwrap())
  let _ = field.fire(@moonui.Scroll(ft, @moonui.LogicalPoint(0.0, 120.0)))
  assert_eq(spin.value(), 7)
  let st = @moonui.EventTarget::of(spin.stepper().handle().unwrap())
  let _ = spin
    .stepper()
    .fire(@moonui.Scroll(st, @moonui.LogicalPoint(0.0, -120.0)))
  assert_eq(spin.value(), 5)
  // 零增量不做事；越界夹到端点且不重复回调
  let _ = field.fire(@moonui.Scroll(ft, @moonui.LogicalPoint(0.0, 0.0)))
  assert_eq(spin.value(), 5)
  let mut n = 0
  while n < 10 {
    let _ = field.fire(@moonui.Scroll(ft, @moonui.LogicalPoint(0.0, 120.0)))
    n = n + 1
  }
  assert_eq(spin.value(), 10)
  assert_eq(seen, [7, 5, 7, 9, 10])
}
