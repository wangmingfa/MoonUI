///|
/// 播放列表（Luna：页签 + 工具条 + 列头 + VirtualList + 属性栏）。
///
/// 第二期把「列表管理」落在这一层：页签（本地音乐/我喜欢的/播放队列）、
/// 排序（点列头切换升降）、搜索（输入即过滤，只动视图不动播放）、
/// m3u 导入导出、底部属性栏（右键「属性」把那首的详情摆出来）。
/// 行账 = 当前视图（app 侧算好传进来），增删与视图变化都走 app 的整树重建
/// （Window::set_content，children 对外部包只读，这是唯一干净的换树口）。
/// 双击播放的接线在 build_row 闭包里（app 装配），行索引在闭包捕获时钉死。
/// 物化窗口由 sync 推进：VirtualList 只在显式 sync 后才建行（组件的既定语义），
/// 挂在**挂树前**调用——行随整树一起 attach。
const CM_ROW_HEIGHT : Double = 20.0

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
  /// 排序列：0 = 原始顺序 / 1 = 标题 / 2 = 歌手 / 3 = 时长
  on_sort : (Int32) -> Unit
  /// 页签：0 = 本地音乐 / 1 = 我喜欢的 / 2 = 播放队列
  on_tab : (Int32) -> Unit
}

///|
/// 列表区的可握把手：root 进列表窗，其余供 app 读状态/改文案。
pub(all) struct TrackTable[B] {
  root : @moonui.Widget[B]
  count_label : @moonui.Widget[B]
  /// 列表名（页签标题那行大字，`T128` 换页签时就地改文案）
  title_label : @moonui.Widget[B]
  /// 三个页签按钮（app 用来给当前页签上色）
  tabs : Array[@moonui.Widget[B]]
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
  hooks : TableHooks,
  build_row : (Int32) -> @moonui.Widget[B] raise @moonui.UiError,
) -> TrackTable[B] raise @moonui.UiError {
  // ——① 页签：本地音乐 / 我喜欢的 / 播放队列——
  let tab_names = ["本地音乐", "我喜欢的", "播放队列"]
  let tabs : Array[@moonui.Widget[B]] = []
  let tab_cells : Array[@moonui.Widget[B]] = []
  for ti, name in tab_names {
    let btn = @moonui.Widget::button(b, name)
    let bg = if ti == active_tab { cm_accent() } else { cm_zebra() }
    let fg = if ti == active_tab { cm_text_light() } else { cm_ink() }
    cm_flat_btn(btn, bg, fg, 10.0)
    let _ = btn.with_on_click(fn() { (hooks.on_tab)(ti) })
    // `tabs` 收的是**按钮本身**（`refresh` 要给它换底色），布局用的包一层
    // `sized` 另存（`T128`：早先 `tabs` 里放的是 `sized(...)`，`refresh` 把
    // 样式下到那层容器上——容器没有按钮脸，于是文案变了、选中底色不动）。
    tabs.push(btn)
    tab_cells.push(@moonui.Widget::sized(b, Some(70.0), Some(20.0), btn))
  }
  let tabs_row = @moonui.Widget::row(b, 4.0, [
    tab_cells[0],
    tab_cells[1],
    tab_cells[2],
    @moonui.Widget::spacer(b).with_expand(true),
  ])

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
  let search = @moonui.Widget::text_input(b, "")
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

  // ——③ 标题行：列表名 + 计数——
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
  ])

  // ——④ 列头：点一下按该列排序（升/降在 app 侧翻）——
  let head_idx = @moonui.Widget::button(b, "#")
  let head_title = @moonui.Widget::button(b, "标题")
  let head_artist = @moonui.Widget::button(b, "歌手")
  let head_dur = @moonui.Widget::button(b, "时长")
  cm_flat_btn(head_idx, cm_zebra(), cm_muted(), 9.0)
  cm_flat_btn(head_title, cm_zebra(), cm_muted(), 9.0)
  cm_flat_btn(head_artist, cm_zebra(), cm_muted(), 9.0)
  cm_flat_btn(head_dur, cm_zebra(), cm_muted(), 9.0)
  let _ = head_idx.with_on_click(fn() { (hooks.on_sort)(0) })
  let _ = head_title.with_on_click(fn() { (hooks.on_sort)(1) })
  let _ = head_artist.with_on_click(fn() { (hooks.on_sort)(2) })
  let _ = head_dur.with_on_click(fn() { (hooks.on_sort)(3) })
  let header_row = @moonui.Widget::row(b, 8.0, [
    @moonui.Widget::sized(b, Some(30.0), Some(17.0), head_idx),
    @moonui.Widget::sized(b, None, Some(17.0), head_title).with_expand(true),
    @moonui.Widget::sized(b, Some(104.0), Some(17.0), head_artist),
    @moonui.Widget::sized(b, Some(46.0), Some(17.0), head_dur),
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

  // ——竖拼：页签 / 工具条 / 标题 / 列头 / 列表 / 属性栏——
  let body = @moonui.Widget::column(b, 4.0, [
    tabs_row,
    toolbar,
    @moonui.Widget::separator(b),
    title_row,
    header_row,
    list.view().with_expand(true),
    @moonui.Widget::separator(b),
    prop,
  ])
  let padded = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(4.0, 8.0),
    body,
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
  for ti, btn in self.tabs {
    let bg = if ti == active_tab { cm_accent() } else { cm_zebra() }
    let fg = if ti == active_tab { cm_text_light() } else { cm_ink() }
    cm_flat_btn(btn, bg, fg, 10.0)
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
