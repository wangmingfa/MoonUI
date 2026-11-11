///|
/// Linux 真机复验探针（2026-11-11，`T235` / `T251` 的人工验证件）：
/// 一只窗 + 一只真输入框 + 一块只读日志。五条事件（FileDrop / ImeStart /
/// ImeCompose / ImeEnd / Input）同时打到终端与窗口里，供人对照
/// `scripts/linux-real-check.sh` 打出的清单逐条核。
///
/// 为什么需要它：自动化那边只能证机制——`canvas-pixel-selftest.c` 用
/// `g_signal_emit_by_name` 驱动组合相位、用 `GdkFileList` 直接喂 drop 分发；
/// "ibus / fcitx5 真把 preedit 递进来"与"文件管理器真把 URI 交给 GTK"只有
/// 真桌面能证。这个探针不判红绿，只把到达的事实原样打出来。

///|
fn main raise {
  let app = @moonui-app.new_app()
  let b = app.backend
  // 真输入框：组合相位挂在它身上（后端按控件取 GtkIMContext 旁听）。
  let input = @moonui.Widget::text_input(b, "")
  let log = @moonui.Widget::multiline(
    b, "探针已就绪：点下面输入框用输入法打中文；把文件从文件管理器拖进窗口。\n",
  )
  let win = app.create_window(
    "MoonUI Linux 真机探针",
    LogicalSize(720.0, 460.0),
  )
  win.set_content(
    @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::all(12.0),
      @moonui.Widget::column(b, 8.0, [
        input,
        @moonui.Widget::sized(b, None, Some(340.0), log),
      ]),
    ),
  )
  win.show()
  // 一行同时进终端与窗口：终端给"照单核对"，窗口给"这东西确实活着"。
  let note = fn(line : String) -> Unit {
    println(line)
    log.set_text(line + "\n" + log.text()) catch {
      _ => ()
    }
  }
  // 输入法四拍 + 上屏全文：target 是输入框自己。
  let _ = app.on_event(input.target(), fn(ev : @moonui.Event) -> Unit {
    match ev {
      ImeStart(_) => note("[IME] start")
      ImeCompose(_, preedit) =>
        note("[IME] compose preedit=\"" + preedit + "\"")
      ImeEnd(_) => note("[IME] end")
      Input(_, text) => note("[Input] text=\"" + text + "\"")
      _ => ()
    }
  })
  // 外部文件拖入：target 是接住拖入的窗口。
  let _ = app.on_event(win.target(), fn(ev : @moonui.Event) -> Unit {
    match ev {
      FileDrop(_, paths) =>
        note(
          "[FileDrop] " +
          paths.length().to_string() +
          " 个：" +
          @common.join(paths, " | "),
        )
      _ => ()
    }
  })
  println("")
  println("检查项 A · 文件拖入交接（T235）：")
  println(
    "  从文件管理器（Nautilus / Dolphin / Thunar 都行）拖 2 个文件到窗口任意位置松手。",
  )
  println(
    "  期望：终端出现一条 [FileDrop] 2 个：<路径1> | <路径2>，顺序与拖入一致；窗口日志同样一行。",
  )
  println(
    "  再拖 1 个：期望一条 [FileDrop] 1 个：<路径>。拖文本/网页链接不应出现 [FileDrop]。",
  )
  println("")
  println("检查项 B · 输入法组合相位（T251）：")
  println(
    "  点进输入框，切到 ibus 或 fcitx5 的中文输入法，键入「中文测试」。",
  )
  println(
    "  期望：先 [IME] start，随后若干 [IME] compose（preedit 为拼音/候选串），",
  )
  println(
    "        选词上屏后 [IME] end，最后一条 [Input] text=\"中文测试\"。",
  )
  println(
    "  组合期间每敲一个字母不应产生逐键 [Input]（上屏全文只随最后一次 Input 走）。",
  )
  println(
    "  取消组合（Esc）应只看到 [IME] end，没有对应的 [Input]。",
  )
  println("")
  println(
    "检查项 C · 焦点归属：组合中把焦点移到窗口别处（点日志框），再切回输入框，",
  )
  println(
    "  相位应从新的 start 重新开始，不出现上一只控件的 compose。",
  )
  println("")
  println(
    "关窗口结束；把终端里的行数与内容抄进 TODO 的复验记录。",
  )
  app.run()
}
