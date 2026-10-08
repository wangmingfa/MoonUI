# TODO

约定：

- 每一项行尾带日期，格式 `（YYYY-MM-DD）`，记的是**这条被写下的那天**。
- 做完把 `[ ]` 改成 `[x]`，日期换成完成那天，行中间保留原来的写下日期：
  `（2026-09-12 记 / 2026-10-08 完成）`。
- 每次往这个文件写东西之前，先清一遍：**`[x]` 且完成日期满一个月的，直接删**。
  做完的事 git log 和 README 都记着，这里不留档案。
- **`[ ]` 多久都不动它**，不删也不搬去 issue。超过一个月没落地的，通常正是最难或
  最架构性的那条，它留在这里，直到有人真做了、或者决定不做（那是一次有意的删除，
  不是到期）。
- `§48-nn` 是设计文档里那条路线的步骤号，留着是为了能和 README、代码注释对上。
- 这里只记"还没成立的事实"：写清现在什么是真的（哪个调用 raise、哪个分支没挂、
  哪个 job 被排除），而不是只写目标。

## 真后端：平台与工具链

- [ ] `scripts/build-libui.sh`：unix（GTK3）/ macOS（Cocoa）两条编译路径，现在只有 `build-libui.ps1`（Windows）（2026-10-08）
- [ ] 把 `backends/libui` 按平台加回 CI 闸门（§48-22~24）。现状：排除它的是 `core` job 的传参而不是脚本——那条是 `bash scripts/ci-packages.sh packages examples tests _doccheck`（`ci.yml:71`），压根没列 `backends`，而 `scripts/ci-packages.sh` 唯一的规则是目录名以 `*-native` 结尾（那是 `examples/hello-native`）。`core-portability`（wasm，§47"Core 里不许出现 GUI 库名字"的证明）倒是传了 `backends`（:134），今天两边都过。**类型闸门现在就能加**：`moon check --deny-warn backends/libui` 在 macOS 上不用 meson、不用现编的 `libui.a` 就能过，而且它连 `backend_wbtest.mbt` 一起类型检查——探针是往那条测试里塞一个 `let x : Int = "…"`，check 立刻报 4014，改回去文件按哈希复核过是逐字节复原的。缺的只剩链接和真窗口那两段：`moon build backends/libui` 要 `scripts/build-libui.ps1` 的产物（不入库），`moon test backends/libui` 的 14 条要一只有人在点的窗口，只有 Windows 有（2026-10-08）
- [ ] macOS/unix 上重验层叠方向：`moonui_control_z_index` 数的是 Win32 的 `GW_HWNDPREV`，这条在 GTK/Cocoa 上根本没有对应物，`raise_widget` 在那两边怎么实现要另想（2026-10-08）

## 真后端：还没接的能力

这些方法现在都如实 `raise Unsupported`，`backend_wbtest.mbt` 里有测试钉住那八条消息——接一条就同步改那条断言，别让测试替谎言背书。

- [ ] 剪贴板读写（§48-18）：Win32 `OpenClipboard`（2026-10-08）
- [ ] 消息框 / 确认框（§48-19）：`uiMsgBox`（2026-10-08）
- [ ] 打开文件 / 保存文件 / 选文件夹（§48-19）：`IFileDialog`（2026-10-08）
- [ ] 菜单栏（§48-20）：`uiNewMenu`（2026-10-08）
- [ ] TextInput 的文本变化事件、Checkbox 的勾选事件（§48-12/13/16）。现状：`create_widget` 里只有 `@moonui.Button` 分支挂了 `on_click`，其余种类是 `_ => ()`，所以真后端上输入框改了文字不会产生任何事件（2026-10-08）
- [ ] `ScaleChanged` 的原生来源（§48-21）。换算那半已经落地（`scale_of_window` / `scale_of_widget` 被读写尺寸的四条方法用着），Core 侧的派发路由也有（`app.mbt` / `window.mbt` 各有测试）；缺的是真后端把系统的缩放变化推成一条事件（2026-10-08）

## 真后端：Demo 覆盖

- [x] `examples/hello-native` 跑通真窗口（§48-09~11，2026-10-08 完成）
- [x] Stack 的层叠落到真后端，方向被 `native_control_z_index` 钉住（§48-15，2026-10-08 完成）
- [ ] counter / form / todo / file-manager 这四个 Demo 的 native 版；form 要等输入框事件，file-manager 要等文件对话框，所以顺序上它们排在上面两条之后（2026-10-08）

上面那两条 `[x]` 是这次立规则时留下的样例，按约定它们到 2026-11-08 就该删了。

## Core / 设计层欠账

架构性欠账不会因为过了一个月就消失，所以这一节不参与任何到期规则，只做长期挂账。

- [ ] §32 的焦点链由 Core 自己管：原生层只有一份子窗口顺序，它同时管绘画和 Tab，Stack 的层叠因此把内部叶子的 Tab 顺序翻成了数组倒序（这条代价写在 `widget.mbt` 的 `apply_layers` 和 README 那一节里，不是隐藏问题）。同一条欠账还挡住第二个后端的形状：`Backend::raise_widget`（`packages/moonui/backend.mbt:84`）假定"层叠 = 原生 z-order"，MockBackend 拿 `MockWindow.z_order` 数组模拟（同文件 :113、读取口 `child_z_order` :268），真后端量的是 Win32 的 `GW_HWNDPREV` 步数；自绘后端（§51 的 Backend #2）根本没有 z-order 这回事，只有 Core 给的绘画顺序。层叠与焦点一起收到 Core，这两件事才同时解开（2026-10-08）
- [x] `Style`/`Theme` 没有任何到后端的通路，自绘后端拿不到配色与字号（§15/§16/§18，2026-10-08 记 / 2026-10-08 完成）：`Backend` 多了一条 `set_widget_style`（`backend.mbt:67`，方法数 41 → 42），契约是"先推样式、再测量"——`Window::relayout`（`window.mbt:443`）先跑 `root.apply_styles(self.style_base)` 再 `do_layout`，顺序反了就会拿旧字号的度量排新矩形。`Widget::apply_styles`（`widget.mbt:533`）沿 Core 树把 `resolved_style` 的结果发给叶子，纯布局节点不占原生对象所以直接往下透传，每层拿到的都是同一个 base（父容器覆盖由 `resolved_style` 走祖先链解决，不在这里累加）。`style_base` 存在窗口里（`window.mbt:24`），`App::create_window`（`app.mbt:136`）建好窗口就灌一次，`App::set_theme`（`app.mbt:72`）换主题时对未关闭的窗口逐个重推重排——所以它的签名从 `Unit` 变成 `raise UiError`、后端参数多了 `: Backend`，这是一次有意的破坏性改动。`widget_intrinsic_size` 仍然只收句柄：样式是后端"当下持有"的那份，尺寸由它算；§18 那种"Core 交 `Style`、后端回报尺寸"的形状没采纳，因为那样"控件长什么样"会在两处各说一遍。Mock 侧 `font_size`/`font_weight` 真的进度量（`mock_widget.mbt` 的 `mock_intrinsic` 多收一个 `Style?`），四条测试钉住度量随样式走、下发的是解析值、换主题会重推、容器上的字号进叶子；libui 侧是有意的不生效（§32 要保住系统原生外观），那条豁免连同它的两处代价写在 `backends/libui/backend.mbt` 里——不校验句柄（句柄检查全在 C 侧），以及两边度量不一致意味着跨后端的布局断言只能用不带 `font_size` 的样式；真后端那半的断言（`backends/libui/backend_wbtest.mbt:121~127`）今天只过了类型检查，行为要 Windows 上 `moon test backends/libui` 跑过才算数。剩下"配色/圆角/透明度要画出来才看得见"那一半挂在下面那条帧事件里。
- [ ] 事件循环是纯拉的，空闲窗口没有任何"该画一帧"的信号。现状：`App::step`（`app.mbt:304`）一圈只跑 `post` 的任务再取一个 `poll_event`，`None` 且本轮无任务就返回 false，`run` 的 while 随即 break（`drive`/`run` 在 :318/:335）。契约写在 `app.mbt` 文件头："真实后端的 `poll_event` 阻塞到有事件或循环关闭，返回 `None` 只表示循环结束"，LibuiBackend 照它实现（`backends/libui/backend.mbt:184~194`，产品语义是 `wait_budget_ms = -1` 一直等）。原生控件后端因此没事——重绘是系统的事；自绘后端要么被这个 `None` 判成"循环该退"，只能自己造事件续命。缺的是两处：`Event` 的 16 个变体里（`event.mbt`）没有 Timer/Frame/NeedsRedraw，`Backend` 里也没有 request_redraw / schedule。便宜的地方在于 `App::dispatch`（`app.mbt:253`）分流是 `MenuSelect` + catch-all（:265），新增事件变体不会让它编译失败，成本集中在后端侧。样式下发那半已经落地（`Backend::set_widget_style`），但它带过来的配色/圆角/透明度只有真的画一帧才看得见——自绘后端那一半要等这条才能验证，今天 Mock 上能断言的只有度量，libui 上是有意不生效（2026-10-08）

## 记着别再做的

这一节不按时间清——它是结论，不是待办，过期删会把踩过的坑还回去。要删只能因为代码层面已经不相关了。

- 别尝试合成 `VK_TAB` 去量对话框管理器的行进方向：`SetFocus` 要先让进程抢到前台，而前台归属是本机的用户状态，实测落点跟着激活时序漂。层叠只需要"绘画和 Tab 共用同一条列表"这条 Win32 定义，方向靠 `z_index` 钉（`adapter.h` 末尾有同样的说明）
