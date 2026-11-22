///|
/// 清行的最小判据：只测 `clear_lines` 这一段，不碰 UI。
/// 这几条同时是"卡死"的回归入口——两行连续满时旧实现会原地打转。

///|
fn fill_row(g : Game, y : Int32, v : Int32) -> Unit {
  for x in 0..<BOARD_W {
    g.board[y * BOARD_W + x] = v
  }
}

///|
test "clear_lines: 单行满" {
  let g = Game::new(7)
  fill_row(g, BOARD_H - 1, 1)
  // 上一行只填前 5 格：清完后这 5 格应原样落到底行，且只清 1 行
  for x in 0..<5 {
    g.board[(BOARD_H - 2) * BOARD_W + x] = 2
  }
  assert_eq(g.clear_lines(), 1)
  for x in 0..<5 {
    assert_eq(g.board[(BOARD_H - 1) * BOARD_W + x], 2)
  }
  for x in 5..<BOARD_W {
    assert_eq(g.board[(BOARD_H - 1) * BOARD_W + x], 0)
  }
  for y in 0..<(BOARD_H - 1) {
    for x in 0..<BOARD_W {
      assert_eq(g.board[y * BOARD_W + x], 0)
    }
  }
}

///|
test "clear_lines: 两行连续满（Tetris 之外最常见的双消）" {
  let g = Game::new(7)
  fill_row(g, BOARD_H - 1, 1)
  fill_row(g, BOARD_H - 2, 2)
  // 第三行只填前 3 格，避免被一起消掉，同时用来验落位
  for x in 0..<3 {
    g.board[(BOARD_H - 3) * BOARD_W + x] = 3
  }
  assert_eq(g.clear_lines(), 2)
  for x in 0..<3 {
    assert_eq(g.board[(BOARD_H - 1) * BOARD_W + x], 3)
  }
  for x in 3..<BOARD_W {
    assert_eq(g.board[(BOARD_H - 1) * BOARD_W + x], 0)
  }
  for y in 0..<(BOARD_H - 1) {
    for x in 0..<BOARD_W {
      assert_eq(g.board[y * BOARD_W + x], 0)
    }
  }
}

///|
test "clear_lines: 四行全满 + 顶行参与" {
  let g = Game::new(7)
  for i in 0..<4 {
    fill_row(g, BOARD_H - 1 - i, i + 1)
  }
  assert_eq(g.clear_lines(), 4)
  for y in 0..<BOARD_H {
    for x in 0..<BOARD_W {
      assert_eq(g.board[y * BOARD_W + x], 0)
    }
  }
}

///|
test "clear_lines: 顶行满不读负索引" {
  let g = Game::new(7)
  fill_row(g, 0, 5)
  assert_eq(g.clear_lines(), 1)
  for x in 0..<BOARD_W {
    assert_eq(g.board[x], 0)
  }
}

///|
test "clear_lines: 没有满行时不动棋盘" {
  let g = Game::new(7)
  fill_row(g, BOARD_H - 1, 1)
  g.board[(BOARD_H - 1) * BOARD_W + 3] = 0
  assert_eq(g.clear_lines(), 0)
  assert_eq(g.board[(BOARD_H - 1) * BOARD_W + 0], 1)
  assert_eq(g.board[(BOARD_H - 1) * BOARD_W + 3], 0)
}

///|
/// 随机操作的 fuzz：不验分数，只验"有限步内总能推进"。旧清行实现（清掉一行
/// 后原地重查、被搬走的上一行仍留在原位）在这里会挂住，`moon test` 表现为
/// 进程超时——这就是卡死的回归入口。
test "随机操作 20 轮不卡死" {
  let g = Game::new(2026)
  let mut round = 0
  while round < 20 {
    g.restart()
    g.start()
    let mut i = 0
    while i < 200 && g.state == 1 {
      let r = i * 7 + round * 3
      let k = r % 9
      if k == 0 {
        let _ = g.shift(-1, 0)
      } else if k == 1 {
        let _ = g.shift(1, 0)
      } else if k == 2 {
        let _ = g.rotate(1)
      } else if k == 3 {
        let _ = g.rotate(-1)
      } else if k == 4 {
        let _ = g.shift(0, 1)
      } else if k == 5 {
        g.hold_piece()
      } else {
        let _ = g.hard_drop()
      }
      g.tick(16)
      i += 1
    }
    // 20 轮 × 200 步都以某个合法状态收尾（不挂在中间）
    assert_eq(g.state == 1 || g.state == 2 || g.state == 3, true)
    // 棋盘下标始终在界内：顺带钉住"没有负索引/越界写"
    for y in 0..<BOARD_H {
      for x in 0..<BOARD_W {
        let v = g.board[y * BOARD_W + x]
        assert_eq(v >= 0 && v <= 7, true)
      }
    }
    round += 1
  }
}
