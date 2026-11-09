# 应用图标

两份都是**第一方原创**资产，无任何第三方品牌/产品外观：

- **MoonUI 框架图标** —— `moonui-logo.svg` 是设计源文件；`moonui.png`（mac 的
  `NSImage` 吃）与 `moonui.ico`（Windows 的 `LoadImageW` 吃）是渲染产物，改了 SVG 要重渲。
  由 `examples/common`、gallery 等框架示例共用：`App::set_icon("assets/logo/moonui")`。

- **Luna 音乐播放器图标** —— `luna.png` / `luna.ico` 由 `luna_draw.js` 算法自绘
  （圆角方形深蓝渐变 + 月牙 + 均衡器柱条），不是从别处拆来的图。要改形状/配色就改
  `luna_draw.js` 再跑一遍重出 PNG 与多尺寸 ICO。音乐播放器示例（`examples/lunamusic`）
  用它：`App::set_icon("assets/logo/luna")`。

**2026-11-09 迁移说明**：两个重渲脚本已从 Python/Pillow 换成**零 npm 依赖**的
Node（`scripts/png-image.js` 复刻 Pillow 的整数椭圆栅格化、定点 LANCZOS 与 RGBA
预乘）。重渲出的 PNG/ICO **像素**与现存产物一致，但**字节**会变（Pillow 用自适应
PNG filter，这里统一 filter 0）；`render.js` 的端到端重渲需要 `qlmanage` 白底中间
图，本机受限沙箱里跑不了，判据 `node scripts/logo-check.js` 用现存 `moonui.png`
独立验掩码与 ICO、用合成白底图验反解公式。判据已接进 `scripts/test-local.sh`。

两个 stem 都是**无扩展名**的名：mac 侧补 `.png`、Windows 侧补 `.ico`，所以两平台共用同一行代码。

重渲 MoonUI 图标（macOS）：

```sh
qlmanage -t -s 1024 -o . moonui-logo.svg   # 产出白底的 moonui-logo.svg.png
node render.js                            # 修 alpha、去白边、出 PNG 与多尺寸 ICO
rm moonui-logo.svg.png                     # 中间产物不入库
```

重渲 Luna 图标：

```sh
node luna_draw.js                         # 纯 Node（零依赖），无中间产物
```

## 留白不用自己留

macOS 的图标网格（Big Sur 起）是 1024 画布 + 824 主体、四周各 100 的留白，而
`luna.png` 这类自绘图标是**满幅**的（alpha 包围盒贴到四边）。两份都不用在这里补边：
原生后端的 `set_app_icon` 会量 alpha 包围盒、按 824/1024 重排到透明画布（内容不重采样，
只加透明边；主体已经 ≤86% 的图保持原样）。所以资产保持原样——补白是平台口径，不是美术决定。
