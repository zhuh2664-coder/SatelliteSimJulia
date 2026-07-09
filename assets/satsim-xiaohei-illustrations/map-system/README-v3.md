# SatelliteSimJulia 可缩放插图地图 v3

v3 修正 v2 的占位问题：每个模块内部不再显示文件名文字框，而是嵌入真实 Ian 小黑风格插图缩略图。

## 文件

- `satsim-scalable-map-v3-illustrated.svg`：带真实插图缩略图的 SVG。
- `satsim-scalable-map-v3-illustrated-viewer.html`：可拖拽/缩放查看器，带正文层、边界锚点、小黑插图开关。
- `assets/`：地图引用的局部小黑插图素材副本。

## 原则

- SVG 负责大地图结构、文字、路径和边界。
- 小黑 PNG 只作为模块内部视觉素材。
- 后续扩展时，每个模块可以替换/增加局部素材，但不要把结构文字烘焙进 PNG。
