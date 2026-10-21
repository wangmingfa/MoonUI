# MoonUI P0 交接提示词

> 用法：把下面「=== 提示词正文开始 ===」与「=== 提示词正文结束 ===」之间的全部内容，
> 原样贴给另一台电脑上的 agent。它是自包含的——那台机器上的 agent 不需要读过本仓库
> 的任何历史会话，只需要这份提示词 + 仓库本身。

---

=== 提示词正文开始 ===

你要在 MoonUI 仓库上继续做 **P0 阶段的三项任务**。请先读完本提示词的全部约束再动手——
这个项目对"每一刀怎么做"有很具体的要求，违反了会返工。

## 0. 仓库与基线

- 仓库根：`/Users/11048490/shared/MoonUI`（**若你那台机器路径不同，以你本地实际路径为准**）
- 基线提交：`9e8e01a`（`feat(widgets): 自绘面拿到带坐标的左键，DataGrid 表头点击默认接线（T102 第七刀）`）
- 分支：`main`；**本仓库没有 remote**，所以不存在"拉不到最新"的问题
- 工具链：MoonBit `moon 0.1.20261016`；macOS 上原生后端走 Cocoa（`backends/native-macos/adapter_native.m`）
- 你的工作从 `9e8e01a` 之后开始。如果本地 HEAD 不是这个提交，先 `git log --oneline -3` 核对

## 1. 这个项目是什么（你需要的心智模型）

MoonUI 是一个跨平台 GUI 框架，写在 MoonBit 上。三层结构：

- **`packages/moonui`** —— Core 层，纯 MoonBit，跨平台共用。定义了 `Widget` / `Event` /
  `Layout` / `App` 等一切抽象。**Core 里不许出现任何 GUI 库名字**（§47 第 6 条，`moon test`
  的 wasm 清单就靠这条证明）。
- **`backends/native-common`** + **`backends/native-macos`** —— 原生后端。C 侧
  `adapter_native.m`（ObjC/AppKit），MoonBit 侧 `backend.mbt`（事件翻译 + 控件管理）。
  两平台（mac / Windows）的 MoonBit 侧**共用同一份** `native-common`，分叉全在 C 里。
- **`packages/widgets`** —— 住户控件包（`DataGrid` / `TreeView` / `Sparkline` /
  `ProgressRing`）。**只许 import Core，不许 import 任何 `backends/`**（`T107` 的依赖
  方向钉子，由 `scripts/test-local.sh` 里一条 grep 守着）。

关键概念：

- **`Widget::custom(size, paint)`** —— 自绘面。控件自己往 `DrawList` 里画，命令是纯数据，
  后端负责上屏。`DataGrid` / `TreeView` 都是自绘面。
- **Core 的鼠标事件坐标口径一律是「窗口/父局部」逻辑坐标**（`MouseDown` / `MouseUp` /
  `MouseMove` / `Scroll` 都一样）。控件局部坐标 = 事件坐标 − `widget.frame().origin`。
  这是 `T110` 刚钉死的口径。
- **事件订阅**：`Widget::on_any(handler)` / `Widget::on(kind, handler)` 就在控件身上，
  **不需要 `App`**。需要 `App` 的是**事件循环**（`App::step` / `App::run`），这两件事
  曾经被混成一件，是 `T102` 第五刀卡住的原因，别再混。
- **公开 API 的"行号"一律指数据行号**（不是显示位置）。排序/折叠会重排视图，包内用
  `grid_data_row_at` / `grid_view_pos_of` 两个互逆映射翻译，**公开 API 一个都不露位置**。

## 2. 本轮任务（P0，三项，按顺序做）

### P0-1【首选先做】T102 第八刀：滚轮与点击的默认接线

**目标**：让 `DataGrid` / `TreeView` 能被滚轮滚动——即 `DataGrid` 订阅自己的 `Scroll`
事件，把滚轮增量换算成纵向偏移。

**动手前必读的重要更正**（我已核过代码，TODO 里的旧记案不准，别被误导）：

- TODO 第 311 行写着"滚轮在 mac 上恒报窗口自己，接线与鼠标那条不是同一条路"——
  **这句话已经不准确了**。实测代码：原生后端 `backends/native-common/backend.mbt`
  的 kind 4 分支**已经**把滚轮翻译成 `@moonui.Scroll(target, LogicalPoint(dx, dy))`，
  且 target 是**命中控件**（`mouse_target_widget` 查 `live_widgets`，自绘面也在
  `live_widgets` 里所以能被命中），空白处才落回窗口。自绘后端
  `backends/canvas-macos/mouse.mbt` 的 `translate_mouse` 也已有 kind 4 分支且做了
  命中测试。**所以滚轮事件本身是齐的，缺的是"控件把它接到自己的滚动上"那一段。**
- `Core` 的 `Scroll(EventTarget, LogicalPoint)` **只带增量、不带位置点**（见
  `packages/moonui/event.mbt:125`）——这与 `MouseDown` 不同。接线时**不要**试图
  从 `Scroll` 里取"点在哪"。
- `DataGrid` 现有的滚动账：包内 `grid_max_offset` / `grid_clamp_offset` /
  `grid_effective_offset` / `grid_first_row`，公开面有 `offset()` / `set_offset()` /
  `scroll_to_row()`。滚轮接线应当复用 `grid_clamp_offset` 这条夹法（**上限会夹**，
  "最后一行贴底"），别自己另算一份。
- **增量换算的单位**：`Scroll` 里的 `LogicalPoint` 是**逻辑像素增量**（C 侧
  `native_mouse_delta()` 已把行轮/精确滚动换算成逻辑像素）。所以直接
  `offset += dy` 即可，**不要再乘行高**。

**建议的落点**（`packages/widgets/data_grid.mbt` 的 `DataGrid::new` 末尾，
与 `T110` 那段 `widget.on_any(...)` 同一个订阅里加一个 `Scroll` 分支，或另起一个
`on_any`）：

```
@moonui.Scroll(_, delta) => {
  // 纵向滚：dy 为逻辑像素增量，负值 = 向下滚（按现有 Scroll 语义核对方向）
  // 横向滚：dx 走 set_h_offset
  // 两边都要用 grid_clamp_offset / grid_clamp_h_offset 夹
  // 改了偏移要 widget.repaint()
}
```

**必须钉住的判据**（写在 `packages/widgets/data_grid_test.mbt`）：

- 用 `MockBackend::push_event` 派发带 target 的 `Scroll`，**不要**真窗。
  （`MockBackend::push_event` 在 `packages/moonui/backend.mbt:545`；`packages/widgets`
  自己的测试里已经在用这个套路，见 `packages/widgets/data_grid_test.mbt` 里 `T110`
  那条判据——第 1169 行起，照它的写法写。）
- 断言要覆盖：滚下去 offset 变大、**滚到顶/底会停住**（夹住）、**横向滚走的是
  `h_offset` 不是 `offset`**（两笔账别混——这是最容易写错的地方）。
- **数据集要留余量**：正文高要够小、行数要够多，否则滚动上限是 0，"怎么滚都是 0"，
  判据是空的（第五刀踩过这个坑）。
- **判据要可观测**：光断言"offset 变了"不够——**要断言具体行内容换到了什么位置**
  （比如第一行可见文本从 "b" 变成 "c"），否则改坏实现也可能照样绿。

**必须做的负控制**（≥3 条，每条跑完恢复并复跑确认全绿）：

- 去掉夹取（不 clamp）→ 应红在"滚到边界停住"那条。
- 把横向滚也算进纵向 `offset` → 应红在"横向滚走 h_offset"那条。
- 增量单位错（比如误乘行高）→ 应红在具体行内容那条。
- 接线没订阅事件 → 应红。

**先做的一步**：动手前先用探针确认 `Scroll` 的方向语义（`dy` 正负对应滚上还是滚下），
在**三个后端**（native / wasm / mock）上是否一致，别照着某一份猜。

### P0-2：T102 续 —— 拖放 / 多选 / 行内改名

**这三项是并列的独立工作，建议一个一个做，每项一刀。**

- **多选**：前置是**先定选择模型**——`DataGrid::selected()` 现在返回单个 `Int32`（数据
  行号），多选要定是"集合"还是"锚点 + 区间"。这个形状**建议先问 owner 裁决**，别自己
  拍板（`T102` 第五、六刀的行号口径统一就是上一轮拍的，后来擦了一轮屁股）。
- **行内改名**：要能改 `set_cell` 写进去的值，涉及编辑态（哪个 cell 在编辑、输入从哪
  来、Enter/Esc 怎么收）——形状建议先跟 `TextInput` 那套原生控件的用法对齐。
- **拖放**：牵扯 `T86⑥` 已落的 `FileDrop` 事件变体，与自绘面的拖动路径（鼠标 kind 2）。
  自绘面在 `T110` 之后已经有带坐标的左键了，拖动路径可以复用那套换算。

**这三条都别一次做完**。每一条都要按第 3 节的纪律走完整流程。

### P0-3：T109 尾巴 —— `StrokePolyline` 折线命令

**注意：这一条我建议先确认再动手。** 它当前**没有真实住户**——折线现在用 n-1 条 `Line`
拼是 `Line` 的本义，不算绕路。挂着的理由只是"`DESIGN §18` 列了 `draw_path()`"。
项目里有条明确纪律（`T107`）：**"别在没有真实住户的时候先做"**。

所以：**做之前先在 `TODO.md` 里找到第一个真实的折线需求**（比如多系列叠加图、路径动画）。
找不到就**别做**，把它留在 P2 继续挂着，在提交说明里写清"经查无真实住户，暂不做"。
这条纪律比"清单上有一项就做掉"重要。

## 3. 每一刀的纪律（**最重要的一节，请严格照做**）

这个项目的历史教训大多写在这里，逐条遵守能省掉大量返工。

### 3.1 门禁（提交前必须全跑通）

```bash
bash scripts/test-local.sh
```

它一条命令覆盖了：`moon check --deny-warn`（native + wasm）、core native 测试、
core wasm 测试、六个 examples 的 `moon run`、`moon info`（并检查 `.mbti` 漂移）、
`moon fmt --check`、mingw 交叉语法闸门、**mac 真窗测试**（`moon test backends/native-macos`）。

**当前基线的数字**（你的刀应该让它们只增不减）：

| 清单 | 基线 | 说明 |
|---|---|---|
| native 核心 | 365 | `moon test` 的 core 清单（`packages` + `examples` + `tests` + `_doccheck`） |
| wasm | 364 | wasm 清单比 core 多带 `backends/` |
| mac 真窗 | 47 | `moon test backends/native-macos`（`backends/native-common` **没有独立测试文件**，它的测试都在 native-macos 里） |

单包参考：`moon test packages/widgets` = 31 条。

另外单独跑（`test-local.sh` 已含 mingw，但 mac clang 那道不 含）：

```bash
cc -fsyntax-only -Wall -Wextra -x objective-c \
   -I backends/native-common -I ~/.moon/include \
   backends/native-macos/adapter_native.m
```

### 3.2 产物时间戳（改过 C 之后必看）

**改了 `backends/native-*/adapter_native.*` 之后，`moon test` 可能仍跑旧代码**——
moon 只在认为有 `.mbt` 变化时才重跑 prebuild/重链。症状是"修完 bug 测试还报老错"。

解法（**两样都要清**）：

```bash
rm -f _build/prebuild/adapter_native.o _build/native/debug/test/backends/native-macos/*.exe
```

只清 `.o` 不够——测试二进制 `*.exe` 自己也可能是旧的。**跑之前先 `ls -la` 看产物
时间戳**；别拿"连跑几轮都一样"当稳定性证据，那几轮可能跑的是同一份旧二进制。

（如果你这一刀**没动 C 侧**，就不涉及这个坑，但按纪律仍核一下时间戳。）

### 3.3 判据与负控制

- **每条判据写完先问一句：把被验的行为改坏，它真的会红吗？**
- **负控制全绿 ≠ 判据无效**，先怀疑判据本身，三种成因分开查：
  1. **判据不可观测**——数据要让被验的性质**看得见**（三行数据文本全一样，顺序乱了你也看不出来）；
  2. **判据挂在脆索引上**——多条判据用硬下标取正文时，别的改动一挪下标就全体红，看起来像"负控制有效"其实是判据耦合；改成按内容取（按 y 筛正文区）；
  3. **改动是等价变换**——比如两个映射方向搞反，而 `sort_order` 是排列、互逆后函数值不变；改负控制要改**语义**（退化成恒等、漏掉一层翻译），不是改符号。
- **负控制被编译错误挡住时，你看到的是「编译失败」不是「判据红」**。`--deny-warn` 下改坏一行常让整个包编译不过（典型：把 `x + hoff` 改成 `x` 之后 `hoff` 变 unused 警告 → 升级成 error → 测试**根本没跑**）。改法要保证变量仍被使用（`x + hoff * 0.0`）。
  **跑完看输出里有没有 `Total tests: N, passed: ...` 这一行——没有就是没真跑到判据。**
- **判据的数据集本身也要设计**：能滚动的数据集要比可视区多一行；**滚动上限会夹**
  （"最后一行贴底"），期望值得按夹法算，别按算术值写。

### 3.4 遇到偶发红：先证伪归因，再动手改

怀疑"是我刚写的代码"时，**先 `git stash` 掉全部改动、在干净 HEAD 上复跑**——照样红
就说明是既有缺陷，别去改不该改的地方。

**真窗测试（`moon test backends/native-macos`）特别容易假红**：

- 跑真窗测试时**让这台机器的使用者先停下操作**（真鼠标/真键盘交错会让测试假红）。
- 症状：断言里**多出来**几个没注入过的事件（比如多出 `down:z` / `down:h`）——那是**真人
  在打字**被真窗口的键盘监听抓到的，不是实现问题。**看"多出来的事件是什么"再下结论。**
- **AppKit 会吃掉测试进程里的左键首击**：测试进程不是前台应用时，左键首击被系统当
  "激活点击"消费掉——那一击走完进程级监听（`MouseDown`/`MouseUp` 照旧到）却**不进** view
  的 `mouseUp:`，所以**没有 `Click`**。实测形态：**首击有 Down+Up 无 Click、第二击才
  三条齐全**。写"一次点击应该产生哪些事件"的判据前，先点一次做激活、断言放第二击；
  同一条测试里若有"点原生按钮"的对照分支，那个分支也得同样处理，否则时红时绿。
  （这与"读像素读早了"是**两类**问题：那次是帧还没落地，这次是事件被系统吃掉了。）

### 3.5 改动范围的纪律

- **后端补事件翻译要圈定范围，不能无条件放开**。原生控件的左键消费者是控件回调发的
  `Click`，长按识别账（`T86⑧` / `App::long_press_track`）也吃 `MouseDown(Left)`——
  一并会动。`T110` 因此把左键翻译**圈定在自绘面**（`NativeBackend.custom_faces` 登记表）。
  负控制实测：放开后**T108 的中键那条既有判据也会变红**——这就是范围约束被真实钉住的证据。
- **后端自建的"身份登记表"要跟销毁同步销账**。句柄表会复用 id，销晚了后来新建的控件会
  "继承"上一任的身份。
- **`packages/widgets` 只许 import Core**，不许 import 任何 `backends/`。
- **抽象新东西时，"抽一个共用实现出来"时顺手看一眼原函数的 doc 注释有没有被劈开**——
  插入新函数容易把上一个函数的 doc 吃到中间去（编译不受影响，只有文档误导）。

### 3.6 文档同步（每刀都要做，缺一样算没做完）

改完代码要同步这几处：

- `TODO.md` —— 挂账条目下写**落地注**：卡点是什么、落地形状、判据与证据、负控制实测、
  踩坑、门禁数字、新的"还没做的"清单
- `README.md` —— 住户控件那行（`packages/widgets` 的描述）
- `API.md` —— 对应示例段
- `DESIGN.md` —— 对应章节记这一刀（**注意段落顺序要跟时间线一致**：新刀插在它解的那一刀**之后**）
- `docs/backend-lessons.md` —— 后端/平台层的踩坑
- `.workbuddy/memory/YYYY-MM-DD.md` —— 当日工作日志

### 3.7 提交纪律

- **每刀结束后直接用中文单笔提交**，不询问、不 push、**不加 `Co-Authored-By`**。
- 提交信息用中文，说清：这一刀解了什么卡点、落地形状、判据与证据、负控制、门禁数字。
- **本仓库没有 remote，也不要提醒用户是否 push。**
- 提交前**通读一遍 `git diff`**——见 3.5 最后一条。
- **不要**把 `.workbuddy/` 下的记忆文件提交进去（它们已被 gitignore，正常不会进）。

## 4. 优先级与范围建议

**建议顺序**：P0-1（滚轮接线）→ P0-2 三项各一刀 → P0-3（先确认有没有真实住户）。

理由：`T102` 是唯一有连续动能的一条线（已 7 刀，基础设施齐，判据与负控制的方法论成熟）。
滚轮接线做完，`DataGrid` / `TreeView` 在真实应用里就能滚了——这是最接近"能被真用"的里程碑。

**其余 P0 之外的东西先别碰**（留给后续阶段）：`T99` GPU/Metal（开工前要先裁决要不要做、
走 Metal 还是换后端）、`T102` 富文本 / WebView、`T98④` Windows Direct2D、`T93①`
真窗描框、`T38` 错误码（注意这条现在**基本是空账**，`backend.mbt` 里 `Unsupported` 已一条
不剩）、`T86⑦` 多窗口状态持久化、`T93②` L10n 文件加载。

## 5. 起步动作（建议的头 30 分钟）

1. `cd` 到仓库根，`git log --oneline -3` 确认 HEAD 是 `9e8e01a`，`git status --short` 确认干净。
2. 跑一次 `bash scripts/test-local.sh` —— **先确认基线是绿的**（365 / 364 / 47）。
   基线不绿就先查是不是上一刀遗留，别直接开工。
3. 读 `packages/widgets/data_grid.mbt` 的 `DataGrid::new`（第 167 行起）末尾那段
   `widget.on_any(...)`（`T110` 留下的表头点击接线），以及
   `packages/widgets/data_grid_test.mbt` 里 `T110` 那条判据——**照着它的写法写新判据**。
4. 用探针确认 `Scroll` 的方向语义与单位（mock 后端上派发即可），三个后端对一遍。
5. 然后开始 P0-1。

## 6. 遇到判断不了的事

- **形状需要 owner 裁决的**（如多选的选择模型、拖放的交互细节）：**停下来问，别自己拍板**。
  这个项目里"自己拍板 → 下一刀擦屁股"的模式已经发生过（`T102` 第五刀的排序口径、
  第六刀的回归）。
- **其它不确定的**：先查 `TODO.md` / `DESIGN.md` / `docs/backend-lessons.md` / `.workbuddy/memory/`
  ——这个项目的历史决策几乎都留在这四处。先查再问。
- 做完 P0-1 之后，**先把那一刀的完整落地注写进 `TODO.md` 与记忆文件，再开下一刀**。

祝顺利。有任何一步卡住了，把现象、已排除的可能、下一步打算发回来。

=== 提示词正文结束 ===
