"""
    states

卫星运行状态模块。

本文件定义了卫星仿真运行时的各种状态数据结构，包括：
- 卫星运行状态（卫星 ID、状态类型、电源、通信）
- 卫星状态表（管理多颗卫星的状态）
- 电源状态（电池容量、存储能量、太阳能发电、负载）
- 通信尾状态（各通信类型的队列长度）

这些状态用于模拟卫星在仿真过程中的动态变化。

# [算法说明]
# PowerState电池模型：
# 这是一个简化的卫星电源系统模型，包含以下组件：
# 1. 电池容量（battery_capacity_wh）：最大存储能量，单位瓦时；
# 2. 存储能量（stored_energy_wh）：当前电池剩余能量；
# 3. 太阳能发电功率（solar_generation_w）：太阳能板输出功率；
# 4. 负载功率：包括基础负载、有效载荷负载、通信负载。
#
# 电池充放电模型：
# - 充电：stored_energy += solar_generation * Δt
# - 放电：stored_energy -= (base_load + payload_load + communication_load) * Δt
# - 约束：0 ≤ stored_energy ≤ battery_capacity
#
# 为什么需要这个模型：
# 1. 电源状态影响卫星功能：低电量可能导致卫星降级或离线；
# 2. 太阳能发电受地影影响：in_eclipse标志表示卫星是否在地球阴影中；
# 3. 负载平衡：通信负载与数据传输需求相关。
#
# SatelliteRuntimeState组成：
# 这是一个复合状态结构，包含三个子状态：
# 1. 卫星运行状态（SatelliteOperationalStatus）：正常、降级、离线、故障；
# 2. 电源状态（PowerState）：能源系统状态；
# 3. 通信尾状态（CommunicationTailState）：通信队列状态。
#
# 为什么使用组合模式：
# 1. 关注点分离：每个子状态独立管理，降低复杂度；
# 2. 灵活更新：可以单独更新电源状态而不影响通信状态；
# 3. 模拟真实卫星：真实卫星也是由多个子系统组成的。
"""

"""
    SatelliteOperationalStatus

卫星运行状态枚举。

# [算法说明]
# 卫星运行状态模型：
# 定义卫星的四种运行状态，表示卫星的功能完整性。
#
# 状态含义：
# 1. SatelliteNominal（正常）：
#    - 所有系统正常运行
#    - 完全可用，可执行所有任务
#    - 功耗正常，性能达标
#
# 2. SatelliteDegraded（降级）：
#    - 部分系统故障或性能下降
#    - 部分功能可用（如通信正常但载荷受限）
#    - 可能由于硬件故障、软件错误或资源不足
#
# 3. SatelliteOffline（离线）：
#    - 卫星暂时不可用
#    - 可能正在维护、重启或进入安全模式
#    - 可能通过地面指令恢复
#
# 4. SatelliteFailed（故障）：
#    - 卫星永久不可用
#    - 关键系统故障，无法恢复
#    - 需要退役或替换
#
# 状态转换：
# 正常 → 降级 → 离线 → 故障
# 故障 → 降级/正常（如果修复成功）
#
# 为什么需要状态枚举：
# 1. 标准化：统一表示卫星状态
# 2. 决策依据：影响路由和资源分配
# 3. 监控管理：跟踪卫星健康状态
# 4. 仿真建模：模拟真实卫星行为
#
# 与真实卫星的对应：
# - 正常：所有载荷和通信系统工作
# - 降级：部分载荷故障，但通信正常
# - 离线：进入安全模式，等待指令
# - 故障：永久失效，需要退役

状态类型
- `SatelliteNominal`：正常运行状态
- `SatelliteDegraded`：降级运行状态（部分功能受限）
- `SatelliteOffline`：离线状态（暂时不可用）
- `SatelliteFailed`：故障状态（永久不可用）
"""
@enum SatelliteOperationalStatus begin
    SatelliteNominal      # 正常运行
    SatelliteDegraded     # 降级运行
    SatelliteOffline      # 离线状态
    SatelliteFailed       # 故障状态
end

"""
    PowerState

卫星电源状态，描述卫星的能源系统状态。

# [算法说明]
# 电源系统模型：
# 卫星电源系统由太阳能板和电池组成，工作原理：
# 1. 充电阶段（光照期）：太阳能板发电，为负载供电并为电池充电
# 2. 放电阶段（阴影期）：电池放电，为负载供电
#
# 能量平衡方程：
# ΔE = (solar_generation - total_load) * Δt
# 其中：
# - ΔE：存储能量变化
# - solar_generation：太阳能发电功率（阴影期为0）
# - total_load = base_load + payload_load + communication_load
# - Δt：时间步长
#
# 约束条件：
# 1. 0 ≤ stored_energy ≤ battery_capacity（电池容量限制）
# 2. 所有功率值 ≥ 0（物理约束）
# 3. solar_generation = 0 当 in_eclipse = true（阴影期无太阳能）
#
# 地影判断（in_eclipse）：
# 卫星是否在地球阴影中取决于：①卫星轨道位置；②太阳方向；③地球半径。
# 简化模型：当卫星-太阳矢量与地球-卫星矢量夹角小于阈值时，认为在阴影中。
#
# 电池模型简化：
# - 线性充放电：假设效率100%
# - 无老化效应：电池容量恒定
# - 无温度影响：忽略温度对性能的影响
# - 无自放电：忽略电池自放电
#
# 实际应用考虑：
# 1. 充放电效率：通常80-90%
# 2. 电池老化：容量随循环次数下降
# 3. 温度影响：低温降低容量
# 4. 自放电：每月损失1-2%

字段
- `battery_capacity_wh::Float64`：电池总容量（瓦时，Wh）
- `stored_energy_wh::Float64`：当前存储能量（瓦时，Wh）
- `solar_generation_w::Float64`：太阳能发电功率（瓦，W）
- `base_load_w::Float64`：基础负载功率（瓦，W）
- `payload_load_w::Float64`：有效载荷负载功率（瓦，W）
- `communication_load_w::Float64`：通信负载功率（瓦，W）
- `in_eclipse::Bool`：是否处于地影区

构造参数
- `battery_capacity_wh::Real`：电池容量，默认为 0
- `stored_energy_wh::Real`：存储能量，默认为 0
- `solar_generation_w::Real`：太阳能发电功率，默认为 0
- `base_load_w::Real`：基础负载，默认为 0
- `payload_load_w::Real`：有效载荷负载，默认为 0
- `communication_load_w::Real`：通信负载，默认为 0
- `in_eclipse::Bool`：是否在地影区，默认为 false

约束条件
- 存储能量不能超过电池容量
- 所有能量和功率值必须非负

异常
- `ArgumentError`：当参数违反约束条件时抛出
"""
struct PowerState
    battery_capacity_wh::Float64
    stored_energy_wh::Float64
    solar_generation_w::Float64
    base_load_w::Float64
    payload_load_w::Float64
    communication_load_w::Float64
    in_eclipse::Bool

    function PowerState(;
        battery_capacity_wh::Real = 0,
        stored_energy_wh::Real = 0,
        solar_generation_w::Real = 0,
        base_load_w::Real = 0,
        payload_load_w::Real = 0,
        communication_load_w::Real = 0,
        in_eclipse::Bool = false,
    )
        # 验证电池容量非负
        battery_capacity_wh >= 0 || throw(ArgumentError("battery_capacity_wh must be non-negative"))
        # 验证存储能量非负
        stored_energy_wh >= 0 || throw(ArgumentError("stored_energy_wh must be non-negative"))
        # 验证存储能量不超过电池容量
        stored_energy_wh <= battery_capacity_wh ||
            throw(ArgumentError("stored_energy_wh must not exceed battery_capacity_wh"))
        # 验证太阳能发电功率非负
        solar_generation_w >= 0 || throw(ArgumentError("solar_generation_w must be non-negative"))
        # 验证基础负载非负
        base_load_w >= 0 || throw(ArgumentError("base_load_w must be non-negative"))
        # 验证有效载荷负载非负
        payload_load_w >= 0 || throw(ArgumentError("payload_load_w must be non-negative"))
        # 验证通信负载非负
        communication_load_w >= 0 || throw(ArgumentError("communication_load_w must be non-negative"))

        # 转换为 Float64 类型
        return new(
            Float64(battery_capacity_wh),
            Float64(stored_energy_wh),
            Float64(solar_generation_w),
            Float64(base_load_w),
            Float64(payload_load_w),
            Float64(communication_load_w),
            in_eclipse,
        )
    end
end

"""
    CommunicationTailState

通信尾状态，描述卫星通信队列中的待处理数据量。

# [算法说明]
# 通信队列模型：
# 卫星通信系统包含四个队列，分别处理不同方向的数据流：
# 1. 下行链路队列（downlink）：卫星→地面站的数据
# 2. 上行链路队列（uplink）：地面站→卫星的数据
# 3. 星间链路发送队列（isl_sender）：卫星→其他卫星的数据
# 4. 星间链路接收队列（isl_receiver）：其他卫星→卫星的数据
#
# "尾"值的物理意义：
# 尾值表示由于链路容量限制而积压在队列中的数据包数量。
# 例如：当下行链路容量为10Mbps，但数据生成速率为15Mbps时，
# 每秒会积压5Mbps的数据，形成队列尾部。
#
# 为什么需要这个模型：
# 1. 延迟计算：队列长度直接影响传输延迟
# 2. 资源分配：帮助决定如何分配有限的通信资源
# 3. 性能评估：评估网络吞吐量和延迟性能
# 4. 流量工程：优化路由和资源分配策略
#
# 队列动力学：
# - 入队：新数据包到达，队列长度增加
# - 出队：数据包被发送，队列长度减少
# - 约束：队列长度不能为负（不能发送不存在的数据）
# - 稳态：当入队速率=出队速率时，队列长度稳定
#
# 队列管理策略：
# 1. FIFO：先进先出，简单公平
# 2. 优先级队列：高优先级数据先处理
# 3. 加权公平队列：按权重分配带宽
# 本模型假设使用FIFO策略。

这些"尾"值表示在流量处理模型中，由于链路容量限制而积压在队列中的数据包数量。

字段
- `downlink_tail_remaining::Int`：下行链路队列中剩余的数据包数
- `uplink_tail_remaining::Int`：上行链路队列中剩余的数据包数
- `isl_sender_tail_remaining::Int`：星间链路发送队列中剩余的数据包数
- `isl_receiver_tail_remaining::Int`：星间链路接收队列中剩余的数据包数

构造参数
- `downlink_tail_remaining::Int`：下行队列剩余，默认为 0
- `uplink_tail_remaining::Int`：上行队列剩余，默认为 0
- `isl_sender_tail_remaining::Int`：星间链路发送队列剩余，默认为 0
- `isl_receiver_tail_remaining::Int`：星间链路接收队列剩余，默认为 0

约束条件
- 所有队列值必须非负

异常
- `ArgumentError`：当任一队列值为负数时抛出
"""
struct CommunicationTailState
    downlink_tail_remaining::Int
    uplink_tail_remaining::Int
    isl_sender_tail_remaining::Int
    isl_receiver_tail_remaining::Int

    function CommunicationTailState(;
        downlink_tail_remaining::Int = 0,
        uplink_tail_remaining::Int = 0,
        isl_sender_tail_remaining::Int = 0,
        isl_receiver_tail_remaining::Int = 0,
    )
        # 验证所有队列值非负
        downlink_tail_remaining >= 0 || throw(ArgumentError("downlink_tail_remaining must be non-negative"))
        uplink_tail_remaining >= 0 || throw(ArgumentError("uplink_tail_remaining must be non-negative"))
        isl_sender_tail_remaining >= 0 ||
            throw(ArgumentError("isl_sender_tail_remaining must be non-negative"))
        isl_receiver_tail_remaining >= 0 ||
            throw(ArgumentError("isl_receiver_tail_remaining must be non-negative"))

        return new(
            downlink_tail_remaining,
            uplink_tail_remaining,
            isl_sender_tail_remaining,
            isl_receiver_tail_remaining,
        )
    end
end

"""
    SatelliteRuntimeState

卫星运行时状态，表示单颗卫星在仿真某一时刻的完整状态。

# [算法说明]
# 卫星状态组成模型：
# SatelliteRuntimeState采用组合模式，包含三个独立子状态：
# 1. 运行状态（SatelliteOperationalStatus）：卫星整体功能状态
#    - SatelliteNominal：正常运行，所有功能正常
#    - SatelliteDegraded：降级运行，部分功能受限（如通信能力下降）
#    - SatelliteOffline：离线状态，暂时不可用（如维护模式）
#    - SatelliteFailed：故障状态，永久不可用
#
# 2. 电源状态（PowerState）：能源系统状态
#    影响因素：电池电量、太阳能发电、负载需求
#    影响范围：影响所有子系统的可用性
#
# 3. 通信尾状态（CommunicationTailState）：通信队列状态
#    影响因素：链路容量、数据流量、处理能力
#    影响范围：影响数据传输延迟和吞吐量
#
# 状态转换逻辑：
# 1. 正常 → 降级：当电源不足或通信队列过长时
# 2. 降级 → 离线：当关键系统故障时
# 3. 离线 → 故障：当故障不可恢复时
# 4. 故障 → 降级/正常：当修复完成时（可选）
#
# 为什么使用这种结构：
# 1. 模块化：每个子状态独立管理，降低复杂度
# 2. 灵活性：可以单独更新电源状态而不影响通信状态
# 3. 可扩展：未来可以添加新的子系统状态
# 4. 仿真真实：真实卫星也是由多个独立子系统组成的
#
# 组合模式的好处：
# - 单一职责：每个子状态只管理一个方面
# - 松耦合：子状态之间没有直接依赖
# - 易测试：每个子状态可以独立测试
# - 可复用：子状态可以在其他上下文中使用

字段
- `satellite_id::Int`：卫星 ID（从 1 开始）
- `status::SatelliteOperationalStatus`：运行状态
- `power::PowerState`：电源状态
- `communication::CommunicationTailState`：通信尾状态

构造参数
- `satellite_id::Int`：卫星 ID（必须为正整数）
- `status::SatelliteOperationalStatus`：运行状态，默认为 SatelliteNominal
- `power::PowerState`：电源状态，默认为空 PowerState
- `communication::CommunicationTailState`：通信尾状态，默认为空 CommunicationTailState

异常
- `ArgumentError`：当 satellite_id 不是正整数时抛出
"""
struct SatelliteRuntimeState
    satellite_id::Int
    status::SatelliteOperationalStatus
    power::PowerState
    communication::CommunicationTailState

    function SatelliteRuntimeState(;
        satellite_id::Int,
        status::SatelliteOperationalStatus = SatelliteNominal,
        power::PowerState = PowerState(),
        communication::CommunicationTailState = CommunicationTailState(),
    )
        # 验证卫星 ID 为正整数
        satellite_id > 0 || throw(ArgumentError("satellite_id must be positive"))
        return new(satellite_id, status, power, communication)
    end
end

"""
    SatelliteStateTable

卫星状态表，管理整个星座中所有卫星的运行状态。

# [算法说明]
# 卫星状态表设计原理：
# 这是一个管理多颗卫星状态的数据结构，设计目标：
# 1. 高效访问：O(1)时间复杂度获取任意卫星状态
# 2. 内存紧凑：连续存储，利于缓存预取
# 3. 语义清晰：直接通过satellite_id索引
#
# 索引规则：
# states[i] 对应 satellite_id = i
# 这个约定确保：①O(1)访问；②避免查找表；③简化代码
#
# 为什么需要这种结构：
# 1. 状态管理：统一管理所有卫星的状态，避免分散存储
# 2. 批量更新：可以高效地更新整个星座的状态
# 3. 状态查询：快速查询任意卫星的状态
# 4. 状态验证：确保状态一致性和完整性
#
# 内存布局：
# [sat1_state, sat2_state, sat3_state, ..., satN_state]
# 这种布局使得按satellite_id访问是O(1)操作。
#
# 与字典的比较：
# - 字典：O(1)平均情况，但有哈希开销
# - 向量：O(1)最坏情况，内存连续，缓存友好
# 对于卫星仿真，向量更合适，因为satellite_id是连续的整数。
#
# 设计模式：
# - 管理器模式：集中管理所有卫星状态
# - 索引约定：确保高效访问
# - 验证机制：保证数据一致性

索引规则：向量中的索引位置必须与 satellite_id 一致（即 states[i] 对应 satellite_id = i）

字段
- `states::Vector{SatelliteRuntimeState}`：卫星状态向量

构造方法

## 从状态向量构造
- 输入包含至少一个 SatelliteRuntimeState 的向量
- 验证每个状态的 satellite_id 与其索引位置匹配

## 从卫星数量构造
- 指定卫星数量，所有卫星使用相同的状态参数

## 从星座构造
- 从 Constellation 对象获取卫星数量，使用相同的状态参数

异常
- `ArgumentError`：当状态表为空或索引不匹配时抛出
"""
struct SatelliteStateTable
    states::Vector{SatelliteRuntimeState}

    function SatelliteStateTable(states::Vector{SatelliteRuntimeState})
        # 验证状态表非空
        !isempty(states) || throw(ArgumentError("SatelliteStateTable must contain at least one state"))

        # 验证每个状态的 satellite_id 与索引位置匹配
        for (index, state) in pairs(states)
            state.satellite_id == index ||
                throw(ArgumentError("state vector index must match satellite_id"))
        end

        return new(states)
    end
end

"""
    SatelliteStateTable(
        satellite_count::Int;
        status::SatelliteOperationalStatus = SatelliteNominal,
        power::PowerState = PowerState(),
        communication::CommunicationTailState = CommunicationTailState(),
    ) -> SatelliteStateTable

从卫星数量创建状态表，所有卫星使用相同的初始状态。

# [算法说明]
# 批量创建算法：
# 该函数根据卫星数量批量创建状态表，所有卫星使用相同初始状态。
#
# 创建过程：
# 1. 验证卫星数量：必须为正整数
# 2. 循环创建：为每颗卫星创建SatelliteRuntimeState
# 3. 构建状态表：调用SatelliteStateTable构造函数
#
# 为什么需要这个函数：
# 1. 便捷性：一次性创建整个星座的状态
# 2. 一致性：确保所有卫星初始状态相同
# 3. 简化初始化：避免手动循环创建
#
# 默认状态：
# - status：SatelliteNominal（正常）
# - power：空PowerState（无能量）
# - communication：空CommunicationTailState（无队列）
#
# 使用场景：
# - 仿真初始化：创建星座初始状态
# - 测试：创建测试数据
# - 配置：根据配置文件初始化状态
#
# 与其他方法的比较：
# - 手动循环：需要编写循环代码
# - 本函数：提供简洁的接口
# 更易于使用和维护。

参数
- `satellite_count::Int`：卫星数量（必须为正整数）
- `status::SatelliteOperationalStatus`：运行状态，默认为 SatelliteNominal
- `power::PowerState`：电源状态，默认为空 PowerState
- `communication::CommunicationTailState`：通信尾状态，默认为空 CommunicationTailState

返回值
- `SatelliteStateTable`：包含指定数量卫星的状态表

异常
- `ArgumentError`：当 satellite_count 不是正整数时抛出
"""
function SatelliteStateTable(
    satellite_count::Int;
    status::SatelliteOperationalStatus = SatelliteNominal,
    power::PowerState = PowerState(),
    communication::CommunicationTailState = CommunicationTailState(),
)::SatelliteStateTable
    # 验证卫星数量为正整数
    satellite_count > 0 || throw(ArgumentError("satellite_count must be positive"))

    # 为每颗卫星创建相同的状态
    states = [
        SatelliteRuntimeState(
            satellite_id = satellite_id,
            status = status,
            power = power,
            communication = communication,
        ) for satellite_id in 1:satellite_count
    ]

    return SatelliteStateTable(states)
end

"""
    SatelliteStateTable(
        constellation::Constellation;
        status::SatelliteOperationalStatus = SatelliteNominal,
        power::PowerState = PowerState(),
        communication::CommunicationTailState = CommunicationTailState(),
    ) -> SatelliteStateTable

从星座对象创建状态表。

# [算法说明]
# 星座状态表创建：
# 该函数从Constellation对象创建状态表，自动获取卫星数量。
#
# 创建过程：
# 1. 获取卫星数量：调用satellite_count(constellation)
# 2. 调用批量创建：使用satellite_count版本的构造函数
# 3. 返回状态表：包含所有卫星的初始状态
#
# 为什么需要这个函数：
# 1. 便捷性：直接使用Constellation对象，无需手动获取数量
# 2. 一致性：确保状态表与星座匹配
# 3. 类型安全：确保使用正确的星座对象
#
# 依赖关系：
# - satellite_count(constellation)：获取星座卫星数量
# - SatelliteStateTable(satellite_count)：批量创建状态表
#
# 使用场景：
# - 仿真初始化：根据星座配置创建状态
# - 星座扩展：新星座创建初始状态
# - 测试：使用测试星座创建状态
#
# 与其他方法的比较：
# - 手动指定数量：需要知道卫星数量
# - 本函数：自动从星座获取数量
# 更安全和便捷。

参数
- `constellation::Constellation`：星座对象
- `status::SatelliteOperationalStatus`：运行状态，默认为 SatelliteNominal
- `power::PowerState`：电源状态，默认为空 PowerState
- `communication::CommunicationTailState`：通信尾状态，默认为空 CommunicationTailState

返回值
- `SatelliteStateTable`：包含星座中所有卫星的状态表
"""
function SatelliteStateTable(
    constellation::Constellation;
    status::SatelliteOperationalStatus = SatelliteNominal,
    power::PowerState = PowerState(),
    communication::CommunicationTailState = CommunicationTailState(),
)::SatelliteStateTable
    return SatelliteStateTable(
        satellite_count(constellation);
        status = status,
        power = power,
        communication = communication,
    )
end

"""
    Base.length(table::SatelliteStateTable) -> Int

获取状态表中的卫星数量。

# [算法说明]
# 状态表长度计算：
# 该函数返回状态表中卫星的数量。
#
# 实现方式：
# 调用Julia标准库的length函数，作用于内部states向量。
#
# 为什么需要这个函数：
# 1. 符合Julia接口：支持length(table)调用
# 2. 语义清晰：表示卫星数量
# 3. 便于循环：for i in 1:length(table)
#
# 时间复杂度：O(1)
# 空间复杂度：O(1)
#
# 使用场景：
# - 循环控制：遍历所有卫星
# - 边界检查：验证索引有效性
# - 统计信息：显示星座规模

参数
- `table::SatelliteStateTable`：卫星状态表

返回值
- `Int`：卫星数量
"""
Base.length(table::SatelliteStateTable)::Int = length(table.states)

"""
    Base.getindex(table::SatelliteStateTable, satellite_id::Int) -> SatelliteRuntimeState

通过卫星 ID 获取运行时状态。

# [算法说明]
# 状态索引访问：
# 该函数通过卫星ID获取对应的运行时状态。
#
# 实现方式：
# 直接索引内部states向量：table.states[satellite_id]
#
# 为什么需要这个函数：
# 1. 符合Julia接口：支持table[satellite_id]语法
# 2. 高效访问：O(1)时间复杂度
# 3. 类型安全：确保返回正确的类型
#
# 边界检查：
# - Julia的数组索引会自动进行边界检查
# - 超出范围会抛出BoundsError
#
# 使用场景：
# - 直接访问：table[1]获取第一颗卫星状态
# - 循环访问：for id in 1:N; table[id]; end
# - 函数参数：作为函数调用参数
#
# 与runtime_state的比较：
# - table[satellite_id]：直接索引，更高效
# - runtime_state(table, satellite_id)：语义化，更清晰
# 两者功能相同，选择取决于上下文。

参数
- `table::SatelliteStateTable`：卫星状态表
- `satellite_id::Int`：卫星 ID

返回值
- `SatelliteRuntimeState`：对应卫星的运行时状态
"""
Base.getindex(table::SatelliteStateTable, satellite_id::Int)::SatelliteRuntimeState = table.states[satellite_id]

"""
    Base.getindex(table::SatelliteStateTable, satellite::Satellite) -> SatelliteRuntimeState

通过卫星对象获取运行时状态（便捷方法）。

# [算法说明]
# 卫星对象索引访问：
# 该函数通过Satellite对象获取对应的运行时状态。
#
# 实现方式：
# 提取satellite.id，调用整数版本的getindex
#
# 为什么需要这个函数：
# 1. 便捷性：直接使用Satellite对象，无需手动提取ID
# 2. 语义清晰：代码更易于理解
# 3. 类型安全：确保使用正确的卫星对象
#
# 使用场景：
# - 在卫星循环中：直接使用循环变量
# - 函数参数：函数接收Satellite对象
# - 链式调用：与satellite操作自然衔接
#
# 与其他方法的比较：
# - table[satellite.id]：手动提取ID
# - table[satellite]：自动提取ID
# 本函数提供更简洁的接口。

参数
- `table::SatelliteStateTable`：卫星状态表
- `satellite::Satellite`：卫星对象

返回值
- `SatelliteRuntimeState`：对应卫星的运行时状态
"""
Base.getindex(table::SatelliteStateTable, satellite::Satellite)::SatelliteRuntimeState = table[satellite.id]

"""
    runtime_state(table::SatelliteStateTable, satellite_id::Int) -> SatelliteRuntimeState

通过卫星 ID 获取运行时状态。

# [算法说明]
# 状态查询算法：
# 该函数通过卫星ID获取对应的运行时状态。
#
# 查询过程：
# 1. 边界检查：确保satellite_id在有效范围内
# 2. 索引访问：O(1)时间复杂度获取状态
# 3. 返回状态：SatelliteRuntimeState对象
#
# 为什么需要这个函数：
# 1. 语义清晰：比直接索引更易于理解
# 2. 类型安全：确保返回正确的类型
# 3. 错误处理：提供边界检查
#
# 与其他方法的比较：
# - table[satellite_id]：直接索引
# - runtime_state(table, satellite_id)：语义化访问
# 本实现使用直接索引，但提供语义化接口。
#
# 使用场景：
# - 状态检查：查询卫星当前状态
# - 状态更新：作为更新操作的前序步骤
# - 条件判断：根据状态决定行为

参数
- `table::SatelliteStateTable`：卫星状态表
- `satellite_id::Int`：卫星 ID

返回值
- `SatelliteRuntimeState`：对应卫星的运行时状态
"""
runtime_state(table::SatelliteStateTable, satellite_id::Int)::SatelliteRuntimeState = table[satellite_id]

"""
    runtime_state(table::SatelliteStateTable, satellite::Satellite) -> SatelliteRuntimeState

通过卫星对象获取运行时状态（语义化方法）。

# [算法说明]
# 卫星对象查询：
# 该函数通过Satellite对象获取对应的运行时状态。
#
# 查询过程：
# 1. 提取ID：从satellite对象获取satellite.id
# 2. 调用ID版本：使用satellite_id版本的runtime_state
# 3. 返回状态：SatelliteRuntimeState对象
#
# 为什么需要这个版本：
# 1. 便捷性：直接使用Satellite对象，无需手动提取ID
# 2. 语义清晰：代码更易于理解
# 3. 类型安全：确保使用正确的卫星对象
#
# 使用场景：
# - 在卫星循环中：直接使用循环变量
# - 函数参数：函数接收Satellite对象
# - 链式调用：与satellite操作自然衔接

参数
- `table::SatelliteStateTable`：卫星状态表
- `satellite::Satellite`：卫星对象

返回值
- `SatelliteRuntimeState`：对应卫星的运行时状态
"""
runtime_state(table::SatelliteStateTable, satellite::Satellite)::SatelliteRuntimeState = table[satellite.id]

"""
    set_runtime_state!(table::SatelliteStateTable, state::SatelliteRuntimeState) -> SatelliteStateTable

设置指定卫星的运行时状态。

# [算法说明]
# 状态更新算法：
# 该函数更新指定卫星的运行时状态。
#
# 更新过程：
# 1. 边界检查：确保satellite_id在有效范围内
# 2. 状态替换：用新状态替换旧状态
# 3. 返回修改后的状态表
#
# 为什么需要这个函数：
# 1. 原地更新：修改现有状态表，避免创建新对象
# 2. 原子操作：确保状态更新的原子性
# 3. 错误处理：提供边界检查
#
# 原地更新的好处：
# - 性能：避免创建新对象
# - 内存：减少内存分配
# - 一致性：确保状态表引用不变
#
# 与其他方法的比较：
# - 创建新表：返回新的SatelliteStateTable
# - 原地更新：修改现有表并返回
# 本实现使用原地更新，更适合仿真循环。
#
# 使用场景：
# - 状态更新：根据仿真结果更新卫星状态
# - 错误恢复：将故障卫星状态重置为正常
# - 配置调整：修改卫星参数

参数
- `table::SatelliteStateTable`：卫星状态表
- `state::SatelliteRuntimeState`：要设置的运行时状态

返回值
- `SatelliteStateTable`：修改后的状态表

异常
- `BoundsError`：当 satellite_id 超出状态表范围时抛出
"""
function set_runtime_state!(table::SatelliteStateTable, state::SatelliteRuntimeState)::SatelliteStateTable
    # 检查索引边界
    checkbounds(table.states, state.satellite_id)
    # 更新状态
    table.states[state.satellite_id] = state
    return table
end

"""
    update_power_state!(
        table::SatelliteStateTable,
        satellite_id::Int,
        power::PowerState,
    ) -> SatelliteStateTable

更新指定卫星的电源状态，保持其他状态不变。

# [算法说明]
# 电源状态更新算法：
# 该函数只更新指定卫星的电源状态，保持其他状态不变。
#
# 更新过程：
# 1. 获取当前状态：读取卫星的完整状态
# 2. 保持不变：status和communication保持不变
# 3. 更新电源：用新power替换旧power
# 4. 设置新状态：调用set_runtime_state!更新
#
# 为什么需要这个函数：
# 1. 部分更新：只更新需要变化的部分
# 2. 状态保持：确保其他状态不被意外修改
# 3. 便捷接口：提供专门的电源更新方法
#
# 不可变性保证：
# - 读取当前状态：不修改原状态
# - 创建新状态：基于当前状态创建
# - 原子更新：确保状态一致性
#
# 使用场景：
# - 能量计算后更新电池状态
# - 太阳能发电变化后更新发电功率
# - 负载变化后更新功耗
#
# 与其他方法的比较：
# - 直接调用set_runtime_state!：需要手动构建完整状态
# - 本函数：自动保持其他状态不变
# 更安全和便捷。

参数
- `table::SatelliteStateTable`：卫星状态表
- `satellite_id::Int`：卫星 ID
- `power::PowerState`：新的电源状态

返回值
- `SatelliteStateTable`：修改后的状态表
"""
function update_power_state!(
    table::SatelliteStateTable,
    satellite_id::Int,
    power::PowerState,
)::SatelliteStateTable
    # 获取当前状态
    current = runtime_state(table, satellite_id)
    # 更新电源状态，保持其他状态不变
    return set_runtime_state!(
        table,
        SatelliteRuntimeState(
            satellite_id = satellite_id,
            status = current.status,
            power = power,
            communication = current.communication,
        ),
    )
end

"""
    update_communication_tail_state!(
        table::SatelliteStateTable,
        satellite_id::Int,
        communication::CommunicationTailState,
    ) -> SatelliteStateTable

更新指定卫星的通信尾状态，保持其他状态不变。

# [算法说明]
# 通信状态更新算法：
# 该函数只更新指定卫星的通信尾状态，保持其他状态不变。
#
# 更新过程：
# 1. 获取当前状态：读取卫星的完整状态
# 2. 保持不变：status和power保持不变
# 3. 更新通信：用新communication替换旧communication
# 4. 设置新状态：调用set_runtime_state!更新
#
# 为什么需要这个函数：
# 1. 部分更新：只更新需要变化的部分
# 2. 状态保持：确保其他状态不被意外修改
# 3. 便捷接口：提供专门的通信更新方法
#
# 通信状态变化时机：
# 1. 数据传输后：更新队列长度
# 2. 链路状态变化：更新可用容量
# 3. 路由变化：更新数据流向
#
# 与其他方法的比较：
# - 直接调用set_runtime_state!：需要手动构建完整状态
# - 本函数：自动保持其他状态不变
# 更安全和便捷。

参数
- `table::SatelliteStateTable`：卫星状态表
- `satellite_id::Int`：卫星 ID
- `communication::CommunicationTailState`：新的通信尾状态

返回值
- `SatelliteStateTable`：修改后的状态表
"""
function update_communication_tail_state!(
    table::SatelliteStateTable,
    satellite_id::Int,
    communication::CommunicationTailState,
)::SatelliteStateTable
    # 获取当前状态
    current = runtime_state(table, satellite_id)
    # 更新通信尾状态，保持其他状态不变
    return set_runtime_state!(
        table,
        SatelliteRuntimeState(
            satellite_id = satellite_id,
            status = current.status,
            power = current.power,
            communication = communication,
        ),
    )
end

"""
    total_load_w(power::PowerState) -> Float64

计算电源总负载功率。

# [算法说明]
# 总负载功率计算：
# 总负载功率 = 基础负载 + 有效载荷负载 + 通信负载
#
# 负载组成：
# 1. 基础负载（base_load_w）：
#    - 卫星基本系统功耗
#    - 包括：计算机、热控、姿态控制等
#    - 通常相对稳定
#
# 2. 有效载荷负载（payload_load_w）：
#    - 有效载荷工作功耗
#    - 包括：相机、雷达、科学仪器等
#    - 可能随任务模式变化
#
# 3. 通信负载（communication_load_w）：
#    - 通信系统功耗
#    - 包括：发射机、接收机、天线等
#    - 与数据传输量相关
#
# 为什么需要总负载：
# 1. 电源规划：确定所需太阳能板功率
# 2. 能量平衡：计算充放电速率
# 3. 热设计：功耗影响热平衡
# 4. 性能评估：评估卫星能效
#
# 简化假设：
# - 线性叠加：假设各负载独立
# - 无相互作用：忽略负载间的耦合效应
# - 稳态计算：不考虑瞬态变化

参数
- `power::PowerState`：电源状态

返回值
- `Float64`：总负载功率（瓦），等于基础负载 + 有效载荷负载 + 通信负载
"""
total_load_w(power::PowerState)::Float64 =
    power.base_load_w + power.payload_load_w + power.communication_load_w

"""
    state_of_charge(power::PowerState) -> Union{Nothing,Float64}

计算电池荷电状态（State of Charge, SOC）。

# [算法说明]
# SOC（State of Charge）定义：
# SOC = 当前存储能量 / 电池总容量
# 范围：0 ≤ SOC ≤ 1
# 物理意义：表示电池剩余电量占总容量的百分比
#
# 为什么需要SOC：
# 1. 健康状态评估：低SOC表示电池电量不足
# 2. 充放电控制：根据SOC决定充电或放电策略
# 3. 寿命管理：避免深度放电（SOC<0.2）延长电池寿命
# 4. 性能预测：SOC影响卫星可运行时间
#
# 边界情况处理：
# - battery_capacity_wh = 0：返回nothing（无电池或电池损坏）
# - stored_energy_wh = 0：SOC = 0（完全放电）
# - stored_energy_wh = battery_capacity_wh：SOC = 1（完全充电）
#
# 与实际电池的对应：
# 真实卫星电池通常使用锂离子电池，SOC特性：
# - 线性区（0.2 < SOC < 0.8）：电压与SOC近似线性
# - 非线性区（SOC < 0.2或SOC > 0.8）：电压变化剧烈
# 本模型简化了这些非线性特性。

SOC = 当前存储能量 / 电池总容量

参数
- `power::PowerState`：电源状态

返回值
- `Union{Nothing,Float64}`：
  - 如果电池容量为 0，返回 nothing
  - 否则返回 SOC 值（范围 0 到 1）
"""
function state_of_charge(power::PowerState)::Union{Nothing,Float64}
    # 处理电池容量为 0 的情况
    power.battery_capacity_wh == 0 && return nothing
    # 计算并返回 SOC
    return power.stored_energy_wh / power.battery_capacity_wh
end

"""
    is_operational(state::SatelliteRuntimeState) -> Bool

判断卫星是否处于可运行状态。

# [算法说明]
# 卫星运行状态分类：
# 1. SatelliteNominal（正常）：所有功能正常，完全可用
# 2. SatelliteDegraded（降级）：部分功能受限，但基本功能可用
# 3. SatelliteOffline（离线）：暂时不可用，可能正在维护或重启
# 4. SatelliteFailed（故障）：永久不可用，需要地面干预
#
# 为什么将降级状态视为可运行：
# 1. 实际需求：降级卫星仍能提供部分服务
# 2. 资源利用：避免浪费可用的卫星资源
# 3. 冗余设计：星座通常有冗余，单颗降级不影响整体
# 4. 渐进失效：从正常到故障通常经历降级阶段
#
# 应用场景：
# - 路由决策：只选择可运行卫星
# - 资源分配：为可运行卫星分配任务
# - 可用性评估：统计可运行卫星比例
# - 故障恢复：监控状态变化，触发恢复流程
#
# 与真实卫星的对应：
# - 正常：所有载荷和通信系统工作
# - 降级：部分载荷故障，但通信正常
# - 离线：进入安全模式，等待指令
# - 故障：永久失效，需要退役

可运行状态包括正常和降级状态。离线和故障状态被认为是不可运行的。

参数
- `state::SatelliteRuntimeState`：卫星运行时状态

返回值
- `Bool`：如果状态为 SatelliteNominal 或 SatelliteDegraded 则返回 true
"""
is_operational(state::SatelliteRuntimeState)::Bool =
    state.status == SatelliteNominal || state.status == SatelliteDegraded