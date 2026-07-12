# 可微 SGP4 → 轨道-网络端到端可微（设计与分步计划）

> 状态：进行中（步进实施，每步经用户评审 + 独立评估子程序把关）。
> 目标一句话：让梯度能从**真实 TLE 的 SGP4 轨道参数**（而不只是解析 J2 的 Walker 参数）一路反传到**网络 KPI**（覆盖 / 软 ISL / 软路由），并用有限差分逐步验证。
> 定位依据：调研确认「轨道六根数 → 端到端可微 → 网络 KPI」到 2026 年仍是公开空白（dSGP4 止于轨道、Kacker&Cahoy 止于几何覆盖、dNE 止于地面 TE）。

## 一、已有基础（盘点，全部有测试）

| 能力 | 位置 | 状态 |
|---|---|---|
| 单星/星座 SGP4 对 7 参数（n₀,e,i,Ω,ω,M,B*）可微，ForwardDiff+Zygote，FD 对标 <1e-4 | `src/opt/src/layers/01_orbit/propagator_differentiable.jl`（`_sgp4_from_params`、`constellation_gradient`） | ✅ `test/test_differentiable_propagator.jl` |
| 玩具端到端：3 星 SGP4（单时刻）→ 软路由损失 → 21 参数梯度（fwd/rev/FD） | `src/opt/src/layers/06_optimization/end_to_end_gradient.jl` | ✅ `test/test_end_to_end_gradient.jl`（CURRENT.md 记录） |
| 覆盖软松弛 R1–R4 + `coverage_loss(positions N×NT×3, …)` | `src/opt/src/layers/06_optimization/coverage.jl` | ✅（当前只接解析 Kepler/J2 参数化） |
| 软 ISL / 软容量 / 拥塞损失 | `src/opt/src/layers/03_topology/soft_isl.jl` 等 | ✅ |
| TEME→ECEF 简化旋转（GMST z 旋转，AD 安全） | `src/opt/src/layers/01_orbit/propagator_keplerian.jl` `teme_to_ecef_simple` | ✅ |
| 真实 Starlink TLE（10,495 颗，本机） | `data/tle/celestrak/starlink_gp_latest.tle` | ✅ |

## 二、缺口（本设计要补的）

1. **时间序列批量可微 SGP4**：现有可微入口只算单时刻 `t_min`；网络损失（覆盖/重访/ISL 时变）需要 `(N, NT, 3)` 序列。
2. **真实 TLE → ECEF → 网络损失未接通**：`coverage_loss` 等现在只吃解析 Kepler/J2 的 `(raans, mas)` 参数；SGP4 输出（TEME）没有走 GMST 旋转接到地面相关损失。
3. **多星 epoch 对齐**：各星 TLE epoch 不同，需按公共墙钟时刻对齐（`dt_i = (jd_ref − epoch_i)×1440 + t_min`）。
4. **反向模式限制**：`coverage_loss` 内部有数组 mutation——ForwardDiff 可用，**Zygote 不可用**；反向模式需 Enzyme 或免 mutation 重写（后置步骤处理）。
5. **规模与性能**：ForwardDiff 参数量 = 7N；N 大时需换反向模式或分块（后置评估）。

## 三、分步计划（每步：交付 + 验收标准；做完一步经评审再下一步）

- **Step 1（可行性冒烟，先行）**：真实 Starlink TLE（10 颗）→ 时间序列 SGP4（~1 轨道周期、10 时间步）→ GMST 旋转到 ECEF → `coverage_loss` → ForwardDiff 对 70 个 TLE 参数求梯度。
  **验收**：损失有限、梯度有限且非零；vs 中心差分最大相对误差 < 1e-3（含浮动地板）；记录耗时。
- **Step 2（正式 API）**：在 Opt 落 `sgp4_constellation_series(params, epochs, ts_min)`（AD 透明，(N,NT,3) TEME）与 `sgp4_series_ecef(...)`（含 GMST 旋转、epoch 对齐），export + 测试。
  **验收**：与 `src/orbit` 的 SGP4 非可微路径在 Float64 下位置一致（同 epoch 约定）；ForwardDiff 梯度 FD 对标。
- **Step 3（接真网络损失）**：TLE 参数 → 序列 → 覆盖损失 + 软 ISL/软路由损失（N 星推广，非 3 星玩具）→ 标量 KPI 梯度；输出按参数类别（n₀/e/i/Ω/ω/M/B*）的敏感度归因。
  **验收**：FD 对标；给出一个"梯度即归因"的最小演示（哪类轨道参数对该 KPI 最敏感）。
- **Step 4（反向模式与规模）**：Enzyme（或免 mutation 覆盖损失变体）打通反向；在更大 N（≥66）测时间/内存，与 ForwardDiff 对比，给出选型建议。
  **验收**：反向 vs 前向梯度一致（<1e-6 相对）；规模基准表。
- **Step 5（收口）**：测试并入 `src/opt` 测试套；`docs/`/`CURRENT.md` 如实更新；（可选）与 GPU 包的可微覆盖伴随衔接。

## 四、风险与护栏（诚实边界）

- **不连续处梯度**（可见性/ISL 通断）：全部走已有软松弛（R1–R4、sigmoid 软链路）；引用 Suh et al. (ICML'22) 的限制，不宣称"可微处处更优"。
- **B\* 梯度量级小**：相对误差用带地板的口径，B\* 单独报告，不混入整体断言。
- **深空 SDP4 不做**（与 GPU 包口径一致）；TEME→ECEF 只做 GMST z 旋转（与 CPU 主链 `r_eci_to_ecef(TEME,PEF)` 同款近似，不含极移）。
- **epoch 对齐近似**：以 `jd_ref = max(epochs)` 为公共参考；GMST 按公共墙钟时刻取，**对参数梯度是常数**（不进 AD）。
- 每步先 `ForwardDiff`（对 mutation 鲁棒）；Zygote/Enzyme 只在标注免 mutation 的入口上启用。

## 五、进展记录

### Step 1 — 可行性冒烟 ✅（2026-07-13）

- 脚本：`/tmp/diffsgp4_step1.jl`（只读仓库数据）。配置：真实 Starlink TLE 10 颗（epoch 跨度 500.1 min）、NT=10（0–95 min）、地面网格 G=50、`coverage_loss`。
- 结果：loss=0.9008（有限）；ForwardDiff 70 参数梯度全有限且非零，`|grad|=50.59`；**vs 中心差分最大相对误差 2.75e-5**（70/70 全为显著分量）；ForwardDiff 2.7s（含编译）、FD <0.05s。
- 参数类敏感度（未归一，仅示意）：n₀ 主导（50.6），e 0.35，Ω 0.21，ω/M ~0.11，i 0.068，B* 0.045。注意 n₀ 量级大部分来自单位尺度（rad/min），Step 3 归因需做尺度归一。
- **顺手修复**：`coverage.jl` 的 `soft_coverage`/`logsumexp_max` 把 Dual 数塞进 `SoftCoverage`/`LogSumExpMax` 的 `Float64` 字段导致 ForwardDiff 报错；改为用默认字段构造分派 token（`relax` 只读显式实参，语义不变）。待回归验证。
- 环境注意：`src/opt/Manifest.toml` 需在 Link 加依赖后 `Pkg.resolve()`（本机已做，Manifest 未提交）。

## 六、验证与评审机制

- 每步：有限差分对标（中心差分、相对步长 1e-6、带地板的相对误差）+ 独立评估子程序（gpt-5.6-sol-max-fast）审读 + 用户逐步评审。
- 不 `git commit`，除非用户明确要求。
