///|
/// 在线取词的**网络半**（`T158`，native 目标限定，moon.pkg targets 门控）。
///
/// 分层的账与音频那条一模一样：决策全在无头可测的纯逻辑里
/// （`examples/lunamusic/lrclib.mbt` 的 `online_lyrics_plan` /
/// `online_lyrics_step`），本文件只干三件事——发请求、把响应体喂回决策机、
/// 把结果投回主循环。所以这一层没有可测的判断，测试压在纯逻辑那侧。
///
/// **线程模型**（本次唯一的新地基，owner 指定用官方异步库）：
/// `moonbitlang/async` 的 `run_async_main` 会独占调用它的线程跑自己的事件
/// 循环（`with_event_loop` 内部只允许一个循环，而且循环登记是**进程级**的，
/// 不是线程局部）。GUI 主线程要跑 MoonUI 的泵，不能交出去，所以整条取词走一次
/// worker 线程：worker 里 `run_async_main` 发 HTTP、跑完决策机，`land` 闭包回到
/// 主循环把结果交给 App。worker 那套（incref/decref + 投递纪律）是 `T85①`
/// 打过底的原语，不新造机制。
///
/// **关于 `ExternalEventLoop`**：0.22.6 提供这个形状（`poll(timeout?)` +
/// `get_wakeup_callback_for_foreign_thread()` + `terminate()`），把调度器直接
/// 挂到宿主自己的事件循环上，不再需要第二条线程。0.22.6 最初装不上（本机 core
/// 没有 `moonbitlang/core/async`），实现按当时能用的 0.20.0 形状落在 worker
/// 线程上；工具链升级到 core 0.10.18 之后 0.22.6 能装了，但**这套不入主循环是
/// 有意的**：把调度器挂进 MoonUI 的泵意味着主线程要按 async 的节奏醒，而那条
/// 泵现在同时被 500ms 进度心跳与 33ms 频谱链按自己的时刻表驱动（`T152` 的
/// `post_after`），两套"什么时候该醒"的账混在一起是更难查的 bug 面。
/// worker 线程那条路已经被真实 HTTPS 与门禁验证过，代价只是每次调用现起一套
/// 事件循环（建管道、线程池、装信号处理器）——所以一次换歌只发**一轮**请求，
/// 不做长驻连接池，也不为同一首歌重试。真要收掉这份开销时再换
/// `ExternalEventLoop`，形状已经在这里留好。

///|
/// 取词的整体预算：超过就当没查到。换歌是高频动作，一轮请求卡住几秒以上，
/// 下一首已经在播了，这份词来了也没人看。
pub fn online_lyrics_budget_ms() -> Int32 {
  8000
}

///|
/// lrclib 的礼貌要求是带一个能认出调用方的 User-Agent（它们按 UA 做限流与
/// 封禁判断，空 UA 会被直接 403）。
fn online_lyrics_ua() -> String {
  "LunaMusic/0.1 (MoonUI; +https://github.com/lunamusic)"
}

///|
/// 取一首歌的在线歌词。**立即返回**，结果在 `on_done` 里回主循环。
///
/// `candidates` 是 `@lunamusic.tag_query_candidates` 给的有序候选表（已经按
/// 「两种都查，命中优先」排好）；`duration_s` 是探针读出的时长（0 = 未知）。
/// `on_done(path, lrc)` 的 `path` 原样回传，调用方据此判"这份词还是不是当前
/// 那首的"——换歌之后才回来的旧结果必须丢掉，否则会把上一首的词贴到这一首
/// 上（与 `T153` 的 `lit_path` 同一个教训）。
///
/// 起不来线程只打印一行，不 raise：取词失败不该影响播放。
pub fn[B] fetch_online_lyrics(
  app : @moonui.App[B],
  path : String,
  candidates : Array[(String, String)],
  duration_s : Double,
  on_done : (String, String?) -> Unit,
) -> Unit {
  let plan = @lunamusic.online_lyrics_plan(candidates, duration_s)
  if plan.length() == 0 {
    // 候选表全空（连歌名都没有）：不发请求，直接回 None
    let _ = app.post(fn() { on_done(path, None) })
    return
  }
  // worker 与 land 之间只搬这一个格子；闭包生命周期由 worker_run 的
  // incref/decref 看守（`T85①`），这里不额外持有
  let box : OnlineBox = { lrc: None, }
  @native-common.worker_run(
    app,
    fn() {
      box.lrc = online_lyrics_fetch_blocking(plan, candidates, duration_s)
    },
    fn() { on_done(path, box.lrc) },
  ) catch {
    _ => () // 线程没起来：当作没查到
  }
}

///|
/// worker 与 land 之间搬结果用的格子（`T85①` 的 FoundBox 同款）。
priv struct OnlineBox {
  mut lrc : String?
}

///|
/// 手动搜索歌词（`T161`）：把 `/api/search` 的结果**全部**搬回主循环。
///
/// 与 `fetch_online_lyrics` 共用同一条线程纪律，但**不复用**它的决策机：
/// `online_lyrics_plan`/`online_lyrics_step` 是"自动挑一条"的形状（get 优先、
/// 打分挑选、命中即收工），而人工搜索要的正好相反——一次请求、原序全列、
/// 由用户双击决定。硬套那台状态机只会把"全列出来"拆成"挑一条再全列一遍"。
///
/// 只发一条请求（`/api/search`，不带 duration：人工搜索时用户填的是名字，
/// 不是那一首的确切时长），所以也不需要 plan 那种逐条串行的循环。
///
/// `on_done` 总是会被回调（失败给空数组），弹窗据此把状态行从"查询中…"
/// 改成"没找到"——静默不回会让用户对着"查询中…"发呆。
pub fn[B] fetch_lyric_search(
  app : @moonui.App[B],
  title : String,
  artist : String,
  on_done : (Array[@lunamusic.LyricSearchResult]) -> Unit,
) -> Unit {
  let box : LyricSearchBox = { results: [], }
  @native-common.worker_run(
    app,
    fn() {
      box.results = lyric_search_blocking(
        @lunamusic.lrclib_search_url(@lunamusic.OnlineLyricQuery::{
          title,
          artist,
          duration_s: 0.0,
        }),
      )
    },
    fn() { on_done(box.results) },
  ) catch {
    _ => {
      // 线程没起来：当作没查到，但照样回一次，别让状态行僵在"查询中…"
      let _ = app.post(fn() { on_done([]) })
    }
  }
}

///|
/// worker 与 land 之间搬结果用的格子（`OnlineBox` 同款，装的是数组）。
priv struct LyricSearchBox {
  mut results : Array[@lunamusic.LyricSearchResult]
}

///|
/// worker 线程上的整条流程：一条请求、一次解析、返回。失败给空数组。
fn lyric_search_blocking(url : String) -> Array[@lunamusic.LyricSearchResult] {
  let out : Ref[Array[@lunamusic.LyricSearchResult]] = Ref([])
  @async.run_async_main(async fn() {
    match online_lyrics_fetch_one(url) {
      Some(body) => out.val = @lunamusic.lyric_search_results(body)
      None => ()
    }
  })
  out.val
}

///|
/// worker 线程上的整条流程：**阻塞**到取完或超时。
///
/// `run_async_main` 会在这里把 async 事件循环跑起来然后收掉，所以本函数正常
/// 返回就代表循环已经清理干净了。它自己 catch 住一切：worker 闭包 raise 会
/// 跨 C 帧，那是未定义行为（`T85①` 的纪律），所以整条包在 try 里。
fn online_lyrics_fetch_blocking(
  plan : Array[(Int32, Bool, String)],
  candidates : Array[(String, String)],
  duration_s : Double,
) -> String? {
  let out : Ref[String?] = Ref(None)
  // run_async_main 自己不 raise（它内部 catch 到底并 exit），所以这里不套 try
  @async.run_async_main(async fn() {
    let r = online_lyrics_run_plan(plan, candidates, duration_s)
    out.val = r
  })
  out.val
}

///|
/// 决策机的执行端：反复问 `online_lyrics_step` 要下一条 URL，取回来接上。
///
/// 循环长度由 plan 固定（每轮 `responses` 长一格，而 step 只在
/// `responses` 用尽时才给 Fetch），不会空转。
async fn online_lyrics_run_plan(
  plan : Array[(Int32, Bool, String)],
  candidates : Array[(String, String)],
  duration_s : Double,
) -> String? {
  let responses : Array[String?] = []
  while true {
    match
      @lunamusic.online_lyrics_step(plan, candidates, duration_s, responses) {
      @lunamusic.OnlineStep::Done(lrc) => return Some(lrc)
      @lunamusic.OnlineStep::GiveUp => return None
      @lunamusic.OnlineStep::Fetch(url) => {
        let body = online_lyrics_fetch_one(url)
        responses.push(body)
      }
    }
  }
  None
}

///|
/// 取一个 URL 的响应体。失败一律 `None`——404（这首歌没有）、503（服务器
/// 限流）、连不上、超时，在调用方眼里都是同一件事：这一条没查到，换下一条。
///
/// 超时用 `with_timeout` 卡在单条请求上；整轮的预算由 plan 长度 × 单条超时
/// 自然封顶（候选最多 4 条——两种切法 × 剥/不剥括注——× 2 个端点 = 8 次，
/// 最坏 8 × 8 秒；实际上第一个精确命中就返回了，而 404 是毫秒级的）。
async fn online_lyrics_fetch_one(url : String) -> String? {
  // `async@0.22.6` 把 headers 的键换成了 `@http.CaseInsensitiveString`
  // （`Headers = Map[CaseInsensitiveString, String]`）——HTTP 头名本来就不分
  // 大小写，这条类型把这件事挪进了类型系统。字面量可以隐式转换，所以键直接
  // 写字符串；显式标注会要求包外类型名，得不偿失。
  let headers : @http.Headers = Map::from_array([
    ("User-Agent", online_lyrics_ua()),
    ("Accept", "application/json"),
  ])
  let body : Ref[String?] = Ref(None)
  @async.with_timeout(online_lyrics_budget_ms(), async fn() {
    let (resp, data) = @http.get(url, headers~)
    if resp.code == 200 {
      body.val = Some(data.text())
    }
  }) catch {
    _ => () // 超时 / 连接失败 / 服务器错误：这一条按没查到处理
  }
  body.val
}
