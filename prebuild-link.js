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
// 是 darwin/win32 时吐空列表（Linux 后端落地时在此补一分）。
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
const windowsNativeLinkFlags =
  "user32.lib kernel32.lib gdi32.lib comctl32.lib uxtheme.lib comdlg32.lib ole32.lib oleaut32.lib oleacc.lib uuid.lib advapi32.lib shell32.lib gdiplus.lib msimg32.lib windowscodecs.lib imm32.lib"

/// 原生 Cocoa 后端的 macOS 链接参数：平台事实（ObjC runtime + Cocoa），本
/// 目录的 ABI 头 adapter.h 在 `T82` 起也住在这里。共享半从 packages/moonui
/// 并回本份的理由见文件头注释（T80 回避随 T82 失去前提）。`T86⑥` 起加
/// UserNotifications：系统通知走现代的 UNUserNotificationCenter（NSUserNotification
/// 已废弃），框架头由 SDK 自动搜到，链接时那半在这串里。2026-10-18 再加
/// Accelerate：音频频谱的 vDSP（fftsetup/ctoz/fft_zrip）在那半里。
// `-Wl,-no_warn_duplicate_libraries`：`T104` 之后 adapter 以静态库挂链接，
// 配置所属包自己的测试可执行会把同一份 .a 出现两次——ld 本就只拉一次成员，
// 这里只是把那条 "ignoring duplicate libraries" 的提示静音（本机 ld 实测支持）。
const macosNativeLinkFlags = "-lobjc -framework Cocoa -framework UserNotifications -framework AVFoundation -framework CoreMedia -framework Accelerate -Wl,-no_warn_duplicate_libraries"

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

/// 按宿主编译平台 C adapter，返回产物路径。成功返回路径；失败返回 null（构建
/// 会以"链接时找不到符号"的方式红掉，比在这里静默退出更可诊断）。
///
/// 参数对齐 moon 自己编 native-stub 的那一路：include 路径给包目录（adapter.h
/// 的相对引用在 ../native-common）和 ~/.moon/include（moonbit.h）。macOS 用
/// cc（.m 文件 clang 自动按 ObjC 处理，-Wall -Wextra——构建期就要看见告警）；
/// Windows 用 cl（PATH 里得有 MSVC
/// 环境，CI 的 windows job 天然满足，本地开过 vcvars 也一样）。
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
    const out = path.join(outDir, "adapter_native.o")
    // 缓存比对：源文件与 adapter.h 两者取较新（T71 的坑——头改了 ABI 不重编）
    if (
      !fs.existsSync(out) ||
      fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs ||
      fs.statSync(out).mtimeMs < fs.statSync(hdr).mtimeMs
    ) {
      const args = [
        "-c",
        "-Wall",
        "-Wextra",
        "-x",
        "objective-c",
        "-Ibackends/native-macos",
        "-Ibackends/native-common",
        "-I" + moonInclude,
      ]
      // 排查"死在哪一次 FFI 调用"：MOONUI_NATIVE_TRACE=1 moon build ...
      // 给 C 里即时 fflush 的 TRACE 打开（见两份 adapter 的头注）。
      if (process.env.MOONUI_NATIVE_TRACE) {
        args.push("-DMOONUI_TRACE")
      }
      args.push(src, "-o", out)
      const r = spawnSync("cc", args, { stdio: ["ignore", "pipe", "pipe"] })
      if (r.stdout) {
        process.stderr.write(r.stdout)
      }
      if (r.stderr) {
        process.stderr.write(r.stderr)
      }
      if (r.status !== 0) {
        return null
      }
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
  const src = path.join("backends", "native-windows", "adapter_native.c")
  const hdr = path.join("backends", "native-common", "adapter.h")
  const out = path.join(outDir, "adapter_native.obj")
  // 缓存比对：同 mac 半——源文件与 adapter.h 两者取较新（T71 的坑）
  if (
    !fs.existsSync(out) ||
    fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs ||
    fs.statSync(out).mtimeMs < fs.statSync(hdr).mtimeMs
  ) {
    const args = [
      "/utf-8",
      "/c",
      "/Ibackends/native-windows",
      "/Ibackends/native-common",
      "/I" + moonInclude,
    ]
    // 排查"死在哪一次 FFI 调用"：MOONUI_NATIVE_TRACE=1 moon build ...
    // 给 C 里即时 fflush 的 TRACE 打开（见两份 adapter 的头注）。
    if (process.env.MOONUI_NATIVE_TRACE) {
      args.push("/DMOONUI_TRACE")
    }
    args.push(src, "/Fo:" + out.replaceAll("/", "\\"))
    const r = spawnSync(
      "cl",
      args,
      { stdio: ["ignore", "pipe", "pipe"] },
    )
    if (r.stdout) {
      process.stderr.write(r.stdout)
    }
    if (r.stderr) {
      process.stderr.write(r.stderr)
    }
    if (r.status !== 0) {
      return null
    }
  }
  // 返回值要进 link_flags：那里 moon 会按转义解析字符串，Windows 的反斜杠
  // （\p、\a 这类）被当转义符剥掉——实测（2026-10-13，T68）链接器收到的是
  // "_buildprebuildadapter.obj" 而 LNK1181。link.exe 认正斜杠，cl 的 /Fo:
  // 仍用上面的反斜杠原样（那条不经 moon）。
  return out.replaceAll("\\", "/")
}

const linkConfigs = []
const osName = hostOS()
if (osName === "macos" || osName === "windows") {
  // 唯一的一份配置挂 backends/native-common（理由见文件头注释）：本脚本现编的
  // adapter 顺 import 传给所有下游——示例壳、后端包自己的测试二进制。任何
  // 可执行包**只**链接这一份 adapter 对象：后端包从 moon.pkg 的 native-stub
  // 改吃这里的产物（T67 起）。
  const nobj = compileAdapter(osName)
  if (nobj !== null) {
    linkConfigs.push({
      package: "username/MoonUI/backends/native-common",
      link_flags: [osName === "macos" ? macosNativeLinkFlags : windowsNativeLinkFlags, nobj]
        .filter(Boolean)
        .join(" "),
    })
  }
}

console.log(JSON.stringify({ link_configs: linkConfigs }))
