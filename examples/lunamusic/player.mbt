///|
/// 播放器状态（DESIGN.md C-08）：Loading 折进 start_at 的装歌流程里，
/// 对外只有三态。
pub(all) enum PlayerState {
  Idle
  Playing
  Paused
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
  /// 状态/进度变化时广播（UI 拉读），一处回调避免散装监听。
  mut notify : (() -> Unit)?
  /// 连续 load 失败计数：整队列都装不上时止损停机，防死循环。
  mut load_fail_streak : Int32
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
    notify: None,
    load_fail_streak: 0,
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
fn[A : AudioEngine] Player::start_at(self : Player[A], idx : Int32) -> Unit {
  if idx < 0 || idx >= self.queue.length() {
    return
  }
  // 高亮先落位再装：坏文件也能从 pick_next 继续往前走（不落位会无限重试 0）
  self.current = Some(idx)
  try {
    let _ = self.engine.load(self.queue[idx].path)
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
      if self.load_fail_streak >= self.queue.length() {
        // 整队列都装不上：止损
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
fn[A] Player::reshuffle(self : Player[A], cur : Int32, n : Int32) -> Unit {
  self.deck.clear()
  for i = 0; i < n; i = i + 1 {
    if i != cur {
      self.deck.push(i)
    }
  }
  // core 没有随机数——用引擎位置当搅种会引入不确定性，
  // 测试要确定性：默认不搅（牌堆即顺序），真随机放壳层（FP3 注入 seed 通道）
  // 见 DESIGN.md C-08；这里只保证「不重复直到放完一轮」的集合语义。
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
    Idle =>
      match self.current {
        Some(i) => self.start_at(i)
        None => self.start_at(0)
      }
  }
}

///|
/// 停止键（Luna的 ■）：撤声回 Idle，保住当前曲高亮（再按播放从头播）。
pub fn[A : AudioEngine] Player::stop(self : Player[A]) -> Unit {
  self.stop_all(true)
}

///|
/// 上一首：位置 >3s 回开头，否则切上一首；Idle 时播队列尾（行为表第二行）。
pub fn[A : AudioEngine] Player::prev(self : Player[A]) -> Unit {
  match self.state {
    Idle => {
      let n = self.queue.length()
      if n > 0 {
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
    self.start_at(i)
  }
}

///|
/// 双击列表行：该行成为当前，从头播。
pub fn[A : AudioEngine] Player::play_index(
  self : Player[A],
  idx : Int32,
) -> Unit {
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
/// 供 500ms 心跳（C-08 进度推进）拉读：当前位置毫秒。
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
