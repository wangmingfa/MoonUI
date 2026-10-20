// 组合组件的黑盒测试：全部走公共 API（`@moonui.` 前缀），在 MockBackend 上
// 断言状态、文案与使能态——真后端上这些是原生属性，语义必须先在 mock 定死。
// 树内控件通过 `view().children()` 取：组件不公开内部句柄，测试也按用户姿势来。

///|
/// RadioGroup 的程序设值与用户换选：回调携带新下标，程序赋值不回声。
test "RadioGroup：换选回调带下标，程序设值不回声" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let group = @moonui.RadioGroup::new(b, ["苹果", "香蕉", "樱桃"], 0)
  assert_eq(group.selected(), 0)
  assert_eq(group.selected_text(), "苹果")
  // 程序设值：状态与文案都跟上，但没有回调
  let mut hits = 0
  group.on_change(fn(_) { hits = hits + 1 })
  group.set_selected(2)
  assert_eq(group.selected(), 2)
  assert_eq(group.selected_text(), "樱桃")
  assert_eq(hits, 0)
  // 用户换选：先让原生选中（模拟用户点选），再派 Change（§48-16 的形状）
  let radio = group.view().children()[0]
  radio.set_selected(1)
  let _ = radio.fire(Change(radio.target()))
  assert_eq(group.selected(), 1)
  assert_eq(group.selected_text(), "香蕉")
  // 说明文案跟着换选走
  let caption = group.view().children()[1]
  assert_eq(caption.text(), "当前：香蕉")
  assert_eq(hits, 1)
  // 越界的程序设值原样不动
  group.set_selected(9)
  assert_eq(group.selected(), 1)
  @moonui.Backend::terminate(b)
}

///|
/// Alert 的标题 / 情绪 / 说明原地改；Card 的标题原地改。
test "Alert 与 Card：文案原地改，情绪重拼标题" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let alert = @moonui.Alert::new(b, AlertInfo, "提示", "一条普通提示")
  assert_eq(alert.view().children()[0].text(), "ℹ 提示")
  // 改标题不改情绪，改情绪要用"当下这份"标题
  alert.set_title("注意")
  alert.set_type(AlertWarning)
  assert_eq(alert.view().children()[0].text(), "⚠ 注意")
  alert.set_description("文案换了")
  assert_eq(alert.view().children()[1].text(), "文案换了")
  let card = @moonui.Card::new(b, "订单详情", [
    @moonui.Widget::label(b, "行一"),
  ])
  card.set_title("会员详情")
  assert_eq(card.view().children()[0].text(), "会员详情")
  // Card 骨架：标题、分隔线、内容，顺序不可乱
  assert_eq(card.view().children().length(), 3)
  assert_eq(card.view().children()[2].text(), "行一")
  @moonui.Backend::terminate(b)
}

///|
/// Steps 的圆点跟 current 走，越界夹紧；步数与箭头是骨架。
test "Steps：圆点跟 current 走，越界夹紧" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let steps = @moonui.Steps::new(b, ["下单", "付款", "发货", "收货"], 1)
  // 三只箭头 + 四个步骤 = 7 格
  assert_eq(steps.view().children().length(), 7)
  assert_eq(steps.view().children()[0].text(), "○ 下单")
  assert_eq(steps.view().children()[2].text(), "● 付款")
  steps.set_current(3)
  assert_eq(steps.view().children()[0].text(), "○ 下单")
  assert_eq(steps.view().children()[6].text(), "● 收货")
  // 越界：两头都夹到边界
  steps.set_current(-4)
  assert_eq(steps.current(), 0)
  assert_eq(steps.view().children()[0].text(), "● 下单")
  steps.set_current(99)
  assert_eq(steps.current(), 3)
  @moonui.Backend::terminate(b)
}

///|
/// Breadcrumb：点哪段回调哪个下标，最后一段是当前页、不可点。
test "Breadcrumb：点哪段回调哪个下标" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let bc = @moonui.Breadcrumb::new(b, ["首页", "订单列表", "订单详情"])
  let mut got = -1
  bc.on_navigate(fn(i) { got = i })
  // 三段两斜杠：按钮、/、按钮、/、当前页（Label）
  let cells = bc.view().children()
  assert_eq(cells.length(), 5)
  assert_eq(cells[4].text(), "订单详情")
  let _ = cells[2].fire(Click(cells[2].target(), Left))
  assert_eq(got, 1)
  let _ = cells[0].fire(Click(cells[0].target(), Left))
  assert_eq(got, 0)
  @moonui.Backend::terminate(b)
}

///|
/// Pagination：页码、边界禁用、用户回调与程序设值分家。
test "Pagination：页码往返与边界禁用" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let pg = @moonui.Pagination::new(b, 45, 10)
  assert_eq(pg.pages(), 5)
  assert_eq(pg.page(), 1)
  // cells：上一页、1..5、下一页、说明，共 8 格
  let cells = pg.view().children()
  assert_eq(cells.length(), 8)
  // 第一页：上一页禁用、下一页可用、当前页「1」且禁用
  assert_false(cells[0].enabled())
  assert_true(cells[6].enabled())
  assert_eq(cells[1].text(), "「1」")
  assert_false(cells[1].enabled())
  assert_eq(cells[7].text(), "共 45 条 / 5 页")
  // 用户点第 3 页：状态、文案、使能态、回调一起跟上
  let mut got = 0
  pg.on_change(fn(p) { got = p })
  let _ = cells[3].fire(Click(cells[3].target(), Left))
  assert_eq(pg.page(), 3)
  assert_eq(got, 3)
  assert_eq(cells[1].text(), "1")
  assert_true(cells[1].enabled())
  assert_eq(cells[3].text(), "「3」")
  // 末页：下一页禁用；点「下一页」被夹住、不回调
  pg.set_page(5)
  assert_eq(pg.page(), 5)
  assert_false(cells[6].enabled())
  let before = got
  let _ = cells[6].fire(Click(cells[6].target(), Left))
  assert_eq(pg.page(), 5)
  assert_eq(got, before)
  // 程序设值：夹紧、不回调
  pg.set_page(0)
  assert_eq(pg.page(), 1)
  assert_eq(got, before)
  @moonui.Backend::terminate(b)
}

///|
/// Rate：点星打分、程序设值夹紧，星与星之间只有文案差。
test "Rate：点星打分，程序设值夹紧" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let rate = @moonui.Rate::new(b, 5, 2)
  let stars = rate.view().children()
  assert_eq(stars.length(), 5)
  assert_eq(stars[0].text(), "★")
  assert_eq(stars[2].text(), "☆")
  let mut got = 0
  rate.on_change(fn(v) { got = v })
  // 点第 4 颗（下标 3）：4 分
  let _ = stars[3].fire(Click(stars[3].target(), Left))
  assert_eq(rate.value(), 4)
  assert_eq(got, 4)
  assert_eq(stars[3].text(), "★")
  assert_eq(stars[4].text(), "☆")
  // 程序设值：夹到 0..max，不回调
  rate.set_value(99)
  assert_eq(rate.value(), 5)
  assert_eq(got, 4)
  rate.set_value(0)
  assert_eq(rate.value(), 0)
  assert_eq(stars[0].text(), "☆")
  @moonui.Backend::terminate(b)
}

///|
/// Tabs：点页签只改状态并回调，树由调用方按需重建；数量不齐是明确错误。
test "Tabs：点页签改状态回调，重建由调用方做" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let tabs = @moonui.Tabs::new(backend, ["水果", "蔬菜"], [
    fn() raise @moonui.UiError { @moonui.Widget::label(backend, "苹果页") },
    fn() raise @moonui.UiError { @moonui.Widget::label(backend, "菠菜页") },
  ])
  // view() 每次都是新树：头两颗按钮 + 分隔线 + 当前页内容
  let tree = tabs.view()
  let head = tree.children()[0]
  assert_eq(head.children()[0].text(), "● 水果")
  assert_eq(head.children()[1].text(), "○ 蔬菜")
  assert_eq(tree.children()[2].text(), "苹果页")
  // 数量不齐：明确报错而不是悄悄越界
  let msg = try {
    let _ = @moonui.Tabs::new(backend, ["a", "b"], [
      fn() raise @moonui.UiError { @moonui.Widget::label(backend, "x") },
    ])
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(
    msg,
    Some("操作失败：页签标题与内容的数量必须一致"),
  )
  // 用户点第二个页签：状态与回调一起上，树没变（重建是调用方的事）
  let mut got = -1
  tabs.on_change(fn(i) { got = i })
  let btn2 = head.children()[1]
  let _ = btn2.fire(Click(btn2.target(), Left))
  assert_eq(tabs.current(), 1)
  assert_eq(got, 1)
  // 重建后的新树按新 current 摆内容、标圆点
  let tree2 = tabs.view()
  let head2 = tree2.children()[0]
  assert_eq(head2.children()[0].text(), "○ 水果")
  assert_eq(head2.children()[1].text(), "● 蔬菜")
  assert_eq(tree2.children()[2].text(), "菠菜页")
  // 程序 select：夹紧、不回调
  tabs.select(99)
  assert_eq(tabs.current(), 1)
  tabs.select(0)
  assert_eq(tabs.current(), 0)
  assert_eq(got, 1)
  @moonui.Backend::terminate(b)
}

///|
/// `T86④` 判据·视口外零句柄 + 出窗回收：窗口 = 视口行数 + 1 行半行档，
/// 出窗的行整棵 `close_tree`（句柄归表，`T49` 族机制）、同参数重复 sync 幂等。
/// 1000 行 × 行高 32、视口 320 → 11 行 materialized；滚动轴上是后端的事（§14），
/// 推进靠调用方显式给偏移——判据钉的是"句柄总量恒等于常驻视口 + 窗内行"。
test "VirtualList：视口外零句柄，出窗回收，同窗幂等（T86④判据）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let list = @moonui.VirtualList::new(b, 1000, 32.0, fn(
    i,
  ) raise @moonui.UiError {
    @moonui.Widget::button(b, "行 \{i}")
  })
  // 开窗档：视口 320 → ceil(320/32) + 1 = 11 行
  list.sync(0.0, 320.0)
  assert_eq(list.materialized_count(), 11)
  assert_eq(list.materialized_first(), 0)
  // 常驻 1 只（Scroll 视口，T74）+ 11 只行按钮；填充与 Sized 包装零句柄
  assert_eq(b.live(), 12)
  // 同参数重复 sync：幂等空操作，零建零毁
  list.sync(0.0, 320.0)
  assert_eq(b.live(), 12)
  // 推进到行 100（偏移 3200 = 100 × 32）：出窗的 11 行回收、新 11 行建成，
  // 句柄总量恒定——"视口外零句柄"的直接后果
  list.sync(3200.0, 320.0)
  assert_eq(list.materialized_first(), 100)
  assert_eq(list.materialized_count(), 11)
  assert_eq(b.live(), 12)
  // 推过列表尾：窗口夹到空档，只剩常驻视口一只
  list.sync(32000.0, 320.0)
  assert_eq(list.materialized_count(), 0)
  assert_eq(b.live(), 1)
  // 拉回表头：回收过的行号重建照常（表里没有废账）
  list.sync(0.0, 320.0)
  assert_eq(list.materialized_first(), 0)
  assert_eq(b.live(), 12)
  // 整棵关账：树干 + 窗内行全部归还，句柄表归零（§8 的回收账干净）
  list.view().close_tree()
  assert_eq(b.live(), 0)
  @moonui.Backend::terminate(b)
}

///|
test "VirtualList：负行数与零行高显式报错，零列表开空窗（T86④·§33）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let msgs : Array[String] = []
  let msg1 = try {
    let _ = @moonui.VirtualList::new(b, -1, 32.0, fn(_) raise @moonui.UiError {
      @moonui.Widget::button(b, "x")
    })
    "no error"
  } catch {
    e => e.message()
  }
  msgs.push(msg1)
  let msg2 = try {
    let _ = @moonui.VirtualList::new(b, 10, 0.0, fn(_) raise @moonui.UiError {
      @moonui.Widget::button(b, "x")
    })
    "no error"
  } catch {
    e => e.message()
  }
  msgs.push(msg2)
  assert_eq(msgs, [
    "操作失败：列表行数不能为负", "操作失败：虚拟列表的行高必须为正",
  ])
  // 零列表：sync 开空窗，填充零高，只剩常驻视口
  let empty = @moonui.VirtualList::new(b, 0, 32.0, fn(_) raise @moonui.UiError {
    @moonui.Widget::button(b, "x")
  })
  empty.sync(0.0, 320.0)
  assert_eq(empty.materialized_count(), 0)
  assert_eq(b.live(), 1)
  empty.view().close_tree()
  assert_eq(b.live(), 0)
  @moonui.Backend::terminate(b)
}

///|
test "VirtualList：窗口行的文档位置随偏移走（T86④·行程账）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let list = @moonui.VirtualList::new(backend, 100, 32.0, fn(
    i,
  ) raise @moonui.UiError {
    @moonui.Widget::button(backend, "行 \{i}")
  })
  list.sync(320.0, 320.0)
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(list.view())
  // 文档区 = Scroll 的唯一子项；孩子在 [top_filler, *rows, bottom_filler]
  let doc = list.view().children()[0]
  assert_eq(doc.children().length(), 13)
  // 第 10 行（首行）的按钮落在文档 y = 10 × 32 = 320，行高被 Sized 锁成 32——
  // 窗口外的 320 行程由纯布局填充占位（零句柄），文档总长恒等于 100 × 32
  let first_row_btn = doc.children()[1].children()[0]
  assert_eq(first_row_btn.frame().origin.y, 320.0)
  assert_eq(first_row_btn.frame().size.height, 32.0)
  // 末行（行 20）落在 20 × 32 = 640；它之后到底（3200）全是 bottom_filler 的行程
  let last_row_btn = doc.children()[11].children()[0]
  assert_eq(last_row_btn.frame().origin.y, 640.0)
  // 推进偏移再排一次：同一批按钮的账挪到新窗口位置，回收/补建照旧
  list.sync(640.0, 320.0)
  win.relayout()
  assert_eq(list.materialized_first(), 20)
  let moved = doc.children()[1].children()[0]
  assert_eq(moved.frame().origin.y, 640.0)
  // 句柄账：幸存 1 行 + 常驻视口 + 重建 10 行 = 12 只控件，加上窗口自己
  // （mock 的句柄表里窗口也占一格）= 13；回收 10、补建 10，净零
  assert_eq(b.live(), 13)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}
