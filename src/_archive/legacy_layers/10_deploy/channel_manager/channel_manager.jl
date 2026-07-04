#=
本文件：src/deploy/channel_manager/channel_manager.jl

职责：
- 定义通道管理器抽象层与两种实现：DryRun（仅记录）和 VMRoute（通过 limactl 操作 Lima VM 路由）。
- 将 OEF（Orbital Events File）中的 link_up/link_down 事件翻译为 restore/blackhole 路由动作。
- 提供 OEF 回放、VM 命令生成、调度记录与序列化工具。

在项目流水线中的位置：
- 上游：core/orbital_events.jl 生成的 OEF 文件，以及 deploy/materialization 提供的 TestbedMaterializationPlan / RuntimeEndpointRegistry。
- 下游：在 Lima VM 中实际执行 `ip route replace blackhole` / `ip route del blackhole`，以复现卫星链路通断。

数据流说明：
- OEF 事件处理流程：
  → OEF 文件（OrbitalEventsFile）包含轨道事件时间序列
  → sorted_channel_manager_events(oef) 筛选 link_up/link_down 事件并排序
  → replay_oef!() 按仿真时间顺序回放事件
  → 对每个事件调用 execute_event!() 生成 ChannelManagerAction
  → action_type 映射：link_down → :blackhole_route，link_up → :restore_route
- DryRun 模式（仅记录）：
  → DryRunChannelManager 仅将 ChannelManagerAction 追加到 actions 列表
  → 不执行任何 VM 命令，用于验证事件流和动作序列
- VMRoute 模式（实际执行）：
  → VMRouteChannelManager 处理事件时：
    → 选择 endpoint 解析来源：runtime_registry（动态）或 materialization（静态）
    → vm_route_commands() 生成双向路由命令（源→目标 + 目标→源）
    → route_command_script() 生成 VM 内部 shell 脚本
    → limactl_route_command() 封装完整的 limactl shell 命令
    → run_vm_route_command() 通过 sh -lc 执行命令
    → 记录命令到 commands 列表（便于审计）
    → 记录动作到 actions 列表
- 输出：
  → ChannelManagerAction 列表（动作序列）
  → ChannelManagerScheduleRecord 列表（调度记录，含时间偏差信息）
  → VMRouteCommand 列表（实际执行的 VM 命令，用于审计）
- 辅助数据流：
  → action_dict() / schedule_record_dict() / route_command_dict()：序列化为可 JSON 化字典
  → endpoint_label()：将 OEF 端点编码为 "kind-id" 字符串
  → channel_manager_action()：由单个 OEF 事件生成完整的 ChannelManagerAction

[算法说明]
本文件实现了OEF事件驱动的通道管理器，核心算法包括：

1. **OEF事件驱动算法**：
   - OEF(Orbital Events File)定义了卫星轨道事件的时间序列
   - 通道管理器关注两类事件：
     * link_down: 链路断开，需要阻断网络通信
     * link_up: 链路恢复，需要恢复网络通信
   - 事件处理流程：
     1. 解析OEF文件，筛选出link_up/link_down事件
     2. 按(elapsed_s, time_index, event_type)排序，确保时间顺序
     3. 逐个事件触发路由动作
   - 动作映射：
     * link_down -> :blackhole_route（添加黑洞路由）
     * link_up -> :restore_route（删除黑洞路由）

2. **VM路由命令生成算法**：
   - route_command_script()生成VM内部执行的shell脚本
   - 黑洞路由脚本（blackhole_route）：
     1. getent hosts解析目标主机名到IP
     2. ip route get验证路由可达性
     3. sudo ip route replace blackhole添加黑洞路由（/32掩码）
   - 恢复路由脚本（restore_route）：
     1. getent hosts解析目标主机名到IP
     2. sudo ip route del blackhole删除黑洞路由
     3. 2>/dev/null || true忽略删除失败（路由不存在时）
   - limactl_route_command()封装完整的limactl命令：
     * limactl shell <runtime_name> -- env -i ... sh -lc <script>
     * env -i清理环境变量，避免宿主机污染

3. **Dry-run与VM执行模式**：
   - DryRunChannelManager：
     * 仅记录动作，不执行VM命令
     * 用于验证OEF事件流和生成的动作序列
     * actions列表记录所有生成的动作
   - VMRouteChannelManager：
     * 真正执行limactl命令
     * execute字段控制是否实际执行（false时仅收集命令）
     * 支持两种endpoint解析来源：
       a. 物化计划（静态映射）
       b. 运行时注册表（动态IP/hostname）
   - 命令选择逻辑：
     if manager.runtime_registry === nothing
       使用物化计划（静态）
     else
       使用运行时注册表（动态）

4. **调度记录与动作日志算法**：
   - replay_oef!()按仿真时间回放OEF事件
   - 调度记录(ChannelManagerScheduleRecord)包含：
     * scheduled_time_s: 事件计划发生的仿真时间
     * waited_s: 回放前实际等待的时间
     * action: 本次调度触发的动作
   - 时间加速算法：
     * speedup=Inf：立即执行，不等待
     * speedup=N：等待时间=delta_s/N
     * delta_s=max(0, event.elapsed_s - previous_time_s)
   - 序列化：
     * action_dict()：动作序列化
     * schedule_record_dict()：调度记录序列化
     * route_command_dict()：命令序列化

5. **双向路由算法**：
   - vm_route_commands()将单向动作扩展为双向命令
   - 对于链路(A, B)的blackhole_route：
     * 在A上执行：blackhole路由到B
     * 在B上执行：blackhole路由到A
   - 确保双向通信都被阻断/恢复
   - 返回Vector{VMRouteCommand}，包含两条命令

6. **endpoint标签算法**：
   - endpoint_label()将OEF端点编码为字符串
   - 格式："kind-id"（如"satellite-3"）
   - 用于生成人类可读的路由描述
   - 在日志和调试中提供可读的端点标识
=#

"""
    AbstractChannelManager

通道管理器（Channel Manager）的抽象基类。部署层通过通道管理器把 OEF（Orbital Events File）
中的 `link_up`/`link_down` 事件翻译为对测试床节点的路由操作，从而复现卫星链路通断。
目前派生实现包括：
- `DryRunChannelManager`：仅记录动作，不真正执行；
- `VMRouteChannelManager`：通过 `limactl` 在 Lima 虚拟机内部下发 blackhole/restore 路由命令。
"""
abstract type AbstractChannelManager end

"""
    ChannelManagerAction

通道管理器要执行的一次链路动作。

# 字段
- `action_type::Symbol`：动作类型，仅支持 `:restore_route`（恢复路由）或 `:blackhole_route`（黑洞路由）。
- `event::OrbitalLinkEvent`：触发该动作的 OEF 链路事件。
- `description::String`：人类可读的动作描述，用于日志与调试。
"""
struct ChannelManagerAction
    action_type::Symbol
    event::OrbitalLinkEvent
    description::String

    function ChannelManagerAction(action_type::Symbol, event::OrbitalLinkEvent, description::String)
        # 只允许两种动作类型，防止非法路由操作进入执行阶段
        action_type in (:restore_route, :blackhole_route) ||
            throw(ArgumentError("action_type must be :restore_route or :blackhole_route"))
        isempty(description) && throw(ArgumentError("description must not be empty"))
        return new(action_type, event, description)
    end
end

"""
    DryRunChannelManager

只记录、不执行的通道管理器实现。用于在真正操作 VM 之前验证 OEF 事件流和生成的动作序列。

# 字段
- `actions::Vector{ChannelManagerAction}`：已处理的全部动作记录。
"""
mutable struct DryRunChannelManager <: AbstractChannelManager
    actions::Vector{ChannelManagerAction}

    DryRunChannelManager() = new(ChannelManagerAction[])
end

"""
    VMRouteCommand

在 Lima VM 内部执行的具体路由命令。

# 字段
- `source_node::String`：源节点在 TestbedSpec 中的 id。
- `source_runtime_name::String`：源节点对应的 Lima 实例名（`runtime_name`）。
- `destination_node::String`：目标节点在 TestbedSpec 中的 id。
- `destination_hostname::String`：目标节点在 Lima 网络中的主机名。
- `action_type::Symbol`：`:restore_route` 或 `:blackhole_route`。
- `command::String`：已经组装好的 `limactl shell ...` 命令字符串，可直接交给 `sh -lc` 执行。
"""
struct VMRouteCommand
    source_node::String
    source_runtime_name::String
    destination_node::String
    destination_hostname::String
    action_type::Symbol
    command::String

    function VMRouteCommand(;
        source_node::AbstractString,
        source_runtime_name::AbstractString,
        destination_node::AbstractString,
        destination_hostname::AbstractString,
        action_type::Symbol,
        command::AbstractString,
    )
        action_type in (:restore_route, :blackhole_route) ||
            throw(ArgumentError("VM route action_type must be :restore_route or :blackhole_route"))
        # 以下字段均用于定位 VM 与目标地址，不允许为空
        isempty(source_node) && throw(ArgumentError("source_node must not be empty"))
        isempty(source_runtime_name) && throw(ArgumentError("source_runtime_name must not be empty"))
        isempty(destination_node) && throw(ArgumentError("destination_node must not be empty"))
        isempty(destination_hostname) && throw(ArgumentError("destination_hostname must not be empty"))
        isempty(command) && throw(ArgumentError("command must not be empty"))
        return new(
            String(source_node),
            String(source_runtime_name),
            String(destination_node),
            String(destination_hostname),
            action_type,
            String(command),
        )
    end
end

"""
    VMRouteChannelManager

基于 Lima VM 的通道管理器实现。它把 OEF 事件转成 `limactl shell` 命令并在 VM 内执行 blackhole/restore。

# 字段
- `materialization::TestbedMaterializationPlan`：物化计划，用于把 OEF endpoint 映射到 VM 节点。
- `runtime_registry::Union{Nothing,RuntimeEndpointRegistry}`：运行时端点注册表，可用于动态解析 IP；
  为 `nothing` 时回退到物化计划中的静态信息。
- `actions::Vector{ChannelManagerAction}`：已生成的动作记录。
- `commands::Vector{VMRouteCommand}`：已生成的 VM 命令记录（`execute=false` 时可单独审计）。
- `execute::Bool`：是否真正调用 `limactl`；关闭时仅收集命令，便于 dry-run。
"""
mutable struct VMRouteChannelManager <: AbstractChannelManager
    materialization::TestbedMaterializationPlan
    runtime_registry::Union{Nothing,RuntimeEndpointRegistry}
    actions::Vector{ChannelManagerAction}
    commands::Vector{VMRouteCommand}
    execute::Bool

    function VMRouteChannelManager(
        materialization::TestbedMaterializationPlan;
        runtime_registry::Union{Nothing,RuntimeEndpointRegistry} = nothing,
        execute::Bool = true,
    )
        # [算法说明]
        # 运行时注册表自动加载算法：
        # 1. 如果调用方未传入registry（runtime_registry=nothing）
        # 2. 且物化阶段已生成runtime_endpoints.json文件
        # 3. 则自动加载该文件作为运行时注册表
        # 4. 否则使用调用方传入的registry（可能为nothing）
        # 这种设计允许在没有显式传入registry的情况下自动使用物化阶段生成的文件。
        resolved_registry = runtime_registry === nothing && isfile(materialization.runtime_registry_path) ?
            read_runtime_endpoint_registry(materialization.runtime_registry_path) :
            runtime_registry
        return new(materialization, resolved_registry, ChannelManagerAction[], VMRouteCommand[], execute)
    end
end

"""
    ChannelManagerScheduleRecord

`replay_oef!` 回放过程中产生的一次调度记录，用于衡量实际执行与计划时间的偏差。

# 字段
- `scheduled_time_s::Int`：事件计划发生的仿真时间（秒）。
- `waited_s::Float64`：回放前实际等待的秒数（`speedup=Inf` 时为 0）。
- `action::ChannelManagerAction`：本次调度触发的动作。
"""
struct ChannelManagerScheduleRecord
    scheduled_time_s::Int
    waited_s::Float64
    action::ChannelManagerAction

    function ChannelManagerScheduleRecord(;
        scheduled_time_s::Int,
        waited_s::Real,
        action::ChannelManagerAction,
    )
        scheduled_time_s >= 0 || throw(ArgumentError("scheduled_time_s must be non-negative"))
        waited_s >= 0 || throw(ArgumentError("waited_s must be non-negative"))
        return new(scheduled_time_s, Float64(waited_s), action)
    end
end

# [算法说明]
# OEF端点标签生成算法：将端点类型和ID编码为字符串。
# 格式："kind-id"（如"satellite-3"）
# 用途：生成人类可读的路由描述，用于日志和调试。
"""
    endpoint_label(endpoint::OrbitalLinkEndpoint) -> String

将 OEF endpoint 编码为 `"kind-id"` 字符串，用于生成人类可读的路由描述。
"""
function endpoint_label(endpoint::OrbitalLinkEndpoint)::String
    return "$(endpoint.kind)-$(endpoint.id)"
end

# [算法说明]
# OEF事件到路由动作的映射算法：
# - link_up -> :restore_route（链路恢复，删除黑洞路由）
# - link_down -> :blackhole_route（链路断开，添加黑洞路由）
# 这种映射使得轨道事件可以直接转换为网络路由操作。
"""
    channel_manager_action_type(event::OrbitalLinkEvent) -> Symbol

把 OEF 事件类型映射为通道管理器动作类型。
- `:link_up` -> `:restore_route`（链路恢复，撤销黑洞路由）。
- `:link_down` -> `:blackhole_route`（链路断开，添加黑洞路由）。
"""
function channel_manager_action_type(event::OrbitalLinkEvent)::Symbol
    if event.event_type == :link_up
        return :restore_route
    elseif event.event_type == :link_down
        return :blackhole_route
    end
    throw(ArgumentError("unsupported Channel Manager event_type: $(event.event_type)"))
end

# [算法说明]
# 动作描述生成算法：生成人类可读的动作文本描述。
# 格式："{action_type} route between {source} and {destination} at t={time}s"
# 用途：用于日志输出和调试，提供可读的事件描述。
"""
    channel_manager_description(action_type::Symbol, event::OrbitalLinkEvent) -> String

生成动作的文本描述，包含源/目的 endpoint 标签与事件发生时间。
"""
function channel_manager_description(action_type::Symbol, event::OrbitalLinkEvent)::String
    source = endpoint_label(event.endpoint_a)
    destination = endpoint_label(event.endpoint_b)
    if action_type == :restore_route
        return "restore route between $source and $destination at t=$(event.elapsed_s)s"
    elseif action_type == :blackhole_route
        return "blackhole route between $source and $destination at t=$(event.elapsed_s)s"
    end
    throw(ArgumentError("unsupported Channel Manager action_type: $action_type"))
end

"""
    channel_manager_action(event::OrbitalLinkEvent) -> ChannelManagerAction

由单个 OEF 事件生成完整的 `ChannelManagerAction`。
"""
function channel_manager_action(event::OrbitalLinkEvent)::ChannelManagerAction
    action_type = channel_manager_action_type(event)
    return ChannelManagerAction(action_type, event, channel_manager_description(action_type, event))
end

"""
    execute_event!(manager::DryRunChannelManager, event::OrbitalLinkEvent) -> ChannelManagerAction

对 `DryRunChannelManager` 处理单个 OEF 事件：仅记录动作，不执行 VM 命令。
"""
function execute_event!(manager::DryRunChannelManager, event::OrbitalLinkEvent)::ChannelManagerAction
    action = channel_manager_action(event)
    push!(manager.actions, action)
    return action
end

# [算法说明]
# Dry-run模式OEF处理算法：顺序处理所有事件，仅记录动作。
# 实现：遍历OEF事件，对每个事件调用execute_event!()。
# 返回：所有生成的动作列表。
# 用途：验证OEF事件流和生成的动作序列，不实际执行VM命令。
"""
    execute_oef!(manager::DryRunChannelManager, oef::OrbitalEventsFile) -> Vector{ChannelManagerAction}

对 `DryRunChannelManager` 顺序处理 OEF 文件中的所有事件，返回动作列表。
"""
function execute_oef!(manager::DryRunChannelManager, oef::OrbitalEventsFile)::Vector{ChannelManagerAction}
    for event in oef.events
        execute_event!(manager, event)
    end
    return manager.actions
end

# [算法说明]
# VM路由命令脚本生成算法：构造在VM内部执行的shell脚本。
# 黑洞路由脚本（blackhole_route）：
#   1. getent hosts解析目标主机名到IP
#   2. test -n验证IP非空
#   3. ip route get验证路由可达性
#   4. sudo ip route replace blackhole添加黑洞路由（/32掩码）
# 恢复路由脚本（restore_route）：
#   1. getent hosts解析目标主机名到IP
#   2. test -n验证IP非空
#   3. sudo ip route del blackhole删除黑洞路由
#   4. 2>/dev/null || true忽略删除失败（路由不存在时）
# /32掩码表示精确匹配单个IP地址。
"""
    route_command_script(action_type::Symbol, destination_hostname::AbstractString) -> String

生成在 VM 内部执行的 shell 脚本，用于添加/删除到目标主机的黑洞路由。

脚本逻辑：
1. 用 `getent hosts` 解析目标主机名到 IPv4；
2. 对 `:blackhole_route` 执行 `ip route replace blackhole`；
3. 对 `:restore_route` 执行 `ip route del blackhole`（删除失败时忽略）。
"""
function route_command_script(action_type::Symbol, destination_hostname::AbstractString)::String
    if action_type == :blackhole_route
        return "set -eu; dst=\$(getent hosts $(destination_hostname) | awk '{print \$1; exit}'); test -n \"\$dst\"; ip route get \"\$dst\" >/dev/null; sudo ip route replace blackhole \"\$dst/32\""
    elseif action_type == :restore_route
        return "set -eu; dst=\$(getent hosts $(destination_hostname) | awk '{print \$1; exit}'); test -n \"\$dst\"; sudo ip route del blackhole \"\$dst/32\" 2>/dev/null || true"
    end
    throw(ArgumentError("unsupported VM route action_type: $action_type"))
end

# [算法说明]
# Shell命令引号算法：与shell_single_quote()功能相同。
# 规则：外部用单引号包裹，内部单引号替换为'\"'\"'
# 用途：在limactl命令中安全传递参数。
"""
    shell_command_quote(value::AbstractString) -> String

对字符串做单引号 shell 转义：把内部单引号替换为 `'"'"'`，
使字符串能安全嵌入到 `sh -lc` 的命令参数中。
"""
function shell_command_quote(value::AbstractString)::String
    return "'" * replace(String(value), "'" => "'\"'\"'") * "'"
end

# [算法说明]
# Lima VM路由命令构造算法：
# 1. 调用route_command_script()生成VM内部执行的shell脚本
# 2. 使用shell_command_quote()对参数进行单引号转义
# 3. 构造完整的limactl shell命令：
#    - limactl shell <runtime_name>：进入指定VM
#    - env -i HOME=/root PATH=...：清理环境变量
#    - sh -lc <script>：执行脚本
# 4. 返回VMRouteCommand，包含完整的命令字符串
"""
    limactl_route_command(
        source::TestbedVMNodeMaterialization,
        destination::TestbedVMNodeMaterialization,
        action_type::Symbol,
    ) -> VMRouteCommand

使用物化计划中的静态节点信息构造 `VMRouteCommand`。
命令通过 `limactl shell` 在源节点 VM 内执行 `route_command_script`。
"""
function limactl_route_command(
    source::TestbedVMNodeMaterialization,
    destination::TestbedVMNodeMaterialization,
    action_type::Symbol,
)::VMRouteCommand
    script = route_command_script(action_type, destination.lima_hostname)
    # env -i 清空环境变量，避免宿主环境对 VM 内脚本造成干扰；PATH 覆盖常见系统目录
    command = "limactl shell $(shell_command_quote(source.runtime_name)) -- env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin sh -lc $(shell_command_quote(script))"
    return VMRouteCommand(
        source_node = source.node_id,
        source_runtime_name = source.runtime_name,
        destination_node = destination.node_id,
        destination_hostname = destination.lima_hostname,
        action_type = action_type,
        command = command,
    )
end

"""
    limactl_route_command(
        source::RuntimeEndpoint,
        destination::RuntimeEndpoint,
        action_type::Symbol,
    ) -> VMRouteCommand

使用运行时端点注册表中的动态信息构造 `VMRouteCommand`，可在 VM 启动后根据实际 hostname 下发路由。
"""
function limactl_route_command(
    source::RuntimeEndpoint,
    destination::RuntimeEndpoint,
    action_type::Symbol,
)::VMRouteCommand
    script = route_command_script(action_type, destination.runtime_hostname)
    command = "limactl shell $(shell_command_quote(source.runtime_name)) -- env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin sh -lc $(shell_command_quote(script))"
    return VMRouteCommand(
        source_node = source.node_id,
        source_runtime_name = source.runtime_name,
        destination_node = destination.node_id,
        destination_hostname = destination.runtime_hostname,
        action_type = action_type,
        command = command,
    )
end

# [算法说明]
# 双向路由命令生成算法：将单向动作扩展为双向命令。
# 原因：卫星链路是双向的，断开/恢复需要在两端同时操作。
# 算法：
#   1. 从物化计划中查找源节点和目标节点
#   2. 生成两条命令：
#      - 源节点 -> 目标节点：在源VM上添加/删除到目标的黑洞路由
#      - 目标节点 -> 源节点：在目标VM上添加/删除到源的黑洞路由
#   3. 返回Vector{VMRouteCommand}，包含两条命令
# 这确保双向通信都被阻断或恢复。
"""
    vm_route_commands(
        materialization::TestbedMaterializationPlan,
        action::ChannelManagerAction,
    ) -> Vector{VMRouteCommand}

根据物化计划把一次链路动作扩展为两条双向 VM 路由命令：
`source -> destination` 与 `destination -> source`，保证双向 blackhole/restore 一致。
"""
function vm_route_commands(
    materialization::TestbedMaterializationPlan,
    action::ChannelManagerAction,
)::Vector{VMRouteCommand}
    source = find_materialized_endpoint(materialization, action.event.endpoint_a)
    destination = find_materialized_endpoint(materialization, action.event.endpoint_b)
    return [
        limactl_route_command(source, destination, action.action_type),
        limactl_route_command(destination, source, action.action_type),
    ]
end

"""
    vm_route_commands(
        registry::RuntimeEndpointRegistry,
        action::ChannelManagerAction,
    ) -> Vector{VMRouteCommand}

根据运行时端点注册表把一次链路动作扩展为两条双向 VM 路由命令。
"""
function vm_route_commands(
    registry::RuntimeEndpointRegistry,
    action::ChannelManagerAction,
)::Vector{VMRouteCommand}
    source = find_runtime_endpoint(registry, action.event.endpoint_a)
    destination = find_runtime_endpoint(registry, action.event.endpoint_b)
    return [
        limactl_route_command(source, destination, action.action_type),
        limactl_route_command(destination, source, action.action_type),
    ]
end

# [算法说明]
# VM路由命令执行算法：在本地shell中执行limactl命令。
# 实现：使用Julia的run()函数执行shell命令。
# 依赖：limactl已在PATH中，且对应Lima实例处于运行状态。
"""
    run_vm_route_command(command::VMRouteCommand) -> Nothing

在本地 shell 中执行已组装的 `limactl` 命令。
依赖：`limactl` 已在 PATH 中，且对应 Lima 实例处于运行状态。
"""
function run_vm_route_command(command::VMRouteCommand)::Nothing
    run(`sh -lc $(command.command)`)
    return nothing
end

# [算法说明]
# VM路由通道管理器事件处理算法：
# 1. 根据OEF事件生成ChannelManagerAction
# 2. 选择endpoint解析来源：
#    - runtime_registry=nothing：使用物化计划（静态映射）
#    - runtime_registry!=nothing：使用运行时注册表（动态IP/hostname）
# 3. 生成双向VM路由命令
# 4. 如果execute=true，通过limactl执行命令
# 5. 记录动作到actions列表
# execute字段允许在不实际执行的情况下收集命令，便于审计和测试。
"""
    execute_event!(manager::VMRouteChannelManager, event::OrbitalLinkEvent) -> ChannelManagerAction

对 `VMRouteChannelManager` 处理单个 OEF 事件：
1. 生成动作；
2. 根据是否有运行时注册表，选择物化计划或注册表解析 endpoint；
3. 生成双向 VM 命令并追加到 `manager.commands`；
4. 若 `manager.execute == true`，则通过 `limactl` 下发命令；
5. 记录动作。
"""
function execute_event!(manager::VMRouteChannelManager, event::OrbitalLinkEvent)::ChannelManagerAction
    # [执行流程]
    # 步骤1: 根据 OEF 事件类型生成 ChannelManagerAction（link_down → :blackhole_route，link_up → :restore_route）
    action = channel_manager_action(event)
    # 步骤2: 选择 endpoint 解析来源
    # - runtime_registry=nothing：使用物化计划中的静态映射（启动前）
    # - runtime_registry!=nothing：使用运行时注册表的动态 IP/hostname（启动后）
    commands = manager.runtime_registry === nothing ?
        vm_route_commands(manager.materialization, action) :
        vm_route_commands(manager.runtime_registry, action)
    # 步骤3: 将双向命令追加到 commands 列表（用于审计和导出）
    append!(manager.commands, commands)
    # 步骤4: 如果 execute=true，通过 limactl 实际执行路由命令
    if manager.execute
        for command in commands
            run_vm_route_command(command)
        end
    end
    # 步骤5: 记录动作到 actions 列表
    push!(manager.actions, action)
    return action
end

# [算法说明]
# VM路由模式OEF处理算法：顺序处理所有事件，生成并执行路由命令。
# 实现：遍历OEF事件，对每个事件调用execute_event!()。
# execute_event!()会：
#   1. 生成ChannelManagerAction
#   2. 生成双向VM路由命令
#   3. 如果execute=true，通过limactl执行命令
#   4. 记录动作
# 返回：所有生成的动作列表。
"""
    execute_oef!(manager::VMRouteChannelManager, oef::OrbitalEventsFile) -> Vector{ChannelManagerAction}

对 `VMRouteChannelManager` 顺序处理 OEF 文件中的所有事件。
"""
function execute_oef!(manager::VMRouteChannelManager, oef::OrbitalEventsFile)::Vector{ChannelManagerAction}
    for event in oef.events
        execute_event!(manager, event)
    end
    return manager.actions
end

# [算法说明]
# OEF事件筛选与排序算法：
# 1. 筛选出通道管理器关心的事件类型（link_up/link_down）
# 2. 按三元组(elapsed_s, time_index, event_type)排序：
#    - elapsed_s：事件发生的仿真时间（主排序键）
#    - time_index：时间索引（次排序键，处理同一时间的多个事件）
#    - event_type：事件类型（第三排序键，确保确定性顺序）
# 排序确保回放顺序与仿真时间一致，避免因果倒置。
"""
    sorted_channel_manager_events(oef::OrbitalEventsFile) -> Vector{OrbitalLinkEvent}

从 OEF 中筛选出通道管理器关心的 `:link_up` 与 `:link_down` 事件，
并按 `(elapsed_s, time_index, event_type)` 排序，保证回放顺序与仿真时间一致。
"""
function sorted_channel_manager_events(oef::OrbitalEventsFile)::Vector{OrbitalLinkEvent}
    events = [event for event in oef.events if event.event_type in (:link_up, :link_down)]
    sort!(events, by = event -> (event.elapsed_s, event.time_index, String(event.event_type)))
    return events
end

# [算法说明]
# OEF事件回放算法：按仿真时间顺序执行轨道事件。
# 核心逻辑：
# 1. 筛选并排序OEF事件（link_up/link_down）
# 2. 按时间顺序逐个处理事件
# 3. 计算事件间隔并根据加速比换算等待时间：
#    - delta_s = max(0, event.elapsed_s - previous_time_s)
#    - wait_s = isinf(speedup) ? 0.0 : delta_s / speedup
# 4. 等待指定时间后执行事件
# 5. 记录调度结果（计划时间、等待时间、动作）
# 支持注入自定义sleep函数，便于测试时跳过等待。
"""
    replay_oef!(
        manager::AbstractChannelManager,
        oef::OrbitalEventsFile;
        speedup::Real = Inf,
        start_time_s::Int = 0,
        sleep_fn::Function = sleep,
    ) -> Vector{ChannelManagerScheduleRecord}

按仿真时间回放 OEF 事件到指定通道管理器。

# 参数
- `manager`：目标通道管理器（dry-run 或 VM）。
- `oef`：轨道事件文件。
- `speedup`：时间加速比；`Inf` 表示不等待，立即顺序执行。
- `start_time_s`：起始时间，之前的事件被跳过。
- `sleep_fn`：等待函数，默认 `sleep`；可注入自定义函数便于测试。

# 返回
- 每条事件的调度记录，包含计划时间、实际等待时长与动作。
"""
function replay_oef!(
    manager::AbstractChannelManager,
    oef::OrbitalEventsFile;
    speedup::Real = Inf,
    start_time_s::Int = 0,
    sleep_fn::Function = sleep,
)::Vector{ChannelManagerScheduleRecord}
    speedup > 0 || throw(ArgumentError("speedup must be positive"))
    start_time_s >= 0 || throw(ArgumentError("start_time_s must be non-negative"))

    records = ChannelManagerScheduleRecord[]
    previous_time_s = start_time_s
    # [执行流程]
    # 步骤1: 筛选并排序 OEF 事件（link_up/link_down，按时间排序）
    for event in sorted_channel_manager_events(oef)
        # 步骤2: 跳过起始时间之前的事件
        event.elapsed_s < start_time_s && continue
        # 步骤3: 计算事件间隔并根据加速比换算等待时间
        delta_s = max(0, event.elapsed_s - previous_time_s)
        # speedup=Inf：立即执行（wait_s=0.0）；speedup=N：等待 delta_s/N 秒
        wait_s = isinf(speedup) ? 0.0 : delta_s / Float64(speedup)
        # 步骤4: 等待指定时间（可通过 sleep_fn 注入自定义等待逻辑）
        wait_s > 0 && sleep_fn(wait_s)
        # 步骤5: 执行事件处理（生成动作、执行路由命令）
        action = execute_event!(manager, event)
        # 步骤6: 记录调度结果（计划时间、实际等待时间、动作）
        push!(
            records,
            ChannelManagerScheduleRecord(
                scheduled_time_s = event.elapsed_s,
                waited_s = wait_s,
                action = action,
            ),
        )
        # 步骤7: 更新前一个事件的时间戳，用于计算下一个事件的间隔
        previous_time_s = event.elapsed_s
    end
    return records
end

# [算法说明]
# 动作序列化算法：将ChannelManagerAction转换为可JSON化的字典。
# 包含：动作类型、时间、链路类型、端点信息和描述。
"""
    action_dict(action::ChannelManagerAction) -> Dict{String,Any}

把 `ChannelManagerAction` 序列化为可 JSON 化的字典。
"""
function action_dict(action::ChannelManagerAction)::Dict{String,Any}
    return Dict{String,Any}(
        "action_type" => String(action.action_type),
        "time_s" => action.event.elapsed_s,
        "link_type" => String(action.event.link_type),
        "endpoint_a" => endpoint_dict(action.event.endpoint_a),
        "endpoint_b" => endpoint_dict(action.event.endpoint_b),
        "description" => action.description,
    )
end

# [算法说明]
# 调度记录序列化算法：将ChannelManagerScheduleRecord转换为可JSON化的字典。
# 包含：计划时间、等待时间和动作信息。
"""
    schedule_record_dict(record::ChannelManagerScheduleRecord) -> Dict{String,Any}

把调度记录序列化为可 JSON 化的字典。
"""
function schedule_record_dict(record::ChannelManagerScheduleRecord)::Dict{String,Any}
    return Dict{String,Any}(
        "scheduled_time_s" => record.scheduled_time_s,
        "waited_s" => record.waited_s,
        "action" => action_dict(record.action),
    )
end

# [算法说明]
# VM路由命令序列化算法：将VMRouteCommand转换为可JSON化的字典。
# 包含：源节点、目标节点、动作类型和完整的命令字符串。
# 用途：导出审计，记录实际执行的命令。
"""
    route_command_dict(command::VMRouteCommand) -> Dict{String,Any}

把 VM 路由命令序列化为可 JSON 化的字典，便于导出审计。
"""
function route_command_dict(command::VMRouteCommand)::Dict{String,Any}
    return Dict{String,Any}(
        "source_node" => command.source_node,
        "source_runtime_name" => command.source_runtime_name,
        "destination_node" => command.destination_node,
        "destination_hostname" => command.destination_hostname,
        "action_type" => String(command.action_type),
        "command" => command.command,
    )
end
