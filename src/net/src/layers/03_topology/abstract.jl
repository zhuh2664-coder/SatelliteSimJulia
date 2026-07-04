# ===== ISL 拓扑 — 抽象类型与辅助函数 =====
# 利用 Julia 多分派，新增拓扑策略只需定义子类型 + 实现 generate_topology()。
#
# 接口契约（3 方法）:
#   必实现: generate_topology(::Strategy, T, P) -> TopologyOutput
#   可选:   isl_neighbors(::Strategy, sat_id, T, P) -> Vector{Int}
#   可选:   num_isl(::Strategy, T, P) -> Int
#
# 新增策略示例:
#   struct MyStrategy <: AbstractTopologyStrategy end
#   function generate_topology(::MyStrategy, T, P) ... end
#   # isl_neighbors 和 num_isl 有默认实现，不覆写即可

import Random

export AbstractTopologyStrategy, TopologyOutput,
       generate_topology,
       IntraPlaneConfig, InterPlaneConfig,
       generate_intra_plane_links, generate_inter_plane_links,
       generate_isl_candidates, isl_neighbors, num_isl

# -- 配置类型 --

Base.@kwdef struct IntraPlaneConfig
    span::Int = 1
    wrap::Bool = true
end

Base.@kwdef struct InterPlaneConfig
    span::Int = 1
    slot_offset::Int = 0
    wrap::Bool = true
end

# -- 连接算法 --

function generate_intra_plane_links(n_sats::Int, config::IntraPlaneConfig=IntraPlaneConfig())
    n_sats >= 2 || return Tuple{Int,Int}[]
    links = Tuple{Int,Int}[]
    for i in 1:n_sats
        for delta in 1:config.span
            j = i + delta
            if config.wrap
                j = mod1(j, n_sats)
            else
                j > n_sats && break
            end
            i != j && push!(links, minmax(i, j))
        end
    end
    return unique(links)
end

function generate_inter_plane_links(sats_per_plane::Int, n_planes::Int, config::InterPlaneConfig=InterPlaneConfig())
    n_planes >= 2 || return Tuple{Int,Int}[]
    links = Tuple{Int,Int}[]
    seen = Set{Tuple{Int,Int}}()
    for p in 1:n_planes, delta in 1:config.span
        q = p + delta
        if config.wrap
            q = mod1(q, n_planes)
        else
            q > n_planes && continue
        end
        p == q && continue
        pair = minmax(p, q)
        pair in seen && continue
        push!(seen, pair)
        for s in 1:sats_per_plane
            t = mod1(s + config.slot_offset, sats_per_plane)
            i = (p - 1) * sats_per_plane + s
            j = (q - 1) * sats_per_plane + t
            push!(links, minmax(i, j))
        end
    end
    return unique(links)
end

function generate_isl_candidates(T::Int, P::Int;
    intra::IntraPlaneConfig=IntraPlaneConfig(),
    inter::InterPlaneConfig=InterPlaneConfig())
    S = div(T, P)
    intra_links = generate_intra_plane_links(S, intra)
    inter_links = generate_inter_plane_links(S, P, inter)
    all_links = Tuple{Int,Int}[]
    for p in 1:P
        offset = (p - 1) * S
        for (i, j) in intra_links
            push!(all_links, (i + offset, j + offset))
        end
    end
    append!(all_links, inter_links)
    return unique(all_links)
end

# -- 抽象拓扑策略 --

abstract type AbstractTopologyStrategy end

struct TopologyOutput
    static_links::Vector{Tuple{Int,Int}}
    dynamic_candidates::Vector{Tuple{Int,Int}}
    description::String
end

function generate_topology(::AbstractTopologyStrategy, T::Int, P::Int)::TopologyOutput
    error("未实现的 generate_topology 方法")
end

# -- 可选接口（有默认实现） --

"""
    isl_neighbors(strategy, sat_id, T, P) -> Vector{Int}

返回卫星 `sat_id` 的所有 ISL 邻居（静态链路）。
默认通过 `generate_topology` 构建邻接表查询。
策略可覆写此方法以提供 O(1) 查找（如 GridPlus）。
"""
function isl_neighbors(strategy::AbstractTopologyStrategy, sat_id::Int, T::Int, P::Int)::Vector{Int}
    topo = generate_topology(strategy, T, P)
    neighbors = Int[]
    for (i, j) in topo.static_links
        if i == sat_id; push!(neighbors, j)
        elseif j == sat_id; push!(neighbors, i)
        end
    end
    return sort(neighbors)
end

"""
    num_isl(strategy, T, P) -> Int

返回静态 ISL 总数。默认通过 `generate_topology` 计算。
策略可覆写为解析公式（如 Grid+ 的 `T * 2`）。
"""
function num_isl(strategy::AbstractTopologyStrategy, T::Int, P::Int)::Int
    topo = generate_topology(strategy, T, P)
    return length(topo.static_links)
end
