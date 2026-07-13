# 可微 SGP4 → 轨道-网络端到端可微（设计与分步计划）

> 状态：进行中（Step 1–3 已完成；后续步骤继续按评审结果推进）。
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
- **Step 3（接真网络 KPI）✅（2026-07-13）**：TLE 参数 → 序列 → 覆盖损失 + 通用软 ISL 邻接（N 星推广，非 3 星玩具）→ 软网络 KPI（软时延 / 软可达 / 软代数连通度 λ₂）→ 复合标量梯度；输出按参数类别（n₀/e/i/Ω/ω/M/B*）的尺度化敏感度。
  **验收**：KPI 对 positions ForwardDiff vs 中心差分 <1e-6；端到端 θ→KPI（blockdiag/enzyme）vs 全量 ForwardDiff <1e-6；七类参数逐类 FD + 方向导数对标；每个软 KPI 给 hard 对照；最小归因演示打印 `STEP3_ATTRIBUTION_OK`。
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

### Step 3 — 轨道 → 网络 KPI（软 ISL 拓扑 + 软路由/连通性）✅（2026-07-13）

**定位**：把可微链从「轨道→几何覆盖」延伸到「轨道→网络 KPI」。据本文调研所及，未见「轨道六根数 → 端到端可微 → 网络 KPI（软 ISL 拓扑 + 软路由时延/连通性）」的公开先例（dSGP4 止于轨道、Kacker&Cahoy 止于几何覆盖、dNE 止于地面 TE）。

**新增文件**

| 文件 | 职责 |
|---|---|
| `src/opt/src/layers/03_topology/soft_isl_general.jl` | 通用软 ISL 邻接 `soft_isl_adjacency`（`Ã[i,j]=σ((d_thresh−d_ij)/τ)`，任意 N/时刻，**不依赖 Walker P/SPP**）、软边权 `soft_isl_edge_weights`、可选平滑 LOS 遮挡 `soft_los_factor`、硬参照 `hard_isl_adjacency` |
| `src/opt/src/layers/04_routing/soft_network_kpi.jl` | 三个可微 KPI + 组合损失 `network_kpi_loss` + dL/dP 伴随 + SGP4 接链 `sgp4_network_kpi_gradient` |
| `src/opt/test/test_sgp4_network_kpi.jl` | 单测（已并入 `src/opt/test/runtests.jl` 实际运行）|
| `src/opt/scripts/sgp4_step3_network_kpi.jl` | 真实规模实验脚本（独立入口，不 include test/）|
| `src/opt/scripts/sgp4_step3_attribution.jl` | 最小“梯度即归因”演示：覆盖 + 加权软网络 KPI 复合标量、七类尺度化敏感度、逐类中心差分与方向导数 |

**软 KPI 定义与 hard 对照**（均从 `(N,NT,3)` ECEF 序列按 NT 时间片聚合；AD 透明，纯 Julia 显式循环）

1. **软期望时延（ms）**：在软边权 `W[i,j]=d_ij+penalty·(1−ã_ij)`（无 `Inf`）上做软 Bellman-Ford，硬 `min` 换温度 `τsp` 的 softmin `−τ·logΣexp(−·/τ)`（softmin≤min，τ→0 收敛硬最短路）。KPI = OD 对与时间上 `soft_dist/c` 均值。**hard 对照**：`dijkstra_latency` 最短路时延。
2. **软可达比例**：`σ((dmax−soft_dist)/τ_reach)∈[0,1]` 的 OD/时间均值。**hard 对照**：Dijkstra 有限距离的 OD 占比。
3. **软代数连通度 λ₂（Fiedler 值）**：`L=D−Ã` 第二小特征值，定 K 步去偏（⊥1）幂迭代 Rayleigh 商估计（谱位移 `c=2·max_deg+1` 取 Gershgorin 紧界以保收敛）。**hard 对照**：`eigvals` 精确 λ₂。

**接链（两引擎）**：`sgp4_network_kpi_gradient(params, epochs, ts_min; jd_ref, gmsts, engine=:blockdiag|:enzyme, kind=:latency|:reachability|:connectivity|:combined, od_pairs, …) → (loss, grad::7N)`，时间契约同 `sgp4_series_ecef`（显式 `jd_ref`、UTC≈UT1、GMST z 旋转 TEME→PEF≈ECEF 无极移、SDP4 拒绝、域校验）。

- `:blockdiag`（默认，可扩展）：先算 dL/dP，再每星 ForwardDiff SGP4 Jacobian（3NT×7，chunk=7，`Threads.@threads`）块对角收缩 `∇_{θ_i}L=J_iᵀ·vec(dP[i,:,:])`（复用 `sgp4_e2e.jl` 的 `_satellite_series_ecef`）。**dL/dP 两条路**：
  - 连通度：免 tape 的**特征值扰动恒等式** `∂λ₂/∂Ã_ij=(v_i−v_j)²`（v 单位 Fiedler 向量，Hellmann–Feynman/包络定理，**收敛处精确**），`O(N²·NT)` 内存 → 可扩到全星座；
  - 时延/可达：一次 **Enzyme 反向**拿 dL/dP（tape 随 `K·N²·|src|·NT`，适中 N）。
- `:enzyme`（小 N 交叉验证）：整链一次 Enzyme 反向。

**对标（正确性，N=10 真实 Starlink）**

- KPI 对 positions（ForwardDiff-on-P vs 中心差分，步长扫描 best-rel）：时延 / 可达均 **< 1e-6**。
- 时延 dL/dP：Enzyme vs ForwardDiff-on-P 相对 L2 **≈ 1e-15**。
- 端到端 θ→时延：`:blockdiag` 与 `:enzyme` vs 全量 ForwardDiff 相对 L2 **≈ 1e-16**（验收 <1e-6）；随机方向导数中心差分 <1e-5。
- 连通度 λ₂ 扰动 VJP：端到端 `:blockdiag` vs 全量 ForwardDiff 相对 L2 **1.4e-9**；位置级（带谱隙的路径图）vs `eigvals` 精确 λ₂ 中心差分 < 1e-3；前向 `soft_algebraic_connectivity` vs `eigvals` < 1e-3。
- LOS：Enzyme==ForwardDiff（**1e-16 一致**）；但近掠射几何刚性，中心差分在不连续处会失配 → **LOS 只断言 AD 一致，不断言中心差分**（诚实，见下）。
- `Pkg.test` 全绿：aon_throughput 2 + SGP4 e2e 84 + **网络 KPI 188**。

**最小“梯度即归因”演示**（真实 Starlink TLE，默认 N=8、NT=4、真实 `dt=20 min`）：

```bash
julia --project=src/opt src/opt/scripts/sgp4_step3_attribution.jl
```

复合目标为 `L = L_coverage + 1e-3·latency − 0.25·reachability − λ₂`。本机实测
`L=5.811667`、`‖grad‖=2.815e2`，七类尺度化敏感度排序为
`n₀ > M > Ω > ω > i > e > B*`，故该配置下最敏感类别为 **n₀**。七类代表分量中心差分
最大 best-rel `2.20e-8`，随机方向导数相对误差 `9.23e-11`，末行
`STEP3_ATTRIBUTION_OK`。该排序是当前 TLE、时窗与损失权重附近的**局部尺度化灵敏度**，
不是因果效应或跨配置恒定结论；可用 `SATSIM_ATTR_N`、`SATSIM_ATTR_NT`、
`SATSIM_TLE_PATH` 覆盖默认配置。

**真实规模实验**（本机 M2 Max 32GB、julia 1.12.6、`-t auto`=8 线程；真实 Starlink TLE；`jd_ref=max(epochs)`。数字实测非估算；脚本 `sgp4_step3_network_kpi.jl`）

| KPI | 规模 | loss | ‖grad‖ | dL/dP 引擎·耗时 | 总梯度 | hard 对照 |
|---|---|---|---|---|---|---|
| 软代数连通度 λ₂ | N=**1584**, NT=4, d_thresh=5500km, τ=200, K=1500 | −33.755（=−mean λ₂） | 647.5（11088/11088 有限） | 扰动 VJP · 2.58 s | **2.94 s** | 精确 λ₂(t=1)=33.007992，幂迭代=33.007992，**relerr 7.3e-12**，gap(λ₃−λ₂)=5.03 |
| 软期望时延 | N=200, NT=6, d_thresh≈10921km, τ=400, τsp=80, K=24, \|OD\|=16 | 24.80 ms | 3052（1400/1400 有限） | Enzyme 反向 · 2.07 s | **2.09 s** | Dijkstra 均值(t=1)=26.72 ms（16/16 可达），soft=25.54 ms（差 **4.4%**）|

**尺度化敏感度**（‖xⱼ⊙∂L/∂xⱼ‖₂，量纲无关的相对灵敏度指标，**不作因果归因**）：

- 连通度：n₀ 4.31e1 ≫ M 4.90 > Ω 3.16 > ω 2.31 ≫ i 8.78e-1 ≫ B* 1.53e-3 ≈ e 7.72e-4。
- 时延：n₀ 2.06e2 ≫ M 2.79e1 > Ω 1.23e1 > ω 1.16e1 ≫ i 3.00 ≫ B* 2.92e-3 ≈ e 1.68e-3。

两 KPI 排序一致，且与覆盖实验同型：平近点角速率 n₀ 杠杆最大（定周期/相位 → 全部星间几何），e/B* 灵敏度最小（近圆低阻星座该时窗对这两类几乎不敏感）。

**解读与瓶颈**

- 连通度 dL/dP 用扰动恒等式（免反向 tape），`O(N²·NT)`，本机 1584 一次端到端梯度 < 3 s；K=1500 时前向 λ₂ 与精确特征值机器精度一致（7e-12）。前提是幂迭代收敛且 λ₂ 有谱隙：稠密星座低谱拥挤时收敛需更多 K（谱位移已取 Gershgorin 紧界 `2·max_deg+1`，把先前 `2N` 过松导致的收敛停滞从 relerr 23% 修正到 7e-12）。
- 时延用 Enzyme 反向拿 dL/dP，tape 随 `K·N²·|src|·NT`，故本轮时延做到 N=200；扩到 1584 需按时间片切 tape 或手写 Bellman 伴随（后续可加）。软时延对硬 Dijkstra 的差距随 (τ,τsp)→0 单调收敛（实测 12.97%→4.77%→0.51%→0.14%→0.03%），本实验用适中温度换梯度光滑。

**诚实边界**

- 三个 KPI 都是 soft 代理：软 ≤K-hop 路径自由能（报告为软期望时延）↔ Dijkstra 最短路时延、软距离阈值比例 ↔（大 dmax 下）可达 OD 占比、软 λ₂ ↔ **同一软拉普拉斯**的精确第二小特征值（不是 {0,1} 硬邻接的 λ₂）。报告均给了数值对照与差距。
- softmin **排除零代价自环**：若把 `W[j,j]=0` 纳入 softmin，则 softmin(d,d)=d−τlog2，距离会每步向 −∞ 漂移；`K` 是度量的一部分（≤K 跳），τsp→0 且 K≥直径时恢复 Dijkstra。
- 连通度扰动 VJP `∂λ₂/∂w_ij=(v_i−v_j)²` **仅在 Fiedler 残差低于容差时启用**（Hellmann–Feynman/包络定理在收敛处成立）；否则 `:blockdiag` 回退到 Enzyme 对有限-K Rayleigh 商本身求导。
- 不连续处（链路通断 / 选路 argmin / 距离阈值 / 地球遮挡）一律软松弛（sigmoid / softmin），引用 **Suh et al., ICML'22** 作为可微仿真器一阶梯度在刚性/不连续处可能失效的广义警示；AD 返回的是松弛本身的分支导数，不是硬仿真器的梯度。LOS 掠射与 λ₂ 近简并谱即此类。
- 定位一律「据本文调研所及」，不写「首个/唯一」。深空 SDP4 不做；TEME→ECEF 仅 GMST z 旋转（无极移，与主链同款近似）。默认 `los=false` 时软邻接允许穿地弦，物理 ISL 需显式打开 LOS。
- 时延/可达 Enzyme 反向 tape 随 `K·N²·|src|·NT`，本轮时延做到 N=200；连通度免 tape 路径可到 1584。稠密 soft 尾在大 N 上使图近乎完全，进一步扩规模需候选图稀疏化（后续）。
- 公共 KPI 与 dL/dP 入口接受 `AbstractArray`/`SubArray`；Enzyme shadow 递归镜像视图结构，不要求调用者复制。

## 六、验证与评审机制

- 每步：有限差分对标（中心差分、相对步长 1e-6、带地板的相对误差）+ 独立评估子程序（gpt-5.6-sol-max-fast）审读 + 用户逐步评审。
- 不 `git commit`，除非用户明确要求。
