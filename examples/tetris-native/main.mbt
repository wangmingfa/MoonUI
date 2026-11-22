///|
/// 俄罗斯方块帧率基准：整窗只有一块自绘面，16ms 一拍重画一次。
/// 一帧只提交一份 DrawList，因此屏幕上的 FPS 就是这套管线端到端的读数。

///|
struct Monitor {
  mut last : Int32
  mut frames : Int32
  mut acc : Int32
  mut fps : Double
  mut frame_ms : Double
  mut total : Int32
  mut elapsed : Int32
  mut worst : Double
  mut paint_total : Int32
  mut paint_max : Int32
  mut cmds : Int32
}

///|
struct Input {
  mut left : Bool
  mut right : Bool
  mut down : Bool
  mut left_ms : Int32
  mut right_ms : Int32
  mut down_ms : Int32
}

///|
fn fmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn shift_rgb(rgb : Int32, delta : Int32) -> Int32 {
  let r = (rgb >> 16) & 255
  let g = (rgb >> 8) & 255
  let b = rgb & 255
  let nr = fmin((r + delta).to_double(), 255.0).to_int()
  let ng = fmin((g + delta).to_double(), 255.0).to_int()
  let nb = fmin((b + delta).to_double(), 255.0).to_int()
  nr * 65536 + ng * 256 + nb
}

///|
fn draw_block(
  dl : @moonui.DrawList,
  x : Double,
  y : Double,
  s : Double,
  kind : Int32,
  ghost : Bool,
) -> Unit {
  let c = block_color(kind)
  if ghost {
    dl.fill_rect(
      x + 2.0,
      y + 2.0,
      s - 4.0,
      s - 4.0,
      radius=3.0,
      rgb=c,
      alpha=48,
    )
  } else {
    dl.fill_rect(x, y, s, s, radius=4.0, rgb=shift_rgb(c, -62))
    dl.fill_rect(x + 1.5, y + 1.5, s - 3.0, s - 3.0, radius=3.0, rgb=c)
    dl.fill_rect(
      x + 2.0,
      y + 2.0,
      s - 4.0,
      fmin(s * 0.2, 4.0),
      radius=2.0,
      rgb=shift_rgb(c, 46),
    )
  }
}

///|
/// 落定格只画一笔：每帧 200 格 × 3 笔的圆角+高光是 GDI+ 上最贵的一块，
/// 落定的方块不需要每帧重画高光，留一笔圆角就够清楚。
fn draw_locked(
  dl : @moonui.DrawList,
  x : Double,
  y : Double,
  s : Double,
  kind : Int32,
) -> Unit {
  dl.fill_rect(
    x + 0.5,
    y + 0.5,
    s - 1.0,
    s - 1.0,
    radius=3.0,
    rgb=shift_rgb(block_color(kind), -28),
  )
}

///|
fn panel(
  dl : @moonui.DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  title : String,
) -> Unit {
  dl.fill_rect(x, y, w, h, radius=12.0, rgb=0x151B29)
  dl.stroke_rect(x, y, w, h, radius=12.0, width=1.0, rgb=0x2B3852)
  dl.text(title, x + 12.0, y + 10.0, size=11.0, bold=true, rgb=0x8FA3BF)
}

///|
fn text_center(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  text : String,
  cx : Double,
  y : Double,
  size : Double,
  bold : Bool,
  rgb : Int32,
) -> Unit {
  let (tw, _) = env.measure_text(text, size, bold)
  dl.text(text, cx - tw / 2.0, y, size~, bold~, rgb~)
}

///|
fn stat_row(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  label : String,
  value : String,
  x : Double,
  y : Double,
  w : Double,
) -> Unit {
  dl.text(label, x, y, size=11.0, rgb=0x8FA3BF)
  let (tw, _) = env.measure_text(value, 15.0, true)
  dl.text(value, x + w - tw, y - 3.0, size=15.0, bold=true, rgb=0xE8F0FC)
}

///|
/// 预览框：把四格方块按包围盒居中，不留空白偏心。
fn preview(
  dl : @moonui.DrawList,
  kind : Int32,
  cx : Double,
  cy : Double,
  cell : Double,
) -> Unit {
  if kind < 0 {
    return
  }
  let shape = cells(kind, 0)
  let mut minx = 9
  let mut maxx = 0
  let mut miny = 9
  let mut maxy = 0
  for c in shape {
    let (x, y) = c
    if x < minx {
      minx = x
    }
    if x > maxx {
      maxx = x
    }
    if y < miny {
      miny = y
    }
    if y > maxy {
      maxy = y
    }
  }
  let ox = cx -
    (maxx - minx + 1).to_double() * cell / 2.0 -
    minx.to_double() * cell
  let oy = cy -
    (maxy - miny + 1).to_double() * cell / 2.0 -
    miny.to_double() * cell
  for c in shape {
    let (x, y) = c
    draw_locked(
      dl,
      ox + x.to_double() * cell + 1.0,
      oy + y.to_double() * cell + 1.0,
      cell - 2.0,
      kind,
    )
  }
}

///|
fn fixed1(v : Double) -> String {
  let n = (v * 10.0 + 0.5).to_int()
  "\{n / 10}.\{n % 10}"
}

///|
fn paint(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  game : Game,
  mon : Monitor,
) -> Unit {
  let w = env.width()
  let h = env.height()
  let pad = 18.0
  let top = 58.0
  let bottom = 60.0
  let content_h = h - top - bottom - pad
  let side_w = 176.0
  let left_w = w - pad * 3.0 - side_w
  let cell = fmin(left_w / 10.0, content_h / 20.0)
  let bw = cell * 10.0
  let bh = cell * 20.0
  let bx = pad + (left_w - bw) / 2.0
  let by = top + (content_h - bh) / 2.0
  let sx = bx + bw + 24.0
  let sw = w - sx - pad

  dl.fill_rect(0.0, 0.0, w, h, rgb=0x0C1018)
  dl.fill_rect(0.0, 0.0, w, 3.0, rgb=0x3B82F6)
  dl.text("TETRIS", pad, 14.0, size=24.0, bold=true, rgb=0xF2F6FF)
  dl.text(
    "MoonUI native · 60 FPS 渲染基准",
    pad + 116.0,
    24.0,
    size=11.0,
    rgb=0x7F8FA8,
  )
  let fps_rgb = if mon.fps >= 55.0 {
    0x4ADE80
  } else if mon.fps >= 45.0 {
    0xFACC15
  } else {
    0xF87171
  }
  dl.fill_rect(w - pad - 166.0, 12.0, 166.0, 32.0, radius=9.0, rgb=0x151B29)
  dl.stroke_rect(
    w - pad - 166.0,
    12.0,
    166.0,
    32.0,
    radius=9.0,
    width=1.0,
    rgb=0x2B3852,
  )
  dl.text(
    "FPS \{fixed1(mon.fps)}   \{fixed1(mon.frame_ms)} ms",
    w - pad - 154.0,
    21.0,
    size=12.0,
    bold=true,
    rgb=fps_rgb,
  )

  // 棋盘底与网格
  dl.shadow(0.0, 6.0, 14.0, 0x000000)
  dl.fill_rect(
    bx - 8.0,
    by - 8.0,
    bw + 16.0,
    bh + 16.0,
    radius=14.0,
    rgb=0x121826,
  )
  dl.shadow(0.0, 0.0, 0.0, 0x000000)
  dl.fill_rect(bx, by, bw, bh, radius=6.0, rgb=0x0A0E16)
  for x in 0..<BOARD_W {
    let gx = bx + x.to_double() * cell
    dl.line(gx, by, gx, by + bh, width=1.0, rgb=0x1A2231)
  }
  for y in 0..<BOARD_H {
    let gy = by + y.to_double() * cell
    dl.line(bx, gy, bx + bw, gy, width=1.0, rgb=0x1A2231)
  }
  for y in 0..<BOARD_H {
    for x in 0..<BOARD_W {
      let v = game.board[y * BOARD_W + x]
      if v > 0 {
        draw_locked(
          dl,
          bx + x.to_double() * cell + 1.0,
          by + y.to_double() * cell + 1.0,
          cell - 2.0,
          v - 1,
        )
      }
    }
  }
  if game.state != 3 {
    let gy = game.ghost_y()
    if gy != game.py {
      for c in cells(game.kind, game.rot) {
        let (cx, cy) = c
        let y = gy + cy
        if y >= 0 {
          draw_block(
            dl,
            bx + (game.px + cx).to_double() * cell + 1.0,
            by + y.to_double() * cell + 1.0,
            cell - 2.0,
            game.kind,
            true,
          )
        }
      }
    }
    for c in cells(game.kind, game.rot) {
      let (cx, cy) = c
      let y = game.py + cy
      if y >= 0 {
        draw_block(
          dl,
          bx + (game.px + cx).to_double() * cell + 1.0,
          by + y.to_double() * cell + 1.0,
          cell - 2.0,
          game.kind,
          false,
        )
      }
    }
  }

  // 侧栏：暂存 / 接下来 / 数据
  let hold_h = 92.0
  panel(dl, sx, top, sw, hold_h, "暂存  C")
  let hold_kind = if game.hold_used { -2 } else { game.hold }
  if hold_kind == -2 {
    dl.text("本回合已用", sx + 12.0, top + 42.0, size=11.0, rgb=0x64748B)
  } else {
    preview(dl, game.hold, sx + sw / 2.0, top + 54.0, 17.0)
  }
  let next_y = top + hold_h + 10.0
  let next_h = 206.0
  panel(dl, sx, next_y, sw, next_h, "接下来")
  for i in 0..<3 {
    let row_y = next_y + 30.0 + i.to_double() * 58.0
    dl.fill_rect(sx + 10.0, row_y, sw - 20.0, 52.0, radius=8.0, rgb=0x101725)
    preview(dl, game.queue[i], sx + sw / 2.0, row_y + 26.0, 15.0)
  }
  let stat_y = next_y + next_h + 10.0
  let stat_h = h - bottom - stat_y - pad + 42.0
  panel(dl, sx, stat_y, sw, stat_h, "本局数据")
  stat_row(
    dl,
    env,
    "得分",
    game.score.to_string(),
    sx + 12.0,
    stat_y + 38.0,
    sw - 24.0,
  )
  stat_row(
    dl,
    env,
    "消除",
    game.lines.to_string(),
    sx + 12.0,
    stat_y + 66.0,
    sw - 24.0,
  )
  stat_row(
    dl,
    env,
    "等级",
    game.level.to_string(),
    sx + 12.0,
    stat_y + 94.0,
    sw - 24.0,
  )
  stat_row(
    dl,
    env,
    "方块",
    game.pieces.to_string(),
    sx + 12.0,
    stat_y + 122.0,
    sw - 24.0,
  )

  // 底部键位提示
  dl.line(
    pad,
    h - bottom + 8.0,
    w - pad,
    h - bottom + 8.0,
    width=1.0,
    rgb=0x1D2636,
  )
  dl.text(
    "← → 移动   ↑ / X 旋转   Z 逆转   ↓ 软降",
    pad,
    h - 34.0,
    size=11.0,
    rgb=0x9AAAC2,
  )
  dl.text(
    "SPACE 硬降   C 暂存   P 暂停   R 重开",
    pad,
    h - 18.0,
    size=11.0,
    rgb=0x9AAAC2,
  )

  // 状态覆盖层：字压在棋盘上，不额外开 HWND
  if game.state != 1 {
    let title = if game.state == 0 {
      "按 空格 开始"
    } else if game.state == 2 {
      "已暂停 · P 继续"
    } else {
      "游戏结束 · R 重开"
    }
    let hint = if game.state == 0 {
      "方向键移动，空格一落到底"
    } else if game.state == 2 {
      "当前进度已保留"
    } else {
      "得分 \{game.score.to_string()} · 消除 \{game.lines.to_string()} 行"
    }
    dl.fill_rect(bx, by, bw, bh, radius=6.0, rgb=0x05080F, alpha=196)
    text_center(
      dl,
      env,
      title,
      bx + bw / 2.0,
      by + bh / 2.0 - 22.0,
      18.0,
      true,
      0xF2F6FF,
    )
    text_center(
      dl,
      env,
      hint,
      bx + bw / 2.0,
      by + bh / 2.0 + 10.0,
      11.0,
      false,
      0xA9B7CD,
    )
  }
  mon.cmds = dl.len()
}

///|
fn autorepeat(inp : Input, game : Game, dt : Int32) -> Unit {
  let das = 170
  let arr = 45
  if inp.left {
    inp.left_ms += dt
    if inp.left_ms >= das {
      let steps = (inp.left_ms - das) / arr + 1
      inp.left_ms = das - (inp.left_ms - das) % arr
      for _i in 0..<steps {
        if !game.shift(-1, 0) {
          break
        }
      }
    }
  }
  if inp.right {
    inp.right_ms += dt
    if inp.right_ms >= das {
      let steps = (inp.right_ms - das) / arr + 1
      inp.right_ms = das - (inp.right_ms - das) % arr
      for _i in 0..<steps {
        if !game.shift(1, 0) {
          break
        }
      }
    }
  }
  if inp.down {
    inp.down_ms += dt
    if inp.down_ms >= 45 {
      let steps = inp.down_ms / 45
      inp.down_ms = inp.down_ms % 45
      for _i in 0..<steps {
        if !game.shift(0, 1) {
          break
        }
      }
    }
  }
}

///|
/// `moon run examples/tetris-native` 开真窗口；设 `TETRIS_BENCH_MS=5000`
/// 则跑满 5 秒后自动打印统计并退出，方便无人值守测帧率。
fn main raise {
  let bench_ms = match @env.get_env_var("TETRIS_BENCH_MS") {
    Some(v) => (@string.from_str(v[:]) : Int32) catch { _ => 0 }
    None => 0
  }
  let app = @moonui-app.new_app()
  // 应用图标：stem 约定（Windows 补 `.ico`、mac 补 `.png`，两份都在
  // `assets/logo/`）。读不到只是装饰没装上——从 exe 旁边 / 快捷方式启动时
  // CWD 不是仓库根，`assets/` 在那儿不存在，不该为此把示例打死。
  app.set_icon("assets/logo/tetris") catch {
    @moonui.OperationFailed(m) => println("应用图标没装上：\{m}")
    _ => println("应用图标没装上")
  }
  let b = app.backend()
  let game = Game::new(20261122)
  let mon = Monitor::{
    last: 0,
    frames: 0,
    acc: 0,
    fps: 0.0,
    frame_ms: 0.0,
    total: 0,
    elapsed: 0,
    worst: 999.0,
    paint_total: 0,
    paint_max: 0,
    cmds: 0,
  }
  let inp = Input::{
    left: false,
    right: false,
    down: false,
    left_ms: 0,
    right_ms: 0,
    down_ms: 0,
  }
  let face = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(760.0, 640.0),
    fn(dl, env) { paint(dl, env, game, mon) },
    focusable=true,
  )
  let _ = face.on_any(fn(ev) {
    match ev {
      @moonui.KeyDown(_, kp) => {
        let k = kp.key
        if k == "Left" {
          if !inp.left {
            let _ = game.shift(-1, 0)
            inp.left = true
            inp.left_ms = 0
          }
        } else if k == "Right" {
          if !inp.right {
            let _ = game.shift(1, 0)
            inp.right = true
            inp.right_ms = 0
          }
        } else if k == "Down" {
          if !inp.down {
            let _ = game.shift(0, 1)
            inp.down = true
            inp.down_ms = 0
          }
        } else if k == "Up" || k == "x" || k == "X" {
          let _ = game.rotate(1)
        } else if k == "z" || k == "Z" {
          let _ = game.rotate(-1)
        } else if k == "Space" {
          if game.state == 0 {
            game.start()
          } else if game.state == 3 {
            game.restart()
            game.start()
          } else if game.state == 1 {
            let _ = game.hard_drop()
          }
        } else if k == "c" || k == "C" {
          game.hold_piece()
        } else if k == "p" || k == "P" || k == "Escape" {
          game.toggle_pause()
        } else if k == "r" || k == "R" {
          game.restart()
          game.start()
        }
      }
      @moonui.KeyUp(_, kp) => {
        let k = kp.key
        if k == "Left" {
          inp.left = false
          inp.left_ms = 0
        } else if k == "Right" {
          inp.right = false
          inp.right_ms = 0
        } else if k == "Down" {
          inp.down = false
          inp.down_ms = 0
        }
      }
      _ => ()
    }
  })
  let win = app.create_window(
    "Tetris · MoonUI 60 FPS Bench",
    @moonui.LogicalSize(760.0, 640.0),
  )
  win.set_content(face)
  win.show()
  // `T343`：把帧率同时送到一只独立的透明 HUD 窗。HUD 窗走 layered
  // 一次成型，不进主窗的重绘账，所以右上角面板的读数与 HUD 是同一份数、
  // 却互不拖累。`T349` 起改成**应用内**档：贴在主窗右上角、跟着主窗走，
  // 主窗最小化时一起隐藏（不再固定在屏幕坐标上浮着）。mac/linux 第一期
  // 这一档返回 None，主窗读数照旧。
  app.set_hud_clock(fn() { @native-common.native_time_ms() })
  let hud = @native-common.NativeHud::create_in_window(
    win.handle(),
    @native-common.HudCorner::TopRight,
    -12,
    12,
    210,
    116,
  )
  let hud_id = app.on_hud_metrics(500, fn(m) {
    match hud {
      Some(w) => {
        let _ = w.show_metrics(m, ["State  \{game.state}"])
      }
      None => ()
    }
    // 这里不再 `face.repaint()`：ticker 每 16ms 已经重画主窗，HUD 回调再补
    // 一发就变成同一帧提交两份 DrawList/两次 present，16fps 下肉眼就是一跳。
    // FPS 读数在 mon 里，下一拍 ticker 的 paint 自然带上最新值。
  })
  let _ = hud_id
  println(
    "俄罗斯方块已开窗：空格开始，方向键操作；关窗口退出",
  )
  println(
    "  帧率读数在右上角与独立 HUD 窗；设 TETRIS_BENCH_MS=<毫秒> 可自动跑分退出",
  )

  let ticker = @moonui.Ticker()
  // `T345`：帧节拍用 `post_animation`（绝对节拍续期）——`post_every` 是
  // "干完再等 16ms"，配上 20ms 的一帧只能量出 27fps，画得再快也到不了 60。
  let _ = app.post_animation(ticker, 16, fn(
    first,
  ) -> Bool raise @moonui.UiError {
    let now = @native-common.native_time_ms()
    let dt = if mon.last == 0 {
      16
    } else {
      let d = now - mon.last
      if d > 0 && d < 1000 {
        d
      } else {
        16
      }
    }
    mon.last = now
    mon.frames += 1
    mon.total += 1
    mon.acc += dt
    mon.elapsed += dt
    if mon.acc >= 500 {
      mon.fps = mon.frames.to_double() * 1000.0 / mon.acc.to_double()
      mon.frame_ms = mon.acc.to_double() / mon.frames.to_double()
      if mon.fps < mon.worst {
        mon.worst = mon.fps
      }
      mon.frames = 0
      mon.acc = 0
    }
    let _ = first
    autorepeat(inp, game, dt)
    game.tick(dt)
    let t0 = @native-common.native_time_ms()
    face.repaint()
    let cost = @native-common.native_time_ms() - t0
    mon.paint_total += cost
    if cost > mon.paint_max {
      mon.paint_max = cost
    }
    // `T343`：把这一帧的命令数喂进 HUD 账，随下一跳 FPS 一起发给订阅者。
    app.report_hud_cmds(mon.cmds)
    if bench_ms > 0 && mon.elapsed >= bench_ms {
      let avg = mon.total.to_double() * 1000.0 / mon.elapsed.to_double()
      println(
        "Tetris bench: frames=\{mon.total}, elapsed=\{mon.elapsed}ms, avg=\{fixed1(avg)}fps, worst-window=\{fixed1(mon.worst)}fps, paint=\{fixed1(mon.paint_total.to_double() / mon.total.to_double())}ms/max\{mon.paint_max}ms, cmds=\{mon.cmds}",
      )
      app.quit()
      return false
    }
    true
  })
  app.run()
}
