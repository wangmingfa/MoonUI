// 模块级 prebuild 配置脚本（TODO `T59`，Windows 半 `T60`；`T67` 起还自编
// C adapter，`T69` 起还自动现编 libui.a）：把链接参数在构建前注入，让它顺
// import 传给下游的可执行包（六个 -libui 示例壳，及两个后端包自己的测试
// 二进制）。
//
// 为什么存在：`moon.pkg` 的 `link` 只在被链接的可执行包里生效，库包声明的
// 不顺 import 传下来，于是每个壳都得抄一份 `cc-link-flags`。moon 的
// `--moonbit-unstable-prebuild` 机制（moon.mod 的 options 里指到本文件）让
// 脚本在构建前跑一次、往 stdout 吐一份 JSON，其中的 `link_configs` 会挂到
// 指定包上并传播给依赖它的可执行包。机制只在 native/LLVM 后端跑（wasm 与
// `moon check` 都跳过），需要 PATH 里有 node。
//
// 2026-10-13 起（示例不按平台分家）：本脚本还负责**按宿主编译 C adapter**，
// 且链接配置集中在 libui-common 一个包——平台链接参数加上
// 现编产物 `_build/prebuild/adapter.o`（Windows 是 .obj）一起从那里顺
// import 传给所有下游：六个 -libui 示例壳、两个后端包的测试二进制，全走
// 这同一条（Qt 绑定 qt.mbt 的形状）。因此后端包的 moon.pkg 不再写
// native-stub，任何可执行包都只会链接到这一份 adapter，也就不再需要
// libui-native 那样的纯挂点包。
//
// 2026-10-15 起（T80，前台门 T79 的连带账）：mac 那半的链接参数劈成共享半
// 与 exclusive 半——`packages/moonui-app` import 两份后端，链 libui 的可执行
// 同时吃到两份 common 的配置，平台共享半（-lobjc/-framework Cocoa）挂 common
// 就重复，ld 报 duplicate-library 警告。共享半改挂 packages/moonui（每个
// native 可执行的必经点），两份 common 只带 exclusive 半；Windows 半两份配置
// 原样（本机无量过 cl，T50 先保形状的先例）。
//
// 按宿主分支（借 justjavac/moonbit-dialog 的写法）：只吐当前平台那一份。
// moon 跑本脚本时环境里带 MOON_HOST_OS，兜底再认 process.platform；
// 两边都不是 darwin/win32 时吐空列表（Linux GTK3 后端 `T2` 落地时在此
// 补一分）。
//
// Windows 那份的 link_flags 逐字抄自原先 backends/libui-windows/moon.pkg
// 里的 cc-link-flags——开头那个 `-link` 是 cl→link.exe 的分隔符，不能少
// （T14 量过：删掉它 /LIBPATH 就落到 cl 头上，LNK1104 打不开 libui.a）。
// 这里**不**借 moon 的 MSVC 自动翻译（`-lfoo`→`foo.lib`）改成通用写法：
// 那套翻译在这台机器上没量过，而这串 MSVC 原样是 T7/T50 真跑验证过的
// 形状，先保形状。
//
// 注意相对路径按当前工作目录（仓库根）展开，与原先 moon.pkg 里的行为一致，
// 所以 moon 命令仍必须在仓库根跑。`libui.a` 是静态归档文件而不是 -l 库名，
// 保持整串写在 link_flags 里。

const { spawnSync } = require("child_process")

/// 保证 libui-ng 静态库在场（scripts/build-libui.sh / .ps1 本身就是幂等 +
/// pin 缓存的：产物在、pinned-commit.txt 匹配就直接跳过，所以热路径只是一次
/// 几十毫秒的 bash spawn）。第一跑会从 GitHub 浅 fetch 并全量编译（一两分钟）。
///
/// 关键的一条：**子进程的 stdout 必须整个改道到 stderr**。本脚本的 stdout 是
/// 给 moon 解析的纯 JSON（link_configs），构建脚本里那些 "==>" 进度行如果漏进
/// stdout，moon 的 JSON 解析当场红。所以这里用 pipe 收下、往 process.stderr 写。
/// 失败不抛：照常（不挂那份配置地）往下走，链接器随后报"找不到 libui.a"，
/// 加上 stderr 上的构建日志，比在这里静默退出更好诊断。
const fs = require("fs")
const os = require("os")
const path = require("path")

/// 两个后端的链接参数各一份。macOS 是 clang 写法；Windows 是 MSVC 原样
/// （含 `-link` 分隔符，见上）。宿主不是 darwin/win32 时一份都不挂。
const windowsLinkFlags =
  '-link /LIBPATH:"third-party/libui/lib" libui.a user32.lib kernel32.lib gdi32.lib comctl32.lib uxtheme.lib msimg32.lib comdlg32.lib d2d1.lib dwrite.lib ole32.lib oleaut32.lib oleacc.lib uuid.lib windowscodecs.lib advapi32.lib'

/// macOS 的链接参数劈成两半（2026-10-15，T80；起因是 `T79` 的前台门）：
/// `packages/moonui-app` import 两份后端包，链 libui 的可执行从此**同时**吃到
/// libui-common 与 native-common 两份配置——两份若各带一遍平台共享半，链接线
/// 就重复 `-lobjc`/`-framework Cocoa`，ld 报 "ignoring duplicate libraries"
/// 警告（先前"一个可执行包只 import 其中一个后端、两份配置互不串味"的前提
/// 被前台门劈掉了）。按构造去重：共享半只挂 packages/moonui 一处——它是每个
/// native 可执行 import 闭包里的必经点且只出现一次；两份 common 的配置只留
/// 各自 exclusive 半。挂 moonui 不破 §47：那条红线是"Core 不 import 后端包"
/// （import 层），链接配置由本脚本在构建期注入、`moon check` 与 wasm 路径根本
/// 看不见，Core 目录一个字不动；-lobjc/-framework Cocoa 是**平台**事实（mac 上
/// 的 UI 可执行无论选哪个后端都要 ObjC runtime + Cocoa——libui.a 经 meson 要
/// -lobjc 与 Foundation/AppKit，两份 ObjC adapter 直写 AppKit 同样要），不是
/// 后端选择。
const macosSharedLinkFlags = "-lobjc -framework Cocoa"

/// libui 那份的 exclusive 半：libui.a（共享半见上，由 moonui 那份配置带）。
const macosLibuiLinkFlags = "third-party/libui/lib/libui.a"

/// 原生 Cocoa 后端（§51 的 Backend #2）的 macOS exclusive 半：**空**——它不
/// 链任何库，只吃本脚本现编的 adapter_native.o（见下方 link_flags 拼装处的
/// filter 处理）。
const macosNativeLinkFlags = ""

/// 原生 Win32 后端（§51 的 Backend #2，Windows 半，T75）的链接参数：同一批
/// 系统库（user32 之外的 comctl32/uxtheme/ole32 是 trackbar/DPI 主题/文件面板
/// 那批要的），但**不带** libui.a 也不带 d2d1/dwrite/msimg32（那些是 libui 自己
/// 画图要的）——直写 Win32 的 adapter 只用控件和 GDI 那档。开头 `-link` 是
/// cl→link.exe 的分隔符，和上面 windowsLinkFlags 同一条理由。
const windowsNativeLinkFlags =
  "-link user32.lib kernel32.lib gdi32.lib comctl32.lib uxtheme.lib comdlg32.lib ole32.lib oleaut32.lib oleacc.lib uuid.lib advapi32.lib"

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

/// 先决条件：third-party/libui/lib/libui.a。没有就按宿主现编（脚本自己有
/// pin 缓存，已有产物时这里只是一次快速跳过）。返回 true/false。
function ensureLibui(osName) {
  const script =
    osName === "macos"
      ? ["bash", [path.join("scripts", "build-libui.sh")]]
      : [
          "powershell",
          [
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "scripts/build-libui.ps1",
          ],
        ]
  const r = spawnSync(script[0], script[1], {
    stdio: ["ignore", "pipe", "pipe"],
  })
  if (r.stdout) {
    process.stderr.write(r.stdout)
  }
  if (r.stderr) {
    process.stderr.write(r.stderr)
  }
  return r.status === 0
}

/// 按宿主编译 C adapter，返回产物路径。成功返回路径；失败返回 null（构建
/// 会以"链接时找不到符号"的方式红掉，比在这里静默退出更可诊断）。
///
/// 参数对齐 moon 自己编 native-stub 的那一路：include 路径给包目录（ui.h /
/// adapter.h 的相对引用都在那里）和 ~/.moon/include（moonbit.h）。macOS 用
/// cc（.m 文件 clang 自动按 ObjC 处理）；Windows 用 cl（PATH 里得有 MSVC
/// 环境，CI 的 windows job 天然满足，本地开过 vcvars 也一样）。
/// 源文件没动过就不重编（mtime 比对）；`moon clean` 清掉 _build 也无妨，
/// 下一次构建自动补。
function compileAdapter(osName) {
  const outDir = path.join("_build", "prebuild")
  fs.mkdirSync(outDir, { recursive: true })
  const moonInclude = path.join(os.homedir(), ".moon", "include")
  if (osName === "macos") {
    const src = path.join("backends", "libui-macos", "adapter_macos.m")
    const out = path.join(outDir, "adapter_macos.o")
    if (
      !fs.existsSync(out) ||
      fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs
    ) {
      const r = spawnSync(
        "cc",
        [
          "-c",
          "-x",
          "objective-c",
          "-Ibackends/libui-macos",
          "-I" + moonInclude,
          src,
          "-o",
          out,
        ],
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
    return out
  }
  if (osName === "windows") {
    const src = path.join("backends", "libui-windows", "adapter.c")
    const out = path.join(outDir, "adapter.obj")
    if (
      !fs.existsSync(out) ||
      fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs
    ) {
      const r = spawnSync(
        "cl",
        [
          "/utf-8",
          "/c",
          "/Ibackends/libui-windows",
          "/Ibackends/libui-common",
          "/I" + moonInclude,
          src,
          "/Fo:" + out.replaceAll("/", "\\"),
        ],
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
  return null
}

/// 编译原生后端的 C adapter（§51 的 Backend #2）：macOS 半是 backends/
/// native-macos/adapter_native.m（cc，ObjC），Windows 半是 backends/
/// native-windows/adapter_native.c（cl，和 compileAdapter 的 Windows 支
/// 同一套 /Fo: 反斜杠、返回正斜杠的形状——理由在那里）。两份产物都**不**
/// 依赖 libui.a（直写 AppKit / Win32）。和 compileAdapter 同一套 mtime 缓存；
/// 宿主不是 macos/windows 时返回 null。
function compileNativeAdapter(osName) {
  if (osName !== "macos" && osName !== "windows") {
    return null
  }
  const outDir = path.join("_build", "prebuild")
  fs.mkdirSync(outDir, { recursive: true })
  const moonInclude = path.join(os.homedir(), ".moon", "include")
  if (osName === "macos") {
    const src = path.join("backends", "native-macos", "adapter_native.m")
    const out = path.join(outDir, "adapter_native.o")
    if (
      !fs.existsSync(out) ||
      fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs
    ) {
      const r = spawnSync(
        "cc",
        [
          "-c",
          "-x",
          "objective-c",
          "-Ibackends/native-macos",
          "-Ibackends/libui-common",
          "-I" + moonInclude,
          src,
          "-o",
          out,
        ],
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
    return out
  }
  const src = path.join("backends", "native-windows", "adapter_native.c")
  const out = path.join(outDir, "adapter_native.obj")
  if (
    !fs.existsSync(out) ||
    fs.statSync(out).mtimeMs < fs.statSync(src).mtimeMs
  ) {
    const r = spawnSync(
      "cl",
      [
        "/utf-8",
        "/c",
        "/Ibackends/native-windows",
        "/Ibackends/libui-common",
        "/I" + moonInclude,
        src,
        "/Fo:" + out.replaceAll("/", "\\"),
      ],
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
  // 返回值进 link_flags 时要用正斜杠，理由同 compileAdapter 的 Windows 支。
  return out.replaceAll("\\", "/")
}

const linkConfigs = []
const osName = hostOS()
if (osName === "macos" || osName === "windows") {
  // libui.a 不在就现编（脚本自带 pin 缓存，在的时候是快速跳过）——
  // 用户从此不需要在 moon 命令之外手动跑任何构建脚本。
  ensureLibui(osName)
  if (osName === "macos") {
    // macOS 平台共享半只挂 packages/moonui 一处（T80，理由见上方常量注释）：
    // 它是每个 native 可执行 import 闭包里的必经点且只出现一次——前台门落地
    // 后链 libui 的可执行同时吃到两份 common 的配置，共享半挂 common 就必然
    // 重复。这份配置里**没有对象文件**，所以"配置会被 moon 对包库 + 测试可执行
    // 各应用一次"的 hazard 在这里无害（那份 hazard 只对对象文件成立，见下方
    // native-common 那条注释；-l/-framework 的重复应用 moon 对每个可执行也只
    // 带一次）。
    linkConfigs.push({
      package: "username/MoonUI/packages/moonui",
      link_flags: macosSharedLinkFlags,
    })
  }
  // exclusive 半挂在两份 common 上（Qt 绑定 qt.mbt 的形状）：本脚本现编的
  // adapter 顺 import 传给所有下游——六个 -libui 示例、原生那批示例、两个后端
  // 包自己的测试二进制。任何可执行包**只**链接这一份 adapter 对象：后端包从
  // moon.pkg 的 native-stub 改吃这里的产物，libui-native 挂点包已删（不再需
  // 要）。Windows 两份配置原样没劈共享半：本机没有 MSVC 环境、那半链接从来
  // 只在 CI 闸门量（T50 先保形状的先例），且 link.exe 那边没有观测到 mac ld
  // 这条 duplicate-library 警告的对应物。
  const obj = compileAdapter(osName)
  if (obj !== null) {
    linkConfigs.push({
      package: "username/MoonUI/backends/libui-common",
      link_flags: [osName === "macos" ? macosLibuiLinkFlags : windowsLinkFlags, obj]
        .filter(Boolean)
        .join(" "),
    })
  }
  // 原生后端（§51 的 Backend #2，macOS 半 + T75 的 Windows 半）：单独一份配置
  // 挂在 backends/native-common 上——macOS 只吃 adapter_native.o（libui.a 与
  // 平台共享半都不在本份，见 T80 注），Windows 原样带那批系统库、不带 libui.a
  // 也不带 d2d1/dwrite/msimg32（那些是 libui 自己画图要的）。
  if (osName === "macos" || osName === "windows") {
    const nobj = compileNativeAdapter(osName)
    if (nobj !== null) {
      // 挂 backends/native-common（共享 MoonBit 层那侧），**不**挂
      // backends/native-macos / native-windows：测试二进制住在后端包里，配置若
      // 挂在那一侧会被 moon 对"包库 + 测试可执行"各应用一次、把 adapter 对象
      // 链两遍撞重复符号。libui 那侧正是靠"配置挂 libui-common、C 与测试住后
      // 端包"避开的那同一套 hazard 形状，本侧照抄。
      linkConfigs.push({
        package: "username/MoonUI/backends/native-common",
        link_flags: [osName === "macos" ? macosNativeLinkFlags : windowsNativeLinkFlags, nobj]
          .filter(Boolean)
          .join(" "),
      })
    }
  }
}

console.log(JSON.stringify({ link_configs: linkConfigs }))
