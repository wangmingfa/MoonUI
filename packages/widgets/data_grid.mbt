///|
/// `DataGrid`——只读数据表（`T102` 的第一刀）。
///
/// 为什么自绘而不去包平台的原生表：`NSTableView` 与 Win32 `ListView` 都要
/// 数据源 / delegate / 单元格复用那一整套，两套 API 除了"都是表格"之外没有
/// 一处对得上；而一屏"几列文字 + 几条分隔线"的画法在两边其实是同一个东西。
/// `T101` 的自绘面正好够画它，于是这份配方在原生、自绘、mock 三个后端上画出
/// 来的是同一张表——这也是 `packages/widgets` 存在的意义（API.md §6.8）。
///
/// **虚拟化在这里是"复用公式"而不是"复用对象"**：`VirtualList`（`T86④`）靠
/// 视口内建/窗外销毁原生子控件来省句柄；自绘面只有**一个**原生对象，省的是
/// **命令**——只有与正文矩形相交的那些行才产出命令，滚到第 500 行时前面 499
/// 行一条命令都不发。窗口起点仍是同一条算术（`floor(offset / 行高)`），只是
/// 落点从"句柄表"换成了"这一帧的清单"。
///
/// 为什么滚动偏移是控件自己的状态、而不是外面套一个 Scroll：自绘面是一个不
/// 可再分的原生对象，里面没有原生滚动视图可套。偏移因此做成显式 API
/// （`set_offset` / `scroll_to_row`），由调用方在收到滚轮或按键时推进——事件
/// 本身 Core 是有的（`MouseDown` / `MouseMove` / `Scroll`），但 `packages/widgets`
/// 拿不到 `App`（事件循环不归控件所有），而且这三条事件的坐标是**窗口/父局部**
/// 的、滚轮在 mac 上恒报窗口自己（`T108`），所以"指针在不在我身上、落在第几行"
/// 得由拿着 `App` 的那一层算——`row_at` 就是给它的那一半。
///
/// 坐标一律控件局部逻辑像素（`T101` 的契约），逻辑→物理换算归后端。

///|
/// 一列：标题 + 宽 + 对齐。
///
/// 宽是**逻辑像素**，两种口径：`DataGrid` 的 `auto_width` 关掉时是**固定宽**
///（给了多宽就是多宽）；打开时它变成**下限**——列的实际宽度取"自然宽"与这个
/// 下限的较大者（自然宽 = max(表头宽, 该列最宽的一格) + 2×内边距）。
///
/// 为什么下限而不是忽略它：列宽是调用方给的意图（"这列至少这么宽"），忽略它
/// 等于让调用方填一个没用的数；"精确指定某一列的宽"是另一根轴（手动调列宽），
/// 与自适应不搭界。
pub struct GridColumn {
  title : String
  width : Double
  right : Bool
  /// 这一列按**数值**比大小（排序时）。关掉就是字典序。
  numeric : Bool
}

///|
/// 造一列。`right=true` 是给数字列的——金额、计数右对齐才读得顺。
///
/// `numeric=true` 说"这一列按数值比大小"（`T102` 第五刀的排序用）。为什么要有
/// 这个标记而不是自动探测：格子里全是字符串，"10" 按字典序排在 "9" 前面——数字
/// 列按字典序排是**错的**；可是自动探测也不可靠（"1e5" 算不算数？"" 算不算？
/// " 3 " 带空格算不算？每一种约定都得有人认账）。所以这件事交给调用方声明：
/// 它知道这一列装的是金额还是编号。
pub fn GridColumn::new(
  title : String,
  width : Double,
  right~ : Bool = false,
  numeric~ : Bool = false,
) -> GridColumn raise @moonui.UiError {
  if width <= 0.0 {
    raise @moonui.OperationFailed("表格列宽必须为正")
  }
  { title, width, right, numeric, }
}

///|
/// 列标题。
pub fn GridColumn::title(self : GridColumn) -> String {
  self.title
}

///|
/// 列宽（逻辑像素）。
pub fn GridColumn::width(self : GridColumn) -> Double {
  self.width
}

///|
/// 是否右对齐。
pub fn GridColumn::right_align(self : GridColumn) -> Bool {
  self.right
}

///|
/// 这一列是不是按数值比大小。
pub fn GridColumn::is_numeric(self : GridColumn) -> Bool {
  self.numeric
}

///|
/// 表格的可变账（与 `RingState` / `SparkState` 同一条理由：绘制回调捕获状态，
/// 控件只是宿主与重画入口）。
struct GridState {
  columns : Array[GridColumn]
  mut rows : Array[Array[String]]
  row_height : Double
  header_height : Double
  font_size : Double
  header_font_size : Double
  pad : Double
  zebra : Bool
  bg : Int32
  header_bg : Int32
  zebra_bg : Int32
  selected_bg : Int32
  text_color : Int32
  header_text : Int32
  border : Int32
  empty_text : String
  mut offset : Double
  /// 横向偏移（逻辑像素）。只在**固定宽**模式下有意义：自适应模式把列压进可用宽，
  /// 横向本来就没有可滚的余量（见 `grid_max_h_offset`）。
  mut h_offset : Double
  /// 上一帧实际用的列宽（自适应模式下是压缩后的）。命中与"滚到某列"按它算——
  /// 命中要跟**用户看到的那一帧**对齐，用快照天然对齐。
  mut last_widths : Array[Double]
  /// 选中行号，`-1` = 没有选中
  mut selected : Int32
  /// 自适应列宽：关掉时各列就是声明宽
  auto_width : Bool
  /// 量出来的自然宽（`auto_width` 开着才有意义）。数据变了要重量——全表扫描
  /// 每格一次后端度量（真机上过一次 C），所以只在数据变了之后重算一次
  mut natural_widths : Array[Double]
  /// 自然宽过期了（数据变了）
  mut widths_dirty : Bool
  /// 排序列号，`-1` = 没排
  mut sort_col : Int32
  /// 排序方向：`true` = 升序，`false` = 降序
  mut sort_asc : Bool
  /// `T102` 第十四刀：排序**请求**回调。`Some` 时表不自己排，只把"用户点了
  /// 哪一列、想要哪个方向"报给调用方，由它重取/重排数据后 `set_rows` 回来。
  ///
  /// 为什么要有这条路：表内置的比较只有字典序与数值序，而真实应用要排的
  /// 是"按热度 / 按最近播放 / 按服务端返回的顺序"这类表看不见的东西，还有
  /// "原始顺序"这一档。`None`（默认）时行为与以前一字不差：表头点击自己排。
  sort_hook : ((Int32, Bool) -> Unit)?
  /// `T102` 第九刀：拖拽重排的起点**数据行号**，`-1` = 没在拖。
  ///
  /// 只在排序列为空时记：排序激活时显示顺序由排序决定，拖拽重排要么看不见、
  /// 要么抬起后被排序立刻覆盖，不如干脆不接。
  mut drag_from : Int32
  /// 按下点（控件局部 y）：用来判"这是拖还是点"——没过阈值就当普通点击。
  mut drag_press_y : Double
  /// 拖拽插入间隙 `0..rows.length()`（放在第 gap 个显示位置**之前**），
  /// `-1` = 没在拖。存显示位置而不是数据行号：间隙本来就不属于任何一行。
  mut drag_gap : Int32
  /// 越过阈值、真正进入拖拽。`false` 时只是按着没动（抬起不该重排）。
  mut dragging : Bool
  /// 显示顺序：第 i 个显示行对应第几条数据（`sort_order` 里的行号）。
  ///
  /// 为什么另存一份而不直接重排 `rows`：`rows` 是**数据**，数据行号必须在排序
  /// 前后都稳定——`set_cell(row, col)` 按数据行号写格子，若排序把 `rows` 重排了，
  /// 同一个 `row` 就会指向另一条数据，写错格子还查不出来。
  mut sort_order : Array[Int32]
  /// 排序键过期了（排序列的内容变了，或换了数据）
  mut sort_dirty : Bool
  /// 粘贴**请求**回调。表是只读的，粘贴进来的内容归调用方
  /// 决定怎么用（换行、改格、还是只记一笔），表只把"哪一行、什么文本"报出去。
  paste_hook : ((Int32, String) -> Unit)?
  /// `T102` 第十六刀：手动调过的列宽（按列号，空 = 全用声明宽）。
  ///
  /// 为什么另存一份而不是改写 `columns`：`columns` 是调用方给的**意图**
  /// （"这列至少这么宽"），拖动只是运行时的调整；`reset_column_widths()`
  /// 要能一键回到调用方给的宽，改写掉就回不去了。
  mut col_widths : Array[Double]
  /// 正在拖哪一列的右边界（`-1` = 没在拖）
  mut resize_col : Int32
  /// 按下点的控件局部 x，以及那一列按下时的宽——拖动是"按下时的宽 + 位移"，
  /// 不是"每一帧加增量"（后者会把帧率算进结果里）。
  mut resize_press_x : Double
  mut resize_start_width : Double
}

///|
/// 只读数据表。`new` 之后用 `widget()` 进布局，`set_rows` / `set_cell` 推数据、
/// `set_offset` / `scroll_to_row` 推滚动、`select_row` 推选中（都自动重画）。
pub struct DataGrid[B] {
  widget : @moonui.Widget[B]
  backend : B
  state : GridState
  size : @moonui.LogicalSize
}

///|
/// 造一张表。
///
/// 参数口径：
/// - `columns` 的宽度是逻辑像素：`auto_width=false`（默认）时是固定宽，总宽可以
///   超过控件宽（这一刀不做横向滚动，超出部分被自绘面自然裁掉）；
/// - `auto_width=true` 时列宽自适应：每列取"自然宽"（表头与该列最宽的一格取较宽
///   者，再加左右内边距）与声明宽（当下限）的较大者；总宽超过控件宽时按比例压
///   缩，装得下就按自然宽排布（**富余留在右侧，不摊开**——摊开之后左对齐的文字列
///   会散得很开，跨列对读反而更难）；
/// - `row_height` 必须为正、`header_height` 可以为零（无表头）；
/// - `font_size` 必须为正；`header_font_size=0` 表示"跟正文字号一样"（表头靠
///   粗体区分）；
/// - `pad` 是单元格左右内边距，列窄到 `pad × 2` 都放不下时那一格干脆不画文字
///   （免得压到隔壁列）；
/// - `zebra` 管隔行底色；选中行永远盖在斑马之上（一次只画一层底）；
/// - `empty_text` 只在没有行时出现在正文正中，`""` 表示什么都不写。
/// - `on_sort` 给了就由**调用方**排序：表头点击（以及 `sort_by_column`）只把
///   "哪一列、哪个方向"报给它（同列再点翻方向、换列回升序，与内置排序同一套
///   口径），表不再自己排，显示顺序就是 `rows` 的顺序——调用方重排好数据后
///   `set_rows` 回来即可；箭头按这次请求画。不给时行为与以前一字不差。
/// - `on_paste` 是粘贴的去处：`⌘V` / `Ctrl+V`（以及 `paste_from_clipboard`）把
///   **(选中行的数据行号, 剪贴板全文)** 报给它，由它决定改哪一格 / 换整行。表是
///   只读的，不给回调时粘贴什么都不做；没有选中行、剪贴板为空时也不回调（粘贴
///   要有去处、要有内容）。
/// - 复制（`⌘C` / `Ctrl+C`）不需要开关：选中行按 TSV 进系统剪贴板，一行一条。
/// - `context_menu` 默认开：右键先选中指针下那一行，再弹一份「复制 / 粘贴」菜单
///   （置灰按"此刻有没有选中行、有没有 `on_paste`"算）。传 `false` 关掉，自己用
///   `widget().set_context_menu(...)` 管——两条路别同时开，否则各弹一次。
///
/// 颜色是 0xRRGGBB，**没有从 `Theme` 取色**：`Theme` 挂在 `App` 上、控件拿不到
/// （与 `ProgressRing` 同一条），先由调用方把色板传进来。
pub fn[B : @moonui.Backend] DataGrid::new(
  backend : B,
  columns : Array[GridColumn],
  rows~ : Array[Array[String]] = [],
  width~ : Double = 360.0,
  height~ : Double = 220.0,
  row_height~ : Double = 24.0,
  header_height~ : Double = 28.0,
  font_size~ : Double = 12.0,
  header_font_size~ : Double = 0.0,
  pad~ : Double = 8.0,
  auto_width~ : Bool = false,
  zebra~ : Bool = true,
  bg~ : Int32 = 0xFFFFFF,
  header_bg~ : Int32 = 0xF1F5F9,
  zebra_bg~ : Int32 = 0xF7FAFC,
  selected_bg~ : Int32 = 0xEBF4FF,
  text_color~ : Int32 = 0x1A202C,
  header_text~ : Int32 = 0x4A5568,
  border~ : Int32 = 0xE2E8F0,
  empty_text~ : String = "",
  on_sort~ : ((Int32, Bool) -> Unit)? = None,
  on_paste~ : ((Int32, String) -> Unit)? = None,
  context_menu~ : Bool = true,
) -> DataGrid[B] raise @moonui.UiError {
  if row_height <= 0.0 {
    raise @moonui.OperationFailed("表格行高必须为正")
  }
  if header_height < 0.0 {
    raise @moonui.OperationFailed("表格表头高度不能为负")
  }
  if font_size <= 0.0 {
    raise @moonui.OperationFailed("表格字号必须为正")
  }
  let w = if width > 0.0 { width } else { 0.0 }
  let h = if height > 0.0 { height } else { 0.0 }
  let state = GridState::{
    columns,
    rows,
    row_height,
    header_height,
    font_size,
    header_font_size: if header_font_size > 0.0 {
      header_font_size
    } else {
      0.0
    },
    pad: if pad > 0.0 {
      pad
    } else {
      0.0
    },
    zebra,
    bg,
    header_bg,
    zebra_bg,
    selected_bg,
    text_color,
    header_text,
    border,
    empty_text,
    offset: 0.0,
    h_offset: 0.0,
    last_widths: [],
    selected: -1,
    auto_width,
    natural_widths: [],
    widths_dirty: true,
    sort_col: -1,
    sort_asc: true,
    sort_hook: on_sort,
    drag_from: -1,
    drag_press_y: 0.0,
    drag_gap: -1,
    dragging: false,
    sort_order: [],
    sort_dirty: false,
    paste_hook: on_paste,
    col_widths: [],
    resize_col: -1,
    resize_press_x: 0.0,
    resize_start_width: 0.0,
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(w, h),
    fn(dl, env) {
      if state.auto_width && state.widths_dirty {
        // 自然宽要量全表（每格一次后端度量），所以只在数据变了之后量一次；每帧
        // 只做"按可用宽压缩"这道纯算术（见 grid_fit_widths）
        state.natural_widths = grid_natural_widths(state, env)
        state.widths_dirty = false
      }
      let widths = grid_column_widths(state, env.width())
      if state.auto_width && env.width() > 0.0 && env.height() > 0.0 {
        // 自适应模式把这一帧实际用的列宽记下来：`column_at` / `scroll_to_column`
        // 要跟用户看到的那一帧对齐，就不能另算一份。
        // 零尺寸那一帧不记：那时 `paint_grid` 会早退、什么都不画，把"压成 0 宽"的
        // 结果记成快照的话，命中就会按一份用户根本没看到的列宽去算
        state.last_widths = widths
      }
      paint_grid(state, dl, env, widths)
    },
    // `T102` 第十一刀：表要键盘（方向键 / 翻页 / Home / End），所以它是少数
    // 需要抢焦点的自绘面——不 opt-in 的话真窗上点它、按方向键，`KeyDown`
    // 派给的是窗口，第十刀的导航一格都走不动。
    focusable=true,
  )
  // `T110`：表头点击的**默认接线**——点表头就按那一列排序（同列再点翻方向）。
  //
  // 为什么现在能做：第五刀记的卡点是"`Click` 不带坐标、自绘面拿不到坐标"。
  // `T110` 之后自绘面能收到带坐标的 `MouseDown`，坐标口径是**窗口/父局部**
  // （Core 的鼠标事件一律如此），所以这里要减掉 `frame().origin` 换算成控件
  // 局部——`column_at` / `header_height` 吃的都是控件局部坐标。
  //
  // 为什么默认就接上、而不是留一个"要不要排序"的开关：表头点了不排序是
  // 用户看得见的"点了没反应"，而排序这件事表自己最清楚（表头高随表头字号
  // 变、列宽自适应、横向偏移换算都在表内）。想自己接管的应用层仍可以在
  // 订阅里拿到 `MouseDown` 再排序——两条路不冲突（订阅是加法）。
  let _ = widget.on_any(fn(ev) raise @moonui.UiError {
    match ev {
      @moonui.MouseDown(_, @moonui.Left, p) => {
        let origin = widget.frame().origin
        let local_x = p.x - origin.x
        let local_y = p.y - origin.y
        // 落在表头那一行才排序（表头高随表头字号变，判据走表自己的账）。
        //
        // `T102` 第十六刀：表头**列边界**上是调列宽，不是排序。先判边界再判列：
        // 两者重叠的那一条缝归"调宽"，否则用户永远调不动（点击总是先命中列）。
        // 自适应模式下边界拖动不接——那里的列宽由"自然宽压进可用宽"决定，
        // 让用户拖了却看不到变化是骗人；这一颗也就**不排序**（拖完手指抬起，
        // 顺手给表排个序不是用户要的）。
        let hh = grid_header_height(state, h)
        if local_y >= 0.0 && local_y < hh {
          match grid_column_edge_at(state, local_x, w) {
            Some(col) =>
              if state.auto_width {
                ()
              } else {
                grid_ensure_col_widths(state)
                let widths = grid_declared_widths(state)
                state.resize_col = col
                state.resize_press_x = local_x
                state.resize_start_width = widths[col]
              }
            None =>
              match grid_column_at(state, local_x, w) {
                Some(col) => {
                  grid_sort_by_column(state, col)
                  widget.repaint()
                }
                None => ()
              }
          }
        } else if local_y >= hh {
          // `T102` 第九刀：正文按下记拖拽起点。**排序激活时不接**——那时显示
          // 顺序由排序决定，拖动改的却是数据顺序，抬起后排序会把它重新排回去，
          // 用户看到的是"拖了没反应"，接上等于骗人。
          if state.sort_col < 0 && state.row_height > 0.0 {
            let body = grid_body_height(state, h)
            let eff = grid_effective_offset(state, body)
            let view_pos = ((local_y - hh + eff) / state.row_height)
              .floor()
              .to_int()
            // 落在正文最后一行以下的空白里不记：那里没有"哪一行"可拖
            if view_pos >= 0 && view_pos < state.rows.length() {
              state.drag_from = grid_data_row_at(state, view_pos)
              state.drag_press_y = local_y
              state.drag_gap = -1
              state.dragging = false
            }
          }
        }
      }
      // 拖动过程：过了阈值才算拖（否则"按一下"会被当成拖到本行、白重排一次）。
      // 阈值用 4 逻辑像素：小于它的是手抖，大于它的才是有意移动。
      @moonui.MouseMove(_, p) =>
        if state.resize_col >= 0 {
          // `T102` 第十六刀：拖列宽。用"按下时的宽 + 位移"算，不是每帧加增量
          // ——后者会把帧率算进结果，同样拖 100 像素，事件多的那台机器更宽。
          let local_x = p.x - widget.frame().origin.x
          let next = state.resize_start_width + (local_x - state.resize_press_x)
          let clamped = if next < grid_min_col_width {
            grid_min_col_width
          } else {
            next
          }
          // 直接写账（不走 `set_column_width`）：拖动中每帧都重画，而那一支
          // 还要按新宽度夹横向偏移——拖动时列宽在长，偏移本来就该跟着夹，
          // 但夹的判断留给抬起那一颗更省事，这里先记账再夹一次。
          state.col_widths[state.resize_col] = clamped
          state.h_offset = grid_clamp_h_offset(state, w, state.h_offset)
          widget.repaint()
        } else if state.drag_from >= 0 {
          let local_y = p.y - widget.frame().origin.y
          if !state.dragging && (local_y - state.drag_press_y).abs() >= 4.0 {
            state.dragging = true
          }
          if state.dragging {
            state.drag_gap = grid_drag_gap_at(state, h, local_y)
            widget.repaint()
          }
        }
      // 抬起：真拖过才提交重排；只是按一下就把状态清干净（不留"下一发移动
      // 还在拖"的残局——自绘面不会收到系统的 mouse-up 之外的补偿事件）。
      @moonui.MouseUp(_, @moonui.Left, _) =>
        if state.resize_col >= 0 {
          // `T102` 第十六刀：抬手收尾。宽度在移动那一颗里已经写进账了，这里只
          // 清拖拽状态并重画一次——不重画的话最后一帧的宽度可能还差一颗事件
          // 的距离（抬起点的位移只在移动事件里被看到过）。
          state.resize_col = -1
          widget.repaint()
        } else if state.drag_from >= 0 {
          if state.dragging && state.drag_gap >= 0 {
            let from = state.drag_from
            let gap = state.drag_gap
            // 间隙是"插到第 gap 个位置之前"；`from` 行先被抽走，所以落在它
            // 后面的间隙要减一才是移除之后的下标
            let to = if gap > from { gap - 1 } else { gap }
            grid_move_row(state, from, to)
          }
          state.drag_from = -1
          state.drag_gap = -1
          state.dragging = false
          widget.repaint()
        }
      // `T102` 第八刀：滚轮的**默认接线**——落在表上的滚轮滚表，不用应用层转。
      //
      // `Scroll` 只带增量、不带位置点（`packages/moonui/event.mbt`），所以这里
      // 只做"把增量加到偏移上"这一件事；"这一发滚轮归哪张表"由事件的 target
      // 决定（订阅是按 target 路由的），不由这张表自己猜指针位置。
      //
      // 增量的单位是**逻辑像素**（adapter.h 鼠标段：C 侧已把行轮/精确滚动换算
      // 完），不是行数，所以直接加、不再乘行高。方向按同一段的约定：正 = 往下
      // 读 / 往右读（偏移增大）。纵向走 `grid_clamp_offset`（"最后一行贴底"
      // 那条上限也在这儿），横向走 `grid_clamp_h_offset`——两笔账各自夹、各自
      // 记，混在一起的话横向滚会把表往下拖。
      @moonui.Scroll(_, delta) => {
        let body = grid_body_height(state, h)
        let mut moved = false
        if delta.y != 0.0 {
          let next = grid_clamp_offset(state, body, state.offset + delta.y)
          if next != state.offset {
            state.offset = next
            moved = true
          }
        }
        if delta.x != 0.0 {
          let next = grid_clamp_h_offset(state, w, state.h_offset + delta.x)
          if next != state.h_offset {
            state.h_offset = next
            moved = true
          }
        }
        if moved {
          widget.repaint()
        }
      }
      // `T102` 第十刀：键盘导航的**默认接线**。
      //
      // 方向键在**显示顺序**上移动（`grid_view_order`），不是数据顺序：排过序之后
      // 用户眼里的"上一行"是屏幕上那一行，按数据行号移动会跳到别处去。`selected`
      // 存的仍是**数据行号**，所以进出各翻译一次（`grid_view_pos_of` /
      // `grid_data_row_at`）。
      //
      // 修饰键必须**全松**才接：`Shift+Down` 将来是扩选区间，`Ctrl`/`Alt`/`Meta`
      // 各有别的语义；现在把它们一并让出去，比事后再拆干净容易。
      //
      // 不接 `Enter` / 空格之类"激活某一行"的键：这张表还没有行激活的概念
      // （没有双击回调、没有行命令），接了等于造一条没人听的语义。
      //
      // 滚动的口径是"只在该行看不见时才滚"（`grid_keep_visible`），不是每次
      // `scroll_to_row`：后者会让光标钉在视口顶部、屏幕整行翻，读起来像翻页。
      // `T102` 第十五刀：复制 / 粘贴的**默认接线**。
      //
      // 为什么放在键盘这一层：表是只读的，复制走的是系统剪贴板（`Backend` 上
      // 本来就有 `clipboard_text` / `set_clipboard_text`），粘贴则是一条"请求"——
      // 表不能替调用方决定换进来的文本怎么用（改一格？换整行？只是提示？），
      // 所以只把 `(数据行号, 文本)` 报给 `on_paste`。
      //
      // 为什么 `meta` 与 `ctrl` 都认：mac 走 `⌘C`，Windows / Linux 走 `Ctrl+C`，
      // 而这张表在三个后端上画的是同一张表。`alt` / `shift` 必须松：`⌘⇧C`
      // 在很多应用里是另一条命令，这里不抢。
      @moonui.KeyDown(_, kp) =>
        if kp.key == "c" && (kp.meta || kp.ctrl) && !kp.alt && !kp.shift {
          let _ = grid_copy_selected(state, backend)
        } else if kp.key == "v" && (kp.meta || kp.ctrl) && !kp.alt && !kp.shift {
          let _ = grid_paste_from_clipboard(state, backend)
        } else if !kp.ctrl && !kp.alt && !kp.shift && !kp.meta {
          let n = state.rows.length()
          if n > 0 {
            let cur = if state.selected >= 0 {
              grid_view_pos_of(state, state.selected)
            } else {
              -1
            }
            let body = grid_body_height(state, h)
            // 一屏能站几行：`PageDown` 走这个步幅。正文比一行还矮时按一行算，
            // 否则翻页就成了原地不动。
            let mut per_page = 1
            if state.row_height > 0.0 {
              let k = (body / state.row_height).floor().to_int()
              if k > 1 {
                per_page = k
              }
            }
            // `handled` 与目标分开记：键名不在词表里时不能落到下面的夹法上——
            // 没有选中时 `cur = -1`，一夹就变成 0，按任何键都会选中第一行。
            let (handled, target) = match kp.key {
              "Down" => (true, if cur < 0 { 0 } else { cur + 1 })
              "Up" => (true, if cur < 0 { 0 } else { cur - 1 })
              "Home" => (true, 0)
              "End" => (true, n - 1)
              "PageDown" => (true, if cur < 0 { 0 } else { cur + per_page })
              "PageUp" => (true, if cur < 0 { 0 } else { cur - per_page })
              _ => (false, cur)
            }
            // 键名不在词表里时 `handled = false`，下面整段不执行
            if handled {
              let clamped = if target < 0 {
                0
              } else if target > n - 1 {
                n - 1
              } else {
                target
              }
              if clamped != cur {
                state.selected = grid_data_row_at(state, clamped)
                let _ = grid_keep_visible(state, body, clamped)
                widget.repaint()
              }
            }
          }
        }
      _ => ()
    }
  })
  // `T102` 第十七刀：右键菜单的**默认接线**。
  //
  // 为什么表自己弹而不是只留 `widget().set_context_menu(...)` 给调用方：右键一张
  // 表时用户期待的就是那份"复制 / 粘贴"，而这两件事表自己就能做（第十五刀已经
  // 把两个入口备好）。菜单每次右键**现造**，不是装一份再改勾选态——「复制」要
  // 按"此刻有没有选中行"启停，复用同一份会依赖"改状态"与"框架弹菜单"两段订阅
  // 的先后（`set_context_menu` 的订阅在 `new` 之外，顺序由调用方决定）。
  //
  // 右键先**选中指针下那一行**：标准表格语义，也让「复制」的目标就是用户按下的
  // 那一行。落在表头 / 正文空白处不改选中（那两处没有"哪一行"），菜单照弹。
  //
  // 自己要一份菜单的应用传 `context_menu=false`，再 `set_context_menu`，两条
  // 路别同时开——同时开就是两段订阅各弹一次。
  if context_menu {
    let _ = widget.on_any(fn(ev) raise @moonui.UiError {
      match ev {
        @moonui.MouseDown(_, @moonui.Right, p) => {
          let origin = widget.frame().origin
          let local_y = p.y - origin.y
          let hh = grid_header_height(state, h)
          if local_y >= hh && state.row_height > 0.0 {
            let body = grid_body_height(state, h)
            let eff = grid_effective_offset(state, body)
            let view_pos = ((local_y - hh + eff) / state.row_height)
              .floor()
              .to_int()
            if view_pos >= 0 && view_pos < state.rows.length() {
              state.selected = grid_data_row_at(state, view_pos)
              widget.repaint()
            }
          }
          grid_show_context_menu(state, backend)
        }
        _ => ()
      }
    })
  }
  { widget, backend, state, size: @moonui.LogicalSize(w, h), }
}

///|
/// 有效表头高：不超过整块面的高（表头比控件还高时，表头占满、正文为零）。
fn grid_header_height(state : GridState, surface : Double) -> Double {
  if state.header_height <= 0.0 {
    0.0
  } else if state.header_height > surface {
    surface
  } else {
    state.header_height
  }
}

///|
/// 正文高（表头以下的部分）。
fn grid_body_height(state : GridState, surface : Double) -> Double {
  let body = surface - grid_header_height(state, surface)
  if body > 0.0 {
    body
  } else {
    0.0
  }
}

///|
/// 偏移上限：滚到最后一行的底边对齐正文底边就到头了，再滚就是空屏。
fn grid_max_offset(state : GridState, body : Double) -> Double {
  let total = state.rows.length().to_double() * state.row_height
  let max = total - body
  if max > 0.0 {
    max
  } else {
    0.0
  }
}

///|
/// 真正生效的偏移：夹到 `[0, 上限]`。
///
/// 为什么夹在**读**的地方也要做一次：`set_offset` 只能用声明高度算上限，调用方
/// 一旦用 `.height()` 覆盖过实际高度，两者就不一致了——绘制时按真实高度再夹一
/// 次，才算"无论怎么改尺寸都不会滚出空屏"。
fn grid_clamp_offset(
  state : GridState,
  body : Double,
  offset : Double,
) -> Double {
  let max = grid_max_offset(state, body)
  let off = if offset > max { max } else { offset }
  if off < 0.0 {
    0.0
  } else {
    off
  }
}

///|
/// 当前偏移夹过之后的值。
fn grid_effective_offset(state : GridState, body : Double) -> Double {
  grid_clamp_offset(state, body, state.offset)
}

///|
/// 窗口第一行：`floor(偏移 / 行高)`，越界夹到表的两端。
fn grid_first_row(state : GridState, body : Double) -> Int32 {
  let n = state.rows.length()
  if n == 0 {
    return 0
  }
  let eff = grid_effective_offset(state, body)
  let first = (eff / state.row_height).floor().to_int()
  if first < 0 {
    0
  } else if first > n - 1 {
    n - 1
  } else {
    first
  }
}

///|
/// 画一格文字：把内边距吃掉之后交给 `draw_fitted_text`（`text_fit.mbt`）。
///
/// 这一层只负责"格子 → 文字区"的换算（左右各让出 `pad`），省略、夹住、右对齐
/// 都在共用件里——树的行文案走的是同一条，改一处两边同时生效。
fn draw_cell_text(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  text : String,
  col_x : Double,
  col_w : Double,
  top : Double,
  height : Double,
  size : Double,
  bold : Bool,
  rgb : Int32,
  pad : Double,
  right_align : Bool,
) -> Unit {
  let avail = col_w - pad * 2.0
  if avail <= 0.0 {
    return
  }
  draw_fitted_text(
    dl,
    env,
    text,
    col_x + pad,
    avail,
    top,
    height,
    size,
    bold,
    rgb,
    right_align,
  )
}

///|
/// 固定列宽（`auto_width` 关掉时用）：各列声明的宽，手动调过的那一列用调过的值。
///
/// 只在这一处合流（绘制、命中、横向偏移上限、滚到某列都调它），所以"拖动改了宽"
/// 之后每一处看到的都是同一份宽——各自去读 `columns[i].width` 的话，拖过的表会
/// 出现"画的是新宽、点的是旧宽"。
fn grid_declared_widths(state : GridState) -> Array[Double] {
  let out = Array(capacity=state.columns.length())
  let mut i = 0
  for col in state.columns {
    let over = if i < state.col_widths.length() {
      state.col_widths[i]
    } else {
      0.0
    }
    out.push(if over > 0.0 { over } else { col.width })
    i = i + 1
  }
  out
}

///|
/// 自然宽：每列 = max(表头宽, 该列最宽的一格) + 2×内边距，且不小于声明宽。
///
/// 代价与缓存：自然宽要量全表——每格一次后端度量（真机上过一次 C），所以量出来
/// 的结果缓存在状态里，只在数据变了之后重算一次（见 `widths_dirty`），每帧只做
/// "按可用宽压缩"那道纯算术。
fn grid_natural_widths(
  state : GridState,
  env : @moonui.PaintEnv,
) -> Array[Double] {
  let ncols = state.columns.length()
  let out = Array(capacity=ncols)
  let hfs = if state.header_font_size > 0.0 {
    state.header_font_size
  } else {
    state.font_size
  }
  let mut j = 0
  while j < ncols {
    let col = state.columns[j]
    let (hw, _) = env.measure_text(col.title, hfs, true)
    let mut widest = hw
    let mut i = 0
    while i < state.rows.length() {
      let row = state.rows[i]
      // 短行（列数不够的稀疏行）按空串算：宽度上它不占位
      if j < row.length() {
        let (cw, _) = env.measure_text(row[j], state.font_size, false)
        if cw > widest {
          widest = cw
        }
      }
      i = i + 1
    }
    let natural = widest + state.pad * 2.0
    out.push(if natural < col.width { col.width } else { natural })
    j = j + 1
  }
  out
}

///|
/// 把自然宽压进可用宽：装得下就按自然宽（**富余留在右侧**），装不下按比例压缩。
///
/// 为什么富余不摊到各列：摊开之后左对齐的文字列会被拉得很散，跨列对读反而更
/// 难——表格的用处就是"一列一列对得上"，紧挨着比铺满要紧。富余留在右边是列表
/// 视图的常见做法（macOS 的文件列表也这样）。
///
/// 为什么压缩按比例而不是"先压最宽的那列"：比例是纯算术、可预测、也容易对账；
/// "先压最宽的"要一轮轮迭代才收敛，结果还依赖列的顺序。
fn grid_fit_widths(natural : Array[Double], avail : Double) -> Array[Double] {
  let n = natural.length()
  let out = Array(capacity=n)
  if n == 0 {
    return out
  }
  let mut total = 0.0
  let mut i = 0
  while i < n {
    total = total + natural[i]
    i = i + 1
  }
  if total <= avail || total <= 0.0 {
    let mut k = 0
    while k < n {
      out.push(natural[k])
      k = k + 1
    }
    return out
  }
  let scale = avail / total
  let mut j = 0
  while j < n {
    out.push(natural[j] * scale)
    j = j + 1
  }
  out
}

///|
/// 这一帧真正用的列宽。自适应开着就用"自然宽压进可用宽"，否则就是声明宽。
///
/// 自然宽还没量出来时（第一帧之前）退回声明宽：宁可先用固定宽画一帧，也不要
/// 因为缓存没就绪而画不出列。
fn grid_column_widths(state : GridState, avail : Double) -> Array[Double] {
  if !state.auto_width {
    return grid_declared_widths(state)
  }
  if state.natural_widths.length() != state.columns.length() {
    return grid_declared_widths(state)
  }
  grid_fit_widths(state.natural_widths, avail)
}

///|
/// 横向偏移上限：总列宽减去控件宽（装得下就是 0）。
///
/// **自适应模式恒为 0**：自适应把列压进可用宽，横向本来就没有可滚的余量。两种
/// 模式是互斥的两条路——"我要一屏看到所有列" vs "我给每列定好了宽"——所以横向
/// 滚动只对固定宽模式有意义。
fn grid_max_h_offset(state : GridState, surface : Double) -> Double {
  if state.auto_width {
    return 0.0
  }
  let widths = grid_declared_widths(state)
  let mut total = 0.0
  let mut i = 0
  while i < widths.length() {
    total = total + widths[i]
    i = i + 1
  }
  let max = total - surface
  if max > 0.0 {
    max
  } else {
    0.0
  }
}

///|
/// 横向偏移夹在 `[0, 上限]`。
///
/// 为什么夹在**读**的地方也要做一次：与纵向同一条理由——`set_h_offset` 只能用
/// 声明宽算上限，调用方一旦用 `.width()` 覆盖过实际宽度，两者就不一致了；绘制时
/// 按真实宽度再夹一次，才算"无论怎么改尺寸都不会滚出一片空白"。
fn grid_clamp_h_offset(
  state : GridState,
  surface : Double,
  offset : Double,
) -> Double {
  let max = grid_max_h_offset(state, surface)
  let off = if offset > max { max } else { offset }
  if off < 0.0 {
    0.0
  } else {
    off
  }
}

///|
/// 当前生效的横向偏移。
fn grid_effective_h_offset(state : GridState, surface : Double) -> Double {
  grid_clamp_h_offset(state, surface, state.h_offset)
}

///|
/// 拿一格的值；短行（列数不够）按空串算。
fn grid_cell(state : GridState, row : Int32, col : Int32) -> String {
  let cells = state.rows[row]
  if col < cells.length() {
    cells[col]
  } else {
    ""
  }
}

///|
/// 两个文本的字典序比较（负数 / 0 / 正数）。
///
/// **不能用 `<` 运算符**——MoonBit 给 `String` 的 `Compare` 实现是 **shortlex**
/// （长度优先，长度一样才比字符码，见 `builtin/string.mbt` 的
/// `impl Compare for String`）。shortlex 下 `"9" < "10"` 成立（1 < 2），排序出来是
/// 9 → 10 → 100；而用户心里的字典序是 `"10" < "100" < "9"`。更糟的是 shortlex 与
/// 数值序在这批数据上**恰好一致**，两个口径混在一起，看不出差别。
///
/// 所以这里显式用 `String::lexical_compare`（逐 UTF-16 码元比，前缀短者在前）。
fn grid_text_cmp(a : String, b : String) -> Int32 {
  a.lexical_compare(b)
}

///|
/// 一格按数值比还是按字典序比。`numeric` 说的是"这一列是数字列"。
///
/// 数值列里有一格解析不出来（""、"--"、"1,234"）怎么办：**这一格退回字典序**。
/// 为什么不是"解析不出来就当 0"：那会把 "--" 和真正的 0 混成一堆，排出来的顺序
/// 骗人。退回字典序是诚实的——那一格跟别的数字本来就不可比。
fn grid_cell_less(
  state : GridState,
  a : Int32,
  b : Int32,
  col : Int32,
  numeric : Bool,
) -> Bool {
  let va = grid_cell(state, a, col)
  let vb = grid_cell(state, b, col)
  if numeric {
    let da = grid_parse_number(va)
    let db = grid_parse_number(vb)
    match (da, db) {
      (Some(x), Some(y)) =>
        if x < y {
          true
        } else if x > y {
          false
        } else {
          // 数值相等：按字符串再比一次（"1" 与 "1.0" 谁在前要有定论），
          // 还相等就按原行号比（见 grid_sort_cmp）
          grid_text_cmp(va, vb) < 0
        }
      (Some(_), None) => false
      (None, Some(_)) => true
      (None, None) => grid_text_cmp(va, vb) < 0
    }
  } else {
    grid_text_cmp(va, vb) < 0
  }
}

///|
/// 解析一个数字；解析不出来给 `None`。
///
/// 用 `core/string` 的 `parse_double`（标准库，不是 backends——依赖闸门管的是
/// `backends/`）。它对 "abc"、""、带逗号的都会 raise，这里接住当 `None`。
fn grid_parse_number(s : String) -> Double? {
  if s == "" {
    return None
  }
  try {
    let d = @string.parse_double(s)
    if d.is_nan() {
      None
    } else {
      Some(d)
    }
  } catch {
    _ => None
  }
}

///|
/// 排序比较：返回负数表示 a 在前。
///
/// **必须稳定**——`Array::sort_by` 是不稳定的（相等元素的相对次序会被打乱）。
/// 表格里同价的两行换位置是用户看得见的抖动（点一下排序，行就跳了），所以比较
/// 函数在键相等时按**原行号**兜底：同键的行保持原有的先后。
fn grid_sort_cmp(
  state : GridState,
  a : Int32,
  b : Int32,
  col : Int32,
  numeric : Bool,
) -> Int32 {
  if grid_cell_less(state, a, b, col, numeric) {
    -1
  } else if grid_cell_less(state, b, a, col, numeric) {
    1
  } else if a < b {
    -1
  } else if a > b {
    1
  } else {
    0
  }
}

///|
/// 重算显示顺序。
///
/// 排序列是 `sort_col` 时按它排（升序或降序），否则就是原序。
/// 降序的做法不是"排完再反转"——反转会把同键行的相对次序也一起反过来（稳定性
/// 就没了），而是**比较时把方向算进去**。
fn grid_rebuild_sort(state : GridState) -> Unit {
  let n = state.rows.length()
  // `T102` 第十四刀：有排序回调时**表不排**——数据是调用方按自己的口径排好
  // 送进来的，显示顺序就是数据顺序。这里也必须走这一支：`set_rows` 会把
  // `sort_dirty` 置真，若放它进下面的内置比较，调用方排好的顺序会被表的
  // 字典序再排一遍（而它用哪个键排的，表根本不知道），表头箭头与正文对不上。
  let external = match state.sort_hook {
    Some(_) => true
    None => false
  }
  if external || state.sort_col < 0 || state.sort_col >= state.columns.length() {
    // 没排序（或排序归调用方）：显示顺序就是原序
    state.sort_order = Array(capacity=n)
    let mut i = 0
    while i < n {
      state.sort_order.push(i)
      i = i + 1
    }
    state.sort_dirty = false
    return
  }
  let col = state.sort_col
  let numeric = state.columns[col].numeric
  let asc = state.sort_asc
  // 先把行号按"值"排好，再用稳定的方式落到数组里：直接 sort 一个行号数组，
  // 比较函数里带上原行号做 tiebreak（见 grid_sort_cmp）
  let order = Array(capacity=n)
  let mut i = 0
  while i < n {
    order.push(i)
    i = i + 1
  }
  order.sort_by(fn(a : Int32, b : Int32) {
    let c = grid_sort_cmp(state, a, b, col, numeric)
    if asc {
      c
    } else {
      -c
    }
  })
  state.sort_order = order
  state.sort_dirty = false
}

///|
/// 这一帧用的显示顺序（必要时先重算）。
fn grid_view_order(state : GridState) -> Array[Int32] {
  if state.sort_dirty {
    grid_rebuild_sort(state)
  }
  state.sort_order
}

///|
/// 显示位置 → 数据行号。
///
/// 这一层是第五刀补上的：排序把"第几行"劈成了两个意思——**显示位置**（屏幕上
/// 第几行）与**数据行号**（`rows` 里的第几条）。公开 API 一律用**数据行号**
/// （`cell` / `set_cell` / `select_row` 都是这个口径），显示位置只在包内活着。
/// 少这一层翻译，"排序后点一行高亮到别处"就会发生。
fn grid_data_row_at(state : GridState, view_pos : Int32) -> Int32 {
  let view = grid_view_order(state)
  if view_pos < 0 || view_pos >= view.length() {
    view_pos
  } else {
    view[view_pos]
  }
}

///|
/// 数据行号 → 显示位置。
///
/// `grid_data_row_at` 的逆。找不到（数据行号越界、或排序表里没有这一行）时
/// 原样返回：调用方拿它去算偏移，越界自有夹法收拾。
fn grid_view_pos_of(state : GridState, data_row : Int32) -> Int32 {
  let view = grid_view_order(state)
  let mut i = 0
  while i < view.length() {
    if view[i] == data_row {
      return i
    }
    i = i + 1
  }
  data_row
}

///|
/// 让某个显示位置的行落在视口里：**只在该行看不见时才滚**，且滚到"刚好露出"。
///
/// 为什么不是每次都 `scroll_to_row`：那样按一次 `Down` 屏幕就跟着滚一整行，
/// 选中条钉在顶部不动，读起来像翻页而不是移动光标。桌面表格的惯例是"光标在
/// 视口内走，走到边上才把视口推一格"。
///
/// 返回有没有改偏移（调用方据此决定要不要重画）。
fn grid_keep_visible(
  state : GridState,
  body : Double,
  view_pos : Int32,
) -> Bool {
  if state.row_height <= 0.0 || body <= 0.0 {
    return false
  }
  let eff = grid_effective_offset(state, body)
  let top = view_pos.to_double() * state.row_height
  let bottom = top + state.row_height
  let want = if top < eff {
    top
  } else if bottom > eff + body {
    bottom - body
  } else {
    eff
  }
  let next = grid_clamp_offset(state, body, want)
  if next != state.offset {
    state.offset = next
    true
  } else {
    false
  }
}

///|
/// 控件局部 y → 拖拽插入间隙 `0..rows.length()`（放在第 gap 个显示位置**之前**）。
///
/// 用 `round` 不用 `floor`：指针落在某行**上半**时插到这一行前面，落在**下半**
/// 时插到它后面——这正是"拖到哪条线"的直觉。指针在表头里给 0、拖过表尾给 n，
/// 两端都夹住（拖出控件也还能落到第一/最后）。
fn grid_drag_gap_at(state : GridState, surface : Double, y : Double) -> Int32 {
  if state.row_height <= 0.0 {
    return 0
  }
  let hh = grid_header_height(state, surface)
  let body = grid_body_height(state, surface)
  let eff = grid_effective_offset(state, body)
  let rel = y - hh + eff
  let n = state.rows.length()
  let gap = (rel / state.row_height).round().to_int()
  if gap < 0 {
    0
  } else if gap > n {
    n
  } else {
    gap
  }
}

///|
/// 把第 `from` 行移到索引 `to`（移完之后它位于 `to`）——公开 `move_row` 与
/// 拖拽提交共用这一份，别在两处各写一套顺序账。
///
/// **这是真改数据顺序**，不是排序那种"只改显示顺序"：之后的数据行号按新顺序
/// 重编，外部留着的旧行号会指向另一条数据（`set_cell(old_row, …)` 会写错格）。
/// 选中行号跟着数据一起走，不然用户会发现"高亮条留在了原地"。
fn grid_move_row(state : GridState, from : Int32, to : Int32) -> Unit {
  let n = state.rows.length()
  if from == to || from < 0 || from >= n || to < 0 || to >= n {
    return
  }
  let moving = state.rows[from]
  let next : Array[Array[String]] = []
  let mut i = 0
  while i < n {
    if i == from {
      // 原位置抽走；`moving` 什么时候落地由下面"输出位置 == to"决定
      i = i + 1
      continue
    }
    if next.length() == to {
      next.push(moving)
    }
    next.push(state.rows[i])
    i = i + 1
  }
  if next.length() == to {
    next.push(moving)
  }
  state.rows = next
  let sel = state.selected
  if sel == from {
    state.selected = to
  } else if from < sel && sel <= to {
    state.selected = sel - 1
  } else if to <= sel && sel < from {
    state.selected = sel + 1
  }
  // 排序激活时显示顺序要按值重算：行号已经重编，旧的 `sort_order` 会指错数据。
  // （拖拽本身只在无排序时进入，但 `move_row` 是公开 API，排序中也可能被调。）
  if state.sort_col >= 0 {
    state.sort_dirty = true
    grid_rebuild_sort(state)
  }
}

///|
/// 命中与定位用的列宽：与"这一帧画出来的"一致。
///
/// 固定宽模式就是声明宽；自适应模式用上一帧的快照（压缩后的实际宽）。为什么用
/// 快照而不是现算：自然宽要过一遍后端度量（真机上过一次 C），而命中是交互路径
/// 上的高频调用；更要紧的是命中要跟**用户看到的那一帧**对齐，快照天然对齐。
fn grid_layout_widths(state : GridState, surface : Double) -> Array[Double] {
  if !state.auto_width {
    return grid_declared_widths(state)
  }
  if state.last_widths.length() == state.columns.length() {
    return state.last_widths
  }
  grid_column_widths(state, surface)
}

///|
/// 把整张表画进这份清单。纯函数：不读后端、不 raise，度量全走 `PaintEnv`。
///
/// 命令顺序是有讲究的：底 → 表头 → 表头文案 → 表头下边线 → 逐行（底色 →
/// 单元格 → 行分隔线）→ 空表文案 → 竖向分列线。分列线必须最后画，否则会被
/// 斑马/选中的底色整条盖掉（第一版就是这么错的）。
fn paint_grid(
  state : GridState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  widths : Array[Double],
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let hh = grid_header_height(state, h)
  let body = h - hh
  // 横向偏移：固定宽模式下总列宽可以超过控件宽，滚动的列一起左移
  let hoff = grid_effective_h_offset(state, w)
  dl.fill_rect(0.0, 0.0, w, h, rgb=state.bg)
  if hh > 0.0 {
    dl.fill_rect(0.0, 0.0, w, hh, rgb=state.header_bg)
    let hfs = if state.header_font_size > 0.0 {
      state.header_font_size
    } else {
      state.font_size
    }
    // 列的屏幕起点 = 内容起点 - 横向偏移；完全滚出视野的列整列不画
    // （与纵向的窗口化同一条：看不见的就不发命令）
    let mut cx = 0.0
    let mut hj = 0
    while hj < state.columns.length() {
      let col = state.columns[hj]
      let cw = widths[hj]
      let sx = cx - hoff
      if sx + cw > 0.0 && sx < w {
        draw_cell_text(
          dl,
          env,
          col.title,
          sx,
          cw,
          0.0,
          hh,
          hfs,
          true,
          state.header_text,
          state.pad,
          col.right,
        )
        // 排序列的表头后面画一个方向箭头（▲ 升 / ▼ 降）
        if hj == state.sort_col {
          draw_sort_marker(
            dl,
            env,
            sx,
            cw,
            0.0,
            hh,
            hfs,
            state.sort_asc,
            state.header_text,
            state.pad,
          )
        }
      }
      cx = cx + cw
      hj = hj + 1
    }
    if hh < h {
      dl.line(0.0, hh, w, hh, width=1.0, rgb=state.border)
    }
  }
  let n = state.rows.length()
  let eff = grid_effective_offset(state, body)
  // 显示顺序是**整帧一份**的量，不是每行一份：原来在循环里取，每行都要过一次
  // 脏检查与数组取用
  let view = grid_view_order(state)
  let mut i = grid_first_row(state, body)
  while i < n && hh + i.to_double() * state.row_height - eff < h {
    let y = hh + i.to_double() * state.row_height - eff
    // 正文取的是**显示顺序**里的第 i 行对应的数据行
    let data_row = if i < view.length() { view[i] } else { i }
    // 选中比的是**数据行号**（`state.selected` 存的就是它），不是显示位置——
    // 排序之后这两者会分家，比错了就高亮到另一条数据上
    if state.selected == data_row {
      dl.fill_rect(0.0, y, w, state.row_height, rgb=state.selected_bg)
    } else if state.zebra && i % 2 == 1 {
      dl.fill_rect(0.0, y, w, state.row_height, rgb=state.zebra_bg)
    }
    let row = state.rows[data_row]
    let mut cx = 0.0
    for j, col in state.columns {
      let cw = widths[j]
      let sx = cx - hoff
      if sx + cw > 0.0 && sx < w {
        // 短行（列数不够的稀疏行）按空串画：数据是从 CSV/接口来的，行不齐是常态，
        // 为这个 raise 等于把"补空"的活推给每个调用方
        let text = if j < row.length() { row[j] } else { "" }
        draw_cell_text(
          dl,
          env,
          text,
          sx,
          cw,
          y,
          state.row_height,
          state.font_size,
          false,
          state.text_color,
          state.pad,
          col.right,
        )
      }
      cx = cx + cw
    }
    // 贴着底边的分隔线不画：它落在自绘面之外，画了也是被裁掉，白白多一条命令
    if y + state.row_height < h {
      dl.line(
        0.0,
        y + state.row_height,
        w,
        y + state.row_height,
        width=1.0,
        rgb=state.border,
      )
    }
    i = i + 1
  }
  // `T102` 第九刀：拖拽落点的那条线。画在插入间隙上（gap 0 = 第一行顶边、
  // gap n = 最后一行底边），夹在正文区里——拖到表头里或表外时线不该跑出控件。
  if state.dragging && state.drag_gap >= 0 {
    let gy = hh + state.drag_gap.to_double() * state.row_height - eff
    let cy = if gy < hh { hh } else if gy > h { h } else { gy }
    dl.line(0.0, cy, w, cy, width=2.0, rgb=0x3182CE)
  }
  if n == 0 && state.empty_text != "" && body > 0.0 {
    let (tw, th) = env.measure_text(state.empty_text, state.font_size, false)
    dl.text(
      state.empty_text,
      (w - tw) / 2.0,
      hh + (body - th) / 2.0,
      size=state.font_size,
      rgb=state.text_color,
    )
  }
  let nc = state.columns.length()
  if nc > 1 && body > 0.0 {
    // 分列线跟着横向偏移走；落在控件外的那些不画（画了也被裁掉，白费命令）
    let mut cx = 0.0
    let mut j = 0
    while j + 1 < nc {
      cx = cx + widths[j]
      let sx = cx - hoff
      if sx >= 0.0 && sx <= w {
        dl.line(sx, hh, sx, h, width=1.0, rgb=state.border)
      }
      j = j + 1
    }
  }
}

///|
/// 表头里的排序方向箭头。
///
/// 画在**表头文字的右边**（右对齐的列则画在文字左边）——跟着对齐走，箭头永远在
/// 文字外侧，不会压住标题。
fn draw_sort_marker(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  col_x : Double,
  col_w : Double,
  top : Double,
  height : Double,
  size : Double,
  asc : Bool,
  rgb : Int32,
  pad : Double,
) -> Unit {
  let marker = if asc { "▲" } else { "▼" }
  let (mw, mh) = env.measure_text(marker, size, false)
  let my = top + (height - mh) / 2.0
  // 箭头跟着对齐走：右对齐的列，箭头贴在左边（外侧）
  let mx = if col_w - pad * 2.0 < mw * 2.0 {
    // 列太窄：箭头贴在文字区最左边
    col_x + pad
  } else {
    col_x + col_w - pad - mw
  }
  dl.text(marker, mx, my, size~, rgb~)
}

///|
/// 拿控件进布局。
pub fn[B] DataGrid::widget(self : DataGrid[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 声明尺寸。
pub fn[B] DataGrid::size(self : DataGrid[B]) -> @moonui.LogicalSize {
  self.size
}

///|
/// 行数。
pub fn[B] DataGrid::row_count(self : DataGrid[B]) -> Int32 {
  self.state.rows.length()
}

///|
/// 列数。
pub fn[B] DataGrid::column_count(self : DataGrid[B]) -> Int32 {
  self.state.columns.length()
}

///|
/// 行高（逻辑像素）——调用方要把窗口坐标换算成行号时用得上。
pub fn[B] DataGrid::row_height(self : DataGrid[B]) -> Double {
  self.state.row_height
}

///|
/// 表头高（逻辑像素）。
pub fn[B] DataGrid::header_height(self : DataGrid[B]) -> Double {
  self.state.header_height
}

///|
/// 当前滚动偏移（逻辑像素）。
pub fn[B] DataGrid::offset(self : DataGrid[B]) -> Double {
  self.state.offset
}

///|
/// 当前选中行号，`-1` = 没有选中。
pub fn[B] DataGrid::selected(self : DataGrid[B]) -> Int32 {
  self.state.selected
}

///|
/// 某一格的内容；行号或列号越界给 `None`。
pub fn[B] DataGrid::cell(
  self : DataGrid[B],
  row : Int32,
  col : Int32,
) -> String? {
  if row < 0 || row >= self.state.rows.length() {
    return None
  }
  let cells = self.state.rows[row]
  if col < 0 || col >= cells.length() {
    return None
  }
  Some(cells[col])
}

///|
/// 把控件局部坐标里的 y 换算成行号：表头里、表下方空白、越界都给 `None`。
///
/// 为什么要这个口子：Core 的事件是有的，但 `MouseDown` / `MouseMove` 带的是
/// **窗口/父局部**坐标（`T108` 的真窗判据就是按 `frame().origin + size/2` 断言的），
/// 而且"第几行"这个概念只有表自己知道——它要表头高、行高、当前偏移三样内部账。
/// 与其让每个调用方各抄一份换算（还得跟虚拟窗口的夹法对齐），不如这里给一条。
/// 调用方把 `y - 控件frame.origin.y` 递进来即可；`height` 传了就用它（控件被
/// `.height()` 覆盖过时），不传按声明高度算。
///
/// 返回的是**数据行号**（与 `cell` / `set_cell` / `select_row` 同一口径），不是
/// 屏幕上的第几行：排序之后这两者会分家，调用方多半是拿它去选中或读格子，
/// 给显示位置的话，选中的是另一条数据。
pub fn[B] DataGrid::row_at(
  self : DataGrid[B],
  y : Double,
  height~ : Double = -1.0,
) -> Int32? {
  let surface = if height > 0.0 { height } else { self.size.height }
  let hh = grid_header_height(self.state, surface)
  let body = surface - hh
  if y < hh || body <= 0.0 {
    return None
  }
  let eff = grid_effective_offset(self.state, body)
  let rel = y - hh + eff
  let view_pos = (rel / self.state.row_height).floor().to_int()
  if view_pos < 0 || view_pos >= self.state.rows.length() {
    None
  } else {
    // 显示位置 → 数据行号
    Some(grid_data_row_at(self.state, view_pos))
  }
}

///|
/// 当前横向偏移（逻辑像素）。
pub fn[B] DataGrid::h_offset(self : DataGrid[B]) -> Double {
  self.state.h_offset
}

///|
/// 推一个横向偏移并重画（负值归零、越过尾部夹到"最后一列贴右"）。
///
/// 只在**固定宽**模式下有意义：自适应模式把列压进可用宽，横向偏移恒为 0
/// （`grid_max_h_offset` 直接给 0）。
pub fn[B : @moonui.Backend] DataGrid::set_h_offset(
  self : DataGrid[B],
  offset : Double,
) -> Unit raise @moonui.UiError {
  let surface = self.size.width
  self.state.h_offset = grid_clamp_h_offset(self.state, surface, offset)
  self.widget.repaint()
}

///|
/// 把控件局部坐标里的 x 换算成列号：控件外、右侧的空白都给 `None`。
///
/// 与 `row_at` 同一条思路：`column_at` 只回答"落在哪一列"，"点的是不是表头"由
/// 调用方拿 `header_height()` 自己比（表头高随表头字号变，表自己最清楚）。
///
/// 横向滚过之后 x 是**屏幕坐标**，这里加上当前横向偏移换算回内容坐标再定位。
/// 坐标一律控件局部逻辑像素——Core 的鼠标事件带的是窗口/父局部坐标，调用方要
/// 先减掉 `frame().origin`。
pub fn[B] DataGrid::column_at(
  self : DataGrid[B],
  x : Double,
  width~ : Double = -1.0,
) -> Int32? {
  let surface = if width > 0.0 { width } else { self.size.width }
  grid_column_at(self.state, x, surface)
}

///|
/// 控件局部 x → 列号（`T110` 抽出来给默认接线用）。
///
/// 与 `column_at` 同一条实现——表头点击的默认接线要答"落在哪一列"，走的正是
/// 这一道算术（自适应模式的压缩后列宽、横向偏移的换算都在里面），两处各算
/// 一次的话，改了一处忘了另一处，"点表头"就会点在跟用户看到的不一样的列上。
fn grid_column_at(state : GridState, x : Double, surface : Double) -> Int32? {
  if x < 0.0 || x >= surface {
    return None
  }
  let widths = grid_layout_widths(state, surface)
  let hoff = grid_effective_h_offset(state, surface)
  let content_x = x + hoff
  let mut acc = 0.0
  let mut j = 0
  while j < widths.length() {
    let cw = widths[j]
    if content_x < acc + cw {
      return Some(j)
    }
    acc = acc + cw
    j = j + 1
  }
  None
}

///|
/// `T102` 第十六刀：列边界的手感半径（逻辑像素）。
///
/// 4 像素与第九刀的拖拽阈值同一条口径：小于它的是手抖，大于它的才是有意。
/// 太小则"想调宽"老是点成排序，太大则两列之间那一小段都点不了表头。
let grid_resize_grab : Double = 4.0

///|
/// 列宽下限（逻辑像素）。拖到更窄时停在这儿，而不是夹成 0：0 宽列等于让
/// 这一列**消失**，而用户想要的通常是"窄一点"。
let grid_min_col_width : Double = 24.0

///|
/// 把"手动调过的列宽"这本账铺成与列数等长（`0.0` = 这一列没调过）。
///
/// 稀疏账比"每列都从声明宽拷一份"省一点，但真正的理由是**语义**：`0` 明确表示
/// "用调用方给的宽"，`reset_column_widths` 只要清空整本账就回到原样。
fn grid_ensure_col_widths(state : GridState) -> Unit {
  let n = state.columns.length()
  if state.col_widths.length() == n {
    return
  }
  let full = Array(capacity=n)
  let mut i = 0
  while i < n {
    full.push(0.0)
    i = i + 1
  }
  state.col_widths = full
}

///|
/// 控件局部 x 落在哪一列的**右边界**上（`None` = 不在任何边界附近）。
///
/// 与 `grid_column_at` 同一套坐标换算（横向偏移、这一帧的实际列宽），差别只在
/// "离边界的距离"：命中列用区间、命中边界用距离。
fn grid_column_edge_at(
  state : GridState,
  x : Double,
  surface : Double,
) -> Int32? {
  if x < 0.0 || x >= surface {
    return None
  }
  let widths = grid_layout_widths(state, surface)
  let hoff = grid_effective_h_offset(state, surface)
  let content_x = x + hoff
  let mut acc = 0.0
  let mut j = 0
  while j < widths.length() {
    acc = acc + widths[j]
    if (content_x - acc).abs() <= grid_resize_grab {
      return Some(j)
    }
    j = j + 1
  }
  None
}

///|
/// 把某一列的宽定成 `width`（逻辑像素，夹到 `grid_min_col_width` 以上）并重画。
///
/// **只在固定宽模式下有意义**：自适应模式下声明宽只是下限，列的实际宽由"自然宽
/// 压进可用宽"决定，定多宽都会被那一套盖掉——所以这里在自适应模式下**不动**
/// （不是"改了但不生效"：后者会让调用方以为设进去了）。拖动的那条路同理，直接
/// 不接。
pub fn[B : @moonui.Backend] DataGrid::set_column_width(
  self : DataGrid[B],
  col : Int32,
  width : Double,
) -> Unit raise @moonui.UiError {
  if self.state.auto_width || col < 0 || col >= self.state.columns.length() {
    return
  }
  grid_ensure_col_widths(self.state)
  let w = if width < grid_min_col_width { grid_min_col_width } else { width }
  self.state.col_widths[col] = w
  // 变宽之后横向偏移可能越界（窄了则原先的上限变小），按新宽度再夹一次
  self.state.h_offset = grid_clamp_h_offset(
    self.state,
    self.size.width,
    self.state.h_offset,
  )
  self.widget.repaint()
}

///|
/// 某一列**这一帧**的实际宽（调过的算调过的，没调过的算声明宽）。
///
/// 自适应模式下这是压缩后的实时值（没有缓存时退回声明宽），与用户看到的一致
/// ——`set_column_width` 在那里不生效，所以这里读到的也仍是自适应算出来的宽。
pub fn[B] DataGrid::column_width(self : DataGrid[B], col : Int32) -> Double {
  let widths = grid_layout_widths(self.state, self.size.width)
  if col < 0 || col >= widths.length() {
    0.0
  } else {
    widths[col]
  }
}

///|
/// 把所有手动调过的列宽清掉，回到调用方声明的宽并重画。
pub fn[B : @moonui.Backend] DataGrid::reset_column_widths(
  self : DataGrid[B],
) -> Unit raise @moonui.UiError {
  if self.state.col_widths.length() == 0 {
    return
  }
  self.state.col_widths = []
  self.state.h_offset = grid_clamp_h_offset(
    self.state,
    self.size.width,
    self.state.h_offset,
  )
  self.widget.repaint()
}

///|
/// 把某一列滚进视野（已经在里面就不动）并重画。越界按 `scroll_to_row` 的规则夹住
/// （负数夹到第一列、超过夹到最后一列）。
pub fn[B : @moonui.Backend] DataGrid::scroll_to_column(
  self : DataGrid[B],
  col : Int32,
) -> Unit raise @moonui.UiError {
  let surface = self.size.width
  let widths = grid_layout_widths(self.state, surface)
  if widths.length() == 0 {
    return
  }
  let c = if col < 0 {
    0
  } else if col >= widths.length() {
    widths.length() - 1
  } else {
    col
  }
  // 目标列的内容起点与终点
  let mut start = 0.0
  let mut i = 0
  while i < c {
    start = start + widths[i]
    i = i + 1
  }
  let end = start + widths[c]
  let hoff = grid_effective_h_offset(self.state, surface)
  // 左边被切了就贴左、右边被切了就贴右；两头都在视野里就不动
  let target = if start < hoff {
    start
  } else if end > hoff + surface {
    end - surface
  } else {
    hoff
  }
  self.state.h_offset = grid_clamp_h_offset(self.state, surface, target)
  self.widget.repaint()
}

///|
/// 当前排序列号，`-1` = 没排。
pub fn[B] DataGrid::sort_column(self : DataGrid[B]) -> Int32 {
  self.state.sort_col
}

///|
/// 排序方向：`true` = 升序，`false` = 降序。没排序时是 `true`（默认）。
pub fn[B] DataGrid::sort_ascending(self : DataGrid[B]) -> Bool {
  self.state.sort_asc
}

///|
/// 按某一列排序并重画。再点同一列就**翻方向**（升 ↔ 降）——表头点击的常见行为。
///
/// 列号越界 raise：这是调用方算错了索引，静默吞掉会让"我点了表头但没排序"变成
/// 只有用户能发现的 bug。
///
/// 排序**不改动数据**：`rows` 里的行号在排序前后都稳定，另存一份显示顺序
/// （`sort_order`）来映射——`set_cell(row, col)` 按数据行号写格子，排序时它写的
/// 仍然是同一条数据的那一格。
///
/// 相同键的行保持原有的先后（排序是稳定的）：同价的两行换位置是用户看得见的
/// 抖动。
pub fn[B : @moonui.Backend] DataGrid::sort_by_column(
  self : DataGrid[B],
  col : Int32,
) -> Unit raise @moonui.UiError {
  if col < 0 || col >= self.state.columns.length() {
    raise @moonui.OperationFailed("表格排序列号越界：\{col}")
  }
  grid_sort_by_column(self.state, col)
  self.widget.repaint()
}

///|
/// 按列排序的**包内**实现（`T110`）：改状态、算显示顺序，不重画。
///
/// 为什么抽出来：公开的 `sort_by_column` 与表头点击的默认接线要**同一条**口径
/// （同列再点翻方向、换列回升序），两处各写一遍的话，改了一处忘了另一处，
/// "点表头"与"调 API"会给出两种结果——而用户分不出这两个入口。
fn grid_sort_by_column(state : GridState, col : Int32) -> Unit {
  if col < 0 || col >= state.columns.length() {
    return
  }
  if state.sort_col == col {
    // 同一列再点一次：翻方向
    state.sort_asc = !state.sort_asc
  } else {
    state.sort_col = col
    state.sort_asc = true
  }
  // `T102` 第十四刀：交给调用方排。回调里它多半会同步 `set_rows` 换数据，
  // 所以**回调之后再收尾**（先清脏标记按最新数据重置显示顺序），否则回调
  // 换进来的行会被下一次 `grid_view_order` 当成"还没排过"再走一遍内置比较。
  // 箭头照旧按这次请求画：`sort_col` / `sort_asc` 就是这次要的方向。
  match state.sort_hook {
    Some(f) => {
      f(col, state.sort_asc)
      state.sort_dirty = false
      grid_rebuild_sort(state)
      return
    }
    None => ()
  }
  state.sort_dirty = true
  grid_rebuild_sort(state)
}

///|
/// 一行的剪贴板形态：各列按**数据列序**用制表符连起来，`\n` 结尾（一行一条，
/// 粘贴方按行切）。没有这一行时 `None`。
///
/// 为什么是 TSV 而不是逗号：格子是自由文本，逗号太常见；而且 Excel / Numbers /
/// 飞书表格的"复制一行"落在剪贴板上的就是 TSV，粘过去能直接分列。
///
/// 诚实边界：**格子里本身带制表符或换行时这一行会被切错**——这里不做转义
/// （转义会在粘贴方那里留下一串没人认的引号），带这类内容的列不该拿它去复制。
fn grid_row_text(state : GridState, row : Int32) -> String? {
  if row < 0 || row >= state.rows.length() {
    return None
  }
  let cells = state.rows[row]
  Some(cells.join("\t") + "\n")
}

///|
/// 复制选中行到剪贴板，返回有没有东西被复制（没选中行就是 `false`）。
///
/// 抽成内部函数而不是只做公开方法：键盘那支（第十五刀的默认接线）也要走同一条，
/// 两处各写一遍就会有一个入口忘了处理"没选中"。
fn[B : @moonui.Backend] grid_copy_selected(
  state : GridState,
  backend : B,
) -> Bool raise @moonui.UiError {
  match grid_row_text(state, state.selected) {
    Some(text) => {
      @moonui.Backend::set_clipboard_text(backend, text)
      true
    }
    None => false
  }
}

///|
/// 把剪贴板文本交给粘贴回调，返回回调有没有收到东西。
///
/// 四条"不做事"的边界都在这里：没有回调（表不知道这份文本该往哪写）、剪贴板
/// 是空的（`None` 读不到东西，`Some("")` 读到了也没内容——两种都算空）、
/// **没有选中行**（粘贴要有个去处；报一个 `-1` 行号给调用方只是把这个判断推给
/// 别人，而别人也没有更多信息）。
fn[B : @moonui.Backend] grid_paste_from_clipboard(
  state : GridState,
  backend : B,
) -> Bool raise @moonui.UiError {
  if state.selected < 0 {
    return false
  }
  let hook = match state.paste_hook {
    Some(f) => f
    None => return false
  }
  match @moonui.Backend::clipboard_text(backend) {
    Some(text) =>
      if text == "" {
        false
      } else {
        hook(state.selected, text)
        true
      }
    None => false
  }
}

///|
/// 弹右键菜单（`T102` 第十七刀）。
///
/// 每次右键现造一份：两个条目都要按**此刻**的状态启停——「复制」要有选中行，
/// 「粘贴」还要有 `on_paste`（没去处就不该点亮，点了什么都不发生比置灰更糟）。
/// 回调直接走第十五刀的两个内部函数，所以右键、键盘、公开方法三个入口的语义
/// 逐字一致（复制取的是选中那条**数据**，粘贴只报请求）。
///
/// 选中行 / 剪贴板的读取都在调用方那一颗事件里做完了，这里只负责造菜单与弹出。
fn[B : @moonui.Backend] grid_show_context_menu(
  state : GridState,
  backend : B,
) -> Unit raise @moonui.UiError {
  let has_row = state.selected >= 0
  let copy = @moonui.MenuItem::new("复制")
  copy.set_enabled(has_row)
  let _ = copy.on(fn(_) raise @moonui.UiError {
    let _ = grid_copy_selected(state, backend)
  })
  let paste = @moonui.MenuItem::new("粘贴")
  paste.set_enabled(has_row && state.paste_hook is Some(_))
  let _ = paste.on(fn(_) raise @moonui.UiError {
    let _ = grid_paste_from_clipboard(state, backend)
  })
  let menu = @moonui.Menu::new("表格", [
    @moonui.MenuNode::Item(copy),
    @moonui.MenuNode::Separator,
    @moonui.MenuNode::Item(paste),
  ])
  @moonui.Backend::show_context_menu(backend, menu)
}

///|
/// 复制选中行到剪贴板（`⌘C` / `Ctrl+C` 的默认接线也走这条），返回有没有东西
/// 被复制。内容形态见 `grid_row_text`（TSV，一行一条）。
pub fn[B : @moonui.Backend] DataGrid::copy_selected(
  self : DataGrid[B],
) -> Bool raise @moonui.UiError {
  grid_copy_selected(self.state, self.backend)
}

///|
/// 读剪贴板把文本交给 `on_paste`（`⌘V` / `Ctrl+V` 的默认接线也走这条），返回
/// 回调有没有收到东西。没有 `on_paste`、剪贴板为空、没有选中行时都不做事。
pub fn[B : @moonui.Backend] DataGrid::paste_from_clipboard(
  self : DataGrid[B],
) -> Bool raise @moonui.UiError {
  grid_paste_from_clipboard(self.state, self.backend)
}

///|
/// 取消排序，回到原始行序并重画。
///
/// 有排序回调时这条只清箭头（`sort_column()` 回 -1），**不会**回调——数据
/// 顺序归调用方，要不要回到"原始顺序"由它自己决定（表不知道原始顺序是什么）。
pub fn[B : @moonui.Backend] DataGrid::clear_sort(
  self : DataGrid[B],
) -> Unit raise @moonui.UiError {
  self.state.sort_col = -1
  self.state.sort_asc = true
  self.state.sort_dirty = true
  grid_rebuild_sort(self.state)
  self.widget.repaint()
}

///|
/// 整份换数据并重画。
///
/// 顺手做两件收尾：选中行超出新表长就清掉（否则会高亮一行不存在的行），偏移
/// 按新行数收回（否则删完行会停在空屏上）。
pub fn[B : @moonui.Backend] DataGrid::set_rows(
  self : DataGrid[B],
  rows : Array[Array[String]],
) -> Unit raise @moonui.UiError {
  self.state.rows = rows
  // 数据变了：自然宽过期（"最宽的那一格"可能换人了）
  self.state.widths_dirty = true
  // 数据换了：排序键也过期（同一列的内容全变了）
  self.state.sort_dirty = true
  grid_rebuild_sort(self.state)
  if self.state.selected >= rows.length() {
    self.state.selected = -1
  }
  let body = grid_body_height(self.state, self.size.height)
  self.state.offset = grid_effective_offset(self.state, body)
  self.widget.repaint()
}

///|
/// 改一格并重画。行号/列号越界 raise：这是调用方算错了索引，静默吞掉会让
/// "我改了但屏幕没变"变成只有用户能发现的 bug。
pub fn[B : @moonui.Backend] DataGrid::set_cell(
  self : DataGrid[B],
  row : Int32,
  col : Int32,
  text : String,
) -> Unit raise @moonui.UiError {
  if row < 0 || row >= self.state.rows.length() {
    raise @moonui.OperationFailed("表格行号越界：\{row}")
  }
  if col < 0 || col >= self.state.columns.length() {
    raise @moonui.OperationFailed("表格列号越界：\{col}")
  }
  self.state.rows[row][col] = text
  // 一格变了：这列的自然宽可能变了（也可能没变，重量一次最省事）
  self.state.widths_dirty = true
  // 改的正是排序列：排序键变了，显示顺序要重排
  if col == self.state.sort_col {
    self.state.sort_dirty = true
    grid_rebuild_sort(self.state)
  }
  self.widget.repaint()
}

///|
/// 把第 `from` 行挪到索引 `to` 并重画（`T102` 第九刀；拖拽抬起时走的就是它）。
///
/// 口径是**数据行号**，且这一刀**真改数据顺序**——与排序（只改显示顺序、
/// `rows` 不动）不同：挪完之后行号按新顺序重编，外部留着的旧行号会指向另一条
/// 数据。要"只改显示顺序"请用 `sort_by_column`。越界 raise（与 `set_cell` 同一
/// 条理由：静默吞掉会让"我挪了但屏幕没变"只有用户能发现）。
pub fn[B : @moonui.Backend] DataGrid::move_row(
  self : DataGrid[B],
  from : Int32,
  to : Int32,
) -> Unit raise @moonui.UiError {
  let n = self.state.rows.length()
  if from < 0 || from >= n {
    raise @moonui.OperationFailed("表格行号越界：\{from}")
  }
  if to < 0 || to >= n {
    raise @moonui.OperationFailed("表格目标行号越界：\{to}")
  }
  grid_move_row(self.state, from, to)
  self.widget.repaint()
}

///|
/// 推一个滚动偏移并重画（负值归零、越过尾部夹到最后一行贴底）。
pub fn[B : @moonui.Backend] DataGrid::set_offset(
  self : DataGrid[B],
  offset : Double,
) -> Unit raise @moonui.UiError {
  let body = grid_body_height(self.state, self.size.height)
  self.state.offset = grid_clamp_offset(self.state, body, offset)
  self.widget.repaint()
}

///|
/// 滚到第 `row` 行（对齐正文顶边）并重画。越界按 `set_offset` 的规则夹住。
///
/// `row` 是**数据行号**（与 `cell` / `select_row` 同一口径）：排序之后同一行数据
/// 可能排在显示顺序的第几处，滚过去要滚到它**当前所在的位置**，不是滚到"第 row
/// 个显示位置"——后者会让调用方以为滚到了某条数据，其实滚去了另一条。
pub fn[B : @moonui.Backend] DataGrid::scroll_to_row(
  self : DataGrid[B],
  row : Int32,
) -> Unit raise @moonui.UiError {
  let r = if row < 0 { 0 } else { row }
  // 数据行号 → 显示位置 → 偏移
  let view_pos = grid_view_pos_of(self.state, r)
  DataGrid::set_offset(self, view_pos.to_double() * self.state.row_height)
}

///|
/// 选中一行并重画；越界或负数表示**清掉选中**（`-1`）。
pub fn[B : @moonui.Backend] DataGrid::select_row(
  self : DataGrid[B],
  row : Int32,
) -> Unit raise @moonui.UiError {
  if row < 0 || row >= self.state.rows.length() {
    self.state.selected = -1
  } else {
    self.state.selected = row
  }
  self.widget.repaint()
}
