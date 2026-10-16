// 组合组件的黑盒测试：全部走公共 API（`@moonui.` 前缀），在 MockBackend 上
// 断言状态、文案与使能态——真后端上这些是原生属性，语义必须先在 mock 定死。
// 树内控件通过 `view().children()` 取：组件不公开内部句柄，测试也按用户姿势来。

///|
/// `T88④` 判据·设置中心（表单/主题/偏好/异步档）：表单档四控件的值往返、
/// 浅深主题切换的真语义（App 底样式跟上——`T86⑦` 持久化闭环的应用半）、
/// 偏好档状态（应用到后端读数由注入底座自理——泵闸门判据在 `T87③` 在案）、
/// `T85①` 异步档经一圈 `step` 落进状态行。持久化闭环的文件半判据在
/// demo_dx_file_native.mbt（native 门控——wasm 没有文件系统）。
test "SettingsDemo：表单档值往返、主题切换与偏好档（T88④判据·设置中心）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.SettingsDemo::demo(app, @moonui.LogicalSize(800.0, 600.0))
  // 表单档默认账
  assert_eq(demo.username_text(), "用户名")
  assert_false(demo.notify_checked())
  assert_eq(demo.engine_selected(), 0)
  assert_eq(demo.channel_selected(), 0)
  assert_eq(demo.theme(), @moonui.Theme::Light)
  assert_false(demo.reduced_motion())
  // 值往返：四种表单控件各一只（条目原文的形状）
  demo.set_username("明")
  demo.set_notify(true)
  demo.set_engine(1)
  demo.set_channel(1)
  assert_eq(demo.username_text(), "明")
  assert_true(demo.notify_checked())
  assert_eq(demo.engine_selected(), 1)
  assert_eq(demo.channel_selected(), 1)
  // 浅深主题切换真语义：应用档与 App 档一起走
  demo.set_theme_choice(@moonui.Theme::Dark)
  assert_eq(demo.theme(), @moonui.Theme::Dark)
  assert_eq(app.theme(), @moonui.Theme::Dark)
  // 偏好档：状态真应用半由注入底座复验（Mock 注入后读数翻转）
  demo.set_reduced_motion(true)
  assert_true(demo.reduced_motion())
  b.set_prefers_reduced_motion(true)
  assert_true(@moonui.Backend::get_prefers_reduced_motion(b))
  // 异步档（T85① 可用性）：post_task 一圈落状态行
  let _ = demo.refresh_async()
  assert_true(app.step())
  assert_eq(demo.status_text(), "偏好已同步（异步档）")
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88④` 判据·Markdown 编辑器（无文件半）：分栏、行账与预览最小编排。
/// 子集注记的形状判据：标题 / 列表 / 粗体 / 正文四类行，空行不进账；预览侧
/// 按行账用现有组件拼（标题加粗、列表垫 "• "、粗体加粗、正文原样）——现有
/// 组件的最小编排，不是渲染器。文件半判据在 demo_dx_file_native.mbt。
test "MarkdownDemo：分栏、行账与预览最小编排（T88④判据·编辑器）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.MarkdownDemo::demo(
    app, "# 标题\n\n- 一\n**粗体**\n正文",
  )
  // 分栏：内容根 Row 两格（左编辑右预览），编辑器是多行域
  let root = demo.window().content()
  assert_true(root is Some(_))
  match root {
    Some(r) => {
      assert_eq(r.kind(), @moonui.WidgetKind::Row)
      assert_eq(r.children().length(), 2)
      assert_eq(r.children()[0].kind(), @moonui.WidgetKind::MultilineEntry)
      assert_eq(r.children()[1].kind(), @moonui.WidgetKind::Column)
    }
    None => assert_true(false) // unreachable
  }
  // 行账：标题/列表/粗体/正文四类，空行不进账（子集注记的形状判据）
  assert_eq(demo.parsed(), [
    @moonui.MarkdownLine::{
      kind: @moonui.MarkdownKind::Heading,
      text: "标题",
    },
    @moonui.MarkdownLine::{ kind: @moonui.MarkdownKind::Bullet, text: "一", },
    @moonui.MarkdownLine::{ kind: @moonui.MarkdownKind::Bold, text: "粗体", },
    @moonui.MarkdownLine::{ kind: @moonui.MarkdownKind::Plain, text: "正文", },
  ])
  // 预览拼排：顺序即行账顺序；标题与粗体加粗（样式账），列表垫 "• "
  assert_eq(demo.preview_texts(), ["标题", "• 一", "粗体", "正文"])
  match demo.window().content() {
    None => assert_true(false) // unreachable
    Some(r) => {
      let preview = r.children()[1]
      let bold_style = @moonui.style(font_weight=Some(@moonui.FontWeight::Bold))
      assert_eq(preview.children()[0].style(), Some(bold_style))
      assert_eq(preview.children()[1].style(), None)
      assert_eq(preview.children()[2].style(), Some(bold_style))
      assert_eq(preview.children()[3].style(), None)
    }
  }
  // 编辑器文本往返
  assert_eq(demo.editor_text(), "# 标题\n\n- 一\n**粗体**\n正文")
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88④` 判据·数据后台（虚拟化账）：1000 行合成数据上复验"视口外零句柄"
/// ——窗口行数 = 视口高 ÷ 行高 + 1 半行档，出窗回收、同窗幂等、换页净零；
/// 分页是滚动偏移的跳账（表格页跟着 offset 走，VirtualList 不重建）；行账
/// 确定性可逐行断言。过滤切换账在下面一条。
test "DataAdminDemo：虚拟化账在 1000 行合成数据上复验（T88④判据·数据后台）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.DataAdminDemo::demo(app)
  // 确定性账：id 0..999、部门按清单轮转
  assert_eq(demo.rows(), 1000)
  assert_eq(demo.row(0), @moonui.AdminRow::{
    id: 0,
    name: "员工 0",
    dept: "研发",
  })
  assert_eq(demo.row(1), @moonui.AdminRow::{
    id: 1,
    name: "员工 1",
    dept: "产品",
  })
  assert_eq(demo.row(999), @moonui.AdminRow::{
    id: 999,
    name: "员工 999",
    dept: "市场",
  })
  assert_eq(demo.pages(), 50)
  assert_eq(demo.page(), 1)
  // 视口推进（判据显式给偏移——T86④ 的窗口语义）：160 视口 → 6 行
  demo.sync_rows(0.0, 160.0)
  assert_eq(demo.materialized(), 6)
  assert_eq(demo.materialized_first(), 0)
  let live_window = b.live()
  // 同参数幂等：零建零毁
  demo.sync_rows(0.0, 160.0)
  assert_eq(b.live(), live_window)
  // 分页账：第 3 页 = 偏移 (3-1)×20×32 → 首行 40；出窗回收 + 补建净零
  demo.show_page(3)
  assert_eq(demo.page(), 3)
  assert_eq(demo.materialized_first(), 40)
  assert_eq(demo.materialized(), 6)
  assert_eq(b.live(), live_window)
  // 表尾夹档：第 50 页首行 980（980+6 ≤ 1000，夹在列表两端）
  demo.show_page(50)
  assert_eq(demo.materialized_first(), 980)
  assert_eq(b.live(), live_window)
  // 拉回表头：窗口行的重建账照常（表里没有废账）
  demo.show_page(1)
  assert_eq(demo.materialized_first(), 0)
  assert_eq(b.live(), live_window)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88④` 判据·过滤切换账：行账按部门切片、页码归 1、表格页与分页条整只
/// 重建（count/total 都与行数绑死——静态 count 档的既定语义，重建不是绕行）。
/// 用户路径（原生选中 + 派 Change，§48-16 形状）与程序路径共账；分页条用户
/// 路径换页接到同一条跳账上。
test "DataAdminDemo：过滤切换重建与分页条重建（T88④判据·过滤切换账）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.DataAdminDemo::demo(app)
  demo.sync_rows(0.0, 160.0)
  // 用户路径过滤：原生选中 + 派 Change（产品 = 清单下标 1）
  demo.wire_filter()
  let filter = demo.filter_view()
  filter.set_selected(2)
  let _ = filter.fire(@moonui.Event::Change(filter.target()))
  assert_eq(demo.rows(), 250)
  assert_eq(demo.pages(), 13)
  assert_eq(demo.page(), 1)
  assert_eq(demo.row(0), @moonui.AdminRow::{
    id: 1,
    name: "员工 1",
    dept: "产品",
  })
  assert_eq(demo.materialized_first(), 0)
  assert_eq(demo.materialized(), 6)
  // 程序路径过滤（共账）：研发
  demo.apply_filter(1)
  assert_eq(demo.rows(), 250)
  assert_eq(demo.pages(), 13)
  assert_eq(demo.row(0), @moonui.AdminRow::{
    id: 0,
    name: "员工 0",
    dept: "研发",
  })
  // 分页条用户路径换页：页码按钮派 Click → 跳账（重建后的分页条照账）
  demo.wire_pager()
  let page2 = demo.pager_view().children()[2]
  let _ = page2.fire(
    @moonui.Event::Click(page2.target(), @moonui.MouseButton::Left),
  )
  assert_eq(demo.page(), 2)
  assert_eq(demo.materialized_first(), 20)
  assert_eq(demo.materialized(), 6)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}
