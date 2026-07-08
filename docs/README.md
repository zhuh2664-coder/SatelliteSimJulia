# docs/ 索引

> 本索引按「文档类型 + 时效性」组织当前分支下的所有文档。
> 阅读任何**状态快照**类文档前，先看它的日期——过时快照只作历史参考，不作当前事实。
>
> 整理日期：2026-07-08（本轮已删除历史推进报告、过期作战总纲、已完工的 milestones 明细，见文末）

---

## 一、长期参考（协议 / 契约，随代码演进维护）

| 文档 | 内容 | 说明 |
|---|---|---|
| [`AI_COLLABORATION_PROTOCOL.md`](AI_COLLABORATION_PROTOCOL.md) | 与 AI 协作的输入/输出协议：五层信息分类、任务模板、最小验证原则 | 2026-07-08 创建，日常协作首选入口 |
| [`VALIDATION_LADDER.md`](VALIDATION_LADDER.md) | L0–L6 分层验证阶梯：从 syntax/load 到 stress/nightly，含提交前推荐组合 | 验证命令的权威参考 |
| [`SatelliteSimJulia_MCP_TOOLS.md`](SatelliteSimJulia_MCP_TOOLS.md) | MCP 安全工具面契约：默认只读两个 safe tools，硬边界清单 | 改 MCP/AgentOS 面前必读 |
| [`AI_ORCHESTRATION.md`](AI_ORCHESTRATION.md) | AI 编排层产品级架构验收参考：能力矩阵、artifact 契约、CLI/API 示例、遗留 gap | 英文；描述的是设计目标与验收门 |

## 二、状态快照（带日期，时效有限）

| 文档 | 快照日期 | 时效判断 |
|---|---|---|
| [`LAB12_INTERACTION_MATURITY.md`](LAB12_INTERACTION_MATURITY.md) | 2026-07-09 | **最新**。AI 交互层成熟度分层（已稳定/半成品/原型），判断 lab 12 层可用性以此为准 |
| [`PLATFORM_STATUS_REPORT.md`](PLATFORM_STATUS_REPORT.md) | 2026-07-03 | ⚠️ **部分过时**：AI 适配层章节已被后续实现推翻（文首自带时效声明）；其余章节为 07-03 快照。因根 `README.md` 与 `demo.jl` 引用而保留 |
| [`STATUS.md`](STATUS.md) | 持续更新 | 只跟踪 **Godot 客户端** M0–M10 里程碑（已全部完成），不代表全项目进度 |

## 三、计划与 Backlog

| 文档 | 日期 | 状态 |
|---|---|---|
| [`EXPERIMENT_FACTORY_BACKLOG.md`](EXPERIMENT_FACTORY_BACKLOG.md) | 2026-07-05 | 活跃 backlog：P0/P1/P2 分级实验清单，含完成判据命令 |
| [`GAME_PLAN.md`](GAME_PLAN.md) | 历史计划 | Godot 客户端开发计划。**已执行完毕**（M0–M10 done，见 `STATUS.md`），保留作选型与架构决策记录 |

---

## 分支说明

本分支（`cursor/2bc5be1b`）的 `docs/` 是主仓库 docs 的**子集**。以下被引用的文档存在于主仓库检出（`~/Research/SatelliteSimJulia/docs/`）但不在本分支，属分支差异而非丢失：

- `USER_GUIDE.md` / `API_REFERENCE.md` / `DEVELOPER_GUIDE.md`（根 `README.md` 引用）
- `2026-07-06_LAYERED_ADVANCEMENT_STATUS.md`（`LAB12_INTERACTION_MATURITY.md` 引用）
- `modules/`、`audits/`、`实验编排层入口.md`（`AI_COLLABORATION_PROTOCOL.md` 引用）
- 根目录 `AGENTS.md`

## 2026-07-08 清理记录

以下文档已删除（git 历史可回溯，主仓库检出另有副本）：

- `2026-07-05_MAX_COMPUTE_PUSH_REPORT.md` — 一次性执行报告，历史使命完成
- `AGGRESSIVE_PROJECT_PUSH_PLAN.md` — 作战总纲，可执行部分已被 `EXPERIMENT_FACTORY_BACKLOG.md` 和 `VALIDATION_LADDER.md` 覆盖
- `milestones/`（M0–M7）— Godot 客户端已完工，结论与关键 commit 保留在 `STATUS.md` 进度表

## 文档纪律

1. 状态快照类文档必须带日期，过时后加时效声明而不是静默留存（先例：`PLATFORM_STATUS_REPORT.md` 文首声明）。
2. 一次性执行报告不长期留在 docs/：结论并入长期文档后即删，git 历史即存档。
3. 新增文档后在本索引登记归类。
