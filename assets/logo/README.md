# MoonUI logo

`moonui-logo.svg` 是设计源文件；`moonui.png`（mac 的 `NSImage` 吃）与
`moonui.ico`（Windows 的 `LoadImageW` 吃）是渲染产物，改了 SVG 要重渲。
示例里的 `App::set_icon("assets/logo/moonui")` 传的是这份无扩展名的名——
mac 侧补 `.png`、Windows 侧补 `.ico`，所以两个平台共用同一行代码。

重渲（macOS）：

```sh
qlmanage -t -s 1024 -o . moonui-logo.svg   # 产出白底的 moonui-logo.svg.png
python3 render.py                          # 修 alpha、去白边、出 PNG 与多尺寸 ICO
rm moonui-logo.svg.png                     # 中间产物不入库
```

## 留白不用自己留

macOS 的图标网格（Big Sur 起）是 1024 画布 + 824 主体、四周各 100 的留白，
而 `cloudmusic.png` 这类从别处拆出来的原版图是**满幅**的（alpha 包围盒贴到四边）。
两份都不用在这里补边：原生后端的 `set_app_icon` 会量 alpha 包围盒、按 824/1024
重排到透明画布（内容不重采样，只加透明边；主体已经 ≤86% 的图保持原样）。
所以资产保持原样——补白是平台口径，不是美术决定。
