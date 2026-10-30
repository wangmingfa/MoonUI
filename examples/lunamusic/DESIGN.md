# lunamusic 设计：一比一复刻本地音乐桌面端（第一期：本地音乐播放）

> 状态：第一、二期已大面积落地（截至 2026-10-29）。这份文档与 TODO 的对应关系：
> 每一期开工时挂一条 `Tnn`，完成注记回这里的小节号（`C-nn`，本文件的小节号
> 与仓库 DESIGN.md 的 `§nn` 互不干涉，本节号**不许重排**，新增往末尾追加）。
>
> **C-01 的边界表已被实现超越**：当初划进"第二期"的歌词、迷你模式、托盘、
> 「我喜欢的」、均衡器都已落地。C-01 原文保留（它是历史边界，删了就看不出
> 范围是怎么漂的），实际状态以 **C-12** 为准。

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
- 歌词（.lrc 读取与桌面歌词）；← **已落地，见 C-12**
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
  lyrics.mbt                   LRC 解析 + 活动行定位 + 伴随文件路径推导（C-12）
  prefs.mbt                    播放偏好（音量/模式/最后曲目）
  probe.mbt                    元数据打包字节的解析（adapter.h 音频段布局）
  shared.mbt                   与门控无关的小工具（String → UTF-8 Bytes）
  skin.mbt                     颜色 token（一套皮肤 = 一组常量 + 名字）
  layout.mbt                   各窗默认落座（位置/尺寸/最小尺寸）
  ui_playbar.mbt               主控面板：信息条 / 频谱 / 大字时间 / 进度 / 走带
  ui_table.mbt                 播放列表（页签 + 工具条 + 列头 + VirtualList + 属性栏）
  ui_lyrics.mbt                歌词秀（3 行）+ 桌面歌词窗（2 行）
  ui_eq.mbt                    均衡器（十段真滑块 → AudioEngine::eq_apply）
  ui_strip.mbt                 伴窗顶条（皮肤底 + 标题 + 关闭方块）
  walk_native.mbt              目录行走的 native 半（targets 门控）
  walk_wasm.mbt                目录行走的 wasm 半（显式缺席报 Unsupported）
  storage_native.mbt           曲库档/歌词档的 libc stdio 落盘半（targets 门控）
  storage_wasm.mbt             同上，wasm 半显式缺席
  app.mbt                      LunaMusicApp：把以上组装成可 run 的应用
  lunamusic_wbtest.mbt         无头测试（MockBackend + MockAudioEngine，wasm 可跑）
  layout_wbtest.mbt            布局回归护栏
examples/lunamusic-shell/     双后端共享壳（库包，shell.mbt 逐文件门控 native-only）
  shell.mbt                    NativeAudioEngine 适配 + 装配 + 菜单栏/托盘/曲库档/
                               偏好档/进度心跳/频谱链/拖入
examples/lunamusic-native/    原生真窗壳（-native 后缀，native-only，不进 wasm 门禁）
examples/lunamusic-canvas-native/  自绘后端壳（同一份 shell，换一个后端构造）
```

> 上面这棵与最初设计有出入：原计划的 `ui_shell.mbt` / `ui_drawer.mbt` 没建，
> 抽屉与三栏组装直接在 `app.mbt` 与 `ui_table.mbt` 里；真窗壳拆成了
> `lunamusic-shell` + 两个薄壳。**以实际文件为准**。

两条关键约束，都是现有门禁推出来的：

1. `scripts/ci-packages.sh` 靠 `-native` 后缀把 native-only 包排除出 wasm 门禁
   （examples/README.md 写明，新建真后端示例必须沿用），所以壳的名字锁死
   `lunamusic-native`。
2. 应用本体**不许 import `backends/native-common`**——否则 wasm 门禁编不过。
   音频 ABI 的 extern 住在 native-common，本体只面向自己定义的 `AudioEngine`
   trait 编程；壳里那段适配（`NativeAudioEngine` 把 trait 方法转到
   `@native-common` 的 audio extern）是唯一碰音频 ABI 的 MoonBit 代码。
   测试全部走 `MockAudioEngine`（记录调用序列 + 可编排的「播完了」回放），
   在 wasm 下全绿。

   这条约束没有松动，但**承载它的是 `lunamusic-shell` 而不是单个薄壳**：
   `app.mbt` 里的 `LunaMusicApp::refresh_lyrics` 只调 `load_lyrics_for`
   （读文件走 `storage_native.mbt`，那是 libc extern 不是音频 ABI），
   音频适配全在 shell 的 `NativeAudioEngine` 里。

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

> 落地情况（2026-10-29 核）：`.lrc` 本地歌词 ✅、托盘 ✅、迷你模式 ✅、
> 「我喜欢的」页签 ✅、均衡器（真 AVAudioUnitEQ，不是画的柱子）✅；
> 播放详情全屏页 ❌、歌词**滚动**动画 ❌（歌词秀是 3 行换字，不是滚动列表）、
> 全局快捷键 ❌、云同步 ❌。明细在 C-12。

## C-12 歌词加载与渲染：实际实现

**这一节记的是代码现在的样子**，不是设计意图。C-01/C-11 里把歌词划在第二期，
但它在 `a3f255d` 那一笔就落地了，文档一直没跟上。

### 数据从哪来

只认**音频同目录、同名 `.lrc`**。`lyrics.mbt` 的 `lyric_path_for` 把扩展名换掉：

```
夜曲.mp3  → 夜曲.lrc        （取最后一个点之前的全部 + .lrc）
夜曲.flac → 夜曲.lrc
无扩展名  → 原样 + .lrc
```

**没有**内嵌歌词（ID3 `USLT`/`SYLT`、FLAC `VORBIS_COMMENT` 都不读）、没有手动
指定文件。联网那半已由 C-13 补上（本地 `.lrc` 缺席时问 lrclib.net）——但**优先级
不变**：本地有词就一个字都不发。读取复用曲库档那套 libc stdio（`storage_native.mbt` 的
`load_lyric_text` 直接调 `library_load`），整份读进内存再交给解析器。

文件不存在返回 `None`，**不是错误**——无歌词是常态。wasm 半显式
`raise Unsupported`（`storage_wasm.mbt`），与曲库档同一条账。

### 解析（`lyrics.mbt` 的 `parse_lrc`）

逐行处理，坏行整行丢弃、不阻断：

| 写法 | 处理 |
| --- | --- |
| `[mm:ss.xx]词` | 记一行；`xx` 位数随意，按小数位定标（`.5` = 500ms，`.50` = 500ms） |
| `[00:01.00][00:30.00]词` | 一行多个时间标签 → 展开成多行，同一句在多个时刻都高亮 |
| `[ti:][ar:][al:][by:]` | 忽略 |
| `[offset:±500]` | 全文件统一平移，可出现在任意位置，最后一次性加上 |
| 时间标签格式错 / 词为空 | 整行丢弃 |

结果按时间升序做插入排序（行数小，不值得上快排）。

`active_lyric_index(lyrics, pos_ms)` 线性扫到最后一个 `t <= 位置`，未到第一句
返回 `-1`。**每拍都从头扫**——1000 行歌词 × 500ms 一拍，开销可忽略；真到万行
再换二分，现在不值得。

### 什么时候读、什么时候刷

**只在换曲时读文件**，缓存在 `app.mbt` 的两个字段：

```moonbit
mut lyrics_path : String       // 当前曲路径，判"要不要重读"用
mut current_lyrics : Array[Lyric]
```

```moonbit
if t.path != self.lyrics_path {        // 路径变了才重读
  self.lyrics_path = t.path
  self.current_lyrics = load_lyrics_for(t.path)
}
```

之后的刷新只重算高亮行，不碰文件。两个驱动入口：

1. **500ms 进度心跳**（`shell.mbt` 的 `post_after` 自续链，播着才续，见 `T152`）；
2. `rebuild_ui` 末尾补调一次，让换树后立刻有内容。

停播时清空缓存、刷新成占位。

**注意**：`refresh_lyrics` 的注释写明它"不在 wasm 测试路径上触发"，因为
`load_lyrics_for` 会读文件。歌词逻辑本身（解析 / 定位 / 路径推导）在
`lunamusic_wbtest.mbt` 的 `lyrics：LRC 解析 + 活动行定位` 里被完整覆盖，但那
一条只调 `parse_lrc` 与 `active_lyric_index`，**不经过读文件**。

### 画在哪

| 位置 | 组件 | 内容 |
| --- | --- | --- |
| 歌词秀窗（独立窗，上排右侧） | `LyricsView`（`ui_lyrics.mbt`） | 5 行：当前句居中，上下各两行。当前句 17pt Bold + 强调色，其余 12pt 暗色 |
| 桌面歌词窗（屏幕底部居中） | `DeskLyrics`（`ui_lyrics.mbt`） | 2 行：当前句 + 下一句 |

歌词秀无歌词时中间行显示歌名（歌名也没有才显示「（暂无歌词）」）；桌面歌词窗
无歌词时显示歌名，歌名也没有才显示「Luna」。

**是换字，不是滚动**——没有滚动动画、没有居中高亮列表。C-11 说的"歌词滚动"
仍未落地。

**五行是 `T159`③**（owner 2026-10-29 点的）：原来是三行，只看得见紧邻的上下
各一句，一句唱完立刻换屏，读起来像在追字幕。五行能提前看到下一句、也能回味
上一句。窗口高度下限跟着从 100 加到 130（`layout.mbt`）——17pt 当前句 + 4×12pt
上下句 + 行距装得下。行数与"哪一行是当前句"都由 `cm_lyric_lines()` /
`cm_lyric_center()` 单点定义，改动只碰这两个函数。

### 桌面歌词窗的显隐

```moonbit
cm_desk_visible(show_desk, mini, has_lyrics) =
  show_desk && !mini && has_lyrics.length() > 0
```

三条同时成立才露头。**按边沿触底**：`sync_desk_window` 先跟 `desk_shown` 比
一次，只有"该变"了才碰窗口。理由写在函数头上——`Window::show` 落的是
`makeKeyAndOrderFront:`，500ms 一拍无脑 show 等于每半秒把焦点从用户正在用的
程序抢回来。

### 已知欠账

- **内嵌歌词不读**：只认外部 `.lrc`。要支持得先有元数据读取能力，
  当前 `probe.mbt` 只取 title/artist/album。
- **滚动动画没做**：3 行换字，不是 Apple Music / 网易云那种居中滚动的长列表。
- **编码只走 `decode_lossy`**：`.lrc` 是 GBK 时整份会变成替换字符，没有
  编码探测。

## C-13 在线歌词（lrclib.net）

本地没有可用歌词时联网取一份。这是 `T158` 落地的样子。

### 优先级与触发

`refresh_lyrics`（500ms 心跳驱动）里，路径变了才做三件事：读本地 `.lrc` →
解析 → **解析结果为空**才走在线取词。判据是"解析结果是空的"而不是"文件不
存在"：一份时间标签全坏的 `.lrc` 同样等于没有词。

三条闸门（`maybe_fetch_online_lyrics`）：

| 闸 | 为什么 |
| --- | --- |
| `current_lyrics` 非空就返回 | 本地有词不联网 |
| `on_fetch_online` 是 `None` 就返回 | 无头测试 / wasm 侧不接 |
| `lyrics_asked_path == t.path` 就返回 | 心跳是 500ms 一拍，没有这道闸就是每半秒一轮 HTTP |

`lyrics_asked_path` **只记发过一次的路径，不记结果**——"问过但没查到"也要记，
否则每拍重发。它不清空：这次会话里切回来不再打服务器。

结果回来时 `apply_online_lyrics` 先比 `lyrics_path`：用户可能在请求飞在路上时
已经切了歌，那份词贴上去就是错位（`T153` 的 `lit_path` 同一个教训）。

### 拿什么去问（`tag.mbt`）

输入是 Track，输出一张**有序候选表** `Array[(title, artist)]`。三条来源规则：

1. **元数据优先**：探针读出真值（非空、非哨兵）就用。
2. **缺哪个补哪个**：只有缺失的那一半去文件名里找，另一半原样保留。
3. **两者都缺**才整份走文件名规则。

`"未知"` 是 `Track::from_path` 的哨兵（不是空串），判缺失必须认它。

**还有第三种"缺失"**：探针读不出标签时 `Track::from_path` 直接把文件名去扩展
名塞进 title。这个值是兜底不是元数据，但它在 Track 里与真值长得一模一样——
只有对着文件名比才分得出来。所以 `title == 文件名去扩展名` 也算缺失。判错的
代价很小：真值恰好等于文件名的歌，两种走法给出的查询词是同一个。

**文件名切段**（`cm_filename_segments`）：去扩展名 → `_` 换成空格 → 按任意横杠
（`-` / `－` / `—` / `–`）切 → 去空段 → **从尾部剥掉纯数字段**（至少留一段）。

```
給我一首歌的時間_(Piano_Ver_)-Piano_Echoes-275694467-320.mp3
  → ["給我一首歌的時間 (Piano Ver )", "Piano Echoes"]
听妈妈的话（钢琴版）-周杰伦-385944392-100.ogg
  → ["听妈妈的话（钢琴版）", "周杰伦"]
你怎么舍得我难过-黄品源-145527-2000.flac
  → ["你怎么舍得我难过", "黄品源"]
```

**顺序**：两段时两种切法都发（`A = 歌手 / B = 歌名` 与反过来），先发哪个由
`cm_title_first` 判，两个信号按可信度排：

1. **尾部括注**：`（钢琴版）`/`(Live)`/`[Remastered]` 只挂在歌名上 → 带括注的
   那一段是歌名。这条最硬。
2. **横杠两侧的空格**：`Artist - Title`（两侧有空格，手打标签的习惯）歌手在前；
   `Title-Artist`（紧贴，下载站命名的习惯）歌名在前。owner 给的三个例子全是
   紧贴写法，所以默认按下载站走。

另外每个候选还会再补一份「剥掉标题尾部一层括注」的版本（`tag_with_title_variants`），
追加在原表**之后**。原因见下：`/api/get` 是精确匹配，`听妈妈的话（钢琴版）`
精确查一定 404，而正版条目通常叫 `听妈妈的话`。原始候选在前，真有原名条目的
仍优先命中。整串就是一个括注（`（纯音乐）`）时剥成空，那条不发。

### 端点（2026-10-29 实跑核对）

```text
GET /api/get?track_name=&artist_name=&duration=   → 单个对象 / 404
GET /api/search?track_name=&artist_name=          → 数组（可能空）
```

实跑观察到三条，直接决定了实现形状：

- `/api/get` 是**精确匹配**，多一个字就 404 → 版本后缀的歌得靠 `/api/search`；
- `/api/search` 的结果里 `syncedLyrics` 可能为 `null` 而 `plainLyrics` 有值；
- **有速率限制**：连着快发会 503，且必须带能认出调用方的 `User-Agent`
  （空 UA 直接 403）。

URL 构造的两条纪律：空 `artist` 与未知（`<= 0`）时长**不带那个参数**——带
`duration=0` 会让 lrclib 按"0 秒"精确匹配，必然 404。编码按 **UTF-8 字节**做
`%XX`（不是按字符），空格用 `%20` 不用 `+`。

### 决策状态机（`lrclib.mbt`）

网络从决策里剥出来的那一层：喂它「URL + 已取到的响应体」，它说下一步干什么。

```moonbit
enum OnlineStep { Fetch(String); Done(String); GiveUp }
```

`online_lyrics_plan` 把候选表翻成 URL 序列，每个候选两条（get 在前、search 在后），
空标题的候选跳过。每一格带**候选序号**——空标题被跳过后位置与序号不再对齐，
拿 `i / 2` 反推会取到错的人（用甲的歌手去挑乙的结果）。

`online_lyrics_step` 的规则：

1. `/api/get` 命中就用——它是精确匹配，回来的就是对的那首；
2. get 404 换 `/api/search`，用 `pick_lyrics_hit` 挑；
3. 一个候选两条都空就换下一个候选；
4. 全空 → `GiveUp`。

`pick_lyrics_hit` 的三条优先级：**带时间轴 +1000**（能做逐句高亮）> 标题/歌手逐字
相同各 +100 > 时长差每 1 秒 −1。三条同时参与排分，取第一条，同分保持服务器原序。
时长那条是实打实需要的：同一首歌的现场版与录音室版常差 30 秒，配上去时间轴会
整体错位。

`hit_to_lrc`：有时间轴原样回去走 `parse_lrc`（与本地 `.lrc` 同一条路）；只有纯文本
就把它合成一份**递增假时间轴**（第 k 句在第 k 秒）。整段塞一行是显示不出来的——
假时间轴至少让歌词秀一屏一屏往前走。真时间轴拿不到是服务器的事，注释里写清了。

### 线程模型

`moonbitlang/async` 的 `run_async_main` 会**独占调用它的线程**跑自己的事件循环
（`with_event_loop` 内部只允许一个循环，而且循环登记是**进程级**的，不是线程
局部）。GUI 主线程要跑 MoonUI 的泵，交不出去，所以整条取词走一次 worker 线程：
worker 里 `run_async_main` 发 HTTP 并跑完决策机，`land` 闭包回到主循环把结果交给
App。worker 那套（incref/decref + 投递纪律）是 `T85①` 打底的原语，没新造机制。

**依赖版本**：`moonbitlang/async@0.22.6`（`moon.mod`）。它要求
`moonbitlang/core/async`，而 core 跟工具链走——最初的 core `0.10.17` 没有这个包，
`moon check` 直接报 `Cannot find import 'moonbitlang/core/async'`；升到 core
`0.10.18+6c83a7f62` 之后才能解析。0.22.6 还改了 http 的一处形状：头名的键从
`String` 换成 `@http.CaseInsensitiveString`（`Headers = Map[CaseInsensitiveString,
String]`），HTTP 头名本来就不分大小写，这条把这件事挪进了类型系统；字面量键可以
隐式转换，所以调用处只改类型标注。

**关于 `ExternalEventLoop`**（0.22.6 提供、正是给 GUI 用的形状：`poll(timeout?)` +
`get_wakeup_callback_for_foreign_thread()` + `terminate()`，把调度器挂到宿主自己的
事件循环上，不需要第二条线程）：**没换，是有意的**。挂进 MoonUI 的泵意味着主线程
要按 async 的节奏醒，而那条泵现在同时被 500ms 进度心跳与 33ms 频谱链按各自的
时刻表驱动（`T152` 的 `post_after`）——两套"什么时候该醒"的账混在一起，是更难查
的 bug 面。worker 那条路已被真实 HTTPS 与门禁验证过，代价只是每次调用现起一套
事件循环——所以一次换歌只发**一轮**请求，不做长驻连接池，也不为同一首歌重试。
要收掉这份开销时再换，形状已经留好。

单条请求 8 秒预算（`@async.with_timeout`）。**不 raise**：起不来线程、超时、503、
404，在取词这条链上一律等于"没查到"，不影响播放。

### 分层与可测性

| 层 | 文件 | 目标 | 可测 |
| --- | --- | --- | --- |
| 元数据/文件名推导 | `tag.mbt` | 全目标 | 全量无头 |
| URL / JSON / 挑选 / 状态机 | `lrclib.mbt` | 全目标 | 全量无头 |
| HTTP + 线程 | `../lunamusic-shell/online_lyrics.mbt` | 仅 native | 不在门禁里 |

最后一层没有可测的判断——它只做三件事：发请求、把响应体喂回决策机、把结果投回
主循环。所以测试压在纯逻辑那侧，网络半靠代码审读 + 真机手验。

## C-14 歌名与歌手的完整提取链路

`T158` 之前只在 C-06 里提过一句"load 合成装歌 + 读元数据两口"。这一节把
"从音频文件到最终拿去查歌词的那一对 (歌名, 歌手)"整条链路写清楚——四层，
每层都可能把值换掉，而**它们给出的东西不是同一个东西**。

```
音频文件
  │  ① C 探针（AVFoundation / Media Foundation）
  ▼
原始元数据包（打包字节）
  │  ② MoonBit 拆包 + 逐字段退回文件名兜底
  ▼
Track{ title, artist, album, duration_ms, cover }   ← UI 显示的是这一层
  │  ③ 取词时才做的推导（判"兜底"与"真值"）
  ▼
有序候选表 [(歌名, 歌手), ...]                        ← 只喂给 lrclib
```

### ① C 探针：从文件里读什么

| | macOS | Windows |
| --- | --- | --- |
| 实现 | `backends/native-macos/adapter_native.m` 的 `moonui_native_audio_probe` | `backends/native-windows/adapter_native.c` 同名函数 |
| 手段 | `AVAsset` + `[asset metadata]` | **空实现**，恒返回空包 |
| 键空间 | **只认 `AVMetadataKeySpaceCommon`** | — |
| 取哪些键 | `CommonKeyTitle` / `CommonKeyArtist` / `CommonKeyAlbumName` / `CommonKeyArtwork` | — |
| 时长 | `CMTimeGetSeconds([asset duration]) * 1000`，负值记为 `-1` | — |

**Windows 侧读不出任何标签**（FP4 之前 Media Foundation 只做播放），所以那边
的文件永远走第 ③ 层的文件名规则。

打包布局（`adapter.h` 音频段，MoonBit 侧按同一份契约拆）：

```text
[int32 title_len][title][int32 artist_len][artist]
[int32 album_len][album][int64 duration_ms][int32 cover_len][cover]
```

所有整数小端。打不开文件、`AVAsset` 为 nil、包超出 `INT32_MAX`、`malloc` 失败
都返回**空包**而不是 NULL——NULL 会让 MoonBit 侧解引用空指针闪退，空包是干净的
"读不出"。

**这一层只有 `Common` 键空间**，所以 FLAC 的 `VORBIS_COMMENT`、ID3 的 `TXXX`
自定义帧、`ALBUMARTIST` 那一类都读不到。中文 flac 里歌手放在 `ALBUMARTIST`
的情况不少，那些文件会整份退回文件名规则。另外 `[item stringValue]` 对多值
item 只取一个，`周杰伦/费玉清` 这种合唱歌手会被截成单个。

### ② 拆包与兜底（`probe.mbt`）

`track_from_probe(path, packed)` 按上面的布局逐字段读：

- 任一段长度越界 / 为负 → **整体返回 `None`**（不是逐字段部分成功）。打包布局
  坏了说明这份数据不可信，整份丢；
- 每个字符串字段**空串或 UTF-8 解码失败** → 退回 `Track::from_path(path)` 的
  对应字段。所以"探针读不出歌手"在 Track 里落成 `artist = "未知"`；
- `cover_len == 0` → `None`。

打包为空（0 字节）时 `read_i32_le` 直接失败，`track_from_probe` 返回 `None`，
调用方（壳的 `NativeAudioEngine::load`）退到 `Track::from_path(path)`。

**兜底函数 `Track::from_path`（`model.mbt`）给出的是：**

| 字段 | 值 |
| --- | --- |
| `title` | **文件名去扩展名，整串**，不做任何切分 |
| `artist` | `"未知"`（哨兵，不是空串） |
| `album` | `"未知"` |
| `duration_ms` | `-1L` |
| `cover` | `None` |

`"未知"` 是哨兵这件事在代码里有实际后果：判"有没有歌手"时必须认它，只判
空串会漏。

### ③ 取词推导（`tag.mbt`）

第 ② 层留下的坑：兜底把**整个文件名**塞进了 `title`，于是兜底出来的 Track
永远"有标题"，文件名规则一条都走不到——拿 `周杰伦 - 晴天` 当歌名去查，精确
匹配必 404。所以这一层要先判"这个 title 是兜底还是真值"。

**判定**（`tag_query_candidates`）：

```moonbit
title_missing  = 空串 || 哨兵 "未知" || title == 文件名去扩展名
artist_missing = 空串 || 哨兵 "未知"
```

对文件名比才是唯一能分辨的办法——兜底与真值在 `Track` 里长得一模一样（都是
非空 `String`）。判错的代价很小：真值恰好等于文件名的歌，两种走法给出的查询
词是同一个。

**三种情形**（owner 2026-10-29 定的「缺哪个补哪个」）：

| 情形 | 处理 |
| --- | --- |
| 两个都不缺 | 只出一格，元数据原样，文件名完全不碰 |
| 缺一个 | 只补那一半；补的时候取文件名里**不等于已有那一半**的段（`周杰伦 - 晴天.mp3` 已知歌手是周杰伦，歌名就该取「晴天」）。文件名给不出别的段就留空 |
| 两个都缺 | 整份走文件名规则，两种切法都出 |

**文件名切段**（`cm_filename_segments`）：

1. 取路径最后一段（`/` 与 `\` 都认）；
2. 去扩展名（最后一个 `.` 之前；`.gitignore` 那种点开头且无别的点的原样返回）；
3. `_` → 空格；
4. 按任意横杠切：`-`、`－`(U+FF0D)、`—`(U+2014)、`–`(U+2013)；
5. 去空段，每段 trim（含全角空格 U+3000）；
6. **从尾部剥掉纯数字段**，至少留一段。

第 6 步是 owner 点名的三种形状推出来的——下载站命名尾部常挂 UUID 与时长：

```
給我一首歌的時間_(Piano_Ver_)-Piano_Echoes-275694467-320.mp3
  → ["給我一首歌的時間 (Piano Ver )", "Piano Echoes"]
听妈妈的话（钢琴版）-周杰伦-385944392-100.ogg
  → ["听妈妈的话（钢琴版）", "周杰伦"]
你怎么舍得我难过-黄品源-145527-2000.flac
  → ["你怎么舍得我难过", "黄品源"]
```

只剥**尾部**：`A-320-B.mp3` 中间的 `320` 保留（三段都发，只取前两段）。
`123-456.mp3` 全数字也不剥成空（至少留一段）。

**两种切法的顺序**（`cm_title_first`）——「两种都查，命中优先」的排序依据。
按可信度两个信号：

1. **尾部括注**：`（钢琴版）`、`(Live)`、`[Remastered]`、`【】` 只挂在歌名上，
   歌手名不会带版本标记。剥得掉的那一段是歌名。这条最硬，压过空格习惯。
2. **横杠两侧的空格**：`Artist - Title`（两侧有空格，iTunes/手打标签的习惯）
   歌手在前；`Title-Artist`（紧贴，下载站命名的习惯）歌名在前。owner 给的三个
   例子全是紧贴写法，所以默认按下载站走。

两个信号都没有（`A-B` 且都不带括注）时落到第 2 条的紧贴规则：歌名在前。

所以 `听妈妈的话（钢琴版）-周杰伦-…ogg` 的第一格是
`("听妈妈的话（钢琴版）", "周杰伦")` 而不是反过来——靠的是第 1 条。

**尾部括注再补一份候选**（`tag_with_title_variants`）：每个候选后面再追加一份
"剥掉标题尾部一层括注"的版本。因为 `/api/get` 是精确匹配，带 `（钢琴版）`
一定 404，而 lrclib 上的正版条目通常叫 `听妈妈的话`。**原始候选排前面**，真
有条目用原名的仍优先命中；这条只是多一次机会。剥完为空（`（纯音乐）` 整串都
是括注）就不发；与已有候选重复也不追加。

### 边界与已知缺口

- **Windows 读不出标签**：`moonui_native_audio_probe` 是空实现，那边一律走
  文件名规则。MEDIA 层补齐之前这是事实，不是缺陷。
- **只有 `Common` 键空间**：`VORBIS_COMMENT` / `TXXX` / `ALBUMARTIST` 读不到。
- **多值只取第一个**：合唱歌手会被截成单个。
- **第 ③ 层只服务取词**：UI（播放条、列表、歌词秀的歌名行）显示的是第 ② 层
  的 `Track.title` / `Track.artist`。所以一个 tags 读不出、文件名是
  `周杰伦 - 晴天.mp3` 的文件，**界面上显示的是 `周杰伦 - 晴天`（歌名）/
  `未知`（歌手）**，而查歌词时用的是 `晴天 / 周杰伦`。
- **中文文件名里的分隔符**：`、`、`·`、`/`（后者在路径里不可能出现）都不当
  分隔符，`周杰伦、费玉清 - 千里之外.mp3` 会把 `周杰伦、费玉清` 整段当歌手
  （其实这个结果是好的，只是按"两种切法"它也会多试一次）。

### 判据

`examples/lunamusic/lunamusic_wbtest.mbt` 里 7 条 `tag：` 开头的测试钉住这一层
（原生与 wasm 两个目标都跑）：三种文件名形状逐字、剥数字只动尾巴、两种切法
顺序、缺哪个补哪个 + 哨兵当缺失、标题等于文件名算缺失、尾部括注补候选、
缺失判定本身。
第 ①② 层的 C 侧靠 `tests/ffi` 与真窗批；拆包那半在
`lunamusic_wbtest.mbt` 的 `track_from_probe` 用例里（整包 / 空包 / 全零）。

## C-15 简体优先与在线歌词本地缓存（`T159`）

owner 2026-10-29 提的三件事：① 在线查词优先要简体；② 查到的词存到本地，
下次不再联网；③ 歌词秀显示五行（③ 在 C-12 的「画在哪」里记了）。这里记 ①②。

### ① 简体：服务器上根本没有简体条目，只能"取到再转"

最初的设想是"在候选里挑一条简体的"。实跑推翻了它：lrclib 上中文歌的条目
**几乎全是繁体**——`素颜` 的 20 条命中，`syncedLyrics` 无一例外是
「又是一個安靜的晚上」。没有任何简体条目可挑，所以"优先简体"只能落在
**拿到之后转**。

转换点在 `hit_to_lrc`（`lrclib.mbt`）——在线歌词的**唯一出口**。不管服务器
给的是时间轴版还是纯文本版，也不管是从 `/api/get` 还是 `/api/search` 来的，
出去时一律过一道 `to_simplified`。挑选层（`pick_lyrics_hit`）仍然只看时间轴 /
时长 / 逐字相同，**不参与简繁**——两件事分开，改一边不动另一边。

表在 `t2s.mbt`（生成文件，2902 对）：`CFStringTransform` 的
`Traditional-Simplified` 对 CJK 三个 BMP 区段逐字跑一遍，只留单字对单字且
真的变了的。查表走 `t2s_map`（`@lazy.Lazy` 一次性建 `Map[Char, Char]`，首次
取词才付这份钱）。

**只剔除四个一对多的多义字**：`乾`（乾隆 / 乾淨）、`藉`（慰藉 / 狼藉）、
`瞭`（明瞭 / 瞭望）、`徵`（徵求 / 宮商角徵羽）。按字硬换会把前一种语境换错，
留个繁体字比出个错字好。`妳` 也不在表里——ICU 不把它并成 `你`，并掉等于改词。

**`著` 曾经在剔除名单里，2026-10-29 拿掉了**。理由是实测：从 lrclib 拉 25 首
真实中文歌词（25071 字）数了一遍，`著` 出现 **205 次，全部是时态助词「着」**
（「就飄著」「試著掉落」「握著妳手」），"notable" 用法 0 次。剔掉它等于每首歌
平均带 8 个繁体字，正好把这条需求抵消掉。代价是「著名」会被换成「着名」——
这个词在歌词里罕见，认了。

判据见 `lunamusic_wbtest.mbt` 的 `t2s：` 与 `lrclib：取到的歌词出口统一是简体`。

### ② 本地缓存：写到共用的 `歌.lrc`

在线查到的词存到本地，下次读词先看它。

**落点跟着歌走**（2026-10-29 owner 提的，比最初放家目录对）：词是这首歌的属性，
换机器、把目录拷给别人、重装应用，词都还在。最初那版落
`$HOME/.lunamusic-lyric-<hash>.lrc`，hash 里编着**旧路径**——音乐目录一挪缓存
全成孤儿，而且家目录里摊一堆十六进制名字，谁也认不出是哪个。

**写的是共用的 `歌.lrc`，不是私有名字**（同一天第二次修正，owner 追问"其它音乐
软件是不是就用不了了"）：`.lrc` 同目录同名是 foobar / 网易云 / 各种小众客户端都认
的约定，写私有名等于把词锁在 Luna 里，别的播放器打开同一首歌还得各自联网再查一遍。

```text
夜曲.mp3  →  夜曲.lrc        （写这里；别的播放器也认）
```

**已经有 `歌.lrc` 就不写**：它可能是用户手工对过轴的、别处下载的，覆盖它有踩踏
风险。走到"要写缓存"这一步本来就说明 `load_lyrics_for` 没读出词，那只可能是两种
情形——① 文件不存在（绝大多数情况，该写）；② 它在但一行时间标签都解析不出来
（纯文本歌词、或坏文件）。②很罕见，为它再备一套私有档名的代价是每次都要多解释
一遍"这两个文件谁是谁"；**不动别人的文件永远比"我有更好的版本"更稳**。代价只是
这首歌下次还会联网一次。

所以读取路径只有一条，没有优先级之争：

```text
同目录 歌.lrc   ← 用户放的 / 别的播放器下的 / 本程序取到的，都在这个名字上
```

读到这里解析出非空就算有词，否则照常联网（`T158` 那条链）。

写点在 `apply_online_lyrics`（`app.mbt`）——结果确认对应的是当前这首之后、贴到
`current_lyrics` 之前。**写失败吞掉**：音乐目录常是只读的（外置盘、共享目录、
导入的曲库），那只是"下次还得再问一次服务器"，不该让这一次的歌词不显示。

`lyric_save_path` 要探一次文件，所以归 `lyrics.mbt` 而不是纯逻辑层。wasm 半的
`save_lyric_text` 显式 `raise Unsupported`，与曲库档同一条账。

### 判据

- `t2s：繁体歌词转简体，ASCII 与多义字原样` — 真转、时间标签原样、多义字
  剔除、`著` 转换；
- `lrclib：取到的歌词出口统一是简体` — 出口唯一转换点；
- `缓存：空曲目路径不缓存（wasm 与无头测试据此跳过）` — "文件已存在就不写"
  那半要探盘，无头测试探不到，只能真机验；
- `app：歌词秀五行，当前句居中、上下各两行` — ③ 的判据（在 C-12）。

## C-16 歌曲信息编辑：实际实现（`T160`）

**这一节记的是代码现在的样子**。owner 2026-10-29 要能改标题 / 歌手 / 专辑，并且
**直接写回音频文件本身的标签**——不是只改内存里的曲库。结构照 C-12 的体裁：
先说数据从哪来、写进去，再说界面怎么接，最后记已知边界。

### 为什么是 vendored 包，不是依赖 mooncakes

原计划 `moon add cp15695540483/moontag@0.1.1`，owner 否掉并给了理由：**把上游源码按需
裁进本仓库做独立包**。两条依据：

- 上游`moontag` 从没在 native 上验过。读过源码：16 个 `.mbt` 里 `extern` /
  `native-stub` / `targets` / `#cfg` **零命中**，纯 `Bytes` 运算，`moon.mod` 的
  `preferred_target = "wasm-gc"` 只是默认值。所以它**不是编不过**，是**没人担保过**。
  vendoring 之后这条从"悬着的前提"变成我们自己的测试项——`examples/lunamusic-tag`
  现在 native 与 wasm 两份门禁都跑。
- 出了问题自己能改，不被上游版本卡住。代价是上游继续演进时我们要手动同步，所以
  `examples/lunamusic-tag/README.md` 里维护着「已取用 / 暂未取用 / 同步上游」三张表
  ——尤其「暂未取用」一节把封面（`id3_apic.mbt` 的 `Picture` / `serialize_picture` /
  `set_picture`）的上游对位逐条写清了，下次做封面时按那份清单回来取。

裁剪边界：保留 13 个文件（约 2100 行），丢掉 `id3_apic.mbt`（封面）与 `apev2.mbt`
（MP3 尾部 APEv2），`tags.mbt` 只留 `AudioFormat` + `detect_format`。已知差异一条：
只有 APEv2 标签的 mp3 读不出旧值；但写入会新建 ID3v2，而 ID3v2 在优先级上本就压过
APEv2，写完就正常了。这条写在包 README 里，不静默。

**许可证**：上游 Apache-2.0 与本仓库一致。`LICENSE` 副本随包分发（§4(a)），每个
`.mbt` 顶部保留来源声明与本地改动清单（§4(b)）。

### 三层分工：纯逻辑 / 注入的落盘 / 界面

| 层 | 文件 | 碰什么 |
| --- | --- | --- |
| 纯逻辑 | `tagwrite.mbt` | 输入整个文件的 `Bytes`，输出新 `Bytes`。不门控，wasm 门禁也编、也测 |
| 落盘 | `fileio_native.mbt` / `fileio_wasm.mbt` | 读字节 + 原子写；wasm 半逐个 `raise Unsupported` |
| 界面 | `ui_edit.mbt` + `app.mbt` | 编辑小窗 + 右键菜单 + 保存链路 |

**为什么 `write_tags` 要注入**（`LunaMusicApp::new` 的一个参数）：`examples/lunamusic`
是库包，同时进 core 与 wasm 两份门禁，**不能** import `backends/native-common`，也就
不能在包内直接碰文件系统。注入之后：wasm 能编；无头测试塞一个假 `write_tags` 就能把
"写文件"换成可控结果，其余全走真实现（库、队列、界面、属性栏都真更新）。这与
`probe_many` / `on_load_skin_dir` / `on_fetch_online` 同一条路。

### 写进去的是什么

`cm_write_tags` 按 `detect_format` 分派，四种容器四条路：

| 格式 | 入口 | 字段 |
| --- | --- | --- |
| MP3 | `set_fields` | `TIT2` / `TPE1` / `TALB`（v2.3 用 UTF-16，v2.4 用 UTF-8；padding 复用） |
| FLAC | `read_vorbis_comment` → `set_key` ×3 → `set_vorbis_comment` | `TITLE` / `ARTIST` / `ALBUM` |
| Ogg | `read_ogg_comment` → `parse_ogg_comment_payload` → `set_key` ×3 → `set_ogg_comment` | 同上 |
| M4A | `set_mp4_tags_with_delete` | `©nam` / `©ART` / `©alb`（stco/co64 偏移自动修正） |

**空串 = 删除该标签**，四种容器语义一致。MP4 是唯一需要额外接线的：`ilst` 里没有
"空值条目"这种表达，所以上游的 `set_mp4_tags` 只能更新、不能清空——本仓库补了一个
`set_mp4_tags_with_delete(v, updates, deletes)`，`set_mp4_tags` 变成它的空删除薄包装
（这是相对上游的 5 处本地改动之一，逐条记在包 README 里）。

删空之后 `Track` 回退文件名兜底——**这一步不在这里做**，见下。

**wav / aiff / aac / 其它 `detect_format` 认不出的**一律 `UnsupportedFormat`，界面弹
"这种格式不支持写入标签"，**文件一个字节都不动**。不假装成功。

失败（`TagError`）一律 catch 成 `Failed(TagError::message(e))`，同时返回**原样的
`data`**——调用方据此保证"不写盘"。

### 原子写：为什么不能原地截断

macOS 侧 `AVAudioPlayer` 在播放期间一直持有这个文件。原地截断再写会让正在播的那首
当场读到错位字节甚至静音。所以 `file_write_bytes_atomic` 走：

```
写 path.lunatmp  →  rename(path.lunatmp, path)
```

POSIX 的 `rename` 是原子替换：旧 inode 由播放器继续持有，新 inode 接到文件名上，
两边都不坏。真机判据就是"播放中改当前曲，音乐不断、进度不回零"。

Windows 注记：CRT 的 `rename` 不覆盖已存在的目标，退化成 `remove(目标)` + `rename`，
**这一步不原子**。Windows 半的音频探针本就是空实现（`adapter_native.c:10145`），整条
链路在那边没到可用程度，等补探针时一起处理。代码注释里写明了。

`file_read_bytes` **不复用 `library_load`**：后者走 `@utf8.decode_lossy`，会把标签里的
封面等二进制字节换成 U+FFFD，写回去就毁文件。这里必须原样搬运字节。

### 保存链路：顺序不能换

`LunaMusicApp::save_track_info(path, title, artist, album)`，五步：

1. `(self.write_tags)(path, ...)`。`Failed` / `UnsupportedFormat` 各自弹一句，**不落盘、
   不改库、不关窗**——用户能改个值再试一次。
2. `Written` 后用 `(self.probe_many)([path])` 拿回**真探针结果**，而不是自己按输入拼
   一个 `Track`。"清空字段 → 回退文件名"这条规则只长在探针那条路上，自己拼会造出
   "界面显示空标题、扫描却显示文件名"的两套行为。
3. `lib.set_meta(...)` —— 就地替换 `tracks` 里同 path 那条（`Track` 不可变，重建值），
   保住位置与总数；`player.update_track_meta(...)` —— 按 path 替换 `queue` 里那条。
   **不用 `replace_queue` / `set_queue_keep_current`**：那会清空 `history` 和随机牌堆，
   改个标题就把播放历史抹掉是不对的。
4. `view = compute_view()` + `refresh_table()` + `refresh_bar()`，属性栏若正钉着这首也刷。
   当前曲就是被改的那首时，播放条/迷你条/桌面歌词都读 `player.track()`，所以自动跟着变，
   不用额外记账。
5. 最后才 `(self.on_library_changed)()`。

### 曲库档即时落盘：为什么必须

曲库档本来**只在退出时存一次**（`shell.mbt` 末尾），而启动恢复是"直接入账、不重探"
（C-07）。不即时落盘的话，改完标题、正常退出后再打开会读回**旧标题**——文件里是新
的、曲库里是旧的。所以 `on_library_changed` 在壳里绑成
`library_save(library_path(), cm.lib.to_json().stringify())`，每次保存成功立刻写一次。

一句话口径：**改的是文件本体，曲库档只是缓存**。那也就意味着，把曲库档删掉再重扫
一遍，得到的结果应该和刚才界面上看到的一样——这是文件真的写对了的最终判据。

壳里的解环手法照 `AddDirBox`：`on_library_changed` 要读 `cm.lib`，而 `cm` 的构造又要
这个回调，用 `LibSaveBox`（一个 `mut fire` 字段）构造后再赋值。

### 界面：编辑小窗

`ui_edit.mbt` 的 `EditDialog[B]`，与播放列表 / 均衡器 / 歌词秀共用 `CmStrip` +
`cm_window_shell` 那套外壳，摆在一起才像同一个程序里的第五只窗。固定 340×196，
**不进 `CmLayout`**（那是六只常驻窗的落座表，加进去要连带改 `reset_windows` 与布局
断言），打开时按主窗位置现算一次居中。

两条手性：

1. **窗只建一次**（`LunaMusicApp.edit` 懒建），`rebuild_ui` 不碰它。整树重建会销毁
   原生输入控件，正在打的字、光标位置、输入法状态全没。
2. **输入值不镜像到 MoonBit 侧**：保存时用 `Widget::text()` 现读。打字过程零状态、
   零回调、零重建。

入口在列表行的右键菜单，「属性」之后加一项「编辑信息…」。

### 判据

- `tagwrite：四个容器往返 + 清空字段 = 删除标签` — 造最小容器骨架，写进去再用
  vendored 的实现读回来逐字比对；音频段必须一位不差地留在标签之后；
- `tagwrite：未知格式报 UnsupportedFormat 且返回原字节` — wav 这条路；
- `tagwrite：坏 Ogg 报 Failed，不崩不写`；
- `edit：保存成功——库、队列、播放条、属性栏、曲库档全换新值` — 注入假
  `write_tags`，其余走真实现；
- `edit：写入失败 / 格式不支持——库与界面一个字都不改，弹一句原因`；
- `edit：小窗懒建且 rebuild_ui 不重建它（输入不丢）`；
- `library.set_meta` / `player.update_track_meta` 的边界（只动一条、状态与历史不动）。

真机判据（无头测不到，只能手验）：**退出重开标题还在**——这条走的是 AVFoundation
探针 + 曲库档两条**独立于 moontag 的读路径**，我们写的东西被另一套实现读出来了，
才算真写对。外加 `ffprobe -show_format` 与访达「显示简介」的交叉核对。

### 不做

封面替换（`id3_apic.mbt` 未拉入，`Track.cover` 也不落盘——但上游对位写在包 README 的
「暂未取用」里，随时可回来取）、APEv2、音轨号/年份/流派、批量编辑多首。
