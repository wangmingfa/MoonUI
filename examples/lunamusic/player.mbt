///|
/// 播放器状态（DESIGN.md C-08）：Loading 折进 start_at 的装歌流程里，
/// 对外只有三态。
pub(all) enum PlayerState {
  Idle
  Playing
  Paused
} derive(Debug, Eq)

///|
/// 播放失败（`T186`）：记下"刚才那首为什么没播起来"，由界面翻译成一句人话。
///
/// 此前这些失败在 `start_at` 的 `catch` 里被静默吃掉——格式不支持（`T166` 的
/// ogg）、文件已被删除、文件损坏，在界面上**都是"点了没反应"**。这一层只记
/// 事实（谁装不上 / 整队列都装不上），怎么说给用户听归 `display.mbt`。
///
/// 放 **path** 而不是 `Track`：这条错误的唯一出路是显示（按当前显示口径算
/// 名字），而 `Track` 里的 `cover` 是整张封面字节，塞进一个每次广播都要比对
/// 的枚举里毫无必要。
pub(all) enum PlayerError {
  /// 这一首装不上（载荷是它的 **path**）
  ///
  /// 记 path 而不是歌名，是因为歌名怎么显示归 `DisplaySource` 管（`T193`）——
  /// 用户选了"文件名"口径时界面显示的是文件名，这里记标签名就对不上。界面
  /// 侧拿 path 回队列里查，才能按当前口径算出同一份显示名。
  LoadFailed(String)
  /// 整份队列都装不上，已止损停机
  AllFailed
} derive(Debug, Eq)

///|
/// 播放状态机（DESIGN.md C-08 行为表的逐条实现），泛型注入 AudioEngine。
/// 纯逻辑零 UI：状态变化通过 notify 回调广播，由壳/应用侧拉读最新状态。
pub(all) struct Player[A] {
  engine : A
  mut queue : Array[Track]
  mut current : Int32?
  mut state : PlayerState
  mut mode : PlayMode
  mut volume : Int32
  /// 随机播放走过的轨迹——上一首靠它回退。
  history : Array[Int32]
  /// 随机模式的洗牌牌堆：不重复直到放完一轮，空了再洗。
  deck : Array[Int32]
  /// 洗牌用的随机源（`T167`）：`new` 里起的是**真随机**（`@random.Rand()`
  /// 向平台熵源要种子，wasm-gc 拿不到熵时退到 core 的固定种子——仍是真洗牌，
  /// 只是进程内可复现）。测试用 `set_shuffle_rng` 换成固定种子钉住顺序。
  mut rng : @random.Rand
  /// 状态/进度变化时广播（UI 拉读），一处回调避免散装监听。
  mut notify : (() -> Unit)?
  /// 连续 load 失败计数：整队列都装不上时止损停机，防死循环。
  mut load_fail_streak : Int32
  /// 上一首歌为什么没播起来（`T186`）。成功装上并开播、用户主动按停止、
  /// 或者队列被整体换掉之后清空——那三种情形下留着旧错误只会骗人。
  mut last_error : PlayerError?
}

///|
pub fn[A : AudioEngine] Player::new(
  engine : A,
  queue : Array[Track],
) -> Player[A] {
  let p : Player[A] = {
    engine,
    queue,
    current: None,
    state: Idle,
    mode: Sequential,
    volume: 1000,
    history: [],
    deck: [],
    rng: @random.Rand(),
    notify: None,
    load_fail_streak: 0,
    last_error: None,
  }
  // 播完回调一次接线；闭包持有 player 的字段而非 self，避免自引用
  engine.on_finished(fn() { p.handle_finished() })
  p
}

///|
/// 状态变化通知通道：应用侧装配时挂上，player 每次状态迁移后调用。
pub fn[A] Player::on_update(self : Player[A], cb : () -> Unit) -> Unit {
  self.notify = Some(cb)
}

///|
fn[A] Player::broadcast(self : Player[A]) -> Unit {
  match self.notify {
    Some(cb) => cb()
    None => ()
  }
}

///|
/// 队列被库扫描增删后整体替换；当前曲还在就保住高亮，否则回 Idle。
pub fn[A : AudioEngine] Player::replace_queue(
  self : Player[A],
  queue : Array[Track],
) -> Unit {
  let old = self.current
  self.queue = queue
  match old {
    Some(i) =>
      if i < queue.length() {
        if queue[i].path != self.now_path() {
          // 同位置已是别的歌：找不到旧歌就停
          self.stop_all(false)
        }
      } else {
        self.stop_all(false)
      }
    None => ()
  }
  self.history.clear()
  self.deck.clear()
  // 队列换了，上一份队列里的失败没意义了（`T186`）
  self.last_error = None
  self.broadcast()
}

///|
/// 视图变化（页签切换 / 排序 / 搜索）后把队列换成新视图，但**按 path 保住正在
/// 播的那一首**：排序只挪位置、不该让歌重头播，更不该把播着的歌踢出队列。
/// 新视图里找不到当前曲时整段不动——搜索把正在播的歌过滤掉了，队列不能跟着
/// 缩水（调用方想强制换队列时用 `replace_queue`）。
pub fn[A] Player::set_queue_keep_current(
  self : Player[A],
  queue : Array[Track],
) -> Unit {
  let cur = self.now_path()
  if cur != "" {
    let mut hit = -1
    for i, t in queue {
      if t.path == cur {
        hit = i
        break
      }
    }
    if hit < 0 {
      return
    }
    self.queue = queue
    self.current = Some(hit)
  } else {
    self.queue = queue
  }
  self.history.clear()
  self.deck.clear()
}

///|
/// 就地换掉队列里同 path 那条的元数据（DESIGN.md C-16）。
///
/// **不能用 `replace_queue` / `set_queue_keep_current`**：那两个都会
/// `history.clear()` + `deck.clear()`，改一个歌名把随机播放的牌堆和历史清掉
/// 是不可接受的副作用。这里只按 path 换元素，位置、当前下标、播放状态
/// 一律不动，然后广播一次让播放条/迷你条拉读新文案。
///
/// 改的若正是正在播的那首，`track()` 立刻返回新值——不需要重装引擎，
/// 播放不中断、进度不回零。
pub fn[A] Player::update_track_meta(self : Player[A], t : Track) -> Unit {
  for i, q in self.queue {
    if q.path == t.path {
      self.queue[i] = t
    }
  }
  self.broadcast()
}

///|
/// 当前曲目的完整元数据。
pub fn[A] Player::track(self : Player[A]) -> Track? {
  match self.current {
    Some(i) if i < self.queue.length() => Some(self.queue[i])
    _ => None
  }
}

///|
fn[A] Player::now_path(self : Player[A]) -> String {
  match self.track() {
    Some(t) => t.path
    None => ""
  }
}

///|
/// 装歌并开播；装不上按「下一首」规则跳（C-10 风险 4 的播放侧：逐首隔离）。
///
/// `T186` 的错误记录有个容易写错的地方：**成功这一支不清 `last_error`**。
/// 点第 1 首、它坏了、自动跳到第 2 首播起来——这时该留下的是"第 1 首装不上"
/// 而不是一句"没事"。清错误的时机在**用户发起播放的那几个入口**（`toggle` /
/// `prev` / `next` / `play_index` / 自然播完），语义是"用户又试了一次，旧的
/// 那句话不再代表当前状态"。若在这里清，失败恢复那条递归会把刚记的原因顺手
/// 抹掉，界面上就只剩"第 2 首在播"，用户永远不知道第 1 首为什么没播。
fn[A : AudioEngine] Player::start_at(self : Player[A], idx : Int32) -> Unit {
  if idx < 0 || idx >= self.queue.length() {
    return
  }
  // 高亮先落位再装：坏文件也能从 pick_next 继续往前走（不落位会无限重试 0）
  self.current = Some(idx)
  try {
    let loaded = self.engine.load(self.queue[idx].path)
    // 装引擎这一趟把封面解出来了（`T174`）。曲库档不落封面字节（体积，见
    // `Library::to_json`），重启后队列里那份是 `cover: None`——这里丢掉就
    // 永远显示不出来，所以补进队列。
    // **只补封面**：文本字段一律以队列为准。用户可能刚用「编辑标签」改过
    // 歌名/歌手，一次 load 把扫描结果回填会把编辑覆盖回去（`T193` 之后
    // 这条更要紧：显示口径也吃这几个字段）。
    if loaded.cover is Some(c) {
      let q = self.queue[idx]
      if q.cover is None {
        self.queue[idx] = {
          path: q.path,
          title: q.title,
          artist: q.artist,
          album: q.album,
          duration_ms: q.duration_ms,
          cover: Some(c),
        }
      }
    }
    self.load_fail_streak = 0
    self.push_history(idx)
    try {
      self.engine.play()
      self.state = Playing
    } catch {
      _ => self.state = Idle
    }
    self.broadcast()
  } catch {
    _ => {
      self.load_fail_streak = self.load_fail_streak + 1
      // 记下"这一首装不上"（`T186`）：界面据此说话。写在这里而不是停止之后，
      // 是因为下面立刻要递归跳下一首——那一趟若成功会把 `last_error` 清掉，
      // 最终留下的是"最后那一首为什么不行"，正好是用户想知道的。
      self.last_error = Some(LoadFailed(self.queue[idx].path))
      if self.load_fail_streak >= self.queue.length() {
        // 整队列都装不上：止损。`AllFailed` 比"最后一首的名字"更有用——
        // 连跳一整轮都没成，问题多半不在某一个个别文件上。
        self.last_error = Some(AllFailed)
        self.stop_all(false)
      } else {
        self.start_at(self.pick_next(false))
      }
    }
  }
}

///|
fn[A] Player::push_history(self : Player[A], idx : Int32) -> Unit {
  self.history.push(idx)
  if self.history.length() > 64 {
    let _ = self.history.remove(0)
  }
}

///|
/// 按模式取下一首下标（不迁移状态）。
/// auto=false 是用户按「下一首」：顺序/随机到尾都回绕；
/// auto=true 是自然播完：顺序到尾停（返回 -1 表示停）。
pub fn[A] Player::pick_next(self : Player[A], auto : Bool) -> Int32 {
  let cur = match self.current {
    Some(i) => i
    None => return 0 // 空态从头
  }
  let n = self.queue.length()
  if n == 0 {
    return -1
  }
  match self.mode {
    RepeatOne => if auto { cur } else { (cur + 1) % n }
    Sequential => if cur + 1 < n { cur + 1 } else if auto { -1 } else { 0 }
    Shuffle => {
      if self.deck.length() == 0 {
        // 洗一副新牌：全队列随机序，当前曲排头
        self.reshuffle(cur, n)
      }
      if self.deck.length() > 0 {
        self.deck.remove(0)
      } else if auto {
        -1 // 放完一轮：自然结束停机
      } else {
        0 // 手动到尾回绕
      }
    }
  }
}

///|
/// 洗牌：把除当前曲外的所有下标随机排列进牌堆（Fisher-Yates）。
///
/// `T167` 之前这里只按顺序压入、注释还写着"core 没有随机数……真随机放壳层
/// （FP3 注入 seed 通道）"——而那条壳侧注入从来没接，于是 `Shuffle` 与
/// `Sequential` 行为等价，用户按了随机听到的还是原顺序。`@random` 一直都在
/// （`Rand::shuffle` 是现成的 Fisher-Yates），本机直接洗，不再等壳。
///
/// 随机源是 `Player` 的 `rng`：生产默认 `@random.Rand()`（平台熵源），
/// 测试用 `set_shuffle_rng` 换固定种子，两边都不牺牲。
fn[A] Player::reshuffle(self : Player[A], cur : Int32, n : Int32) -> Unit {
  self.deck.clear()
  for i = 0; i < n; i = i + 1 {
    if i != cur {
      self.deck.push(i)
    }
  }
  // 洗整副牌（已排除当前曲）：Fisher-Yates 一遍下来每张牌落哪个位置等概率，
  // 且「不重复直到放完一轮」的集合语义由牌堆本身保证（洗的是下标池，不是抽样）。
  let deck = self.deck
  self.rng.shuffle(deck.length(), fn(i : Int32, j : Int32) {
    let t = deck[i]
    deck[i] = deck[j]
    deck[j] = t
  })
}

///|
/// 换洗牌随机源（测试用）：固定种子让 `Shuffle` 顺序可断言。
/// 生产路径不调它——`Player::new` 起的已经是真随机。
pub fn[A] Player::set_shuffle_rng(self : Player[A], rng : @random.Rand) -> Unit {
  self.rng = rng
}

///|
/// 上一首下标：有轨迹回退，没有就回绕到队尾。
fn[A] Player::pick_prev(self : Player[A]) -> Int32 {
  let n = self.queue.length()
  if n == 0 {
    return -1
  }
  // 弹掉当前曲自己的轨迹项，再取上一个
  if self.history.length() > 0 {
    let _ = self.history.pop()
  }
  match self.history.pop() {
    Some(i) => i
    None =>
      match self.current {
        Some(i) => if i > 0 { i - 1 } else { n - 1 }
        None => n - 1
      }
  }
}

///|
/// 播放/暂停键（行为表第一行）。
pub fn[A : AudioEngine] Player::toggle(self : Player[A]) -> Unit {
  match self.state {
    Playing => {
      self.engine.pause()
      self.state = Paused
      self.broadcast()
    }
    Paused => {
      try {
        self.engine.unpause()
        self.state = Playing
      } catch {
        _ => ()
      }
      self.broadcast()
    }
    Idle => {
      // 用户又发起了一次播放（`T186`）：上一句"装不上"不再代表当前状态
      self.last_error = None
      match self.current {
        Some(i) => self.start_at(i)
        None => self.start_at(0)
      }
    }
  }
}

///|
/// 停止键（Luna的 ■）：撤声回 Idle，保住当前曲高亮（再按播放从头播）。
///
/// 顺带清掉上一次的播放失败（`T186`）：这是**用户主动**的动作，界面上还挂着
/// 一句"无法播放：xxx"会让人以为按钮没生效。
pub fn[A : AudioEngine] Player::stop(self : Player[A]) -> Unit {
  self.last_error = None
  self.stop_all(true)
}

///|
/// 上一首：位置 >3s 回开头，否则切上一首；Idle 时播队列尾（行为表第二行）。
pub fn[A : AudioEngine] Player::prev(self : Player[A]) -> Unit {
  match self.state {
    Idle => {
      let n = self.queue.length()
      if n > 0 {
        self.last_error = None
        self.start_at(n - 1)
      }
    }
    _ =>
      if self.engine.position() > 3000L && self.current is Some(_) {
        self.engine.seek(0L)
        self.broadcast()
      } else {
        let i = self.pick_prev()
        if i >= 0 {
          self.last_error = None
          self.start_at(i)
        }
      }
  }
}

///|
/// 下一首（手动）：按模式取，到尾回绕。
pub fn[A : AudioEngine] Player::next(self : Player[A]) -> Unit {
  let i = self.pick_next(false)
  if i >= 0 {
    self.last_error = None
    self.start_at(i)
  }
}

///|
/// 双击列表行：该行成为当前，从头播。
pub fn[A : AudioEngine] Player::play_index(
  self : Player[A],
  idx : Int32,
) -> Unit {
  // 用户点了某一首（`T186`）：先把上一句"装不上"撤掉，再装。装不上的话
  // `start_at` 会重新记一条，界面上说的就是**这一次**点的那首。
  self.last_error = None
  self.start_at(idx)
}

///|
/// 进度拖动：seek 后保持原状态（行为表第五行）。
pub fn[A : AudioEngine] Player::seek(self : Player[A], ms : Int64) -> Unit {
  self.engine.seek(ms)
  self.broadcast()
}

///|
/// 模式循环：顺序 → 单曲循环 → 随机 → 回顺序（C-08）。
pub fn[A] Player::cycle_mode(self : Player[A]) -> Unit {
  self.mode = self.mode.next()
  self.deck.clear() // 换模式作废旧牌堆
  self.broadcast()
}

///|
pub fn[A : AudioEngine] Player::set_volume(
  self : Player[A],
  permille : Int32,
) -> Unit {
  let v = if permille < 0 {
    0
  } else if permille > 1000 {
    1000
  } else {
    permille
  }
  self.volume = v
  self.engine.set_volume(v)
  self.broadcast()
}

///|
/// 自然播完回调：按模式取下一首；顺序到尾则停（行为表第四行）。
fn[A : AudioEngine] Player::handle_finished(self : Player[A]) -> Unit {
  if self.mode is RepeatOne {
    // 单曲循环：从头再播
    self.engine.seek(0L)
    self.engine.play() catch {
      _ => ()
    }
    self.broadcast()
    return
  }
  let i = self.pick_next(true)
  if i >= 0 {
    // 自然播完切下一首也算"新的一次播放"（`T186`）：上一首是正常播完的，
    // 它那条"装不上"本来就该翻篇
    self.last_error = None
    self.start_at(i)
  } else {
    self.state = Idle
    self.broadcast()
  }
}

///|
/// 全停：撤声、清高亮按需。
fn[A : AudioEngine] Player::stop_all(self : Player[A], keep : Bool) -> Unit {
  self.engine.stop()
  self.state = Idle
  if !keep {
    self.current = None
  }
  self.broadcast()
}

///|
/// 装上一首**但不播**，并跳到指定位置（`T184` 的恢复路径）。
///
/// "记住上次播到哪儿"与"启动自动开播"是两件事：这里装引擎是为了让时长、
/// 进度条、封面、状态行都显示真实值（不装就全是"未播放"），seek 是为了让进度
/// 落在上次的位置；**不调 play**，所以用户看到的是一首停在那儿的曲目，按下
/// 播放键从那里继续。
///
/// 状态记 `Paused` 而不是 `Idle`：`toggle` 的 `Idle` 分支会走 `start_at` →
/// 重新 `load`，而 `load` 把引擎位置归零——记 Idle 就等于每次续播都从头开始，
/// `seek` 白做。`Paused` 分支走 `unpause`，从引擎当前位置起来，正是想要的。
///
/// 装不上（文件被删/损坏）记一条 `last_error` 就停，**不跳下一首**：启动时
/// 用户没点任何东西，把队列从头试一遍没有意义，那句话挂在状态行上等人看见。
pub fn[A : AudioEngine] Player::prepare(
  self : Player[A],
  idx : Int32,
  at_ms : Int64,
) -> Unit {
  if idx < 0 || idx >= self.queue.length() {
    return
  }
  self.current = Some(idx)
  self.last_error = None
  try {
    let loaded = self.engine.load(self.queue[idx].path)
    // 与 `start_at` 同一条：只补封面，文本字段以队列为准
    if loaded.cover is Some(c) {
      let q = self.queue[idx]
      if q.cover is None {
        self.queue[idx] = {
          path: q.path,
          title: q.title,
          artist: q.artist,
          album: q.album,
          duration_ms: q.duration_ms,
          cover: Some(c),
        }
      }
    }
    self.load_fail_streak = 0
    // 按**真实时长**夹一次：档里的位置可能来自一次编辑过标签的文件（时长变了）
    // 或者手改坏档。夹在这里而不是读档那处，是因为只有装完引擎才知道时长。
    let dur = self.engine.duration()
    let mut at = if at_ms > 0L { at_ms } else { 0L }
    if dur > 0L && at >= dur {
      // 到尾了就从头（不然一进来就"播完"，按 ▶ 立刻又结束）
      at = 0L
    }
    if at > 0L {
      self.engine.seek(at)
    }
    self.state = Paused
    self.broadcast()
  } catch {
    _ => {
      self.last_error = Some(LoadFailed(self.queue[idx].path))
      self.state = Idle
      self.broadcast()
    }
  }
}

///|
pub fn[A : AudioEngine] Player::position(self : Player[A]) -> Int64 {
  self.engine.position()
}

///|
pub fn[A : AudioEngine] Player::duration(self : Player[A]) -> Int64 {
  self.engine.duration()
}

///|
pub fn[A] Player::is_playing(self : Player[A]) -> Bool {
  self.state is Playing
}

///|
/// 上一首歌为什么没播起来（`T186`）；`None` = 最近一次装歌是成功的。
///
/// 这是个**粘性**状态：置上之后一直留着，直到下一次装歌成功 / 用户按停止 /
/// 队列被整体换掉。粘着是想要的——错误提示一闪而过等于没提示，用户松手去
/// 看列表的时候字已经没了。
pub fn[A] Player::last_error(self : Player[A]) -> PlayerError? {
  self.last_error
}
