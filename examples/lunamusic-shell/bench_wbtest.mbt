///|
/// 固定种子的伪随机数（64 位 LCG，Deterministic——不引 core/random，壳包没这
/// 个依赖；本地算术就够）。返回值右移 33 位取高位，低位质量对"挑池子下标"
/// 这种用法绰绰有余。
fn bench_rnd() -> () -> Int64 {
  let mut s = 20261104L
  fn() {
    s = s * 6364136223846793005L + 1442695040888963407L
    s >> 33
  }
}

///|
/// T173 规模实测：万首曲库下各条用户路径的耗时。**打印数字、不设毫秒断言**
/// （这是测量不是回归判据——不同机器/负载下数字会漂，断言会把 CI 变成
/// 抽奖）。数据形状：标题混中西文（shortlex 下两族交错）、歌手/专辑走小
/// 池子（排序时同键大量同分，考验稳定排序的合并路径）、时长伪随机。
/// 时钟是 `native_time_ms`（毫秒整），1ms 以下的段落读作 0。
test "bench：万首曲库排序与搜索规模实测（T173，native only）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = @lunamusic.MockAudioEngine::new()
  let cm = @lunamusic.LunaMusicApp::new(app, engine)
  // ——造 10000 首——
  let n = 10000
  let rnd = bench_rnd()
  let tracks : Array[@lunamusic.Track] = []
  for i in 0..<n {
    let r = rnd()
    let title = if r % 4L == 0L { "歌曲\{i}" } else { "Track \{i}" }
    let artist = "artist \{r % 37L}"
    let album = "album \{r % 21L}"
    let dur = 120_000L + r % 240_000L
    tracks.push({
      path: "/m/t\{i}.mp3",
      title,
      artist,
      album,
      duration_ms: dur,
      cover: None,
    })
  }
  assert_eq(tracks.length(), n)
  // ——① merge_scan：并入 + 队列替换 + rebuild_ui 整树重建（启动/重扫那一趟）
  let mut t0 = @native-common.native_time_ms()
  cm.merge_scan("/m", tracks)
  let t1 = @native-common.native_time_ms()
  println(
    "[T173] ① merge_scan 10000 首（含 rebuild_ui 整树重建）：\{t1 - t0} ms",
  )
  assert_eq(cm.view.length(), n)
  // ——② compute_view 基线：ByIndex（比较器恒 0 的稳定排序 = 纯拷贝）+ 空查询过滤
  t0 = @native-common.native_time_ms()
  let v0 = cm.compute_view()
  let t2 = @native-common.native_time_ms()
  println(
    "[T173] ② compute_view 基线（原序 + 空查询）：\{t2 - t0} ms（\{v0.length()} 首）",
  )
  assert_eq(v0.length(), n)
  // ——③ 纯排序：lib.sorted(ByTitle)（不含 refresh，看排序本身）
  let mut best_title = 1 << 30
  let mut best_dur = 1 << 30
  for _rep in 0..<3 {
    t0 = @native-common.native_time_ms()
    let sv = cm.lib.sorted(@lunamusic.ByTitle, true)
    let t3 = @native-common.native_time_ms()
    best_title = if t3 - t0 < best_title { t3 - t0 } else { best_title }
    assert_eq(sv.length(), n)
  }
  for _rep in 0..<3 {
    t0 = @native-common.native_time_ms()
    let sv = cm.lib.sorted(@lunamusic.ByDuration, true)
    let t3 = @native-common.native_time_ms()
    best_dur = if t3 - t0 < best_dur { t3 - t0 } else { best_dur }
    assert_eq(sv.length(), n)
  }
  println(
    "[T173] ③ lib.sorted 纯排序（3 遍取最好）：标题 \{best_title} ms / 时长 \{best_dur} ms",
  )
  // ——④ 点列头全链路：set_sort（compute_view + sync_queue + refresh_table）
  for k in [1, 3] {
    t0 = @native-common.native_time_ms()
    cm.set_sort(k)
    let t3 = @native-common.native_time_ms()
    let key = if k == 1 { "标题" } else { "时长" }
    println(
      "[T173] ④ set_sort(\{k}) 全链路（\{key}列）：\{t3 - t0} ms",
    )
  }
  // 回原序：比较器恒 0，稳定排序应当"不洗牌"且最快
  t0 = @native-common.native_time_ms()
  cm.set_sort(0)
  let t4 = @native-common.native_time_ms()
  println(
    "[T173] ④ set_sort(0) 回原序（比较器恒 0）：\{t4 - t0} ms",
  )
  // ——⑤ 搜索逐字符：每敲一个字符全量扫 + refresh（用户敲 "Tra" 的三连击）
  for q in ["T", "Tr", "Tra", "歌曲", "zzzz无此曲"] {
    t0 = @native-common.native_time_ms()
    cm.query = q
    cm.view = cm.compute_view()
    // refresh_table 是私有 fn；这两步就是它的全部内容（T128 的就地改列表区）
    match cm.ui {
      Some(u) =>
        u.table.refresh(cm.view.length(), cm.tab_title(), cm.tab) catch {
          _ => ()
        }
      None => ()
    }
    let t3 = @native-common.native_time_ms()
    println(
      "[T173] ⑤ 搜索 \"\{q}\"（compute_view + refresh_table）：\{t3 - t0} ms，命中 \{cm.view.length()} 首",
    )
  }
  // 清干净，别把查询词留给同包其他测试（App 是本测试自建的，其实不漏，保险）
  cm.query = ""
  cm.view = cm.compute_view()
  @moonui.Backend::terminate(b)
}
