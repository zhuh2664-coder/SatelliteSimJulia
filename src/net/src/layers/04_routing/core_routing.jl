#=
# 路由模块 (routing.jl)

## 模块说明
本模块是 SatelliteSimJulia 卫星仿真系统网络层的核心组件，负责计算卫星网络中的通信路径。

## 位置与依赖关系
- **所属层级**: `core/network_layer/` - 网络层核心模块
- **上游依赖**:
  - `ISLPhysicalLinkSeries`: 卫星间链路（ISL）的物理状态时间序列
  - `AccessDecisionTable`: 地面站与卫星之间的接入决策表
  - `SimulationTimeGrid`: 仿真时间网格定义

## 核心功能
1. **路径请求表示** - 定义源地面站和目标地面站的通信请求
2. **单时刻路径计算** - 使用 Dijkstra 算法计算最短延迟的卫星间路径
3. **时间序列路径计算** - 计算整个仿真时间窗口内的路径变化
4. **不可达原因分析** - 识别路径不可达的具体原因

## 主要算法
本模块实现了基于 Dijkstra 算法的最短路径查找，用于在动态变化的 ISL 网络中
找到从源卫星到目标卫星的最低延迟路径。

## Dijkstra 算法详解

### 算法原理
Dijkstra 算法用于在带权有向图中求解单源最短路径问题。在卫星网络中：
- 节点 = 卫星
- 边 = 可用的 ISL 链路
- 边权 = 链路的光传播时延（秒）

### 时间复杂度
本实现使用线性扫描选择最小距离节点，时间复杂度为 O(V²)，
其中 V 是卫星数量。对于中等规模星座（数百颗卫星），该复杂度是可接受的。
若需优化，可使用优先队列（二叉堆）降至 O((V+E) log V)。

### 边权选择：传播时延
边权使用光传播时延而非欧氏距离，原因：
1. 时延是通信性能的直接度量
2. 时延 = 距离 / 光速，与时延呈线性关系
3. 路由目标是最小化端到端延迟，而非最小化物理距离

### 路径重构
Dijkstra 算法通过前驱映射（predecessor map）记录路径：
- previous_satellite[node] = 到达 node 的前一个卫星
- previous_link[node] = 到达 node 使用的链路 ID
重构时从目标节点反向追踪到源节点，然后反转得到正向路径。
=#

export RouteRequest, RoutePath, RouteSeries,
       route_at, reachable_routes, route_unreachable,
       push_isl_edge!, available_isl_adjacency,
       shortest_isl_path, route_path_at, route_series

"""
    RouteRequest

路由请求结构体，表示从一个地面站到另一个地面站的通信路径请求。

## 字段说明
- `source_ground_id::Int`: 源地面站 ID，必须为正整数
- `destination_ground_id::Int`: 目标地面站 ID，必须为正整数且不等于源地面站

## 构造函数验证
- 源地面站 ID 必须为正整数
- 目标地面站 ID 必须为正整数
- 源和目标地面站 ID 不能相同
"""
struct RouteRequest
    source_ground_id::Int
    destination_ground_id::Int

    function RouteRequest(source_ground_id::Int, destination_ground_id::Int)
        source_ground_id > 0 || throw(ArgumentError("source_ground_id must be positive"))
        destination_ground_id > 0 || throw(ArgumentError("destination_ground_id must be positive"))
        source_ground_id != destination_ground_id ||
            throw(ArgumentError("source and destination ground ids must differ"))
        return new(source_ground_id, destination_ground_id)
    end
end

"""
    RoutePath

路由路径结构体，表示在特定时刻某个路由请求的实际路径结果。

## 字段说明
- `request::RouteRequest`: 对应的路由请求
- `time_index::Int`: 时间网格中的索引位置
- `elapsed_s::Int`: 从仿真开始经过的秒数
- `source_access_satellite_id::Union{Nothing,Int}`: 源地面站接入的卫星 ID，若不可达则为 `nothing`
- `destination_access_satellite_id::Union{Nothing,Int}`: 目标地面站接入的卫星 ID，若不可达则为 `nothing`
- `satellite_path::Vector{Int}`: 卫星路径序列，包含从源卫星到目标卫星的所有卫星 ID
- `isl_link_ids::Vector{Int}`: 沿路径使用的 ISL 链路 ID 序列
- `isl_delay_s::Float64`: ISL 部分的总传播延迟（秒）
- `source_gsl_delay_s::Union{Nothing,Float64}`: 源 GSL（地面-卫星链路）延迟
- `destination_gsl_delay_s::Union{Nothing,Float64}`: 目标 GSL 延迟
- `total_delay_s::Union{Nothing,Float64}`: 整个路径的总延迟
- `reachable::Bool`: 是否可达
- `reason::Symbol`: 路径状态的原因说明（如 `:shortest_delay`, `:source_no_access` 等）

## 构造函数验证
- 时间索引必须为正数
- 经历时间必须非负
- 当提供卫星 ID 或延迟值时，必须满足相应的约束
- 如果路径可达，必须有完整的卫星路径和总延迟
- 卫星路径必须以源接入卫星开始，以目标接入卫星结束
"""
struct RoutePath
    request::RouteRequest
    time_index::Int
    elapsed_s::Int
    source_access_satellite_id::Union{Nothing,Int}
    destination_access_satellite_id::Union{Nothing,Int}
    satellite_path::Vector{Int}
    isl_link_ids::Vector{Int}
    isl_delay_s::Float64
    source_gsl_delay_s::Union{Nothing,Float64}
    destination_gsl_delay_s::Union{Nothing,Float64}
    total_delay_s::Union{Nothing,Float64}
    reachable::Bool
    reason::Symbol

    function RoutePath(;
        request::RouteRequest,
        time_index::Int,
        elapsed_s::Int,
        source_access_satellite_id::Union{Nothing,Int},
        destination_access_satellite_id::Union{Nothing,Int},
        satellite_path::Vector{Int} = Int[],
        isl_link_ids::Vector{Int} = Int[],
        isl_delay_s::Real = 0,
        source_gsl_delay_s::Union{Nothing,Real} = nothing,
        destination_gsl_delay_s::Union{Nothing,Real} = nothing,
        total_delay_s::Union{Nothing,Real} = nothing,
        reachable::Bool,
        reason::Symbol,
    )
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        source_access_satellite_id === nothing || source_access_satellite_id > 0 ||
            throw(ArgumentError("source_access_satellite_id must be positive when provided"))
        destination_access_satellite_id === nothing || destination_access_satellite_id > 0 ||
            throw(ArgumentError("destination_access_satellite_id must be positive when provided"))
        all(id -> id > 0, satellite_path) ||
            throw(ArgumentError("satellite_path ids must be positive"))
        all(id -> id > 0, isl_link_ids) ||
            throw(ArgumentError("isl_link_ids must be positive"))
        isl_delay_s >= 0 || throw(ArgumentError("isl_delay_s must be non-negative"))
        source_gsl_delay_s === nothing || source_gsl_delay_s >= 0 ||
            throw(ArgumentError("source_gsl_delay_s must be non-negative when provided"))
        destination_gsl_delay_s === nothing || destination_gsl_delay_s >= 0 ||
            throw(ArgumentError("destination_gsl_delay_s must be non-negative when provided"))
        total_delay_s === nothing || total_delay_s >= 0 ||
            throw(ArgumentError("total_delay_s must be non-negative when provided"))
        if reachable
            !isempty(satellite_path) || throw(ArgumentError("reachable routes require a satellite_path"))
            source_access_satellite_id == first(satellite_path) ||
                throw(ArgumentError("satellite_path must start at the source access satellite"))
            destination_access_satellite_id == last(satellite_path) ||
                throw(ArgumentError("satellite_path must end at the destination access satellite"))
            total_delay_s !== nothing || throw(ArgumentError("reachable routes require total_delay_s"))
        end
        return new(
            request,
            time_index,
            elapsed_s,
            source_access_satellite_id,
            destination_access_satellite_id,
            satellite_path,
            isl_link_ids,
            Float64(isl_delay_s),
            source_gsl_delay_s === nothing ? nothing : Float64(source_gsl_delay_s),
            destination_gsl_delay_s === nothing ? nothing : Float64(destination_gsl_delay_s),
            total_delay_s === nothing ? nothing : Float64(total_delay_s),
            reachable,
            reason,
        )
    end
end

"""
    RouteSeries

路由时间序列结构体，包含一个路由请求在整个仿真时间窗口内的所有路径结果。

## 字段说明
- `request::RouteRequest`: 对应的路由请求，在整个时间序列中保持不变
- `time_grid::SimulationTimeGrid`: 仿真时间网格，定义时间离散化规则
- `paths::Vector{RoutePath}`: 每个时间片对应的路径结果，长度必须与时间网格的片数匹配

## 构造函数验证
- 路径数量必须与时间网格的时间片数一致
- 所有路径必须共享同一个路由请求
- 每个路径的时间索引必须与其在序列中的位置一致
"""
struct RouteSeries
    request::RouteRequest
    time_grid::SimulationTimeGrid
    paths::Vector{RoutePath}

    function RouteSeries(
        request::RouteRequest,
        time_grid::SimulationTimeGrid,
        paths::Vector{RoutePath},
    )
        length(paths) == time_count(time_grid) ||
            throw(ArgumentError("paths must match the time grid length"))
        for (time_index, path) in pairs(paths)
            path.request == request || throw(ArgumentError("all route paths must share request"))
            path.time_index == time_index ||
                throw(ArgumentError("route path time_index must match time slice order"))
        end
        return new(request, time_grid, paths)
    end
end

"""
    route_at(series::RouteSeries, time_index::Int) -> RoutePath

获取路由时间序列中指定时间索引的路径结果。

## 参数说明
- `series::RouteSeries`: 路由时间序列
- `time_index::Int`: 时间索引（1-based）

## 返回值
指定时间索引对应的 `RoutePath` 对象
"""
route_at(series::RouteSeries, time_index::Int)::RoutePath = series.paths[time_index]

"""
    reachable_routes(series::RouteSeries) -> Vector{RoutePath}

获取路由时间序列中所有可达的路径。

## 参数说明
- `series::RouteSeries`: 路由时间序列

## 返回值
所有 `reachable` 字段为 `true` 的 `RoutePath` 对象组成的向量
"""
reachable_routes(series::RouteSeries)::Vector{RoutePath} =
    [path for path in series.paths if path.reachable]

"""
    route_unreachable(request, time_index, elapsed_s, source_access_satellite_id,
                     destination_access_satellite_id, reason) -> RoutePath

创建一个表示不可达路由的 RoutePath 对象。

这是路径计算失败时返回的标准格式，统一处理各种不可达情况。

## 参数说明
- `request::RouteRequest`: 原始路由请求
- `time_index::Int`: 时间索引
- `elapsed_s::Int`: 从仿真开始经过的秒数
- `source_access_satellite_id::Union{Nothing,Int}`: 源接入卫星 ID（可能为 nothing）
- `destination_access_satellite_id::Union{Nothing,Int}`: 目标接入卫星 ID（可能为 nothing）
- `reason::Symbol`: 不可达的原因符号，常用值包括：
  - `:source_no_access` - 源地面站无卫星可接入
  - `:destination_no_access` - 目标地面站无卫星可接入
  - `:isl_unreachable` - 卫星间网络不可达

## 返回值
一个 `reachable` 字段为 `false` 的 `RoutePath` 对象
"""
function route_unreachable(
    request::RouteRequest,
    time_index::Int,
    elapsed_s::Int,
    source_access_satellite_id::Union{Nothing,Int},
    destination_access_satellite_id::Union{Nothing,Int},
    reason::Symbol,
)::RoutePath
    return RoutePath(
        request = request,
        time_index = time_index,
        elapsed_s = elapsed_s,
        source_access_satellite_id = source_access_satellite_id,
        destination_access_satellite_id = destination_access_satellite_id,
        reachable = false,
        reason = reason,
    )
end

"""
    push_isl_edge!(adjacency, a, b, link_id, delay_s) -> Nothing

向邻接表中添加一条 ISL（卫星间链路）的无向边。

## 参数说明
- `adjacency::Dict{Int,Vector{Tuple{Int,Int,Float64}}}`: 邻接表字典
  - 键：卫星 ID
  - 值：相邻节点列表，每个元素为 (邻居卫星 ID, 链路 ID, 延迟) 的元组
- `a::Int`: 端点 A 的卫星 ID
- `b::Int`: 端点 B 的卫星 ID
- `link_id::Int`: 链路的唯一标识符
- `delay_s::Real`: 链路的传播延迟（秒）

## 实现说明
- 将延迟转换为 Float64 类型
- 同时在两个方向的邻接表中添加边（无向图）
- 使用 `get!` 自动初始化不存在的键
"""
# [算法说明]
# 邻接表构建 - 添加无向边
# ISL 链路是双向的（无向图），因此需要在两个方向都添加边。
# 邻接表结构：satellite_id → [(neighbor_id, link_id, delay_s), ...]
# 使用 get! 自动初始化不存在的键，避免手动检查
function push_isl_edge!(
    adjacency::Dict{Int,Vector{Tuple{Int,Int,Float64}}},
    a::Int,
    b::Int,
    link_id::Int,
    delay_s::Real,
)::Nothing
    delay = Float64(delay_s)
    push!(get!(adjacency, a, Tuple{Int,Int,Float64}[]), (b, link_id, delay))
    push!(get!(adjacency, b, Tuple{Int,Int,Float64}[]), (a, link_id, delay))
    return nothing
end

"""
    available_isl_adjacency(series, time_index) -> Dict{Int,Vector{Tuple{Int,Int,Float64}}}

构建指定时刻可用的 ISL 网络邻接表。

## 参数说明
- `series::ISLPhysicalLinkSeries`: ISL 物理链路的时间序列
- `time_index::Int`: 时间索引

## 返回值
邻接表字典，表示该时刻卫星网络的连接状态：
- 键：卫星 ID
- 值：该卫星所有可用链路的列表，每个元素为 (邻居 ID, 链路 ID, 延迟)

## 实现说明
- 遍历该时刻所有可用的链路采样
- 仅包含状态为 "available" 的链路
- 使用 `push_isl_edge!` 添加双向连接
"""
function available_isl_adjacency(
    series::ISLPhysicalLinkSeries,
    time_index::Int,
)::Dict{Int,Vector{Tuple{Int,Int,Float64}}}
    adjacency = Dict{Int,Vector{Tuple{Int,Int,Float64}}}()
    for sample in available_link_samples(series, time_index)
        push_isl_edge!(
            adjacency,
            sample.endpoint_a_id,
            sample.endpoint_b_id,
            sample.link_id,
            sample.propagation_delay_s,
        )
    end
    return adjacency
end

"""
    shortest_isl_path(series, time_index, source_satellite_id, destination_satellite_id)
        -> Union{Nothing,Tuple{Vector{Int},Vector{Int},Float64}}

使用 Dijkstra 算法查找两个卫星之间的最短延迟路径。

## 参数说明
- `series::ISLPhysicalLinkSeries`: ISL 物理链路的时间序列
- `time_index::Int`: 时间索引
- `source_satellite_id::Int`: 源卫星 ID
- `destination_satellite_id::Int`: 目标卫星 ID

## 返回值
- 若路径存在：返回元组 `(satellite_path, link_path, total_delay)`
  - `satellite_path::Vector{Int}`: 卫星 ID 序列（包含起点和终点）
  - `link_path::Vector{Int}`: 链路 ID 序列
  - `total_delay::Float64`: 总传播延迟（秒）
- 若路径不存在：返回 `nothing`

## Dijkstra 算法实现说明

### 数据结构
- `adjacency`: 邻接表，表示网络拓扑
- `distances`: 字典，记录从源点到每个已知节点的当前最短距离
- `previous_satellite`: 字典，记录路径上每个节点的前驱节点
- `previous_link`: 字典，记录路径上每个节点的前驱链路
- `visited`: 集合，记录已确定最短路径的节点

### 算法流程
1. **初始化**:
   - 构建可用 ISL 邻接表
   - 设置源节点距离为 0，其他为无穷大

2. **主循环**（迭代直到目标被访问或无法继续）:
   - 选择未访问节点中距离最小的节点作为当前节点
   - 若无法选择（所有可达节点都已访问），路径不存在
   - 若当前节点即为目标节点，完成搜索
   - 标记当前节点为已访问

3. **松弛操作**（对当前节点的每个邻居）:
   - 计算经由当前节点到邻居的新距离
   - 若新距离小于已知距离，更新距离和前驱信息

4. **路径重构**:
   - 从目标节点反向追踪前驱节点
   - 同时记录前驱链路
   - 反转得到正向路径

### 特殊处理
- 源和目标相同：直接返回单节点路径
"""
# [算法说明]
# Dijkstra 最短路径算法
# 在卫星网络中查找从源卫星到目标卫星的最低延迟路径。
#
# 算法输入：
#   - ISLPhysicalLinkSeries：ISL 物理链路时间序列（包含距离、时延、可用性）
#   - time_index：当前时间步索引
#   - source_satellite_id：源卫星 ID
#   - destination_satellite_id：目标卫星 ID
#
# 算法输出：
#   - 若路径存在：(卫星路径, 链路路径, 总延迟)
#   - 若路径不存在：nothing
#
# 算法步骤：
#   1. 构建邻接表：从可用 ISL 链路中提取网络拓扑
#   2. 初始化：源节点距离为 0，其他为无穷大
#   3. 主循环：
#      a. 选择未访问节点中距离最小的节点作为当前节点
#      b. 若当前节点为目标节点，搜索完成
#      c. 对当前节点的每个邻居执行松弛操作：
#         若 new_dist = dist[current] + delay(current→neighbor) < dist[neighbor]
#         则更新 dist[neighbor] 和前驱信息
#   4. 路径重构：从目标节点反向追踪前驱节点，反转得到正向路径
#
# 松弛操作（Relaxation）的含义：
#   假设已知从源到节点 A 的最短距离为 d(A)，边 A→B 的权重为 w(A,B)。
#   如果 d(A) + w(A,B) < d(B)，则发现了一条更短的到 B 的路径，
#   更新 d(B) = d(A) + w(A,B)，并记录 B 的前驱为 A。
function shortest_isl_path(
    series::ISLPhysicalLinkSeries,
    time_index::Int,
    source_satellite_id::Int,
    destination_satellite_id::Int,
)::Union{Nothing,Tuple{Vector{Int},Vector{Int},Float64}}
    # 参数验证：源和目标卫星 ID 必须为正整数
    source_satellite_id > 0 || throw(ArgumentError("source_satellite_id must be positive"))
    destination_satellite_id > 0 || throw(ArgumentError("destination_satellite_id must be positive"))
    # 特殊情况：源和目标相同时，返回零延迟的单节点路径
    source_satellite_id == destination_satellite_id &&
        return ([source_satellite_id], Int[], 0.0)

    # === Dijkstra 算法初始化 ===
    # 构建可用链路的邻接表，表示当前时刻的网络拓扑
    # 邻接表结构：satellite_id → [(neighbor_id, link_id, delay_s), ...]
    adjacency = available_isl_adjacency(series, time_index)
    # 距离字典：源节点距离为 0，其他节点初始未设置（等效于无穷大）
    distances = Dict(source_satellite_id => 0.0)
    # 前驱节点字典：用于路径重构，记录到达每个节点的前一个卫星
    previous_satellite = Dict{Int,Int}()
    # 前驱链路字典：记录到达每个节点使用的链路 ID
    previous_link = Dict{Int,Int}()
    # 已访问节点集合：已确定最短路径的节点
    visited = Set{Int}()

    # === Dijkstra 主循环 ===
    while true
        # 步骤 1: 从未访问节点中选择距离最小的节点（贪心选择）
        current::Union{Nothing,Int} = nothing
        current_distance = Inf
        for (satellite_id, distance) in distances
            if !(satellite_id in visited) && distance < current_distance
                current = satellite_id
                current_distance = distance
            end
        end
        # 若没有可访问的未访问节点，说明目标不可达
        current === nothing && return nothing
        # 若当前节点即为目标节点，完成搜索
        current == destination_satellite_id && break
        # 标记当前节点为已访问（其最短距离已确定）
        push!(visited, current)

        # 步骤 2: 松弛操作 - 尝试通过当前节点改进邻居的距离
        for (neighbor, link_id, delay_s) in get(adjacency, current, Tuple{Int,Int,Float64}[])
            # 跳过已访问节点（其最短距离已确定，无需再更新）
            neighbor in visited && continue
            # 计算经由当前节点到邻居的新距离（当前最短距离 + 边权重）
            new_distance = current_distance + delay_s
            # 松弛判断：若新距离更优，更新距离和前驱信息
            if new_distance < get(distances, neighbor, Inf)
                distances[neighbor] = new_distance
                previous_satellite[neighbor] = current
                previous_link[neighbor] = link_id
            end
        end
    end

    # === 路径重构 ===
    # 从目标节点反向追踪到源节点，利用前驱映射重建路径
    satellite_path = Int[destination_satellite_id]
    link_path = Int[]
    cursor = destination_satellite_id
    while cursor != source_satellite_id
        # 安全检查：确保前驱节点存在（防止路径断裂）
        haskey(previous_satellite, cursor) || return nothing
        # 将链路添加到路径头部（保持正向顺序）
        pushfirst!(link_path, previous_link[cursor])
        # 移动到前驱节点
        cursor = previous_satellite[cursor]
        # 将节点添加到路径头部（保持正向顺序）
        pushfirst!(satellite_path, cursor)
    end

    # 返回完整路径和总延迟
    return satellite_path, link_path, distances[destination_satellite_id]
end

"""
    route_path_at(request, isl_series, access_table, time_index) -> RoutePath

计算特定时刻的完整路由路径，包括源/目标地面站的接入和卫星间的 ISL 路径。

## 参数说明
- `request::RouteRequest`: 路由请求（源和目标地面站）
- `isl_series::ISLPhysicalLinkSeries`: ISL 物理链路的时间序列
- `access_table::AccessDecisionTable`: 接入决策表，包含地面站与卫星的接入信息
- `time_index::Int`: 时间索引

## 返回值
完整的 `RoutePath` 对象，包含路径的所有信息。

## 处理流程

### 1. 前置检查
- 确保 ISL 系列和接入表使用相同的时间网格
- 计算当前时间片的绝对时间偏移

### 2. 获取接入信息
- 查询源地面站的接入决策（选择的卫星）
- 查询目标地面站的接入决策（选择的卫星）

### 3. 可达性检查
依次检查三种不可达情况：
- `:source_no_access` - 源地面站无可用卫星接入
- `:destination_no_access` - 目标地面站无可用卫星接入
- `:isl_unreachable` - 卫星间网络无路径

### 4. 计算完整路径
若可达，则：
- 使用 Dijkstra 算法计算 ISL 路径
- 计算源 GSL 延迟
- 计算目标 GSL 延迟
- 汇总得到总延迟

### 5. 返回结果
构建包含所有字段的 `RoutePath` 对象
"""
# [算法说明]
# 完整路由路径计算
# 端到端路径由三部分组成：
#   1. 源 GSL：地面站 → 源接入卫星（传播时延）
#   2. ISL 路径：源接入卫星 → 目标接入卫星（Dijkstra 最短路径）
#   3. 目标 GSL：目标接入卫星 → 目标地面站（传播时延）
#
# 总延迟 = 源 GSL 延迟 + ISL 路径延迟 + 目标 GSL 延迟
#
# 不可达的三种情况：
#   1. :source_no_access - 源地面站无卫星可接入（仰角不足或无可见卫星）
#   2. :destination_no_access - 目标地面站无卫星可接入
#   3. :isl_unreachable - 卫星间网络无路径（网络不连通或链路全部不可用）
function route_path_at(
    request::RouteRequest,
    isl_series::ISLPhysicalLinkSeries,
    access_table::AccessDecisionTable,
    time_index::Int,
)::RoutePath
    # 前置检查：确保 ISL 系列和接入表使用相同的时间网格对象
    isl_series.time_grid === access_table.time_grid ||
        throw(ArgumentError("ISL series and access table must share the same time_grid object"))
    # 计算当前时间片的绝对时间偏移（从仿真开始经过的秒数）
    elapsed_s = timeslot_offsets(isl_series.time_grid)[time_index]

    # 获取源和目标地面站的接入决策
    source_access = access_decisions_at(access_table, request.source_ground_id, time_index)
    destination_access = access_decisions_at(access_table, request.destination_ground_id, time_index)
    # 提取选择的卫星 ID
    source_satellite_id = source_access.selected_satellite_id
    destination_satellite_id = destination_access.selected_satellite_id

    # 检查 1: 源地面站是否有卫星可接入
    if source_satellite_id === nothing
        return route_unreachable(
            request,
            time_index,
            elapsed_s,
            source_satellite_id,
            destination_satellite_id,
            :source_no_access,  # 不可达原因：源无接入
        )
    # 检查 2: 目标地面站是否有卫星可接入
    elseif destination_satellite_id === nothing
        return route_unreachable(
            request,
            time_index,
            elapsed_s,
            source_satellite_id,
            destination_satellite_id,
            :destination_no_access,  # 不可达原因：目标无接入
        )
    end

    # 检查 3: 卫星间网络是否有路径（调用 Dijkstra 算法）
    result = shortest_isl_path(
        isl_series,
        time_index,
        source_satellite_id,
        destination_satellite_id,
    )
    if result === nothing
        return route_unreachable(
            request,
            time_index,
            elapsed_s,
            source_satellite_id,
            destination_satellite_id,
            :isl_unreachable,  # 不可达原因：ISL 网络不通
        )
    end

    # 路径可达，提取 ISL 路径结果
    satellite_path, link_path, isl_delay_s = result
    # 计算源 GSL 延迟（若无采样样本则默认为 0）
    source_gsl_delay_s = source_access.selected_sample === nothing ?
        0.0 :
        source_access.selected_sample.propagation_delay_s
    # 计算目标 GSL 延迟（若无采样样本则默认为 0）
    destination_gsl_delay_s = destination_access.selected_sample === nothing ?
        0.0 :
        destination_access.selected_sample.propagation_delay_s
    # 计算总延迟：源 GSL + ISL + 目标 GSL
    total_delay_s = source_gsl_delay_s + isl_delay_s + destination_gsl_delay_s

    return RoutePath(
        request = request,
        time_index = time_index,
        elapsed_s = elapsed_s,
        source_access_satellite_id = source_satellite_id,
        destination_access_satellite_id = destination_satellite_id,
        satellite_path = satellite_path,
        isl_link_ids = link_path,
        isl_delay_s = isl_delay_s,
        source_gsl_delay_s = source_gsl_delay_s,
        destination_gsl_delay_s = destination_gsl_delay_s,
        total_delay_s = total_delay_s,
        reachable = true,
        reason = :shortest_delay,
    )
end

"""
    route_series(request, isl_series, access_table) -> RouteSeries

计算一个路由请求在整个仿真时间窗口内的完整路径序列。

## 参数说明
- `request::RouteRequest`: 路由请求（源和目标地面站）
- `isl_series::ISLPhysicalLinkSeries`: ISL 物理链路的时间序列
- `access_table::AccessDecisionTable`: 接入决策表

## 返回值
包含每个时间片路径结果的 `RouteSeries` 对象

## 使用场景
此函数用于分析路由路径随时间的变化情况，例如：
- 观察路径切换事件（当卫星移动导致最优路径变化时）
- 统计不可达时间比例
- 计算延迟随时间的变化

## 实现说明
- 对时间网格中的每个时间片调用 `route_path_at`
- 使用推导式构建路径向量
- 最后构造 `RouteSeries` 对象，自动验证路径数量与时间网格匹配
"""
function route_series(
    request::RouteRequest,
    isl_series::ISLPhysicalLinkSeries,
    access_table::AccessDecisionTable,
)::RouteSeries
    # 对每个时间片计算路径，构建完整的时间序列
    paths = [
        route_path_at(request, isl_series, access_table, time_index)
        for time_index in 1:time_count(isl_series.time_grid)
    ]
    return RouteSeries(request, isl_series.time_grid, paths)
end
