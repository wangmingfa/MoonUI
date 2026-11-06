///|
/// 播放列表（Luna：侧栏 + 工具条 + 列头 + VirtualList + 属性栏）。
///
/// 第二期把「列表管理」落在这一层：侧栏导航（`T179`：我的音乐/我喜欢的/
/// 播放队列 + 每张歌单一条，`T175` 的横向页签行整行撤掉）、
/// 排序（点列头切换升降）、搜索（输入即过滤，只动视图不动播放）、
/// m3u 导入导出、底部属性栏（右键「属性」把那首的详情摆出来）。
/// 行账 = 当前视图（app 侧算好传进来），增删与视图变化都走 app 的整树重建
/// （Window::set_content，children 对外部包只读，这是唯一干净的换树口）。
/// 双击播放的接线在 build_row 闭包里（app 装配），行索引在闭包捕获时钉死。
/// 物化窗口由 sync 推进：VirtualList 只在显式 sync 后才建行（组件的既定语义），
/// 挂在**挂树前**调用——行随整树一起 attach。
const CM_ROW_HEIGHT : Double = 20.0

///|
/// 侧栏宽（`T179`）。Winamp 式紧凑：固定项文案「播放队列」四个字（10pt）
/// 加内边距装得下就够，再宽是白吃列表区的地——`T178` 的五列定宽（30/104/
/// 90/46/18）不缩，标题列 expand 吃剩余，侧栏每宽一档标题列就窄一档。
pub fn cm_sidebar_w() -> Double {
  96.0
}

///|
/// 首屏物化的视口高度（逻辑像素）。真滚动偏移回流是另一条 ABI 的账
/// （组件段注），第一期先按「一屏 + 余量」物化：几百首以内全量可见，
/// 更大的库只露前 ~30 行（挂账见 DESIGN.md C-10 风险 5）。
const CM_SYNC_VIEWPORT : Double = 900.0

///|
/// 列表区的操作回调：全部由 app 提供（app 持有库与播放器，这里只发信号）。
/// 签名统一不带 raise——按钮回调里的 raise 不许跨 C 帧，收口在 app 那侧。
pub(all) struct TableHooks {
  on_play_all : () -> Unit
  on_add_dir : () -> Unit
  on_clear : () -> Unit
  on_import : () -> Unit
  on_export : () -> Unit
  on_search : (String) -> Unit
  /// 排序列：0 = 原始顺序 / 1 = 标题 / 2 = 歌手 / 3 = 专辑 / 4 = 时长
  on_sort : (Int32) -> Unit
  /// 页签：0 = 本地音乐 / 1 = 我喜欢的 / 2 = 播放队列
  on_tab : (Int32) -> Unit
  /// 手动重扫（`T172`）：把已有目录整份重走一遍行走 + 探针，替换曲库本体。
  /// 文件删了要重启才消失、改了标签得清库重来——这条就是那两个洞的出口。
  on_rescan : () -> Unit
  // ——歌单页签（`T175`）——
  /// 页签行末「＋」：新建歌单（弹名字小窗）。
  on_playlist_new : () -> Unit
  /// 歌单页签右键「重命名」：收歌单序号（playlists 数组下标，0 起）。
  on_playlist_rename : (Int32) -> Unit
  /// 歌单页签右键「删除」：同样收歌单序号。
  on_playlist_delete : (Int32) -> Unit
}

///|
/// 列表区的可握把手：root 进列表窗，其余供 app 读状态/改文案。
pub(all) struct TrackTable[B] {
  root : @moonui.Widget[B]
  count_label : @moonui.Widget[B]
  /// 列表名（页签标题那行大字，`T128` 换页签时就地改文案）
  title_label : @moonui.Widget[B]
  /// 侧栏（`T179`）：判据⑥量宽度用
  sidebar : @moonui.Widget[B]
  /// 侧栏导航项（app 用来给当前页上亮）。`T179` 起是 MenuRow 不是页签钮，
  /// 选中态走 checked 通道。
  tabs : Array[@moonui.Widget[B]]
  /// 与 `tabs` 平行的页签号（`T175` 后不止三个页签：0/1/2 固定页，歌单 i =
  /// 3+i）。refresh 按它对亮——导航项集合是数据驱动的，下标不再等于页签号。
  tab_ids : Array[Int32]
  search : @moonui.Widget[B]
  /// 底部属性栏（右键「属性」的落地端）
  prop : @moonui.Widget[B]
  list : @moonui.VirtualList[B]
}

///|
/// 小方钮皮肤（工具条 / 页签 / 列头共用）：白卡片上的浅灰扁钮。
/// 与播放条的 cm_btn_skin 同款手法——显式给底就摘掉系统 bezel。
fn[B] cm_flat_btn(
  btn : @moonui.Widget[B],
  bg : @moonui.Color,
  fg : @moonui.Color,
  size : Double,
) -> Unit raise @moonui.UiError {
  let _ = btn.set_style(
    Some(
      @moonui.style(
        background=Some(bg),
        foreground=Some(fg),
        font_size=Some(size),
        radius=Some(2.0),
      ),
    ),
  )
}

///|
/// 建列表区。title 是列表标题（页签决定）；build_row 由 app 提供（含双击 /
/// 右键接线）。列宽走 Sized 通道（与行同一条账），标题列 expand 吃剩余宽度。
pub fn[B : @moonui.Backend] TrackTable::new(
  b : B,
  count : Int32,
  title : String,
  active_tab : Int32,
  playlist_tabs : Array[String],
  hooks : TableHooks,
  build_row : (Int32) -> @moonui.Widget[B] raise @moonui.UiError,
) -> TrackTable[B] raise @moonui.UiError {
  // ——① 侧栏导航（`T179`）：三固定项 + 歌单区——
  // 页签号 0/1/2 固定，歌单 i = 3+i。**数据驱动**：playlist_tabs 由 app 按当下
  // 的歌单账现算传进来，建树时铺开；重建树（rebuild_ui）时歌单变了侧栏跟着变。
  // `T175` 的横向页签行整行撤除，交互原样搬进侧栏：点击切页、歌单条目右键
  // 重命名/删除、「＋」新建；`T175` 的「▸」溢出菜单在侧栏里自然消失——歌单多了
  // 整个歌单区包进竖向 Scroll（选滚动不选折叠：歌单是平账，折叠要记每组的
  // 开合状态，滚动零状态）。当前页高亮走 MenuRow 的 checked 通道（DESIGN C-03
  // 的映射零件），refresh 时 set_checked 切换。
  let fixed_tabs = ["我的音乐", "我喜欢的", "播放队列"]
  let tabs : Array[@moonui.Widget[B]] = []
  let tab_ids : Array[Int32] = []
  let nav : Array[@moonui.Widget[B]] = []
  // 追加一条侧栏项的公共尾：选中态 / 点击 / 右键（歌单条才有）。
  fn nav_item(
    id : Int32,
    name : String,
    on_menu : (@moonui.Widget[B]) -> Unit raise @moonui.UiError,
  ) -> Unit raise @moonui.UiError {
    let row = @moonui.Widget::menu_row(b, name, id == active_tab)
    let _ = row.on_click(fn() { (hooks.on_tab)(id) })
    on_menu(row)
    tabs.push(row)
    tab_ids.push(id)
    nav.push(@moonui.Widget::sized(b, Some(cm_sidebar_w()), Some(22.0), row))
  }
  for ti, name in fixed_tabs {
    nav_item(ti, name, fn(_w : @moonui.Widget[B]) { () })
  }
  // 歌单区分组头：小标题 + 「＋」新建歌单（`T175` 的入口原样搬过来）
  let btn_new = @moonui.Widget::button(b, "＋")
  cm_flat_btn(btn_new, cm_zebra(), cm_ink(), 9.0)
  let _ = btn_new.with_on_click(fn() { (hooks.on_playlist_new)() })
  nav.push(
    @moonui.Widget::row(b, 4.0, [
      @moonui.Widget::label(b, "歌单").font_size(9.0).foreground(cm_muted()),
      @moonui.Widget::spacer(b).with_expand(true),
      @moonui.Widget::sized(b, Some(18.0), Some(16.0), btn_new),
    ]),
  )
  for pi in 0..<playlist_tabs.length() {
    let pi = pi
    nav_item(3 + pi, playlist_tabs[pi], fn(
      w : @moonui.Widget[B],
    ) raise @moonui.UiError {
      // 歌单条目右键 = 重命名 / 删除（收歌单序号 0 起，app 侧认账）
      let rename = @moonui.MenuItem::new("重命名…")
      let _ = rename.on(fn(_) { (hooks.on_playlist_rename)(pi) })
      let del = @moonui.MenuItem::new("删除")
      let _ = del.on(fn(_) { (hooks.on_playlist_delete)(pi) })
      let _ = w.set_context_menu(
        @moonui.Menu::new("歌单", [Item(rename), Item(del)]),
      )
    })
  }
  let sidebar_list = @moonui.Widget::column(b, 2.0, nav)
  let sidebar = @moonui.Widget::scroll(b, @moonui.Axis::Vertical, sidebar_list)

  // ——② 工具条：播放全部 / 添加目录 / 导入 / 导出 / 清空 + 搜索框——
  let btn_play_all = @moonui.Widget::button(b, "▶ 播放全部")
  let btn_add = @moonui.Widget::button(b, "＋ 添加目录")
  let btn_import = @moonui.Widget::button(b, "导入 m3u")
  let btn_export = @moonui.Widget::button(b, "导出 m3u")
  let btn_clear = @moonui.Widget::button(b, "清空")
  cm_flat_btn(btn_play_all, cm_zebra(), cm_ink(), 10.0)
  cm_flat_btn(btn_add, cm_zebra(), cm_ink(), 10.0)
  cm_flat_btn(btn_import, cm_zebra(), cm_ink(), 10.0)
  cm_flat_btn(btn_export, cm_zebra(), cm_ink(), 10.0)
  cm_flat_btn(btn_clear, cm_zebra(), cm_ink(), 10.0)
  let _ = btn_play_all.with_on_click(fn() { (hooks.on_play_all)() })
  let _ = btn_add.with_on_click(fn() { (hooks.on_add_dir)() })
  let _ = btn_import.with_on_click(fn() { (hooks.on_import)() })
  let _ = btn_export.with_on_click(fn() { (hooks.on_export)() })
  let _ = btn_clear.with_on_click(fn() { (hooks.on_clear)() })
  let search = @moonui.Widget::text_input(b, "").with_placeholder(
    "搜索标题 / 歌手",
  )
  let _ = search.with_on_input(fn(text : String) { (hooks.on_search)(text) })
  let toolbar = @moonui.Widget::row(b, 4.0, [
    @moonui.Widget::sized(b, Some(78.0), Some(20.0), btn_play_all),
    @moonui.Widget::sized(b, Some(84.0), Some(20.0), btn_add),
    @moonui.Widget::sized(b, Some(70.0), Some(20.0), btn_import),
    @moonui.Widget::sized(b, Some(70.0), Some(20.0), btn_export),
    @moonui.Widget::sized(b, Some(46.0), Some(20.0), btn_clear),
    @moonui.Widget::spacer(b).with_expand(true),
    @moonui.Widget::sized(b, Some(110.0), Some(20.0), search),
  ])

  // ——③ 标题行：列表名 + 计数 + 重扫——
  let btn_rescan = @moonui.Widget::button(b, "⟳ 重扫")
  cm_flat_btn(btn_rescan, cm_zebra(), cm_muted(), 9.0)
  let _ = btn_rescan.with_on_click(fn() { (hooks.on_rescan)() })
  let count_label = @moonui.Widget::label(b, "共 \{count} 首").foreground(
    cm_muted(),
  )
  let title_lbl = @moonui.Widget::label(b, title)
    .font_size(12.0)
    .font_weight(Bold)
    .foreground(cm_ink())
  let title_row = @moonui.Widget::row(b, 8.0, [
    title_lbl,
    @moonui.Widget::spacer(b).with_expand(true),
    count_label,
    // 重扫（`T172`）：放在标题行而不是工具条——工具条那五颗按钮加搜索框
    // 已经把 380 的窗宽用满（`T120` 量过），第六颗会把搜索框挤出去。
    @moonui.Widget::sized(b, Some(52.0), Some(16.0), btn_rescan),
  ])

  // ——④ 列头：点一下按该列排序（升/降在 app 侧翻）——
  let head_idx = @moonui.Widget::button(b, "#")
  let head_title = @moonui.Widget::button(b, "标题")
  let head_artist = @moonui.Widget::button(b, "歌手")
  let head_album = @moonui.Widget::button(b, "专辑")
  let head_dur = @moonui.Widget::button(b, "时长")
  cm_flat_btn(head_idx, cm_zebra(), cm_muted(), 9.0)
  cm_flat_btn(head_title, cm_zebra(), cm_muted(), 9.0)
  cm_flat_btn(head_artist, cm_zebra(), cm_muted(), 9.0)
  cm_flat_btn(head_album, cm_zebra(), cm_muted(), 9.0)
  cm_flat_btn(head_dur, cm_zebra(), cm_muted(), 9.0)
  let _ = head_idx.with_on_click(fn() { (hooks.on_sort)(0) })
  let _ = head_title.with_on_click(fn() { (hooks.on_sort)(1) })
  let _ = head_artist.with_on_click(fn() { (hooks.on_sort)(2) })
  let _ = head_album.with_on_click(fn() { (hooks.on_sort)(3) })
  let _ = head_dur.with_on_click(fn() { (hooks.on_sort)(4) })
  // 专辑列 90（`T178`）：歌手 104 / 时长 46 的中间值——标题列 expand 吃剩余
  // 宽，多出的 90 从它身上扣，行与表头同一条账，列缝对得齐。尾格 18 是行右缘
  // 的拖动句柄位（`T176`，只有行有钮、表头留空），不垫这格的话行与表头的
  // expand 宽差 18，歌手往后的列缝整条错位。
  let header_row = @moonui.Widget::row(b, 8.0, [
    @moonui.Widget::sized(b, Some(30.0), Some(17.0), head_idx),
    @moonui.Widget::sized(b, None, Some(17.0), head_title).with_expand(true),
    @moonui.Widget::sized(b, Some(104.0), Some(17.0), head_artist),
    @moonui.Widget::sized(b, Some(90.0), Some(17.0), head_album),
    @moonui.Widget::sized(b, Some(46.0), Some(17.0), head_dur),
    @moonui.Widget::sized(b, Some(18.0), Some(17.0), @moonui.Widget::spacer(b)),
  ])

  // ——⑤ 列表本体（VirtualList）——
  let list = @moonui.VirtualList::new(b, count, CM_ROW_HEIGHT, build_row)
  // 首屏物化：挂树前 sync，行随树一起 attach
  list.sync(0.0, CM_SYNC_VIEWPORT)

  // ——⑥ 属性栏（右键「属性」的落地端）——
  let prop = @moonui.Widget::label(
      b, "属性：双击一首歌播放，右键看属性",
    )
    .foreground(cm_muted())
    .font_size(9.0)

  // ——竖拼：工具条 / 标题 / 列头 / 列表 / 属性栏——
  let body = @moonui.Widget::column(b, 4.0, [
    toolbar,
    @moonui.Widget::separator(b),
    title_row,
    header_row,
    list.view().with_expand(true),
    @moonui.Widget::separator(b),
    prop,
  ])
  // ——横拼（`T179`）：侧栏（定宽）+ 竖分隔线 + 列表区（吃剩下的宽）——
  // 与 gallery 的左目录同款（gallery.mbt refresh）：row 里侧栏用 sized 定宽
  // 不 expand，body with_expand 吃行里剩下的全部宽度。
  let root_row = @moonui.Widget::row(b, 6.0, [
    @moonui.Widget::sized(b, Some(cm_sidebar_w()), None, sidebar),
    @moonui.Widget::vseparator(b),
    body.with_expand(true),
  ])
  let padded = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(4.0, 8.0),
    root_row,
  )
  // 浅色卡片（Luna列表区是脸面下方的浅色面板）
  let panel = @moonui.Widget::panel(b, padded)
  let _ = panel.set_style(
    Some(@moonui.style(background=Some(cm_playlist_bg()))),
  )
  {
    root: panel,
    count_label,
    title_label: title_lbl,
    tabs,
    tab_ids,
    sidebar,
    search,
    prop,
    list,
  }
}

///|
/// 就地换列表内容（`T128`）：改标题 / 计数 / 页签高亮 / 列表行数。
///
/// 干什么、不干什么：**只碰这张表里的四样**，不碰窗口、不碰别的窗、不换树。
/// 三个页签的控件结构完全同构（页签行 / 工具条 / 标题行 / 列头 / 列表 / 属性栏
/// 一模一样），差别只有"哪个页签点亮 + 列表名 + 数据"。旧路径 `set_tab` 走
/// `rebuild_ui` 把六只窗的整树拆了重建（一次 ~700ms，主控窗的播放按钮和
/// 「状态：就绪」也跟着被销毁重造 = 闪一下），这一步只改值。
///
/// 行由 `VirtualList::set_count` 按新数据重建（视图已换成新页签那份），
/// 只重建窗内那十来行。
pub fn[B : @moonui.Backend] TrackTable::refresh(
  self : TrackTable[B],
  count : Int32,
  title : String,
  active_tab : Int32,
) -> Unit raise @moonui.UiError {
  // 高亮按 tab_ids 对（`T175` 后导航项的下标不再等于页签号：歌单重排/
  // 删除后同一条可能换页签号）。选中态走 MenuRow 的 checked 通道（`T179`）。
  for i, item in self.tabs {
    let ti = self.tab_ids[i]
    item.set_checked(ti == active_tab) catch {
      _ => ()
    }
  }
  let _ = self.title_label.set_text(title)
  let _ = self.count_label.set_text("共 \{count} 首")
  self.list.set_count(count)
  self.list.sync(0.0, CM_SYNC_VIEWPORT)
}

///|
/// 高亮变了、歌单没变：按当下的视图原地重建窗内那十来行（`T153`）。
///
/// 为什么不能省这一步：行的高亮（`▶` / 蓝字 / 蓝底）是 `build_row` 在**建行
/// 那一刻**按 `player.current` 烤进去的，而切歌不走 `refresh`（那会 `set_count`
/// 把滚动位置弹回顶端）。于是列表窗的高亮一直停在旧行，播放条和歌词窗却每拍
/// 从 player 拉最新状态、当场就变了——owner 报的"其它两个窗口都变过来了，播放
/// 列表还是前一首"就是这个不对称。
///
/// 代价：重建窗内约十来行（`VirtualList` 的物化窗口），不是整棵树；滚动位置
/// 由 `rebuild_rows` 自己保住。同一首反复调是幂等的——建出来一样，只是白建
/// 一遍，所以调用方按"当前曲真的变了"的边沿调，别每拍都调。
pub fn[B : @moonui.Backend] TrackTable::refresh_current(
  self : TrackTable[B],
) -> Unit raise @moonui.UiError {
  self.list.rebuild_rows()
}
