# SatelliteSimJulia 可缩放地图骨架

第一版目标不是美术完成，而是把大地图系统的结构先站起来。

## 文件

- `satsim-scalable-map-skeleton.svg`：可编辑 SVG 骨架。
- `satsim-scalable-map-viewer.html`：可拖拽、滚轮缩放的查看器。

## 边界原则

- 主橙色路径必须跨 tile 连续。
- 红色锚点是边界契约，分区生成时必须对齐。
- AI 小黑图只放在 asset slot，不承担结构文字。
- 缩小时看模块，放大时看 asset slot、反馈路径和模块内部说明。
