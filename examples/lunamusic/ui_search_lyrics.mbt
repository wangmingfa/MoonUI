///|
/// 「搜索歌词」小窗（`T161`①）：填歌名 / 歌手 → 查 lrclib → 结果列表 →
/// 双击某一条就应用（并且**立刻写回本地**），直到满意再关窗。
///
/// 为什么是**独立小窗**而不是应用内弹层：框架里没有应用内模态这回事
/// （`packages/moonui/dialog.mbt` 只包系统原生面板，`show_message`/`confirm`
/// 那几只）。既有先例是「编辑信息」（`ui_edit.mbt`）——`create_window` +
/// `CmStrip` + `cm_window_shell`，懒建一次、之后复用。这里照抄那套形状。
///
/// 两只手性同 `EditDialog`：
/// 1. 窗只建一次（`LunaMusicApp.search_dlg` 懒建），`rebuild_ui` 不碰它——
///    整树重建会销毁原生输入控件，正在打的字、输入法状态全没。
/// 2. 输入值不镜像到 MoonBit 侧：查询那一刻用 `Widget::text()` 现读。
///
/// 与编辑窗唯一不同的地方：结果数组与"这一轮问的是谁"放在一只私有状态盒里，
/// 由行工厂闭包与窗口共享——行工厂要按行号去读结果，而 `VirtualList` 建在
/// 对话框结构体之前。（`LyricsView` 用的是"先建结构体再补字段"，这里反过来，
/// 因为 `VirtualList` 没有能当占位的空构造。）
pub(all) struct LyricSearchDialog[B] {
  window : @moonui.Window[B]
  title_in : @moonui.Widget[B]
  artist_in : @moonui.Widget[B]
  search : @moonui.Widget[B]
  status : @moonui.Widget[B]
  /// 列表区居中的提示文案（`T164`①）。结果一条没有时这块是**一片空白**，
  /// 用户不知道是在查、是查完了没结果、还是压根没开始（owner 的截图就是
  /// 「查询中…」压在底部状态行，中间整块白板）。它叠在列表上，见下面 body
  /// 那条注释。
  hint : @moonui.Widget[B]
  list : @moonui.VirtualList[B]
  state : LyricSearchState
  /// 用当前两个输入框发一次查询。抽出来是为了让 `open()` 能**自己按一次**
  /// （自动解析到歌名时的自动查询），不必去伪造一次点击事件。
  query : () -> Unit
  /// 按当下状态把空白区提示重算一遍（`T164`①）。无参、失败自己吞——`open()`
  /// 与两处查询落点都调它，没有一处需要处理错误。
  sync_hint : () -> Unit
}

///|
/// 行工厂与窗口共享的那一格账。
///
/// `pub(all)` 而不是 `priv` 是被类型系统逼的：`LyricSearchDialog` 是
/// `pub(all)`（app 要读它的字段），而公开结构体的字段不能是私有类型。
/// 它是实现细节，不打算给包外用——名字与注释按这个口径写。
pub(all) struct LyricSearchState {
  /// 当前结果（行工厂按行号读它）。**原地增删**不换数组对象——闭包捕获的是
  /// 这一份引用，所以只 clear/push，不重新赋值（因此没有 `mut`）。
  results : Array[LyricSearchResult]
  /// 最近一次查询的 `(歌名, 歌手)`。结果回来时对一下：用户可能已经改了输入框
  /// 又点了一次查询，旧结果必须让位。
  mut asked : (String, String)
  /// 查询中（挡连点，也用来把状态行从"查询中…"换回来）
  mut pending : Bool
}

///|
/// 搜索窗的固定尺寸：宽到放得下一整条「歌名 - 歌手 + 时长」，高到一屏十条
/// 再加两行输入和一颗按钮。同样**不进 `CmLayout`**（那是六只常驻窗的落座表），
/// 打开时按锚窗位置现算一次居中。
pub fn cm_search_size() -> @moonui.LogicalSize {
  @moonui.LogicalSize(470.0, 400.0)
}

///|
/// 结果列表的行高（一条一首，够放 10pt 字 + 行距）。
const CM_SEARCH_ROW_H : Double = 22.0

///|
/// 结果行的左右内缩（`T163`②）。行底是整条深色，字贴着面板边缘起笔会顶到
/// 滚动条与窗框上；10pt 与标签列 / 时长列的留白看起来是一套。
const CM_SEARCH_ROW_PAD_X : Double = 10.0

///|
/// 列表区为空时压在中间的那句提示（`T164`①）。三档，与底部状态行说的是同一件
/// 事，但位置在**用户眼睛盯着的那块空白**上——不放这儿的话，「查询中…」缩在
/// 窗最底下，中间一整块白板，看起来像卡死了。
const CM_SEARCH_HINT_IDLE : String = "输入歌名后点「查询」"

///|
const CM_SEARCH_HINT_QUERYING : String = "查询中…"

///|
const CM_SEARCH_HINT_EMPTY : String = "没找到"

///|
/// 列表首屏的物化视口高——比窗口内容区高出一截，一屏能物化全部结果
/// （搜索结果通常十来条，不做滚动也显示得完）。
const CM_SEARCH_VIEWPORT : Double = 600.0

///|
/// 建搜索窗（不显示）。`on_search(title, artist, land)` 由壳注入（真窗走
/// worker 发 HTTP），`land` 回到主循环喂结果；`on_apply(result)` 是双击的
/// 落地端（app 侧写盘 + 换歌词）。
pub fn[B : @moonui.Backend] LyricSearchDialog::new(
  b : B,
  app : @moonui.App[B],
  on_search : (String, String, (Array[LyricSearchResult]) -> Unit) -> Unit,
  on_apply : (LyricSearchResult) -> Unit,
  on_close : () -> Unit,
) -> LyricSearchDialog[B] raise @moonui.UiError {
  let size = cm_search_size()
  let window = app.create_window("搜索歌词", size)
  let _ = window.set_resizable(false) catch { _ => () }
  let _ = window.set_titlebar_style(Immersive) catch { _ => () }
  let title_in = @moonui.Widget::text_input(b, "")
  let artist_in = @moonui.Widget::text_input(b, "")
  let search = @moonui.Widget::button(b, "查询")
  // 按钮底色取顶条那档深蓝（`cm_titlebar_bg`）：脸面本身就是中蓝（`cm_page_bg`），
  // 用强调色 `cm_accent` 当底只比底色深一点点，一颗"主操作"按钮看着像没画出来。
  // 深蓝与对话框自己那条顶条同色，读起来是"这个窗的操作"，与 ✕ / 顶条动作钮
  // 同一套皮肤。
  cm_flat_btn(search, cm_titlebar_bg(), cm_text_light(), 10.0)
  // 状态行的字色：它直接躺在脸面中蓝上。`cm_muted`（0x5E7688）在这块底上
  // 与底色的亮度差不到 15%，真窗上就是"一行看不出写的是什么"。换 `cm_text_light`
  // 后与脸面拉开到 5:1 以上。
  let status = @moonui.Widget::label(b, "未查询")
    .foreground(cm_text_light())
    .font_size(10.0)
  let state : LyricSearchState = {
    results: [],
    asked: ("", ""),
    pending: false,
  }
  // 空白区提示（`T164`①）：结果列表一条都没有时，把话说在用户正盯着的那块
  // 白板上。字色取 `cm_ink` 而不是 `cm_text_light`——列表区没被行底覆盖的
  // 部分是滚动视口的浅底（真窗取证：一片白），浅字压上去等于没写。
  let hint_label = @moonui.Widget::label(b, CM_SEARCH_HINT_IDLE)
    .foreground(cm_ink())
    .font_size(10.0)
  // 三层「撑开 - 文字 - 撑开」：Column 上下两只 Spacer 吃剩余高度，中间那行
  // 左右两只 Spacer 吃剩余宽度，文字就落在整块区域的几何中心。不能只套
  // `Widget::center`：它的测量不看父容器给的高，居中就没有可居中的余量。
  let hint_row = @moonui.Widget::row(b, 0.0, [
    @moonui.Widget::spacer(b).with_expand(true),
    hint_label,
    @moonui.Widget::spacer(b).with_expand(true),
  ])
  let hint = @moonui.Widget::column(b, 0.0, [
    @moonui.Widget::spacer(b).with_expand(true),
    hint_row,
    @moonui.Widget::spacer(b).with_expand(true),
  ])
  // 提示的内容与去留只看两件事：有结果就整块收起来（结果盖满列表时那句提
  // 示只会压在行上），没结果就按"查没查过 / 正在查"挑一句。重查期间旧结果
  // 还在屏上，所以这里不会在行上面冒出一句「查询中…」。
  //
  // 可见性每次都显式写、不做"只在变化时推"的去重：这条路径只在开窗与结果
  // 落地时走一次，多推一次原生层的代价远小于多存一格状态（`set_visible`
  // 本身幂等，同值重复写不改观感）。
  let sync_hint : () -> Unit = fn() {
    if state.results.length() > 0 {
      let _ = hint.set_visible(false) catch { _ => () }
      return
    }
    let text = if state.pending {
      CM_SEARCH_HINT_QUERYING
    } else if state.asked == ("", "") {
      CM_SEARCH_HINT_IDLE
    } else {
      CM_SEARCH_HINT_EMPTY
    }
    let _ = hint_label.set_text(text) catch { _ => () }
    let _ = hint.set_visible(true) catch { _ => () }
  }
  // 行工厂：`标题 - 歌手` 左对齐吃剩余宽度，时长右对齐。双击挂在 **Panel**
  // 上而不是 Row 上（`app.mbt` 建行那条注释：Row 是纯布局节点，原生层没有
  // 可命中的对象）。
  let build_row : (Int32) -> @moonui.Widget[B] raise @moonui.UiError = fn(
    i : Int32,
  ) -> @moonui.Widget[B] raise @moonui.UiError {
    if i < 0 || i >= state.results.length() {
      return @moonui.Widget::panel(b, @moonui.Widget::spacer(b))
    }
    let r = state.results[i]
    let label = if r.artist.length() > 0 {
      "\{r.title} - \{r.artist}"
    } else {
      r.title
    }
    let row = @moonui.Widget::row(b, 8.0, [
      @moonui.Widget::sized(
        b,
        None,
        Some(CM_SEARCH_ROW_H),
        @moonui.Widget::column(b, 0.0, [
          @moonui.Widget::spacer(b),
          @moonui.Widget::label(b, label)
          .font_size(10.0)
          .foreground(cm_text_light()),
          @moonui.Widget::spacer(b),
        ]),
      ).with_expand(true),
      @moonui.Widget::sized(
        b,
        Some(46.0),
        Some(CM_SEARCH_ROW_H),
        @moonui.Widget::column(b, 0.0, [
          @moonui.Widget::spacer(b),
          @moonui.Widget::label(
            b,
            format_duration((r.duration_s * 1000.0).to_int64()),
          )
          .font_size(9.0)
          .foreground(cm_text_light()),
          @moonui.Widget::spacer(b),
        ]),
      ),
    ])
    // 左右各留 10pt：行底是整条深色，字贴着面板边缘起笔会顶到滚动条与窗框
    // 上（真窗上第一列字几乎是黏在左边缘的）。上下不缩——行高 22 就是给
    // 一行 10pt 字用的，再压会让行距看起来不均。
    let padded = @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(0.0, CM_SEARCH_ROW_PAD_X),
      row,
    )
    let panel = @moonui.Widget::panel(b, padded)
    let _ = panel.with_on_double_click(fn() {
      on_apply(r)
      status.set_text("已应用：\{label}") catch {
        _ => ()
      }
    })
    // 行底必须**显式给**，不能靠"透出窗底色"：列表挂在 `NSScrollView` 里，
    // 透出来的未必是脸面蓝（滚动视口自己还有一层底），浅字压上去就是一片白。
    // 底色取 `cm_inset`（频谱窗那档深底），与上面的浅字是一对：对比度约 13:1。
    // 同一条窗里"上浅下深"也把输入区和结果区分开了。
    let _ = panel.set_style(Some(@moonui.style(background=Some(cm_inset()))))
    // 悬停抬到强调色（比 `cm_inset` 亮一档，浅字仍读得清），与列表窗里
    // "选中行整条变色"同一个观感。
    let _ = panel.set_hover_style(
      Some(@moonui.style(background=Some(cm_accent()))),
    )
    panel
  }
  let list = @moonui.VirtualList::new(b, 0, CM_SEARCH_ROW_H, build_row)
  // 查一次：读**当前**两个输入框的值发出去，结果回来喂列表。
  //
  // 抽成一只闭包而不是只挂在按钮上，是让 `open()` 能在自动解析到歌名时
  // 直接跑一遍（`T163`①）——不用去伪造一次点击事件，那条路还要过一遍命中
  // 测试，纯属自找麻烦。
  let run_query : () -> Unit = fn() {
    let title = title_in.text() catch { _ => "" }
    let artist = artist_in.text() catch { _ => "" }
    let title = cm_trim(title)
    let artist = cm_trim(artist)
    // 挡连点，但只在"问的是同一个人"时挡：`open()` 自己会按一次自动查询
    // （`T163`①），那一轮还在路上时用户改了名字再按「查询」，必须能发出去——
    // 否则得等上一轮回来才动得了，而那一轮的结果照样会被下面的 `asked` 判据
    // 丢掉。
    if state.pending && state.asked == (title, artist) {
      return
    }
    if title.length() == 0 {
      status.set_text("歌名不能为空") catch {
        _ => ()
      }
      return
    }
    state.asked = (title, artist)
    state.pending = true
    status.set_text("查询中…") catch {
      _ => ()
    }
    // 旧结果还在屏上时不动提示（`sync_hint` 自己有"有结果就收起"那一档），
    // 一行没有才把「查询中…」摆到空白区正中。
    sync_hint()
    on_search(title, artist, fn(found) {
      // 查询期间用户又改了一次：这一轮结果作废（新那一轮已经在路上）
      if state.asked != (title, artist) {
        return
      }
      state.pending = false
      // 原地替换：行工厂闭包捕获的就是这只数组
      state.results.clear()
      for r in found {
        state.results.push(r)
      }
      list.set_count(state.results.length()) catch {
        _ => ()
      }
      list.sync(0.0, CM_SEARCH_VIEWPORT) catch {
        _ => ()
      }
      status.set_text(
        if state.results.length() == 0 {
          "没找到"
        } else {
          "找到 \{state.results.length()} 条，双击应用"
        },
      ) catch {
        _ => ()
      }
      sync_hint()
    })
  }
  // 包一层：`with_on_click` 要的是可 raise 的闭包，而 `run_query` 自己把
  // 错误全 catch 在里面（状态行写不进去不该让点击失败），包一层让类型对上。
  let _ = search.with_on_click(fn() { run_query() })
  let dialog : LyricSearchDialog[B] = {
    window,
    title_in,
    artist_in,
    search,
    status,
    hint,
    list,
    state,
    query: run_query,
    sync_hint,
  }
  // 两行「标签 + 输入框」：标签列宽 44，与编辑窗同一条账。
  //
  // 三格都锁 22 高（与输入框同高），标签与按钮再各套一层 `Center`：Row 的交叉轴
  // 左上对齐（`layout_line`），裸标签会贴在 22 高那一行的上缘，真窗上就是标签
  // 比输入框里的字高一截。`Center` 读的是这一格的 frame，锁了高才有正中可放。
  let rows : Array[@moonui.Widget[B]] = []
  let labels = ["歌名", "歌手"]
  let inputs = [title_in, artist_in]
  for i, w in inputs {
    let lbl = @moonui.Widget::label(b, labels[i])
      .font_size(10.0)
      .foreground(cm_text_light())
    rows.push(
      @moonui.Widget::row(b, 6.0, [
        @moonui.Widget::sized(
          b,
          Some(44.0),
          Some(22.0),
          @moonui.Widget::center(b, lbl),
        ),
        @moonui.Widget::sized(b, None, Some(22.0), w).with_expand(true),
        if i == 0 {
          // 按钮**铺满**这一格（不套 `Center`）：系统按钮自己会把标题排在正中，
          // 外面再居中没有可居中的余地，反而会让按钮缩回文字宽。
          @moonui.Widget::sized(b, Some(64.0), Some(22.0), search)
        } else {
          @moonui.Widget::sized(
            b,
            Some(64.0),
            Some(22.0),
            @moonui.Widget::spacer(b),
          )
        },
      ]),
    )
  }
  // 提示叠在列表上（`T164`①）而不是当列表的兄弟：`Column` 不为不可见子项
  // 让出空间（布局脊柱不看可见性），收起一条兄弟行底下是空不出来那块的；
  // `Stack` 里两个子项共用同一块矩形，提示收起来时列表照旧铺满。
  //
  // 叠层的命中：`hit_test` 会穿过布局节点、落在带句柄的叶子上，所以结果空着
  // 时点在提示上不产生任何动作（它没有回调），有结果时提示已经收了——mac 的
  // `NSView hitTest:` 本来就不返回隐藏视图。
  let list_area = @moonui.Widget::stack(b, [list.view().with_expand(true), hint])
  let body = @moonui.Widget::column(b, 6.0, [
    rows[0],
    rows[1],
    list_area.with_expand(true),
    status,
  ])
  let strip = CmStrip::new(b, "搜索歌词", fn() { on_close() })
  let root = cm_window_shell(b, strip.root, body, 8.0)
  window.set_content(root)
  dialog
}

///|
/// 打开搜索窗：预填歌名 / 歌手，清空上一轮结果，**贴在锚窗（歌词秀）右侧**。
///
/// 为什么不再按锚窗居中：搜索窗和歌词秀是同一件事的两半——左边看当前歌词长得
/// 对不对，右边挑新的一条。居中摆过来正好把歌词秀盖掉，双击换词之后用户反而
/// 看不见换成了什么（owner：「否则看不到实际歌词是什么样的」）。
///
/// 横向贴锚窗右缘加一道 `cm_layout_gap()`（与默认布局里相邻窗的缝同值，摆在一
/// 起才像一套窗）；纵向顶边对齐。窗口跑到屏幕外时不做夹取——框架里读"这块屏
/// 的可用区域"只有 `Window::center` 一条路，而它给的落点是居中，会把这个位置
/// 抹掉；用户拖一下就能拖回来，比"猜一个夹取值"更可预期。
///
/// 预填用的是 `tag_query_candidates` 的第一格——多数时候用户只是想把自动
/// 猜错的那一半改一下，从空输入框开始敲一整遍是白费。
pub fn[B : @moonui.Backend] LyricSearchDialog::open(
  self : LyricSearchDialog[B],
  title : String,
  artist : String,
  anchor : @moonui.Window[B],
) -> Unit raise @moonui.UiError {
  let _ = self.title_in.set_text(title)
  let _ = self.artist_in.set_text(artist)
  self.state.results.clear()
  self.state.pending = false
  self.state.asked = ("", "")
  self.list.set_count(0)
  self.list.sync(0.0, CM_SEARCH_VIEWPORT)
  let _ = self.status.set_text("未查询")
  // 提示归零到"还没查"：上面刚把 `asked` 清成空对，`sync_hint` 按这条判据
  // 挑「输入歌名后点「查询」」。自动查询马上就把它换成「查询中…」。
  (self.sync_hint)()
  let p = anchor.position() catch { _ => @moonui.LogicalPoint(0.0, 0.0) }
  let s = anchor.size() catch { _ => @moonui.LogicalSize(cm_lyrics_w(), 240.0) }
  let _ = self.window.set_position(
    @moonui.LogicalPoint(p.x + s.width + cm_layout_gap(), p.y),
  )
  // 红绿灯摆进这条 22pt 顶条的中线（`rebuild_ui` 那张表只覆盖六只常驻窗，
  // 这只是一只懒建的临时窗，赶不上那一趟）。不摆的话三颗按钮留在 AppKit
  // 给标准 28pt 标题栏算的位置上，压在自己画的 22pt 条的下缘。
  cm_place_traffic_lights(self.window, cm_strip_h())
  self.window.show()
  // 解析到了歌名就**直接查一次**（`T163`①）：走到这个窗的用户本来就是
  // "自动取词没取到 / 取错了"，绝大多数时候预填的名字就是对的那个，让他再按
  // 一次「查询」纯属多一步。空歌名不查——那会立刻在状态行报「歌名不能为空」，
  // 而用户其实是刚打开、还没开始填。
  //
  // 放在 `show()` 之后：`set_text` 在窗口没显示时也能写，但这个顺序让"先看见
  // 窗、再看状态行变成查询中…"更自然，也不依赖 `set_text` 的时序。
  if cm_trim(title).length() > 0 {
    (self.query)()
  }
}

///|
/// 关窗（用户点顶条 ✕）。不清结果：重开时 `open` 自己会清。
pub fn[B : @moonui.Backend] LyricSearchDialog::close(
  self : LyricSearchDialog[B],
) -> Unit {
  self.window.hide() catch {
    _ => ()
  }
}
