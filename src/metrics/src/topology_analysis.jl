# ===== 拓扑图论分析指标 =====
# 输入统一为 Graphs.SimpleGraph（无向图）。
# 覆盖：度分布、聚类系数、中心性（介数/接近/Pagerank）、鲁棒性（代数连通度/删节点）。
using Graphs
using LinearAlgebra: eigvals, I, Diagonal, Symmetric
using Statistics: mean
using Random: shuffle!, default_rng

export degree_histogram, clustering_coefficient, betweenness_centrality,
       closeness_centrality, pagerank, algebraic_connectivity, robustness_curve,
       link_churn, topology_churn_rate

# ----- 度分布 -----

"""
    degree_histogram(g::SimpleGraph) -> Vector{Int}

返回度数直方图：下标 = 度数，值 = 该度数的节点数。

# 参数
- `g::SimpleGraph`: 无向图

# 返回
`Vector{Int}` — 长度为最大度数的向量，第 k 个元素为度数等于 k 的节点数。
"""
function degree_histogram(g::SimpleGraph)::Vector{Int}
    deg = degree(g)
    isempty(deg) && return Int[]
    maxd = maximum(deg)
    maxd == 0 && return Int[0]  # 全孤立节点：仅含度数 0
    h = zeros(Int, maxd)
    for d in deg
        h[d] += 1
    end
    return h
end

# ----- 聚类系数 -----

"""
    clustering_coefficient(g::SimpleGraph) -> Float64

计算平均聚类系数（所有节点局部聚类系数的均值）。

# 参数
- `g::SimpleGraph`: 无向图

# 返回
`Float64` — 平均聚类系数 (0-1)，完全图 = 1.0。
"""
function clustering_coefficient(g::SimpleGraph)::Float64
    n = nv(g)
    n == 0 && return 0.0
    return mean(local_clustering_coefficient(g))
end

# ----- 介数中心性（Brandes 算法）-----

"""
    betweenness_centrality(g::SimpleGraph) -> Vector{Float64}

介数中心性（自实现 Brandes 算法）。

每个节点的介数 = 经过该节点的最短路径比例，已归一化（除以 (n-1)(n-2)/2）。
中心节点最短路径负载最大。

# 参数
- `g::SimpleGraph`: 无向图

# 返回
`Vector{Float64}` — 每个节点的归一化介数值。
"""
function betweenness_centrality(g::SimpleGraph)::Vector{Float64}
    n = nv(g)
    CB = zeros(Float64, n)  # 介数累积值

    n < 3 && return CB

    for s in 1:n
        # --- 单源最短路 (BFS, 无权图) ---
        S = Int[]                       # 已处理节点栈（按发现逆序）
        P = [Int[] for _ in 1:n]        # 前驱列表
        sigma = zeros(Float64, n)       # 最短路条数
        sigma[s] = 1.0
        dist = fill(-1, n)              # 距离，-1 = 未访问
        dist[s] = 0
        Q = Int[s]                      # BFS 队列
        head = 1
        while head <= length(Q)
            v = Q[head]
            head += 1
            push!(S, v)
            for w in neighbors(g, v)
                if dist[w] < 0          # 首次发现 w
                    dist[w] = dist[v] + 1
                    push!(Q, w)
                end
                if dist[w] == dist[v] + 1  # v 在 w 的最短路上
                    sigma[w] += sigma[v]
                    push!(P[w], v)
                end
            end
        end

        # --- 反向累积依赖 ---
        delta = zeros(Float64, n)
        while !isempty(S)
            w = pop!(S)
            for v in P[w]
                delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w])
            end
            w != s && (CB[w] += delta[w])
        end
    end

    # 无向图：双向遍历导致每对路径计两次，先除以 2 得到无向介数；
    # 再除以 (n-1)(n-2)/2 归一化（中心节点最大值 = 1）。
    return (CB ./ 2.0) .* (2.0 / ((n - 1) * (n - 2)))
end

# ----- 接近中心性 -----

"""
    closeness_centrality(g::SimpleGraph) -> Vector{Float64}

接近中心性 = (n-1) / Σ d(i,j)。

节点到其余所有节点的最短距离之和越小，中心性越高。
非连通分量中的不可达节点（距离 = typemax）按 Graphs.jl 惯例计入总和。

# 参数
- `g::SimpleGraph`: 无向图

# 返回
`Vector{Float64}` — 每个节点的接近中心性。
"""
function closeness_centrality(g::SimpleGraph)::Vector{Float64}
    n = nv(g)
    cc = zeros(Float64, n)
    n <= 1 && return cc
    for i in 1:n
        d = gdistances(g, i)
        total = sum(d)
        if total > 0
            cc[i] = (n - 1) / total
        end
    end
    return cc
end

# ----- Pagerank 幂迭代 -----

"""
    pagerank(g::SimpleGraph; damping, n_iter, tol) -> Vector{Float64}

Pagerank 幂迭代。

迭代式：PR = damping * M * PR + (1-damping)/n
其中 M 是按列归一化的邻接矩阵（M[i,j] = 从 j 转移到 i 的概率）。
悬挂节点（无出边）的权重均分给所有节点以保证随机游走平稳。

# 参数
- `g::SimpleGraph`: 无向图
- `damping::Float64=0.85`: 阻尼系数
- `n_iter::Int=100`: 最大迭代次数
- `tol::Float64=1e-6`: ‖PR_new - PR_old‖₁ 收敛阈值

# 返回
`Vector{Float64}` — 每个节点的 Pagerank 值（和为 1）。
"""
function pagerank(g::SimpleGraph;
                  damping::Float64=0.85,
                  n_iter::Int=100,
                  tol::Float64=1e-6)::Vector{Float64}
    n = nv(g)
    n == 0 && return Float64[]
    PR = fill(1.0 / n, n)

    # 邻接矩阵转置后列归一化：Aᵀ[:,j] 即节点 j 的出边（无向图 = 邻接列）
    A = Matrix(adjacency_matrix(g))
    outdeg = vec(sum(A, dims = 1))  # 每列和 = 节点出度
    M = similar(A, Float64)
    for j in 1:n
        if outdeg[j] > 0
            for i in 1:n
                M[i, j] = A[i, j] / outdeg[j]
            end
        else
            # 悬挂节点：均匀转移
            for i in 1:n
                M[i, j] = 1.0 / n
            end
        end
    end

    base = (1.0 - damping) / n
    for _ in 1:n_iter
        PR_new = damping .* (M * PR) .+ base
        if sum(abs.(PR_new .- PR)) < tol
            PR = PR_new
            break
        end
        PR = PR_new
    end
    return PR
end

# ----- 代数连通度（Fiedler 值）-----

"""
    algebraic_connectivity(g::SimpleGraph) -> Float64

代数连通度（Fiedler 值）= 拉普拉斯矩阵 L = D - A 的第二小特征值。

连通图 Fiedler > 0，值越大越鲁棒；非连通图 Fiedler = 0。

# 参数
- `g::SimpleGraph`: 无向图

# 返回
`Float64` — Fiedler 值（第二小拉普拉斯特征值）。
"""
function algebraic_connectivity(g::SimpleGraph)::Float64
    n = nv(g)
    n <= 1 && return 0.0
    L = Diagonal(degree(g)) - adjacency_matrix(g)
    λ = eigvals(Symmetric(Matrix(L)))
    # λ 已升序；第二小特征值
    return max(λ[2], 0.0)
end

# ----- 鲁棒性曲线（删节点）-----

"""
    robustness_curve(g::SimpleGraph; attack, n_steps, rng) -> Vector{Float64}

删节点后最大连通簇占比曲线。

每步删除 `n÷n_steps` 个节点，记录剩余图中最大连通簇节点数占原图节点数的比例。
- `:random` 攻击：随机选择节点删除
- `:targeted` 攻击：按度数从大到小依次删除（模拟蓄意攻击）

# 参数
- `g::SimpleGraph`: 无向图
- `attack::Symbol=:random`: 攻击策略 (:random 或 :targeted)
- `n_steps::Int=10`: 删除步数
- `rng`: 随机数生成器（仅 :random 模式使用）

# 返回
`Vector{Float64}` — 长度 `n_steps+1` 的曲线，首元素为 1.0（原图完整）。
"""
function robustness_curve(g::SimpleGraph;
                          attack::Symbol=:random,
                          n_steps::Int=10,
                          rng=default_rng())::Vector{Float64}
    n = nv(g)
    n == 0 && return Float64[]

    # 确定删除顺序（基于原图节点编号）
    if attack === :targeted
        order = sortperm(degree(g); rev=true)  # 度数从大到小
    else
        order = collect(1:n)
        shuffle!(rng, order)
    end

    step_size = max(1, n ÷ n_steps)
    active = trues(n)  # 活动节点掩码（原图编号）

    curve = Float64[1.0]  # 初始：全连通

    cursor = 0
    for step in 1:n_steps
        # 删除本步节点（按 order 顺序，跳过已删除）
        to_remove = step_size
        while to_remove > 0 && cursor < n
            cursor += 1
            v = order[cursor]
            if active[v]
                active[v] = false
                to_remove -= 1
            end
        end
        # 用剩余原图编号节点诱导子图，计算最大连通簇占比
        surviving = findall(active)
        if isempty(surviving)
            push!(curve, 0.0)
        else
            sub, _ = induced_subgraph(g, surviving)
            comps = connected_components(sub)
            largest = isempty(comps) ? 0 : maximum(length.(comps))
            push!(curve, largest / n)
        end
    end
    return curve
end

# ----- 时变 churn 度量 -----

"""
    link_churn(edge_series::AbstractVector{<:AbstractVector{Tuple{Int,Int}}}) -> Vector{Int}

计算相邻时间帧之间边集的对称差大小（链路增删总量）。

# 参数
- `edge_series`: 每个时间帧的边列表序列，`edge_series[t]` 为第 t 帧的边集合

# 返回
`Vector{Int}` — 长度为 `length(edge_series) - 1`，第 t 个元素为第 t 帧与第 t+1 帧之间
新增与消失的边数之和（churn）。全静态序列返回全 0。
"""
function link_churn(edge_series::AbstractVector{<:AbstractVector{Tuple{Int,Int}}})::Vector{Int}
    length(edge_series) >= 2 || return Int[]
    churn = Vector{Int}(undef, length(edge_series) - 1)
    prev = Set{Tuple{Int,Int}}(edge_series[1])
    for t in 1:length(churn)
        cur = Set{Tuple{Int,Int}}(edge_series[t + 1])
        # 对称差大小 = (prev - cur) ∪ (cur - prev) 的元素数
        churn[t] = length(symdiff(prev, cur))
        prev = cur
    end
    return churn
end

"""
    topology_churn_rate(edge_series; normalize=true) -> Float64

时变拓扑的平均链路 churn 率。

# 参数
- `edge_series`: 每个时间帧的边列表序列
- `normalize::Bool=true`: 是否按平均边数归一化到 [0,1] 区间

# 返回
`Float64` — 平均每帧 churn 数（normalize=true 时除以平均边数）。
全静态序列返回 0.0；单帧序列返回 0.0。
"""
function topology_churn_rate(edge_series::AbstractVector{<:AbstractVector{Tuple{Int,Int}}};
                             normalize::Bool=true)::Float64
    churn = link_churn(edge_series)
    isempty(churn) && return 0.0
    avg_churn = mean(churn)
    normalize || return avg_churn
    avg_edges = mean(length.(edge_series))
    avg_edges == 0 && return 0.0
    return avg_churn / avg_edges
end
