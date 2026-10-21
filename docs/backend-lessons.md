# 后端踩坑与真窗口验证笔记

> 本文件从 `README.md` 抽出的深水内容：原生后端（Windows/Win32、macOS/Cocoa）接入时量出的工程事实，以及真窗口测试的逐条验证。README 只保留概览，细节留在这里。文中 `Tnn` 与 `§nn` 引用见 `TODO.md` 与 `DESIGN.md`。

## 真后端量出来的事

记下来免得再踩。**史注先说清**（`T82`，2026-10-15）：这一节量出的对象是 libui 那两份 C（adapter.c / adapter_macos.m），删 libui 后文件没了——但原生后端的两份 C 形状逐段从 adapter.c 搬过来（Windows 份文件头自证），这些结论跟着形状一起活在现树上，个别指向已删文件的路径按删除后的树读。Windows 那半（Win32 + libui-ng 的 `windows/`）八条：

- **libui 的文案 getter 是分配语义。** `uiButtonText()` 返回它自己 malloc 的一份拷贝，契约要求调用方 `uiFreeText()`；Adapter 拷进 `Bytes` 之后就还掉。还漏一块的后果不是慢慢漏，是退出时炸。
- **`uiUninit()` 末尾审计 libui 自己的分配表，发现泄漏就直接 `DebugBreak()`**（libui-ng 的 release 构建也不关这条）。没有调试器时这就是一个退不出去的测试进程 / 0x80000003。所以 `terminate()` 的前提是 MoonBit 侧句柄表已经归零，里程碑测试断言的正是这一点。这条在测试里的形状 Windows 上量过，和 mac 上不一样：一条真窗口测试中途 raise 漏下窗口，红的不是"后面每条各报一次 `1 != 0`"，而是下一条走到 `terminate()` 的测试直接死在这里，整批 `moon test backends/libui-windows` 拿不到一行测试输出（native 的 println 全缓冲，abort 即丢）。两份真窗口的测试因此各自加了"每条开头替上一条补跑收尾"的隔离（mac 是 `macos_test.mbt` 的 `sweep_leaked_handles`；Windows 那份在 `backend_wbtest.mbt` 里同一套之外还多两张按种类分开的登记表，因为 `ffi_wbtest.mbt` 那 6 条不建后端实例）。
- **`uiInit()` / `uiUninit()` 没有引用计数**，重复 init 会因窗口类已存在而失败。Adapter 把这一对守成幂等单例，同一个测试进程里跑两条冒烟才安全。
- **静态库带不进 manifest**，Common Controls v6 与 DPI 感知由 `adapter.c` 自己补（`#pragma comment(linker, ...)` + 建窗口前 `SetProcessDpiAwarenessContext`）。
- **链接参数里的 `-link` 前缀不能去。** 它是 moon 把后面一串参数转交给 link.exe 的通道，代价是每次链接多印一句 `LNK4044：无法识别的选项 "/link"，已忽略`——这条无害；去掉前缀就变成 `LNK1104：打不开 libui.a`。两头都在 Windows 上实测过：删掉那 5 个字符，先由 cl 报 `D9002`（`/LIBPATH` 被当陌生选项吞掉）和 `D9024`（`libui.a` 当源文件、"object file assumed"），再由 link.exe 报三条 `LNK1104`，三个测试 exe 一个都产不出来。
- **`ChildWindowFromPoint` 和 `SetWindowPos` 在同一个坐标系里。** 前者收父窗口客户区坐标，后者摆的也是客户区，所以按坐标注入点击不需要任何换算；命不中子窗口时它返回父窗口自己，于是"点在空白处"和"控件摆错了位置"落在同一个负数返回上——点击因此能反过来验证布局矩形真的落到了原生 HWND。
- **`MsgWaitForMultipleObjects` 报的是"上次醒来之后新到的消息"，不是"队列里还有消息"。** 队列里有积压时它能一直返回 `WAIT_TIMEOUT`，而 WM_QUIT 就躺在队列里读不到——"等一次、走一步"的泵因此会在预算无限时空转。所以 `pump` 先用 `PeekMessage(PM_NOREMOVE)` 探测、把已有消息排干才去等，并且用墙钟（`GetTickCount64`）兜一条硬预算。libui 的 `uiMainStep(0)` 帮不上忙：它把"处理了一条"和"队列本来空"都返回 1，只有 WM_QUIT 返回 0。
- **`link` 只在可执行包里生效，不会顺着 import 传下来。** `backends/libui-windows/moon.pkg` 声明的那串库对它的测试包够用（测试包本身就是可执行包），但示例壳必须自己再写一遍，否则就是整套 53 条 LNK2019——这是 MoonBit 的链接模型（`T59`/`T60` 起 example 不再手抄：prebuild-link.js 的 `link_configs` 顺 import 传播，就是为绕开这一条）。
- **libui 的菜单 API 在 Windows 上是个陷阱：不认识的命令 id 直接 `DebugBreak()`。** `windows/menu.cpp:296` 把 `runMenuEvent` 里查不到的那一条交给 `uiprivImplBug`，而 §25 的菜单项 id 是 Core 分配的编号、libui 的账本里没有，所以 `T22` 自己搭 `HMENU`（逐窗口一份，活窗口记在 64 槽的登记表里），并用经典子类化把窗口过程筛成"`WM_COMMAND` 且 `lParam=0` 且 `HIWORD(wParam)=0` 且 id 在我们那段基址（`0x4000`）之上"才接、其余原样放行（`IDOK`/`IDCANCEL` 正是 libui 要吞的那两条）。这条过滤放宽一寸，后果不是某条测试红，而是整进程 `0x80000003`、零行输出——和上面 `uiUninit` 那条同一个形态。另外两笔只在这边存在的账：`SetMenu` 会吃掉客户区一行，而 §25 是运行时才装的、libui 建窗口时按"没有菜单位"算的外框事后并不知道，所以要么建窗口就把最后一个参数给 1（让 libui 自己现量，`menu_pad` 必须留 0），要么事后装并**量**出那一行（全摘一次、挂上一次的差值；不抄 `SM_CYMENU`，不同 DPI 与菜单字体下它和真行高不等），随后每一次 `uiWindowSetContentSize` 都加回去；`MFT_RADIOCHECK` 是**类型**位不是状态位（勾选态读回要看 `fType`），`MF_DISABLED` 从不回写（写回去会变成 `MF_GRAYED`，而置灰检查读的正是它）。**这一条整段已经过真跑**：快照逐字符、两种装序的 pad、radio 读回、置灰那发 `-2` 都在那台 Windows 机器上跑绿（`T45`，2026-10-10——真跑量出 `GetMenuItemInfoW` 读回的 fType 不带 `MF_POPUP` 位，快照函数改认 `hSubMenu`）。

macOS 那半（Cocoa + libui-ng 的 `darwin/`）另加八条：

- **自动释放池是栈式的，而 `uiInit` 自己压了一层。** 把 `uiInit`/`uiUninit` 包进 `@autoreleasepool` 就是弹非栈顶的池，运行期直接 fatal（`objc: Invalid or prematurely-freed autorelease pool`），而且测试进程一行输出都不留——因为 `uiInit` 压进去的那层（libui 的 `globalPool`）活得比这次调用久。做法是自己 alloc 一层存在 `adapter_macos.m:89`，`uiUninit` 之后才 drain；`uiMainSteps`/`uiMainStep`/`uiQuit` 三个循环入口干脆不套池，AppKit 的事件对象不归本次调用管。
- **翻折自逆，所以方向单靠自己测不出来。** MoonUI 的矩形从左上量，Cocoa 的 view 从左下量，这一翻写在 `moonui_flip_y`（`adapter_macos.m:229`）里、摆位和读数共用一条公式。负控制实测：把它改成恒等，"控件矩形往返"那条的坐标断言**一条都没红**——写反的两次翻折仍然互相抵消。要钉住方向必须引入一个不经过这条路径的坐标，于是有了 `moonui_cocoa_origin_of_widget`（同文件 :1278）：顶边的控件在 Cocoa 原始 frame 里 `origin.y` 必须接近"父视图高 - 控件高"，这一条是全 suite 里唯一为方向红的。共享实现里所有别的坐标断言都做不到这件事。（那次运行其余几条也红，是 `native_live_handles()` 量的那张**进程全局**表被中途 raise 的测试污染：raise 跳过它自己的 `terminate()`，而表在 `backends/libui-common/ffi.mbt:17`、跟后端实例无关。这条已经修掉——`macos_test.mbt` 里每条测试开头替上一条补跑一次 `terminate()`（`sweep_leaked_handles`），实测注入一条故意失败的测试时红数从"9 条红 8 条"收到只红它自己，把清场改成空转又回到 8 条。更自然的 `defer` 写法走不通：MoonBit 的 panic 不执行 defer，本机量过。）
- **AppKit 不给出 `buttonType` 的读取口。** 只有 `setButtonType:`，所以 `-[NSButtonCell buttonType]` 在运行期是 unrecognized selector（实测崩在测试脚手架里）。想在 Cocoa 上把 checkbox 从"按钮"里剔出去得去问无障碍角色；而 Win32 那份本来也没剔（它的类名判断同样把 BS_CHECKBOX 算进 Button），所以两边按 `isKindOfClass:[NSButton class]` 一致，反而不用细分。
- **Cocoa 的层叠就是 `subviews` 数组顺序，和 Win32 是同一种话。** "Cocoa 没有 z-order"这句先前的判断是错的：数组末尾画在最上面，`addSubview:positioned:NSWindowBelow`（:904）就是 `SetWindowPos(HWND_BOTTOM)`，`NSWindowAbove` 就是 `HWND_TOP`。所以两个后端量出来的数一模一样——Row 得 `[0,1,2]`，同样三个控件放进 Stack 得 `[2,1,0]`（`backends/libui-macos/macos_test.mbt` 与 Windows 那份 `backend_wbtest.mbt` 各钉一条）。层叠与 Tab 在两边也确实共用同一条列表：Cocoa 靠 `setAutorecalculatesKeyViewLoop:` 按 subviews 顺序重算焦点链。
- **点是单位，Retina 是倍数。** libui-ng 的 darwin 后端根本没有 DPI 概念，`backingScaleFactor` 就是全部信息，于是 `moonui_window_dpi` 报的是倍数乘 96（本机 Retina 读出 192）。控件矩形这里过一道 px→点→px，AppKit 存的是小数坐标，所以往返自逆、断言能写到 1 逻辑像素内；而 libui 收 int 的入口（窗口尺寸、窗口位置）只吃整点，窗口级的量最坏差 1 物理像素——这就是 mac 那份测试的容差比 Windows 那份松一格的原因。
- **`uiQuit` 是 `[NSApp terminate:]`，但在 steps 模式下它只把循环标成"跑完了"。** 实测调用后进程照常在，`uiMainStep` 从这里开始返回 0，之后还能再 init 一轮——所以共享实现里 `loop_ended` 那条判定在 mac 上也成立，测试敢调它。
- **darwin 的 libui 把"固有尺寸"整个交给了 Auto Layout，`ui_darwin.h` 里没有 minimum size 的对应物。** 于是 §18 那句"量由原生层做"在 mac 上是直接问 AppKit，而且要同时问两条再**逐维取大**（`adapter_macos.m` 的 `moonui_widget_minimum_size` 起）：`intrinsicContentSize` 和 `[cell cellSize]`（后者正是 NSButton 自己算固有尺寸的算法）。只取前一条会截字——实测 label 报 81.5 而 cell 要 85.3，按钮 72x20 而 86x32，勾选框 63x16 而 65x18；差的那几像素是边框的 `alignmentRectInsets`（按钮左右各 7pt），标题在 72pt 的 frame 里只拿到 48pt，而 "Click Me" 要 52pt，于是 Demo 上显示成 "Click M"。反过来 TextInput 的 `intrinsicContentSize`（宽 96）比 `cellSize`（66）大，那是可编辑区的最小宽度而不是截字，所以取大不会把它压小。测试那条对照组直接读 AppKit 的 `[cell cellSize]`（`moonui_cocoa_cell_size_of_widget`，在文件末尾的测试脚手架那一节），不拿我们自己的数字当尺子；把实现改回只取 `intrinsicContentSize`，label、按钮、勾选框三条一起红。控件 view 一出生也没有 superview（darwin 的控件构造只 alloc/init，挂进窗口是 libui 自己的 `SetSuperview` 的事，而我们从不叫它），所以"搬进窗口客户区"这一步在 mac 上比 Windows 还短——就是 `addSubview:`。

- **libui 的 darwin 菜单在建过窗口之后就封版了，而且它的勾选是个"翻"。** `uiNewWindow` 末尾调 `uiprivFinalizeMenus()`（`third-party/libui/src/darwin/window.m:438`），此后 `uiNewMenu` 与建条目都撞 `uiprivUserBug`（`darwin/menu.m:339`）——在这台机器上是当场终止进程，而 §25 的菜单恰好是运行时才装的，所以 `T22` 的 Cocoa 那半直接搭 `NSMenu` 挂到 `[NSApp mainMenu]`（整棵换，旧的 `removeItem:` 拆干净）。第二处更要紧：`uiMenuItemSetChecked` 压根不看入参（`darwin/menu.m:252`），只把当前态翻一下——§25 的勾选态只存在 Core，"翻"在框架层就是错的语义，这就是 `Backend` 多一条 `set_menu_item_checked(id, checked)` 的原因（Core 算完**推**给后端，Radio 连同组兄弟一起推，互斥是 Core 的事、原生层不会自己取消谁）。独立尺子是 `[NSApp mainMenu]` 本身：那三条测试逐字符比的是主菜单里当下真挂着的那几顶，不是 adapter 自己抄的名单；四条负控制（摘掉 `addItem:`、摘掉 `terminate` 里那次 `moonui_menu_clear()`、摘掉交给 MoonBit 的那次调用、摘掉 `setState:`）各红在预测的那一处，逐条记在 `macos_test.mbt` 的注释与 TODO `T22` 里。顺带一条 AppKit 的规矩：`setAutoenablesItems:` 得关掉，否则 AppKit 会按"target 现在能不能响应"自己置灰我们那些没有 action 的条目，于是 `isEnabled` 变成它说了算、Core 推过去的置灰就看不见。

### §14 的落点：控件按 HWND 自己摆

libui-ng 的 Windows 后端只有容器布局（uiBox / uiGrid / uiForm），没有绝对摆放；而 §14 要 MoonUI 自己做布局、纯布局节点不占原生对象、叶子的原生父级只有窗口，§32 又要真控件保住原生外观与无障碍。三条候选路里只有"绕过 libui 的布局层"同时保住这两条，所以 Adapter 用 `moonui_control_attach` 把控件的 HWND 从 libui 的隐藏工具窗口（`windows/control.cpp` 里所有控件出生时的 parent）搬进目标窗口客户区，再按 MoonUI 算出的矩形 `SetWindowPos`。

两条不变量支撑这条捷径，都是从 vendored 源码读出来、再被冒烟测试验证的：

- 回调路由按控件 HWND 查表（`windows/events.cpp` 的 `runWM_COMMAND` 拿 `lParam` 当键，不是控件 ID），所以换父级不影响 `WM_COMMAND`；顺带一提，控件挂在 utilWindow 下时这条路由是**故意被跳过**的，搬进真窗口才收得到点击。
- 主循环对顶层祖先跑 `IsDialogMessage`（`windows/main.cpp` 的 `processMessage`），键盘 Tab 因此照旧，只是顺序跟 z-order 走。所以首次挂载把控件插到 z-order 末尾——挂载顺序即 Tab 顺序；之后的重新布局只改矩形、不动 z-order，免得 resize 把焦点链重排一遍。

代价是 libui 的容器不再替窗口收尾：控件必须在所属窗口之前逐个 `destroy_button`，否则 `DestroyWindow` 连带释放 HWND，libui 那份控件对象却不回收，退出时的分配审计就把这次运行变成 `DebugBreak`。挂回调的控件由同一次 `destroy_button` 松开闭包引用（§47 风险 1：C 长期持有的闭包不 decref 就是泄漏，不 incref 就是悬垂）。

Cocoa 那份把同一件事又做了一遍，而且更短：`moonui_control_attach` 就是 `[contentView addSubview:v positioned:NSWindowBelow]` 加一句 `setTranslatesAutoresizingMaskIntoConstraints:YES`（`adapter_macos.m` 里的 `moonui_control_attach`，按名字读）——后者是"这个 view 的 frame 由 MoonUI 管，别给它生成约束"的正式写法，而 libui 自己的容器布局站在反方向（NO + Auto Layout），既然不建 `uiBox` 就必须站到 YES 这边，否则第一次 layout 就把 `setFrame:` 的结果覆盖掉。回调路由也不看父级：action 落在控件自己的 target 上。收尾那条代价两边同名，只是 mac 上是"view 还留在 subviews 里而它的 libui 对象已经没了"，所以 `moonui_widget_destroy` 里先 `removeFromSuperview`。

### §48-15 的落点：层叠与焦点链都收到 Core

原生层只有一份顺序，它同时管着"谁画在上面"和"谁先响应 Tab"，而挂载只能给一个方向。Stack 的契约（数组靠后的盖住靠前的）和挂载顺序正好相反。`T29` 把这件事从"靠 attach/raise 的增量去凑"改成"Core 算好整份推下去"：`Widget::paint_order` 算出整窗**从顶层到底层**的绘画顺序（普通容器先序、Stack 子树叶子倒序），`set_content` 挂载之后整份推给 `Backend::set_paint_order`；焦点链是另一条——声明顺序（先序，`collect_native` 收出来的 `leaves` 原样），整份推给 `Backend::set_focus_chain`。两条链在 Core 里分开算、分开推，后端只负责"落"。不含 Stack 的树两条链同值（先序 = 声明序），行为与旧的"挂载顺序 = Tab 顺序"一致；Stack 里两条链分道——层叠倒序、焦点声明序，Tab 不再跟着层叠翻。

写出来的方向是被真窗口量过的，不是靠文档印象：`moonui_control_z_index` 在 Windows 读 `GetWindow(GW_HWNDPREV)` 的步数，在 macOS 从 `subviews` 数组末尾倒数，两边都是 0 = 最上层。同一组控件在两个后端上给同一组数——Row 的三个控件 `[0, 1, 2]`，同样三个控件放进 Stack `[2, 1, 0]`（`backends/libui-windows/backend_wbtest.mbt` 与 `backends/libui-macos/macos_test.mbt` 各钉一条）。这不是巧合，是 `set_paint_order` 在 LibuiBackend 里按倒序逐个 `raise_widget`（底层先提、顶层后提）翻译成 z-order 的结果——和旧的"挂载压底 + Stack 逐个提顶"逐位相同，所以这两条真窗口测试原样绿；"Cocoa 没有 z-order"那句旧话就是在这里被推翻的。Core 的 `paint_order` 因此可以只写一遍。

焦点链在原生后端上今天还是空操作：`LibuiBackend::set_focus_chain` 只 `check_initialized()` 一句（和 `T31` 的 `request_redraw` 在原生后端上空转同一种"契约先行、机制后补"），所以真窗口上 Tab 暂时仍是旧行为——不含 Stack 的树无感，Stack 里 Tab 仍跟着层叠翻成数组倒序。把声明顺序真正接进原生焦点机制（macOS 的 `nextKeyView` 链、Windows 的 z-order 与 Tab 本就同源）那一格挂在 TODO `T66`。没有量的那一维是 Tab 的落点：合成一条 `VK_TAB` 要先让测试进程抢到前台，而前台归属是这台机器的用户状态，实测落点跟着激活时序漂，所以没留这个脚手架（见 `adapter.h` 的说明）——`T66` 的验证要么靠真窗口上人工 Tab 走一遍、要么得先补一套稳定的 Tab 脚手架。

### §48-16 的落点：三种事件都从原生回调入队

按钮点击之外，输入框的文本变化和勾选框的勾选现在也从真控件的回调里出来（`T23`）。三条走的是同一套机制：`backend.mbt` 的 `create_widget` 在建好原生控件之后按种类挂一个闭包（`native_widget_on_click` / `on_text_changed` / `on_toggled`），C 侧用一张 `(owner, fn)` 的槽位表接住它——incref 一次，同 owner 同 fn 重复注册是替换而不是再加，槽位在 `moonui_widget_destroy` 里整批放开，所以挂三种事件不需要动销毁路径。libui 给每种控件的回调函数指针类型不同（`void(*)(uiEntry*,void*)` 对 `void(*)(uiCheckbox*,void*)`），所以每种各一个 trampoline，不能共用一个函数；trampoline 丢掉 libui 递来的 sender，因为 MoonBit 侧要的是"回头问那个控件现在的状态"，不是它报的那半句话。

于是 `push_input` 在回调里再读一次 `widget_text`，把**那一刻的全文**入队成 `Input(target, 全文)`——§48-16 那句"通知只说变了、内容要问原生对象"就落在这一步；勾选那条不需要读，`BN_CLICKED` / `onToggled:` 之后 libui 已经把状态翻好了，读的是 `moonui_widget_checked`。

测试侧的脚手架是"按坐标命中真控件，再对它做这个平台上真人会做的那件事"，两条各用各的原生入口：Windows 把焦点给那个 `edit` 再逐 UTF-16 code unit 发一条 `WM_CHAR`，macOS 把 focus view 给那只文本框再让它的 field editor 走 `insertText:`。两者都**不用**程序化改文本的入口（`EM_REPLACESEL` / `SetWindowText` / `setStringValue:`），因为那正是"Core 自己 `set_text` 不该回声成一条 `Input`"要排除的东西；这条区分是被负控制钉住的——把 mac 那份换成 `setStringValue:` 那条测试就红（Windows 侧的对应物已经在那台机器实测过了：`uiEntrySetText` 期间由 `inhibitChanged` 压住 `EN_CHANGE`，见 TODO `T34`——而且是先红了一次才逼出来的：那边原先直接发 `WM_SETTEXT`，跳过这道闸，Core 改文案于是回声成一条多余的 `Input`）。

顺着这条还钉住一件 Windows 特有的事：**勾选框和按钮共用同一个窗口类名**。libui 拿 `L"button"` 创建两者，只把样式位分开（`BS_PUSHBUTTON` 对 `BS_CHECKBOX`，`button.cpp:92-94`、`checkbox.cpp:106-108`），所以 `moonui_widget_set_text` 想按类名分派到 libui 自己的 setter（必须走 setter，见上面那条 `inhibitChanged`），在 `button` 那一支还得再看一次 `GWL_STYLE & BS_TYPEMASK`，否则就是把 `uiCheckbox*` 当 `uiButton*` 使。

这层分派改的是**类型正确性，不是可观测行为**，说清楚免得把测试估高：错派成 `uiButtonSetText` 今天看不出来——两个 setter 函数体逐行相同（`button.cpp:72-77` 对 `checkbox.cpp:70-75`），`hwnd` 在两个结构体里也同偏移（都是 `uiWindowsControl c` 之后紧跟 `HWND hwnd`）。错派成 `uiEntrySetText` 就确实是踩内存，但咬的位置和先前记的不同：`BOOL inhibitChanged` 是 `struct uiEntry` 的**最后一个**字段，而 `struct uiCheckbox` 到 `onToggledData` 就结束了（`entry.cpp:4-8` 对 `checkbox.cpp:4-8`），于是那两句赋值是往这只对象末尾**之外**多写 4 字节（先 `TRUE` 后 `NULL`），落在堆的 slack 里，今天既不弄哑勾选框也不红一条测试。所以新加那句勾选测试（`check.set_text` 之后 `assert_false(app.step())` 与 `check.text()`）钉的是"这条分支真跑过、读写都对"，它的下界由两次负控制给出：把勾选框那一支改成什么都不做 → `check.text()` 那句红；在那句 setter 之后补一次 `BM_CLICK` → 紧跟其后的 `assert_false(app.step())` 红。mac 那侧不需要这层分派（按钮与勾选框同为 `NSButton`，`setTitle:` 一支就够），但两条测试同形同序。（AppKit 里确实有一个官方的"别带我玩"开关：`NSCell` 的 `mimicOptOut` / `isMimic`——鼠标跟踪期间被收进同一个 mimic set 的一组 cell 只会各自收到 drawing 与 action **一次**，opt-out 的那个连画都不画。但那条机制只在真人鼠标 tracking 的循环里生效，我们这两句 setter 根本不进 tracking，所以"程序赋值不回声"靠的是"不发消息"，不是 mimic。写在这儿是为了下次有人问到"同一批 NSButton 会不会被连带触发"时不必再查一遍。）

一个诚实的差异：**同样一串字在两侧产生的事件条数不同**。Windows 逐 code unit 发 `WM_CHAR`，edit 每个字符发一次 `EN_CHANGE`，所以往"初值"里打两个字出**两条** `Input`（第一条带的是打进去一个字之后的"初值打"，第二条才是"初值打字"）；macOS 一次 `insertText:` 整串，同样这段只出**一条**。Core 收到的还是同一种事件（每条都带当时读回的全文），所以 MoonBit 里一行按平台分叉的代码都没有——差异全部留在两份 C 和两份测试的断言里。这正是 `T18` 定的 (a) 那个形状，也是它第一次真被用上。

macOS 这条路上有一个坑值得单独记：`hitTest:` 命中的是 **field editor**（一只 `NSTextView`，它是文本框的子视图，窗口一显示就已经在编辑），不是那只 `NSTextField`。所以命中之后得往上退到包住它的那只文本框，而且不许越过 `contentView`——不然标题栏附近那只真的 `NSTextField` 会被误认成内容区的输入框。

- **AppKit 会吃掉测试进程里的左键首击（`T110`，2026-10-22）。** 测试进程不是前台应用时，左键**首击**被系统当"激活点击"消费掉：那一击**走完进程级监听**（`MouseDown` / `MouseUp` 照旧到——监听挂在 NSApp 的派发路径上，在消费之前），却**不进** view 的 `mouseUp:`，所以控件自己那条 `Click` 不回流。实测（本机真跑量到的具体形态）：第一击 = `MouseDown` + `MouseUp`、**没有** `Click`；第二击才三条齐全。`T101` 记过"首击会被激活点击吞掉"这件事，但当时只说"首击"，没量到"首击有 Down+Up 无 Click、第二击才全"这个具体形状——本刀写判据时按"点一次就该三条齐全"写，实测只拿到两条，当场红。

  这与 `T101` 那次"读像素读早了"是**两类**问题，值得分开记：那次是**帧还没落地**（`scaffold_drain` 排一次空就解决），这次是**事件被系统吃掉了**（排空解决不了，得先点一次把激活做完）。判据写"一次点击应该产生哪些事件"之前，得先确认这一次点击真的**完整走完了 AppKit 的派发路径**——一个走监听、一个走 view 回调的测试入口，事件条数本来就不一样。

  顺带一条判据设计上的连带：同一条测试里若还有"点原生按钮"的对照分支，那个分支也得同样处理（先点一次激活、断言放第二击），否则它会**时红时绿**——首击被吞的那一次没有 `Click`，看起来像"原生按钮不回 Click"，其实是系统吃掉了。

### 死在哪一次 FFI 调用

两份 Adapter 都有 `TRACE(...)`，打开方式是一个环境变量：`MOONUI_NATIVE_TRACE=1 moon build/test ...`——prebuild-link.js 的 compileAdapter 看到它就给编译器带 `-DMOONUI_TRACE`（mac）/ `/DMOONUI_TRACE`（Windows）。不设这个变量时 TRACE 是零成本的空宏，不需要改任何 moon.pkg（`T82` 删 libui 后 moon.pkg 已不编 C，早先"在 moon.pkg 里加 `stub-cc-flags`"的做法随之作废——那份字段还要求同一份 flags 同时喂给 cl 和 clang，两边 `-D` 与 `/D` 一字之差，现在由脚本按平台分开带）。

为什么需要它：native 测试进程里 MoonBit 的 `println` 是全缓冲的，异常退出时整段丢失（macOS 上第一次撞自动释放池那次就是零输出），只有 C 侧即时 `fflush` 的 trace 留得住顺序。

### 真窗口那两批逐条

**史注先说清**（`T82`，2026-10-15）：标题里那“两批”是 libui 后端的真窗口测试（macOS 40/44 条、Windows 35/38 条），随删 libui 整体退场——还在树上的现役批是原生后端的 `backends/native-macos` 38 条与 `backends/native-windows` 15 条（`native_test.mbt`，逐条钉了什么见 TODO `T75`/`T77` 的完成注），这一节按史注保留：它钉的每一条形状（句柄隔离、剪贴板复原、模态脚手架、菜单快照、缩放分叉）在原生后端的同形测试里都在，读它就是读那些测试的形状账。macOS 那批按测试名读、不按行号（往被引用的文件插一行就把后面的引用全挪走，而挪走的引用不会自己报错）。两批都做了句柄隔离：每条开头替上一条补跑收尾，一条中途失败只红它自己，不再需要"只看第一条红"。

macOS 40 条（`backends/libui-macos`，2x 屏机器上刚跑过）：

- `T19` 剪贴板往返「真后端读写系统剪贴板，测完把原内容放回去」——读写的就是这台机器上用户的剪贴板，复原只覆盖文本形态。
- `T20` 对话框「消息框与确认框真弹原生面板，答案是按钮给的」——模态面板靠预排的那发脚手架替用户按按钮、答案来自面板自己。
- `T21` 文件 / 保存 / 文件夹「真弹出来，答案是取消」——`NSOpenPanel`/`NSSavePanel` 真弹，macOS 15.6 上面板在 XPC 服务进程里、客户端没有替按"接受"的通道，所以钉的是阻塞时间与取消映射，"选了 → 路径"交给 Windows 那份真跑（`T44`）。
- `T22` 菜单栏三条（整棵装进原生主菜单的逐字符快照 / 真点击回流成 `MenuSelect` / 失败形态和 MockBackend 逐字相同），尺子是 `[NSApp mainMenu]` 本身。
- `T39` 键盘与焦点三条（真按键成 `KeyDown`/`KeyUp`、菜单认领的 ⌘Q 只回一条 `MenuSelect` 不双响、改焦点出恰好一条 `Focus` 挪走补一条 `Blur`）加鼠标五条（按下与拖拽成 `MouseDown`/`MouseMove` 点是客户区物理像素、抬起只从不自跑的控件报上来、一条双击配一条 `Click`、滚轮方向与量级往返且两轴同时非零当场报 -5、三种失败形态返回码报回去而一条事件不许多）。
- `T40` 系统外观读数钉在「窗口尺寸、位置、缩放按物理像素往返」里，靠一条只影响本进程的 `NSApp.setAppearance:` 覆盖双向钉住（深色读到 `Dark`、浅色读到 `Light`、取消覆盖读回原值），和跑它的那台机器当下是什么主题无关，也不动用户的系统设置。
- `T24` 缩放变化两条（「窗口停在同一块屏上时一条 ScaleChanged 都不许多」与「窗口搬去另一块屏出恰好一条 ScaleChanged，搬回来再来一条」），目的屏从活后端的 `screen_size()` 现读、换屏的触发前提在移动前后各量一次 DPI，只有一块屏的机器走 `else` 分支钉"不许冒多余的那条"并打印一句换屏触发没跑到；`adapter.c` 与 `adapter_macos.m` 这次一个字都没动，它是 MoonBit 侧在每轮 `pump` 里读一次已经读过的 DPI 去重。
- `T42` 按窗口工作区一条「工作区读数与居中跟着窗口自己那块屏走」，尺子是 `[win screen].visibleFrame` 读回来的矩形对 `screen_size()` 那份**主屏**读数——这台机器的副屏 scale 是 1.0，拿主屏的倍数换算必错；窗口还没上屏时 C 退回主屏那块，而不是报一个 0 尺寸（0 尺寸会被 `LogicalRect::center` 读成"摆到左上角"，症状会被误读成居中 bug）。
- `T54` 补 mac 侧对 Windows 的两处测试不对称：「未初始化的真后端拒绝创建对象」负控制进了 `macos_test.mbt` 第一条，六条 libui 冒烟（真按钮被点一次句柄全收 / 重新摆放只改矩形不动挂接 / 点第二个只触发第二个 / 四种控件状态读写都落在真 view 上 / 窗口几何可读可写且摘下来的控件不再响应点击 / 纯布局节点没有原生对象可读）新起一份白盒 `backends/libui-macos/ffi_wbtest.mbt`，mac 那批从 28 涨到 35（28 + 1 + 6）；几何那条顺手钉住 Cocoa 的真分叉——子视图在窗口变大时锚着左下原点不动，mac 版断言是"显式 `set_bounds` 之后 origin 恢复"，与 Windows 那份的直等断言刻意不同。
- `T55` set_text 自动重排（b6537ce）的同形缺口——set_style / set_insets 存值后现在也沿父链标脏：真窗口的 set_insets 同形测试（尺子是孩子的原生 origin：内边距 10 → 30 逻辑点两轴各挪 20，mac 侧 36/36 全绿）。
- 鼠标那两条在本机量到过环境性偶发红（有人在机器上动真鼠标时，真事件和脚手架的合成事件在同一支队列里交错，排好的抬起偶发整条没送进监听），空闲机器上连跑二十次单测加四次全套全绿——真鼠标在真窗口上本来就该赢，无头 CI（`T6`）上没有真指针，这条自然消失。

Windows 35 条（`backends/libui-windows`，2026-10-11 在那台机器整批跑绿 35/35，末行 `Total tests: 35, passed: 35, failed: 0.`）：代码里是 34 条（`backend_wbtest.mbt` 28 + `ffi_wbtest.mbt` 6），2026-10-10 整批跑绿、退出码 0；2026-10-11 加上 `T55` 的 set_insets 同形测试后整批 35 条再跑一遍全绿，同轮把 `T58` 的无障碍真验一并做了。此前在那台机器跑绿过 16 条（`T34`/`T36`，2026-10-09；上一轮 14 条也是同一台机器量的，那次跑的是同步过来的提交 `9acc6b5…`，核对走内容探针——那边的提交号与本仓库对不上，两边历史分叉），原先那条"菜单如实报不支持"的钉子随 `T22` 落地删掉了，补上的 18 条就是 TODO 里九批欠账的收口，每一批都在真跑里量出过至少一枚只有真窗口才有的牙：

- 剪贴板往返（`T37`）量出 `OpenClipboard` 会被系统的剪贴板监视进程短暂占住，adapter.c 的打开加了 10 次 × 10 毫秒的有界重试。
- 对话框与文件 / 保存 / 文件夹面板（`T43`/`T44`）把模态脚手架在那台机器上真走到面板跟前。
- 菜单栏那四条（`T45`）量出 `GetMenuItemInfoW` 读回的 fType 不带 `MF_POPUP` 位（本机探针实测 fType=0x0、hSubMenu 有值），子菜单只能认 `hSubMenu`，adapter.c 的快照函数为此改了一处。
- 键盘与焦点那三条（`T46`）量出真硬件发的 VK 是大写 `0x41`~`0x5A` 而查找表折成小写，`moonui_key_read_name` 补成两种都收、出口统一小写。
- 系统外观读数（`T47`）是那条几何测试按注册表读数的复跑。
- 缩放变化那两条（`T51`）在这台单屏机器走"不许冒多余的那条"分支。
- 按窗口的工作区那一条（`T52`）把 `MonitorFromWindow` 那两条从没进过编译器的入口第一次真编真跑。
- 鼠标那半那五条（`T53`）量出脚手架的滚轮格数要按 Win32 的规矩乘上 `WHEEL_DELTA` 进 HIWORD 才读得回来（投裸格数恒得 `Scroll(0,0)`），以及 BS_PUSHBUTTON 把 `WM_LBUTTONDBLCLK` 当一次按下、双击总账两边从此同形为 1 DoubleClick 配 2 Click 而不是 3——`adapter.h` 的判据段照实订正。

这台 Mac 给 Windows 那批到的还是类型检查，从 `T40` 起还多一道交叉预编译（`scripts/test-local.sh` 里若有 `x86_64-w64-mingw32-gcc` 就拿它把 `adapter.c` 过一遍 `-fsyntax-only -Wall`；第一次用就抓到 `MF_RADIOCHECK` 这个不存在的宏，正确拼写是 `MFT_RADIOCHECK`）。牙齿是往新测试里插一句不存在的名字：`T23` 那次是 `let _bogus_probe : Int = "teeth-check"` → Error 4014，`T22` 那次是把「菜单栏整棵装进活窗口的原生菜单位」那条里的 `menu_dump_full` 改成不存在的名字 → Error 4021 unbound；两次都当场改回，`moon check` 会说 `now up to date` 吃缓存，所以不发这一探针就不能说"读过这个文件"。顺带留一句 `T23` 那次真跑的收获，它揪出的是只有 Windows 才有的 bug——`moonui_widget_set_text` 原先直接发 `WM_SETTEXT`，绕过 libui 的 `inhibitChanged`，于是 Core 自己改文案会回声成一条多余的 `Input`，现在改成走 libui 的 setter。

`macos-backend-link` 为什么是"测试真跑 + 示例只连"而不是一条命令：闸门是 `moon test --target native backends/libui-macos`（2026-10-14 `T6` 起去掉 `--build-only`，44 条真窗口测试当场跑）+ `moon test --target native backends/native-macos`（原生 Cocoa 那半，38 条）+ `moon build --target native examples/hello-libui examples/counter-libui examples/form-libui examples/todo-libui examples/file-manager-libui examples/gallery-libui`（只连不跑，要真人关窗口）。听起来更直白的 `moon build backends/libui-macos` 在本机冷 target-dir 实测是**红的**——库包没有 `main`，`moon build` 照样去链接它，健康的树也报 `Undefined symbols: _main`。这几条盖的链接配置现在只有**一份**：仓库根 `prebuild-link.js`（moon.mod 的 `--moonbit-unstable-prebuild` 指过去，构建前注入 `backends/libui-macos`、顺 import 传给这几条命令要链接的每个可执行产物，TODO `T59`）。2026-10-11 之前是**六份**——库包 `backends/libui-macos/moon.pkg` 那一份，和 `examples/` 下五份可执行包各自 `moon.pkg` 里的副本（`link` 不顺着 import 传，副本会独自腐烂，在它进闸门之前没有任何 job 编过它）；五份副本是 2026-10-10 从一份涨上来的（`T28` 的 macOS 那半新建 counter / form / todo / file-manager 四份，每份把同一串 `-lobjc -framework Cocoa third-party/libui/lib/libui.a` 再抄一遍），`T59` 用 prebuild 机制收成了一份。产物凭什么算"真的链接过"：`nm` 数出来 428 个 `_ui*`/`_uipriv*`（只可能来自 `third-party/libui/lib/libui.a`）、49 个 `_moonui_*` 是已定义的外部符号（`adapter_macos.m` 编出来的），`_uiInit` 是 `T` 而不是 `U`，`otool -L` 里 Cocoa / AppKit / libobjc 三条 load command 都在。**这几个数里只有 `_moonui_*` 那一个当天就写明了口径（已定义的外部符号），`T22` 之后在同一道闸门上重数：它从 49 涨到 66**——ABI 从 47 个入口涨到 64 个，另加两个 `moonui_cocoa_*` 探针，逐条对得上；`T39` 之后在同一道口径下再数是 74（72 条 ABI 入口加那两个探针）；`T40` 之后在本机最近一次 mac 真窗口测试的产物（`_build/native/debug/test/backends/libui-macos/libui-macos.blackbox_test.exe`）上按同一条口径重数：**76**，逐条对得上——73 条 ABI 入口加三条 mac 专用探针（`moonui_cocoa_origin_of_widget` / `moonui_cocoa_cell_size_of_widget` / `moonui_cocoa_set_appearance_override`，最后那条是 `T40` 为外观断言加的进程级覆盖，申报在 `adapter_macos.m` 而不是 `adapter.h`，所以不进 ABI 计数）；同一条口径今天在本机全量重编之后的五份 `-native-macos` 可执行文件上各数了一遍，**五份都是 78**（`T42` 给 ABI 加了那两条按窗口的工作区入口，于是 75 条 ABI 入口加三条探针），`_uiInit` 五份都是 `T`，未定义的 `_moonui_*` 一份都是 0，这条数是本机量的，CI 那道闸门上的产物要等那一次真跑才算它自己的数；而那句"428 个 `_ui*`/`_uipriv*`"今天在同一份产物上数不出同一个数（`nm -g | grep ' _ui\| _uipriv'` 是 276 行，只算已定义是 269 个），当时用的到底是哪一条命令没写下来，所以链接这一格别再拿总数当尺子，判据留给"`_uiInit` 是 `T`、`_moonui_*` 全部已定义、三条 load command 都在"这三句。这些尺子来自链接器、`nm` 和 `otool`，不是我们自己的代码。这个 job 本身在 CI 上的第一次真跑没法本地验证——本仓库没有 remote，workflow 要推上去才跑得起。

快照测试和断言测试的取舍写在 AGENTS.md：稳定的结果用 `assert_eq`，结构化的调试输出用 `debug_inspect`。

- **程序化改文本会连输入法的标记区间一起清掉。** `-[NSTextField setStringValue:]` / `-[NSTextView setString:]` 都走"整段换文本"那条路，`markedRange` 随之作废——从输入法视角是脚下的文本被人抽走，表现成 Core 收到一条 `ImeEnd`、组合串凭空消失。`set_text` 因此在编辑视图上要先取标记串、写正文、再 `setMarkedText:` 标回文末；空串组合（`marked.length == 0`）不在此列，那就是一次正常的取消。同理，读文本时"组合串算在文本里"是既有语义（`text()` 在组合中返回"正文 + 组合串"），改文本的返回值要跟这条对齐，不能只报程序写进去的那半。

- **`moon` 不会因为 `.m` 改了就把测试可执行重链一次。** 链接参数走 `link_flags`，里面挂的是**路径字符串**（`_build/prebuild/libadapter_native.a`），文件内容变了而路径没变，moon 的依赖哈希就看不出变化——测试可执行原样留着，跑的是上一份 C。只删 `_build/prebuild/adapter_native.o` 也不够（prebuild 会重编那个 `.o`，但 exe 还是不重链），必须把 `_build/native/debug/test/<包路径>/*.exe` 一起删（mac 真窗是 `.../test/backends/native-macos/`）。`T100` 的第一轮负控制就是这么假绿的：`.o` 时间戳已经是新的、断言全绿，删掉 exe 之后同一份代码当场红在 `Rotate(5156.62) != Rotate(1.570796)`。判据很简单——**改 C 之后第一条命令就是 `rm -f` 那两处产物**，看见"绿"先怀疑缓存，别怀疑断言。

- **AppKit 没有公开入口造 gesture 事件，所以手势的自动化只能验"派发之后"。** `+[NSEvent otherEventWithType:...]` 不收 `NSEventTypeMagnify` / `Rotate` / `Swipe`，`CGEvent` 也没有对应的事件类型（键盘有 `CGEventCreateKeyboardEvent`、滚轮有 `CGEventCreateScrollWheelEvent`，手势是死路）。于是 `T100` 的三支脚手架投的是监听处理器算完之后的那个共享函数（`moonui_native_gesture_dispatch`）：命中反查、编码读回、闭包过 C 帧、MoonBit 翻译、Core 派发全在断言里，"AppKit 会不会真把 magnify 交给本地监听"与 `NSEventPhase → 四档` 的映射退回人手捏一次。这与托盘"真弹窗"那半（`T91⑥`/`T105`）是同一档取舍：能自动化的那一段做到底，剩下那一格明确写出来，不假装覆盖了。

- **给 `Backend` trait 加方法，必须同一次提交把 `pub extend ... with Trait::{...}` 的清单补齐。** `T101` 加 `draw_custom` / `measure_text` 两条口子时，两个具体后端（`NativeBackend`、`CanvasBackend`）都实现了，编译却红在 `implicit_impl_as_method`——新语法下 trait 的方法会隐式提升成普通方法，`extend` 块里没登记就是一条 deny-warn 级的弃用诊断（`--deny-warn` 下直接是 error）。诊断文本提的是"隐式实现即方法"，与"少写了个名字"看起来没关系，第一次撞会往 trait 定义那边找。另有一条同源的：`MockWidget` 因为 `derive(Debug, Eq)` 要求 `DrawList` 也能 Debug/Eq，给数据型命令枚举加 `derive(Debug, Eq)` 比在 mock 里手写 `to_string` 便宜，也让失败断言能打出差异。

- **测试文件后缀决定它看得见什么：`*_test.mbt` 是黑盒，`*_wbtest.mbt` 是白盒。** `T101` 的 Core 判据要读 `mock_widgets()`、`widget_error()`、`MockBackend::widget()` 这些包内私有项，写在 `custom_widget_wbtest.mbt` 才编得过；写在 `_test.mbt` 里的症状是"`Type Unit does not implement trait Backend`"——因为那几个函数一个都解析不到，`mock_widgets()` 退化成 `Unit`。判据要摸内部账就选 `_wbtest`，这是选择而不是妥协。

- **合成的左键事件会被"激活点击"吞掉，右键不会。** `T101` 的点击脚手架第一版照 `right_click_in_window` 的做法造了一对真 `NSEvent` 走 `[NSApp sendEvent:]`，结果探针读得到像素、`Click` 一次都不回来：测试进程不是前台应用，左键首击落在 AppKit 的激活逻辑里（右键没这条规矩，所以右键那条一直是绿的）。改成依次调那只 view 自己的 `mouseDown:` / `mouseUp:`——事件对象仍是真 `NSEvent`（含窗口坐标），"按下并原地抬起"那条判据照跑，绕开的只是应用激活语义。要真验激活路径就得 `activateIgnoringOtherApps:`，那是把测试变成一次前台抢焦点，不值得。

- **像素探针证明的边界要写在判据旁边。** `moonui_native_custom_probe` 读的是 `layer.contents` 那张 CGImage（`present_view` 贴上去的就是 `begin_frame` 开出来的位图本身），用 1×1 `CGBitmapContext` 读单像素——它证明"图层里有这些像素、坐标没有翻错"，**不**证明"合成器把窗口扫到了屏幕"。后者归 FP1 的手测。同类边界还有一处：它读的 y 要按 `(h-1-y)` 翻一次（CG 的 y 向上、位图缓冲第 0 行在顶），只读一个点的话"上下镜像"这种错照样能过——所以那条真窗判据同时读左上与左下两块色块。

- **合成的鼠标事件没有 window 归属，而测试进程里 `[NSApp keyWindow]` 恒 nil。** `T108` 补 `send_mouse_in_window` 的 mac 半时，滚轮那一支第一版的症状是"返回 0 但一条事件都没有"——不是造不出事件，是事件进了监听之后被第一句 `win = [e window]` 判成 nil 整条丢掉：`+[NSEvent eventWithCGEvent:]` 转出来的事件 `windowNumber` 是 0，AppKit 在 `sendEvent:` 里不替它补；而 `+[NSEvent mouseEventWithType:...]` 造的按下/拖动/抬起**带**我们传的 `windowNumber`，所以那几支一直是绿的，只有滚轮这一支掉坑里。兜底到 `[NSApp keyWindow]` 也不行——实测测试进程里它恒为 0x0（键盘那条同款兜底之所以从没被发现，是因为键盘事件自带 windowNumber，那一支根本走不到）。最后的做法是投送侧把目标窗口登记进一个 static（`moonui_native_synth_wheel_win`），监听在 `[e window] == nil` 那支接住它：真事件都带 window，这一支只服务合成滚轮，代价与边界都写在了 C 侧注释里（合成滚轮不会被 NSScrollView 真正消费，"滚轮真把滚动容器滚了"这条脚手架证明不了）。

- **会自跑的控件（NSButton、滚动条）在合成的按下里要一颗"排队等着的"抬起，否则测试是挂住而不是红。** `NSButton` 的 `mouseDown:` 会开 tracking 嵌套循环，从事件队列取那一颗抬起；`[NSApp sendEvent:]` 是直派、根本不进队列，于是循环等不到——表现为测试进程卡死。解法是先把配套的抬起 `postEvent:atStart:NO` 排进队列再发按下（双击因此是"第一对直发 + 第二对排队"）。同一条 `NSEvent.h` 事实的另一面：嵌套循环不收监听，所以落在自跑控件上的那颗抬起永远不报给 Core（adapter.h 记的"抬起两边不等价"），断言要按真值来。

- **`CGEventPost` 那条"真路"在测试进程里走不通，退回 `[NSApp sendEvent:]` 直派。** 滚轮试过 `CGEventSetLocation` + `CGEventPost(kCGHIDEventTap, ...)`——WindowServer 按位置路由，而测试进程的窗口层叠时序不可控（刚 `activateIgnoringOtherApps:` 完也不保证在那一瞬是最前的），事件进不到我们的队列。直派换来的是同步可断言，代价记在 C 侧注释里。

- **诊断 C 侧"到底走到哪一步"最快的办法是临时 `fprintf(stderr, ...)`：测试二进制的 stderr 会出现在 `moon test` 的输出里**，比反复改断言去猜快得多。这次靠两行诊断（一行打在监听 handler 入口、一行打在投送处）一次就咬出"`[e window]` 与 `keyWindow` 双双为 0"，省掉了三四轮盲改。用完记得连临时加的 `#include <stdio.h>` 一起删——那份文件平时只在 `MOONUI_TRACE` 下才 include 它。

- **跨包的测试看得见 public 函数，看不见 `pub struct` 的字段。** `T107` 要在 `packages/widgets` 里断言"这一帧画了什么"，第一反应是 `b.widget(h).custom_draw`——编译不过，`MockWidget` 的字段对包外不可见（`pub struct` 只公开类型名）。补的不是"把字段改成 pub"（那是把 mock 的账本变成公共 API），而是加一条与 `scroll_content_of` 同形的读回口 `MockBackend::drawn(h) -> DrawList?`：**mock 的账本要能被读，否则控件包只能靠肉眼看窗口**。同一条经验的反面也成立：`inspect(x)` 要 `Show`，而 `DrawCmd` 只有 `derive(Debug, Eq)`，在别的包里打印命令会报 `does not implement trait Show`——要么 `fail("第 N 条不是 X")`，要么拿 `assert_eq` 让 Debug 差异自己说话。

- **`grep` 闸门要只看 import 行，别扫整份文件。** `T107` 给 `packages/widgets/moon.pkg` 加了"不许 import `backends/`"的闸门，第一版是 `grep -q "backends/"`，结果**当场误伤自己**：那个文件的注释正在解释这条规则，里面就写着 `backends/`。改成 `grep -qE '^[[:space:]]*"[^"]*backends/'`（行首可缩进的双引号路径）之后才对——判据要盯着"依赖边"，不是"文件里出现过这个词"。

- **"先让真实控件把需求顶出来，再动 ABI"这个顺序是能省钱也能省设计的。** `T107` 的 `ProgressRing` 需要画弧，直觉是给 `DrawList` / `Painter` / 画布 ABI 各加一条 `Arc`（四个后端 + 两份 C）。实际做法是先拿 72 段 `Line` 拼：8px 线宽下接缝缺口 `w/2 × sin(2.5°)` ≈ 0.09px，肉眼不可见，于是一条 ABI 都没动就把控件交付了。换来的是一份**具体**的缺口清单（面积图要闭合多边形填充、环想要单条弧、一帧 72 次 `CGContextStrokePath` 有点多），而不是"我们觉得以后可能需要 `draw_path`"。反过来也记一笔：`Line` 拼折线**不是**绕路，直线段本来就是它的语义——判断"这是不是将就"的标准是"语义对不对"，不是"命令条数多不多"。

- **内边距要按"最胖的那一笔"算，不是按线宽算。** `Sparkline` 第一版 `pad = line_width / 2 + 1`，坐标判据全绿——因为判据算的是同一个公式。真问题在视觉上：端点圆的半径（3）比半根线宽（0.75）大得多，最高/最低那个点被画在 `y = 1.75`，圆的上半截落到控件矩形之外，会被后端裁掉。改成 `pad = max(line_width / 2, dot) + 1` 之后才不裁。教训有两层：①任何"描边/圆点贴边"的绘制，内边距要覆盖整笔画幅的一半；②判据和实现用同一个公式时，它证明的只是"实现没变"，证明不了"看得对"——所以那条判据的期望值要**手算**写死（`pad = 4` 是我们自己推的，不是从代码里抄的）。

- **画弧的角度方向要落到像素上验证，不能靠读代码确认。** `T109` 给 `DrawList` 加了 `StrokeArc`（口径：0° = 三点钟、顺时针为正、`|扫过| ≥ 360` 画整圈）。mac 半最终**不用** `CGContextAddArc`，而是按角度采样成折线再一次性 `StrokePath`，两个理由都踩过：①CG 的弧角度按 y **向上**定义，而位图上下文在开帧时被翻成 y 向下——直接用它就得再翻一层（交换起止角、或把 sin 的符号反过来），**翻错一次画出来的是镜像的那一半**，而"镜像的弧"在清单对账里看不出错（命令参数一样），只有像素能说话；采样折线把角度直接定义在 y 向下的屏幕坐标系里（点 = `cx + r·cosθ, cy + r·sinθ`），转换只有一次、就写在点公式里。②负扫角（逆时针）不能把负 delta 直接丢给 `AddArc`：它会把小于起点的终点补 2π，画出剩下那一大圈，于是本该在右上角的 90° 弧变成覆盖左半屏的 270°。教训：凡是"角度符号 / 坐标系翻转"的账，**至少一条判据要读像素**，别只信命令参数对账。

- **改完 C 又改回原样的负控制，会把 `.o` 留成旧版本。** `moon test` 只在认为有 `.mbt` 变化时才重跑 prebuild / 重链；C/ObjC 文件（`adapter_native.m` / `adapter_native.c`）不在它的变化判定里。所以"临时改 C 跑负控制、再改回原样"之后，`_build/prebuild/adapter_native.o` 仍是负控制那版的二进制，接下来任何 `moon test backends/native-macos` 都跑的是错误实现，而且**只在该条 C 相关的像素/行为判据上红**，很容易误判成"代码写错了"。根因定位套路：负控制脚本结尾必须 `diff` 备份核对源码真的还原，跑完门禁前先 `rm -f _build/prebuild/adapter_native.o _build/native/debug/test/backends/native-macos/*.exe` 强制重编。`T109` 这一轮就踩过：像素判据本身正确，是门禁跑在陈旧 `.o` 上才红；清掉 `.o` 重编后 43/43 全绿。**同一条坑还有更隐蔽的一半：光清 `.o` 不够，测试二进制 `*.exe` 自己也可能是旧的**——`moon` 不把 `.mbt` 之外的变化算进重链判定，`internal_test.exe` 的时间戳会停在改动之前，于是"连跑三轮"跑的是同一份旧二进制，三轮结论全不可信。判据要先看产物时间戳（`ls -la _build/native/debug/test/backends/native-macos/*.exe`），别拿"跑了几轮都一样"当稳定性证据。

- **偶发红要先去干净 HEAD 上把"归因"证伪掉，再动手改。** `T109` 落地时 `T101`（自定义面像素判据）起红，一度被归因为"新加的 `CGContextAddArc` 在翻转 CTM 上污染 CG 线程态、让同进程别处偶发丢命令"。证伪只要一步：`git stash` 掉本轮全部改动、清掉陈旧产物、在**干净 HEAD** 上复跑——照样红在同一处、同样两个值，于是"是我新写的代码"这个前提当场倒掉。教训：**"偶发红"最容易诱导人往刚动过的地方找，而真因往往是既有缺陷**；而且二分定位法（换成别的绘制命令复跑）在陈旧产物上是**无效的**——临时改 C 跑的那几轮跑的其实是旧二进制，测出来的"相关性"是假的。本轮就是先被这条带偏了半天才证伪。

- **读到像素的判据要先把"帧落地"做实；"半成品帧"症状很像"某几笔没画"。** `T101` 的像素探针读的是自定义面 `layer.contents` 里那张位图，而自定义面的首帧是**懒显示**的——摆出来那一次不会立刻把位图 present 到图层上，要等一次 run loop / 显示过程。于是单步 `app.step()` 之后立刻读像素，会读到"蓝底已经铺上、后面几笔还没落到图层"的半成品帧：症状是**顶部的方块判得到、底部那块判不到**（顶部那笔先画、显示早一步），看上去极像"底部那块没画出来"。定位手法是**先打印一列像素**再改实现：在 x=4 处从 y=0 扫到 80，绿块若在图里（只是读早了）就说明是时序问题，若压根不在图里才是绘制问题——这一列打印直接省掉一整轮猜测。修法不是加 sleep，而是用脚手架既有的 `scaffold_drain(app)`（循环 `app.step()` 把事件排空、让帧落地）在**像素断言之前**排一次空；排空后连跑三轮 43/43 全绿。教训：**判据读到的是"某一时刻的产物"时，要先确认那个时刻产物已经完整**。

- **填充路径的"闭合"在 CG 里是免费的，所以它验不出来。** `T109` 第二刀给 `DrawList` 补 `FillPolygon`（闭合多边形填充）时，自然会想"去掉 `CGContextClosePath` 看看判据红不红"——结果**全绿**：`CGContextFillPath` 会把开放路径自动闭合成路径，所以那是个**等价变换**，不是有效负控制（与"两个映射方向搞反"同一类：排列的两个方向恰好互逆）。"首尾相连"这条约定真正能验的形式是**"调用方给哪种写法都一样"**——重复首点与不重复首点画出来必须逐像素相同。这条更一般的教训：**一条负控制全绿，先问"它是不是等价变换"**，再问"判据是不是空的"。

- **数组过 C ABI 的打包要验符号扩展与右移语义，别想当然。** 顶点表打包成「小端 int32 × 2 + 长度」，MoonBit 侧用 `Int32::to_int64` 再逐字节移位。这两条语义是前提：`to_int64` 必须是**符号扩展**（否则负坐标变成大正数）、`>>` 必须是**算术右移**（否则高字节取错）。实测确认：`-5` 打出 `FB FF FF FF`，正是 int32 的小端表示。验证方式是一个几行的 `moon run` 探针，比在 C 侧对不上字节再回头猜快得多。


- **"某个后端已经把某个事件报给控件了"这句要以 C 侧源码为准，不能以记案或二手描述为准。** `T102` 第八刀开工前核实滚轮 target 时，记案（`TODO` / 提示词）说"原生后端 kind 4 已把 target 落到命中控件"，实际 mac 的 `adapter_native.m` 里滚轮那一支是 `if (owner == nil || wheel)`——**`wheel` 为真时无条件跳过命中**，注释也写着"滚轮恒报窗口自己（2026-10-18）"，于是 `mouse_target_widget` 拿窗口句柄查不到、落回 `drop_target_window`。三个后端的口径因此各不相同：mac 原生恒报窗口、Windows 原生 `ChildWindowFromPoint` + 钩子里反查 owner（能到控件）、`canvas-macos` 的 `translate_mouse` 按坐标命中（能到控件）、mock 由测试自己指定。教训有两条：①"事件齐了吗"这个问题必须**逐后端、逐事件类型**核 C 侧那一支，一句概括会把三个后端抹成一个；②只改控件包（订阅自己的 `Scroll`）能让 mock / 自绘 / Windows 生效，但 mac 原生上那一发永远不会到控件——**能在 mock 上绿的判据，不等于这个功能在真窗上可用**，缺口要单独记在 `TODO` 里，别让"判据全绿"读成"已经能用"。
