# 可微 SGP4 → 轨道-网络端到端可微（设计与分步计划）

> 状态：进行中（Step 1–2 已完成；后续步骤继续按评审结果推进）。
> 目标一句话：让梯度能从**真实 TLE 的 SGP4 轨道参数**（而不只是解析 J2 的 Walker 参数）一路反传到**网络 KPI**（覆盖 / 软 ISL / 软路由），并用有限差分逐步验证。
> 定位依据：据本文调研所及，未发现「轨道六根数 → 端到端可微 → 网络 KPI」的公开先例（dSGP4 止于轨道、Kacker&Cahoy 止于几何覆盖、dNE 止于地面 TE）。

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
- **Step 2（正式 API）✅（2026-07-13）**：在 Opt 落 `sgp4_constellation_series(params, epochs, ts_min)`（AD 透明，(N,NT,3) TEME）与 `sgp4_series_ecef(...)`（含 GMST 旋转、epoch 对齐），export + 测试。
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

**包内化文件**

| 文件 | 职责 |
|---|---|
| `src/opt/src/layers/06_optimization/sgp4_e2e.jl` | `sgp4_constellation_series`、`sgp4_series_ecef`、`coverage_loss_vjp`、`sgp4_e2e_gradient` |
| `src/opt/src/SatelliteSimOpt.jl` | include + export 上述 API |
| `src/opt/test/test_sgp4_e2e.jl` | 单元测试：VJP vs ForwardDiff；端到端梯度 vs 全量 ForwardDiff + 中心差分抽检 |
| `src/opt/scripts/sgp4_step1_check.jl` | 独立冒烟脚本（Modal 镜像入口；不 include `test/`） |

**配置**：真实 Starlink TLE 10 颗（`data/tle/celestrak/starlink_gp_latest.tle`，可用 `SATSIM_TLE_PATH` 覆盖）、NT=10（0–95 min）、`ground_grid(5,10)`（G=50）、`coverage_loss`。

**验证命令**

```bash
# 单元测试
julia --project=src/opt -e 'using Pkg; Pkg.resolve(); Pkg.instantiate(); Pkg.test(; coverage=false)'

# Step1 冒烟（4 线程 CPU，目标 <5 min）
julia --project=src/opt --threads=4 src/opt/scripts/sgp4_step1_check.jl
```

**STEP1_OK 判据**（脚本末行打印 `STEP1_OK` 即全过；任一失败 `exit(1)` 并打印原因）

1. `loss` 与 `grad` 全有限且非零范数。
2. 对 `|grad|` 最大的 20 个分量做中心差分：`h = 1e-6·max(|x_i|, 1e-2)`，`relerr = |g_ad − g_fd| / (|g_fd| + 1e-12)`，全部 `< 1e-3`。
3. 输出格式（逐行）：
   - `STEP1 loss=... grad_norm=... finite=true`
   - `STEP1 fd_max_relerr=... n_checked=20`
   - `STEP1_OK`

**早期原型**（已 supersede）：`/tmp/diffsgp4_step1.jl` 只读仓库数据验证过可行性（loss=0.9008，FD 最大相对误差 2.75e-5）；现以包内 API + 脚本为准。

- **顺手修复**：`coverage.jl` 的 `soft_coverage`/`logsumexp_max` 把 Dual 数塞进 `Float64` 字段导致 ForwardDiff 报错 → 改为默认字段构造分派 token；`sgp4_e2e_gradient` 中 `dP` 与 ForwardDiff Jacobian 展平顺序对齐（`(NT,3)` → `(3,NT)` 列主序）。
- 环境注意：`src/opt/Manifest.toml` 需在 Link 加依赖后 `Pkg.resolve()`（本机已做，Manifest 未提交）。

### Step 2 — 正式 API 与 1584 真实规模扩展 ✅（2026-07-13）

**交付**：`src/opt/src/layers/06_optimization/sgp4_e2e.jl`（`SatelliteSimOpt.jl` include + export），测试 `src/opt/test/test_sgp4_e2e.jl`（已接入 `src/opt/test/runtests.jl` 实际运行路径）。

**API**（时间契约显式化：`jd_ref` 为必填 kwarg，数值核不再隐式 `max(epochs)`；UTC≈UT1 近似、GMST z 旋转 TEME→PEF≈ECEF 无极移，GMST 对参数为常数不进 AD）：

- `sgp4_constellation_series(params, epochs, ts_min; jd_ref)` → `(N,NT,3)` TEME，AD 透明；
- `sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref)` → `(N,NT,3)` ECEF；
- `coverage_loss_vjp(positions, gp, w; ...) -> (loss, dP)`：`coverage_loss` 的手写 CPU 伴随（数学与 GPU 包 `adjoint.jl` 同款），`dt` 必须传真实时间步长（分钟）；
- `sgp4_e2e_gradient(params, epochs, ts_min, gp, w; jd_ref, engine=:enzyme|:blockdiag, dt=真实步长, ...) -> (loss, grad::Vector{7N})`。

**Step 2 正式验收**：两个 series API 均为公开 export；同一公共墙钟 epoch 下，2 颗真实 Starlink、3 个时刻的 Float64 ECEF 位置与 `SatelliteSimOrbit.propagate_to_ecef` 主链最大分量差约 `6.3e-5 km`（验收 `<1e-4 km`，差异来自等价墙钟/Julian-date 计算的 Float64 舍入）；对 7 类 TLE 参数分别穿过 TEME 与 ECEF 两个公开 API 的 ForwardDiff 梯度逐分量做中心差分步长扫描，两条路径均满足最大相对误差 `<1e-5`。

**双引擎**：主引擎 `:enzyme`（Enzyme 整链反向，一次反传拿全部 7N 梯度，单线程）；交叉验证引擎 `:blockdiag`（手写 loss 伴随 → dL/dP，再每星 ForwardDiff Jacobian 3NT×7（chunk=7，`Threads.@threads`）块对角收缩）。域校验：n₀>0、周期 ≥225 min 抛 ArgumentError（SDP4 不支持）、e∈[0,1)、|B*|<1。

**对标（N=10 真实 Starlink，NT=10，G=50）**：两引擎 vs 全量 ForwardDiff 相对 L2 **≈1.1e-15 / 1.3e-15**（验收 <1e-8）；中心差分 10 随机分量步长扫描（h×{0.1,1,10}）best-rel <1e-4 全过；随机方向导数相对误差 <1e-5；伴随 vs ForwardDiff-on-P（N=6,NT=4,G=20）rtol 1e-10 过。`Pkg.test` 全绿（aon_throughput 2 + SGP4 e2e 84）。

**1584 真实实验**（本机 M2 Max 32GB，julia 1.12.6，`-t auto`=8 线程；真实 Starlink TLE 前 1584 颗，epoch 跨度 3558 min；G=800（ground_grid(20,40)），λ=0.1，dt=真实步长，jd_ref=max(epochs)=2461199.83338。数字为实测非估算）：

| 配置 | loss | \|grad\| | Enzyme 热 run | blockdiag 总耗时（series/伴随/Jac/收缩） | 引擎互检 rel_l2 | 峰值 RSS |
|---|---|---|---|---|---|---|
| NT=20 (dt=5 min) | −0.331537585 | 8.90e-4 | 4.58 s | **1.88 s**（0.009/1.861/0.007/0.001） | 6.7e-8 | ~4.4 GiB |
| NT=96 (dt=1 min) | −0.331537753 | 7.00e-4 | 28.4 s | **9.47 s**（0.040/9.404/0.024/0.003） | 6.3e-8 | ~7.6–9.2 GiB |

前向（series+loss）单独计时：NT=20 0.855 s、NT=96 4.22 s。梯度 11088/11088 全有限非零。

**尺度化敏感度**（‖xⱼ·∂L/∂xⱼ‖₂，7 类参数按尺度归一后，NT=96）：n₀ 4.6e-5 ≫ M 5.4e-6 > i 3.5e-6 > argp 2.3e-6 > raan 1.9e-6 ≫ e 3.8e-10 ≈ B* 3.6e-10。注意这是"尺度化敏感度"（量纲无关的相对灵敏度指标），不作因果归因解释。

**解读与瓶颈**：
- 1584 星时 noisy-OR 覆盖饱和（mean_cov≈1），loss ≈ −1 + λ·τ·log G ≈ −0.33（LSE 下界项），梯度范数随饱和度变小——物理上合理（满覆盖星座的边际覆盖梯度趋零）。
- 两引擎 6e-8 互检差异来自 1584 项 noisy-OR 连乘的浮点消去（N=10 时互检 ~1e-15），属数值精度非实现错误。
- 瓶颈拆解：blockdiag 路径 >98% 时间在手写伴随（O(N·G·NT) 仰角+sigmoid 两遍），SGP4 series 与 per-sat Jacobian（8 线程）近乎免费；Enzyme 整链约为手写伴随的 2.4–3.0×（单线程、含 tape 开销），内存也更高。
- **结论：本机可常态化跑 1584 端到端梯度**——NT=20 一次梯度 <2 s（blockdiag）/ <5 s（Enzyme），NT=96 <10 s / <29 s，远低于 30 min 预算；日常迭代建议 blockdiag 为默认高性能路径、Enzyme 作数学参照，两者已在测试中互锁。

**顺带修正**：`soft_coverage` 文档描述错误（sigmoid 在 cutoff 处恒为 0.5，原文误写 τ=5° 时 ≈0.88）；本文档定位声明由「公开空白」改为「据本文调研所及未发现」。

## 六、验证与评审机制

- 每步：有限差分对标（中心差分、相对步长 1e-6、带地板的相对误差）+ 独立评估子程序（gpt-5.6-sol-max-fast）审读 + 用户逐步评审。
- 不 `git commit`，除非用户明确要求。
