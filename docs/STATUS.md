# SatelliteSim Godot 客户端 — 进度跟踪

> 每个 milestone 一个 commit。状态变化时更新本文档 + 一个 commit。

## 当前进度

| M    | 任务                             | 状态          | 关键 commit |
|------|----------------------------------|---------------|-------------|
| M0   | 装 Godot 4                       | ✅ done       | -           |
| M1   | 项目骨架 + 5 GDScript            | ✅ done       | `da7cb75`, `7818be2` |
| M2   | WS 端到端（list+start+frames）   | ✅ done       | headless 测试 |
| M3   | 3D 地球 + 卫星散点               | ✅ done       | `28572c9`, `5716614`, `356d5fe` |
| M4   | ISL 实时连线                     | ✅ done       | `b4d0449`, `1ec265e` |
| M5   | UI 控制面板                      | ✅ done       | `b59828c` |
| M6   | 摄像机控制                       | ✅ done       | `223a8b6`, `e730fc5`, `7572959`, `2bdd814` |
| M7   | 14 星座回归 + 性能               | ⏳ in progress | `e5d1a8e`, `f5baeac`, `d43c9e2`, `407ce27` (M7.2 done) |

## 工作纪律

1. 一次只动一个文件 / 一个功能
2. 每个 commit 单一目的，message 写清楚验证结果
3. 改之前先告诉用户（"改什么、哪几行、为什么"）
4. 改完跑 e2e 或相关测试再 commit
5. 完成 milestone 后更新本文档 + 一个 commit

## 文档导航

- [`GAME_PLAN.md`](GAME_PLAN.md) — 完整计划（选型、架构、风险）
- [`milestones/`](milestones/) — 每个 M 单独文档
- [`STATUS.md`](STATUS.md) — 本文件，进度表
