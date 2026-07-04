# ===== 流量需求模式（工程级）=====
#
# 4 种真实需求模式，每种生成 Vector{TrafficDemand} 喂给 evaluate_traffic。
# 现有 intent_resolution 只有 4 种恒定速率模式（UniformLoad/HotspotLoad/VideoLoad/IoTLoad），
# 本文件补充工程级模式：OD 矩阵、人口加权、泊松到达、昼夜调制。
#
# 新增于 2026-07-04（Phase 1 - A2）。

using Random
using Statistics: mean

# 标准库实现分布（不依赖 Distributions.jl）

"""泊松采样（Knuth 算法）。"""
function _rand_poisson(rng::AbstractRNG, λ::Float64)::Int
    λ <= 0 && return 0
    L = exp(-λ)
    k = 0
    p = 1.0
    while true
        k += 1
        p *= rand(rng)
        p <= L && return k - 1
        k > 100_000 && return k  # 安全阀（极端 λ）
    end
end

"""指数分布采样（rate = 1/mean）。"""
_rand_exponential(rng::AbstractRNG, mean::Float64)::Float64 = mean * randexp(rng)

"""对数正态采样（保证正数）。"""
function _rand_lognormal(rng::AbstractRNG, μ_ln::Float64, σ::Float64)::Float64
    # LogNormal(μ, σ²) = exp(Normal(μ, σ²))
    # Box-Muller 生成标准正态
    u1 = rand(rng); u2 = rand(rng)
    z = sqrt(-2log(u1)) * cos(2π * u2)
    return exp(μ_ln + σ * z)
end

export
    # 抽象模式类型
    AbstractDemandPattern,
    TrafficMatrixPattern,
    PopulationWeightedPattern,
    PoissonArrivalPattern,
    DiurnalPattern,
    # 生成器
    generate_demands

# ────────────────────────────────────────────────────────────
# 抽象接口
# ────────────────────────────────────────────────────────────

"""
    AbstractDemandPattern

所有流量需求模式的抽象基类型。每种模式通过多重分派实现 generate_demands。
"""
abstract type AbstractDemandPattern end

"""
    generate_demands(pattern, ground_ids, t0_s, duration_s; rng, kwargs...) -> Vector{TrafficDemand}

把需求模式翻译成具体 OD 需求列表。
"""
function generate_demands end

# 全对（不含自环）
_all_ground_pairs(gids) = [(a, b) for (i, a) in enumerate(gids) for b in gids[i+1:end]]

# 自增 id 生成器
_next_ids(n::Int) = collect(1:n)

# ────────────────────────────────────────────────────────────
# 模式 1：OD 矩阵（用户直接给 N×N 速率矩阵）
# ────────────────────────────────────────────────────────────

"""
    TrafficMatrixPattern

用户直接给 OD（Origin-Destination）速率矩阵，支持任意分布。
矩阵元素 [i,j] = 从地面站 i 到 j 的恒定速率（Mbps），对角线忽略。

适用于：已知精确流量矩阵的研究场景（如对标文献基准）。
"""
struct TrafficMatrixPattern <: AbstractDemandPattern
    matrix::Matrix{Float64}  # N×N，元素 = Mbps
end

function generate_demands(
    pattern::TrafficMatrixPattern,
    ground_ids::Vector{Int},
    t0_s::Int,
    duration_s::Int;
    rng::AbstractRNG = Random.default_rng(),
)
    mat = pattern.matrix
    N = length(ground_ids)
    size(mat) == (N, N) ||
        throw(ArgumentError("matrix must be $(N)×$(N), got $(size(mat))"))
    demands = TrafficDemand[]
    id = 0
    for i in 1:N, j in 1:N
        i == j && continue
        rate = mat[i, j]
        rate > 0 || continue
        id += 1
        push!(demands, TrafficDemand(;
            id = id,
            source_ground_id = ground_ids[i],
            destination_ground_id = ground_ids[j],
            start_elapsed_s = t0_s,
            end_elapsed_s = t0_s + duration_s,
            rate_mbps = rate,
        ))
    end
    return demands
end

# ────────────────────────────────────────────────────────────
# 模式 2：人口加权（按地面站权重生成非均匀需求）
# ────────────────────────────────────────────────────────────

"""
    PopulationWeightedPattern

按地面站权重（如人口、GDP）加权生成需求。
权重高的地面站发起/接收更多流量。

适用于：模拟真实地理流量分布（城市 vs 农村）。

# 字段
- `weights::Vector{Float64}`: 每个地面站的权重（与 ground_ids 等长）
- `total_demand_mbps::Float64`: 总需求速率，按权重分配到各 OD 对
"""
struct PopulationWeightedPattern <: AbstractDemandPattern
    weights::Vector{Float64}
    total_demand_mbps::Float64
end

function generate_demands(
    pattern::PopulationWeightedPattern,
    ground_ids::Vector{Int},
    t0_s::Int,
    duration_s::Int;
    rng::AbstractRNG = Random.default_rng(),
)
    N = length(ground_ids)
    length(pattern.weights) == N ||
        throw(ArgumentError("weights must match ground_ids length"))
    w = pattern.weights
    total_w = sum(w)
    total_w > 0 || throw(ArgumentError("weights must sum to positive"))

    # 每对 (i,j) 的速率 = total * (w_i * w_j) / sum_{a≠b}(w_a * w_b)
    # 归一化：所有非自环对的权重积之和
    pair_weight_sum = sum(w[i] * w[j] for i in 1:N for j in 1:N if i != j)
    demands = TrafficDemand[]
    id = 0
    for i in 1:N, j in 1:N
        i == j && continue
        rate = pattern.total_demand_mbps * (w[i] * w[j]) / pair_weight_sum
        rate > 0 || continue
        id += 1
        push!(demands, TrafficDemand(;
            id = id,
            source_ground_id = ground_ids[i],
            destination_ground_id = ground_ids[j],
            start_elapsed_s = t0_s,
            end_elapsed_s = t0_s + duration_s,
            rate_mbps = rate,
        ))
    end
    return demands
end

# ────────────────────────────────────────────────────────────
# 模式 3：泊松到达（随机到达 + 指数持续，生成时间序列需求）
# ────────────────────────────────────────────────────────────

"""
    PoissonArrivalPattern

泊松到达模型：需求按泊松过程随机到达，每个需求持续指数分布时间。
模拟突发性流量（如 web 请求、短连接）。

# 字段
- `arrival_rate_hz::Float64`: 整个网络的到达率（需求/秒），泊松 λ
- `mean_duration_s::Float64`: 每个需求的平均持续秒数（指数分布均值）
- `mean_rate_mbps::Float64`: 每个需求的平均速率
- `rate_std_mbps::Float64`: 需求速率标准差（对数正态抖动）
- `pairs::Union{Nothing,Vector{Tuple{Int,Int}}}`: 限制 OD 对（nothing = 全对均匀选）

适用于：模拟真实互联网流量的突发性和随机性。
"""
struct PoissonArrivalPattern <: AbstractDemandPattern
    arrival_rate_hz::Float64
    mean_duration_s::Float64
    mean_rate_mbps::Float64
    rate_std_mbps::Float64
    pairs::Union{Nothing,Vector{Tuple{Int,Int}}}
end

# 便捷构造器
PoissonArrivalPattern(;
    arrival_rate_hz::Float64 = 0.1,
    mean_duration_s::Float64 = 60.0,
    mean_rate_mbps::Float64 = 20.0,
    rate_std_mbps::Float64 = 10.0,
    pairs::Union{Nothing,Vector{Tuple{Int,Int}}} = nothing,
) = PoissonArrivalPattern(arrival_rate_hz, mean_duration_s, mean_rate_mbps, rate_std_mbps, pairs)

function generate_demands(
    pattern::PoissonArrivalPattern,
    ground_ids::Vector{Int},
    t0_s::Int,
    duration_s::Int;
    rng::AbstractRNG = Random.default_rng(),
)
    N = length(ground_ids)
    # 确定可用 OD 对
    od_pairs = pattern.pairs === nothing ? _all_ground_pairs(ground_ids) : pattern.pairs
    isempty(od_pairs) && return TrafficDemand[]

    # 泊松到达：期望到达数 = λ * duration
    expected_arrivals = pattern.arrival_rate_hz * duration_s
    n_arrivals = _rand_poisson(rng, expected_arrivals)

    demands = TrafficDemand[]
    for id in 1:n_arrivals
        # 到达时间：均匀分布（泊松过程的条件分布）
        arrival_offset = rand(rng) * duration_s
        arrival_s = t0_s + Int(floor(arrival_offset))
        # 持续时间：指数分布
        dur_s = max(1, Int(floor(_rand_exponential(rng, pattern.mean_duration_s))))
        end_s = min(t0_s + duration_s, arrival_s + dur_s)
        end_s <= arrival_s && continue
        # OD 对：均匀随机选
        (src, dst) = rand(rng, od_pairs)
        # 速率：对数正态（保证正数）
        σ = pattern.rate_std_mbps > 0 ? pattern.rate_std_mbps / pattern.mean_rate_mbps : 0.01
        μ_ln = log(pattern.mean_rate_mbps) - σ^2 / 2
        rate = max(0.1, _rand_lognormal(rng, μ_ln, σ))
        push!(demands, TrafficDemand(;
            id = id,
            source_ground_id = src,
            destination_ground_id = dst,
            start_elapsed_s = arrival_s,
            end_elapsed_s = end_s,
            rate_mbps = rate,
        ))
    end
    return demands
end

# ────────────────────────────────────────────────────────────
# 模式 4：昼夜调制（恒定需求 × 昼夜峰值因子）
# ────────────────────────────────────────────────────────────

"""
    DiurnalPattern

昼夜调制模型：基础需求按昼夜峰值因子调制。
把仿真时长映射到 24 小时周期，每个时间窗的速率 = base_rate × diurnal_factor(hour)。

适用于：模拟真实互联网的昼夜潮汐（白天高、深夜低）。

# 字段
- `base_rate_mbps::Float64`: 每对的基础速率
- `peak_ratio::Float64`: 峰值/谷值比（如 3.0 = 峰值是谷值的 3 倍）
- `phase_offset_h::Float64`: 相位偏移（小时），用于对齐时区
- `pair_set::Symbol`: :all（全对）或 :hotspot（20% 热点对高基础速率）

# 原理
昼夜因子 = 1 + (peak_ratio - 1) * (sin(2π*(hour - 6 + phase)/24) + 1) / 2
hour=6 时谷值，hour=18 时峰值。
"""
struct DiurnalPattern <: AbstractDemandPattern
    base_rate_mbps::Float64
    peak_ratio::Float64
    phase_offset_h::Float64
    pair_set::Symbol  # :all 或 :hotspot
end

DiurnalPattern(;
    base_rate_mbps::Float64 = 50.0,
    peak_ratio::Float64 = 3.0,
    phase_offset_h::Float64 = 0.0,
    pair_set::Symbol = :all,
) = DiurnalPattern(base_rate_mbps, peak_ratio, phase_offset_h, pair_set)

"""
    diurnal_factor(hour_h, peak_ratio, phase_offset_h) -> Float64

计算昼夜调制因子。hour=6 谷值(1.0)，hour=18 峰值(peak_ratio)。
"""
function diurnal_factor(hour_h::Float64, peak_ratio::Float64, phase_offset_h::Float64)::Float64
    # 正弦波：hour=6 时 sin=-1（谷值），hour=18 时 sin=+1（峰值）
    # (hour-6)/12 在 hour=6 时 =0, hour=18 时 =1；减 0.5 后乘 π 得 -π/2..+π/2
    s = sin(π * ((hour_h - 6.0 + phase_offset_h) / 12.0 - 0.5))
    # 归一化到 [1, peak_ratio]：s=-1 → 1.0（谷），s=+1 → peak_ratio（峰）
    return 1.0 + (peak_ratio - 1.0) * (s + 1.0) / 2.0
end

function generate_demands(
    pattern::DiurnalPattern,
    ground_ids::Vector{Int},
    t0_s::Int,
    duration_s::Int;
    rng::AbstractRNG = Random.default_rng(),
)
    pairs = _all_ground_pairs(ground_ids)
    isempty(pairs) && return TrafficDemand[]

    # 热点选择
    if pattern.pair_set == :hotspot
        n_hot = max(1, round(Int, 0.2 * length(pairs)))
        # 给前 20% 的对 3x 基础速率
        base_rates = [k <= n_hot ? pattern.base_rate_mbps * 3.0 : pattern.base_rate_mbps
                      for k in 1:length(pairs)]
    else
        base_rates = fill(pattern.base_rate_mbps, length(pairs))
    end

    # 把 duration 切成若干时间窗（每窗 1 小时 = 3600 秒），每窗按昼夜因子调制
    window_s = 3600
    demands = TrafficDemand[]
    id = 0
    for (pair_idx, (a, b)) in enumerate(pairs)
        base = base_rates[pair_idx]
        win_start = t0_s
        while win_start < t0_s + duration_s
            win_end = min(win_start + window_s, t0_s + duration_s)
            # 这个窗口的中心时刻（小时）
            center_s = (win_start + win_end) / 2
            # 从 epoch 起的小时数（假设 t0_s 是相对 epoch 的秒）
            hour_h = mod(center_s / 3600.0, 24.0)
            factor = diurnal_factor(hour_h, pattern.peak_ratio, pattern.phase_offset_h)
            rate = base * factor
            rate > 0 || (win_start = win_end; continue)
            id += 1
            push!(demands, TrafficDemand(;
                id = id,
                source_ground_id = a,
                destination_ground_id = b,
                start_elapsed_s = win_start,
                end_elapsed_s = win_end,
                rate_mbps = rate,
            ))
            win_start = win_end
        end
    end
    return demands
end
