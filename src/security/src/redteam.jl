# ===== 红队：攻击施加（双通路 + AttackEffect 中间表示）=====
#
# 基于探索点 4 决策选 B：攻击先编译成统一 AttackEffect，
# 各通路（密集矩阵 / 时序序列）各自 apply_effect! 解释执行。
#
# 攻击类型树复用 types.jl 的 AbstractNetworkAttack。
# FaultScenario（拓扑攻击）已在 topology_attacks.jl 定义，本文件补充网络层攻击。

using SatelliteSimTraffic: TrafficDemand

export AttackEffect, compile_attack, apply_effect!,
       LinkBlackhole, TopologySeverance,
       network_attack_summary

# ── 攻击子类型（网络层）──

"""
    LinkBlackhole <: AbstractNetworkAttack

链路黑洞攻击：劫持卫星，使其收包不转发。
在邻接矩阵/距离矩阵中表现为该卫星整行列置 Inf（从网络中隔离）。
"""
struct LinkBlackhole <: AbstractNetworkAttack
    hijack_sat::Int
    function LinkBlackhole(hijack_sat::Int)
        hijack_sat > 0 || throw(ArgumentError("hijack_sat must be positive"))
        new(hijack_sat)
    end
end

"""
    TopologySeverance <: AbstractNetworkAttack

拓扑切断攻击：切断指定的 ISL 边集合，分裂网络连通性。
可用于复现关键链路攻击（配合 find_critical_links 选择目标）。
"""
struct TopologySeverance <: AbstractNetworkAttack
    cut_edges::Vector{Tuple{Int,Int}}
    function TopologySeverance(cut_edges::Vector{Tuple{Int,Int}})
        !isempty(cut_edges) || throw(ArgumentError("cut_edges must not be empty"))
        all(e -> e[1] > 0 && e[2] > 0, cut_edges) ||
            throw(ArgumentError("edge endpoints must be positive"))
        new(copy(cut_edges))
    end
end

# ── AttackEffect 中间表示 ──

"""
    AttackEffect

攻击的统一中间表示，描述对网络状态的操作。
由 compile_attack(攻击实例) 生成，由 apply_effect!(状态, effect) 解释执行。

# 字段
- `isolate_sats::Vector{Int}`：需隔离的卫星（邻接矩阵整行列置 Inf）
- `sever_edges::Vector{Tuple{Int,Int}}`：需切断的链路端点对
"""
struct AttackEffect
    isolate_sats::Vector{Int}
    sever_edges::Vector{Tuple{Int,Int}}
end
AttackEffect(; isolate_sats::Vector{Int} = Int[],
               sever_edges::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[]) =
    AttackEffect(copy(isolate_sats), copy(sever_edges))

# ── 编译：攻击 → AttackEffect ──

"""LinkBlackhole 编译为隔离单颗卫星。"""
compile_attack(atk::LinkBlackhole) = AttackEffect(isolate_sats = [atk.hijack_sat])

"""TopologySeverance 编译为切断指定边。"""
compile_attack(atk::TopologySeverance) = AttackEffect(sever_edges = atk.cut_edges)

"""FaultScenario 编译为隔离卫星 + 切断链路（复用现有拓扑攻击）。"""
compile_attack(atk::FaultScenario) =
    AttackEffect(isolate_sats = atk.failed_satellites, sever_edges = atk.failed_links)

# ── 解释：AttackEffect → 施加到各通路 ──

"""
    apply_effect!(adj, eff) -> Matrix{Float64}

施加效果到密集邻接矩阵（简单通路，run_experiment 用）。
"""
function apply_effect!(adj::Matrix{Float64}, eff::AttackEffect)::Matrix{Float64}
    for sid in eff.isolate_sats
        adj[sid, :] .= Inf
        adj[:, sid] .= Inf
    end
    for (a, b) in eff.sever_edges
        adj[a, b] = Inf
        adj[b, a] = Inf
    end
    return adj
end

"""
    apply_effect!(D_series, eff, t) -> Vector{Matrix{Float64}}

施加效果到时序距离矩阵序列的指定时间步（时序通路，assess_routing_temporal 用）。
"""
function apply_effect!(D_series::Vector{Matrix{Float64}}, eff::AttackEffect, t::Int)
    apply_effect!(D_series[t], eff)
    return D_series
end

"""
    apply_effect!(D_series, eff) -> Vector{Matrix{Float64}}

施加效果到时序距离矩阵序列的全部时间步。
"""
function apply_effect!(D_series::Vector{Matrix{Float64}}, eff::AttackEffect)
    for t in eachindex(D_series)
        apply_effect!(D_series[t], eff)
    end
    return D_series
end

# ── 统一 attack! 入口（先 compile 再 apply）──

"""
    attack!(state, atk) -> state

统一攻击入口：先编译攻击为 AttackEffect，再施加到状态。
state 可为 Matrix{Float64}（单帧）或 Vector{Matrix{Float64}}（时序）。
"""
attack!(state, atk::AbstractAttack) = apply_effect!(state, compile_attack(atk))
attack!(state, atk::AbstractAttack, t::Int) = apply_effect!(state, compile_attack(atk), t)

# ── 攻击摘要（供 Verdict 记录）──

"""
    network_attack_summary(atk) -> String

人类可读的攻击摘要，供 Verdict 和日志记录。
"""
network_attack_summary(atk::LinkBlackhole) = "LinkBlackhole(隔离卫星 $(atk.hijack_sat))"
network_attack_summary(atk::TopologySeverance) =
    "TopologySeverance(切断 $(length(atk.cut_edges)) 条链路)"
network_attack_summary(atk::FaultScenario) =
    "FaultScenario($(atk.name): 隔离 $(length(atk.failed_satellites)) 星, 切断 $(length(atk.failed_links)) 链路)"
