# AI 协作输入/输出协议

本文档定义在 SatelliteSimJulia 项目中与 AI 协作的输入/输出协议，目标是**减少上下文浪费**：让每条信息归位到「谁负责提供、提供一次还是每次、是否需要进上下文」，避免重复贴、贴无关内容或让 AI 盲目读全仓。

创建时间：2026-07-08

---

## 一、五层信息分类

减少上下文浪费的核心是**分层职责**。每条信息归到下表其中一类：

| 类别 | 谁提供 | 频率 | 是否进上下文 | 说明 |
|---|---|---|---|---|
| **固定背景** | 系统 / Project Context | 一次，长期固定 | 常驻 | 架构、依赖方向、9 条纪律、已知坑、验证命令 |
| **本轮任务** | 用户，每次 | 每轮 | 进 | 目标 + 验收标准，1–5 行 |
| **临时证据** | 用户指路 / AI 读取 | 每轮 | 按需进，读段落不读全文 | 具体文件路径+行号、报错原文、数据样例 |
| **执行约束** | 用户，可选 | 每轮或引用固定项 | 进 | 允许改哪些文件、禁改哪些、是否允许跑测试 |
| **输出格式** | 用户，可选 | 每轮或用默认 | 进 | 要 diff / 要文本 / 要报告 / 要不要 commit |

关键约定：

- **固定背景不重复贴**（已在 Project Context，引用即可，如「按纪律 4」）。
- **临时证据优先给路径而非贴内容**（AI 自己读，只读相关段落）。
- **Project Context 只放长期稳定的固定背景，不放一次性任务**；一次性任务只放聊天框（见第五节）。

---

## 二、标准任务模板

每轮任务用这个骨架，字段可缺省（缺省时走默认或由 AI 反问）：

```
# 任务
<一句话目标>

# 验收标准
<可验证的完成判据；最好能对应一条验证命令>

# 证据/入口（给路径，不贴大段内容）
- 相关文件：src/xxx/yyy.jl(:行号范围)
- 相关文档：docs/xxx.md
- 报错原文：<如有，贴关键几行>

# 约束
- 允许改：<文件/目录，或"只读分析">
- 禁改：<默认含 Core/Server/旧代码，可引用固定纪律>
- 敏感区：<是否碰 Core/handlers.jl 等>

# 输出
- 形式：<diff / 替换文本 / 分析报告 / 报告+commit>
- 验证：<跑哪条命令算绿；默认按改动范围选最小命令>
```

**默认值**（用户不写时按此执行）：

- 约束默认「外科手术式、旧代码不动、只碰任务相关文件」（AGENTS.md 9 条纪律）。
- 输出默认「先说改动计划 → 改 → 说明改了什么/怎么验证/风险」。
- 验证默认**按改动范围选最小命令**，不要所有任务都默认跑完整回归（见第四节）。

---

## 三、执行前置判断：直接做 vs 先给计划

- **需求明确的小任务**（单文件、局部、低风险、无歧义）→ **可以直接执行**，执行后说明改了什么/怎么验证/风险。
- **涉及 Core/Server、大范围改动、或需求有歧义** → **先给计划并等确认**，计划要可验证（每步有完成判据），确认后再动手。

对应 AGENTS.md「修改敏感区域前必读」清单：`src/core/SatelliteSimCore.jl`、`src/server/handlers.jl`、`src/net/SatelliteSimNet.jl` 等属敏感区，改前必读且先给计划。

---

## 四、验证命令按范围选择（最小验证原则）

**不要所有任务都默认跑完整回归。** 按改动范围选最小能覆盖的验证命令：

| 改动范围 | 建议验证命令 |
|---|---|
| 只读分析 | 无需跑测试 |
| 单个子包（如 net/orbit/link） | 该子包的 `test/runtests.jl` |
| 跨 Core/Net/Lab 编排 | `julia --project=. scripts/smoke_core_net_lab_experiment.jl` |
| Server 端 | `julia --project=src/server -e 'using Pkg; Pkg.test()'` + `julia --project=src/server scripts/e2e_client.jl` |
| Godot 客户端 | `~/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot-sandbox -s godot-sandbox/tests/regression_constellations.gd` |

已知坑（来自 AGENTS.md）：

- `src/server/Manifest.toml` 缓存陈旧 → `julia --project=src/server -e 'using Pkg; Pkg.resolve(); Pkg.precompile()'`。
- `scripts/quick_validate.jl` 因 `src/link/Project.toml` 缺 `Random` 会失败，属 pre-existing bug，未要求不修。

---

## 五、用户不该贴、应让 AI 自己读的内容

以下贴给 AI = 浪费上下文，请只给路径，AI 按需读段落：

1. **实现源码全文** — `precomposed.jl`、`agent.jl`、`handlers.jl` 等。给路径（最好带行号），AI 只读相关段落。
2. **单模块 API 细节** — `docs/modules/0X_*.md` 是标准参考，点名一篇即可。
3. **编排层/协议契约** — `docs/实验编排层入口.md`、`src/server/README.md`。
4. **大而全的索引/合并文件** — `REPO_MAP.md/.txt`、`SatelliteSimCore_combined.md`、`_索引/`、`project_docs/`。除非明确指定，一般不读。
5. **literature / paper / benchmark / competitive** — 只在明确做调研/论文/对标任务时才碰。
6. **已在 Project Context 的固定背景** — 架构图、依赖方向、9 条纪律、已知坑、验证命令。不用重复贴，直接引用。
7. **完整测试日志** — 失败时贴关键几行报错即可。
8. **git 历史全文** — 给 commit 短 hash 或范围，AI 自己 `git show`。

**应该贴的**：一句话目标、可验证的验收标准、精确文件路径（+行号）、报错原文的关键几行、本轮特殊约束、期望输出形式。

**关于 Project Context**：只放长期稳定的固定背景（架构、纪律、坑、命令）。一次性任务（本轮目标、临时约束、这次要看的文件）只放聊天框，不要塞进 Project Context——否则会长期占用上下文且很快过时。

---

## 六、三个示例

### 示例 1：只读分析

```
# 任务
搞清楚 assess_ground_traffic_temporal_dynamic 的数据流和它调用的底层原子工具。

# 验收标准
能画出调用链（GSL access → Traffic bridge → AON/MinLoad → 负载样本），并指出它没有引入新物理真相源。

# 证据/入口
- src/lab/src/layers/11_experiment/precomposed.jl
- docs/实验编排层入口.md

# 约束
- 只读分析，不改任何文件。

# 输出
- 形式：分析报告（调用链 + 依赖检查）。
- 验证：无需跑测试。
```

AI 响应形态：只读相关段落 → 给调用链 + 依赖方向核对 → 不写代码。

### 示例 2：代码修改

```
# 任务
给 net 层新增一种 ISL 拓扑策略 XxxStrategy。

# 验收标准
- 新增子类型 + generate_topology 新方法，老策略行为不变。
- 为新策略写最小测试并通过。

# 证据/入口
- src/net/src/（拓扑策略定义位置）
- docs/modules/04_topology.md

# 约束
- 允许改：src/net/ 下新增文件 + 在导出处加符号。
- 禁改：已有策略实现、Core、算法层不硬编码星座参数。
- 走"新类型+新方法"，不改老代码（纪律 4）。

# 输出
- 形式：先给计划 → diff → 改了什么/风险。
- 验证：src/net 测试 + smoke_core_net_lab_experiment.jl 绿。
```

AI 响应形态：先出计划（改哪个文件、加哪几行）等确认 → 新增文件/方法 → 跑指定回归 → 报告改动+验证+风险。（net 属常规子包、走新类型新方法，风险可控；但因涉及导出与 smoke 回归，仍建议先给计划。）

### 示例 3：测试 / 回归验证

```
# 任务
验证 server 端到端链路（list → start → frames）是否正常。

# 验收标准
e2e_client.jl 能拿到 frame，无 MethodError/连接被踢。

# 证据/入口
- src/server/README.md（协议）
- 已知坑：Manifest 缓存 / handlers.jl:131 target= 陷阱

# 约束
- 只跑验证，不改代码；如需修依赖只做 Pkg.resolve/precompile。
- quick_validate.jl 的 Random 报错是 pre-existing，不修。

# 输出
- 形式：运行结果 + 通过/失败判定 + 失败时定位到具体行。
- 验证命令：
  julia --project=src/server -e 'using Pkg; Pkg.test()'
  julia --project=src/server scripts/e2e_client.jl
```

AI 响应形态：按顺序跑命令 → 贴关键结果（不贴全量日志）→ 绿则收尾，红则定位到文件+行并提修法（先不改）。

---

## 七、一句话总纲

固定背景引用不重贴，任务只给目标+验收，证据只给路径不给全文，实现细节 AI 按路径自读段落；小任务直接做、动敏感区先给计划，验证按范围选最小命令。

---

## 八、日常快捷模板

适合语音或快速打字使用。5 个字段全可留空，留空按协议默认处理（外科手术式、旧代码不动、按范围选最小验证、动敏感区先给计划）。

```
任务：<一句话干什么>
验收：<怎样算完成>
入口：<文件/文档路径，可留空让 AI 找>
约束：<只读 / 可改哪 / 禁改，留空走默认纪律>
输出：<分析 / diff / 报告，留空走默认>
```

### 5 个示例

示例 1（只读分析）
```
任务：讲清 run_experiment 到底调了哪些底层工具
验收：给出调用链，确认没引入新物理
入口：src/lab/src/layers/11_experiment/
约束：只读
输出：分析
```

示例 2（加拓扑策略）
```
任务：net 层加一个 RingPlus ISL 拓扑策略
验收：新类型+新方法，老策略不变，带最小测试
入口：src/net/src/、docs/modules/04_topology.md
约束：只新增文件，禁改老策略和 Core
输出：先计划再 diff
```

示例 3（Server 验证）
```
任务：验证 server list→start→frames 端到端
验收：e2e 能拿到 frame，无 MethodError
入口：src/server/README.md
约束：只跑验证，不改码，Random 报错不修
输出：结果+判定
```

示例 4（查 bug）
```
任务：定位 evaluate_isl_batch 时延偏大的原因
验收：找到根因并指出在哪几行
入口：src/link/src/
约束：只读定位，先别改
输出：分析+修法建议
```

示例 5（加指标）
```
任务：metrics 加一个链路利用率分位数指标
验收：新函数+导出，带测试，老指标不变
入口：src/metrics/src/、docs/modules/06_metrics.md
约束：新增为主，禁改 Core
输出：先计划再 diff
```
