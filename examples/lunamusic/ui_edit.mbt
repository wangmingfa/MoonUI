///|
/// 「编辑信息」小窗（DESIGN.md C-16）：标题 / 歌手 / 专辑 三行输入。
///
/// 与播放列表 / 均衡器 / 歌词秀共用 `CmStrip` + `cm_window_shell` 那套外壳，
/// 摆在一起才像同一个程序里的第五只窗。
///
/// **两只手性**：
/// 1. 窗只建一次（`LunaMusicApp.edit` 懒建），`rebuild_ui` 不碰它——整树重建
///    会销毁原生输入控件，正在打的字、光标位置、输入法状态全没（`demo.mbt`
///    记过这条限制）。
/// 2. 输入值全文**不镜像到 MoonBit 侧**：保存时用 `Widget::text()` 现读。
///    打字过程零状态、零回调、零重建，也就不会有"每敲一个字就重排一次"。
pub(all) struct EditDialog[B] {
  window : @moonui.Window[B]
  title_in : @moonui.Widget[B]
  artist_in : @moonui.Widget[B]
  album_in : @moonui.Widget[B]
  ok : @moonui.Widget[B]
  cancel : @moonui.Widget[B]
  /// 当前编辑的那条曲的 path（`""` = 没打开任何一首）
  mut path : String
}

///|
/// 编辑窗的固定尺寸。窄而矮——三行输入加一颗保存钮，不需要更大；也刻意
/// **不进 `CmLayout`**（那是六只常驻窗的落座表，加进去要连带改
/// `reset_windows` 与布局断言），打开时按主窗位置现算一次居中。
pub fn cm_edit_size() -> @moonui.LogicalSize {
  @moonui.LogicalSize(340.0, 196.0)
}

///|
/// 建编辑窗（不显示）。三个回调：保存 / 取消（都收 path + 三个值由调用方读，
/// 这里只负责把它们交出去）。
pub fn[B : @moonui.Backend] EditDialog::new(
  b : B,
  app : @moonui.App[B],
  on_save : (String, String, String, String) -> Unit,
  on_cancel : () -> Unit,
) -> EditDialog[B] raise @moonui.UiError {
  let size = cm_edit_size()
  let window = app.create_window("编辑信息", size)
  let _ = window.set_resizable(false) catch { _ => () }
  let _ = window.set_titlebar_style(Immersive) catch { _ => () }
  let title_in = @moonui.Widget::text_input(b, "")
  let artist_in = @moonui.Widget::text_input(b, "")
  let album_in = @moonui.Widget::text_input(b, "")
  let ok = @moonui.Widget::button(b, "保存")
  let cancel = @moonui.Widget::button(b, "取消")
  cm_flat_btn(ok, cm_accent(), cm_text_light(), 10.0)
  cm_flat_btn(cancel, cm_zebra(), cm_ink(), 10.0)
  // 三行"标签 + 输入框"：标签固定 44 宽，输入框吃剩余宽度。
  let rows : Array[@moonui.Widget[B]] = []
  let labels = ["标题", "歌手", "专辑"]
  let inputs = [title_in, artist_in, album_in]
  for i, w in inputs {
    let lbl = @moonui.Widget::label(b, labels[i])
      .font_size(10.0)
      .foreground(cm_ink())
    rows.push(
      @moonui.Widget::row(b, 6.0, [
        @moonui.Widget::sized(b, Some(44.0), Some(22.0), lbl),
        @moonui.Widget::sized(b, None, Some(22.0), w).with_expand(true),
      ]),
    )
  }
  let btn_row = @moonui.Widget::row(b, 6.0, [
    @moonui.Widget::spacer(b).with_expand(true),
    @moonui.Widget::sized(b, Some(70.0), Some(22.0), cancel),
    @moonui.Widget::sized(b, Some(70.0), Some(22.0), ok),
  ])
  let body = @moonui.Widget::column(b, 6.0, [
    rows[0],
    rows[1],
    rows[2],
    @moonui.Widget::spacer(b).with_expand(true),
    btn_row,
  ])
  let dialog : EditDialog[B] = {
    window,
    title_in,
    artist_in,
    album_in,
    ok,
    cancel,
    path: "",
  }
  let _ = ok.with_on_click(fn() {
    on_save(
      dialog.path,
      dialog.title_in.text() catch {
        _ => ""
      },
      dialog.artist_in.text() catch {
        _ => ""
      },
      dialog.album_in.text() catch {
        _ => ""
      },
    )
  })
  let _ = cancel.with_on_click(fn() { on_cancel() })
  let strip = CmStrip::new(b, "编辑信息", fn() { on_cancel() })
  let root = cm_window_shell(b, strip.root, body, 8.0)
  window.set_content(root)
  dialog
}

///|
/// 打开编辑窗并预填三个字段。`show()` 是 `makeKeyAndOrderFront:`，所以只在
/// 用户点菜单那一下调一次，不能放进每拍的刷新里。
pub fn[B : @moonui.Backend] EditDialog::open(
  self : EditDialog[B],
  t : Track,
  anchor : @moonui.Window[B],
) -> Unit raise @moonui.UiError {
  self.path = t.path
  let _ = self.title_in.set_text(t.title)
  let _ = self.artist_in.set_text(t.artist)
  let _ = self.album_in.set_text(t.album)
  // 按主窗位置居中算一次（不记忆拖动位置：这是"要不要关掉"的临时窗）。
  let p = anchor.position() catch { _ => @moonui.LogicalPoint(0.0, 0.0) }
  let s = anchor.size() catch { _ => @moonui.LogicalSize(380.0, 700.0) }
  let me = cm_edit_size()
  let _ = self.window.set_position(
    @moonui.LogicalPoint(
      p.x + (s.width - me.width) / 2.0,
      p.y + (s.height - me.height) / 2.0,
    ),
  )
  self.window.show()
}

///|
/// 关窗（保存成功或用户取消）。不清 `path`：保存成功后调用方还要读它。
pub fn[B : @moonui.Backend] EditDialog::close(self : EditDialog[B]) -> Unit {
  self.window.hide() catch {
    _ => ()
  }
}
