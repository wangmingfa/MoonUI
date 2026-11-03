///|
/// 配色档的整条落盘路（`T199` 文件半，native 目标限定——见 moon.pkg 的
/// targets 门控）。wasm 没有文件系统，这条在那一档结构性缺席，形状沿
/// `T88④`/`T86⑦` 的既定口径：门控与落盘机器同档，临时档自产自销。
///
/// 顺带把 `Settings::save` / `Settings::load` 这条还没判据的路走一遍——
/// `T197` 判的是内存里的读写与 `Fs` 的原子写，两者之间那一步"存盘再读回"
/// 一直没人走过。

///|
test "Palette：配色档落盘往返，坏值兜默认、坏档当没有档（T199）" {
  let path = temp_path("moonui_palette_native_test.json")
  let _ = Fs::remove(path)
  // 缺档 → None。与 `from_settings` 的兜底不同：这里要能区分"用户没配过"
  // （None）与"配了一份全默认的档"（Some(light)）。
  assert_eq(Palette::load(path), None)
  // 存下去再读回来，五格逐位相同
  let p = Palette::{
    background: Color::rgb(10, 10, 14),
    surface: Color::rgb(18, 18, 24),
    text: Color::rgb(240, 240, 245),
    accent: Color::rgb(255, 120, 0),
    border: Color::rgb(60, 60, 70),
  }
  p.to_settings().save(path)
  assert_eq(Palette::load(path), Some(p))
  // 档是好的、某一格写坏了：读得出来，坏那格兜默认（不是整份作废）
  Fs::write_text_atomic(path, "{\"accent\":\"oops\"}")
  assert_eq(Palette::load(path), Some(Theme::light_palette()))
  // 整档不是 JSON：按"没有档"处理——一个写坏的档不该让应用起不来
  Fs::write_text_atomic(path, "这不是 JSON")
  assert_eq(Palette::load(path), None)
  let _ = Fs::remove(path)
  assert_eq(Palette::load(path), None)
}
