# SatelliteSimJulia — 平台状态报告 / Platform Status Report

> **状态 / Status**: 框架已就位，能力矩阵与路线图待补全。
> This file was created to fix broken README links ([#3](https://github.com/zhuh2664-coder/SatelliteSimJulia/issues/3)). Detailed content TBD.

---

## 当前能力矩阵 / Current Capability Matrix

| 子系统 | 状态 | 说明 |
|--------|------|------|
| Walker 星座生成 | ✅ 可用 | 支持 Star/Delta 配置 |
| 二体传播 | ✅ 可用 | 纯 Julia 实现 |
| J2 摄动传播 | ✅ 可用 | 含可微版本（Enzyme/Zygote）|
| J4 传播 | ✅ 可用 | — |
| SGP4/TLE | ✅ 可用 | 依托 SatelliteToolbox |
| ISL 物理评估 | ✅ 可用 | 距离/LOS/仰角/方位/时延/容量 |
| GSL 可见性 | ✅ 可用 | — |
| 拓扑策略 | ✅ 可用 | Grid+/T/Honeycomb/Ring/… |
| 路由算法 | ✅ 可用 | Dijkstra/ECMP/MinLoad |
| 覆盖率指标 | ✅ 可用 | — |
| 图论分析 | ✅ 可用 | 介数/PageRank/Fiedler |
| AoN 流量分配 | ✅ 可用 | — |
| 可微覆盖优化 | ✅ 可用 | `optimize_coverage` + Adam |
| AI 仿真助手 | ✅ 可用 | 需 `DEEPSEEK_API_KEY` |
| GLMakie 可视化 (`viz`) | 🔧 辅助包 | 不参与核心计算链路 |
| GMAT 力模型适配 (`gmat`) | 🔧 辅助包 | — |
| 预编译镜像 (`sysimage`) | 🔧 辅助包 | 加速冷启动 |

---

## 已知限制 / Known Limitations

> TODO: 补充已知的精度边界、规模限制（最大卫星数、时间步数）、内存占用估算。

---

## 路线图 / Roadmap

| 优先级 | 功能 | 预计状态 |
|--------|------|----------|
| 高 | 补全四份文档 | 待完成 |
| 高 | 添加 LICENSE 文件 | 待完成 |
| 中 | GLMakie 可视化文档与示例 | 待规划 |
| 中 | 多线程/GPU 传播性能基准 | 待规划 |
| 低 | GMAT 力模型完整集成 | 待规划 |

---

## 依赖版本 / Dependency Versions

> TODO: 在此列出 `Project.toml` 中的关键依赖及最低 Julia 版本要求。

---

## 另见 / See Also

- [用户手册](USER_GUIDE.md)
- [API 参考](API_REFERENCE.md)
- [开发者指南](DEVELOPER_GUIDE.md)
