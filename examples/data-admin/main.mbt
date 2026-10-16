///|
/// `T88④` 第三个验证性示例：数据后台。验证的地基是 `T86④` 虚拟化账——
/// 1000 行合成数据上"视口外零句柄"复验（表格页推进靠判据显式给偏移）、
/// 分页是滚动偏移的跳账（VirtualList 不重建）、过滤切换整只重建（count 与
/// 行数绑死）。无头演示，真窗滚动留给 owner 手动跑。
fn main raise {
  let app = @common.new_app()
  let demo = @moonui.DataAdminDemo::demo(app)
  println("[Demo 9] 数据后台")
  println(
    "  合成数据：" +
    demo.rows().to_string() +
    " 行，" +
    demo.pages().to_string() +
    " 页",
  )
  let r0 = demo.row(0)
  let r1 = demo.row(1)
  println(
    "  行账确定性：\{r0.id} \{r0.name}（\{r0.dept}）｜ \{r1.id} \{r1.name}（\{r1.dept}）",
  )
  demo.sync_rows(0.0, 160.0)
  println(
    "  表格页：视口 160 → materialized " +
    demo.materialized().to_string() +
    " 行（视口外零句柄）",
  )
  demo.show_page(3)
  println(
    "  第 3 页：首行 " +
    demo.materialized_first().to_string() +
    "（offset 跳账，VirtualList 不重建）",
  )
  demo.apply_filter(2)
  demo.sync_rows(0.0, 160.0)
  println(
    "  过滤「产品」：" +
    demo.rows().to_string() +
    " 行，" +
    demo.pages().to_string() +
    " 页，首行 " +
    demo.materialized_first().to_string(),
  )
  demo.show_page(13)
  println(
    "  表尾第 13 页：首行 " +
    demo.materialized_first().to_string() +
    "（夹在列表两端）",
  )
  app.quit()
  app.run()
  let b = app.backend()
  let stats = b.handle_stats()
  println(
    "  退出句柄统计：live=" +
    stats.live.to_string() +
    " 峰值=" +
    stats.high_water.to_string() +
    "（过滤重建回收过整棵表格页——峰值照见）",
  )
}
