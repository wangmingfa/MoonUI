// 模块级 prebuild 配置脚本（TODO `T59`，Windows 半 `T60`；`T67` 起还自编
// C adapter）：把链接参数在构建前注入，让它顺 import 传给下游的可执行包
// （示例壳，及后端包自己的测试二进制）。
//
// 为什么存在：`moon.pkg` 的 `link` 只在被链接的可执行包里生效，库包声明的
// 不顺 import 传下来，于是每个壳都得抄一份 `cc-link-flags`。moon 的
// `--moonbit-unstable-prebuild` 机制（moon.mod 的 options 里指到本文件）让
// 脚本在构建前跑一次、往 stdout 吐一份 JSON，其中的 `link_configs` 会挂到
// 指定包上并传播给依赖它的可执行包。机制只在 native/LLVM 后端跑（wasm 与
// `moon check` 都跳过），需要 PATH 里有 node。
//
// `T82`（2026-10-15）删 libui 收敛单后端之后，本脚本只剩**一份配置**：挂在
// backends/native-common 上——本脚本按宿主现编的平台 adapter（adapter_native.o
// / .obj）加那一串平台链接参数，一起顺 import 传给所有下游。`T80` 那次"平台
// 共享半劈出来挂 packages/moonui"的回避整个失去前提（那份回避的存在理由是
// 前台门让链 libui 的可执行同时吃到两份 common 的配置），共享半（-lobjc/
// -framework Cocoa）并回 native-common 这一份。挂 native-common **不**挂
// native-macos / native-windows：测试二进制住在后端包里，配置若挂在那一侧会被
// moon 对"包库 + 测试可执行"各应用一次、把 adapter 对象链两遍撞重复符号。
//
// 按宿主分支（借 justjavac/moonbit-dialog 的写法）：只吐当前平台那一份。
// moon 跑本脚本时环境里带 MOON_HOST_OS，兜底再认 process.platform；两边都不
// 是 darwin/win32/linux 时各吐当前平台那一份（Linux 后端已于 T235 落地：
// hostOS 返 linux 走 `compileAdapter` 的 linux 分支，链接参数由 pkg-config
// 现取 gtk4/cairo；应用层仍只调 @native-common，drop-in ABI 不变）。
//
// Windows 那份的 link_flags 逐字抄自原先 backends/native-windows 对应的
// libui-windows/moon.pkg 里的 cc-link-flags；开头那个 cl→link.exe 的分隔符
// `-link` 在 `T71`②（2026-10-22）收掉了——`T14` 那会儿删它会 LNK1104 是
// moon.pkg 时代 cl 驱动链接的形状，prebuild 的 link_flags 由 moon 直接喂给
// link.exe，留着只换来每条二进制一条 LNK4044 噪音，删后真跑链接照过。这里
// **不**借 moon 的 MSVC 自动翻译（`-lfoo`→`foo.lib`）改成通用写法：那套
// 翻译在这台机器上没量过，而这串 MSVC 原样是 T7/T50 真跑验证过的形状，先
// 保形状。
//
// 注意相对路径按当前工作目录（仓库根）展开，与原先 moon.pkg 里的行为一致，
// 所以 moon 命令仍必须在仓库根跑。

const fs = require("fs")
const os = require("os")
const path = require("path")
const { spawnSync } = require("child_process")

/// 原生 Win32 后端（§51 的 Backend #2，Windows 半，T75）的链接参数：同一批
/// 系统库（comctl32/uxtheme/ole32 是 trackbar/DPI 主题/文件面板那批要的）——
/// 直写 Win32 的 adapter 只用控件和 GDI 那档。开头那个 `-link` 在 `T71`②
///（2026-10-22）收掉了：它是 cl 驱动 link.exe 时的分隔符（`T14` 那会儿
/// moon.pkg 直写 `link` 时非要不可），而 prebuild 的 link_flags 由 moon 直接
/// 喂给 link.exe——实测每条测试二进制链接都报一条 LNK4044
/// "unrecognized option '/link'; ignored"，删掉后链接照过、噪音消失。
/// `T86⑥` 起加 shell32：Shell_NotifyIconW 在它里面（托盘/通知）。
/// `T98`④（2026-10-21）加 gdiplus（画布光栅化走 GDI+ flat API）、msimg32
///（present 的 AlphaBlend 在它里面）与 windowscodecs（WIC 的 IID 在 C 下
/// 得链这个库，initguid 管不到它）；`T90②` 那笔"真链接要补 -limm32"的
/// 欠账一并还上（IME 组合事件的 ImmGetContext 一族在 imm32）。
// `T233` 第二刀再加 `/OPT:REF,NOICF`：链接期丢掉未引用的测试脚手架实现
// （与 mac 半 -Wl,-dead_strip 对称；`,NOICF` 关掉相同 COMDAT 折叠，只做段回收，
// 行为更贴近 mac）。它要配合编译期 `/Gy`（见 compileAdapter 的 Windows 分支），
// 否则所有函数还在同一段里、/OPT:REF 摇不掉单函数。
const windowsNativeLinkFlags =
  "user32.lib kernel32.lib gdi32.lib comctl32.lib uxtheme.lib comdlg32.lib ole32.lib oleaut32.lib oleacc.lib uuid.lib advapi32.lib shell32.lib gdiplus.lib msimg32.lib windowscodecs.lib imm32.lib /OPT:REF,NOICF"

/// 原生 Cocoa 后端的 macOS 链接参数：平台事实（ObjC runtime + Cocoa），本
/// 目录的 ABI 头 adapter.h 在 `T82` 起也住在这里。共享半从 packages/moonui
/// 并回本份的理由见文件头注释（T80 回避随 T82 失去前提）。`T86⑥` 起加
/// UserNotifications：系统通知走现代的 UNUserNotificationCenter（NSUserNotification
/// 已废弃），框架头由 SDK 自动搜到，链接时那半在这串里。2026-10-18 再加
/// Accelerate：音频频谱的 vDSP（fftsetup/ctoz/fft_zrip）在那半里。`T102`
/// 第二十五刀再加 WebKit：平台 WebView（WKWebView + WKNavigationDelegate）
/// 的类与协议在那半里。
// `-Wl,-no_warn_duplicate_libraries`：`T104` 之后 adapter 以静态库挂链接，
// 配置所属包自己的测试可执行会把同一份 .a 出现两次——ld 本就只拉一次成员，
// 这里只是把那条 "ignoring duplicate libraries" 的提示静音（本机 ld 实测支持）。
//
// `T233` 第一刀再加 `-Wl,-dead_strip`：产品 exe 不该链测试脚手架。本脚本只吐
// 一份 `link_configs`、所有可执行包共用同一份 .a，而 adapter 只有一份 .o，
// "按宏隔离"做不到（宏在编译期决定，这里没有按目标分叉的维度）。改成编译期
// 给函数/数据各自分段 + 链接期丢未引用段：产品 exe 里没人引用的
// `moonui_native_*` 测试入口被 ld 丢掉，真窗测试二进制有 extern 引用照旧留着。
// **Windows 半（`T233` 第二刀）**：直链 .obj 也能做对称处理——编译期 `/Gy`
// 让每个函数/数据进各自 COMDAT 段、链接期 `/OPT:REF,NOICF` 丢未引用段（见
// `windowsNativeLinkFlags` 与 compileAdapter 的 Windows 分支）。本机 macOS 没有
// MSVC 真链可验、mingw `-fsyntax-only` 证不了链接行为，真链接验证（产品 exe
// `dumpbin /SYMBOLS` 差集、负控制摘 flag 重链）记 win11 TODO，不假装有门禁。
const macosNativeLinkFlags = "-lobjc -framework Cocoa -framework UserNotifications -framework AVFoundation -framework CoreMedia -framework CoreAudio -framework AudioToolbox -framework MediaPlayer -framework Carbon -framework Accelerate -framework Metal -framework QuartzCore -framework WebKit -Wl,-no_warn_duplicate_libraries -Wl,-dead_strip"

/// Linux / GTK4 后端的链接参数（§47 第三个适配器，T235）：GTK4 + Cairo 的
/// 库清单由 pkg-config 现取（不同发行版 / 多架构下硬编码会漏符号）。只在
/// Linux 宿主调用——mac/win 构建路径不碰它，避免在非 Linux 上无故跑 pkg-config。
function linuxNativeLinkFlags() {
  const r = spawnSync("pkg-config", ["--libs", "gtk4", "cairo"], {
    stdio: ["ignore", "pipe", "pipe"],
  })
  if (r.status !== 0) {
    process.stderr.write(
      "[prebuild] pkg-config 找不到 gtk4 / cairo（T235）。\n" +
        "  请在 Linux 上装 libgtk-4-dev 与 libcairo2-dev，再跑 moon 命令。\n",
    )
    return ""
  }
  return r.stdout.toString().trim()
}

/// Linux / GTK4 后端的**编译**参数（T235 P3）：GTK4 + Cairo 的头搜索路径由
/// pkg-config 现取（-I/usr/include/gtk-4.0 … 以及 gtk4 自带依赖）。编译期
/// 必须拿到它，否则 `#include <gtk/gtk.h>` 找不到（链接期的 --libs 不提供头）。
/// 只在 Linux 宿主调用，与 linuxNativeLinkFlags 对称。
function linuxNativeCompileFlags() {
  const r = spawnSync("pkg-config", ["--cflags", "gtk4", "cairo"], {
    stdio: ["ignore", "pipe", "pipe"],
  })
  if (r.status !== 0) {
    process.stderr.write(
      "[prebuild] pkg-config 取不到 gtk4 / cairo 的编译参数（T235）。\n" +
        "  请在 Linux 上装 libgtk-4-dev 与 libcairo2-dev，再跑 moon 命令。\n",
    )
    return []
  }
  // pkg-config 输出是一串以空格分隔的 -I/-D 标志，按空白拆成数组直接喂给 cc。
  const flags = r.stdout
    .toString()
    .trim()
    .split(/\s+/)
    .filter((s) => s.length > 0)
  // 4.6 最低版本闸（T235 P6-3）：生成物的 prelude 里也写了同样两条（带 #ifndef
  // 守卫），这里再传一份是双保险——两条都在，任何一条被谁删掉都还有另一条钉着。
  // 为什么必须钉：①用了比 4.6 新的 API 要当场编不过（Ubuntu 22.04 的 GTK 是 4.6）；
  // ②不钉的话，4.10 起弃用的那批接口（GtkMessageDialog / GtkFileChooserNative 等，
  // 而它们在 4.6 上是唯一可用形态）在 4.24 上每条都刷 -Wdeprecated-declarations。
  flags.push("-DGDK_VERSION_MIN_REQUIRED=GDK_VERSION_4_6")
  flags.push("-DGDK_VERSION_MAX_ALLOWED=GDK_VERSION_4_6")
  // glib 半（T235 CI 首跑② 的第三枚缺口，2026-11-10 补）：Ubuntu 22.04 是
  // glib 2.72，而 g_free 在 >=2.78 的头里会展开成 g_free_sized。MIN/MAX 必须
  // 成对：只写 MAX 会被 gversionmacros.h 的 sanity check 直接 #error。
  // 生成物 prelude 里也写了同一对（带 #ifndef 守卫），这里再传一份是双保险。
  flags.push("-DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_72")
  flags.push("-DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_72")
  return flags
}

function hostOS() {
  const fromMoon = process.env.MOON_HOST_OS
  if (fromMoon) {
    // moon 若透传 Rust 的 std::env::consts::OS 就是 "macos"/"windows"/"linux"；
    // 兼容 "darwin"，process.platform 兜底时也会出现它
    return fromMoon === "darwin" ? "macos" : fromMoon
  }
  if (process.platform === "darwin") {
    return "macos"
  }
  return process.platform === "win32" ? "windows" : process.platform
}

/// `T125`：找出本机的 MSVC 工具链，给 prebuild 那条 cl 调用补一份
/// `INCLUDE` / `LIB`。为什么要有这一步：`compileAdapter` 是直接
/// `spawnSync("cl", ...)`，参数只有三个 `/I`，头文件搜索路径靠继承调用者环境——
/// 普通 PowerShell 没跑过 vcvars 时 cl 起得来、`stdint.h` 找不到，
/// `adapter_native.obj` 于是根本没生成，链接再把 152 个 `moonui_native_*` /
/// `moonui_canvas_*` 报成 LNK2019（2026-10-26 实测，报错面看上去是"链接缺符号"）。
///
/// 已经有 `INCLUDE` / `LIB` 的壳（vcvars、VS 开发者命令行、CI）原样用 PATH 里的
/// cl，不多走这一步；否则按 vswhere → `VC\Tools\MSVC\<ver>` → Windows Kits 的
/// Include/Lib 逐层推。找不到返回 null，由调用方打一条明确提示——不让 C1083
/// 缩在构建日志里、被后面的链接错误盖住。
function windowsToolchain() {
  if (process.env.INCLUDE && process.env.LIB) {
    return { cl: "cl", env: process.env }
  }
  const pgx86 = process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)"
  const pg = process.env.ProgramFiles || "C:\\Program Files"
  // 版本号排序（14.43.34808 / 10.0.22000.0 这类），取最大的一份。
  const newest = (names) =>
    names.slice().sort((a, b) => {
      const na = a.split(/[.\-]/).map(Number)
      const nb = b.split(/[.\-]/).map(Number)
      for (let i = 0; i < Math.max(na.length, nb.length); i++) {
        const d = (na[i] || 0) - (nb[i] || 0)
        if (d !== 0) {
          return d
        }
      }
      return 0
    }).pop()
  const hasToolset = (root) =>
    root !== null && fs.existsSync(path.join(root, "VC", "Tools", "MSVC"))
  let vsRoot = null
  const vswhere = path.join(pgx86, "Microsoft Visual Studio", "Installer", "vswhere.exe")
  if (fs.existsSync(vswhere)) {
    const r = spawnSync(
      vswhere,
      ["-latest", "-products", "*", "-property", "installationPath"],
      { encoding: "utf8" },
    )
    if (r.status === 0 && r.stdout) {
      vsRoot = r.stdout.trim().split(/\r?\n/).pop() || null
    }
  }
  if (!hasToolset(vsRoot)) {
    // vswhere 不在或没吐结果时扫默认布局：...\Microsoft Visual Studio\<年版>\<版次>。
    const found = []
    for (const base of [pg, pgx86]) {
      const root = path.join(base, "Microsoft Visual Studio")
      let years = []
      try {
        years = fs.readdirSync(root)
      } catch {
        continue
      }
      for (const year of years) {
        const yearDir = path.join(root, year)
        let eds = []
        try {
          eds = fs.readdirSync(yearDir)
        } catch {
          continue
        }
        for (const ed of eds) {
          found.push(path.join(yearDir, ed))
        }
      }
    }
    vsRoot = found.find(hasToolset) || null
  }
  if (!hasToolset(vsRoot)) {
    return null
  }
  let toolset = null
  try {
    toolset = path.join(vsRoot, "VC", "Tools", "MSVC", newest(fs.readdirSync(path.join(vsRoot, "VC", "Tools", "MSVC"))))
  } catch {
    return null
  }
  const targets =
    process.arch === "arm64" ?
      { host: "Hostarm64", target: "arm64" }
    : process.arch === "ia32" ? { host: "HostX86", target: "x86" }
    : { host: "HostX64", target: "x64" }
  const cl = path.join(toolset, "bin", targets.host, targets.target, "cl.exe")
  if (!fs.existsSync(cl)) {
    return null
  }
  // Windows SDK：环境里有 KitsRoot10 就用它，否则默认目录；版本取含
  // um\windows.h 与 ucrt\stdio.h 的最大一份。
  const kitsRoot = process.env.WindowsSdkDir || path.join(pgx86, "Windows Kits", "10")
  let sdkVersion = null
  try {
    sdkVersion =
      newest(
        fs.readdirSync(path.join(kitsRoot, "Include")).filter((v) =>
          fs.existsSync(path.join(kitsRoot, "Include", v, "um", "windows.h")) &&
          fs.existsSync(path.join(kitsRoot, "Include", v, "ucrt", "stdio.h"))
        ),
      ) || null
  } catch {
    return null
  }
  if (sdkVersion === null) {
    return null
  }
  const inc = path.join(kitsRoot, "Include", sdkVersion)
  const lib = path.join(kitsRoot, "Lib", sdkVersion)
  const include = [
    path.join(toolset, "include"),
    path.join(inc, "ucrt"),
    path.join(inc, "shared"),
    path.join(inc, "um"),
    path.join(inc, "winrt"),
  ].join(";")
  const libs = [
    path.join(toolset, "lib", targets.target),
    path.join(lib, "ucrt", targets.target),
    path.join(lib, "um", targets.target),
  ].join(";")
  return { cl, env: { ...process.env, INCLUDE: include, LIB: libs } }
}

/// 按宿主编译平台 C adapter，返回产物路径。成功返回路径；失败返回 null（构建
/// 会以"链接时找不到符号"的方式红掉，比在这里静默退出更可诊断）。
///
/// 参数对齐 moon 自己编 native-stub 的那一路：include 路径给包目录（adapter.h
/// 的相对引用在 ../native-common）和 ~/.moon/include（moonbit.h）。macOS 用
/// cc（.m 文件 clang 自动按 ObjC 处理，-Wall -Wextra——构建期就要看见告警）；
/// Windows 用 cl，头/库路径由 `windowsToolchain` 补（`T125`：普通 PowerShell
/// 没有 vcvars 环境，不能再指望调用者自带 INCLUDE/LIB）。
/// 源文件没动过就不重编（mtime 比对，比对两边各自平台的源文件加共享的
/// adapter.h——`T71` 量过旧缓存不比头文件的坑。本脚本每次 native 构建都被
/// moon 调起、由这里的 mtime 比对守卫重编与否——`T97`② 的实测形状：只
/// touch adapter.h 会重编、只 touch 源文件会重编、什么都不改不重编、只
/// touch `.mbt` 不重编）；`moon clean` 清掉
/// _build 也无妨，下一次构建自动补。
function compileAdapter(osName) {
  const outDir = path.join("_build", "prebuild")
  fs.mkdirSync(outDir, { recursive: true })
  const moonInclude = path.join(os.homedir(), ".moon", "include")
  if (osName === "macos") {
    const src = path.join("backends", "native-macos", "adapter_native.m")
    const hdr = path.join("backends", "native-common", "adapter.h")
    // `T166` 起 adapter_native.m 还 #include vendored 的 stb_vorbis.c——它不在
    // 下面的源比对里就会重演 T71 的坑（改了它、缓存不重编、跑到旧二进制假绿）
    const vendored = path.join(
      "backends",
      "native-common",
      "third-party",
      "stb_vorbis.c",
    )
    const out = path.join(outDir, "adapter_native.o")
    // 缓存比对：源文件、adapter.h、vendored 的 stb_vorbis.c 三者取较新
    // `T233`：编译参数本身也是缓存键。只比 mtime 的话，改了这里的 flag 却没
    // `moon clean` 会继续拿旧 .o（同 `T157` 的坑）——dead_strip 于是静默失效。
    const compileArgs = [
      "-c",
      "-Wall",
      "-Wextra",
      // 函数/数据各自分段，`-Wl,-dead_strip` 才能逐段丢掉未引用的测试入口。
      "-ffunction-sections",
      "-fdata-sections",
      "-x",
      "objective-c",
      "-Ibackends/native-macos",
      "-Ibackends/native-common",
      "-I" + moonInclude,
    ]
    // 排查"死在哪一次 FFI 调用"：MOONUI_NATIVE_TRACE=1 moon build ...
    // 给 C 里即时 fflush 的 TRACE 打开（见两份 adapter 的头注）。
    if (process.env.MOONUI_NATIVE_TRACE) {
      compileArgs.push("-DMOONUI_TRACE")
    }
    const stamp = path.join(outDir, "adapter_native.args")
    const signature = compileArgs.join("\n") + "\n"
    const argsChanged =
      !fs.existsSync(stamp) || fs.readFileSync(stamp, "utf8") !== signature
    if (
      !fs.existsSync(out) ||
      fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs ||
      fs.statSync(out).mtimeMs < fs.statSync(hdr).mtimeMs ||
      fs.statSync(out).mtimeMs < fs.statSync(vendored).mtimeMs ||
      argsChanged
    ) {
      const args = compileArgs.concat([src, "-o", out])
      const r = spawnSync("cc", args, { stdio: ["ignore", "pipe", "pipe"] })
      if (r.stdout) {
        process.stderr.write(r.stdout)
      }
      if (r.stderr) {
        process.stderr.write(r.stderr)
      }
      // `T234` 第一刀：把 `T125` Windows 半那条的中文诊断形状推广到 mac 半。
      // cc 起不来（Xcode 命令行工具没装 / PATH 里没有它）时 spawnSync 给的是
      // r.error 而非非零 status；原来只 return null，链接期"缺一堆符号"会把
      // 真因盖住。编译失败同理，把"先看 clang 原始输出"写明白。
      if (r.error) {
        process.stderr.write(
          "[prebuild] macOS 平台 C adapter 编不起来：找不到 / 起不来 cc（T234）。\n" +
            "  请装 Xcode 命令行工具（xcode-select --install），或确认 cc 在 PATH 里。\n" +
            "  底层错误：" + r.error.message + "\n",
        )
        return null
      }
      if (r.status !== 0) {
        process.stderr.write(
          "[prebuild] macOS 平台 C adapter 编译失败（cc 退出码 " + r.status + "，T234）。\n" +
            "  上面是 clang 的原始输出；先修 C 编译错误，别去追后面的链接缺符号。\n",
        )
        return null
      }
      fs.writeFileSync(stamp, signature)
    }
    // 打包成静态库再挂链接（`T104`）：`link_configs` 所属包自己的测试可执行会
    // 把它应用两次，直接链 .o 就是 237 条 duplicate symbol。同一份 .a 出现两次
    // 时 ld 只在需要时拉成员——第二次没有新的未定义符号就整份跳过，重复无害。
    const lib = path.join(outDir, "libadapter_native.a")
    if (
      !fs.existsSync(lib) ||
      fs.statSync(lib).mtimeMs < fs.statSync(out).mtimeMs
    ) {
      const ra = spawnSync("ar", ["rcs", lib, out], {
        stdio: ["ignore", "pipe", "pipe"],
      })
      if (ra.stderr) {
        process.stderr.write(ra.stderr)
      }
      if (ra.status !== 0) {
        return null
      }
    }
    return lib.replaceAll("\\", "/")
  }
  if (osName === "linux") {
    const src = path.join("backends", "native-linux", "adapter_native_gtk.c")
    const hdr = path.join("backends", "native-common", "adapter.h")
    const out = path.join(outDir, "adapter_native_gtk.o")
    const compileArgs = [
      "-c",
      "-Wall",
      "-Wextra",
      // 函数/数据各自分段，对称 mac/win 的 dead-strip（T233 同形）。
      "-ffunction-sections",
      "-fdata-sections",
      // 必须 -fPIC：Ubuntu 的 gcc 默认按 PIE 链接，静态库里若有非 PIC 的数据引用，
      // 链接期报 "relocation against `g_param_spec_types' in read-only section"
      // （CI 首跑实测），新版 binutils 会直接按错误处理。mac 的 x86_64 本来就是
      // PIC，所以这半在 mac 上从来没暴露过。
      "-fPIC",
      "-x",
      "c",
      "-Ibackends/native-linux",
      "-Ibackends/native-common",
      "-I" + moonInclude,
      // GTK4 + Cairo 的头搜索路径由 pkg-config 现取（编译期必须，否则
      // <gtk/gtk.h> 找不到；与 linuxNativeLinkFlags 的 --libs 对称）。
      ...linuxNativeCompileFlags(),
    ]
    if (process.env.MOONUI_NATIVE_TRACE) {
      compileArgs.push("-DMOONUI_TRACE")
    }
    const stamp = path.join(outDir, "adapter_native_gtk.args")
    const signature = compileArgs.join("\n") + "\n"
    const argsChanged =
      !fs.existsSync(stamp) || fs.readFileSync(stamp, "utf8") !== signature
    if (
      !fs.existsSync(out) ||
      fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs ||
      fs.statSync(out).mtimeMs < fs.statSync(hdr).mtimeMs ||
      argsChanged
    ) {
      const args = compileArgs.concat([src, "-o", out])
      const r = spawnSync("cc", args, { stdio: ["ignore", "pipe", "pipe"] })
      if (r.stdout) process.stderr.write(r.stdout)
      if (r.stderr) process.stderr.write(r.stderr)
      if (r.error) {
        process.stderr.write(
          "[prebuild] Linux 平台 C adapter 编不起来：找不到 / 起不来 cc（T235）。\n" +
            "  请确认 gcc/cc 在 PATH 里、且已装 libgtk-4-dev 与 libcairo2-dev。\n" +
            "  底层错误：" + r.error.message + "\n",
        )
        return null
      }
      if (r.status !== 0) {
        process.stderr.write(
          "[prebuild] Linux 平台 C adapter 编译失败（cc 退出码 " + r.status + "，T235）。\n" +
            "  上面是 gcc 的原始输出；先修 C 编译错误，别去追后面的链接缺符号。\n",
        )
        return null
      }
      fs.writeFileSync(stamp, signature)
    }
    const lib = path.join(outDir, "libadapter_native_gtk.a")
    if (!fs.existsSync(lib) || fs.statSync(lib).mtimeMs < fs.statSync(out).mtimeMs) {
      const ra = spawnSync("ar", ["rcs", lib, out], { stdio: ["ignore", "pipe", "pipe"] })
      if (ra.stderr) process.stderr.write(ra.stderr)
      if (ra.status !== 0) return null
    }
    return lib.replaceAll("\\", "/")
  }
  const src = path.join("backends", "native-windows", "adapter_native.c")
  const hdr = path.join("backends", "native-common", "adapter.h")
  const out = path.join(outDir, "adapter_native.obj")
  // 缓存比对：源文件与 adapter.h 两者取较新（T71 的坑）。`T233` 第二刀：编译
  // 参数本身也是缓存键——只比 mtime 的话，改了 /Gy 却没 `moon clean` 会继续
  // 拿旧 .obj（同 T157 的坑），dead-strip 于是静默失效（与 mac 半对称）。
  const compileArgs = [
    "/utf-8",
    "/c",
    // `T233` 第二刀：函数/数据各自进 COMDAT 段，链接期 /OPT:REF 才能逐段丢掉
    // 未引用的测试入口（与 mac 半 -ffunction-sections 对称）。
    "/Gy",
    "/Ibackends/native-windows",
    "/Ibackends/native-common",
    "/I" + moonInclude,
  ]
  // 排查"死在哪一次 FFI 调用"：MOONUI_NATIVE_TRACE=1 moon build ...
  // 给 C 里即时 fflush 的 TRACE 打开（见两份 adapter 的头注）。
  if (process.env.MOONUI_NATIVE_TRACE) {
    compileArgs.push("/DMOONUI_TRACE")
  }
  const stamp = path.join(outDir, "adapter_native_windows.args")
  const signature = compileArgs.join("\n") + "\n"
  const argsChanged =
    !fs.existsSync(stamp) || fs.readFileSync(stamp, "utf8") !== signature
  if (
    !fs.existsSync(out) ||
    fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs ||
    fs.statSync(out).mtimeMs < fs.statSync(hdr).mtimeMs ||
    argsChanged
  ) {
    const args = compileArgs.concat([src, "/Fo:" + out.replaceAll("/", "\\")])
    const tc = windowsToolchain()
    if (tc === null) {
      // `T125`：把真因写明白——不然后面的链接会把"缺 152 个符号"摆在最显眼处。
      process.stderr.write(
        "[prebuild] 找不到 MSVC / Windows SDK 的头与库（T125）。\n" +
          "  请在 \"x64 Native Tools Command Prompt for VS\" 或 Developer PowerShell 里跑 moon 命令，\n" +
          "  或确认已安装 Visual Studio 的\"使用 C++ 的桌面开发\"工作负载。\n",
      )
      return null
    }
    const r = spawnSync(
      tc.cl,
      args,
      { env: tc.env, stdio: ["ignore", "pipe", "pipe"] },
    )
    if (r.stdout) {
      process.stderr.write(r.stdout)
    }
    if (r.stderr) {
      process.stderr.write(r.stderr)
    }
    if (r.status !== 0) {
      // `T234` 第二刀：把 Windows 半的 cl 编译失败也显式写出来，和 mac 半对称。
      // 原来只转发 stderr 后静默 return null，链接期"缺一堆符号"会把真因盖住。
      process.stderr.write(
        "[prebuild] Windows 平台 C adapter 编译失败（cl 退出码 " + r.status + "，T234）。\n" +
          "  上面是 cl 的原始输出；先修 C 编译错误，别去追后面的链接缺符号。\n",
      )
      return null
    }
    fs.writeFileSync(stamp, signature)
  }
  // 返回值要进 link_flags：那里 moon 会按转义解析字符串，Windows 的反斜杠
  // （\p、\a 这类）被当转义符剥掉——实测（2026-10-13，T68）链接器收到的是
  // "_buildprebuildadapter.obj" 而 LNK1181。link.exe 认正斜杠，cl 的 /Fo:
  // 仍用上面的反斜杠原样（那条不经 moon）。
  return out.replaceAll("\\", "/")
}

const linkConfigs = []
const osName = hostOS()
if (osName === "macos" || osName === "windows" || osName === "linux") {
  // 唯一的一份配置挂 backends/native-common（理由见文件头注释）：本脚本现编的
  // adapter 顺 import 传给所有下游——示例壳、后端包自己的测试二进制。任何
  // 可执行包**只**链接这一份 adapter 对象：后端包从 moon.pkg 的 native-stub
  // 改吃这里的产物（T67 起）。
  const nobj = compileAdapter(osName)
  if (nobj !== null) {
    let flags
    if (osName === "macos") {
      flags = macosNativeLinkFlags
    } else if (osName === "windows") {
      flags = windowsNativeLinkFlags
    } else {
      // GTK4 + Cairo 的链接参数由 pkg-config 现取（T235）。
      flags = linuxNativeLinkFlags()
      // 末尾补一个 `-lm`：moon 工具链给的那枚 `-lm` 排在 `libruntime.a` 之后、
      // **adapter 之前**（见 CI 日志的 cc 命令行）。GNU ld 扫到它时 adapter 还没
      // 被拉进来、没有 libm 符号待解，--as-needed 就把这枚 -lm 丢掉了；等
      // adapter 里的 `llround` 出现，libm 已不在命令行上，于是报
      // `undefined reference to 'llround@@GLIBC_2.2.5'` +
      // `DSO missing from command line`（2026-11-09 CI 第二轮实测，
      // linux-backend-link 与 core 的 ubuntu 格都红在这条）。补在最后才在
      // adapter 之后，其它静态库（含 libbacktrace.a）也都在它前面。
      // mac 的 libSystem 自带 libm、win 的 CRT 自带，所以只有 Linux 这一支补。
      // `T233` 第三刀：编译期早就给 Linux adapter 加了 -ffunction-sections /
      // -fdata-sections（compileAdapter 的 Linux 分支，注释写的正是「对称
      // mac/win 的 dead-strip」），但链接侧一直没开段回收——GNU ld 默认不丢
      // 未引用段，分了也白分：产品 exe 照样把 234 个 moonui_native_* 里没人
      // 调用的测试入口 / 中性桩全链进来。--gc-sections 是全局开关、与库顺序
      // 无关，末尾追加即可。三平台现在成对：mac -Wl,-dead_strip、win
      // /Gy + /OPT:REF,NOICF、linux --gc-sections。ELF 真链接的符号差集由
      // CI 的 linux job 验，本机 ld64 只能证等价机制（见
      // scripts/linux-gc-sections-check.sh）。
      flags = [flags, "-lm", "-Wl,--gc-sections"].filter(Boolean).join(" ")
    }
    linkConfigs.push({
      package: "username/MoonUI/backends/native-common",
      // 顺序是**契约**，不是风格：adapter 静态库必须排在它依赖的系统库之前。
      // GNU ld 单遍扫描，`-lgtk-4` 若排在 adapter 前面，扫描到它时还没有任何
      // 未定义符号指向它，它的符号就不进解析表（Ubuntu 默认还带 --as-needed，
      // 干脆把整个库丢掉）；等 adapter 的成员被拉出来时，gtk_* / cairo_* 全部
      // undefined。CI 首跑实测：几十个 gtk/cairo/gobject 符号缺失，而 -lgtk-4
      // 明明就在同一条命令行上。ld64（mac）与 link.exe（win）不按这个方向解析，
      // 所以那两个平台一直绿着，这条顺序 bug 只在 Linux 上现形。
      link_flags: [nobj, flags].filter(Boolean).join(" "),
    })
  }
}

console.log(JSON.stringify({ link_configs: linkConfigs }))
