# ===== 协调进程（Coordinator）：分布式仿真的心脏 =====
#
# 管理N个卫星worker + 步进时间同步 + 集中路由 + 聚合指标。
#
# 注意：@everywhere 宏只能在模块顶层用，不能在函数体内。
# 因此 worker 初始化用 remotecall 调用 toplevel 定义的函数。

# ── worker 端函数（toplevel 定义，供 remotecall 调用）──

"""在 worker 上初始化 SatelliteServer（remotecall 调用）。"""
function _init_worker_server(sat_id::Int, elements, strategy, T::Int, P::Int)
    server = init_server(sat_id, elements, strategy, T, P)
    # 存到 worker 全局变量
    Core.eval(Main, :(global _SATELLITE_SERVER_ = $server))
    return sat_id
end

"""在 worker 上传播到 t，返回位置（remotecall 调用）。"""
function _propagate_worker(t::Float64, propagator)
    server = Main._SATELLITE_SERVER_
    return propagate_server(server, t; propagator=propagator)
end

export DistributedSimulation, run_distributed_simulation

"""
    DistributedSimulation

分布式仿真状态：协调进程管理 N 个卫星 worker。
"""
Base.@kwdef mutable struct DistributedSimulation
    config::Any
    workers::Vector{Int} = Int[]
    n_satellites::Int = 0
    tspan::Vector{Float64} = Float64[]
    current_step::Int = 0
    positions::Matrix{Float64} = zeros(0, 3)
    available_isls::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[]
    isl_weights::Vector{Float64} = Float64[]
end

"""
    run_distributed_simulation(config; n_workers) -> NamedTuple

启动分布式仿真。每颗卫星一个 worker 进程。
返回 (positions, available_isls, D, n_workers)。
"""
function run_distributed_simulation(config; n_workers::Int=0)
    constellation = config.constellation
    T = constellation.T
    P = constellation.P
    n_w = n_workers > 0 ? min(n_workers, T) : T

    # 1. 启动 worker 进程
    worker_pids = addprocs(n_w)
    try
        # 2. 在 worker 加载依赖（用 remotecall_eval 而非 @everywhere，避免 toplevel 宏问题）
        for w in worker_pids
            remotecall_fetch(w) do
                Core.eval(Main, :(using SatelliteSimCore))
                Core.eval(Main, :(using SatelliteSimNet))
                Core.eval(Main, :(using SatelliteSimDistributed))
            end
        end

        # 3. 生成 Walker 根数
        elems = generate_walker_delta(T=T, P=P, F=constellation.F,
                                       alt_km=constellation.alt_km, inc_deg=constellation.inc_deg)
        strategy = config.topology_strategy
        constraints = config.constraints
        propagator = config.propagator

        # 4. 分配卫星到 worker（round-robin）
        sat_to_worker = Dict{Int,Int}()
        for sat_id in 1:T
            sat_to_worker[sat_id] = worker_pids[((sat_id - 1) % n_w) + 1]
        end

        # 5. 初始化各 worker 的 SatelliteServer
        for sat_id in 1:T
            w = sat_to_worker[sat_id]
            remotecall_fetch(_init_worker_server, w, sat_id, elems[sat_id], strategy, T, P)
        end

        # 6. 传播到最终时刻，收集位置
        final_t = Float64(last(config.tspan))
        positions = zeros(T, 3)
        for sat_id in 1:T
            w = sat_to_worker[sat_id]
            pos = remotecall_fetch(_propagate_worker, w, final_t, propagator)
            positions[sat_id, :] = pos
        end

        # 7. 集中评估 ISL + 路由（协调进程用全局位置，和单进程等价）
        topology = generate_topology(strategy, T, P)
        all_links = vcat(topology.static_links, topology.dynamic_candidates)
        available_isls, isl_weights = _evaluate_all_isls_global(positions, all_links, constraints)
        D = _compute_global_routing(T, available_isls, isl_weights)

        return (positions=positions, available_isls=available_isls,
                D=D, n_workers=n_w, tspan=config.tspan)
    finally
        rmprocs(worker_pids)
    end
end

# 协调进程用全局位置集中评估所有 ISL（MVP：和单进程等价）
function _evaluate_all_isls_global(positions::Matrix{Float64}, links, constraints)
    available = Tuple{Int,Int}[]
    weights = Float64[]
    for (i, j) in links
        pos_a = (positions[i,1], positions[i,2], positions[i,3])
        pos_b = (positions[j,1], positions[j,2], positions[j,3])
        avail, _d, _los, delay, _det = evaluate_isl(pos_a, pos_b; constraints=constraints)
        if avail
            push!(available, (i, j))
            push!(weights, delay)
        end
    end
    return available, weights
end

# 集中算路由（Floyd-Warshall）
function _compute_global_routing(T::Int, available_isls, weights)
    isempty(available_isls) && return fill(Inf, T, T)
    A = fill(Inf, T, T)
    for i in 1:T; A[i,i] = 0.0; end
    for (k, (i,j)) in enumerate(available_isls)
        A[i,j] = A[j,i] = weights[k]
    end
    return all_pairs_shortest_paths(A)
end
