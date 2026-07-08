# scripts/ 索引

> 按「角色 + 门禁等级」分类。probe 的三档定义来自 `docs/LAB12_INTERACTION_MATURITY.md` 的建议：
> **regression**（默认验证门，`run_parallel_validation.jl` 默认执行）、
> **opt-in**（依赖外部环境/服务，环境变量开启）、
> **diagnostic**（手动诊断入口，不在门禁内）。
>
> 整理日期：2026-07-08。共 37 个 probe（34 `.jl` + 3 `.py`）+ 41 个其他脚本。

---

## 一、验证入口（先看这里）

| 脚本 | 用途 |
|---|---|
| `run_parallel_validation.jl` | **主入口**。串行 precompile 后并行跑全部 regression probe；package/viz/gmat/server/real-data 组按环境变量 opt-in |
| `quick_validate.jl` | 快速冒烟（已知坑：`src/link` 缺 Random 声明时会失败，pre-existing） |
| `smoke_core_net_lab_experiment.jl` | Core→Net→Lab 垂直冒烟 |
| `test_all.jl` / `run_regression.jl` / `package_tests.jl` | 统一测试 / 回归套件 / 分包测试矩阵 |
| `integration_test.jl` | 集成测试 |

常用命令见 `docs/VALIDATION_LADDER.md`（L0–L6 阶梯）。

## 二、probe：regression（默认门禁，29 个）

`run_parallel_validation.jl` 的 core_jobs + local_service_jobs，改动相关区域后必须回绿。

**引擎横切矩阵**：
`probe_e2e` `probe_opt` `probe_type_stability` `probe_experiment_matrix`
`probe_orbit_propagator_matrix` `probe_orbit_real_tle_unified_entry` `probe_orbit_tle_source_registry_entry`
`probe_topology_strategy_matrix` `probe_routing_algorithm_matrix`
`probe_dynamic_topology_churn` `probe_cli_command_matrix`

**traffic 路径**：
`probe_traffic_aon_power` `probe_traffic_minload_sequential` `probe_traffic_evaluation_minload_bridge`

**lab 编排边界**：
`probe_lab_integration_boundaries` `probe_lab_run_experiment_minload_aon_semantics`
`probe_lab_net_routing_vertical` `probe_lab_dynamic_topology_temporal` `probe_lab_temporal_flow_route_traffic`

**AI 交互层**（★ = 已镜像进 `src/lab/test/runtests.jl` 正式测试，脚本保留作诊断入口）：
`probe_ai_offline_react_planner`
`probe_ai_run_simulation_traffic_aon` ★
`probe_ai_run_simulation_sgp4_traffic_aon` ★
`probe_ai_llm_provider_fake_http` ★（起本地 fake HTTP）
`probe_ai_llm_provider_tool_loop` ★（起本地 fake HTTP）
`probe_ai_team_graph_run_simulation` ★
`probe_ai_team_graph_traffic_aon` `probe_ai_run_study_plan_traffic_aon`

**其他**：`probe_viz_czml_artifact`（CZML 无渲染） `probe_revise_hot_reload`

## 三、probe：opt-in（外部环境组，8 个）

| 环境变量 | probe |
|---|---|
| `SATSIM_RUN_VIZ_GROUP=1` | `probe_viz_png_artifact` `probe_viz_temporal_route_artifact` `probe_viz_traffic_load_artifact` |
| `SATSIM_RUN_REAL_DATA=1` | `probe_real_data_sources.py` `probe_real_traffic_demands.py` `probe_real_traffic_calibration_samples.py` `probe_real_scenario_sgp4_traffic_demands` `probe_ns3_stk_exporters` |

（GMAT/Server 组是包测试而非 probe，同样按 `SATSIM_RUN_GMAT_GROUP` / `SATSIM_RUN_SERVER_GROUP` 开启。）

## 四、诊断 / 演示（手动，不在门禁）

| 脚本 | 用途 |
|---|---|
| `demo_ai_orchestration.jl` | AI 编排演示（见 `docs/AI_ORCHESTRATION.md`） |
| `e2e_client.jl` | server 协议 oracle（list→start→frames） |
| `desktop_sandbox.jl` / `viz_demo.jl` | GLMakie 桌面沙盒 / 可视化演示 |
| `reconstruct_starlink_real_orbits.jl` | 真实 TLE 重建（大规模跑法见 `docs/VALIDATION_LADDER.md` L6） |
| `test_checkpoint.jl` `test_hooks.jl` `test_memory.jl` `test_intent_unification.jl` `test_prompt_cache_boundary.jl` | AI 层单项诊断（未系统纳入包测试） |
| `verify_end_to_end_gradient.jl` | 端到端梯度验证 |
| `call_kimi.jl` | LLM 手动调用 |

## 五、构建与基础设施

`build_core_net_lab_sysimage.jl` `precompile_core_net_lab.jl`（sysimage/预编译）
`mcp_tool_runner.jl` `mcp_stdio_server.jl`（MCP 安全面，契约见 `docs/SatelliteSimJulia_MCP_TOOLS.md`）
`sanitize_keys.jl` `validate_packages.jl`

## 六、文献 / 论文工具链（Python）

采集：`arxiv_collector.py` `fetch_real_data_sources.py` `fetch_ripe_measurement_results.py` `run_paper_agent.py` `run_paper_agent_daily.sh`（产出进 `research_store/`，已 gitignore）
加工：`build_actionable_papers.py` `build_layer_literature_shortlists.py` `build_literature_index.py` `build_paper1_materials.py` `build_supplementary_docs.py` `generate_literature_docs.py` `generate_literature_ppt.py`
流量数据：`build_real_traffic_demands.py` `calibrate_real_traffic_demands.py`
编排：`crewai_satnet_orchestrator.py`
审计：`zcode_token_usage_report.py`

---

## 维护纪律

1. 新增 probe 必须同时在 `run_parallel_validation.jl` 登记（默认组或 opt-in 组），并更新本索引。
2. probe 镜像进正式包测试后，在本索引标 ★，脚本保留作诊断入口。
3. 每个新脚本必须有 small-mode（`docs/VALIDATION_LADDER.md` 推进规则 3）。
