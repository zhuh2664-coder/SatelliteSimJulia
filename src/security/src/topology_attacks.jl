# ===== 拓扑/链路层攻击原语 =====
#
# 迁移自 legacy/layers/07_resource/vulnerability.jl，已修复 3 处 adj→adjacency 笔误
# （原文件 find_critical_links 行157/165、dead_zone_cut_analysis 行192）。
# 按探索点 1 决策，包装进 AbstractAttack 类型树，施加走 attack! 多重分派。
#
# 这些原语作用于「简单通路」的密集邻接矩阵 Matrix{Float64}（Inf=无边），
# 与 build_adjacency / all_pairs_shortest_paths 完全兼容。
# 时序通路（邻接表）的注入见 redteam.jl（P1）。

using Graphs

export FaultScenario, attack!,
       measure_capacity, find_minimum_cut, find_critical_links, dead_zone_cut_analysis

"""
    FaultScenario <: AbstractNetworkAttack

卫星/链路故障场景，作为空间网络层攻击的子类型。

对应 legacy 的 FaultScenario，挂在 AbstractAttack 类型树上，
通过 `attack!(邻接矩阵, scenario)` 施加。

# 字段
- `name::String`：场景名称
- `failed_satellites::Vector{Int}`：失效卫星 ID 列表（整行列置 Inf）
- `failed_links::Vector{Tuple{Int,Int}}`：失效链路端点对列表
- `start_time::Int`：故障起始时间步
- `duration::Int`：持续时长（步数）
"""
struct FaultScenario <: AbstractNetworkAttack
    name::String
    failed_satellites::Vector{Int}
    failed_links::Vector{Tuple{Int,Int}}
    start_time::Int
    duration::Int
end

"""
    attack!(adjacency, atk::FaultScenario) -> Matrix{Float64}

将故障注入邻接矩阵：失效卫星整行列置 Inf，失效链路置 Inf。

# 参数
- `adjacency::Matrix{Float64}`：邻接矩阵（Inf 表示无边），原地修改
- `atk::FaultScenario`：故障场景

# 返回
修改后的邻接矩阵（同一对象，原地修改）。
"""
function attack!(adjacency::Matrix{Float64}, atk::FaultScenario)::Matrix{Float64}
    for sid in atk.failed_satellites
        adjacency[sid, :] .= Inf
        adjacency[:, sid] .= Inf
    end
    for (a, b) in atk.failed_links
        adjacency[a, b] = Inf
        adjacency[b, a] = Inf
    end
    return adjacency
end

"""
    measure_capacity(adjacency, demands, link_cap) -> (total, satisfied, bottleneck_links)

容量测量：逐步走最短路分配负载，找系统饱和点。

# 参数
- `adjacency::Matrix{Float64}`：邻接矩阵
- `demands::Vector{Tuple{Int,Int,Float64}}`：(源, 目的, 速率) 三元组列表
- `link_cap::Float64`：每条链路容量上限

# 返回
`(总需求, 承载量, 瓶颈链路端点对列表)`。
"""
function measure_capacity(adjacency::Matrix{Float64},
                         demands::Vector{Tuple{Int,Int,Float64}},
                         link_cap::Float64)::Tuple{Float64,Float64,Vector{Tuple{Int,Int}}}
    n = size(adjacency, 1)
    loads = Dict{Tuple{Int,Int}, Float64}()
    total = 0.0
    satisfied = 0.0

    for (src, dst, rate) in demands
        total += rate
        adj = copy(adjacency)
        g = SimpleGraph(n)
        for i in 1:n, j in i+1:n
            adj[i,j] < Inf/2 && add_edge!(g, i, j)
        end
        dm = adj ./ 299792.458 .* 1000
        d = dijkstra_shortest_paths(g, src, dm; trackvertices = true)
        d.dists[dst] >= Inf/2 && continue
        cur = dst
        overloaded = false
        while cur != src
            prv = d.parents[cur]
            key = minmax(cur, prv)
            cur_load = get(loads, key, 0.0) + rate
            if cur_load > link_cap
                overloaded = true
                break
            end
            cur = prv
        end
        if !overloaded
            cur = dst
            while cur != src
                prv = d.parents[cur]
                key = minmax(cur, prv)
                loads[key] = get(loads, key, 0.0) + rate
                cur = prv
            end
            satisfied += rate
        end
    end
    bottlenecks = [k for (k, v) in loads if v > link_cap * 0.8]
    return total, satisfied, bottlenecks
end

"""
    find_minimum_cut(adjacency, src, dst) -> (cut_capacity, cut_edges)

最小割集：BFS + 增广路径（Ford-Fulkerson）。

# 参数
- `adjacency::Matrix{Float64}`：邻接矩阵（权重视为容量）
- `src::Int`：源节点
- `dst::Int`：汇节点

# 返回
`(最小割容量, 割边端点对列表)`。用于识别拓扑咽喉，指导定向攻击目标选择。
"""
function find_minimum_cut(adjacency::Matrix{Float64}, src::Int, dst::Int)
    n = size(adjacency, 1)
    cap = copy(adjacency)
    cap[cap .== Inf] .= 0.0
    flow = 0.0
    parent = zeros(Int, n)

    while true
        fill!(parent, 0)
        parent[src] = src
        q = Int[src]
        while !isempty(q) && parent[dst] == 0
            u = popfirst!(q)
            for v in 1:n
                if parent[v] == 0 && cap[u, v] > 1e-10
                    parent[v] = u
                    push!(q, v)
                end
            end
        end
        parent[dst] == 0 && break
        pf = Inf
        v = dst; while v != src; u = parent[v]; pf = min(pf, cap[u, v]); v = u; end
        v = dst; while v != src; u = parent[v]; cap[u,v] -= pf; cap[v,u] += pf; v = u; end
        flow += pf
    end

    visited = falses(n)
    q = Int[src]; visited[src] = true
    while !isempty(q)
        u = popfirst!(q)
        for v in 1:n
            if !visited[v] && cap[u, v] > 1e-10
                visited[v] = true; push!(q, v)
            end
        end
    end

    cut_edges = Tuple{Int,Int}[]
    for u in 1:n, v in 1:n
        if visited[u] && !visited[v] && adjacency[u, v] < Inf/2
            push!(cut_edges, (u, v))
        end
    end
    return flow, cut_edges
end

"""
    find_critical_links(adjacency; n_samples=10) -> Vector{Tuple{Int,Int,Float64}}

关键链路集：逐条移除链路，测量连通性下降程度，按重要性降序排列。

可用于红队「攻击目标选择」——优先攻击关键链路能以最小代价最大化破坏连通性。

# 参数
- `adjacency::Matrix{Float64}`：邻接矩阵
- `n_samples::Int=10`：连通性采样源节点数

# 返回
`(端点A, 端点B, 连通性损失)` 三元组列表，按损失降序。
"""
function find_critical_links(adjacency::Matrix{Float64}; n_samples::Int=10)::Vector{Tuple{Int,Int,Float64}}
    n = size(adjacency, 1)
    baseline_conn = 0.0
    g = SimpleGraph(n)
    for i in 1:n, j in i+1:n
        adjacency[i,j] < Inf/2 && add_edge!(g, i, j)   # ✅ 已修复：原 legacy 笔误 adj→adjacency
    end
    for src in 1:min(n_samples, n)
        d = dijkstra_shortest_paths(g, src, adjacency)
        baseline_conn += sum(d.dists[1:n] .< Inf/2)
    end
    results = Tuple{Int,Int,Float64}[]
    for i in 1:n, j in i+1:n
        adjacency[i,j] >= Inf/2 && continue            # ✅ 已修复：原 legacy 笔误 adj→adjacency
        adj_copy = copy(adjacency)
        adj_copy[i,j] = Inf; adj_copy[j,i] = Inf
        g2 = SimpleGraph(n)
        for a in 1:n, b in a+1:n
            adj_copy[a,b] < Inf/2 && add_edge!(g2, a, b)
        end
        loss = 0.0
        for src in 1:min(n_samples, n)
            d2 = dijkstra_shortest_paths(g2, src, adj_copy)
            loss += baseline_conn / (n_samples * n) - sum(d2.dists[1:n] .< Inf/2) / (n_samples * n)
        end
        push!(results, (i, j, loss))
    end
    sort!(results, by = x -> x[3], rev = true)
    return results
end

"""
    dead_zone_cut_analysis(adjacency) -> Dict

ISL 死区割集分析：识别因几何死区或攻击导致的连通分量分裂。

# 参数
- `adjacency::Matrix{Float64}`：邻接矩阵

# 返回
Dict 含：
- `:n_components`：连通分量数
- `:isolated_nodes`：孤立节点分量列表
- `:reachability`：可达性指标（1.0 = 全连通）
"""
function dead_zone_cut_analysis(adjacency::Matrix{Float64})::Dict
    n = size(adjacency, 1)
    g = SimpleGraph(n)
    for i in 1:n, j in i+1:n
        adjacency[i,j] < Inf/2 && add_edge!(g, i, j)   # ✅ 已修复：原 legacy 笔误 adj→adjacency
    end
    comps = connected_components(g)
    return Dict(
        :n_components => length(comps),
        :isolated_nodes => [c for c in comps if length(c) == 1],
        :reachability => length(comps) == 1 ? 1.0 : 1.0 - sum(length(c)^2 for c in comps) / n^2
    )
end
