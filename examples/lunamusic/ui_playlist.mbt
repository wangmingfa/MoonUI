///|
/// 「新建歌单 / 重命名歌单」小窗（`T175`）：一行名字输入 + 确定/取消。
///
/// 形状照「编辑信息」（`ui_edit.mbt`）那套：独立小窗（框架没有应用内模态）、
/// `CmStrip` + `cm_window_shell` 外壳、输入值不镜像（确定那一刻 `text()`
/// 现读）。与编辑窗一样**懒建一次复用**——整树重建会销毁原生输入控件，
/// 正在打的字全没；这只窗不进 `CmLayout`（六只常驻窗的落座表），打开时按
/// 锚窗位置现算居中。
pub(all) struct PlaylistNameDialog[B] {
  window : @moonui.Window[B]
  /// 顶条。文案在每次 `open` 时按本次用途换（「新建歌单」/「重命名歌单」），
  /// 不能停在建树那一刻（`T255`）。
  strip : CmStrip[B]
  name_in : @moonui.Widget[B]
  /// 确定回调（收输入框现读的名字）。重名/空名的拒绝账在 app 侧——
  /// 对话框只管把字交出去。
  ///
  /// `T255`：每次 `open` 都要刷新。窗是懒建一次复用的，回调若停在第一次
  /// 打开时那条，「重命名…」按确定跑的会是新建（真机现象：侧栏变成两条）。
  mut on_ok : (String) -> Unit
}

///|
pub fn cm_playlist_name_size() -> @moonui.LogicalSize {
  @moonui.LogicalSize(300.0, 110.0)
}

///|
/// 建名字窗（不显示）。`title` 是窗顶条文案（「新建歌单」/「重命名歌单」）。
pub fn[B : @platform-services.PlatformServices] PlaylistNameDialog::new(
  b : B,
  app : @moonui.App[B],
  title : String,
  on_ok : (String) -> Unit,
  on_cancel : () -> Unit,
) -> PlaylistNameDialog[B] raise @moonui.UiError {
  let window = app.create_window(title, cm_playlist_name_size())
  let _ = window.set_resizable(false) catch { _ => () }
  let _ = window.set_titlebar_style(Immersive) catch { _ => () }
  let name_in = @moonui.Widget::text_input(b, "")
  let ok = @moonui.Widget::button(b, "确定")
  let cancel = @moonui.Widget::button(b, "取消")
  cm_flat_btn(ok, cm_accent(), cm_text_light(), 10.0)
  cm_flat_btn(cancel, cm_zebra(), cm_ink(), 10.0)
  let strip = CmStrip::new(b, title, fn() { on_cancel() })
  let dialog : PlaylistNameDialog[B] = { window, strip, name_in, on_ok, }
  let _ = ok.with_on_click(fn() {
    (dialog.on_ok)(dialog.name_in.text() catch { _ => "" })
  })
  let _ = cancel.with_on_click(fn() { on_cancel() })
  let root = cm_window_shell(
    b,
    strip.root,
    @moonui.Widget::column(b, 6.0, [
      @moonui.Widget::row(b, 6.0, [
        @moonui.Widget::sized(
          b,
          Some(44.0),
          Some(22.0),
          @moonui.Widget::label(b, "名字")
          .font_size(10.0)
          .foreground(cm_ink()),
        ),
        @moonui.Widget::sized(b, None, Some(22.0), name_in).with_expand(true),
      ]),
      @moonui.Widget::spacer(b).with_expand(true),
      @moonui.Widget::row(b, 6.0, [
        @moonui.Widget::spacer(b).with_expand(true),
        @moonui.Widget::sized(b, Some(70.0), Some(22.0), cancel),
        @moonui.Widget::sized(b, Some(70.0), Some(22.0), ok),
      ]),
    ]),
    8.0,
  )
  window.set_content(root)
  dialog
}

///|
/// 打开并预填（新建传空串，重命名传旧名——多数时候用户只想改一两个字）。
///
/// `title` 与 `on_ok` 每次都给：窗是懒建复用的，两样都随本次用途刷新
/// （`T255`——不给的话第二次打开还是「新建歌单」+ 新建回调）。
pub fn[B : @platform-services.PlatformServices] PlaylistNameDialog::open(
  self : PlaylistNameDialog[B],
  title : String,
  prefill : String,
  on_ok : (String) -> Unit,
  anchor : @moonui.Window[B],
) -> Unit raise @moonui.UiError {
  self.on_ok = on_ok
  let _ = self.window.set_title(title)
  let _ = self.strip.title.set_text(title)
  let _ = self.name_in.set_text(prefill)
  let p = anchor.position() catch { _ => @moonui.LogicalPoint(0.0, 0.0) }
  let s = anchor.size() catch { _ => @moonui.LogicalSize(380.0, 700.0) }
  let me = cm_playlist_name_size()
  let _ = self.window.set_position(
    @moonui.LogicalPoint(
      p.x + (s.width - me.width) / 2.0,
      p.y + (s.height - me.height) / 2.0,
    ),
  )
  self.window.show()
}

///|
pub fn[B : @platform-services.PlatformServices] PlaylistNameDialog::close(
  self : PlaylistNameDialog[B],
) -> Unit {
  self.window.hide() catch {
    _ => ()
  }
}
