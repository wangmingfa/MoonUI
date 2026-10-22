///|
/// 真手指验证的交互探针（2026-10-22，`T91`/`T106` 的 owner 人工验证件）：
/// 一只窗口，把捏合/旋转/滑动三个手势与文件拖入的事件实时打出来——
/// 终端一份、窗口里一份（只读多行框，最新一行在最上）。另把托盘图标
/// 与托盘菜单装上（点托盘菜单项会在打印里出现），供肉眼验证。
///
/// 为什么这个包存在：真窗测试里的手势与拖文件走的是脚手架注入
/// （WM_GESTURE 合成不进去、拖放走 simulate），自动化证明的是"解析与
/// 派发对"，只有真手指能证明"user32/触控板真的把 WM_GESTURE 投给这只
/// 窗、Explorer 拖文件真的走 WM_DROPFILES"。

///|
fn phase_name(phase : @moonui.GesturePhase) -> String {
  match phase {
    Began => "Began"
    Changed => "Changed"
    Ended => "Ended"
    Cancelled => "Cancelled"
  }
}

///|
fn dir_name(dir : @moonui.SwipeDirection) -> String {
  match dir {
    Left => "左"
    Right => "右"
    Up => "上"
    Down => "下"
  }
}

///|
fn main raise {
  let app = @moonui-app.new_app()
  let b = app.backend
  let log = @moonui.Widget::multiline(
    b, "把文件拖进窗口、双指捏合/旋转/滑动——事件打在这里\n",
  )
  let win = app.create_window("MoonUI 交互探针", LogicalSize(640.0, 420.0))
  win.set_content(log)
  // create_window 只建不显（Gallery::demo 的先例里 show 由壳来调），探针的
  // 这只窗必须真显示出来才有东西可看。
  win.show()
  // 三个事件全挂在窗口目标上：后端的命中归属把手势归到指针下的控件，
  // 拖放归到顶层窗——都取窗口目标最稳。
  let target = win.target()
  let on_ev = fn(ev : @moonui.Event) -> Unit raise @moonui.UiError {
    match ev {
      Gesture(_, Magnify(d, phase)) =>
        log.set_text("捏合增量 \{d} (\{phase_name(phase)})\n" + log.text())
      Gesture(_, Rotate(rad, phase)) =>
        log.set_text(
          "旋转 \{rad} 弧度 (\{phase_name(phase)})\n" + log.text(),
        )
      Gesture(_, Swipe(dir)) =>
        log.set_text("滑动 \{dir_name(dir)}\n" + log.text())
      FileDrop(_, paths) =>
        log.set_text("拖入 \{@common.join(paths, " | ")}\n" + log.text())
      _ => ()
    }
  }
  let _ = app.on_event(target, on_ev)
  // 托盘：图标 + 菜单（点哪一项都有打印可见——退出项直接退出）。
  let _ = app.set_tray_icon("assets/logo/moonui")
  let hi = @moonui.MenuItem::new("探针说你好")
  let _ = hi.on(fn(_) {
    log.set_text("托盘菜单：你好\n" + log.text()) catch {
      _ => ()
    }
  })
  let quit = @moonui.MenuItem::new("退出")
  let _ = quit.on(fn(_) { app.quit() })
  let _ = app.set_tray_menu(
    @moonui.Menu::new("探针", [Item(hi), Separator, Item(quit)]),
  )
  println(
    "真窗口已打开：拖文件进来、双指捏合/旋转/滑动；托盘菜单在任务栏右下角。",
  )
  println("关窗口或点托盘菜单的\"退出\"结束。")
  app.run()
}
