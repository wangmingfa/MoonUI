// Linux 宿主缺依赖时**该装什么**的唯一来源（`T396`）。
//
// 为什么单独一份：报错里写死 Ubuntu 的包名会在别的发行版上误导人——Fedora 上
// `sudo apt install libgtk-4-dev` 直接是 "No match for argument"，照着抄一遍
// 还是装不上，真正该跑的是 `sudo dnf install gtk4-devel`（`T396` 就是这么撞出来
// 的：Fedora 45 上连 `cc` 都没有，而 prebuild 只提示 Debian 包名）。包名随发行版
// 变，宿主是哪一族由 `/etc/os-release` 现读，不在代码里猜。
//
// 单一来源的接法：仓库根的 `prebuild-link.js` 直接 `require` 本文件；bash 闸脚本
// 用 `node scripts/linux-deps.js <逻辑名...>` 取同一份提示（它们本来只在 Linux 上
// 走这条分支，而 Linux 的 native 构建硬依赖 node，见 docs/build-and-environment.md
// §1）。所以改包名只改这一张表。
//
// 逻辑名与各发行版的包名对照（只列本项目用得到的）：
//   cc                 C 编译器（moon 编 runtime、prebuild 编 adapter 都要）
//   pkg-config         读 gtk4 / cairo 的 .pc
//   gtk4               GTK4 **开发包**（运行库装了不算，头与 .pc 在 -devel 里）
//   cairo              Cairo 开发包（同上）
//   gtk4-layer-shell   HUD 置顶窗（`T343`）的可选包
//   xvfb / xauth       无头跑真窗（CI 与本地闸）
//   xdotool            外部真实输入闸（`T235` P9）
//
// 用法：
//   node scripts/linux-deps.js gtk4 cairo
//   node scripts/linux-deps.js cc pkg-config gtk4 cairo
//
// 认不出发行版（没有 /etc/os-release、或是没列进来的发行版）时不猜：把
// Debian / Fedora / Arch / openSUSE 四套命令都打出来，让人按包管理器挑一条。

const fs = require("fs")

/// 逻辑名 → 各发行版族的实际包名。族名：debian / fedora / arch / suse。
/// 只放本项目真正会提示的包；新增逻辑名时四处都要填，缺一项就跳过该族。
const PACKAGES = {
  cc: { debian: "gcc", fedora: "gcc", arch: "gcc", suse: "gcc" },
  "pkg-config": {
    debian: "pkg-config",
    fedora: "pkg-config",
    arch: "pkgconf",
    suse: "pkg-config",
  },
  gtk4: {
    debian: "libgtk-4-dev",
    fedora: "gtk4-devel",
    arch: "gtk4",
    suse: "gtk4-devel",
  },
  cairo: {
    debian: "libcairo2-dev",
    fedora: "cairo-devel",
    arch: "cairo",
    suse: "cairo-devel",
  },
  "gtk4-layer-shell": {
    debian: "libgtk4-layer-shell-dev",
    fedora: "gtk4-layer-shell-devel",
    arch: "gtk4-layer-shell",
    suse: "gtk4-layer-shell-devel",
  },
  xvfb: {
    debian: "xvfb",
    fedora: "xorg-x11-server-Xvfb",
    arch: "xorg-server-xvfb",
    suse: "xvfb",
  },
  xauth: {
    debian: "xauth",
    fedora: "xorg-x11-xauth",
    arch: "xorg-xauth",
    suse: "xauth",
  },
  xdotool: {
    debian: "xdotool",
    fedora: "xdotool",
    arch: "xdotool",
    suse: "xdotool",
  },
}

/// 逻辑名 → 给人看的说明（打印「需要：…」那一行用）。
const DESCRIPTIONS = {
  cc: "C 编译器（cc/gcc）",
  "pkg-config": "pkg-config",
  gtk4: "GTK4 开发包（头文件 + gtk4.pc）",
  cairo: "Cairo 开发包（头文件 + cairo.pc）",
  "gtk4-layer-shell": "gtk4-layer-shell 开发包（HUD 置顶窗）",
  xvfb: "Xvfb（无头跑真窗）",
  xauth: "xauth（xvfb 认证）",
  xdotool: "xdotool（外部真实输入闸）",
}

const LABELS = {
  debian: "Debian / Ubuntu",
  fedora: "Fedora / RHEL",
  arch: "Arch",
  suse: "openSUSE",
}

const INSTALLERS = {
  debian: "sudo apt install -y ",
  fedora: "sudo dnf install -y ",
  arch: "sudo pacman -S --needed ",
  suse: "sudo zypper install -y ",
}

/// `/etc/os-release` 的 ID / ID_LIKE → 包管理器族。读不到文件或认不出来返回
/// "unknown"（调用方据此把四套命令都打出来，而不是押一个）。
function distroFamily() {
  let id = ""
  let like = ""
  try {
    const rel = fs.readFileSync("/etc/os-release", "utf8")
    const field = (key) => {
      const m = rel.match(new RegExp("^" + key + "=(.*)$", "m"))
      return m ? m[1].trim().replace(/^["']|["']$/g, "").toLowerCase() : ""
    }
    id = field("ID")
    like = field("ID_LIKE")
  } catch {
    // 没有 os-release（精简容器 / 非 systemd 镜像）：走 unknown，不猜。
  }
  const ids = (id + " " + like).split(/\s+/).filter((s) => s.length > 0)
  const has = (list) => ids.some((x) => list.includes(x))
  if (
    has([
      "debian",
      "ubuntu",
      "linuxmint",
      "pop",
      "elementary",
      "raspbian",
      "kali",
      "zorin",
    ])
  ) {
    return "debian"
  }
  if (
    has(["fedora", "rhel", "centos", "rocky", "almalinux", "ol", "nobara", "amzn"])
  ) {
    return "fedora"
  }
  if (has(["arch", "manjaro", "endeavouros", "cachyos", "garuda"])) {
    return "arch"
  }
  if (ids.some((x) => x.startsWith("opensuse") || x === "suse" || x === "sles" || x === "sled")) {
    return "suse"
  }
  return "unknown"
}

/// 某族下这些逻辑名对应的包名（保持传入顺序，去重，认不出的逻辑名跳过）。
function packageNames(deps, family) {
  const out = []
  for (const dep of deps) {
    const names = PACKAGES[dep]
    if (!names) continue
    const pkg = names[family]
    if (pkg && !out.includes(pkg)) out.push(pkg)
  }
  return out
}

/// 生成一段可直接贴进报错的中文提示（含缩进、以换行结尾）。
/// opts.optional：可选逻辑名，单独给一行「可选：…」，不进必需安装命令。
function hint(deps, opts) {
  const optional = (opts && opts.optional) || []
  const family = distroFamily()
  const lines = []
  const known = deps.filter((d) => DESCRIPTIONS[d])
  if (known.length > 0) {
    lines.push(
      "  需要" +
        (known.length > 1 ? "（已装的可跳过）" : "") +
        "：" +
        known.map((d) => DESCRIPTIONS[d]).join("、") +
        "。",
    )
  }
  const families =
    family === "unknown" ? ["debian", "fedora", "arch", "suse"] : [family]
  if (family === "unknown") {
    lines.push("  认不出发行版（没有 /etc/os-release 或未列入），按包管理器挑一条：")
  } else {
    lines.push("  装法（/etc/os-release → " + LABELS[family] + "）：")
  }
  for (const f of families) {
    const pkgs = packageNames(deps, f)
    if (pkgs.length === 0) continue
    const prefix = family === "unknown" ? "    " + LABELS[f] + "：" : "    "
    lines.push(prefix + INSTALLERS[f] + pkgs.join(" "))
  }
  if (optional.length > 0) {
    const fam = family === "unknown" ? "debian" : family
    const optPkgs = packageNames(optional, fam)
    if (optPkgs.length > 0) {
      const who = family === "unknown" ? "可选（以 Debian / Ubuntu 为例）" : "可选"
      lines.push(
        "  " +
          who +
          "：" +
          optional.map((d) => DESCRIPTIONS[d] || d).join("、") +
          "：" +
          INSTALLERS[fam] +
          optPkgs.join(" "),
      )
    }
  }
  return lines.join("\n") + "\n"
}

/// 安装完成后最常见的一步：moon 不把 adapter 当 native 目标的输入（`T157`），
/// 装完包不 clean 会继续用旧产物。这行提示与 AGENTS.md 的纪律一致。
function cleanHint() {
  return "  装完先 `moon clean` 再跑 moon 命令（T157：不 clean 会复用旧产物）。\n"
}

module.exports = { distroFamily, packageNames, hint, cleanHint }

if (require.main === module) {
  const deps = process.argv.slice(2)
  if (deps.length === 0) {
    process.stderr.write("用法：node scripts/linux-deps.js <逻辑名...>（如 gtk4 cairo）\n")
    process.exit(2)
  }
  process.stdout.write(hint(deps) + cleanHint())
}
