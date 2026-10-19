///|
/// 一只窗的默认落座：左上角（逻辑坐标）+ 尺寸 + 最小尺寸。
///
/// 建窗与「复位窗口」共用同一份数据——否则两处各写一遍坐标，早晚漂移，
/// 用户点复位回到的是一套"当年写死、后来没人对着改"的位置。
///
/// `min_w` / `min_h` 是**内容撑不住**的下限（不是审美偏好）：再小就会被挤成
/// 一团——十段推子挤到一起、工具条最后一颗钮被挤出窗右缘、歌词两行叠在一起。
/// 下限交给原生层（mac `contentMinSize`、Win32 `WM_GETMINMAXINFO`），所以用户
/// 拖着边框缩到那儿就顶住了，不会先缩坏再弹回来。
pub(all) struct CmPlacement {
  x : Double
  y : Double
  w : Double
  h : Double
  min_w : Double
  min_h : Double
}

///|
/// 六只窗的默认布局。整体由屏幕尺寸推出（真正用到屏幕的只有桌面歌词，
/// 它要贴在 Dock 上方居中），所以复位到的是"当前这块屏的默认位置"，
/// 而不是程序第一次启动那天的坐标。
pub(all) struct CmLayout {
  main : CmPlacement
  lyrics : CmPlacement
  eq : CmPlacement
  playlist : CmPlacement
  mini : CmPlacement
  desk : CmPlacement
}

///|
/// 主控窗左上角的默认位置。140/140 给菜单栏与系统边距让位——原版主控窗
/// 也是偏左上角起手，不是屏幕正中。
pub fn cm_layout_origin_x() -> Double {
  140.0
}

///|
/// 见 `cm_layout_origin_x`。
pub fn cm_layout_origin_y() -> Double {
  140.0
}

///|
/// 相邻窗之间的缝（顶条贴着顶条，看着像一套窗而不是一坨）。
pub fn cm_layout_gap() -> Double {
  6.0
}

///|
/// 播放列表默认高（比主控长，装得下几行；横跨两列之后是整块的下半部）。
pub fn cm_playlist_h() -> Double {
  320.0
}

///|
/// 迷你条默认尺寸（只有一条走带那么高）。
pub fn cm_mini_w() -> Double {
  300.0
}

///|
/// 见 `cm_mini_w`。
pub fn cm_mini_h() -> Double {
  48.0
}

///|
/// 桌面歌词默认宽（浮在 Dock 上方的一条）。
pub fn cm_desk_w() -> Double {
  520.0
}

///|
/// 见 `cm_desk_w`。
pub fn cm_desk_h() -> Double {
  80.0
}

///|
/// 桌面歌词底边距屏幕底的距离。80 的窗高 + 40 的余量：不压 Dock，
/// 也不至于飘到屏幕中间。
pub fn cm_desk_bottom_inset() -> Double {
  120.0
}

///|
/// 默认布局四周留的边（纵向压缩时的兜底、横向判断"还放得下吗"的口径）。
pub fn cm_layout_margin() -> Double {
  24.0
}

///|
/// 默认布局：
///
/// ```
///  ┌──────────┬────────────┐
///  │   主控    │   歌词秀   │
///  ├──────────┴────────────┤
///  │       播放列表         │
///  └───────────────────────┘
/// ```
///
/// 上排两列并排：主控在左、歌词秀在右，顶边对齐、同高；播放列表横跨两列压在
/// 下面，右缘与歌词秀齐平（三只窗拼成一个端正的矩形，像一套而不是一堆）。
/// 均衡器默认收起（`show_eq` 起手 false），但仍留一格落点——用户在走带条上
/// 按 EQ 把它拉开时有地方待。迷你条压在主控的位置（切过去就原地变窄）；
/// 桌面歌词贴屏幕底部居中。
///
/// 为什么上排是"主控 | 歌词秀"而不是过去的"主控 / 歌词秀 竖着堆"：歌词是
/// 横着读的一行字，给它一条横向的宽窗比给它一条又窄又短的横条更合适；播放
/// 列表横跨两列之后也够宽，工具条那五颗定宽钮 + 搜索框排得开。
pub fn cm_default_layout(screen : @moonui.LogicalSize) -> CmLayout {
  let mx = cm_layout_origin_x()
  let my0 = cm_layout_origin_y()
  let gap = cm_layout_gap()
  let margin = cm_layout_margin()
  let main_w = cm_main_w()
  let main_h = cm_main_h()
  let lyrics_w = cm_lyrics_w()
  let pl_h = cm_playlist_h()
  // 上排两列的整宽（播放列表横跨这两列）：主控 + 缝 + 歌词秀。三者拼成一个
  // "上二下一"的矩形——播放列表右缘与歌词秀右缘齐平，缝宽统一。
  let block_w = main_w + gap + lyrics_w
  let block_h = main_h + gap + pl_h
  // 纵向起点：默认 140；屏幕矮到"整块 + 底部那条桌面歌词"都放不下时上提，
  // 最紧贴到 margin（桌面歌词始终给 120 的底边距，它也是要被让开的窗之一）。
  let my = if my0 + block_h + cm_desk_bottom_inset() <= screen.height {
    my0
  } else {
    let fit = screen.height - cm_desk_bottom_inset() - block_h
    if fit > margin {
      fit
    } else {
      margin
    }
  }
  // 均衡器默认收起，落点固定在整块右侧、与上排顶边对齐——它在截图里就是"主窗口
  // 右边那只额外的面板"。屏幕窄到放不下时它有一角会探出右缘：宁可不压住别的窗，
  // 也不占别人已经排好的位置（默认收起，用户拉开后自己拖一下就能全露出来）。
  let eq_x = mx + block_w + gap
  let eq_y = my
  let desk_w = cm_desk_w()
  let desk_h = cm_desk_h()
  // 屏幕比窗还窄时退到左缘；读不到屏幕尺寸的调用方会给 1440×900 兜底。
  let dx = if screen.width > desk_w {
    (screen.width - desk_w) / 2.0
  } else {
    0.0
  }
  let dy = if screen.height > cm_desk_bottom_inset() {
    screen.height - cm_desk_bottom_inset()
  } else {
    0.0
  }
  {
    // 主控锁了不可缩放（皮肤图定尺），下限只为语义完整。**高度下限是顶条高**、
    // 不是整窗高：双击顶条卷起就是把窗压到只剩顶条，下限卡在整窗高的话卷起
    // 会被顶回去（窗口"卷不动"）。
    main: {
      x: mx,
      y: my,
      w: main_w,
      h: main_h,
      min_w: main_w,
      min_h: cm_title_h(),
    },
    // 歌词秀：上排右侧，顶边与主控齐平、同高（并排读起来是"一条横向的字幕带"）。
    // 三行字（17pt 当前句 + 12pt 上下句）加顶条至少 100；宽 320 时长句开始裁字，
    // 再窄连「（暂无歌词）」都会顶到边。
    lyrics: {
      x: mx + main_w + gap,
      y: my,
      w: lyrics_w,
      h: main_h,
      min_w: 320.0,
      min_h: 100.0,
    },
    // 均衡器：横向是硬账——十段 × 34 = 340，加滑槽内衬 6+6、外圈 1+1、面板
    // 内边距 10+10，正好 374；再窄十段就挤在一起、推子互相压。纵向留到 200
    // 还能拖（读数 11 + 推子 ~120 + 频率 11 + 顶条）。
    eq: {
      x: eq_x,
      y: eq_y,
      w: main_w,
      h: cm_eq_h(),
      min_w: 374.0,
      min_h: 200.0,
    },
    // 播放列表：横跨上排两列的整宽，压在主控/歌词秀下面。工具条五颗钮 +
    // 搜索框是定宽（78/84/70/70/46/110）加 6 道 4pt 缝 = 482，加面板左右 16
    // 正好 498——这就是 500 下限的来历，再窄最后一颗钮会被挤出右缘，搜索框
    // 等于没有。纵向按"页签 + 工具条 + 列头 + 三行 + 属性栏"。
    playlist: {
      x: mx,
      y: my + main_h + gap,
      w: block_w,
      h: pl_h,
      min_w: 500.0,
      min_h: 240.0,
    },
    // 迷你条锁死（只有一条走带那么高）。
    mini: {
      x: mx,
      y: my,
      w: cm_mini_w(),
      h: cm_mini_h(),
      min_w: cm_mini_w(),
      min_h: cm_mini_h(),
    },
    // 桌面歌词：两行字各自是定宽 488 的居中格（+ 左右 16 内边距 = 520），
    // 比这更窄会从右边裁字、居中也会偏——所以宽度只能放大不能缩小。
    desk: { x: dx, y: dy, w: desk_w, h: desk_h, min_w: desk_w, min_h: desk_h, },
  }
}

///|
/// 把一只窗按 `CmPlacement` 摆好：**先下限、再尺寸、最后位置**。
///
/// 顺序有讲究：
/// - 下限必须先于尺寸下发——否则先按默认尺寸摆、再收紧下限时，窗口如果比下限
///   还小会被抬一次，白摆一趟；
/// - 尺寸先于位置：部分平台改尺寸会把窗口按"新尺寸重新居中"，先定尺寸再落点
///   才不会白算一次坐标。
///
/// 失败一律吞掉：窗口可能已经不可缩放（主控/迷你条），尺寸那步抛错不该连带
/// 位置也不摆。
pub fn[B : @moonui.Backend] cm_apply_placement(
  w : @moonui.Window[B],
  p : CmPlacement,
) -> Unit {
  let _ = w.set_min_size(Some(@moonui.LogicalSize(p.min_w, p.min_h))) catch {
    _ => ()
  }
  let _ = w.set_size(@moonui.LogicalSize(p.w, p.h)) catch { _ => () }
  let _ = w.set_position(@moonui.LogicalPoint(p.x, p.y)) catch { _ => () }
}

///|
/// 复位的**动画版**：下限与尺寸照旧当场落（内容当场跟上），位置带 300ms 滑动
/// ——用户点「复位」是"把窗送回原位"，六只窗瞬间跳回去看着像闪了一下，滑
/// 过去才看得出"它们各自回到了自己的位置"。落点由动画泵兑现（没接帧钟的
/// 测试环境那一圈直接落，等于瞬移——既有断言一个字不用改语义）。
pub fn[B : @moonui.Backend] cm_animate_placement(
  w : @moonui.Window[B],
  p : CmPlacement,
) -> Unit {
  let _ = w.set_min_size(Some(@moonui.LogicalSize(p.min_w, p.min_h))) catch {
    _ => ()
  }
  let _ = w.set_size(@moonui.LogicalSize(p.w, p.h)) catch { _ => () }
  let _ = w.set_position_animated(@moonui.LogicalPoint(p.x, p.y)) catch {
    _ => ()
  }
}

///|
/// 新建窗的落座：**先切沉浸式标题栏，再摆位置**。
///
/// 反过来的话窗口会整体下移一个标题栏（mac 上 28pt）：设位置那一刻窗口还带着
/// 标准标题栏（frame 比内容高 28），随后切沉浸式高度缩回来、但 Cocoa 的
/// origin（左下角）不动——顶边跟着下降 28。六窗一起低，看起来就是"默认位置
/// 比设计值偏下"，而且和「复位窗口」落点对不上（复位时窗早已是沉浸式）。
pub fn[B : @moonui.Backend] cm_adopt_window(
  w : @moonui.Window[B],
  p : CmPlacement,
) -> Unit {
  let _ = w.set_titlebar_style(@moonui.TitlebarStyle::Immersive) catch {
    _ => ()
  }
  cm_apply_placement(w, p)
}
