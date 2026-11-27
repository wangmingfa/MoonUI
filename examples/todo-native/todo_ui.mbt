///|
/// OpenTodo 复刻件的摆位层（`T409`）。
///
/// 这一层把 `todo.mbt` 的数据与 `painter.mbt` 的绘制拼成控件树：侧栏、顶栏、
/// 主卡（头部 / 快速添加 / 分组 / 任务行 / 提醒条）。像素口径全部来自
/// `DESIGN.md` §48 的量测（2026-11-26 在 demo.open-todo.app 的 1000×700 视口）。
///
/// 框架能力缺的三处都在这里补：
/// - `Style` 没有 border 字段 → 圆角描边画在 `Stack` 顶层的一块 `Custom` 上
///   （`with_expand(true)` 让它在 `layout_stack` 里铺满整个叠放区，`env.size`
///   就是真实显示尺寸）；
/// - 文字没有字重 650 档 → 600/650 一律取 `Bold`；
/// - 列表行悬停才出现的操作簇 → `Widget::on_bubble` 收 `MouseEnter/Leave`，
///   翻转 `set_visible`（框架没有 opacity 过渡）。
///
/// 所有构造器都 `raise @moonui.UiError`：控件不吞异常（§33），调用侧自己决定
/// 怎么接。纯数据 / 绘制（`painter`）不 raise，只有碰原生层的地方 raise。

///|
/// 颜色快捷口（`rgb` 的别名，少打一层限定符）。
fn cx(v : Int32) -> @moonui.Color {
  rgb(v)
}

///|
/// 把字符串截到不超过 `maxw` 宽（按 `env` 量宽），尾部补 "…"。
/// 项目名是纯 ASCII（"Home renovation" 等），按字节截断安全。
/// 取前缀走 `clamped_view`（`String::substring` 已废弃）；`end` 超过字节数时
/// 它自己收口，末字符正好落在边界上也不会错。
fn truncate_to(
  s : String,
  maxw : Double,
  size : Double,
  env : @moonui.PaintEnv,
) -> String {
  let (w, _) = env.measure_text(s, size, false)
  if w <= maxw {
    return s
  }
  let mut lo = 0
  let mut hi = s.length()
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    let t = s[0:mid].to_owned() + "…"
    let (tw, _) = env.measure_text(t, size, false)
    if tw <= maxw {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  s[0:lo].to_owned() + "…"
}

///|
/// 带 1px 描边的圆角盒子。
///
/// 做法：`Panel`（底色 + 圆角）垫底，`Stack` 顶层叠一块 `Custom` 只画描边。
/// `Custom` 叶子开 `expand`，`layout_stack` 按 `is_flex_stack_child` 把它量成
/// 整个叠放区，于是 `env.size` 与盒子的实际尺寸同值，描边正好落在一周。
fn[B : @moonui.Backend] box1(
  b : B,
  w : Double,
  h : Double,
  fill : Int32,
  radius : Double,
  edge : Int32,
  child : @moonui.Widget[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  let p = @moonui.Widget::panel(b, child)
  let _ = p.set_style(
    Some(@moonui.style(background=Some(cx(fill)), radius=Some(radius))),
  )
  // 叠放面里非弹性子项按"测量尺寸"摆——`panel` 不参与弹性分配（非 layout-only），
  // 直接放进去只会拿内容高度（卡片那次是 229 而不是 647，列表区整个是黑的）。
  // 把 panel 包进 `sized(w,h)` 让它拿到整块 w×h 帧，内容（含弹性 scroll）再自己分。
  let body = @moonui.Widget::sized(b, Some(w), Some(h), p)
  let ov = @moonui.Widget::custom(b, @moonui.LogicalSize(w, h), fn(dl, env) {
    outline(dl, env, radius, edge)
  })
  let _ = ov.with_expand(true)
  // 叠放面本身不带尺寸账——不包 `sized` 的话，它在 Column 那种"主轴无界"的
  // 约束下会被 overlay 的 `with_expand` 撑成无限高（开帧 2GB 位图直接失败）。
  // 包一层把整块叠放区钉死在 w×h。
  @moonui.Widget::sized(
    b,
    Some(w),
    Some(h),
    @moonui.Widget::stack(b, [body, ov]),
  )
}

///|
/// 无边框的圆角色块（分组头 / 卡片 / 侧栏分组行）。
fn[B : @moonui.Backend] slab(
  b : B,
  w : Double,
  h : Double,
  fill : Int32,
  radius : Double,
  child : @moonui.Widget[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  let p = @moonui.Widget::panel(b, child)
  let _ = p.set_style(
    Some(@moonui.style(background=Some(cx(fill)), radius=Some(radius))),
  )
  @moonui.Widget::sized(b, Some(w), Some(h), p)
}

///|
/// 固定宽高的一块自绘面。
fn[B : @moonui.Backend] face(
  b : B,
  w : Double,
  h : Double,
  paint : (@moonui.DrawList, @moonui.PaintEnv) -> Unit,
) -> @moonui.Widget[B] raise @moonui.UiError {
  @moonui.Widget::custom(b, @moonui.LogicalSize(w, h), paint)
}

///|
/// 一块弹性空白。
fn[B : @moonui.Backend] gap(b : B) -> @moonui.Widget[B] raise @moonui.UiError {
  @moonui.Widget::spacer(b).with_expand(true)
}

///|
/// 一块固定宽高的空白（占位用的行内间隔）。
fn[B : @moonui.Backend] blank(
  b : B,
  w : Double,
  h : Double,
) -> @moonui.Widget[B] raise @moonui.UiError {
  face(b, w, h, fn(_dl, _env) {  })
}

///|
/// 一枚图标面：`box` 见方面，图标画在左上 `(ox, oy)`，边长 `sz`。
fn[B : @moonui.Backend] ico(
  b : B,
  name : String,
  box : Double,
  ox : Double,
  oy : Double,
  sz : Double,
  c : Int32,
) -> @moonui.Widget[B] raise @moonui.UiError {
  face(b, box, box, fn(dl, _env) { glyph(dl, name, ox, oy, sz, c) })
}

///|
/// 一枚可点的图标面（幽灵图标钮，32×32 里画 16px 图标）。
fn[B : @moonui.Backend] ico_click(
  b : B,
  name : String,
  box : Double,
  ox : Double,
  oy : Double,
  sz : Double,
  c : Int32,
  f : () -> Unit raise @moonui.UiError,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let w = ico(b, name, box, ox, oy, sz, c)
  let _ = w.on_click(fn() raise @moonui.UiError { f() })
  w
}

///|
/// 圆角 + 底色的行块（侧栏条目 / 任务行 / 分组头），可带悬停底色。
fn[B : @moonui.Backend] padrow(
  b : B,
  w : Double,
  h : Double,
  fill : Int32,
  radius : Double,
  child : @moonui.Widget[B],
  hover~ : Int32? = None,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let p = @moonui.Widget::panel(b, child)
  let _ = p.set_style(
    Some(@moonui.style(background=Some(cx(fill)), radius=Some(radius))),
  )
  match hover {
    Some(hv) => p.set_hover_style(Some(@moonui.style(background=Some(cx(hv)))))
    None => ()
  }
  @moonui.Widget::sized(b, Some(w), Some(h), p)
}

///|
/// 带 1px 描边的圆角行块（快速添加条 / 主卡）。
fn[B : @moonui.Backend] boxrow(
  b : B,
  w : Double,
  h : Double,
  fill : Int32,
  radius : Double,
  edge : Int32,
  child : @moonui.Widget[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  box1(b, w, h, fill, radius, edge, child)
}

///|
/// 一枚扁平按钮：底 + 圆角 + 内缩文案（可带图标与快捷键徽标）。
fn[B : @moonui.Backend] fbtn(
  b : B,
  w : Double,
  h : Double,
  fill : Int32,
  fg : Int32,
  radius : Double,
  edge : Int32?,
  icon : String?,
  label : String,
  kbd : String?,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let kids : Array[@moonui.Widget[B]] = []
  match icon {
    Some(n) => kids.push(ico(b, n, 16.0, 0.0, 0.0, 16.0, fg))
    None => ()
  }
  kids.push(
    @moonui.Widget::label(b, label)
    .foreground(cx(fg))
    .font_size(13.0)
    .font_weight(@moonui.FontWeight::Medium),
  )
  match kbd {
    Some(k) => {
      let kb = @moonui.Widget::label(b, k)
        .foreground(cx(fg))
        .font_size(11.5)
        .font_weight(@moonui.FontWeight::Bold)
      kids.push(
        @moonui.Widget::panel(
          b,
          @moonui.Widget::padding(b, @moonui.EdgeInsets::all(3.0), kb),
        ).with_style(
          Some(
            @moonui.style(
              background=Some(cx(mix(fg, 32, fill))),
              radius=Some(4.0),
            ),
          ),
        ),
      )
    }
    None => ()
  }
  let r = @moonui.Widget::row(b, 6.0, kids).cross_align(
    @moonui.CrossAlign::Center,
  )
  let body = @moonui.Widget::row(b, 0.0, [gap(b), r, gap(b)]).cross_align(
    @moonui.CrossAlign::Center,
  )
  let inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(0.0, 10.0),
    body,
  )
  match edge {
    Some(e) => boxrow(b, w, h, fill, radius, e, inner)
    None => slab(b, w, h, fill, radius, inner)
  }
}

///|
/// 一枚小链接（分组头右侧的"全部移至今天 / 重新安排…"）。
fn[B : @moonui.Backend] ghostlink(
  b : B,
  s : String,
  c : Int32,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let l = @moonui.Widget::label(b, s)
    .foreground(cx(c))
    .font_size(12.5)
    .font_weight(@moonui.FontWeight::Medium)
  let p = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(4.0, 10.0),
    @moonui.Widget::row(b, 0.0, [l]).cross_align(@moonui.CrossAlign::Center),
  )
  let _ = p.set_style(Some(@moonui.style(radius=Some(7.0))))
  let _ = p.set_hover_style(Some(@moonui.style(background=Some(cx(0xF1F3F5)))))
  p
}

///|
/// 顶栏（37px 消息条 + 底部 1px 细线）。
pub fn[B : @moonui.Backend] banner(
  b : B,
  p : Palette,
  w : Double,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let msg = @moonui.Widget::label(
      b, "演示：私人沙盒，闲置 2 小时后自动删除。请勿存储任何个人隐私内容。",
    )
    .foreground(cx(p.info_text))
    .font_size(13.0)
  // 右端：了解更多（主色）+ 帮助 + 关闭
  let more = @moonui.Widget::label(b, "了解更多")
    .foreground(cx(p.accent))
    .font_size(13.0)
    .font_weight(@moonui.FontWeight::Medium)
  let help = ico(b, "help", 16.0, 0.0, 0.0, 16.0, p.muted)
  let close = ico(b, "close", 16.0, 0.0, 0.0, 16.0, p.muted)
  let r = @moonui.Widget::row(b, 8.0, [msg, gap(b), more, help, close]).cross_align(
    @moonui.CrossAlign::Center,
  )
  let body = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(0.0, 16.0),
    r,
  )
  let top = @moonui.Widget::panel(b, body)
  let _ = top.set_style(Some(@moonui.style(background=Some(cx(p.info_soft)))))
  // —— 顶栏 36px 蓝底（网页 2x 实测 PNG y0..71 是浅蓝，y72..73 是深蓝底边线，
  // 那条线改由 `build_root` 里的 gutter 面统一画，见 T411：原先这里单独挂一块
  // 1px 面，实测整块落低 2 个物理行）。
  @moonui.Widget::sized(b, Some(w), Some(36.0), top)
}

///|
/// 侧栏：空间切换 + 任务/笔记分段 + 添加任务 + 目的地与分组 + 底部账号。
pub fn[B : @moonui.Backend] sidebar(
  b : B,
  p : Palette,
  h : Double,
  dests : Array[Dest],
  groups : Array[SideGroup],
  on_pick : (String) -> Unit raise @moonui.UiError,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let w = 256.0
  let rw = 232.0 // 行宽（左右各留 12px）
  let kids : Array[@moonui.Widget[B]] = []
  // —— 空间切换行（"个" 首字徽章 + "个人" + 搜索）
  kids.push(
    @moonui.Widget::row(b, 8.0, [
      face(b, 20.0, 20.0, fn(dl, env) {
        dl.fill_rect(0.5, 0.5, 19.0, 19.0, radius=5.0, rgb=p.surface)
        outline(dl, env, 5.0, p.border)
        let (tw, _th) = env.measure_text("个", 13.0, false)
        dl.text("个", (20.0 - tw) / 2.0, 3.0, size=13.0, rgb=p.strong)
      }),
      @moonui.Widget::label(b, "个人")
      .foreground(cx(p.strong))
      .font_size(13.0)
      .font_weight(@moonui.FontWeight::Medium),
      ico(b, "chevron_down", 16.0, 0.0, 0.0, 16.0, p.faint),
      ico(b, "search", 16.0, 0.0, 0.0, 16.0, p.muted),
    ]).cross_align(@moonui.CrossAlign::Center),
  )
  kids.push(blank(b, rw, 1.0))
  // —— 任务 / 笔记 分段控件
  let seg = fn(
    name : String,
    on : Bool,
  ) -> @moonui.Widget[B] raise @moonui.UiError {
    let l = @moonui.Widget::label(b, name)
      .foreground(cx(if on { p.strong } else { p.muted }))
      .font_size(12.5)
      .font_weight(@moonui.FontWeight::Medium)
    let r = @moonui.Widget::row(b, 0.0, [gap(b), l, gap(b)]).cross_align(
      @moonui.CrossAlign::Center,
    )
    let pl = @moonui.Widget::panel(b, r)
    let _ = pl.set_style(
      Some(
        @moonui.style(
          // T412：活跃段纯白、非活跃段与容器同色（sunken）——参考量得容器
          // (242,243,245)，活跃滑块 (255,255,255)。非活跃段不再用 raised。
          background=Some(cx(if on { p.surface } else { p.sunken })),
          radius=Some(6.0),
        ),
      ),
    )
    @moonui.Widget::sized(b, Some(113.0), Some(26.0), pl)
  }
  let tabs = @moonui.Widget::row(b, 0.0, [
    seg("任务", true),
    seg("笔记", false),
  ]).cross_align(@moonui.CrossAlign::Center)
  let tabs_box = @moonui.Widget::padding(b, @moonui.EdgeInsets::all(3.0), tabs)
  let tabs_p = @moonui.Widget::panel(b, tabs_box)
  // T412：分段控件是"白活跃滑块 + 浅灰容器"（参考量得容器 (242,243,245)≈sunken、
  // 活跃段纯白）。之前反了（容器 raised、活跃 surface 混在一起），且侧栏改画布后
  // 容器必须仍是浅灰才看得见。
  let _ = tabs_p.set_style(
    Some(@moonui.style(background=Some(cx(p.sunken)), radius=Some(9.0))),
  )
  kids.push(@moonui.Widget::sized(b, Some(rw), Some(32.0), tabs_p))
  kids.push(blank(b, rw, 5.0))
  // —— 添加任务入口
  kids.push(
    padrow(
      b,
      rw,
      34.0,
      p.canvas,
      7.0,
      @moonui.Widget::row(b, 8.0, [
        face(b, 20.0, 20.0, fn(dl, _env) {
          dl.fill_rect(2.0, 2.0, 16.0, 16.0, radius=8.0, rgb=p.accent)
          dl.line(10.0, 6.0, 10.0, 14.0, rgb=0xFFFFFF, width=1.6)
          dl.line(6.0, 10.0, 14.0, 10.0, rgb=0xFFFFFF, width=1.6)
        }),
        @moonui.Widget::label(b, "添加任务")
        .foreground(cx(p.muted))
        .font_size(13.0),
        gap(b),
      ]).cross_align(@moonui.CrossAlign::Center),
      hover=Some(p.hover),
    ),
  )
  // —— 目的地条目
  let row_of = fn(d : Dest) -> @moonui.Widget[B] raise @moonui.UiError {
    let sel = d.selected
    let fg = if sel { p.strong } else if d.dim { p.faint } else { p.muted }
    // 前置块：收藏夹条目画彩色列表图标（list/bars），项目画"缩进 + 色点"（弱化子项目
    // 多一枚折叠 chevron），其余画单色线性图标。
    let is_col = d.icon == "list" || d.icon == "bars"
    let is_proj = !is_col &&
      (match d.dot {
        Some(_) => true
        None => false
      })
    let lead = if is_col {
      let col = match d.dot {
        Some(c) => c
        None => p.muted
      }
      face(b, 20.0, 20.0, fn(dl, _env) {
        glyph(dl, d.icon, 2.0, 2.0, 16.0, col)
      })
    } else if is_proj {
      // 项目行：前置折叠 chevron（弱化）/ 占位（普通），再接 14px 色点；两者都让
      // 名字落在 x≈64（比收藏夹条目 x≈48 深 16px）。
      let pre = if d.dim {
        ico(b, "chevron_right", 14.0, 0.0, 0.0, 14.0, p.faint)
      } else {
        @moonui.Widget::sized(
          b,
          Some(14.0),
          Some(14.0),
          face(b, 14.0, 14.0, fn(_dl, _env) {  }),
        )
      }
      @moonui.Widget::row(b, 8.0, [
        pre,
        face(b, 14.0, 14.0, fn(dl, _env) {
          let c = match d.dot {
            Some(c) => if d.dim { mix(c, 130, p.surface) } else { c }
            None => p.faint
          }
          dot(dl, 7.0, 7.0, 5.0, c)
        }),
      ]).cross_align(@moonui.CrossAlign::Center)
    } else {
      match d.dot {
        Some(c) =>
          face(b, 20.0, 20.0, fn(dl, _env) { dot(dl, 10.0, 10.0, 5.0, c) })
        None =>
          ico(
            b,
            d.icon,
            20.0,
            0.0,
            0.0,
            20.0,
            if sel {
              p.strong
            } else {
              p.faint
            },
          )
      }
    }
    // 名字：项目名按参考截到 ~103px（"Home renovat…"），其余用普通 label。
    let lbl = if is_proj {
      face(b, 103.0, 18.0, fn(dl, env) {
        let t = truncate_to(d.name, 96.0, 13.0, env)
        dl.text(t, 0.0, 1.0, size=13.0, rgb=fg)
      })
    } else {
      @moonui.Widget::label(b, d.name)
      .foreground(cx(fg))
      .font_size(13.0)
      .font_weight(
        if sel {
          @moonui.FontWeight::Medium
        } else {
          @moonui.FontWeight::Regular
        },
      )
    }
    // 条目数：项目行不显示（网页只画色点 + 名字 + 共享图标）。
    let tail = if is_proj {
      gap(b)
    } else {
      match d.count {
        Some(n) =>
          @moonui.Widget::label(b, n.to_string())
          .foreground(cx(p.faint))
          .font_size(12.5)
        None => gap(b)
      }
    }
    // 共享项目：名字后跟一枚双圆图标。
    let shared = match d.note {
      Some(_) =>
        face(b, 16.0, 16.0, fn(dl, _env) {
          glyph(dl, "shared", 0.0, 0.0, 16.0, p.faint)
        })
      None => gap(b)
    }
    let wgt = @moonui.Widget::row(b, 8.0, [lead, lbl, shared, gap(b), tail]).cross_align(
      @moonui.CrossAlign::Center,
    )
    let wrow = padrow(
      b,
      rw,
      34.0,
      if sel {
        p.selected
      } else {
        p.canvas
      },
      7.0,
      @moonui.Widget::padding(b, @moonui.EdgeInsets::symmetric(0.0, 8.0), wgt),
      hover=Some(p.hover),
    )
    let _ = wrow.on_bubble(
      fn(ev) {
        match ev {
          @moonui.Click(_, _) => true
          _ => false
        }
      },
      fn(_) raise @moonui.UiError { on_pick(d.key) },
    )
    wrow
  }
  // 组头：收藏夹 无 chevron / 无条目数；项目 有 chevron / 无条目数；标签/视图 两者都有。
  // 参考（DOM）：收藏夹 y347 "收藏夹"，项目 y491 "⌄ 项目 全部"，标签 "⌄ 标签 4 全部"。
  let mk_head = fn(g : SideGroup) -> @moonui.Widget[B] raise @moonui.UiError {
    let chev = g.name != "收藏夹"
    let show_count = g.name != "项目"
    let hk : Array[@moonui.Widget[B]] = []
    if chev {
      hk.push(ico(b, "chevron_down", 12.0, 1.0, 1.0, 10.0, p.faint))
    }
    hk.push(
      @moonui.Widget::label(b, g.name)
      .foreground(cx(p.muted))
      .font_size(11.5)
      .font_weight(@moonui.FontWeight::Medium),
    )
    if show_count && g.count > 0 {
      hk.push(
        @moonui.Widget::label(b, g.count.to_string())
        .foreground(cx(p.faint))
        .font_size(11.5),
      )
    }
    hk.push(gap(b))
    match g.link {
      Some(ln) => hk.push(ghostlink(b, ln, p.muted))
      None => hk.push(gap(b))
    }
    @moonui.Widget::row(b, 6.0, hk).cross_align(@moonui.CrossAlign::Center)
  }
  // 四条主目的地
  let n = dests.length()
  for i in 0..<min(4, n) {
    kids.push(row_of(dests[i]))
  }
  // —— "更多" 折叠行（日历 与 收藏夹 之间）
  kids.push(
    padrow(
      b,
      rw,
      34.0,
      p.canvas,
      7.0,
      @moonui.Widget::row(b, 8.0, [
        face(b, 20.0, 20.0, fn(dl, _env) {
          glyph(dl, "chevron_right", 2.0, 2.0, 16.0, p.faint)
        }),
        @moonui.Widget::label(b, "更多")
        .foreground(cx(p.muted))
        .font_size(13.0),
        gap(b),
      ]).cross_align(@moonui.CrossAlign::Center),
      hover=Some(p.hover),
    ),
  )
  // —— 分组（收藏夹 / 项目）：先画前两组
  let ngroups = groups.length()
  for i in 0..<min(2, ngroups) {
    let g = groups[i]
    kids.push(blank(b, rw, 7.0))
    let head = mk_head(g)
    let head_box = @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(2.0, 8.0),
      head,
    )
    kids.push(@moonui.Widget::sized(b, Some(rw), Some(22.0), head_box))
    kids.push(blank(b, rw, 6.0))
    for idx in g.rows {
      if idx < n {
        kids.push(row_of(dests[idx]))
      }
    }
  }
  // —— "日程" 行（项目 与 底部账号 之间）：前置一条分隔线 + 右向折叠 chevron
  kids.push(blank(b, rw, 2.0))
  kids.push(
    @moonui.Widget::sized(
      b,
      Some(rw),
      Some(1.0),
      face(b, rw, 1.0, fn(dl, _env) {
        dl.fill_rect(0.0, 0.0, rw, 1.0, rgb=p.border)
      }),
    ),
  )
  kids.push(blank(b, rw, 2.0))
  kids.push(
    padrow(
      b,
      rw,
      34.0,
      p.canvas,
      7.0,
      @moonui.Widget::row(b, 8.0, [
        face(b, 20.0, 20.0, fn(dl, _env) {
          glyph(dl, "chevron_right", 2.0, 2.0, 16.0, p.faint)
        }),
        @moonui.Widget::label(b, "日程")
        .foreground(cx(p.muted))
        .font_size(13.0),
        gap(b),
      ]).cross_align(@moonui.CrossAlign::Center),
      hover=Some(p.hover),
    ),
  )
  // —— 底部账号区
  kids.push(blank(b, rw, 5.0))
  kids.push(
    @moonui.Widget::row(b, 8.0, [
      face(b, 28.0, 28.0, fn(dl, env) {
        avatar(dl, env, "AD", 28.0, 0x8B5CF6, 0xFFFFFF)
      }),
      @moonui.Widget::label(b, "Alex Demo")
      .foreground(cx(p.strong))
      .font_size(13.0),
      gap(b),
      face(b, 20.0, 20.0, fn(dl, env) {
        glyph(dl, "bell", 2.0, 2.0, 16.0, p.muted)
        badge(dl, env, "2", 12.0, p.danger, 0xFFFFFF, 8.0, -2.0)
      }),
      face(b, 16.0, 16.0, fn(dl, _env) { dot(dl, 8.0, 8.0, 3.5, p.accent) }),
    ]).cross_align(@moonui.CrossAlign::Center),
  )
  kids.push(blank(b, rw, 6.0))
  kids.push(
    @moonui.Widget::row(b, 6.0, [
      ico(b, "logo", 14.0, 0.0, 0.0, 14.0, p.muted),
      @moonui.Widget::label(b, "OpenTodo dev")
      .foreground(cx(p.muted))
      .font_size(12.5),
      gap(b),
    ]).cross_align(@moonui.CrossAlign::Center),
  )
  // —— 分组（标签 / 视图）：画在后两组（网页在 OpenTodo dev 之下，折叠进滚动区）
  for i in 2..<ngroups {
    let g = groups[i]
    kids.push(blank(b, rw, 7.0))
    let head = mk_head(g)
    let head_box = @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(8.0, 8.0),
      head,
    )
    kids.push(@moonui.Widget::sized(b, Some(rw), Some(24.0), head_box))
    kids.push(blank(b, rw, 6.0))
    for idx in g.rows {
      if idx < n {
        kids.push(row_of(dests[idx]))
      }
    }
  }
  kids.push(gap(b))
  let body = @moonui.Widget::column(b, 2.0, kids)
  let pad = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::{ top: 48.0, end: 12.0, bottom: 16.0, start: 12.0, },
    body,
  )
  let p2 = @moonui.Widget::panel(b, pad)
  // T412：侧栏底色是画布灰（网页侧栏没有白卡，条目直接压在画布上）。之前用
  // p.surface 把整栏铺白，量出来整片侧栏白对灰。改成画布色，条目的选中高亮
  // (p.selected) 与悬停 (p.hover) 照旧叠在其上。
  let _ = p2.set_style(Some(@moonui.style(background=Some(cx(p.canvas)))))
  // 侧栏内容比视口高（标签 / 视图 折叠在 OpenTodo dev 之下），整栏滚动
  let sc = @moonui.Widget::scroll(b, @moonui.Axis::Vertical, p2)
  sc.set_hover_style(None)
  @moonui.Widget::sized(b, Some(w), Some(h), sc)
}

///|
fn min(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// 主卡头部。
///
/// "今天"是大字号档（28/650 标题 + 15 号日期副标题 + 15 号简报）；其余视图是
/// 14/600 小标题 + 12.5 号副信息。右侧那簇"整理 + 三枚幽灵图标钮"两档都有。
pub fn[B : @moonui.Backend] card_head(
  b : B,
  p : Palette,
  hd : Head,
  w : Double,
) -> @moonui.Widget[B] raise @moonui.UiError {
  // 右侧操作簇：整理（仅收件箱）+ 筛选 / 日历 / 滑杆 / 更多 / 帮助 五枚幽灵图标钮
  let right_kids : Array[@moonui.Widget[B]] = []
  if hd.tidy {
    right_kids.push(
      fbtn(
        b,
        92.0,
        32.0,
        p.accent,
        0xFFFFFF,
        7.0,
        None,
        None,
        "整理",
        Some("P"),
      ),
    )
  }
  right_kids.push(ico(b, "filter", 32.0, 8.0, 8.0, 16.0, p.muted))
  right_kids.push(ico(b, "monitor", 32.0, 8.0, 8.0, 16.0, p.muted))
  right_kids.push(ico(b, "sliders", 32.0, 8.0, 8.0, 16.0, p.muted))
  right_kids.push(ico(b, "dots", 32.0, 8.0, 8.0, 16.0, p.muted))
  right_kids.push(ico(b, "help", 32.0, 8.0, 8.0, 16.0, p.muted))
  let right = @moonui.Widget::row(b, 0.0, right_kids).cross_align(
    @moonui.CrossAlign::Center,
  )
  if hd.big {
    let title = @moonui.Widget::label(b, hd.title)
      .foreground(cx(p.strong))
      .font_size(28.0)
      .font_weight(@moonui.FontWeight::Bold)
    // meta 用 top:7 内缩再参与行内 Center 对齐，让它的基线与 28px 标题基线持平
    // （网页标题 / 元信息是 baseline 对齐，框架 CrossAlign 只有 Start/Center/End）。
    let meta = @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::{ top: 7.0, end: 0.0, bottom: 0.0, start: 0.0, },
      @moonui.Widget::label(b, hd.meta).foreground(cx(p.muted)).font_size(15.0),
    )
    let trow = @moonui.Widget::row(b, 12.0, [title, meta]).cross_align(
      @moonui.CrossAlign::Center,
    )
    // 简报：加粗引导 + 红色逾期 + warning 尾巴 + "和Sam"（muted），续行 "Rivera 回复了…"。
    // 网页是**自然换行**：整段连续排字，"和Sam" 恰好落在第一行行尾、"Rivera…" 折到
    // 第二行。参考量得第一行墨迹 x579..1875（宽 648 CSS px）、第二行自 y387 起。
    //
    // 实测本端字体的推进宽度比网页窄约 2.2%（同 15px 字号下第一行只有 634 对 648），
    // 所以给每段的起点叠一个补偿斜率 `stretch`，把累计 x 顶到网页的长度上，让行尾
    // 墨迹与折行点都对得上。`T412` 记的三个方向（去 4px 间距 / 只按 run 边界折行 /
    // 换字族）都补不上这个宽度差，就是这个原因。
    //
    // 两段基线：第一行起点 `fx=1.0` 对齐参考的 x579；行内基线 `8.5` 与续行
    // `line_h = 32.0` 是在 `T412` 把卡内边距从 39 收到 30 之后重测的补偿值
    // （卡的整列上移了 9 CSS px，简报是本地钉在面上的，要跟着补回来）。
    // 参考量得第一行 y339、第二行 y387 起。
    let briefing = face(b, 670.0, 52.0, fn(dl, env) {
      let line_h = 32.0
      // T412：换 Inter 后本端推进宽度与网页一致，不再需要逐段 stretch 缝隙
      //（SF Pro 比 Inter 窄 ~8.7%，stretch=6.0 是补那个缺口；现在缺口没了，
      // 缝隙反而让行变宽、run 边界出现参考没有的空格）。
      let stretch = 0.0
      let runs : Array[(String, Int32, Bool)] = []
      runs.push((hd.brief_lead, p.strong, true))
      if hd.brief_danger.length() > 0 {
        runs.push((hd.brief_danger, p.danger, false))
      }
      if hd.brief_rest.length() > 0 {
        runs.push((hd.brief_rest, p.warning, false))
      }
      if hd.brief_mid.length() > 0 {
        runs.push((hd.brief_mid, p.strong, false))
      }
      let mut fx = 1.0
      for e in runs {
        let s = e.0
        let c = e.1
        let bold = e.2
        let w = env.measure_text(s, 15.0, bold).0
        dl.text(s, fx, 8.5, size=15.0, bold~, rgb=c)
        // 补偿斜率：逐段累加，把累计 x 顶到网页的长度上
        fx = fx + w + stretch
      }
      match hd.brief_tail {
        // 续行是单段，没法用逐段补偿斜率顶宽度：本端同字号推进宽度比网页窄，
        // 这里按 8.7% 的缺口把字号提到 16.45 补回来（参考量得跨 808 设备行）。
        // x 起点 1.5 对齐参考的 x581。
        // T412：换 Inter 后缺口消失，字号回到 15（网页口径），跨宽应与参考一致。
        Some(s) => dl.text(s, 1.5, line_h, size=15.0, rgb=p.strong)
        None => ()
      }
    })
    // 网页把操作图标排在标题**上方**的右上角（今天 y≈92，标题 y≈128）；
    // 这里 icons_row 顶到头部首行、gap 把图标推到右缘，trow / briefing 依次下行。
    let icons_row = @moonui.Widget::row(b, 0.0, [gap(b), right]).cross_align(
      @moonui.CrossAlign::Center,
    )
    let col = @moonui.Widget::column(b, 0.0, [
      icons_row,
      @moonui.Widget::padding(
        b,
        @moonui.EdgeInsets::{ top: 14.0, end: 0.0, bottom: 0.0, start: 0.0, },
        trow,
      ),
      @moonui.Widget::padding(
        b,
        @moonui.EdgeInsets::{ top: 5.0, end: 0.0, bottom: 0.0, start: 0.0, },
        briefing,
      ),
    ])
    @moonui.Widget::sized(b, Some(w), Some(146.0), col)
  } else {
    let title = @moonui.Widget::label(b, hd.title)
      .foreground(cx(p.strong))
      .font_size(14.0)
      .font_weight(@moonui.FontWeight::Bold)
    let meta = @moonui.Widget::label(b, hd.meta)
      .foreground(cx(p.muted))
      .font_size(12.5)
    let left = @moonui.Widget::row(b, 8.0, [title, meta, gap(b)]).cross_align(
      @moonui.CrossAlign::Center,
    )
    let r = @moonui.Widget::row(b, 0.0, [left, right]).cross_align(
      @moonui.CrossAlign::Center,
    )
    @moonui.Widget::sized(b, Some(w), Some(34.0), r)
  }
}

///|
/// 快速添加条：1px 边 + 圆角 7，左侧绿色 "+"，中间输入，右侧四枚 28×28 工具钮。
///
/// 返回（控件, 输入框）：输入框的句柄要交出去挂 `bind_input` 与回车录入。
pub fn[B : @moonui.Backend] quick_add(
  b : B,
  p : Palette,
  w : Double,
  placeholder : String,
) -> (@moonui.Widget[B], @moonui.Widget[B]) raise @moonui.UiError {
  let plus = ico(b, "plus", 18.0, 1.0, 1.0, 18.0, p.accent)
  let input = @moonui.Widget::text_input(b, "")
  let _ = input.set_frameless(true)
  let _ = input.set_placeholder(placeholder)
  let _ = input.font_size(13.0)
  let _ = input.foreground(cx(p.strong))
  // `text_input` 是换行态的多行编辑面：不钉住高度它会吃掉整条 52 的高度，
  // 占位文案按多行文路的顶端对齐就飘到条子上沿。钉成 476×20（行内算好的宽
  // 18 + 4×28 + 4×8 + 476 = 636），行的 Center 把它压回竖中线，与网页的居中
  // 占位一致。
  // 宽也得钉死：`with_expand` 挂在展开态的输入框上会让宽度量成无穷大
  // （`Sized(None, …)` 挡不住），行里的工具钮被推到 2³⁰ 以外。
  // **回传句柄仍是 input 本体**——sized 包装是 Sized kind，`bind_input` 里的
  // `set_text` 会拒绝没有文本属性的容器。
  let field = @moonui.Widget::sized(b, Some(476.0), Some(20.0), input)
  let tool = fn(name : String) -> @moonui.Widget[B] raise @moonui.UiError {
    let f = ico(b, name, 28.0, 6.0, 6.0, 16.0, p.muted)
    let _ = f.set_hover_style(
      Some(@moonui.style(background=Some(cx(p.sunken)), radius=Some(6.0))),
    )
    f
  }
  let row = @moonui.Widget::row(b, 8.0, [
    plus,
    field,
    tool("calendar_small"),
    tool("flag"),
    tool("folder"),
    tool("tag"),
  ]).cross_align(@moonui.CrossAlign::Center)
  let body = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(0.0, 12.0),
    row,
  )
  let box = boxrow(b, w, 52.0, p.hover, 7.0, p.border_soft, body)
  let wrap = @moonui.Widget::column(b, 0.0, [gap(b), box])
  (@moonui.Widget::sized(b, Some(w), Some(56.0), wrap), input)
}

///|
/// 分组头：raised 底 + 圆角 6 + 32 高，右侧两条幽灵链接。
pub fn[B : @moonui.Backend] group_head(
  b : B,
  p : Palette,
  s : Section,
  w : Double,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let chev = ico(b, "chevron_down", 20.0, 0.0, 0.0, 20.0, p.muted)
  let nm = @moonui.Widget::label(b, s.title)
    .foreground(cx(p.strong))
    .font_size(12.5)
    .font_weight(@moonui.FontWeight::Medium)
  let cnt = @moonui.Widget::label(b, s.count.to_string())
    .foreground(cx(p.faint))
    .font_size(12.5)
  let r = @moonui.Widget::row(b, 6.0, [
    chev,
    nm,
    cnt,
    gap(b),
    ghostlink(b, "全部移至今天", p.muted),
    ghostlink(b, "重新安排…", p.muted),
  ]).cross_align(@moonui.CrossAlign::Center)
  let body = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(0.0, 8.0),
    r,
  )
  slab(b, w, 32.0, p.raised, 6.0, body)
}

///|
/// 行的正文块：标题一行 + 元信息一行。
///
/// 整块自绘而不是一串 `Label`：元信息是**混排**（多种颜色、带浅底 chip、圆点），
/// 框架没有 attributed text 通道；自绘面里用 `measure_text` 逐段量着摆，正好是
/// 网页那套 inline 流的等价物。
///
/// `read` 每帧读任务（而不是捕获一份拷贝）：勾选切换只 `repaint`，画出来的就是
/// 最新状态，行不必重建。
pub fn[B : @moonui.Backend] body_face(
  b : B,
  p : Palette,
  w : Double,
  read : () -> Task,
) -> @moonui.Widget[B] raise @moonui.UiError {
  face(b, w, 44.0, fn(dl, env) {
    let t = read()
    let fg = if t.done { p.faint } else { p.strong }
    let (tw, th) = env.measure_text(t.title, 13.0, false)
    dl.text(t.title, 0.0, 1.0, size=13.0, rgb=fg)
    // 完成态的删除线：框架没有 text-decoration，自己画一条 1px
    if t.done {
      dl.line(0.0, 1.0 + th / 2.0, tw, 1.0 + th / 2.0, width=1.0, rgb=p.faint)
    }
    // —— 标题行尾的徽记（网页摆在 title 同一行、紧跟标题之后）
    let mut bx = tw + 14.0
    // 优先级信号条（1..=3 才有；4 = 无优先级不画）
    if t.priority >= 1 && t.priority <= 3 {
      glyph(dl, "signal", bx, 1.0, 16.0, prio_line(p, t.priority))
      bx = bx + 16.0
    }
    // 子任务进度：圆圈 + "1/3"
    if t.sub_total > 0 {
      glyph(dl, "check_circle", bx, 2.0, 16.0, p.faint)
      let s = t.sub_done.to_string() + "/" + t.sub_total.to_string()
      dl.text(s, bx + 18.0, 2.0, size=12.5, rgb=p.muted)
      let (dw, _h) = env.measure_text(s, 12.5, false)
      bx = bx + 18.0 + dw + 6.0
    }
    // 备注
    if t.has_notes {
      glyph(dl, "note", bx, 2.0, 16.0, p.faint)
      bx = bx + 16.0
    }
    // 评论数：气泡 + "N"
    if t.comments > 0 {
      glyph(dl, "comment", bx, 2.0, 16.0, p.faint)
      let s = t.comments.to_string()
      dl.text(s, bx + 18.0, 2.0, size=12.5, rgb=p.muted)
      let (dw, _h) = env.measure_text(s, 12.5, false)
      bx = bx + 18.0 + dw + 6.0
    }
    // —— 元信息行（12.5 号，"·" 分隔）
    let mut x = 0.0
    let my = 24.0
    let mut first = true
    let sep = fn() -> Unit {
      if first {
        first = false
      } else {
        dl.text("·", x + 4.0, my, size=12.5, rgb=p.faint)
        let (sw, _h) = env.measure_text("·", 12.5, false)
        x = x + sw + 8.0
      }
    }
    // 到期日：只在"不是今天"时进元信息（今天的任务不写日期；网页口径）。
    // 逾期的用红、其余用弱色，均不加粗（网页 fw=400）。
    match t.due {
      Some(d) =>
        if day_diff(d) != 0 {
          let s = due_text(d)
          dl.text(s, x, my, size=12.5, rgb=due_tone(d, p))
          let (dw, _h) = env.measure_text(s, 12.5, false)
          x = x + dw
          first = false
        }
      None => ()
    }
    // 重复：网页画一个循环图标（"重复" 字样是 sr-only，不可见）。
    match t.repeat {
      Some(_) => {
        sep()
        glyph(dl, "repeat", x, my - 2.0, 16.0, p.muted)
        x = x + 16.0
      }
      None => ()
    }
    match project_of(t.project) {
      Some(pr) => {
        sep()
        dot(dl, x + 4.0, my + 8.0, 4.0, pr.color)
        let nm = pr.name
        dl.text(nm, x + 13.0, my, size=12.5, rgb=p.muted)
        let (dw, _h) = env.measure_text(nm, 12.5, false)
        x = x + 13.0 + dw
      }
      None => ()
    }
    // 标签：chips 之间只有间隙、不画 "·"（网页的 label pill 自带边距）。
    for lk in t.labels {
      match label_of(lk) {
        Some(l) => {
          let nm = l.name
          let (lw, _lh) = env.measure_text(nm, 12.5, false)
          let cw = lw + 12.0
          if first {
            first = false
          } else {
            x = x + 4.0
          }
          dl.fill_rect(
            x,
            my - 1.0,
            cw,
            18.0,
            radius=4.0,
            rgb=mix(l.color, 31, 0xFFFFFF),
          )
          dl.text(
            nm,
            x + 6.0,
            my + 0.5,
            size=12.5,
            rgb=mix(l.color, 150, 0x17191C),
          )
          x = x + cw + 4.0
        }
        None => ()
      }
    }
    if t.estimate > 0 {
      let s = estimate_text(t.estimate)
      sep()
      dl.text(s, x, my, size=12.5, rgb=p.muted)
      let (dw, _h) = env.measure_text(s, 12.5, false)
      x = x + dw
    }
    // 指派人：网页画一个 16px 头像 + 名字（"你" 或人名）。
    match t.assignee {
      Some(a) => {
        sep()
        glyph(dl, "person", x, my - 1.0, 16.0, p.muted)
        let nm = if a == "me" { "你" } else { a }
        dl.text(nm, x + 18.0, my, size=12.5, rgb=p.muted)
        let (dw, _h) = env.measure_text(nm, 12.5, false)
        x = x + 18.0 + dw
      }
      None => ()
    }
    if t.via_api {
      sep()
      let s = "<> 通过 API 添加 · 2 天前"
      dl.text(s, x, my, size=12.5, rgb=p.faint)
    }
  })
}

///|
/// 行内时间列：固定 52px、右对齐、12.5 号。
fn[B : @moonui.Backend] time_face(
  b : B,
  at : String?,
  tone : Int32,
) -> @moonui.Widget[B] raise @moonui.UiError {
  face(b, 52.0, 20.0, fn(dl, env) {
    match at {
      Some(s) => {
        let (_tw, th) = env.measure_text(s, 12.5, false)
        // 网页把时刻靠左排在环右侧（不右对齐），时刻列固定 52 宽给标题让位。
        dl.text(s, 0.0, (20.0 - th) / 2.0, size=12.5, rgb=tone)
      }
      None => ()
    }
  })
}

///|
/// 悬停才出现的右侧操作簇：白底 + 1px 边 + 圆角 7，四枚 32×32 幽灵图标钮。
fn[B : @moonui.Backend] action_cluster(
  b : B,
  p : Palette,
  on_edit : () -> Unit raise @moonui.UiError,
  on_schedule : () -> Unit raise @moonui.UiError,
  on_prio : () -> Unit raise @moonui.UiError,
  on_more : () -> Unit raise @moonui.UiError,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let mk = fn(
    name : String,
    f : () -> Unit raise @moonui.UiError,
  ) -> @moonui.Widget[B] raise @moonui.UiError {
    let f2 = fn() raise @moonui.UiError { f() }
    ico_click(b, name, 32.0, 8.0, 8.0, 16.0, p.muted, f2)
  }
  let r = @moonui.Widget::row(b, 0.0, [
    mk("pencil", on_edit),
    mk("calendar_small", on_schedule),
    mk("flag", on_prio),
    mk("dots", on_more),
  ])
  boxrow(b, 130.0, 34.0, p.surface, 7.0, p.border, r)
}

///|
/// 一条任务行：60 高、圆角 7、内缩 8。
///
/// 悬停时整行亮起 `hover` 底、勾选环换成浅绿底、右侧浮出操作簇（网页用
/// `opacity` 过渡，这里直接切显隐——静态态与网页一致）。
///
/// 行内可变的两处都走信号：`hot_sig` 是悬停档（`MouseEnter/Leave` 翻），
/// `task_sig` 是这条任务本身（勾选切换时由 `todo_app` 更新）。勾选环的自绘面
/// 每帧读这两个信号，`repaint` 只重画这一小面，行不必重建。
pub fn[B : @moonui.Backend] task_row(
  b : B,
  p : Palette,
  t : Task,
  w : Double,
  read : (Int32) -> Task,
  on_toggle : (Int32) -> Unit raise @moonui.UiError,
  on_prio : (Int32) -> Unit raise @moonui.UiError,
  on_delete : (Int32) -> Unit raise @moonui.UiError,
) -> (@moonui.Widget[B], @moonui.Widget[B], @moonui.Widget[B]) raise @moonui.UiError {
  let id = t.id
  let tone = match t.due {
    Some(d) => due_tone(d, p)
    None => p.muted
  }
  let task_sig = @moonui.Signal(t)
  let hot_sig = @moonui.Signal(false)
  let tk_of = fn() -> Task { task_sig.get() catch { _ => read(id) } }
  let hot_of = fn() -> Bool { hot_sig.peek() }
  // 勾选环：面里读 `tk_of()` / `hot_of()` 的最新状态
  let r = face(b, 20.0, 20.0, fn(dl, _env) {
    let tk = tk_of()
    ring(dl, p, tk.priority, tk.done, hot_of(), 0.0, 0.0, 20.0)
  })
  let _ = r.on_click(fn() raise @moonui.UiError { on_toggle(id) })
  let time = time_face(b, t.at, tone)
  let body = body_face(b, p, w - 154.0, tk_of)
  // 悬停才出现的右侧操作簇。四枚钮里只有优先级 / 更多接了账：编辑（铅笔）与排期
  // （日历）在网页上是弹层，这一版还没接，点上去如实抛错而不是静默吞掉。
  let cluster = action_cluster(
    b,
    p,
    fn() raise @moonui.UiError {
      raise @moonui.UiError::Unsupported(
        "行的编辑钮还没接（网页上是弹层）",
      )
    },
    fn() raise @moonui.UiError {
      raise @moonui.UiError::Unsupported(
        "行的排期钮还没接（网页上是弹层）",
      )
    },
    fn() raise @moonui.UiError { on_prio(id) },
    fn() raise @moonui.UiError { on_delete(id) },
  )
  let gripw = grip(b, p)
  let _ = gripw.set_visible(false)
  let content = @moonui.Widget::row(b, 6.0, [
    gripw,
    r,
    time,
    body,
    gap(b),
    cluster,
  ]).cross_align(@moonui.CrossAlign::Start)
  let _ = cluster.set_visible(false)
  let sized_content = @moonui.Widget::sized(
    b,
    Some(w - 16.0),
    Some(44.0),
    content,
  )
  let pad = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::all(8.0),
    sized_content,
  )
  let row = padrow(b, w, 60.0, p.surface, 7.0, pad, hover=Some(0xFAFAFA))
  // 悬停进出：翻面与网页的 `group-hover` 同一条账（握把 + 动作簇一起进出）
  let _ = row.on_bubble(
    fn(ev) {
      match ev {
        @moonui.MouseEnter(_) => true
        @moonui.MouseLeave(_) => true
        _ => false
      }
    },
    fn(ev) raise @moonui.UiError {
      match ev {
        @moonui.MouseEnter(_) => {
          hot_sig.set(true)
          cluster.set_visible(true)
          gripw.set_visible(true)
          r.repaint()
        }
        @moonui.MouseLeave(_) => {
          hot_sig.set(false)
          cluster.set_visible(false)
          gripw.set_visible(false)
          r.repaint()
        }
        _ => ()
      }
    },
  )
  (row, r, cluster)
}

///|
/// 拖拽握把（16×44 面，六个点画在上半段）。
fn[B : @moonui.Backend] grip(
  b : B,
  p : Palette,
) -> @moonui.Widget[B] raise @moonui.UiError {
  face(b, 16.0, 44.0, fn(dl, _env) { grip_glyph(dl, 0.0, 1.0, p.faint) })
}

///|
/// 一栏：分组头（可无）+ 若干行。
pub fn[B : @moonui.Backend] section_view(
  b : B,
  p : Palette,
  s : Section,
  w : Double,
  read : (Int32) -> Task,
  on_toggle : (Int32) -> Unit raise @moonui.UiError,
  on_prio : (Int32) -> Unit raise @moonui.UiError,
  on_delete : (Int32) -> Unit raise @moonui.UiError,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let kids : Array[@moonui.Widget[B]] = []
  if s.title.length() > 0 {
    kids.push(group_head(b, p, s, w))
  }
  for t in s.tasks {
    let (row, _r, _body) = task_row(
      b, p, t, w, read, on_toggle, on_prio, on_delete,
    )
    kids.push(row)
  }
  @moonui.Widget::column(b, 2.0, kids)
}

///|
/// 提醒 Toast：右下角 352×104 白卡 + warning 色 1px 边。
///
/// 为什么整卡自绘（不用 `boxrow` 装内容列）：`boxrow` 的 `sized(352,104)` 里装
/// 一列无弹性内容（标题 + 按钮）时，面板内容会被量成"自然尺寸"、从盒子左上角
/// 起摆，而盒子本身在弹性定位里拿到的是整块帧——两者错位，内容溢出盒子。
/// 卡片的 `boxrow` 之所以能装满是因为它体内有一块弹性 `Scroll` 撑开。提醒条
/// 没有可弹性填充的块，干脆整卡画死：背景 + 边框 + 铃铛 + 两行字 + 四枚钮，
/// 几何全部按网页实测（见 `docs` 里 OpenTodo 复刻口径的 toast 行）。
pub fn[B : @moonui.Backend] toast(
  b : B,
  p : Palette,
  on_dismiss : () -> Unit raise @moonui.UiError,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let w = 352.0
  let h = 104.0
  // 按钮几何（网页实测）：底 y=64、高 32；三枚幽灵钮从 13px 内缩起，4px 缝；
  // 忽略钮推到右缘、右内缩 14。
  let btn = fn(
    dl : @moonui.DrawList,
    env : @moonui.PaintEnv,
    x : Double,
    bw : Double,
    label : String,
    fill : Int32,
    fg : Int32,
    edge : Int32?,
  ) {
    dl.fill_rect(x, 64.0, bw, 32.0, radius=7.0, rgb=fill)
    match edge {
      Some(e) => dl.stroke_rect(x, 64.0, bw, 32.0, radius=7.0, rgb=e, width=1.0)
      None => ()
    }
    let (tw, _th) = env.measure_text(label, 13.0, false)
    dl.text(
      label,
      x + (bw - tw) / 2.0,
      64.0 + (32.0 - 13.0) / 2.0 - 1.0,
      size=13.0,
      rgb=fg,
    )
  }
  let t = face(b, w, h, fn(dl, env) {
    // 白底 + warning 边框
    dl.fill_rect(0.0, 0.0, w, h, radius=7.0, rgb=p.surface)
    outline(dl, env, 7.0, p.warning)
    // 铃铛（左内缩 12，垂直居中于标题块）
    glyph(dl, "alarm", 13.0, 17.0, 18.0, p.muted)
    // 标题 + 副标题
    dl.text(
      "Get three quotes for the kitchen",
      38.0,
      19.0,
      size=13.0,
      bold=true,
      rgb=p.strong,
    )
    dl.text("提醒 · 11月26日, 9:30", 38.0, 41.0, size=12.5, rgb=p.muted)
    // 按钮行
    btn(
      dl,
      env,
      13.0,
      88.0,
      "延后 10 分钟",
      p.surface,
      p.strong,
      Some(p.border),
    )
    btn(dl, env, 105.0, 50.0, "1 小时", p.surface, p.strong, Some(p.border))
    btn(
      dl,
      env,
      159.0,
      80.0,
      "明天 09:00",
      p.surface,
      p.strong,
      Some(p.border),
    )
    btn(dl, env, 298.0, 40.0, "忽略", p.accent, 0xFFFFFF, None)
  })
  // 整卡可点（忽略 → on_dismiss）。命中按整卡算，够用：网页的提醒条点空白也收。
  let _ = t.on_bubble(
    fn(ev) {
      match ev {
        @moonui.Click(_, _) => true
        _ => false
      }
    },
    fn(_) raise @moonui.UiError { on_dismiss() },
  )
  t
}
