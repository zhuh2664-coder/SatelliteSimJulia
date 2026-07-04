#=
本文件：src/deploy/model_generation/testbed_model.jl

职责：
- 定义测试床模型的所有数据结构（TestbedSpec 及其子组件）。
- 提供从 TOML 文件加载测试床规格的解析函数。
- 提供测试床规格的打印/展示功能。

在项目流水线中的位置：
- 上游：用户提供的 TOML 配置文件（描述测试床场景、环境、节点、网络、链接等）。
- 下游：testbed_realization.jl 将解析后的 TestbedSpec 转换为具体的 TestbedRealizationPlan。

数据流说明：
- 输入：TOML 配置文件（磁盘文件）
  → load_testbed_spec(path) 读取并解析 TOML 文件
  → TOML.parsefile(path) 将文件内容解析为 Dict
  → 逐层解析各节（scenario, channel_manager, environment, networks, nodes, links, services, checks）
  → 构造并验证每个子结构体（TestbedScenario, TestbedNode 等）
  → 组装为完整的 TestbedSpec
- 输出：TestbedSpec 对象（内存中的不可变数据结构）
  → 传递给 testbed_realization.jl 的 realize_testbed_spec()
  → 由下游负责转换为 TestbedRealizationPlan
- 辅助数据流：
  → print_testbed_spec() 将 TestbedSpec 格式化输出到 IO 流（stdout 或文件）
  → 常量定义（TESTBED_TIME_MODES, TESTBED_BACKENDS 等）被所有下游模块引用
=#

# [算法说明]
# 测试床模型定义了整个仿真场景的数据结构层次。
# 核心算法思想是将复杂的测试床配置分解为可验证的组件：
# 1. 场景层 (TestbedScenario)：定义全局参数，如时间模式和OEF配置
# 2. 环境层 (TestbedEnvironment)：定义部署环境，支持后端继承机制
# 3. 网络层 (TestbedNetwork)：定义虚拟网络拓扑
# 4. 节点层 (TestbedNode)：定义计算资源，每个节点绑定一个OEF端点
# 5. 链路层 (TestbedLink)：定义节点间连接，支持延迟/丢包模型
# 6. 服务层 (TestbedService)：定义节点上运行的服务
# 7. 检查层 (TestbedCheck)：定义网络连通性验证
# 这种分层设计使得TOML配置可以被递归解析和验证。

# 测试床时间模式常量
const TESTBED_TIME_MODES = (:simulated, :realtime, :accelerated, :manual)

# 通道管理器运行模式常量
const CHANNEL_MANAGER_MODES = (:dry_run, :linux_route, :network_namespace, :docker, :vm)

# 通道管理器执行目标常量
const CHANNEL_MANAGER_EXECUTION_TARGETS = (:host, :container, :vm, :merge_node)

# 通道管理器路由范围常量
const CHANNEL_MANAGER_ROUTE_SCOPES = (:source, :destination, :bidirectional, :cm_switch)

# 测试床后端类型常量
const TESTBED_BACKENDS = (:inherit, :dry_run, :namespace, :docker, :vm, :merge)

# 测试床清理策略常量
const TESTBED_CLEANUP_POLICIES = (:manual, :on_success, :always, :never)

# 测试床网络类型常量
const TESTBED_NETWORK_KINDS = (:data, :control, :soc, :internet)

# 测试床节点类型常量
const TESTBED_NODE_KINDS = (:ground, :satellite, :soc, :attacker, :gateway, :router, :channel_manager)

# 测试床端点类型常量
const TESTBED_ENDPOINT_KINDS = (:ground, :satellite)

# 测试床链接类型常量
const TESTBED_LINK_KINDS = (:gsl, :isl, :terrestrial, :control, :internet)

# 测试床延迟数据来源常量
const TESTBED_LATENCY_SOURCES = (:none, :oef, :model, :trace, :manual)

# 测试床丢包数据来源常量
const TESTBED_LOSS_SOURCES = (:none, :model, :trace, :manual)

# 测试床服务类型常量
const TESTBED_SERVICE_KINDS = (:http, :ssh, :custom, :mission_payload, :monitoring)

# 测试床检查类型常量
const TESTBED_CHECK_KINDS = (:ping, :curl, :scan, :custom)

"""
    require_nonempty(value::AbstractString, field_name::AbstractString) -> String

验证字符串非空，去除首尾空白后检查，若为空则抛出错误。

# 参数
- `value::AbstractString`：待验证的字符串值
- `field_name::AbstractString`：字段名称，用于错误提示

# 返回
- `String`：去除空白后的非空字符串

# 异常
- `ArgumentError`：当字符串为空时抛出
"""
function require_nonempty(value::AbstractString, field_name::AbstractString)::String
    stripped = strip(value)
    !isempty(stripped) || throw(ArgumentError("$field_name must not be empty"))
    return String(stripped)
end

"""
    require_allowed(value::Symbol, allowed::Tuple, field_name::AbstractString) -> Symbol

验证符号值在允许的枚举范围内。

# 参数
- `value::Symbol`：待验证的符号值
- `allowed::Tuple`：允许的符号值元组
- `field_name::AbstractString`：字段名称，用于错误提示

# 返回
- `Symbol`：验证通过的符号值

# 异常
- `ArgumentError`：当值不在允许范围内时抛出
"""
function require_allowed(value::Symbol, allowed::Tuple, field_name::AbstractString)::Symbol
    value in allowed || throw(ArgumentError("$field_name must be one of $(allowed)"))
    return value
end

"""
    TestbedScenario

测试床场景描述，定义测试床的基本信息和时间模式。

# 字段
- `id::String`：场景唯一标识符
- `name::String`：场景名称
- `description::String`：场景描述（可为空）
- `time_mode::Symbol`：时间模式，取值范围 `TESTBED_TIME_MODES`
  - `:simulated`：模拟时间
  - `:realtime`：实时
  - `:accelerated`：加速时间
  - `:manual`：手动控制时间
- `oef_path::String`：OEF（Orbital Environment Framework）配置文件路径

# 构造函数关键字参数
- `id::AbstractString`：场景唯一标识符（必填）
- `name::AbstractString`：场景名称（必填）
- `description::AbstractString = ""`：场景描述（可选）
- `time_mode::Symbol`：时间模式（必填）
- `oef_path::AbstractString`：OEF 配置文件路径（必填）
"""
struct TestbedScenario
    id::String
    name::String
    description::String
    time_mode::Symbol
    oef_path::String

    function TestbedScenario(;
        id::AbstractString,
        name::AbstractString,
        description::AbstractString = "",
        time_mode::Symbol,
        oef_path::AbstractString,
    )
        return new(
            require_nonempty(id, "scenario id"),
            require_nonempty(name, "scenario name"),
            String(description),
            require_allowed(time_mode, TESTBED_TIME_MODES, "scenario time_mode"),
            require_nonempty(oef_path, "scenario oef_path"),
        )
    end
end

"""
    ChannelManagerSpec

通道管理器配置，定义网络模拟的核心组件参数。

# 字段
- `id::String`：通道管理器唯一标识符
- `mode::Symbol`：运行模式，取值范围 `CHANNEL_MANAGER_MODES`
  - `:dry_run`：干运行模式，只做模拟不实际修改网络
  - `:linux_route`：使用 Linux 路由表
  - `:network_namespace`：使用网络命名空间
  - `:docker`：使用 Docker 网络
  - `:vm`：使用虚拟机网络
- `input_oef::String`：输入的 OEF 配置文件路径
- `execution_target::Symbol`：执行目标，取值范围 `CHANNEL_MANAGER_EXECUTION_TARGETS`
  - `:host`：在宿主机上执行
  - `:container`：在容器中执行
  - `:vm`：在虚拟机中执行
  - `:merge_node`：合并到节点执行
- `route_scope::Symbol`：路由范围，取值范围 `CHANNEL_MANAGER_ROUTE_SCOPES`
  - `:source`：源端路由
  - `:destination`：目标端路由
  - `:bidirectional`：双向路由
  - `:cm_switch`：通道管理器交换机模式

# 构造函数关键字参数
- `id::AbstractString`：通道管理器唯一标识符（必填）
- `mode::Symbol`：运行模式（必填）
- `input_oef::AbstractString`：输入的 OEF 配置文件路径（必填）
- `execution_target::Symbol`：执行目标（必填）
- `route_scope::Symbol`：路由范围（必填）
"""
struct ChannelManagerSpec
    id::String
    mode::Symbol
    input_oef::String
    execution_target::Symbol
    route_scope::Symbol

    function ChannelManagerSpec(;
        id::AbstractString,
        mode::Symbol,
        input_oef::AbstractString,
        execution_target::Symbol,
        route_scope::Symbol,
    )
        return new(
            require_nonempty(id, "channel_manager id"),
            require_allowed(mode, CHANNEL_MANAGER_MODES, "channel_manager mode"),
            require_nonempty(input_oef, "channel_manager input_oef"),
            require_allowed(execution_target, CHANNEL_MANAGER_EXECUTION_TARGETS, "channel_manager execution_target"),
            require_allowed(route_scope, CHANNEL_MANAGER_ROUTE_SCOPES, "channel_manager route_scope"),
        )
    end
end

"""
    TestbedEnvironment

测试床环境配置，定义部署环境和清理策略。

# 字段
- `backend::Symbol`：后端类型，取值范围 `TESTBED_BACKENDS`
  - `:inherit`：继承父级配置
  - `:dry_run`：干运行模式
  - `:namespace`：使用网络命名空间
  - `:docker`：使用 Docker
  - `:vm`：使用虚拟机
  - `:merge`：合并模式
- `name_prefix::String`：运行时名称前缀，用于生成资源名称
- `work_dir::String`：工作目录，用于存放生成的配置文件
- `cleanup_policy::Symbol`：清理策略，取值范围 `TESTBED_CLEANUP_POLICIES`
  - `:manual`：手动清理
  - `:on_success`：成功后清理
  - `:always`：总是清理
  - `:never`：从不清理

# 构造函数关键字参数
- `backend::Symbol`：后端类型（必填）
- `name_prefix::AbstractString`：运行时名称前缀（必填）
- `work_dir::AbstractString`：工作目录（必填）
- `cleanup_policy::Symbol`：清理策略（必填）
"""
struct TestbedEnvironment
    backend::Symbol
    name_prefix::String
    work_dir::String
    cleanup_policy::Symbol

    function TestbedEnvironment(;
        backend::Symbol,
        name_prefix::AbstractString,
        work_dir::AbstractString,
        cleanup_policy::Symbol,
    )
        return new(
            require_allowed(backend, TESTBED_BACKENDS, "environment backend"),
            require_nonempty(name_prefix, "environment name_prefix"),
            require_nonempty(work_dir, "environment work_dir"),
            require_allowed(cleanup_policy, TESTBED_CLEANUP_POLICIES, "environment cleanup_policy"),
        )
    end
end

"""
    TestbedNetwork

测试床网络配置，定义一个网络的属性。

# 字段
- `id::String`：网络唯一标识符
- `kind::Symbol`：网络类型，取值范围 `TESTBED_NETWORK_KINDS`
  - `:data`：数据网络
  - `:control`：控制网络
  - `:soc`：安全运营中心网络
  - `:internet`：互联网网络
- `subnet::String`：子网 CIDR（如 "192.168.1.0/24"），空字符串表示无指定子网
- `gateway::String`：网关地址，空字符串表示无指定网关
- `backend::Symbol`：网络后端类型，取值范围 `TESTBED_BACKENDS`

# 构造函数关键字参数
- `id::AbstractString`：网络唯一标识符（必填）
- `kind::Symbol`：网络类型（必填）
- `subnet::AbstractString = ""`：子网 CIDR（可选）
- `gateway::AbstractString = ""`：网关地址（可选）
- `backend::Symbol`：网络后端类型（必填）
"""
struct TestbedNetwork
    id::String
    kind::Symbol
    subnet::String
    gateway::String
    backend::Symbol

    function TestbedNetwork(;
        id::AbstractString,
        kind::Symbol,
        subnet::AbstractString = "",
        gateway::AbstractString = "",
        backend::Symbol,
    )
        return new(
            require_nonempty(id, "network id"),
            require_allowed(kind, TESTBED_NETWORK_KINDS, "network kind"),
            String(strip(subnet)),
            String(strip(gateway)),
            require_allowed(backend, TESTBED_BACKENDS, "network backend"),
        )
    end
end

"""
    TestbedNode

测试床节点配置，定义一个节点的属性和资源需求。

# 字段
- `id::String`：节点唯一标识符
- `kind::Symbol`：节点类型，取值范围 `TESTBED_NODE_KINDS`
  - `:ground`：地面站节点
  - `:satellite`：卫星节点
  - `:soc`：安全运营中心节点
  - `:attacker`：攻击者节点
  - `:gateway`：网关节点
  - `:router`：路由器节点
  - `:channel_manager`：通道管理器节点
- `role::Symbol`：节点角色（不限制枚举）
- `endpoint_kind::Symbol`：OEF 端点类型，取值范围 `TESTBED_ENDPOINT_KINDS`
  - `:ground`：地面端点
  - `:satellite`：卫星端点
- `endpoint_id::Int`：OEF 端点编号（必须为正整数）
- `ip::String`：节点 IP 地址
- `image::String`：镜像标识符（可为空，由镜像目录解析）
- `namespace::String`：命名空间（可为空）
- `container_image::String`：容器镜像（可为空）
- `vm_image::String`：虚拟机镜像（可为空）
- `cpu_cores::Int`：CPU 核心数（必须为正整数）
- `memory_mb::Int`：内存大小（MB，必须为正整数）
- `ssh_user::String`：SSH 用户名（可为空）
- `control_network::String`：控制网络 ID（可为空）
- `backend::Symbol`：节点后端类型，取值范围 `TESTBED_BACKENDS`
- `primary_network::String`：主网络 ID
- `primary_interface::String`：主网络接口名称

# 构造函数关键字参数
- `id::AbstractString`：节点唯一标识符（必填）
- `kind::Symbol`：节点类型（必填）
- `role::Symbol`：节点角色（必填）
- `endpoint_kind::Symbol`：OEF 端点类型（必填）
- `endpoint_id::Int`：OEF 端点编号（必填，必须为正整数）
- `ip::AbstractString`：节点 IP 地址（必填）
- `image::AbstractString = ""`：镜像标识符（可选）
- `namespace::AbstractString = ""`：命名空间（可选）
- `container_image::AbstractString = ""`：容器镜像（可选）
- `vm_image::AbstractString = ""`：虚拟机镜像（可选）
- `cpu_cores::Int = 1`：CPU 核心数（可选，必须为正整数）
- `memory_mb::Int = 512`：内存大小（可选，必须为正整数）
- `ssh_user::AbstractString = ""`：SSH 用户名（可选）
- `control_network::AbstractString = ""`：控制网络 ID（可选）
- `backend::Symbol = :inherit`：节点后端类型（可选，默认继承）
- `primary_network::AbstractString`：主网络 ID（必填）
- `primary_interface::AbstractString`：主网络接口名称（必填）

# 异常
- `ArgumentError`：当 `endpoint_id`、`cpu_cores` 或 `memory_mb` 不为正整数时抛出
"""
struct TestbedNode
    id::String
    kind::Symbol
    role::Symbol
    endpoint_kind::Symbol
    endpoint_id::Int
    ip::String
    image::String
    namespace::String
    container_image::String
    vm_image::String
    cpu_cores::Int
    memory_mb::Int
    ssh_user::String
    control_network::String
    backend::Symbol
    primary_network::String
    primary_interface::String

    function TestbedNode(;
        id::AbstractString,
        kind::Symbol,
        role::Symbol,
        endpoint_kind::Symbol,
        endpoint_id::Int,
        ip::AbstractString,
        image::AbstractString = "",
        namespace::AbstractString = "",
        container_image::AbstractString = "",
        vm_image::AbstractString = "",
        cpu_cores::Int = 1,
        memory_mb::Int = 512,
        ssh_user::AbstractString = "",
        control_network::AbstractString = "",
        backend::Symbol = :inherit,
        primary_network::AbstractString,
        primary_interface::AbstractString,
    )
        endpoint_id > 0 || throw(ArgumentError("node endpoint_id must be positive"))
        cpu_cores > 0 || throw(ArgumentError("node cpu_cores must be positive"))
        memory_mb > 0 || throw(ArgumentError("node memory_mb must be positive"))
        return new(
            require_nonempty(id, "node id"),
            require_allowed(kind, TESTBED_NODE_KINDS, "node kind"),
            role,
            require_allowed(endpoint_kind, TESTBED_ENDPOINT_KINDS, "node endpoint_kind"),
            endpoint_id,
            require_nonempty(ip, "node ip"),
            String(strip(image)),
            String(strip(namespace)),
            String(strip(container_image)),
            String(strip(vm_image)),
            cpu_cores,
            memory_mb,
            String(strip(ssh_user)),
            String(strip(control_network)),
            require_allowed(backend, TESTBED_BACKENDS, "node backend"),
            require_nonempty(primary_network, "node primary_network"),
            require_nonempty(primary_interface, "node primary_interface"),
        )
    end
end

"""
    TestbedLink

测试床链接配置，定义两个节点之间的连接。

# 字段
- `id::String`：链接唯一标识符
- `kind::Symbol`：链接类型，取值范围 `TESTBED_LINK_KINDS`
  - `:gsl`：地面-卫星链路（Ground-Satellite Link）
  - `:isl`：星间链路（Inter-Satellite Link）
  - `:terrestrial`：地面链路
  - `:control`：控制链路
  - `:internet`：互联网链路
- `endpoint_a::String`：端点 A 的节点 ID
- `endpoint_b::String`：端点 B 的节点 ID
- `oef_link_type::Symbol`：OEF 链路类型（`:gsl` 或 `:isl`）
- `network::String`：链接所属的网络 ID
- `bandwidth_mbps::Float64`：带宽（Mbps，必须为非负数）
- `latency_source::Symbol`：延迟数据来源，取值范围 `TESTBED_LATENCY_SOURCES`
  - `:none`：无延迟
  - `:oef`：从 OEF 获取
  - `:model`：从模型计算
  - `:trace`：从轨迹文件读取
  - `:manual`：手动指定
- `loss_source::Symbol`：丢包数据来源，取值范围 `TESTBED_LOSS_SOURCES`
  - `:none`：无丢包
  - `:model`：从模型计算
  - `:trace`：从轨迹文件读取
  - `:manual`：手动指定

# 构造函数关键字参数
- `id::AbstractString`：链接唯一标识符（必填）
- `kind::Symbol`：链接类型（必填）
- `endpoint_a::AbstractString`：端点 A 的节点 ID（必填）
- `endpoint_b::AbstractString`：端点 B 的节点 ID（必填）
- `oef_link_type::Symbol`：OEF 链路类型（必填）
- `network::AbstractString`：链接所属的网络 ID（必填）
- `bandwidth_mbps::Real`：带宽（必填，必须为非负数）
- `latency_source::Symbol`：延迟数据来源（必填）
- `loss_source::Symbol`：丢包数据来源（必填）

# 异常
- `ArgumentError`：当 `bandwidth_mbps` 为负数时抛出
"""
struct TestbedLink
    id::String
    kind::Symbol
    endpoint_a::String
    endpoint_b::String
    oef_link_type::Symbol
    network::String
    bandwidth_mbps::Float64
    latency_source::Symbol
    loss_source::Symbol

    function TestbedLink(;
        id::AbstractString,
        kind::Symbol,
        endpoint_a::AbstractString,
        endpoint_b::AbstractString,
        oef_link_type::Symbol,
        network::AbstractString,
        bandwidth_mbps::Real,
        latency_source::Symbol,
        loss_source::Symbol,
    )
        bandwidth_mbps >= 0 || throw(ArgumentError("link bandwidth_mbps must be non-negative"))
        return new(
            require_nonempty(id, "link id"),
            require_allowed(kind, TESTBED_LINK_KINDS, "link kind"),
            require_nonempty(endpoint_a, "link endpoint_a"),
            require_nonempty(endpoint_b, "link endpoint_b"),
            require_allowed(oef_link_type, (:gsl, :isl), "link oef_link_type"),
            require_nonempty(network, "link network"),
            Float64(bandwidth_mbps),
            require_allowed(latency_source, TESTBED_LATENCY_SOURCES, "link latency_source"),
            require_allowed(loss_source, TESTBED_LOSS_SOURCES, "link loss_source"),
        )
    end
end

"""
    TestbedService

测试床服务配置，定义节点上运行的服务。

# 字段
- `id::String`：服务唯一标识符
- `node::String`：服务所在的节点 ID
- `kind::Symbol`：服务类型，取值范围 `TESTBED_SERVICE_KINDS`
  - `:http`：HTTP 服务
  - `:ssh`：SSH 服务
  - `:custom`：自定义服务
  - `:mission_payload`：任务载荷服务
  - `:monitoring`：监控服务
- `command::String`：启动命令
- `port::Int`：服务端口（1-65535）
- `enabled::Bool`：是否启用该服务

# 构造函数关键字参数
- `id::AbstractString`：服务唯一标识符（必填）
- `node::AbstractString`：服务所在的节点 ID（必填）
- `kind::Symbol`：服务类型（必填）
- `command::AbstractString = ""`：启动命令（可选）
- `port::Int`：服务端口（必填）
- `enabled::Bool`：是否启用（必填）

# 异常
- `ArgumentError`：当 `port` 不在 [1, 65535] 范围内时抛出
"""
struct TestbedService
    id::String
    node::String
    kind::Symbol
    command::String
    port::Int
    enabled::Bool

    function TestbedService(;
        id::AbstractString,
        node::AbstractString,
        kind::Symbol,
        command::AbstractString = "",
        port::Int,
        enabled::Bool,
    )
        1 <= port <= 65535 || throw(ArgumentError("service port must be in [1, 65535]"))
        return new(
            require_nonempty(id, "service id"),
            require_nonempty(node, "service node"),
            require_allowed(kind, TESTBED_SERVICE_KINDS, "service kind"),
            String(command),
            port,
            enabled,
        )
    end
end

"""
    TestbedCheck

测试床检查配置，定义网络连通性检查。

# 字段
- `id::String`：检查唯一标识符
- `from::String`：发起检查的节点 ID
- `to::String`：目标节点 ID
- `kind::Symbol`：检查类型，取值范围 `TESTBED_CHECK_KINDS`
  - `:ping`：Ping 检查
  - `:curl`：HTTP 检查
  - `:scan`：端口扫描
  - `:custom`：自定义检查
- `target::String`：检查目标（IP 或域名）
- `enabled::Bool`：是否启用该检查

# 构造函数关键字参数
- `id::AbstractString`：检查唯一标识符（必填）
- `from::AbstractString`：发起检查的节点 ID（必填）
- `to::AbstractString`：目标节点 ID（必填）
- `kind::Symbol`：检查类型（必填）
- `target::AbstractString`：检查目标（必填）
- `enabled::Bool`：是否启用（必填）
"""
struct TestbedCheck
    id::String
    from::String
    to::String
    kind::Symbol
    target::String
    enabled::Bool

    function TestbedCheck(;
        id::AbstractString,
        from::AbstractString,
        to::AbstractString,
        kind::Symbol,
        target::AbstractString,
        enabled::Bool,
    )
        return new(
            require_nonempty(id, "check id"),
            require_nonempty(from, "check from"),
            require_nonempty(to, "check to"),
            require_allowed(kind, TESTBED_CHECK_KINDS, "check kind"),
            require_nonempty(target, "check target"),
            enabled,
        )
    end
end

"""
    TestbedSpec

完整的测试床规格，包含场景、环境、网络、节点、链接、服务和检查。

# 字段
- `scenario::TestbedScenario`：场景配置
- `channel_manager::ChannelManagerSpec`：通道管理器配置
- `environment::TestbedEnvironment`：环境配置
- `networks::Vector{TestbedNetwork}`：网络配置列表
- `nodes::Vector{TestbedNode}`：节点配置列表
- `links::Vector{TestbedLink}`：链接配置列表
- `services::Vector{TestbedService}`：服务配置列表
- `checks::Vector{TestbedCheck}`：检查配置列表

# 构造函数关键字参数
- `scenario::TestbedScenario`：场景配置（必填）
- `channel_manager::ChannelManagerSpec`：通道管理器配置（必填）
- `environment::TestbedEnvironment`：环境配置（必填）
- `networks::Vector{TestbedNetwork}`：网络配置列表（必填，至少一个网络）
- `nodes::Vector{TestbedNode}`：节点配置列表（必填，至少一个节点）
- `links::Vector{TestbedLink}`：链接配置列表（必填）
- `services::Vector{TestbedService} = TestbedService[]`：服务配置列表（可选）
- `checks::Vector{TestbedCheck} = TestbedCheck[]`：检查配置列表（可选）

# 异常
- `ArgumentError`：当 `networks` 或 `nodes` 为空时抛出
"""
struct TestbedSpec
    scenario::TestbedScenario
    channel_manager::ChannelManagerSpec
    environment::TestbedEnvironment
    networks::Vector{TestbedNetwork}
    nodes::Vector{TestbedNode}
    links::Vector{TestbedLink}
    services::Vector{TestbedService}
    checks::Vector{TestbedCheck}

    function TestbedSpec(;
        scenario::TestbedScenario,
        channel_manager::ChannelManagerSpec,
        environment::TestbedEnvironment,
        networks::Vector{TestbedNetwork},
        nodes::Vector{TestbedNode},
        links::Vector{TestbedLink},
        services::Vector{TestbedService} = TestbedService[],
        checks::Vector{TestbedCheck} = TestbedCheck[],
    )
        !isempty(networks) || throw(ArgumentError("testbed spec must contain at least one network"))
        !isempty(nodes) || throw(ArgumentError("testbed spec must contain at least one node"))
        return new(scenario, channel_manager, environment, networks, nodes, links, services, checks)
    end
end

"""
    required_table(raw::Dict, key::AbstractString) -> Dict

从字典中获取必需的 TOML 表，若不存在或类型不符则抛出错误。

# 参数
- `raw::Dict`：原始 TOML 解析结果字典
- `key::AbstractString`：表键名

# 返回
- `Dict`：对应的 TOML 表

# 异常
- `ArgumentError`：当键不存在或值不是 Dict 类型时抛出
"""
function required_table(raw::Dict, key::AbstractString)::Dict
    haskey(raw, key) || throw(ArgumentError("missing required table: $key"))
    value = raw[key]
    value isa Dict || throw(ArgumentError("table $key must be a TOML table"))
    return value
end

"""
    required_array(raw::Dict, key::AbstractString) -> Vector

从字典中获取必需的 TOML 数组，若不存在或类型不符则抛出错误。

# 参数
- `raw::Dict`：原始 TOML 解析结果字典
- `key::AbstractString`：数组键名

# 返回
- `Vector`：对应的 TOML 数组

# 异常
- `ArgumentError`：当键不存在或值不是 Vector 类型时抛出
"""
function required_array(raw::Dict, key::AbstractString)::Vector
    haskey(raw, key) || throw(ArgumentError("missing required array: $key"))
    value = raw[key]
    value isa Vector || throw(ArgumentError("array $key must be a TOML array"))
    return value
end

"""
    required_value(raw::Dict, key::AbstractString)

从字典中获取必需的值，若不存在则抛出错误。

# 参数
- `raw::Dict`：原始 TOML 解析结果字典
- `key::AbstractString`：键名

# 返回
- 对应的值

# 异常
- `ArgumentError`：当键不存在时抛出
"""
function required_value(raw::Dict, key::AbstractString)
    haskey(raw, key) || throw(ArgumentError("missing required field: $key"))
    return raw[key]
end

"""
    symbol_value(raw::Dict, key::AbstractString) -> Symbol

从字典中获取值并转换为 Symbol 类型。
"""
symbol_value(raw::Dict, key::AbstractString)::Symbol = Symbol(String(required_value(raw, key)))

"""
    string_value(raw::Dict, key::AbstractString) -> String

从字典中获取值并转换为 String 类型。
"""
string_value(raw::Dict, key::AbstractString)::String = String(required_value(raw, key))

"""
    int_value(raw::Dict, key::AbstractString) -> Int

从字典中获取值并转换为 Int 类型。
"""
int_value(raw::Dict, key::AbstractString)::Int = Int(required_value(raw, key))

"""
    float_value(raw::Dict, key::AbstractString) -> Float64

从字典中获取值并转换为 Float64 类型。
"""
float_value(raw::Dict, key::AbstractString)::Float64 = Float64(required_value(raw, key))

"""
    bool_value(raw::Dict, key::AbstractString) -> Bool

从字典中获取值并转换为 Bool 类型。
"""
bool_value(raw::Dict, key::AbstractString)::Bool = Bool(required_value(raw, key))

# [算法说明]
# TOML配置解析采用"必需字段验证 + 可选字段默认值"的策略：
# 1. required_table/required_array/required_value：强制校验，缺失则抛出异常
# 2. get(dict, key, default)：提供可选字段的默认值
# 3. symbol_value/string_value/int_value：类型转换并校验
# 4. require_allowed：枚举值范围校验
# 解析顺序：先解析顶层节（scenario, channel_manager, environment），
# 再解析数组节（networks, nodes, links, services, checks），
# 每个数组元素递归解析其字段。
"""
    load_testbed_spec(path::AbstractString) -> TestbedSpec

从 TOML 文件加载测试床规格。

# 参数
- `path::AbstractString`：TOML 配置文件路径

# 返回
- `TestbedSpec`：解析后的测试床规格

# 异常
- `ArgumentError`：当必需字段缺失或类型不符时抛出
- `SystemError`：当文件不存在或无法读取时抛出

# TOML 文件结构
文件应包含以下节（section）：
- `scenario`：场景配置（必需）
  - `id`：场景 ID（必需）
  - `name`：场景名称（必需）
  - `description`：场景描述（可选）
  - `time_mode`：时间模式（必需）
  - `oef_path`：OEF 路径（必需）
- `channel_manager`：通道管理器配置（必需）
  - `id`：通道管理器 ID（必需）
  - `mode`：运行模式（必需）
  - `input_oef`：输入 OEF 路径（必需）
  - `execution_target`：执行目标（必需）
  - `route_scope`：路由范围（必需）
- `environment`：环境配置（必需）
  - `backend`：后端类型（必需）
  - `name_prefix`：名称前缀（必需）
  - `work_dir`：工作目录（必需）
  - `cleanup_policy`：清理策略（必需）
- `networks`：网络数组（必需，至少一个）
  - `id`：网络 ID（必需）
  - `kind`：网络类型（必需）
  - `subnet`：子网（可选）
  - `gateway`：网关（可选）
  - `backend`：后端（必需）
- `nodes`：节点数组（必需，至少一个）
  - `id`：节点 ID（必需）
  - `kind`：节点类型（必需）
  - `role`：节点角色（必需）
  - `endpoint_kind`：端点类型（必需）
  - `endpoint_id`：端点 ID（必需）
  - `ip`：IP 地址（必需）
  - `image`：镜像（可选）
  - `namespace`：命名空间（可选）
  - `container_image`：容器镜像（可选）
  - `vm_image`：虚拟机镜像（可选）
  - `cpu_cores`：CPU 核心数（可选，默认 1）
  - `memory_mb`：内存大小（可选，默认 512）
  - `ssh_user`：SSH 用户（可选）
  - `control_network`：控制网络（可选）
  - `backend`：后端（可选，默认 inherit）
  - `primary_network`：主网络（必需）
  - `primary_interface`：主接口（必需）
- `links`：链接数组（必需）
  - `id`：链接 ID（必需）
  - `kind`：链接类型（必需）
  - `endpoint_a`：端点 A（必需）
  - `endpoint_b`：端点 B（必需）
  - `oef_link_type`：OEF 链路类型（必需）
  - `network`：网络 ID（必需）
  - `bandwidth_mbps`：带宽（必需）
  - `latency_source`：延迟来源（必需）
  - `loss_source`：丢包来源（必需）
- `services`：服务数组（可选）
  - `id`：服务 ID（必需）
  - `node`：节点 ID（必需）
  - `kind`：服务类型（必需）
  - `command`：命令（可选）
  - `port`：端口（必需）
  - `enabled`：是否启用（必需）
- `checks`：检查数组（可选）
  - `id`：检查 ID（必需）
  - `from`：源节点（必需）
  - `to`：目标节点（必需）
  - `kind`：检查类型（必需）
  - `target`：检查目标（必需）
  - `enabled`：是否启用（必需）
"""
function load_testbed_spec(path::AbstractString)::TestbedSpec
    # [执行流程]
    # 步骤1: 使用 TOML.parsefile() 将文件解析为嵌套字典
    raw = TOML.parsefile(path)
    # 步骤2: 提取三个必需的顶层节（scenario, channel_manager, environment）
    scenario = required_table(raw, "scenario")
    channel_manager = required_table(raw, "channel_manager")
    environment = required_table(raw, "environment")

    # 步骤3: 递归解析各节为类型化结构体，组装为完整的 TestbedSpec
    # - scenario/channel_manager/environment：直接从字典字段构造
    # - networks/nodes/links：使用数组推导式遍历 TOML 数组，逐个构造
    # - services/checks：使用 get() 提供默认空数组（可选节）
    # - 每个字段通过 string_value/symbol_value/int_value/float_value/bool_value 进行类型转换
    # - 可选字段使用 get(dict, key, default) 提供默认值
    # - 必需字段通过 required_* 系列函数校验缺失
    return TestbedSpec(
        scenario = TestbedScenario(
            id = string_value(scenario, "id"),
            name = string_value(scenario, "name"),
            description = String(get(scenario, "description", "")),
            time_mode = symbol_value(scenario, "time_mode"),
            oef_path = string_value(scenario, "oef_path"),
        ),
        channel_manager = ChannelManagerSpec(
            id = string_value(channel_manager, "id"),
            mode = symbol_value(channel_manager, "mode"),
            input_oef = string_value(channel_manager, "input_oef"),
            execution_target = symbol_value(channel_manager, "execution_target"),
            route_scope = symbol_value(channel_manager, "route_scope"),
        ),
        environment = TestbedEnvironment(
            backend = symbol_value(environment, "backend"),
            name_prefix = string_value(environment, "name_prefix"),
            work_dir = string_value(environment, "work_dir"),
            cleanup_policy = symbol_value(environment, "cleanup_policy"),
        ),
        networks = [
            TestbedNetwork(
                id = string_value(network, "id"),
                kind = symbol_value(network, "kind"),
                subnet = String(get(network, "subnet", "")),
                gateway = String(get(network, "gateway", "")),
                backend = symbol_value(network, "backend"),
            )
            for network in required_array(raw, "networks")
        ],
        nodes = [
            TestbedNode(
                id = string_value(node, "id"),
                kind = symbol_value(node, "kind"),
                role = symbol_value(node, "role"),
                endpoint_kind = symbol_value(node, "endpoint_kind"),
                endpoint_id = int_value(node, "endpoint_id"),
                ip = string_value(node, "ip"),
                image = String(get(node, "image", "")),
                namespace = String(get(node, "namespace", "")),
                container_image = String(get(node, "container_image", "")),
                vm_image = String(get(node, "vm_image", "")),
                cpu_cores = Int(get(node, "cpu_cores", 1)),
                memory_mb = Int(get(node, "memory_mb", 512)),
                ssh_user = String(get(node, "ssh_user", "")),
                control_network = String(get(node, "control_network", "")),
                backend = symbol_value(node, "backend"),
                primary_network = string_value(node, "primary_network"),
                primary_interface = string_value(node, "primary_interface"),
            )
            for node in required_array(raw, "nodes")
        ],
        links = [
            TestbedLink(
                id = string_value(link, "id"),
                kind = symbol_value(link, "kind"),
                endpoint_a = string_value(link, "endpoint_a"),
                endpoint_b = string_value(link, "endpoint_b"),
                oef_link_type = symbol_value(link, "oef_link_type"),
                network = string_value(link, "network"),
                bandwidth_mbps = float_value(link, "bandwidth_mbps"),
                latency_source = symbol_value(link, "latency_source"),
                loss_source = symbol_value(link, "loss_source"),
            )
            for link in required_array(raw, "links")
        ],
        services = [
            TestbedService(
                id = string_value(service, "id"),
                node = string_value(service, "node"),
                kind = symbol_value(service, "kind"),
                command = String(get(service, "command", "")),
                port = int_value(service, "port"),
                enabled = bool_value(service, "enabled"),
            )
            for service in Vector(get(raw, "services", []))
        ],
        checks = [
            TestbedCheck(
                id = string_value(check, "id"),
                from = string_value(check, "from"),
                to = string_value(check, "to"),
                kind = symbol_value(check, "kind"),
                target = string_value(check, "target"),
                enabled = bool_value(check, "enabled"),
            )
            for check in Vector(get(raw, "checks", []))
        ],
    )
end

"""
    print_testbed_spec(io::IO, spec::TestbedSpec) -> Nothing

以可读格式打印测试床规格到指定的 IO 流。

# 参数
- `io::IO`：输出 IO 流
- `spec::TestbedSpec`：待打印的测试床规格

# 返回
- `Nothing`
"""
function print_testbed_spec(io::IO, spec::TestbedSpec)::Nothing
    println(io, "TestbedSpec: $(spec.scenario.id)")
    println(io, "  name: $(spec.scenario.name)")
    println(io, "  time_mode: $(spec.scenario.time_mode)")
    println(io, "  oef_path: $(spec.scenario.oef_path)")
    println(io, "  environment: backend=$(spec.environment.backend) work_dir=$(spec.environment.work_dir)")
    println(io, "  channel_manager: $(spec.channel_manager.id) mode=$(spec.channel_manager.mode) route_scope=$(spec.channel_manager.route_scope)")

    println(io, "  networks:")
    for network in spec.networks
        subnet = isempty(network.subnet) ? "none" : network.subnet
        println(io, "    $(network.id) kind=$(network.kind) subnet=$subnet backend=$(network.backend)")
    end

    println(io, "  nodes:")
    for node in spec.nodes
        println(
            io,
            "    $(node.id) kind=$(node.kind) role=$(node.role) ip=$(node.ip) OEF=$(node.endpoint_kind):$(node.endpoint_id) backend=$(node.backend)",
        )
    end

    println(io, "  links:")
    for link in spec.links
        println(
            io,
            "    $(link.id) kind=$(link.kind) $(link.endpoint_a) -> $(link.endpoint_b) network=$(link.network) oef_link_type=$(link.oef_link_type)",
        )
    end

    println(io, "  services:")
    if isempty(spec.services)
        println(io, "    none")
    else
        for service in spec.services
            println(io, "    $(service.id) node=$(service.node) kind=$(service.kind) port=$(service.port) enabled=$(service.enabled)")
        end
    end

    println(io, "  checks:")
    if isempty(spec.checks)
        println(io, "    none")
    else
        for check in spec.checks
            println(io, "    $(check.id) $(check.from) -> $(check.to) kind=$(check.kind) target=$(check.target) enabled=$(check.enabled)")
        end
    end
    return nothing
end

"""
    print_testbed_spec(spec::TestbedSpec) -> Nothing

以可读格式打印测试床规格到标准输出。

# 参数
- `spec::TestbedSpec`：待打印的测试床规格

# 返回
- `Nothing`
"""
print_testbed_spec(spec::TestbedSpec)::Nothing = print_testbed_spec(stdout, spec)