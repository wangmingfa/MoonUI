# lunamusic 设计：一比一复刻本地音乐桌面端（第一期：本地音乐播放）

> 状态：设计定稿候选，未开工。落地后这份文档与 TODO 的对应关系：
> 每一期开工时挂一条 `Tnn`，完成注记回这里的小节号（`C-nn`，本文件的小节号
> 与仓库 DESIGN.md 的 `§nn` 互不干涉，本节号**不许重排**，新增往末尾追加）。

## C-01 目标与边界

用 MoonUI 一比一复刻本地音乐桌面端（macOS/Windows 的桌面客户端那个形状），
分期建设。**第一期只做本地音乐播放**——能跑、能听、能管，此外一律不做。

第一期验收场景（一句话版）：打开应用 → 选一个音乐目录 → 扫描出列表 →
双击一首歌开始播 → 底部播放条全功能（播放/暂停/上一首/下一首/进度拖动/音量/
播放模式/播放列表抽屉）→ 关掉再打开，目录与窗口位置还在。

第一期**不做**（逐条列出，免得范围漂移；每条都对应第二期或更后的档）：

- 在线能力全家（登录、搜索、推荐、歌单同步、下载）——没有网络层，永远不会
  在第一期出现；
- 播放详情全屏页（点封面展开的那页，含歌词滚动）；
- 歌词（.lrc 读取与桌面歌词）；
- 「我喜欢的音乐」与自建歌单（第一期只有「本地音乐」一个列表 + 当前播放队列）；
- 迷你模式、托盘、全局快捷键（托盘零件 `T86⑥` 已在框架里，但第一期的边界
  是窗口内闭环）；
- 音效/均衡器、无缝切换、淡入淡出；
- 主题切换与深色适配的精修（框架的 `ThemeChanged` 通道白给，配色随系统，不另做
  皮肤系统）。

## C-02 复刻对象拆解：常见音乐客户端桌面端的区域地图

参照对象的窗口（约 1000×670 起）分五个区域，第一期保留关系如下：

```
┌──────────────────────────────────────────────────────┐
│ 顶栏：◀ ▶   [搜索框]           …  ⓘ  ─ ▢ ✕          │  ← 第一期：仅窗口控制（原生
│                                                       │     标题栏，搜索不做）
├──────────┬───────────────────────────────────────────┤
│ 侧栏      │ 主区                                       │
│          │                                            │
│ 发现音乐  │  本地音乐                        ⌄ 排序    │
│ 私人 FM  │  ───────────────────────────────────────  │
│ ……（灰） │  [▶ 播放全部] [＋ 添加目录]  共 N 首         │
│          │  ┌──────────────────────────────────────┐ │
│ 我的音乐  │  │ #  标题      歌手    专辑    时长     │ │
│ ▸本地音乐 │  │ 1  …         …      …      03:41   │ │
│ ▸我喜欢(无)│  │ 2  …         …      …      04:02   │ │ ← VirtualList
│          │  │ …（双击播放，右键：播放/从列表移除）  │ │
│ 创建的歌单│  └──────────────────────────────────────┘ │
│  (第一期无)│                                            │
├──────────┴───────────────────────────────────────────┤
│ 播放条：[封面] 歌名          ⏮ ▶ ⏭   ──●──── 02:11/03:41 │
│         歌手            ♡          模式 🔊─●─ ☰          │
└──────────────────────────────────────────────────────┘
                                   ☰ = 播放列表抽屉（右侧滑出）
```

复刻纪律：第一期对**布局结构、交互路径、文案**做一比一（侧栏宽度、播放条
三段式、双击播放、右键菜单、模式图标的循环顺序「顺序播放 → 单曲循环 → 随机
播放」），对**视觉皮肤**不做像素级（圆角、阴影、强调色这些按框架的
`Style`/`Theme` 能力走，能近则近，不为像素新增框架能力——唯一例外
是音频层，见 C-04）。皮肤参照源 2026-10-18 起换成 YesPlayMusic 新版
（github.com/qier222/YesPlayMusic）：强调蓝 #335EEA + 白底，弃经典常见音乐客户端红，
token 全在 `skin.mbt`。

## C-03 框架能力映射：现有零件够不够用

把第一期每个 UI 块映射到框架现役零件（全部已落地、有测试或有真跑记录，
括号里是出处）：

| 区域 | 零件 | 出处 |
| --- | --- | --- |
| 侧栏导航项 | `MenuRow`（扁平可点行，选中态复用 checked 通道） | `T73` |
| 侧栏分组标题 | `Label` + `.font_size().foreground()` 修饰符 | `T83` |
| 主区表格 | `VirtualList`（出窗零句柄，`data-admin` 已在 1000 行合成数据上复验） | `T86④`/`T88` |
| 表格行内列 | `Row` + 定宽 `Sized`/`Label` | §14 |
| 双击播放 | `.with_on_double_click()` | `T83` |
| 右键菜单 | 控件级上下文菜单 | `T86①` |
| 封面 | `Image`（`set_image_bytes`，解码归原生层） | `T86⑤` |
| 播放/暂停等按钮 | `Button` + `.with_on_click()` | 0.1 |
| 进度条/音量 | `Slider`（`value` 千分位通道，`set_value`）+ `Change`/`Input` 事件 | 0.2 |
| 播放列表抽屉 | `Stack` 叠层 + `VirtualList`，`.animation()` 做滑入 | `T74`/`T84` |
| 添加目录 | `Backend::select_folder`（系统原生面板） | `T21` |
| 拖文件进窗口 | `FileDrop(EventTarget, Array[String])` | `T86③` |
| 窗口位置记忆 | `App::create_window_restored` / `save_window_state`（`settings-center` 已验闭环） | `T86⑧`/`T88` |
| 扫描不卡 UI | `App::post_task` + worker（一次投递一条平台线程） | `T85①` |
| 空格播放暂停、⌘←/⌘→ 切歌 | `KeyDown` + `Shortcut`，mac 键路刚移植 | `T39`/`T96` |
| 菜单栏（播放/控制菜单） | `MenuBar` + `MenuSelect` | `T22` |
| 深浅色跟随 | `ThemeChanged` + `style_base` 重算 | `T48` |

**结论：UI 面零缺口**。所有零件都是现役的，唯一的新地基是**音频**——
框架从零没有音频能力（`git grep -iE 'audio|sound'` 全仓命中全是
`decode_lossy`/`UNAuthorizationOptionSound` 误伤），这是 C-04 的全部内容。

## C-04 架构决策一：音频层（第一期唯一的新地基）

### 决策：解码与播放归原生层，照 `Image` 先例（`T86⑤`）进两份平台 C

候选方案与取舍：

- **A. 系统播放器进 adapter（采用）**——mac 半 `AVAudioPlayer`（mp3/aac/m4a/
  wav/flac/alac 全包），Windows 半 Media Foundation（`IMFSourceReader` +
  `IMFSinkWriter` 之外的简单播放路径，或 `MFMediaEngine`）。符合三条既定裁决：
  `T82` 的零第三方依赖、`T18` 的分叉只在 C、`T86⑤` 的「解码归原生层，
  MoonBit 侧零解码」先例。
- B. miniaudio（单文件跨平台 C 库）——一行 ABI 都不用写，但引入第三方
  依赖，`T82` 删 libui 的全部理由（构建链、符号漂移、审计面）原样适用，否。
- C. 纯 MoonBit 解码——MP3/AAC 解码器手写不现实，否。

### ABI 面（`adapter.h` 新增一节，名字沿用 `moonui_native_` 前缀）

```
/* ---- 音频（lunamusic 第一期；解码与元数据解析都归原生层，MoonBit 侧零解码。
 * 一次只装一首歌——播放器是进程级单例，load 新歌即换掉旧的。
 * 错误码照 T18 约定：没接的那侧返回「本平台未实现」码，共享层映射成 Unsupported。---- */
int     moonui_native_audio_load(const char *path, int len); /* 0 装上；<0 错 */
int     moonui_native_audio_play(void);      /* 0 / <0 */
int     moonui_native_audio_pause(void);
int     moonui_native_audio_stop(void);      /* 停并卸载 */
int64_t moonui_native_audio_position_ms(void);
int64_t moonui_native_audio_duration_ms(void);  /* 未知返 -1 */
int     moonui_native_audio_seek_ms(int64_t ms);
int     moonui_native_audio_set_volume(int permille);         /* 0..1000 */
int     moonui_native_audio_is_playing(void);
/* 播完回调：UI 线程投递，闭包生命周期照 worker 先例（T85① 的 incref/decref
 * 配对 + tests/ffi 的真 pthread 探针形状）；重复调用只换回调。 */
int     moonui_native_audio_on_finished(moonui_closure_fn fn, void *closure);
/* 元数据探针：返回打包字节（title/artist/album/duration_ms/封面 PNG 字节段），
 * 打包布局照 menu_tree 先例写在本头文件里；NULL = 读不出（调用方退回文件名）。 */
moonui_ptr moonui_native_audio_probe(const char *path, int len);
```

要点：

- **不进 `Backend` trait**。音频不是 GUI 后端的职责，`Backend` 加方法会逼
  `MockBackend` 与 wasm 门禁跟着长。它是独立的一段 ABI + `ffi.mbt` 里独立的
  一组 extern，应用侧用一个 `AudioEngine` trait（C-06）注入，测试用纯 MoonBit
  的 `MockAudioEngine`——与 `MockBackend`/`Backend` 同一款依赖注入先例。
- 元数据也走原生层（AVFoundation 的 `AVAsset.metadata` / MF 的属性存储），
  **不自解析 ID3v2/FLAC**——原生层给不了的字段（罕见格式）退回文件名显示，
  这是第一期可以接受的形状。
- 封面 PNG 字节段直接喂 `Image::set_image_bytes`（`T86⑤` 的字节通道），
  解码链路与 Image 完全同一条。

## C-05 架构决策二：目录形状与无头可测性

```
examples/lunamusic/           应用本体，**库包**（不带 -native，进 wasm 门禁）
  DESIGN.md                    本文档
  moon.pkg                     library
  model.mbt                    歌曲/曲库/队列的数据模型（纯数据，零 UI 零后端）
  engine.mbt                   AudioEngine trait + MockAudioEngine（纯 MoonBit）
  player.mbt                   播放状态机（C-08，依赖 AudioEngine 注入）
  library.mbt                  曲库：扫描结果处理、目录持久化、增删（纯逻辑）
  ui_shell.mbt                 三栏布局组装（侧栏/主区/播放条）
  ui_playbar.mbt               播放条组件
  ui_table.mbt                 本地音乐表格（VirtualList 行构建）
  ui_drawer.mbt                播放列表抽屉
  app.mbt                      LunaMusicApp：把以上组装成可 run 的应用
  *_test.mbt                   无头测试（MockBackend + MockAudioEngine，wasm 可跑）
examples/lunamusic-native/    真窗壳（-native 后缀，native-only，不进 wasm 门禁）
  moon.pkg                     executable，import lunamusic + moonui-app + native-common
  main.mbt                     new_app() + NativeAudioEngine 适配（~40 行）+ run
```

两条关键约束，都是现有门禁推出来的：

1. `scripts/ci-packages.sh` 靠 `-native` 后缀把 native-only 包排除出 wasm 门禁
   （examples/README.md 写明，新建真后端示例必须沿用），所以壳的名字锁死
   `lunamusic-native`。
2. 应用本体**不许 import `backends/native-common`**——否则 wasm 门禁编不过。
   音频 ABI 的 extern 住在 native-common，本体只面向自己定义的 `AudioEngine`
   trait 编程；壳里那段 ~40 行的适配（`NativeAudioEngine` 把 trait 方法转到
   `@native-common` 的 audio extern）是唯一碰音频 ABI 的 MoonBit 代码。
   测试全部走 `MockAudioEngine`（记录调用序列 + 可编排的「播完了」回放），
   在 wasm 下全绿。

## C-06 AudioEngine trait（应用侧接口）

```moonbit
/// 应用侧的音频引擎接口：native 壳用原生 ABI 实现，测试用 MockAudioEngine。
/// 单位约定：时长/位置毫秒，音量千分位（0..1000），与 adapter.h 的 ABI 一致。
pub(open) trait AudioEngine {
  load(Self, path : String) -> Track raise AudioError   // 装上并读出元数据
  play(Self) -> Unit raise AudioError
  pause(Self) -> Unit
  resume(Self) -> Unit
  stop(Self) -> Unit
  seek(Self, ms : Int64) -> Unit
  position(Self) -> Int64          // 当前位置毫秒
  duration(Self) -> Int64          // -1 = 未知
  set_volume(Self, permille : Int) -> Unit
  is_playing(Self) -> Bool
  on_finished(Self, fn() -> Unit) -> Unit   // 播完回调（自然播完，不含手动 stop）
}
```

`Track` 是 model.mbt 里的纯数据（path/title/artist/album/duration_ms/cover
字节可选）。`load` 返回 Track 意味着元数据探针与装载合成一步（`audio_load`
+ `audio_probe` 在适配层里接连调）。

## C-07 数据与持久化

- **曲库目录清单**：用户添加的目录数组。持久化照 `settings-center` 验过的
  闭环（`T86⑧`/`T88`：窗口状态走 `save_window_state`；应用数据走
  `window_state_file_native.mbt` 同款的落盘先例——libc extern 直指 stdio，
  `T86⑦`/`T88②` 都是这条），落一个 `lunamusic-library.json`（UTF-8，
  目录数组 + 每首歌的上次扫描结果缓存：path/mtime/元数据——mtime 变了才重新
  probe，启动秒开）。
- **窗口状态**：`create_window_restored`（尺寸/位置/最大化态）。
- **播放偏好**：音量、播放模式、最后播放的歌曲与位置（启动时不自动续播，
  只恢复列表高亮——与常见音乐客户端行为一致）。

## C-08 播放状态机（player.mbt，纯 MoonBit，全部无头可测）

状态：`Idle → Loading → Playing ⇄ Paused → (finished) → 下一首的 Loading…`

行为表（每条都对应一条 MockAudioEngine 测试）：

| 触发 | Playing 时 | Paused 时 | Idle 时 |
| --- | --- | --- | --- |
| 点播放键 | pause | resume | 播当前高亮或队列头 |
| 上一首 | 位置 >3s 回开头，否则切上一首 | 同左 | 队列尾 |
| 下一首 | 按模式取下一首 | 同左 | 队列头 |
| 自然播完 | 按模式取下一首；顺序到尾则停 | — | — |
| 双击列表行 | 该行成为当前，从头播 | 同左 | 同左 |
| 进度拖动 | seek，播着不动 | seek，保持暂停 | — |
| 模式切换 | 只改下一次取歌规则 | 同左 | 同左 |

播放模式：`Sequential`（到尾停）→ `RepeatOne` → `Shuffle`（不重复直到放完
一轮——洗牌队列记在 player 里）→ 回到 `Sequential`，与常见音乐客户端的循环顺序一致。

进度推进：播放中由 player 向 `App` 挂一条 500ms 的自续任务（`post_task` 里
再 `post_task` 自己，`cancel_task` 在 pause/stop 时撤），每拍 `position()`
→ `Slider.set_value` + 时间文案。不开 worker——读位置是纯内存调用，没有
阻塞理由（worker 只用于磁盘扫描这种真阻塞）。

## C-09 分步实施与验收判据

按仓库 FP 惯例（每步都可独立验收、独立提交）：

- **FP0 设计定稿**：本文档 review 通过，挂 `T98`。
- **FP1 音频地基（mac 半）**：`adapter.h` 音频节 + `adapter_native.m` 的
  AVAudioPlayer 实现 + `ffi.mbt` extern + `MockAudioEngine` + model/player/
  library 的纯逻辑与无头测试全绿。判据：`moon test examples/lunamusic`
  （wasm）全绿 + `tests/ffi` 形状的手工真机放一首歌（脚本或临时壳）。
- **FP2 应用 UI**：三栏 + 表格 + 播放条 + 抽屉，无头测试（MockBackend 注入
  双击/模式切换/拖动）全绿。判据：wasm 门禁 + `dump_layout` 快照对账。
- **FP3 真窗壳（mac）**：`lunamusic-native` 跑通 C-01 的验收场景；窗口持久化、
  目录持久化、FileDrop 加歌、快捷键（空格/⌘←/⌘→）真机验。判据：人工走一遍
  验收场景录屏 + 无回归（全量门禁绿）。
- **FP4 Windows 半**：`adapter_native.c` 的 Media Foundation 实现。判据：
  那台 Windows 机器上同一场景走一遍（照 `T77` 的六步先例）。
- 每步收尾：`moon info && moon fmt`、`TODO`/`README` 记账、`scripts/test-local.sh` 全绿。

## C-10 风险与已挂账的关联

1. **键路测试零覆盖（`T96`①）**：FP3 的空格/快捷键依赖刚移植的 mac 键路，
   真机手动验证之外没有测试兜底；若踩坑，优先按 `T96`① 的两选一处理
   （给 mac 补键注入脚手架 vs 改头注），不要在 lunamusic 里绕。
2. **音频回调跨线程（§47 风险 1 同款）**：`audio_on_finished` 的闭包由原生
   播放器线程触发，incref/decref 配对与投递纪律照 `T85①` worker 的先例
   逐行抄（那边有 `tests/ffi` 的真 pthread 探针打底）。
3. **Windows Media Foundation 是第一次真写**：mingw 语法闸门盖不住行为层，
   真跑欠账按 `T89`~`T92` 的模式挂（写进 FP4 的判据，不在这份文档里预言）。
4. **元数据读不出**（损坏文件/罕见格式）：退回文件名 + 时长未知显示 `--:--`，
   不阻塞扫描（逐首隔离失败）。
5. **大目录扫描**（上万首）：扫描走 worker + 分批 `post_task` 回灌列表，
   UI 不冻结；`VirtualList` 的行数上限已验证过 1000 行档位，万级档位若实测
   有问题另挂账。

## C-11 第二期展望（只列名字，不设计）

播放详情页 + 歌词滚动；「我喜欢的音乐」与歌单；托盘 + 迷你模式；全局快捷键；
音效；`.lrc` 本地歌词；云同步（如果那一天真来的话）。
