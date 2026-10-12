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
