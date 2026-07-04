"""
    orbital_events

轨道事件模块。

本文件定义了轨道链路事件相关的数据结构和序列化功能，用于表示和管理卫星网络中的链路事件。

主要数据结构：
- `OrbitalLinkEndpoint`：链路端点（地面站或卫星）
- `OrbitalLinkEvent`：单个链路事件（链路建立、断开、更新）
- `OrbitalEventsFile`：轨道事件文件容器，包含时间网格和事件列表
- `OrbitalLinkWindow`：链路可用窗口（从 link_up 到 link_down 的时间段）

主要功能：
- 事件序列化/反序列化（JSON 格式）
- 从 GSL 物理链路采样序列生成轨道事件
- 链路窗口汇总

# [算法说明]
# 链路窗口汇总算法：
# 该算法将离散的link_up/link_down事件序列转换为连续的时间窗口表示。
# 算法步骤：
# 1. 按时间排序事件：确保按时间顺序处理事件；
# 2. 使用字典跟踪未匹配的link_up事件：key为链路标识（端点A,端点B,链路类型）；
# 3. 匹配link_up和link_down事件：遇到link_down时，查找对应的link_up；
# 4. 生成时间窗口：从link_up时间到link_down时间形成一个窗口；
# 5. 处理未匹配事件：仿真结束时仍存在的link_up生成开放窗口；
# 6. 按时间排序输出：确保结果按时间顺序排列。
#
# link_up/link_down事件配对逻辑：
# 这个逻辑基于状态机思想：
# 状态0（初始）：链路不可用
# 状态1（链路可用）：链路已建立
# 状态转换规则：
# - 从状态0到状态1：触发link_up事件
# - 从状态1到状态0：触发link_down事件
# - 状态不变：不触发事件（或触发link_update事件）
#
# 为什么需要事件配对：
# 1. 网络层需要知道链路何时可用，用于路由和资源分配；
# 2. 链路窗口是网络性能分析的基本单位；
# 3. 事件序列比连续采样更紧凑，便于存储和传输。
"""

using JSON

"""
    OrbitalLinkEndpoint

轨道链路端点，表示链路的某一端（地面站或卫星）。

# [算法说明]
# 链路端点模型：
# 链路端点是通信链路的两端，可以是地面站或卫星。
#
# 端点类型：
# 1. :ground（地面站）：
#    - 固定在地球表面
#    - 通常作为数据源或目的
#    - 例如：信关站、用户终端
#
# 2. :satellite（卫星）：
#    - 在轨道上运动
#    - 作为中继节点
#    - 例如：LEO卫星、GEO卫星
#
# ID设计：
# - 正整数：确保唯一性
# - 起始值1：与数组索引一致
# - 全局唯一：不同类型的ID可以重复（如ground-1和satellite-1是不同的）
#
# 为什么需要端点模型：
# 1. 链路表示：链路由两个端点定义
# 2. 类型区分：区分地面站和卫星
# 3. 标识作用：通过ID唯一标识端点
# 4. 序列化：便于存储和传输
#
# 与其他模型的比较：
# - 直接使用ID：无法区分类型
# - 使用对象引用：不利于序列化
# - 端点模型：平衡了类型安全和序列化便利性

字段
- `kind::Symbol`：端点类型，`:ground` 表示地面站，`:satellite` 表示卫星
- `id::Int`：端点 ID，必须为正整数

构造参数
- `kind::Symbol`：端点类型（`:ground` 或 `:satellite`）
- `id::Int`：端点 ID

异常
- `ArgumentError`：当 `kind` 不是 `:ground` 或 `:satellite` 时抛出
- `ArgumentError`：当 `id` 不是正整数时抛出
"""
struct OrbitalLinkEndpoint
    kind::Symbol
    id::Int

    function OrbitalLinkEndpoint(kind::Symbol, id::Int)
        # 验证端点类型必须为 ground 或 satellite
        kind in (:ground, :satellite) || throw(ArgumentError("endpoint kind must be :ground or :satellite"))
        # 验证 ID 必须为正整数
        id > 0 || throw(ArgumentError("endpoint id must be positive"))
        return new(kind, id)
    end
end

"""
    OrbitalLinkEvent

轨道链路事件，表示链路状态的变化。

# [算法说明]
# 链路事件类型详解：
# 1. link_up：链路建立事件
#    - 触发条件：链路从不可用变为可用
#    - 包含信息：建立时间、距离、容量等
#    - 用途：通知网络层链路可用，可以开始传输数据
#
# 2. link_down：链路断开事件
#    - 触发条件：链路从可用变为不可用
#    - 包含信息：断开时间、最终状态等
#    - 用途：通知网络层链路不可用，需要切换路由
#
# 3. link_update：链路更新事件
#    - 触发条件：链路参数变化（如距离、容量变化）
#    - 包含信息：更新后的参数
#    - 用途：通知网络层链路特性变化，可能需要调整传输策略
#
# 物理量含义：
# - distance_km：两端点间的直线距离（km），影响传播延迟
# - propagation_delay_s：信号传播延迟（秒），= distance / 光速
# - capacity_mbps：链路容量（Mbps），最大传输速率
#
# 为什么需要这些信息：
# 1. 路由决策：根据链路状态和容量选择最佳路径
# 2. 资源分配：根据容量分配通信资源
# 3. 延迟计算：根据传播延迟计算端到端延迟
# 4. 性能评估：评估网络性能指标

字段
- `event_type::Symbol`：事件类型（`:link_up` 链路建立、`:link_down` 链路断开、`:link_update` 链路更新）
- `link_type::Symbol`：链路类型（`:gsl` 地空链路、`:isl` 星间链路）
- `time_index::Int`：在时间网格中的索引
- `elapsed_s::Int`：距离 epoch 的累计秒数
- `endpoint_a::OrbitalLinkEndpoint`：链路端点 A
- `endpoint_b::OrbitalLinkEndpoint`：链路端点 B
- `distance_km::Float64`：两端点距离（公里）
- `propagation_delay_s::Float64`：传播时延（秒）
- `capacity_mbps::Float64`：链路容量（Mbps）
- `attributes::Dict{String,Any}`：附加属性字典

构造参数
- `event_type::Symbol`：事件类型
- `link_type::Symbol`：链路类型
- `time_index::Int`：时间索引
- `elapsed_s::Int`：累计秒数
- `endpoint_a::OrbitalLinkEndpoint`：端点 A
- `endpoint_b::OrbitalLinkEndpoint`：端点 B
- `distance_km::Real`：距离（公里）
- `propagation_delay_s::Real`：传播时延（秒）
- `capacity_mbps::Real`：容量（Mbps）
- `attributes::Dict{String,Any}`：附加属性，默认为空字典

异常
- `ArgumentError`：当参数不符合要求时抛出（事件类型、链路类型、时间索引、各种物理量必须合法）
"""
struct OrbitalLinkEvent
    event_type::Symbol
    link_type::Symbol
    time_index::Int
    elapsed_s::Int
    endpoint_a::OrbitalLinkEndpoint
    endpoint_b::OrbitalLinkEndpoint
    distance_km::Float64
    propagation_delay_s::Float64
    capacity_mbps::Float64
    attributes::Dict{String,Any}

    function OrbitalLinkEvent(;
        event_type::Symbol,
        link_type::Symbol,
        time_index::Int,
        elapsed_s::Int,
        endpoint_a::OrbitalLinkEndpoint,
        endpoint_b::OrbitalLinkEndpoint,
        distance_km::Real,
        propagation_delay_s::Real,
        capacity_mbps::Real,
        attributes::Dict{String,Any} = Dict{String,Any}(),
    )
        # 验证事件类型
        event_type in (:link_up, :link_down, :link_update) ||
            throw(ArgumentError("event_type must be :link_up, :link_down, or :link_update"))
        # 验证链路类型
        link_type in (:gsl, :isl) || throw(ArgumentError("link_type must be :gsl or :isl"))
        # 验证时间索引
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        # 验证累计秒数
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        # 验证距离
        distance_km >= 0 || throw(ArgumentError("distance_km must be non-negative"))
        # 验证传播时延
        propagation_delay_s >= 0 || throw(ArgumentError("propagation_delay_s must be non-negative"))
        # 验证容量
        capacity_mbps >= 0 || throw(ArgumentError("capacity_mbps must be non-negative"))

        return new(
            event_type,
            link_type,
            time_index,
            elapsed_s,
            endpoint_a,
            endpoint_b,
            Float64(distance_km),
            Float64(propagation_delay_s),
            Float64(capacity_mbps),
            attributes,
        )
    end
end

"""
    OrbitalEventsFile

轨道事件文件容器，包含完整的事件序列及其元数据。

# [算法说明]
# 轨道事件文件设计：
# 这是轨道事件的完整容器，包含时间网格和事件列表。
#
# 文件结构：
# 1. format：文件格式标识（如"SatelliteSimJulia-OEF"）
# 2. version：版本号，用于兼容性检查
# 3. time_grid：时间网格定义，所有事件的时间必须在此范围内
# 4. events：事件列表，按时间排序
# 5. metadata：元数据字典，包含自定义信息
#
# 为什么需要这种结构：
# 1. 自描述性：文件包含格式和版本信息
# 2. 完整性：包含所有必要信息，可以独立解析
# 3. 可扩展：通过metadata支持自定义信息
# 4. 兼容性：版本控制支持向后兼容
#
# 数据验证：
# 构造函数验证：
# - format和version非空
# - 事件时间索引在时间网格范围内
# - 事件elapsed_s与时间网格偏移量匹配
#
# 使用场景：
# 1. 数据持久化：保存轨道事件到文件
# 2. 数据交换：在不同系统间传输事件
# 3. 分析处理：加载事件进行后处理
# 4. 可视化：生成事件时间线

字段
- `format::String`：文件格式标识符
- `version::String`：文件版本
- `time_grid::SimulationTimeGrid`：仿真时间网格
- `events::Vector{OrbitalLinkEvent}`：事件列表
- `metadata::Dict{String,Any}`：元数据字典

构造参数
- `time_grid::SimulationTimeGrid`：时间网格
- `events::Vector{OrbitalLinkEvent}`：事件列表
- `format::String`：格式标识，默认为 "SatelliteSimJulia-OEF"
- `version::String`：版本号，默认为 "0.1"
- `metadata::Dict{String,Any}`：元数据，默认为空字典

异常
- `ArgumentError`：当格式或版本为空，或事件时间索引超出时间网格范围时抛出
"""
struct OrbitalEventsFile
    format::String
    version::String
    time_grid::SimulationTimeGrid
    events::Vector{OrbitalLinkEvent}
    metadata::Dict{String,Any}

    function OrbitalEventsFile(
        time_grid::SimulationTimeGrid,
        events::Vector{OrbitalLinkEvent};
        format::String = "SatelliteSimJulia-OEF",
        version::String = "0.1",
        metadata::Dict{String,Any} = Dict{String,Any}(),
    )
        # 验证格式字符串非空
        isempty(format) && throw(ArgumentError("format must not be empty"))
        # 验证版本字符串非空
        isempty(version) && throw(ArgumentError("version must not be empty"))

        # 验证所有事件的时间索引和累计秒数与时间网格一致
        for event in events
            event.time_index <= time_count(time_grid) ||
                throw(ArgumentError("event time_index exceeds time_grid length"))
            event.elapsed_s == timeslot_offsets(time_grid)[event.time_index] ||
                throw(ArgumentError("event elapsed_s must match time_grid offset"))
        end

        return new(format, version, time_grid, events, metadata)
    end
end

"""
    OrbitalLinkWindow

轨道链路可用窗口，表示从链路建立到断开的完整时间段。

# [算法说明]
# 链路窗口模型：
# 这个结构表示链路可用的连续时间段，是网络层分析的基本单位。
#
# 窗口状态：
# 1. 开放窗口：link_down_time_index = nothing
#    - 含义：链路在仿真结束时仍然可用
#    - 持续时间：未定义（或无穷大）
#
# 2. 闭合窗口：link_down_time_index ≠ nothing
#    - 含义：链路在指定时间断开
#    - 持续时间：link_down_elapsed_s - link_up_elapsed_s
#
# 窗口计算：
# - 持续时间：Δt = link_down_elapsed_s - link_up_elapsed_s
# - 可用时间占比：Δt / 总仿真时间
# - 窗口数量：统计所有窗口，分析链路稳定性
#
# 为什么需要窗口模型：
# 1. 简化分析：将连续时间离散化为窗口
# 2. 资源规划：根据窗口安排传输任务
# 3. 性能评估：计算链路可用性指标
# 4. 路由优化：选择最长窗口的路径
#
# 与事件序列的比较：
# - 事件序列：记录状态变化时刻，紧凑但需要处理
# - 窗口模型：直接表示可用时间段，易于分析
# 窗口模型是事件序列的高级抽象。

字段
- `link_type::Symbol`：链路类型（`:gsl` 或 `:isl`）
- `endpoint_a::OrbitalLinkEndpoint`：端点 A
- `endpoint_b::OrbitalLinkEndpoint`：端点 B
- `link_up_time_index::Int`：链路建立时的索引
- `link_up_elapsed_s::Int`：链路建立时的累计秒数
- `link_down_time_index::Union{Nothing,Int}`：链路断开时的索引（如果已断开）
- `link_down_elapsed_s::Union{Nothing,Int}`：链路断开时的累计秒数（如果已断开）

构造参数
- `link_type::Symbol`：链路类型
- `endpoint_a::OrbitalLinkEndpoint`：端点 A
- `endpoint_b::OrbitalLinkEndpoint`：端点 B
- `link_up_time_index::Int`：建立时间索引
- `link_up_elapsed_s::Int`：建立时累计秒数
- `link_down_time_index::Union{Nothing,Int}`：断开时间索引，默认为 nothing
- `link_down_elapsed_s::Union{Nothing,Int}`：断开时累计秒数，默认为 nothing

异常
- `ArgumentError`：当参数不符合要求时抛出
"""
struct OrbitalLinkWindow
    link_type::Symbol
    endpoint_a::OrbitalLinkEndpoint
    endpoint_b::OrbitalLinkEndpoint
    link_up_time_index::Int
    link_up_elapsed_s::Int
    link_down_time_index::Union{Nothing,Int}
    link_down_elapsed_s::Union{Nothing,Int}

    function OrbitalLinkWindow(;
        link_type::Symbol,
        endpoint_a::OrbitalLinkEndpoint,
        endpoint_b::OrbitalLinkEndpoint,
        link_up_time_index::Int,
        link_up_elapsed_s::Int,
        link_down_time_index::Union{Nothing,Int} = nothing,
        link_down_elapsed_s::Union{Nothing,Int} = nothing,
    )
        # 验证链路类型
        link_type in (:gsl, :isl) || throw(ArgumentError("link_type must be :gsl or :isl"))
        # 验证建立时间索引
        link_up_time_index > 0 || throw(ArgumentError("link_up_time_index must be positive"))
        # 验证建立累计秒数
        link_up_elapsed_s >= 0 || throw(ArgumentError("link_up_elapsed_s must be non-negative"))

        # 验证断开时间参数的完整性
        if link_down_time_index !== nothing
            link_down_time_index > 0 || throw(ArgumentError("link_down_time_index must be positive"))
            link_down_elapsed_s !== nothing ||
                throw(ArgumentError("link_down_elapsed_s must be present when link_down_time_index is present"))
            link_down_elapsed_s >= link_up_elapsed_s ||
                throw(ArgumentError("link_down_elapsed_s must be greater than or equal to link_up_elapsed_s"))
        elseif link_down_elapsed_s !== nothing
            throw(ArgumentError("link_down_time_index must be present when link_down_elapsed_s is present"))
        end

        return new(
            link_type,
            endpoint_a,
            endpoint_b,
            link_up_time_index,
            link_up_elapsed_s,
            link_down_time_index,
            link_down_elapsed_s,
        )
    end
end

"""
    is_available(sample::GSLPhysicalLinkSample) -> Bool

判断 GSL 物理链路样本是否可用。

# [算法说明]
# 链路可用性判断：
# 该函数判断GSL物理链路样本是否处于可用状态。
#
# 判断逻辑：
# 使用类型检查：sample.state isa LinkAvailable
# - 如果状态是LinkAvailable类型，返回true
# - 否则返回false
#
# 为什么使用类型检查：
# 1. 类型安全：利用Julia的类型系统
# 2. 性能高效：类型检查是O(1)操作
# 3. 语义清晰：直接表达"是否为可用状态"
#
# 链路状态类型：
# - LinkAvailable：链路可用，可以传输数据
# - LinkUnavailable：链路不可用（如超出范围、遮挡等）
# - LinkDegraded：链路降级（如信号弱、容量低）
#
# 使用场景：
# - 事件生成：检测状态变化
# - 链路选择：选择可用链路
# - 性能评估：统计可用时间比例
#
# 与其他方法的比较：
# - 布尔标志：sample.available
# - 枚举比较：sample.state == LinkAvailable
# - 类型检查：sample.state isa LinkAvailable
# 类型检查最简洁和高效。

参数
- `sample::GSLPhysicalLinkSample`：GSL 物理链路样本

返回值
- `Bool`：如果链路状态为 `LinkAvailable` 则返回 true，否则返回 false
"""
is_available(sample::GSLPhysicalLinkSample)::Bool = sample.state isa LinkAvailable

"""
    link_window_duration_s(window::OrbitalLinkWindow) -> Union{Nothing,Int}

计算链路窗口的持续时间（秒）。

# [算法说明]
# 链路窗口持续时间计算：
# 该函数计算链路窗口的持续时间。
#
# 计算公式：
# duration = link_down_elapsed_s - link_up_elapsed_s
#
# 边界情况：
# 1. 闭合窗口（link_down_time_index ≠ nothing）：
#    - 返回持续时间（秒）
#    - 持续时间 ≥ 0
#
# 2. 开放窗口（link_down_time_index = nothing）：
#    - 返回nothing
#    - 表示链路在仿真结束时仍然可用
#
# 为什么返回nothing而不是无穷大：
# 1. 类型安全：nothing表示未定义，而不是无穷大
# 2. 语义清晰：开放窗口没有确定的持续时间
# 3. 避免特殊值：避免处理无穷大的特殊情况
#
# 使用场景：
# - 链路可用性分析：计算平均窗口长度
# - 资源规划：根据窗口长度安排传输任务
# - 性能评估：统计链路稳定性

参数
- `window::OrbitalLinkWindow`：链路窗口

返回值
- `Union{Nothing,Int}`：如果链路已断开则返回持续时间（秒），否则返回 nothing
"""
link_window_duration_s(window::OrbitalLinkWindow)::Union{Nothing,Int} =
    window.link_down_elapsed_s === nothing ? nothing : window.link_down_elapsed_s - window.link_up_elapsed_s

"""
    endpoint_key(endpoint::OrbitalLinkEndpoint) -> Tuple{Symbol,Int}

生成端点的唯一键值。

# [算法说明]
# 端点键值生成算法：
# 该函数将链路端点转换为唯一的元组键值。
#
# 键值结构：
# (kind, id)
# - kind：端点类型（:ground或:satellite）
# - id：端点ID（正整数）
#
# 为什么需要唯一键值：
# 1. 字典索引：作为字典的键，用于快速查找
# 2. 唯一标识：确保每个端点有唯一标识
# 3. 比较操作：支持相等性比较
#
# 键值设计考虑：
# 1. 不可变性：元组是不可变的，适合用作字典键
# 2. 哈希性：元组支持哈希，字典查找高效
# 3. 语义清晰：包含类型和ID，易于理解
#
# 使用场景：
# - 链路窗口汇总：跟踪每条链路的开闭状态
# - 事件去重：避免重复处理相同链路
# - 链路标识：在事件流中标识特定链路

参数
- `endpoint::OrbitalLinkEndpoint`：链路端点

返回值
- `Tuple{Symbol,Int}`：端点类型和 ID 组成的元组
"""
function endpoint_key(endpoint::OrbitalLinkEndpoint)::Tuple{Symbol,Int}
    return (endpoint.kind, endpoint.id)
end

"""
    link_key(event::OrbitalLinkEvent) -> Tuple{Symbol,Tuple{Symbol,Int},Tuple{Symbol,Int}}

生成链路的唯一键值。

# [算法说明]
# 链路键值生成算法：
# 该函数将链路事件转换为唯一的元组键值。
#
# 键值结构：
# (link_type, endpoint_key_a, endpoint_key_b)
# - link_type：链路类型（:gsl或:isl）
# - endpoint_key_a：端点A的键值
# - endpoint_key_b：端点B的键值
#
# 为什么需要链路键值：
# 1. 链路标识：唯一标识一条链路（与方向无关）
# 2. 字典索引：用于跟踪每条链路的开闭状态
# 3. 去重处理：避免重复处理相同链路
#
# 链路方向性考虑：
# - 对于无向链路（如ISL），(A,B)和(B,A)是同一链路
# - 本实现不考虑方向性：键值与端点顺序无关
# - 如需方向性，可以添加方向标志
#
# 键值嵌套设计：
# 使用嵌套元组，优点：
# 1. 层次清晰：链路类型 → 端点A → 端点B
# 2. 唯一性：不同层组合确保唯一
# 3. 可扩展：可以添加更多层信息

参数
- `event::OrbitalLinkEvent`：链路事件

返回值
- `Tuple{Symbol,Tuple{Symbol,Int},Tuple{Symbol,Int}}`：由链路类型、端点 A 键、端点 B 键组成的元组
"""
function link_key(event::OrbitalLinkEvent)::Tuple{Symbol,Tuple{Symbol,Int},Tuple{Symbol,Int}}
    return (event.link_type, endpoint_key(event.endpoint_a), endpoint_key(event.endpoint_b))
end

"""
    endpoint_dict(endpoint::OrbitalLinkEndpoint) -> Dict{String,Any}

将端点转换为字典格式，用于 JSON 序列化。

# [算法说明]
# 端点字典转换算法：
# 该函数将链路端点转换为字典格式，便于JSON序列化。
#
# 转换过程：
# 1. kind：Symbol转换为String（:ground → "ground"）
# 2. id：Int保持不变
# 3. 组合为Dict{String,Any}
#
# 为什么需要字典格式：
# 1. JSON兼容：JSON要求键为字符串
# 2. 序列化：便于存储和传输
# 3. 可读性：人类可读的格式
#
# 键名设计：
# - "kind"：端点类型
# - "id"：端点ID
# 使用简洁的键名，减少文件大小。
#
# 类型转换：
# - Symbol → String：JSON不支持Symbol类型
# - Int → Any：保持整数类型
# - 使用Dict{String,Any}：支持任意值类型

参数
- `endpoint::OrbitalLinkEndpoint`：链路端点

返回值
- `Dict{String,Any}`：包含端点类型（字符串）和 ID 的字典
"""
function endpoint_dict(endpoint::OrbitalLinkEndpoint)::Dict{String,Any}
    return Dict{String,Any}(
        "kind" => String(endpoint.kind),
        "id" => endpoint.id,
    )
end

"""
    event_dict(event::OrbitalLinkEvent) -> Dict{String,Any}

将链路事件转换为字典格式，用于 JSON 序列化。

# [算法说明]
# 事件字典转换算法：
# 该函数将链路事件转换为字典格式，便于JSON序列化。
#
# 转换过程：
# 1. 基本信息：
#    - event_type：Symbol → String
#    - link_type：Symbol → String
#    - time_index, elapsed_s：Int保持不变
#
# 2. 端点信息：
#    - endpoint_a, endpoint_b：调用endpoint_dict转换
#
# 3. 物理量：
#    - distance_km, propagation_delay_s, capacity_mbps：Float64保持不变
#
# 4. 附加属性：
#    - attributes：Dict{String,Any}保持不变
#
# 键名设计：
# 使用描述性键名，如"time_s"而不是"elapsed_s"，
# 使JSON文件更易于人类阅读和理解。
#
# 嵌套结构：
# 使用嵌套字典表示端点信息，保持JSON结构清晰。
#
# 类型转换：
# - Symbol → String：JSON不支持Symbol
# - 保持数值类型：Int, Float64
# - 嵌套字典：Dict{String,Any}

参数
- `event::OrbitalLinkEvent`：链路事件

返回值
- `Dict{String,Any}`：包含事件所有字段的字典
"""
function event_dict(event::OrbitalLinkEvent)::Dict{String,Any}
    return Dict{String,Any}(
        "event_type" => String(event.event_type),
        "link_type" => String(event.link_type),
        "time_index" => event.time_index,
        "time_s" => event.elapsed_s,
        "endpoint_a" => endpoint_dict(event.endpoint_a),
        "endpoint_b" => endpoint_dict(event.endpoint_b),
        "distance_km" => event.distance_km,
        "propagation_delay_s" => event.propagation_delay_s,
        "capacity_mbps" => event.capacity_mbps,
        "attributes" => event.attributes,
    )
end

"""
    window_dict(window::OrbitalLinkWindow) -> Dict{String,Any}

将链路窗口转换为字典格式，用于 JSON 序列化。

# [算法说明]
# 窗口字典转换算法：
# 该函数将链路窗口转换为字典格式，便于JSON序列化。
#
# 转换过程：
# 1. 基本信息：
#    - link_type：Symbol → String
#    - endpoint_a, endpoint_b：调用endpoint_dict转换
#
# 2. 时间信息：
#    - link_up_time_index, link_up_elapsed_s：Int保持不变
#    - link_down_time_index, link_down_elapsed_s：Union{Nothing,Int}保持不变
#
# 3. 计算字段：
#    - duration_s：调用link_window_duration_s计算
#
# 为什么包含计算字段：
# - 预计算：避免下游重复计算
# - 可读性：直接显示持续时间
# - 一致性：确保计算逻辑统一
#
# 键名设计：
# 使用"time_s"表示累计秒数，"time_index"表示索引，
# 使JSON文件更易于人类阅读。
#
# 处理nothing值：
# - link_down_time_index：可能为nothing
# - link_down_elapsed_s：可能为nothing
# - JSON序列化：nothing会被序列化为null

参数
- `window::OrbitalLinkWindow`：链路窗口

返回值
- `Dict{String,Any}`：包含窗口所有字段的字典，包括计算出的持续时间
"""
function window_dict(window::OrbitalLinkWindow)::Dict{String,Any}
    return Dict{String,Any}(
        "link_type" => String(window.link_type),
        "endpoint_a" => endpoint_dict(window.endpoint_a),
        "endpoint_b" => endpoint_dict(window.endpoint_b),
        "link_up_time_index" => window.link_up_time_index,
        "link_up_time_s" => window.link_up_elapsed_s,
        "link_down_time_index" => window.link_down_time_index,
        "link_down_time_s" => window.link_down_elapsed_s,
        "duration_s" => link_window_duration_s(window),
    )
end

"""
    summarize_link_windows(oef::OrbitalEventsFile) -> Vector{OrbitalLinkWindow}

从轨道事件文件中提取并汇总所有链路窗口。

# [算法说明]
# 链路窗口汇总算法详解：
# 这个算法将离散的事件序列转换为连续的时间窗口表示。
# 核心思想：使用状态机跟踪每条链路的开闭状态。
#
# 算法步骤：
# 1. 事件排序：按(elapsed_s, time_index, event_type)排序
#    - 为什么按这个顺序：确保时间顺序，同时link_up在link_down之前处理
#
# 2. 初始化状态机：
#    - 字典open_by_link：key=(链路类型, 端点A, 端点B)，value=未匹配的link_up事件
#    - 列表windows：存储生成的链路窗口
#
# 3. 处理每个事件：
#    - 跳过link_update：只关注状态变化
#    - link_up事件：检查是否已有未匹配的link_up（不允许重复），记录到字典
#    - link_down事件：查找对应的link_up，生成窗口，从字典中删除
#
# 4. 处理未匹配事件：
#    - 仿真结束时仍存在的link_up：生成开放窗口（无link_down时间）
#
# 5. 排序输出：按建立时间、链路类型、端点信息排序
#
# 数据结构设计：
# - 使用字典跟踪未匹配事件：O(1)查找时间复杂度
# - 窗口生成是O(1)操作：只需记录起止时间
# - 最终排序是O(n log n)：但n通常较小
#
# 错误处理：
# - 重复link_up：同一链路不能同时有两个link_up
# - 缺失link_up：link_down必须有对应的link_up
# 这些检查确保事件序列的逻辑一致性。

算法：
1. 按 (elapsed_s, time_index, event_type) 对事件排序
2. 跳过 link_update 事件
3. 对于每条链路，匹配 link_up 和 link_down 事件
4. 生成对应的 OrbitalLinkWindow
5. 对于没有匹配 link_down 的 link_up，生成一个只有 link_up 的窗口
6. 按建立时间排序输出

参数
- `oef::OrbitalEventsFile`：轨道事件文件

返回值
- `Vector{OrbitalLinkWindow}`：所有链路窗口的列表，按建立时间排序

异常
- `ArgumentError`：当发现重复的 link_up 或没有匹配的 link_down 时抛出
"""
function summarize_link_windows(oef::OrbitalEventsFile)::Vector{OrbitalLinkWindow}
    # 按时间排序事件
    sorted_events = sort(oef.events, by = event -> (event.elapsed_s, event.time_index, String(event.event_type)))

    # 跟踪每条链路的 link_up 事件
    open_by_link = Dict{Tuple{Symbol,Tuple{Symbol,Int},Tuple{Symbol,Int}},OrbitalLinkEvent}()

    # 收集所有窗口
    windows = OrbitalLinkWindow[]

    # 处理每个事件
    for event in sorted_events
        # 跳过 link_update 事件
        event.event_type == :link_update && continue

        # 获取链路唯一键
        key = link_key(event)

        if event.event_type == :link_up
            # 检查是否已有未匹配的 link_up
            haskey(open_by_link, key) &&
                throw(ArgumentError("duplicate link_up before link_down for $(endpoint_label_for_error(event.endpoint_a)) -> $(endpoint_label_for_error(event.endpoint_b)) at t=$(event.elapsed_s)s"))
            open_by_link[key] = event
        elseif event.event_type == :link_down
            # 获取对应的 link_up 事件
            up_event = get(open_by_link, key, nothing)
            up_event === nothing &&
                throw(ArgumentError("link_down without matching link_up for $(endpoint_label_for_error(event.endpoint_a)) -> $(endpoint_label_for_error(event.endpoint_b)) at t=$(event.elapsed_s)s"))

            # 创建窗口
            push!(
                windows,
                OrbitalLinkWindow(
                    link_type = event.link_type,
                    endpoint_a = event.endpoint_a,
                    endpoint_b = event.endpoint_b,
                    link_up_time_index = up_event.time_index,
                    link_up_elapsed_s = up_event.elapsed_s,
                    link_down_time_index = event.time_index,
                    link_down_elapsed_s = event.elapsed_s,
                ),
            )
            # 移除已匹配的 link_up
            delete!(open_by_link, key)
        else
            throw(ArgumentError("unsupported event_type while summarizing link windows: $(event.event_type)"))
        end
    end

    # 处理剩余的未匹配 link_up（链路在仿真结束时仍保持）
    for up_event in values(open_by_link)
        push!(
            windows,
            OrbitalLinkWindow(
                link_type = up_event.link_type,
                endpoint_a = up_event.endpoint_a,
                endpoint_b = up_event.endpoint_b,
                link_up_time_index = up_event.time_index,
                link_up_elapsed_s = up_event.elapsed_s,
            ),
        )
    end

    # 按建立时间、链路类型、端点信息排序
    sort!(windows, by = window -> (
        window.link_up_elapsed_s,
        String(window.link_type),
        String(window.endpoint_a.kind),
        window.endpoint_a.id,
        String(window.endpoint_b.kind),
        window.endpoint_b.id,
    ))

    return windows
end

"""
    endpoint_label_for_error(endpoint::OrbitalLinkEndpoint) -> String

生成端点的标签字符串，用于错误消息。

# [算法说明]
# 错误标签生成算法：
# 该函数生成人类可读的端点标签，用于错误消息和日志。
#
# 标签格式：
# "kind-id"
# 例如："ground-1"、"satellite-5"
#
# 为什么需要错误标签：
# 1. 可读性：比数字ID更易于理解
# 2. 调试：快速识别问题端点
# 3. 日志：提供有意义的错误信息
#
# 标签设计：
# - 包含类型和ID：提供完整信息
# - 使用短横线分隔：易于阅读
# - 简洁明了：不包含多余信息
#
# 使用场景：
# - 错误消息：提示哪个端点有问题
# - 日志记录：记录操作涉及的端点
# - 调试输出：显示当前处理的端点

参数
- `endpoint::OrbitalLinkEndpoint`：链路端点

返回值
- `String`：格式为 "kind-id" 的标签
"""
function endpoint_label_for_error(endpoint::OrbitalLinkEndpoint)::String
    return "$(endpoint.kind)-$(endpoint.id)"
end

"""
    orbital_events_dict(oef::OrbitalEventsFile) -> Dict{String,Any}

将轨道事件文件转换为字典格式，用于 JSON 序列化。

# [算法说明]
# 轨道事件文件字典转换算法：
# 该函数将OrbitalEventsFile转换为字典格式，便于JSON序列化。
#
# 转换过程：
# 1. 元数据字典：
#    - 基本信息：format, version
#    - 时间网格：epoch, time_system, duration_s, step_s
#    - 精度信息：precision = "seconds"
#    - 合并用户元数据：oef.metadata
#
# 2. 事件列表：
#    - 遍历每个事件，调用event_dict转换
#    - 保持顺序：事件列表保持原始顺序
#
# 元数据设计：
# 包含两部分：
# 1. 系统元数据：由系统生成，包含文件格式和时间信息
# 2. 用户元数据：由用户提供，包含自定义信息
# 使用merge合并，用户元数据可以覆盖系统元数据。
#
# 为什么需要这种结构：
# 1. 自描述性：文件包含完整的解析信息
# 2. 可扩展性：支持自定义元数据
# 3. 向后兼容：版本控制支持未来扩展
#
# JSON结构示例：
# {
#   "metadata": {
#     "format": "SatelliteSimJulia-OEF",
#     "version": "0.1",
#     "epoch": "2024-01-01T00:00:00",
#     "time_system": "TimeUTC",
#     "duration_s": 3600,
#     "step_s": 60,
#     "precision": "seconds",
#     "custom_field": "custom_value"
#   },
#   "events": [...]
# }

参数
- `oef::OrbitalEventsFile`：轨道事件文件

返回值
- `Dict{String,Any}`：包含元数据和事件列表的字典
"""
function orbital_events_dict(oef::OrbitalEventsFile)::Dict{String,Any}
    return Dict{String,Any}(
        "metadata" => merge(
            Dict{String,Any}(
                "format" => oef.format,
                "version" => oef.version,
                "epoch" => string(oef.time_grid.epoch.instant),
                "time_system" => string(oef.time_grid.epoch.system),
                "duration_s" => oef.time_grid.duration_s,
                "step_s" => oef.time_grid.step_s,
                "precision" => "seconds",
            ),
            oef.metadata,
        ),
        "events" => [event_dict(event) for event in oef.events],
    )
end

"""
    write_orbital_events_json(path::AbstractString, oef::OrbitalEventsFile) -> Nothing

将轨道事件文件写入 JSON 文件。

# [算法说明]
# JSON序列化算法：
# 该函数将轨道事件文件序列化为JSON格式。
#
# 序列化流程：
# 1. 转换为字典：调用orbital_events_dict将OrbitalEventsFile转换为Dict
# 2. 写入文件：使用JSON.print以2空格缩进写入
# 3. 添加换行：文件末尾添加换行符
#
# JSON格式设计：
# {
#   "metadata": {...},
#   "events": [
#     {
#       "event_type": "link_up",
#       "link_type": "gsl",
#       "time_index": 1,
#       "time_s": 60,
#       "endpoint_a": {"kind": "ground", "id": 1},
#       "endpoint_b": {"kind": "satellite", "id": 1},
#       "distance_km": 1500.5,
#       "propagation_delay_s": 0.005,
#       "capacity_mbps": 10.0,
#       "attributes": {"elevation_deg": 45.0, "available": true}
#     },
#     ...
#   ]
# }
#
# 为什么选择JSON格式：
# 1. 可读性：人类可读的格式
# 2. 通用性：几乎所有编程语言都支持
# 3. 可扩展：支持嵌套结构和字典
# 4. 标准化：广泛使用的数据交换格式
#
# 写入优化：
# - 使用2空格缩进：平衡可读性和文件大小
# - 一次性写入：避免多次IO操作
# - 添加换行：确保文件符合POSIX标准

参数
- `path::AbstractString`：输出文件路径
- `oef::OrbitalEventsFile`：轨道事件文件

返回值
- `Nothing`
"""
function write_orbital_events_json(path::AbstractString, oef::OrbitalEventsFile)::Nothing
    open(path, "w") do io
        JSON.print(io, orbital_events_dict(oef), 2)
        println(io)
    end
    return nothing
end

"""
    parse_time_system(value::AbstractString) -> TimeSystem

将字符串解析为时间系统枚举。

# [算法说明]
# 时间系统解析算法：
# 该函数将字符串表示的时间系统转换为枚举值。
#
# 支持的时间系统：
# 1. TimeUTC（协调世界时）：
#    - 基于原子时，通过闰秒调整
#    - 最常用的时间系统
#
# 2. TimeTAI（国际原子时）：
#    - 基于原子钟的连续时间
#    - 没有闰秒调整
#
# 3. TimeTT（地球时）：
#    - TAI + 32.184秒
#    - 用于天体力学计算
#
# 4. TimeUT1（世界时1）：
#    - 基于地球自转
#    - 与地球自转角度直接相关
#
# 为什么需要时间系统转换：
# 1. 数据交换：不同系统使用不同时间系统
# 2. 精度要求：不同应用需要不同精度
# 3. 物理意义：不同时间系统有不同的物理意义
#
# 解析方法：
# 使用简单的字符串比较，而不是字典查找。
# 原因：时间系统数量固定，字符串比较更直接。
#
# 错误处理：
# 如果字符串不匹配任何已知时间系统，抛出ArgumentError。
# 这确保了数据的正确性和完整性。

参数
- `value::AbstractString`：时间系统字符串

返回值
- `TimeSystem`：对应的时间系统枚举值

异常
- `ArgumentError`：当字符串不匹配任何已知时间系统时抛出
"""
function parse_time_system(value::AbstractString)::TimeSystem
    value == "TimeUTC" && return TimeUTC
    value == "TimeTAI" && return TimeTAI
    value == "TimeTT" && return TimeTT
    value == "TimeUT1" && return TimeUT1
    throw(ArgumentError("unsupported time system: $value"))
end

"""
    read_endpoint_dict(raw) -> OrbitalLinkEndpoint

从字典中读取端点信息。

# [算法说明]
# 端点字典解析算法：
# 该函数从字典中解析端点信息，重建OrbitalLinkEndpoint对象。
#
# 解析过程：
# 1. 提取kind字段：String → Symbol
#    - "ground" → :ground
#    - "satellite" → :satellite
#
# 2. 提取id字段：Any → Int
#    - 确保类型转换正确
#
# 3. 构造OrbitalLinkEndpoint：
#    - 调用构造函数，自动验证参数
#
# 类型转换：
# - String(raw["kind"])：确保是字符串类型
# - Symbol(...)：转换为Symbol类型
# - Int(raw["id"])：确保是整数类型
#
# 错误处理：
# - 缺失字段：抛出KeyError
# - 类型错误：抛出MethodError或ArgumentError
# - 值无效：OrbitalLinkEndpoint构造函数会验证
#
# 为什么需要这个函数：
# 1. 反序列化：从JSON重建对象
# 2. 数据验证：确保数据格式正确
# 3. 类型安全：确保正确的类型转换

参数
- `raw`：包含端点信息的字典

返回值
- `OrbitalLinkEndpoint`：解析出的端点对象
"""
function read_endpoint_dict(raw)::OrbitalLinkEndpoint
    return OrbitalLinkEndpoint(Symbol(String(raw["kind"])), Int(raw["id"]))
end

"""
    read_orbital_event_dict(raw) -> OrbitalLinkEvent

从字典中读取轨道链路事件。

# [算法说明]
# 事件字典解析算法：
# 该函数从字典中解析轨道链路事件，重建OrbitalLinkEvent对象。
#
# 解析过程：
# 1. 基本信息：
#    - event_type：String → Symbol
#    - link_type：String → Symbol
#    - time_index：Any → Int
#    - elapsed_s：使用"time_s"键，Any → Int
#
# 2. 端点信息：
#    - 调用read_endpoint_dict解析
#
# 3. 物理量：
#    - distance_km, propagation_delay_s, capacity_mbps：Any → Float64
#
# 4. 附加属性：
#    - 调用字典推导式重建Dict{String,Any}
#
# 键名映射：
# JSON中使用"time_s"，但Julia结构体中使用"elapsed_s"，
# 需要进行键名映射。
#
# 类型转换：
# - Symbol(String(...))：确保Symbol类型
# - Int(...)：确保整数类型
# - Float64(...)：确保浮点数类型
#
# 错误处理：
# - 缺失字段：抛出KeyError
# - 类型错误：抛出MethodError
# - 值无效：OrbitalLinkEvent构造函数会验证
#
# 为什么需要这个函数：
# 1. 反序列化：从JSON重建对象
# 2. 数据验证：确保数据格式正确
# 3. 类型安全：确保正确的类型转换

参数
- `raw`：包含事件信息的字典

返回值
- `OrbitalLinkEvent`：解析出的事件对象
"""
function read_orbital_event_dict(raw)::OrbitalLinkEvent
    return OrbitalLinkEvent(
        event_type = Symbol(String(raw["event_type"])),
        link_type = Symbol(String(raw["link_type"])),
        time_index = Int(raw["time_index"]),
        elapsed_s = Int(raw["time_s"]),
        endpoint_a = read_endpoint_dict(raw["endpoint_a"]),
        endpoint_b = read_endpoint_dict(raw["endpoint_b"]),
        distance_km = Float64(raw["distance_km"]),
        propagation_delay_s = Float64(raw["propagation_delay_s"]),
        capacity_mbps = Float64(raw["capacity_mbps"]),
        attributes = Dict{String,Any}(String(key) => value for (key, value) in raw["attributes"]),
    )
end

"""
    read_orbital_events_json(path::AbstractString) -> OrbitalEventsFile

从 JSON 文件读取轨道事件文件。

# [算法说明]
# JSON反序列化算法：
# 该函数从JSON文件读取并重建OrbitalEventsFile对象。
#
# 反序列化流程：
# 1. 读取JSON文件：JSON.parsefile解析为Julia字典
# 2. 提取元数据：获取时间网格和格式信息
# 3. 构造时间网格：
#    - 解析epoch字符串为DateTime
#    - 解析time_system为TimeSystem枚举
#    - 创建SimulationTimeGrid对象
# 4. 解析事件列表：
#    - 遍历每个事件字典
#    - 调用read_orbital_event_dict解析
# 5. 构建OrbitalEventsFile：
#    - 组合时间网格、事件列表、元数据
#
# 错误处理：
# - 文件不存在：JSON.parsefile会抛出异常
# - 格式错误：JSON解析失败
# - 缺失字段：使用默认值或抛出异常
#
# 为什么需要反序列化：
# 1. 数据持久化：从文件加载之前保存的数据
# 2. 数据交换：在不同系统间传输数据
# 3. 分析处理：加载数据进行后处理
#
# 精度保持：
# - 时间精度：DateTime支持毫秒级精度
# - 数值精度：Float64保持双精度
# - 字符串精度：保持原始格式

参数
- `path::AbstractString`：JSON 文件路径

返回值
- `OrbitalEventsFile`：解析出的轨道事件文件对象
"""
function read_orbital_events_json(path::AbstractString)::OrbitalEventsFile
    # 解析 JSON 文件
    raw = JSON.parsefile(path)

    # 提取元数据
    metadata = Dict{String,Any}(String(key) => value for (key, value) in Dict(raw["metadata"]))

    # 构造 epoch
    epoch = SimulationEpoch(
        DateTime(String(metadata["epoch"])),
        parse_time_system(String(metadata["time_system"])),
    )

    # 构造时间网格
    time_grid = SimulationTimeGrid(
        epoch,
        Int(metadata["duration_s"]),
        Int(metadata["step_s"]),
    )

    # 解析事件列表
    events = [read_orbital_event_dict(event) for event in raw["events"]]

    # 获取格式和版本（使用默认值如果不存在）
    format = String(get(metadata, "format", "SatelliteSimJulia-OEF"))
    version = String(get(metadata, "version", "0.1"))

    return OrbitalEventsFile(time_grid, events; format = format, version = version, metadata = metadata)
end

"""
    samples_changed(previous::GSLPhysicalLinkSample, current::GSLPhysicalLinkSample) -> Bool

判断两个 GSL 物理链路样本的关键参数是否发生变化。

# [算法说明]
# 变化检测算法：
# 该函数判断两个链路样本的关键参数是否发生变化。
#
# 检测参数：
# 1. distance_km：两端点距离（影响传播延迟）
# 2. propagation_delay_s：传播延迟（影响时延敏感应用）
# 3. capacity_mbps：链路容量（影响吞吐量）
# 4. elevation_deg：仰角（影响信号质量）
#
# 为什么检测这些参数：
# 1. 距离变化：影响传播延迟和信号强度
# 2. 容量变化：影响可用带宽
# 3. 仰角变化：影响信号质量和多普勒效应
# 4. 延迟变化：影响时延敏感应用
#
# 为什么需要变化检测：
# 1. 避免重复事件：只有真正变化时才生成事件
# 2. 减少事件数量：压缩事件序列
# 3. 性能优化：避免不必要的事件处理
#
# 比较方法：
# 使用简单的相等比较（!=），而不是阈值比较。
# 原因：链路参数通常是精确计算的，变化应该是精确的。
#
# 与其他方法的比较：
# - 阈值比较：|a - b| > ε
# - 相等比较：a != b
# 本实现使用相等比较，因为链路参数是精确计算的。

参数
- `previous::GSLPhysicalLinkSample`：前一个样本
- `current::GSLPhysicalLinkSample`：当前样本

返回值
- `Bool`：如果距离、传播时延、容量或仰角任一发生变化则返回 true
"""
function samples_changed(previous::GSLPhysicalLinkSample, current::GSLPhysicalLinkSample)::Bool
    return previous.distance_km != current.distance_km ||
        previous.propagation_delay_s != current.propagation_delay_s ||
        previous.capacity_mbps != current.capacity_mbps ||
        previous.elevation_deg != current.elevation_deg
end

"""
    event_type_for_transition(
        previous::Union{Nothing,GSLPhysicalLinkSample},
        current::GSLPhysicalLinkSample,
    ) -> Union{Nothing,Symbol}

根据链路状态变化确定事件类型。

# [算法说明]
# 状态转换检测算法：
# 该函数实现简单的状态机，检测链路状态变化。
#
# 状态定义：
# - 状态0：链路不可用（is_available = false）
# - 状态1：链路可用（is_available = true）
#
# 转换规则：
# 1. 初始状态（previous = nothing）：
#    - 如果当前可用：返回link_up（建立事件）
#    - 如果当前不可用：返回nothing（无事件）
#
# 2. 从状态0到状态1：
#    - 触发条件：!previous_available && current_available
#    - 返回：link_up
#
# 3. 从状态1到状态0：
#    - 触发条件：previous_available && !current_available
#    - 返回：link_down
#
# 4. 状态不变：
#    - 返回nothing（无事件）
#
# 为什么这样设计：
# 1. 简单明了：只有四种可能情况
# 2. 无歧义：每种情况有明确返回值
# 3. 易于扩展：可以添加更多状态和转换规则
#
# 与其他方法的比较：
# - 差分法：比较相邻样本的可用性标志
# - 状态机法：维护状态，检测转换
# 本实现使用状态机法，更清晰和可维护。

参数
- `previous::Union{Nothing,GSLPhysicalLinkSample}`：前一个样本（如果是起始点则为 nothing）
- `current::GSLPhysicalLinkSample`：当前样本

返回值
- `Union{Nothing,Symbol}`：
  - 如果链路从不可用变为可用，返回 `:link_up`
  - 如果链路从可用变为不可用，返回 `:link_down`
  - 如果状态未变化，返回 `nothing`
  - 如果是起始点且链路可用，返回 `:link_up`
"""
function event_type_for_transition(
    previous::Union{Nothing,GSLPhysicalLinkSample},
    current::GSLPhysicalLinkSample,
)::Union{Nothing,Symbol}
    # 判断当前链路是否可用
    current_available = is_available(current)

    # 如果是第一个样本
    if previous === nothing
        return current_available ? :link_up : nothing
    end

    # 判断前一个链路是否可用
    previous_available = is_available(previous)

    # 根据状态变化确定事件类型
    if !previous_available && current_available
        return :link_up
    elseif previous_available && !current_available
        return :link_down
    end

    return nothing
end

"""
    gsl_event(event_type::Symbol, sample::GSLPhysicalLinkSample) -> OrbitalLinkEvent

从 GSL 物理链路样本创建轨道链路事件。

# [算法说明]
# 事件创建算法：
# 该函数将链路样本转换为标准化的事件格式。
#
# 数据映射：
# 1. 基本信息：
#    - event_type → 事件类型（link_up/link_down）
#    - link_type → 固定为:gsl
#    - time_index, elapsed_s → 时间信息
#
# 2. 端点信息：
#    - ground_id → OrbitalLinkEndpoint(:ground, id)
#    - satellite_id → OrbitalLinkEndpoint(:satellite, id)
#
# 3. 物理量：
#    - distance_km → 两端点距离
#    - propagation_delay_s → 传播延迟
#    - capacity_mbps → 链路容量
#
# 4. 附加属性：
#    - elevation_deg → 仰角（重要参数）
#    - available → 可用性标志
#
# 为什么需要这个转换：
# 1. 标准化：统一不同来源的事件格式
# 2. 序列化：便于存储和传输
# 3. 分析：提供标准化的数据结构
#
# 属性字典设计：
# 使用Dict存储额外属性，优点：
# - 灵活性：可以添加任意属性
# - 可扩展：不影响主要结构
# - 易于序列化：JSON格式支持

参数
- `event_type::Symbol`：事件类型
- `sample::GSLPhysicalLinkSample`：链路样本

返回值
- `OrbitalLinkEvent`：创建的轨道链路事件
"""
function gsl_event(event_type::Symbol, sample::GSLPhysicalLinkSample)::OrbitalLinkEvent
    return OrbitalLinkEvent(
        event_type = event_type,
        link_type = :gsl,
        time_index = sample.time_index,
        elapsed_s = sample.elapsed_s,
        endpoint_a = OrbitalLinkEndpoint(:ground, sample.ground_id),
        endpoint_b = OrbitalLinkEndpoint(:satellite, sample.satellite_id),
        distance_km = sample.distance_km,
        propagation_delay_s = sample.propagation_delay_s,
        capacity_mbps = sample.capacity_mbps,
        attributes = Dict{String,Any}(
            "elevation_deg" => sample.elevation_deg,
            "available" => is_available(sample),
        ),
    )
end

"""
    generate_gsl_orbital_events(series::GSLPhysicalLinkSeries) -> Vector{OrbitalLinkEvent}

从单个 GSL 物理链路序列生成轨道事件。

# [算法说明]
# GSL链路事件生成算法：
# 该算法将连续的链路采样序列转换为离散的状态变化事件。
#
# 算法流程：
# 1. 初始化：创建字典previous_by_satellite，记录每颗卫星的前一个样本
# 2. 遍历时间网格：对每个时间片，处理该时间片的所有链路样本
# 3. 状态检测：比较当前样本与前一个样本的状态
# 4. 事件生成：根据状态变化生成link_up或link_down事件
# 5. 状态更新：将当前样本记录为下一次比较的前一个样本
#
# 状态检测逻辑：
# - 初始状态：第一颗卫星的第一个样本，如果可用则生成link_up
# - 状态变化：从不可用变为可用 → link_up；从可用变为不可用 → link_down
# - 状态不变：不生成事件（或生成link_update事件）
#
# 数据结构设计：
# - 使用字典跟踪每颗卫星的前一个样本：O(1)查找时间复杂度
# - 事件生成是O(1)操作：只需比较和记录
# - 最终事件列表按时间顺序生成：因为遍历时间网格是顺序的
#
# 为什么需要这个算法：
# 1. 网络层需要知道链路何时可用/不可用
# 2. 事件序列比连续采样更紧凑：只记录状态变化时刻
# 3. 便于后续链路窗口汇总：事件序列是窗口算法的输入
#
# 时间复杂度分析：
# - 时间片数量：T
# - 每时间片卫星数量：S
# - 总操作：O(T × S)
# - 字典操作：O(1)平均情况
# - 总时间复杂度：O(T × S)

算法：
1. 遍历时间网格中的每个时间片
2. 对于每个时间片，获取所有卫星的链路样本
3. 与前一个样本比较，检测状态变化
4. 根据状态变化生成 link_up 或 link_down 事件

参数
- `series::GSLPhysicalLinkSeries`：GSL 物理链路序列

返回值
- `Vector{OrbitalLinkEvent}`：生成的轨道事件列表
"""
function generate_gsl_orbital_events(series::GSLPhysicalLinkSeries)::Vector{OrbitalLinkEvent}
    # 跟踪每颗卫星的前一个样本
    previous_by_satellite = Dict{Int,GSLPhysicalLinkSample}()

    # 收集事件
    events = OrbitalLinkEvent[]

    # 遍历时间网格中的每个时间片
    for time_index in 1:time_count(series.time_grid)
        # 获取该时间片的所有链路样本
        for sample in gsl_samples_at(series, time_index)
            # 获取该卫星的前一个样本
            previous = get(previous_by_satellite, sample.satellite_id, nothing)

            # 确定事件类型
            event_type = event_type_for_transition(previous, sample)

            # 如果有状态变化，创建事件
            if event_type !== nothing
                push!(events, gsl_event(event_type, sample))
            end

            # 更新前一个样本
            previous_by_satellite[sample.satellite_id] = sample
        end
    end

    return events
end

"""
    generate_gsl_orbital_events(series_by_ground::Vector{GSLPhysicalLinkSeries}) -> Vector{OrbitalLinkEvent}

从多个地面站的 GSL 物理链路序列生成轨道事件。

# [算法说明]
# 多地面站事件生成算法：
# 该算法将多个地面站的链路序列合并为统一的事件列表。
#
# 算法流程：
# 1. 验证输入：
#    - 检查输入非空
#    - 验证所有序列共享同一时间网格
#    - 确保地面站ID唯一
#
# 2. 处理每个地面站：
#    - 调用单地面站事件生成函数
#    - 将生成的事件添加到总列表
#
# 3. 合并和排序：
#    - 合并所有事件
#    - 按时间排序（elapsed_s, endpoint_a.id, endpoint_b.id, event_type）
#
# 为什么需要多地面站支持：
# 1. 星座仿真通常包含多个地面站
# 2. 不同地面站可能同时与多颗卫星建立链路
# 3. 需要统一管理所有链路事件
#
# 时间网格一致性验证：
# 所有地面站的链路序列必须使用相同的时间网格，
# 因为事件时间必须与网格对齐，否则无法正确合并。
#
# 地面站ID唯一性：
# 确保每个地面站只处理一次，避免重复事件。
#
# 排序策略：
# 按(elapsed_s, endpoint_a.id, endpoint_b.id, event_type)排序，
# 确保：①时间顺序；②相同时间按端点排序；③link_up在link_down之前处理。

参数
- `series_by_ground::Vector{GSLPhysicalLinkSeries}`：多个地面站的链路序列列表

返回值
- `Vector{OrbitalLinkEvent}`：所有轨道事件的列表，按时间排序

异常
- `ArgumentError`：当输入为空、时间网格不一致或地面站 ID 重复时抛出
"""
function generate_gsl_orbital_events(series_by_ground::Vector{GSLPhysicalLinkSeries})::Vector{OrbitalLinkEvent}
    # 验证输入非空
    isempty(series_by_ground) && throw(ArgumentError("series_by_ground must not be empty"))

    # 获取共享的时间网格
    time_grid = first(series_by_ground).time_grid

    # 收集所有事件
    events = OrbitalLinkEvent[]

    # 跟踪已处理的地面站 ID，确保唯一性
    ground_ids = Set{Int}()

    # 处理每个地面站的链路序列
    for series in series_by_ground
        # 验证时间网格一致
        series.time_grid === time_grid ||
            throw(ArgumentError("all GSL series must share the same time_grid object"))

        # 验证地面站 ID 唯一
        series.ground_id in ground_ids &&
            throw(ArgumentError("ground_id must be unique when generating GSL orbital events"))
        push!(ground_ids, series.ground_id)

        # 生成该地面站的事件并添加到列表
        append!(events, generate_gsl_orbital_events(series))
    end

    # 按时间排序事件
    sort!(events, by = event -> (event.elapsed_s, event.endpoint_a.id, event.endpoint_b.id, String(event.event_type)))

    return events
end

"""
    generate_gsl_oef(
        series_by_ground::Vector{GSLPhysicalLinkSeries};
        metadata::Dict{String,Any} = Dict{String,Any}(),
    ) -> OrbitalEventsFile

从多个地面站的 GSL 物理链路序列生成轨道事件文件。

# [算法说明]
# 轨道事件文件生成算法：
# 该函数将多个地面站的链路序列转换为标准事件文件格式。
#
# 算法流程：
# 1. 验证输入：
#    - 检查输入非空
#    - 确保所有序列共享同一时间网格
#
# 2. 生成事件：
#    - 调用generate_gsl_orbital_events生成事件列表
#    - 事件已按时间排序
#
# 3. 构建事件文件：
#    - 创建OrbitalEventsFile
#    - 添加元数据（link_scope = "gsl"）
#    - 包含时间网格和事件列表
#
# 元数据设计：
# 包含在元数据中的信息：
# - link_scope: "gsl"（标识链路范围）
# - 其他用户提供的元数据
#
# 为什么需要这个函数：
# 1. 标准化输出：生成标准格式的事件文件
# 2. 序列化：便于存储和传输
# 3. 可读性：JSON格式易于人类阅读
# 4. 可扩展：支持自定义元数据
#
# 输出格式：
# OrbitalEventsFile包含：
# - format: 文件格式标识
# - version: 版本号
# - time_grid: 时间网格定义
# - events: 事件列表
# - metadata: 元数据字典

参数
- `series_by_ground::Vector{GSLPhysicalLinkSeries}`：多个地面站的链路序列列表
- `metadata::Dict{String,Any}`：附加元数据，默认为空字典

返回值
- `OrbitalEventsFile`：生成的轨道事件文件
"""
function generate_gsl_oef(
    series_by_ground::Vector{GSLPhysicalLinkSeries};
    metadata::Dict{String,Any} = Dict{String,Any}(),
)::OrbitalEventsFile
    # 验证输入非空
    isempty(series_by_ground) && throw(ArgumentError("series_by_ground must not be empty"))

    # 获取共享的时间网格
    time_grid = first(series_by_ground).time_grid

    # 生成轨道事件文件
    return OrbitalEventsFile(
        time_grid,
        generate_gsl_orbital_events(series_by_ground);
        metadata = merge(Dict{String,Any}("link_scope" => "gsl"), metadata),
    )
end

"""
    generate_gsl_oef(
        series::GSLPhysicalLinkSeries;
        metadata::Dict{String,Any} = Dict{String,Any}(),
    ) -> OrbitalEventsFile

从单个地面站的 GSL 物理链路序列生成轨道事件文件（便捷方法）。

# 参数
- `series::GSLPhysicalLinkSeries`：单个地面站的链路序列
- `metadata::Dict{String,Any}`：附加元数据，默认为空字典

# 返回值
- `OrbitalEventsFile`：生成的轨道事件文件
"""
function generate_gsl_oef(
    series::GSLPhysicalLinkSeries;
    metadata::Dict{String,Any} = Dict{String,Any}(),
)::OrbitalEventsFile
    return generate_gsl_oef([series]; metadata = metadata)
end