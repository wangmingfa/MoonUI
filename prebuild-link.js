// 模块级 prebuild 配置脚本（TODO `T59`，Windows 半 `T60`；`T67` 起还自编
// C adapter，`T69` 起还自动现编 libui.a）：把链接参数在构建前注入，让它顺
// import 传给下游的可执行包（六个 -native 示例壳，及两个后端包自己的测试
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
// 且全模块的链接配置只挂 backends/libui-common 一个包——平台链接参数加上
// 现编产物 `_build/prebuild/adapter.o`（Windows 是 .obj）一起从那里顺
// import 传给所有下游：六个 -native 示例壳、两个后端包的测试二进制，全走
// 这同一条（Qt 绑定 qt.mbt 的形状）。因此后端包的 moon.pkg 不再写
// native-stub，任何可执行包都只会链接到这一份 adapter，也就不再需要
// libui-native 那样的纯挂点包。
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
const macosLinkFlags =
  "-lobjc -framework Cocoa third-party/libui/lib/libui.a"
const windowsLinkFlags =
  '-link /LIBPATH:"third-party/libui/lib" libui.a user32.lib kernel32.lib gdi32.lib comctl32.lib uxtheme.lib msimg32.lib comdlg32.lib d2d1.lib dwrite.lib ole32.lib oleaut32.lib oleacc.lib uuid.lib windowscodecs.lib advapi32.lib'

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
    return out
  }
  return null
}

const linkConfigs = []
const osName = hostOS()
if (osName === "macos" || osName === "windows") {
  // libui.a 不在就现编（脚本自带 pin 缓存，在的时候是快速跳过）——
  // 用户从此不需要在 moon 命令之外手动跑任何构建脚本。
  ensureLibui(osName)
  // 全部链接配置只挂在 libui-common 一个包上（Qt 绑定 qt.mbt 的形状）：
  // 平台链接参数 + 本脚本现编的 adapter 一起顺 import 传给所有下游——
  // 六个 -native 示例、两个后端包的测试二进制，全走这同一条。因此
  // 任何可执行包**只**链接这一份 adapter：后端包从 moon.pkg 的
  // native-stub 改吃这里的产物，libui-native 挂点包已删（不再需要）。
  const obj = compileAdapter(osName)
  if (obj !== null) {
    linkConfigs.push({
      package: "username/MoonUI/backends/libui-common",
      link_flags:
        (osName === "macos" ? macosLinkFlags : windowsLinkFlags) +
        " " +
        obj,
    })
  }
}

console.log(JSON.stringify({ link_configs: linkConfigs }))
