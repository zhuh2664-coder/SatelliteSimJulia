#=
本文件：src/deploy/materialization/runtime_endpoint_registry.jl

职责：
- 定义运行时端点注册表（RuntimeEndpointRegistry）及其组成类型。
- 将物化阶段生成的静态节点信息（TestbedMaterializationPlan）转换为运行时可访问的端点记录。
- 提供注册表的 JSON 读写、运行时 IP 刷新、端点查找与序列化。

在项目流水线中的位置：
- 上游：deploy/materialization/testbed_materialization.jl 生成的 TestbedMaterializationPlan。
- 下游：deploy/channel_manager/channel_manager.jl 在回放 OEF 时可用注册表动态解析 VM IP/hostname；
  外部脚本也可通过 runtime_endpoints.json 发现并访问各节点服务。

数据流说明：
- 构建注册表（静态阶段）：
  → build_runtime_endpoint_registry(spec, materialization) 是核心入口
  → 遍历 materialization.nodes，对每个物化节点：
    → find_spec_node() 查找原始规格节点
    → runtime_endpoint_from_node() 合并规格和物化信息，构建 RuntimeEndpoint
    → services_for_node() + build_runtime_endpoint_service() 生成服务条目
  → 组装为 RuntimeEndpointRegistry
  → write_runtime_endpoint_registry() 序列化为 JSON 文件（runtime_endpoints.json）
- 刷新 IP（运行时阶段）：
  → refresh_runtime_endpoint_registry(registry) 刷新所有端点的动态 IP
  → lima_runtime_ip_resolver() 通过 limactl shell 在 VM 内部解析 hostname → IP
  → runtime_endpoint_with_ip() 创建更新 IP 后的新端点记录（不可变结构体）
  → 返回 (refreshed_registry, results)，原注册表不变（纯函数设计）
  → refresh_runtime_endpoint_registry_file() 是便捷封装：读取→刷新→写回
- JSON 序列化/反序列化：
  → write：runtime_endpoint_registry_dict() → JSON.print() → 磁盘文件
  → read：JSON.parsefile() → read_runtime_endpoint_registry() → 内存对象
- 下游消费：
  → channel_manager.jl 的 VMRouteChannelManager 读取注册表
  → find_runtime_endpoint() 按 OEF 端点查找运行时端点
  → 获取 runtime_hostname 和 runtime_ip 用于生成 limactl 路由命令
- 辅助数据流：
  → runtime_endpoint_label()：生成端点标签 "kind:id"
  → find_runtime_endpoint()：按 OEF 端点查找运行时端点
  → runtime_endpoint_refresh_result_dict()：将刷新结果序列化为字典

[算法说明]
本文件实现了运行时端点注册表系统，核心算法包括：

1. **注册表结构算法**：
   - RuntimeEndpointRegistry是整个场景的端点集合，包含：
     * format: 注册表格式标识（版本兼容性检查）
     * version: 语义化版本号
     * scenario_id: 场景唯一标识
     * backend: 后端类型（:vm, :docker等）
     * network: 虚拟网络名称
     * endpoints: 端点列表
   - RuntimeEndpoint是单个节点的运行时表示，包含：
     * 身份信息：endpoint_kind, endpoint_id, node_id, node_kind, role
     * 网络信息：configured_ip, runtime_ip, runtime_hostname
     * 部署信息：runtime_name, backend, primary_network, primary_interface
     * 服务信息：services列表
   - RuntimeEndpointService描述单个服务：
     * id, kind, port, url, command, enabled

2. **Lima VM IP解析算法**：
   - lima_runtime_ip_resolver()通过limactl在VM内部解析IP
   - 执行流程：
     1. 构造shell脚本：getent hosts <hostname> | awk '{print $1; exit}'
     2. 通过limactl shell进入指定VM执行脚本
     3. 使用env -i清理环境变量，避免宿主机污染
     4. 使用first_ipv4_address()从输出中提取IPv4地址
   - IPv4提取算法（正则表达式）：
     * 模式：\b(?:\d{1,3}\.){3}\d{1,3}\b
     * 匹配标准点分十进制格式（如192.168.1.1）
     * 注意：仅做格式匹配，不验证八位组范围

3. **注册表刷新算法**：
   - refresh_runtime_endpoint_registry()刷新所有端点的IP
   - 算法流程：
     1. 遍历注册表中的所有端点
     2. 对每个端点调用解析器（默认lima_runtime_ip_resolver）
     3. 捕获异常，确保单点失败不影响整体
     4. 根据策略决定失败时的处理：
        - keep_existing_on_failure=true：保留旧IP
        - keep_existing_on_failure=false：清空为""
     5. 构造新的RuntimeEndpoint（不可变结构体需重新构造）
     6. 记录刷新结果（RuntimeEndpointRefreshResult）
   - 返回值：(refreshed_registry, results)
     * 原注册表不变（纯函数设计）
     * results包含每个端点的刷新状态

4. **序列化/反序列化算法**：
   - 写入：JSON.print(io, dict, 2) 以2空格缩进美化
   - 读取：JSON.parsefile(path) 解析为嵌套字典
   - Symbol转换：Symbol ↔ String（JSON不支持Symbol）
   - 嵌套结构：端点包含服务列表，递归序列化

5. **不可变结构体更新算法**：
   - RuntimeEndpoint是不可变结构体，无法原地修改
   - runtime_endpoint_with_ip()通过复制所有字段创建新实例
   - 唯一变化的是runtime_ip字段
   - 服务列表直接复用引用（服务本身不因IP变化而改变）

核心类型层次：
  RuntimeEndpointService  →  单个服务条目（端口、URL、启用状态）
  RuntimeEndpoint         →  单个节点端点（身份、网络、服务列表）
  RuntimeEndpointRegistry →  整个场景的端点集合（序列化为 JSON）
  RuntimeEndpointRefreshResult → IP 刷新操作的结果记录

依赖：
- 上游类型：TestbedSpec, TestbedNode, TestbedService, TestbedMaterializationPlan,
  TestbedVMNodeMaterialization, OrbitalLinkEndpoint
- 工具函数：require_nonempty, require_allowed, shell_single_quote
- 常量：TESTBED_SERVICE_KINDS, TESTBED_ENDPOINT_KINDS, TESTBED_NODE_KINDS, TESTBED_BACKENDS
- 外部库：JSON（序列化/反序列化）
=#

"""
    RuntimeEndpointService

运行时节点的单个服务条目，描述节点对外暴露的服务端口、URL 与启用状态。

# 字段
- `id::String`：服务标识。
- `kind::Symbol`：服务类型，受 `TESTBED_SERVICE_KINDS` 约束。
- `port::Int`：服务端口，必须在 `[1, 65535]` 范围内。
- `url::String`：服务访问 URL；仅对 HTTP 类服务有意义。
- `command::String`：服务启动命令（对自定义服务）。
- `enabled::Bool`：是否启用。
"""
struct RuntimeEndpointService
    # --- 字段说明 ---
    # 服务标识字符串，全局唯一，用于区分同一节点上的不同服务
    id::String
    # 服务类型符号，必须是 TESTBED_SERVICE_KINDS 中定义的合法值（如 :http, :mission_payload 等）
    kind::Symbol
    # 服务监听端口号，必须在 TCP/UDP 有效范围 [1, 65535] 内
    port::Int
    # 服务访问 URL，仅对 HTTP 类服务有意义；非 HTTP 服务为空字符串
    url::String
    # 自定义服务的启动命令字符串，用于需要显式启动脚本的服务类型
    command::String
    # 服务启用标志：true 表示该服务在仿真中处于激活状态，false 表示已禁用
    enabled::Bool

    # --- 构造函数 ---
    # 使用关键字参数构造，确保每个字段都有明确的命名来源
    function RuntimeEndpointService(;
        id::AbstractString,      # 必填：服务标识
        kind::Symbol,            # 必填：服务类型，受限于 TESTBED_SERVICE_KINDS
        port::Int,               # 必填：端口号
        url::AbstractString = "",     # 可选：默认空 URL
        command::AbstractString = "", # 可选：默认空命令
        enabled::Bool,           # 必填：启用状态
    )
        # 端口合法性校验：拒绝 0、负数及超出 16 位无符号整数范围的值
        1 <= port <= 65535 || throw(ArgumentError("runtime service port must be in [1, 65535]"))
        # 构造不可变对象，所有字符串字段经 strip 处理以消除首尾空白
        return new(
            require_nonempty(id, "runtime service id"),
            require_allowed(kind, TESTBED_SERVICE_KINDS, "runtime service kind"),
            port,
            String(strip(url)),
            String(command),
            enabled,
        )
    end
end

"""
    RuntimeEndpoint

运行时端点记录，对应测试床中的一个节点（卫星或地面站）及其在 Lima/容器中的运行身份。

# 字段
- `endpoint_kind::Symbol`：端点类型（`:ground` 或 `:satellite`）。
- `endpoint_id::Int`：OEF endpoint 编号。
- `node_id::String`：TestbedSpec 中的节点 id。
- `node_kind::Symbol`：节点类型。
- `role::Symbol`：节点角色。
- `configured_ip::String`：Spec 中配置的静态 IP。
- `runtime_name::String`：运行时实例名（Lima 实例名或容器名）。
- `runtime_hostname::String`：运行时网络中的主机名。
- `runtime_ip::String`：运行时解析到的实际 IP（初始可能为空，刷新后填充）。
- `backend::Symbol`：后端类型。
- `primary_network::String`、primary_interface::String`：主网络与接口。
- `services::Vector{RuntimeEndpointService}`：节点上的服务列表。
"""
struct RuntimeEndpoint
    # --- 字段说明 ---
    # 端点类型符号：:ground（地面站）或 :satellite（卫星），受 TESTBED_ENDPOINT_KINDS 约束
    endpoint_kind::Symbol
    # OEF（Orbital Event Format）中的端点编号，必须为正整数，用于链路事件寻址
    endpoint_id::Int
    # TestbedSpec 中定义的节点标识字符串，与物化阶段的 node_id 保持一致
    node_id::String
    # 节点类型符号，如 :satellite、:ground_station 等，受 TESTBED_NODE_KINDS 约束
    node_kind::Symbol
    # 节点角色符号，描述节点在场景中的功能角色（如 :relay、:observer 等）
    role::Symbol
    # Spec 中配置的静态 IP 地址，用于网络规划阶段的路由计算
    configured_ip::String
    # 运行时实例名称：Lima 场景中的 VM 实例名或容器名，用于 limactl/docker 命令定位
    runtime_name::String
    # 运行时网络中的主机名，用于 DNS 解析或服务发现
    runtime_hostname::String
    # 运行时实际解析到的动态 IP 地址；初始为空字符串，经 refresh 操作后填充
    runtime_ip::String
    # 后端类型符号，如 :lima、:docker 等，受 TESTBED_BACKENDS 约束
    backend::Symbol
    # 主网络名称，标识节点所属的网络分区或子网
    primary_network::String
    # 主网络接口名称，如 eth0、en0 等，用于流量捕获和路由配置
    primary_interface::String
    # 该节点上暴露的所有服务列表，每个元素为 RuntimeEndpointService
    services::Vector{RuntimeEndpointService}

    # --- 构造函数 ---
    function RuntimeEndpoint(;
        endpoint_kind::Symbol,       # 必填：端点类型
        endpoint_id::Int,            # 必填：OEF 端点编号
        node_id::AbstractString,     # 必填：节点标识
        node_kind::Symbol,           # 必填：节点类型
        role::Symbol,                # 必填：节点角色
        configured_ip::AbstractString,   # 必填：配置静态 IP
        runtime_name::AbstractString,    # 必填：运行时实例名
        runtime_hostname::AbstractString,# 必填：运行时主机名
        runtime_ip::AbstractString = "", # 可选：动态 IP，初始为空
        backend::Symbol,             # 必填：后端类型
        primary_network::AbstractString, # 必填：主网络名
        primary_interface::AbstractString, # 必填：主接口名
        services::Vector{RuntimeEndpointService} = RuntimeEndpointService[], # 可选：默认空服务列表
    )
        # endpoint_id 必须为正整数，0 和负数无意义
        endpoint_id > 0 || throw(ArgumentError("runtime endpoint_id must be positive"))
        # 构造不可变对象，所有 Symbol 字段经合法性校验，字符串字段经非空校验和空白修剪
        return new(
            require_allowed(endpoint_kind, TESTBED_ENDPOINT_KINDS, "runtime endpoint_kind"),
            endpoint_id,
            require_nonempty(node_id, "runtime node_id"),
            require_allowed(node_kind, TESTBED_NODE_KINDS, "runtime node_kind"),
            role,
            require_nonempty(configured_ip, "runtime configured_ip"),
            require_nonempty(runtime_name, "runtime_name"),
            require_nonempty(runtime_hostname, "runtime_hostname"),
            String(strip(runtime_ip)),
            require_allowed(backend, TESTBED_BACKENDS, "runtime backend"),
            require_nonempty(primary_network, "runtime primary_network"),
            require_nonempty(primary_interface, "runtime primary_interface"),
            services,
        )
    end
end

"""
    RuntimeEndpointRegistry

运行时端点注册表，记录一次仿真场景中所有节点的运行时访问信息，
序列化为 `runtime_endpoints.json` 供外部工具与通道管理器消费。

# 字段
- `format::String`：注册表格式标识。
- `version::String`：版本号。
- `scenario_id::String`：场景 id。
- `backend::Symbol`：后端类型。
- `network::String`：网络名称。
- `endpoints::Vector{RuntimeEndpoint}`：端点记录列表，至少包含一个端点。
"""
struct RuntimeEndpointRegistry
    # --- 字段说明 ---
    # 注册表格式标识字符串，用于版本兼容性检查和文件格式识别
    format::String
    # 注册表版本号字符串，遵循语义化版本规范（如 "0.1"）
    version::String
    # 场景唯一标识字符串，关联到具体的仿真场景定义
    scenario_id::String
    # 后端类型符号，标识该注册表使用的虚拟化后端（如 :lima、:docker）
    backend::Symbol
    # 网络名称字符串，标识该场景中所有节点共享的虚拟网络
    network::String
    # 端点记录向量，包含场景中所有节点的运行时访问信息；至少包含一个端点
    endpoints::Vector{RuntimeEndpoint}

    # --- 构造函数 ---
    function RuntimeEndpointRegistry(;
        format::AbstractString = "SatelliteSimJulia-RuntimeEndpointRegistry", # 可选：默认格式标识
        version::AbstractString = "0.1",     # 可选：默认版本号
        scenario_id::AbstractString,         # 必填：场景 ID
        backend::Symbol,                     # 必填：后端类型
        network::AbstractString,             # 必填：网络名称
        endpoints::Vector{RuntimeEndpoint},  # 必填：端点列表
    )
        # 注册表必须包含至少一个端点，空注册表无实际意义
        !isempty(endpoints) || throw(ArgumentError("runtime endpoint registry must contain at least one endpoint"))
        return new(
            require_nonempty(format, "runtime registry format"),
            require_nonempty(version, "runtime registry version"),
            require_nonempty(scenario_id, "runtime registry scenario_id"),
            require_allowed(backend, TESTBED_BACKENDS, "runtime registry backend"),
            require_nonempty(network, "runtime registry network"),
            endpoints,
        )
    end
end

"""
    RuntimeEndpointRefreshResult

对单个运行时端点执行 IP 刷新后的结果记录。

# 字段
- `endpoint::String`：端点标签。
- `runtime_name::String`：运行时实例名。
- `runtime_hostname::String`：运行时主机名。
- `previous_runtime_ip::String`：刷新前的 IP。
- `runtime_ip::String`：刷新后的 IP（解析失败时为空）。
- `resolved::Bool`：是否成功解析到新 IP。
- `error_message::String`：解析失败时的错误信息。
"""
struct RuntimeEndpointRefreshResult
    # --- 字段说明 ---
    # 端点标签字符串，格式为 "kind:id"（如 "satellite:1"），标识本次刷新操作的目标
    endpoint::String
    # 运行时实例名称，与 RuntimeEndpoint 中的 runtime_name 一致，用于日志关联
    runtime_name::String
    # 运行时主机名，刷新时尝试解析的主机名
    runtime_hostname::String
    # 刷新操作前的 IP 地址，用于对比判断 IP 是否发生变化
    previous_runtime_ip::String
    # 刷新操作后的 IP 地址；解析失败时为空字符串
    runtime_ip::String
    # 解析成功标志：true 表示成功获取到新的有效 IP，false 表示解析失败
    resolved::Bool
    # 错误信息字符串；解析成功时为空，失败时包含异常描述
    error_message::String

    # --- 构造函数 ---
    function RuntimeEndpointRefreshResult(;
        endpoint::AbstractString,            # 必填：端点标签
        runtime_name::AbstractString,        # 必填：运行时实例名
        runtime_hostname::AbstractString,    # 必填：运行时主机名
        previous_runtime_ip::AbstractString, # 必填：刷新前 IP
        runtime_ip::AbstractString,          # 必填：刷新后 IP
        resolved::Bool,                      # 必填：解析状态
        error_message::AbstractString = "",  # 可选：默认无错误信息
    )
        # 构造不可变对象，IP 字段经 strip 处理以消除可能的换行或空白
        return new(
            require_nonempty(endpoint, "refresh result endpoint"),
            require_nonempty(runtime_name, "refresh result runtime_name"),
            require_nonempty(runtime_hostname, "refresh result runtime_hostname"),
            String(strip(previous_runtime_ip)),
            String(strip(runtime_ip)),
            resolved,
            String(error_message),
        )
    end
end

# [算法说明]
# 端点标签生成算法：将端点类型和ID编码为字符串。
# 格式："kind:id"（如"satellite:3"）
# 用途：作为端点的唯一短标识，用于日志、结果记录和快速查找。
"""
    runtime_endpoint_label(kind::Symbol, id::Int) -> String

生成端点标签字符串，格式为 `"kind:id"`。

该标签作为端点的唯一短标识，用于日志输出、结果记录和快速查找。
例如：`runtime_endpoint_label(:satellite, 3)` 返回 `"satellite:3"`。
"""
function runtime_endpoint_label(kind::Symbol, id::Int)::String
    # 使用 Julia 字符串插值拼接 kind 和 id，格式固定为 "kind:id"
    return "$(kind):$(id)"
end

"""
    runtime_endpoint_label(endpoint::RuntimeEndpoint) -> String

从 `RuntimeEndpoint` 提取端点标签。

通过调用 `kind` 和 `id` 的两参数版本实现，确保标签格式一致性。
"""
runtime_endpoint_label(endpoint::RuntimeEndpoint)::String =
    # 委托给两参数版本，从端点对象中提取 endpoint_kind 和 endpoint_id
    runtime_endpoint_label(endpoint.endpoint_kind, endpoint.endpoint_id)

# [算法说明]
# 服务URL生成算法：根据服务类型和端点主机名生成HTTP URL。
# 规则：
# - :http或:mission_payload服务：生成"http://<hostname>:<port>"格式的URL
# - 其他服务类型：返回空字符串（不需要HTTP URL）
# 注意：此时runtime_ip可能尚未解析，因此使用主机名而非IP。
"""
    runtime_service_url(service::TestbedService, endpoint::RuntimeEndpoint) -> String

根据服务类型与端点主机名生成服务 URL。
仅 `:http` 与 `:mission_payload` 服务返回 URL，其余返回空字符串。

# 参数
- `service::TestbedService`：测试床中定义的服务规格。
- `endpoint::RuntimeEndpoint`：已分配运行时主机名的端点记录。

# 返回值
- 字符串形式的 HTTP URL（如 `"http://lima-sat-1:8080"`），或空字符串。
"""
function runtime_service_url(service::TestbedService, endpoint::RuntimeEndpoint)::String
    # 短路求值：仅当服务类型为 :http 或 :mission_payload 时才生成 URL
    # 其他类型（如 :tcp、:udp 等）返回空字符串，因为它们不需要 HTTP URL
    service.kind == :http || service.kind == :mission_payload ||
        return ""
    # 使用端点的运行时主机名和服务端口拼接 HTTP URL
    # 注意：此时 runtime_ip 可能尚未解析，因此使用主机名而非 IP
    return "http://$(endpoint.runtime_hostname):$(service.port)"
end

# [算法说明]
# 节点服务过滤算法：从全局服务列表中筛选出绑定到指定节点的服务。
# 实现：使用数组推导式过滤spec.services，只保留node字段匹配的服务。
# 时间复杂度：O(n)，n为spec.services的长度。
"""
    services_for_node(spec::TestbedSpec, node_id::AbstractString) -> Vector{TestbedService}

返回 TestbedSpec 中绑定到指定节点的所有服务。

# 参数
- `spec::TestbedSpec`：测试床规格对象，包含全局服务列表。
- `node_id::AbstractString`：目标节点的标识字符串。

# 返回值
- `TestbedService` 向量，包含所有 `service.node == node_id` 的服务。
"""
function services_for_node(spec::TestbedSpec, node_id::AbstractString)::Vector{TestbedService}
    # 使用数组推导式过滤 spec.services，只保留 node 字段匹配的目标服务
    # 时间复杂度 O(n)，n 为 spec.services 的长度
    return [service for service in spec.services if service.node == node_id]
end

# [算法说明]
# 运行时服务构建算法：将TestbedService转换为RuntimeEndpointService。
# 核心逻辑：
# 1. 调用runtime_service_url()生成基础URL
# 2. 特殊处理：端口8000的HTTP服务追加"/mission_payload.json"路径
#    - 该服务提供卫星任务载荷的JSON描述文件
#    - 外部工具通过此URL获取载荷配置
# 3. 映射字段：id, kind, port, enabled, command直接透传
# 4. URL字段使用运行时解析后的值
"""
    build_runtime_endpoint_service(
        service::TestbedService,
        endpoint::RuntimeEndpoint,
    ) -> RuntimeEndpointService

将 TestbedSpec 中的服务定义与运行时端点结合，生成 `RuntimeEndpointService`。
对端口 8000 的 HTTP 服务自动追加 `/mission_payload.json` 路径。

# 参数
- `service::TestbedService`：测试床规格中的服务定义（端口、类型、命令等）。
- `endpoint::RuntimeEndpoint`：已分配运行时主机名的端点记录。

# 返回值
- 包含完整 URL 的运行时服务条目。

# 特殊约定
- 端口 8000 的 HTTP 服务被识别为 mission payload 文件服务，URL 自动追加路径。
"""
function build_runtime_endpoint_service(
    service::TestbedService,
    endpoint::RuntimeEndpoint,
)::RuntimeEndpointService
    # [执行流程]
    # 步骤1: 根据服务类型和端点主机名生成基础 URL
    # - 仅 :http 和 :mission_payload 类型生成 URL
    # - 其他类型返回空字符串
    url = runtime_service_url(service, endpoint)
    # 步骤2: 特殊处理：端口 8000 的 HTTP 服务追加 /mission_payload.json 路径
    # - 该服务提供卫星任务载荷的 JSON 描述文件
    # - 外部工具通过此 URL 获取载荷配置
    if service.kind == :http && service.port == 8000
        url = "$(url)/mission_payload.json"
    end
    # 步骤3: 将 TestbedService 字段映射到 RuntimeEndpointService
    # - id, kind, port, enabled, command 直接透传
    # - url 使用运行时解析后的值
    return RuntimeEndpointService(
        id = service.id,
        kind = service.kind,
        port = service.port,
        url = url,
        command = service.command,
        enabled = service.enabled,
    )
end

# [算法说明]
# 运行时端点构建算法：将规格节点和物化节点合并为运行时端点。
# 由于RuntimeEndpoint是不可变结构体，且services字段在构造时即需确定，
# 而services的构建又依赖于已构造的endpoint（用于获取主机名），
# 因此采用两阶段策略：
# 1. 构造不含服务的端点记录
# 2. 构建服务列表（需要endpoint的主机名）
# 3. 重新构造完整端点（附带服务列表）
# 字段来源：
#   - 物化节点：endpoint_kind, endpoint_id, node_id, configured_ip, runtime_name, runtime_hostname
#   - 规格节点：node_kind, role, primary_network, primary_interface
#   - 物化计划：backend
#   - runtime_ip初始为空，后续通过刷新操作填充
"""
    runtime_endpoint_from_node(
        spec::TestbedSpec,
        spec_node::TestbedNode,
        materialized_node::TestbedVMNodeMaterialization,
        materialization::TestbedMaterializationPlan,
    ) -> RuntimeEndpoint

将物化后的 VM 节点与对应 Spec 节点合并为 `RuntimeEndpoint`。
先构造不带服务的端点记录，再追加该节点上的所有服务。

# 参数
- `spec::TestbedSpec`：测试床规格，包含所有节点和服务的定义。
- `spec_node::TestbedNode`：规格中定义的节点信息（类型、角色、网络配置）。
- `materialized_node::TestbedVMNodeMaterialization`：物化后的 VM 节点信息（运行时名称、主机名、IP）。
- `materialization::TestbedMaterializationPlan`：完整的物化计划，提供场景级信息（backend、network）。

# 返回值
- 包含完整服务列表的运行时端点记录。

# 实现说明
由于 RuntimeEndpoint 是不可变结构体，且 services 字段在构造时即需确定，
而 services 的构建又依赖于已构造的 endpoint（用于获取主机名），
因此采用"先构造无服务端点 → 构建服务列表 → 重新构造完整端点"的两阶段策略。
"""
function runtime_endpoint_from_node(
    spec::TestbedSpec,
    spec_node::TestbedNode,
    materialized_node::TestbedVMNodeMaterialization,
    materialization::TestbedMaterializationPlan,
)::RuntimeEndpoint
    # [执行流程]
    # 步骤1: 构造不含服务的端点记录（RuntimeEndpoint 是不可变结构体）
    # 字段来源：
    #   - 物化节点：endpoint_kind, endpoint_id, node_id, configured_ip, runtime_name, runtime_hostname
    #   - 规格节点：node_kind, role, primary_network, primary_interface
    #   - 物化计划：backend
    #   - runtime_ip 初始为空字符串，后续通过 refresh 操作填充
    endpoint = RuntimeEndpoint(
        endpoint_kind = materialized_node.endpoint_kind,
        endpoint_id = materialized_node.endpoint_id,
        node_id = materialized_node.node_id,
        node_kind = spec_node.kind,
        role = spec_node.role,
        configured_ip = materialized_node.configured_ip,
        runtime_name = materialized_node.runtime_name,
        runtime_hostname = materialized_node.lima_hostname,
        backend = materialization.backend,
        primary_network = spec_node.primary_network,
        primary_interface = spec_node.primary_interface,
    )
    # 步骤2: 为当前节点构建所有运行时服务条目
    # - services_for_node() 从 spec 中筛选绑定到该节点的服务
    # - build_runtime_endpoint_service() 生成带 URL 的运行时服务
    services = [
        build_runtime_endpoint_service(service, endpoint)
        for service in services_for_node(spec, spec_node.id)
    ]
    # 步骤3: 重新构造端点，附带完整的服务列表
    # - 不可变结构体无法原地修改，使用相同字段值重新构造新实例
    # - 服务列表直接复用引用（服务本身不因 IP 变化而改变）
    return RuntimeEndpoint(
        endpoint_kind = endpoint.endpoint_kind,
        endpoint_id = endpoint.endpoint_id,
        node_id = endpoint.node_id,
        node_kind = endpoint.node_kind,
        role = endpoint.role,
        configured_ip = endpoint.configured_ip,
        runtime_name = endpoint.runtime_name,
        runtime_hostname = endpoint.runtime_hostname,
        runtime_ip = endpoint.runtime_ip,
        backend = endpoint.backend,
        primary_network = endpoint.primary_network,
        primary_interface = endpoint.primary_interface,
        services = services,
    )
end

# [算法说明]
# 运行时端点注册表构建算法：
# 1. 遍历物化计划中的所有节点
# 2. 对每个节点，在TestbedSpec中查找对应的规格节点
# 3. 调用runtime_endpoint_from_node()构建完整的运行时端点记录
#    - 合并规格节点和物化节点的信息
#    - 生成该节点的所有运行时服务条目
# 4. 使用物化计划中的场景级信息构造注册表
# 5. 返回RuntimeEndpointRegistry
# 注册表包含所有节点的运行时访问信息，供通道管理器使用。
"""
    build_runtime_endpoint_registry(
        spec::TestbedSpec,
        materialization::TestbedMaterializationPlan,
    ) -> RuntimeEndpointRegistry

为物化计划中的所有节点构建运行时端点注册表。

遍历物化计划中的每个节点，在 TestbedSpec 中查找对应的规格节点，
然后调用 `runtime_endpoint_from_node` 构建完整的运行时端点记录。

# 参数
- `spec::TestbedSpec`：测试床规格，包含节点定义和服务绑定关系。
- `materialization::TestbedMaterializationPlan`：物化计划，包含所有已分配资源的 VM 节点。

# 返回值
- 包含所有节点运行时信息的 `RuntimeEndpointRegistry`。

# 异常
- 若 `find_spec_node` 找不到对应节点，将抛出异常。
"""
function build_runtime_endpoint_registry(
    spec::TestbedSpec,
    materialization::TestbedMaterializationPlan,
)::RuntimeEndpointRegistry
    # 预分配端点向量，容量与物化节点数量一致
    endpoints = RuntimeEndpoint[]
    # [执行流程]
    # 步骤1: 遍历物化计划中的所有节点，逐个构建运行时端点
    for materialized_node in materialization.nodes
        # 步骤2: 在 spec 中查找与物化节点 node_id 对应的规格节点
        # 物化阶段保证 node_id 的一致性，找不到说明 spec 与物化计划不匹配
        spec_node = find_spec_node(spec, materialized_node.node_id)
        # 步骤3: 合并规格节点和物化节点的信息，构建完整的运行时端点
        # - 包含：身份信息、网络信息、部署信息、服务列表
        push!(
            endpoints,
            runtime_endpoint_from_node(spec, spec_node, materialized_node, materialization),
        )
    end
    # 步骤4: 使用物化计划中的场景级信息（scenario_id, backend, network）构造注册表
    return RuntimeEndpointRegistry(
        scenario_id = materialization.scenario_id,
        backend = materialization.backend,
        network = materialization.network,
        endpoints = endpoints,
    )
end

# [算法说明]
# 运行时服务序列化算法：
# 1. 将服务字段转换为字典
# 2. Symbol字段转换为String
# 3. 显式指定Dict{String,Any}类型，确保JSON库能正确序列化
# 4. 返回完整的字典结构
"""
    runtime_endpoint_service_dict(service::RuntimeEndpointService) -> Dict{String,Any}

把运行时服务条目序列化为字典。

字典键为字符串形式，值为 Julia 原生类型（String, Int, Bool），
便于 JSON 序列化。Symbol 字段被转换为字符串。

# 参数
- `service::RuntimeEndpointService`：要序列化的运行时服务条目。

# 返回值
- `Dict{String,Any}`，包含服务的所有字段。
"""
function runtime_endpoint_service_dict(service::RuntimeEndpointService)::Dict{String,Any}
    # 显式指定 Dict{String,Any} 类型，确保 JSON 库能正确序列化所有值类型
    return Dict{String,Any}(
        "id" => service.id,               # 服务标识
        "kind" => String(service.kind),   # Symbol 转 String，便于 JSON 存储
        "port" => service.port,           # 端口号（Int）
        "url" => service.url,             # 服务 URL
        "command" => service.command,     # 启动命令
        "enabled" => service.enabled,     # 启用状态（Bool）
    )
end

# [算法说明]
# 运行时端点序列化算法：
# 1. 将端点字段转换为字典
# 2. Symbol字段转换为String
# 3. 使用runtime_endpoint_label()生成"kind:id"标签
# 4. 递归序列化服务列表
# 5. 返回完整的字典结构
"""
    runtime_endpoint_dict(endpoint::RuntimeEndpoint) -> Dict{String,Any}

把运行时端点序列化为字典，包含其服务列表。

端点的 Symbol 字段（endpoint_kind, node_kind, role, backend）均被转换为字符串，
services 字段通过 `runtime_endpoint_service_dict` 逐个转换。

# 参数
- `endpoint::RuntimeEndpoint`：要序列化的运行时端点。

# 返回值
- `Dict{String,Any}`，包含端点的所有字段，其中 "services" 为字典数组。
"""
function runtime_endpoint_dict(endpoint::RuntimeEndpoint)::Dict{String,Any}
    return Dict{String,Any}(
        "endpoint" => runtime_endpoint_label(endpoint),     # 生成 "kind:id" 标签
        "endpoint_kind" => String(endpoint.endpoint_kind),  # Symbol 转 String
        "endpoint_id" => endpoint.endpoint_id,              # OEF 端点编号
        "node_id" => endpoint.node_id,                      # 节点标识
        "node_kind" => String(endpoint.node_kind),          # 节点类型
        "role" => String(endpoint.role),                    # 节点角色
        "configured_ip" => endpoint.configured_ip,          # 配置静态 IP
        "runtime_name" => endpoint.runtime_name,            # 运行时实例名
        "runtime_hostname" => endpoint.runtime_hostname,    # 运行时主机名
        "runtime_ip" => endpoint.runtime_ip,                # 运行时动态 IP（可能为空）
        "backend" => String(endpoint.backend),              # 后端类型
        "primary_network" => endpoint.primary_network,      # 主网络名
        "primary_interface" => endpoint.primary_interface,  # 主接口名
        # 递归序列化每个服务条目为字典，形成嵌套结构
        "services" => [
            runtime_endpoint_service_dict(service)
            for service in endpoint.services
        ],
    )
end

# [算法说明]
# 运行时端点注册表序列化算法：
# 1. 将注册表元数据转换为字典
# 2. Symbol字段转换为String（JSON不支持Symbol）
# 3. 逐个序列化端点，调用runtime_endpoint_dict()
# 4. 返回完整的字典结构
# 这是JSON序列化的顶层入口。
"""
    runtime_endpoint_registry_dict(registry::RuntimeEndpointRegistry) -> Dict{String,Any}

把整个运行时端点注册表序列化为字典。

这是 JSON 序列化的顶层入口，生成的字典结构对应 `runtime_endpoints.json` 的文件格式。

# 参数
- `registry::RuntimeEndpointRegistry`：要序列化的运行时端点注册表。

# 返回值
- `Dict{String,Any}`，包含注册表元数据和所有端点的嵌套字典。
"""
function runtime_endpoint_registry_dict(registry::RuntimeEndpointRegistry)::Dict{String,Any}
    return Dict{String,Any}(
        "format" => registry.format,       # 格式标识，用于版本兼容性检查
        "version" => registry.version,     # 版本号
        "scenario_id" => registry.scenario_id,  # 场景唯一标识
        "backend" => String(registry.backend),  # 后端类型（Symbol 转 String）
        "network" => registry.network,     # 网络名称
        # 逐个序列化端点，形成端点数组
        "endpoints" => [runtime_endpoint_dict(endpoint) for endpoint in registry.endpoints],
    )
end

# [算法说明]
# 运行时端点注册表序列化算法：
# 1. 确保目标目录存在（mkpath）
# 2. 调用runtime_endpoint_registry_dict()将注册表转换为字典
# 3. 使用JSON.print()以2空格缩进输出美化格式
# 4. 在文件末尾追加换行符（POSIX规范）
# 5. 使用do语法确保文件句柄自动关闭
"""
    write_runtime_endpoint_registry(
        path::AbstractString,
        registry::RuntimeEndpointRegistry,
    ) -> Nothing

将运行时端点注册表以 JSON 格式写入指定路径，缩进为 2。

会自动创建目标目录（若不存在），并在 JSON 末尾追加换行符。

# 参数
- `path::AbstractString`：输出文件路径，通常以 `.json` 结尾。
- `registry::RuntimeEndpointRegistry`：要写入的注册表对象。

# 返回值
- `nothing`
"""
function write_runtime_endpoint_registry(
    path::AbstractString,
    registry::RuntimeEndpointRegistry,
)::Nothing
    # 确保目标目录存在，若不存在则递归创建
    mkpath(dirname(path))
    # 打开文件进行写入，使用 do 语法确保文件句柄自动关闭
    open(path, "w") do io
        # 使用 JSON.print 以 2 空格缩进输出美化格式，便于人工阅读和 diff
        JSON.print(io, runtime_endpoint_registry_dict(registry), 2)
        # 在文件末尾追加换行符，符合 POSIX 文本文件规范
        println(io)
    end
    return nothing
end

# [算法说明]
# 运行时服务反序列化算法：
# 1. 从JSON字典中提取字段并转换为正确的Julia类型
# 2. 使用String()确保类型安全（处理JSON的SubString类型）
# 3. 可选字段使用get()提供默认值
# 4. 返回重建的RuntimeEndpointService对象
"""
    read_runtime_endpoint_service_dict(raw) -> RuntimeEndpointService

从 JSON 字典反序列化单个运行时服务条目。

这是 `read_runtime_endpoint_dict` 的辅助函数，处理嵌套在端点中的服务子结构。

# 参数
- `raw`：JSON 解析后的字典，预期包含 "id", "kind", "port", "enabled" 等键。

# 返回值
- 重建的 `RuntimeEndpointService` 对象。

# 默认值
- "url" 和 "command" 字段若缺失，默认使用空字符串。
"""
function read_runtime_endpoint_service_dict(raw)::RuntimeEndpointService
    # 从字典中提取字段并转换为正确的 Julia 类型
    # String() 转换确保类型安全，即使 JSON 解析结果为 SubString 也能正确处理
    return RuntimeEndpointService(
        id = String(raw["id"]),                    # 服务标识（必填）
        kind = Symbol(String(raw["kind"])),        # 类型字符串先转 String 再转 Symbol
        port = Int(raw["port"]),                   # 端口号转为 Int
        url = String(get(raw, "url", "")),         # URL 可选，缺失时默认空字符串
        command = String(get(raw, "command", "")), # 命令可选，缺失时默认空字符串
        enabled = Bool(raw["enabled"]),            # 启用状态（必填）
    )
end

# [算法说明]
# 运行时端点反序列化算法：
# 1. 从JSON字典中提取所有字段
# 2. Symbol字段需要从String转换：Symbol(String(raw["field"]))
# 3. 可选字段使用get()提供默认值
# 4. 递归反序列化嵌套的服务列表
# 5. 返回重建的RuntimeEndpoint对象
"""
    read_runtime_endpoint_dict(raw) -> RuntimeEndpoint

从 JSON 字典反序列化单个运行时端点。

处理端点字典中的所有字段，包括嵌套的服务列表。

# 参数
- `raw`：JSON 解析后的字典，预期包含端点的完整字段集。

# 返回值
- 重建的 `RuntimeEndpoint` 对象，包含完整的服务向量。

# 默认值
- "runtime_ip" 若缺失，默认使用空字符串（表示尚未刷新）。
- "services" 若缺失，默认使用空数组。
"""
function read_runtime_endpoint_dict(raw)::RuntimeEndpoint
    return RuntimeEndpoint(
        endpoint_kind = Symbol(String(raw["endpoint_kind"])),  # 端点类型
        endpoint_id = Int(raw["endpoint_id"]),                  # OEF 端点编号
        node_id = String(raw["node_id"]),                       # 节点标识
        node_kind = Symbol(String(raw["node_kind"])),           # 节点类型
        role = Symbol(String(raw["role"])),                     # 节点角色
        configured_ip = String(raw["configured_ip"]),           # 配置静态 IP
        runtime_name = String(raw["runtime_name"]),             # 运行时实例名
        runtime_hostname = String(raw["runtime_hostname"]),     # 运行时主机名
        runtime_ip = String(get(raw, "runtime_ip", "")),        # 动态 IP，可选
        backend = Symbol(String(raw["backend"])),               # 后端类型
        primary_network = String(raw["primary_network"]),       # 主网络名
        primary_interface = String(raw["primary_interface"]),   # 主接口名
        # 递归反序列化服务列表：将每个服务字典转换为 RuntimeEndpointService
        services = [
            read_runtime_endpoint_service_dict(service)
            for service in Vector(get(raw, "services", []))
        ],
    )
end

# [算法说明]
# 运行时端点注册表反序列化算法：
# 1. 使用JSON.parsefile()读取并解析JSON文件为嵌套字典
# 2. 从顶层字典提取注册表元数据（format, version, scenario_id, backend, network）
# 3. 逐个反序列化端点字典，调用read_runtime_endpoint_dict()
# 4. 返回重建的RuntimeEndpointRegistry对象
# 注意：JSON中的Symbol字段需要从String转换回来。
"""
    read_runtime_endpoint_registry(path::AbstractString) -> RuntimeEndpointRegistry

从 JSON 文件读取运行时端点注册表。

这是反序列化的顶层入口，读取由 `write_runtime_endpoint_registry` 生成的 JSON 文件。

# 参数
- `path::AbstractString`：JSON 文件路径。

# 返回值
- 重建的 `RuntimeEndpointRegistry` 对象。

# 异常
- 若文件不存在或 JSON 格式错误，将抛出异常。
- 若字典中缺少必填字段（如 "format", "scenario_id" 等），将抛出 KeyError。
"""
function read_runtime_endpoint_registry(path::AbstractString)::RuntimeEndpointRegistry
    # 使用 JSON.parsefile 读取并解析整个 JSON 文件为嵌套字典结构
    raw = JSON.parsefile(path)
    # 从顶层字典中提取注册表元数据和端点数组
    return RuntimeEndpointRegistry(
        format = String(raw["format"]),          # 格式标识（必填）
        version = String(raw["version"]),        # 版本号（必填）
        scenario_id = String(raw["scenario_id"]),# 场景 ID（必填）
        backend = Symbol(String(raw["backend"])),# 后端类型（必填）
        network = String(raw["network"]),        # 网络名称（必填）
        # 逐个反序列化端点字典，形成端点向量
        endpoints = [
            read_runtime_endpoint_dict(endpoint)
            for endpoint in Vector(raw["endpoints"])
        ],
    )
end

# [算法说明]
# 运行时端点查找算法：在注册表中按OEF端点查找对应的运行时端点。
# 实现：线性遍历注册表，查找endpoint_kind和endpoint_id都匹配的条目。
# 时间复杂度：O(n)，n为注册表中的端点数量。
# 优化：使用短路求值，先比较endpoint_kind，不匹配则跳过id比较。
"""
    find_runtime_endpoint(
        registry::RuntimeEndpointRegistry,
        endpoint::OrbitalLinkEndpoint,
    ) -> RuntimeEndpoint

在注册表中按 OEF endpoint 的 kind 与 id 查找对应的运行时端点。
未找到时抛出 `ArgumentError`。

# 参数
- `registry::RuntimeEndpointRegistry`：运行时端点注册表。
- `endpoint::OrbitalLinkEndpoint`：OEF 链路端点对象，包含 kind 和 id 字段。

# 返回值
- 匹配的 `RuntimeEndpoint` 对象。

# 异常
- `ArgumentError`：注册表中不存在与给定 OEF endpoint 对应的运行时端点。

# 性能
- 线性扫描，时间复杂度 O(n)，n 为注册表中的端点数量。
  适用于端点数量较少的场景（通常 < 100）。
"""
function find_runtime_endpoint(
    registry::RuntimeEndpointRegistry,
    endpoint::OrbitalLinkEndpoint,
)::RuntimeEndpoint
    # 线性遍历注册表中的所有端点，寻找 kind 和 id 均匹配的条目
    for runtime_endpoint in registry.endpoints
        # 短路求值：先比较 endpoint_kind，不匹配则跳过 id 比较
        runtime_endpoint.endpoint_kind == endpoint.kind &&
            runtime_endpoint.endpoint_id == endpoint.id &&
            return runtime_endpoint
    end
    # 遍历完成仍未找到匹配项，抛出异常并包含端点标识以便调试
    throw(ArgumentError("no runtime endpoint for OEF endpoint $(endpoint.kind):$(endpoint.id)"))
end

# [算法说明]
# 不可变结构体更新算法：通过复制所有字段创建新实例。
# 原因：Julia的struct默认不可变，无法原地修改字段。
# 模式：复制所有字段，仅替换目标字段（runtime_ip）。
# 服务列表直接复用引用，因为服务本身不因IP变化而改变。
"""
    runtime_endpoint_with_ip(
        endpoint::RuntimeEndpoint,
        runtime_ip::AbstractString,
    ) -> RuntimeEndpoint

返回一个复制品，将其 `runtime_ip` 字段替换为指定值，其余字段保持不变。

由于 `RuntimeEndpoint` 是不可变结构体，无法原地修改字段，
因此此函数通过复制所有字段（仅替换 runtime_ip）创建新实例。

# 参数
- `endpoint::RuntimeEndpoint`：源端点记录。
- `runtime_ip::AbstractString`：新的运行时 IP 地址字符串。

# 返回值
- 新的 `RuntimeEndpoint` 对象，runtime_ip 字段为指定值。

# 使用场景
- IP 刷新操作后，用新解析到的 IP 替换旧值，同时保留端点的其他所有信息。
"""
function runtime_endpoint_with_ip(
    endpoint::RuntimeEndpoint,
    runtime_ip::AbstractString,
)::RuntimeEndpoint
    # 不可变结构体的字段更新模式：复制所有字段，仅替换目标字段
    return RuntimeEndpoint(
        endpoint_kind = endpoint.endpoint_kind,
        endpoint_id = endpoint.endpoint_id,
        node_id = endpoint.node_id,
        node_kind = endpoint.node_kind,
        role = endpoint.role,
        configured_ip = endpoint.configured_ip,
        runtime_name = endpoint.runtime_name,
        runtime_hostname = endpoint.runtime_hostname,
        runtime_ip = runtime_ip,        # 唯一被替换的字段
        backend = endpoint.backend,
        primary_network = endpoint.primary_network,
        primary_interface = endpoint.primary_interface,
        services = endpoint.services,    # 服务列表直接复用引用（服务本身不因 IP 变化而改变）
    )
end

# [算法说明]
# IPv4地址提取算法：从文本中提取第一个有效的IPv4地址。
# 正则表达式：\b(?:\d{1,3}\.){3}\d{1,3}\b
#   \b：单词边界，确保匹配完整的数字序列
#   (?:\d{1,3}\.){3}：非捕获组，匹配"数字."重复3次（前三组八位组）
#   \d{1,3}：最后一组八位组（1-3位数字）
#   \b：单词边界
# 注意：仅做格式匹配，不验证八位组范围（如999.999.999.999也会被匹配）
# 用途：解析getent hosts或ifconfig等命令的输出
"""
    first_ipv4_address(value::AbstractString) -> String

从字符串中抽取第一个 IPv4 地址；未匹配到则返回空字符串。

使用正则表达式匹配标准点分十进制 IPv4 格式（如 "192.168.1.1"）。
注意：此函数仅做格式匹配，不验证每个八位组的实际范围（如 "999.999.999.999" 也会被匹配）。

# 参数
- `value::AbstractString`：可能包含 IP 地址的原始字符串（如命令输出）。

# 返回值
- 匹配到的第一个 IPv4 地址字符串，或空字符串。

# 使用场景
- 解析 `getent hosts` 或 `ifconfig` 等命令的输出，提取其中的 IP 地址。
"""
function first_ipv4_address(value::AbstractString)::String
    # 正则表达式解释：
    #   \b          - 单词边界，确保匹配完整的数字序列
    #   (?:\d{1,3}\.){3} - 非捕获组，匹配 "数字." 重复 3 次（前三组八位组）
    #   \d{1,3}     - 最后一组八位组（1-3 位数字）
    #   \b          - 单词边界
    match_result = match(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", value)
    # match 返回 RegexMatch 或 nothing；nothing 表示未匹配到任何 IPv4 地址
    match_result === nothing && return ""
    # 返回匹配到的完整字符串（即第一个 IPv4 地址）
    return match_result.match
end

# [算法说明]
# Lima VM IP解析算法：通过SSH在VM内部解析主机名到IP。
# 核心流程：
# 1. 构造shell脚本：getent hosts <hostname> | awk '{print $1; exit}'
#    - getent hosts查询DNS/hosts记录
#    - awk提取第一列（IP地址）
#    - exit确保只获取第一条记录
# 2. 通过limactl shell进入指定VM执行脚本
#    - env -i清理环境变量，避免宿主机污染
#    - PATH设置为标准系统目录
#    - sh -lc执行脚本，-l加载profile（可能包含网络配置）
# 3. 使用first_ipv4_address()从输出中提取IPv4地址
# 4. 返回提取到的IP地址，失败时返回空字符串
"""
    lima_runtime_ip_resolver(endpoint::RuntimeEndpoint) -> String

通过 `limactl shell` 在 VM 内部解析 `runtime_hostname` 对应的 IPv4 地址。
这是默认的运行时 IP 解析器，依赖 Lima 实例处于运行状态。

# 参数
- `endpoint::RuntimeEndpoint`：要解析 IP 的端点记录，需包含 runtime_name 和 runtime_hostname。

# 返回值
- 解析到的 IPv4 地址字符串；解析失败时返回空字符串。

# 实现细节
1. 在 VM 内部执行 `getent hosts <hostname>` 查询 DNS/hosts 记录。
2. 使用 `awk` 提取输出的第一列（IP 地址）。
3. 通过 `first_ipv4_address` 从命令输出中过滤有效的 IPv4 地址。

# 环境要求
- 宿主机必须安装并配置好 Lima。
- 目标 VM 实例必须处于运行状态。
- limactl 必须在宿主机 PATH 中可用。

# 命令构造说明
- `env -i HOME=/root PATH=...`：清理环境变量，避免宿主机环境污染 VM 内部执行。
- `shell_single_quote`：对脚本和命令参数进行单引号转义，防止 shell 注入。
"""
function lima_runtime_ip_resolver(endpoint::RuntimeEndpoint)::String
    # [执行流程]
    # 步骤1: 构造 VM 内部执行的 shell 脚本
    # - getent hosts 查询 DNS/hosts 记录获取主机名对应的 IP
    # - awk 提取第一列（IP 地址）并立即退出
    script = "getent hosts $(endpoint.runtime_hostname) 2>/dev/null | awk '{print \$1; exit}'"
    # 步骤2: 构造完整的 limactl shell 命令
    # - limactl shell <runtime_name>：进入指定 VM
    # - env -i HOME=/root PATH=...：清理环境变量，避免宿主机污染
    # - sh -lc <script>：执行脚本，-l 加载 profile（可能包含网络配置）
    command = "limactl shell $(shell_single_quote(endpoint.runtime_name)) -- env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin sh -lc $(shell_single_quote(script))"
    # 步骤3: 在宿主机上执行 shell 命令，捕获标准输出
    output = read(`sh -lc $command`, String)
    # 步骤4: 从命令输出中提取第一个有效的 IPv4 地址
    return first_ipv4_address(output)
end

# [算法说明]
# 注册表刷新算法：更新所有端点的动态IP地址。
# 核心逻辑：
# 1. 遍历注册表中的所有端点
# 2. 对每个端点调用解析器（默认lima_runtime_ip_resolver）
# 3. 使用try-catch捕获异常，确保单点失败不影响整体
# 4. 根据策略决定失败时的处理：
#    - keep_existing_on_failure=true：保留旧IP
#    - keep_existing_on_failure=false：清空为""
# 5. 构造新的RuntimeEndpoint（不可变结构体需重新构造）
# 6. 记录刷新结果（RuntimeEndpointRefreshResult）
# 返回值：(refreshed_registry, results)
#   - 原注册表不变（纯函数设计）
#   - results包含每个端点的刷新状态
"""
    refresh_runtime_endpoint_registry(
        registry::RuntimeEndpointRegistry;
        resolver::Function = lima_runtime_ip_resolver,
        keep_existing_on_failure::Bool = true,
    ) -> Tuple{RuntimeEndpointRegistry,Vector{RuntimeEndpointRefreshResult}}

刷新注册表中所有端点的运行时 IP。

对每个端点调用解析器函数（默认通过 Lima 查询 VM 内部 DNS），
获取当前实际 IP 地址，并生成刷新结果记录。

# 参数
- `registry::RuntimeEndpointRegistry`：要刷新的运行时端点注册表。
- `resolver::Function`：解析函数，接收 `RuntimeEndpoint` 返回 IP 字符串或 nothing；
  默认使用 `lima_runtime_ip_resolver`。
- `keep_existing_on_failure::Bool`：解析失败时是否保留旧 IP；否则清空为 `""`。

# 返回值
- 二元组 `(refreshed_registry, results)`：
  - `refreshed_registry`：包含更新后 IP 的新注册表（原注册表不变）。
  - `results`：每个端点的刷新结果向量，包含前后 IP、解析状态及错误信息。

# 异常处理
- 解析器抛出异常时会被捕获，错误信息记录到结果中，不会中断其他端点的刷新。
- 解析器返回 nothing 或空字符串时，视为解析失败。

# 线程安全
- 此函数为纯函数，不修改输入的 registry，返回新的注册表实例。
"""
function refresh_runtime_endpoint_registry(
    registry::RuntimeEndpointRegistry;
    resolver::Function = lima_runtime_ip_resolver,
    keep_existing_on_failure::Bool = true,
)::Tuple{RuntimeEndpointRegistry,Vector{RuntimeEndpointRefreshResult}}
    # 预分配结果容器，容量与端点数量一致
    refreshed_endpoints = RuntimeEndpoint[]
    results = RuntimeEndpointRefreshResult[]

    # [执行流程]
    # 步骤1: 逐个端点进行 IP 刷新（纯函数设计，不修改原注册表）
    for endpoint in registry.endpoints
        # 步骤2: 保存刷新前的 IP，用于后续对比和策略判断
        previous_ip = endpoint.runtime_ip
        # 步骤3: 初始化解析结果为未解析状态
        resolved_ip = ""
        error_message = ""

        # 步骤4: 调用解析器获取当前 IP，异常处理确保单点失败不影响整体
        try
            resolver_output = resolver(endpoint)
            # 解析器可能返回 nothing（表示无法解析），需做防御性检查
            if resolver_output !== nothing
                # 从解析器输出中提取第一个有效的 IPv4 地址
                resolved_ip = first_ipv4_address(String(resolver_output))
            end
        catch error
            # 捕获所有异常（如 VM 未运行、网络不可达、命令不存在等）
            # 将异常转换为可读字符串记录到结果中
            error_message = sprint(showerror, error)
        end

        # 判断解析是否成功：resolved_ip 非空表示成功获取到有效 IP
        resolved = !isempty(resolved_ip)
        # 确定最终 IP：解析成功则用新 IP；失败时根据策略保留旧 IP 或清空
        next_ip = resolved ? resolved_ip : (keep_existing_on_failure ? previous_ip : "")
        # 构造更新后的端点记录（仅 runtime_ip 变化）
        push!(refreshed_endpoints, runtime_endpoint_with_ip(endpoint, next_ip))
        # 记录本次刷新操作的详细结果，便于日志审计和故障排查
        push!(
            results,
            RuntimeEndpointRefreshResult(
                endpoint = runtime_endpoint_label(endpoint),
                runtime_name = endpoint.runtime_name,
                runtime_hostname = endpoint.runtime_hostname,
                previous_runtime_ip = previous_ip,
                runtime_ip = next_ip,
                resolved = resolved,
                error_message = error_message,
            ),
        )
    end

    # 步骤5: 使用更新后的端点列表构造新的注册表，保持其他元数据不变
    refreshed_registry = RuntimeEndpointRegistry(
        format = registry.format,
        version = registry.version,
        scenario_id = registry.scenario_id,
        backend = registry.backend,
        network = registry.network,
        endpoints = refreshed_endpoints,
    )
    return refreshed_registry, results
end

# [算法说明]
# 文件级注册表刷新算法：
# 1. 读取JSON文件中的注册表
# 2. 调用refresh_runtime_endpoint_registry()刷新所有端点IP
# 3. 将刷新后的注册表写回同一文件
# 4. 返回刷新后的注册表和结果
# 这是一个便捷函数，封装了读取-刷新-写入的完整流程。
"""
    refresh_runtime_endpoint_registry_file(
        path::AbstractString;
        resolver::Function = lima_runtime_ip_resolver,
        keep_existing_on_failure::Bool = true,
    ) -> Tuple{RuntimeEndpointRegistry,Vector{RuntimeEndpointRefreshResult}}

读取 JSON 注册表、刷新所有端点 IP，并把结果写回同一文件。
"""
function refresh_runtime_endpoint_registry_file(
    path::AbstractString;
    resolver::Function = lima_runtime_ip_resolver,
    keep_existing_on_failure::Bool = true,
)::Tuple{RuntimeEndpointRegistry,Vector{RuntimeEndpointRefreshResult}}
    registry = read_runtime_endpoint_registry(path)
    refreshed_registry, results = refresh_runtime_endpoint_registry(
        registry;
        resolver = resolver,
        keep_existing_on_failure = keep_existing_on_failure,
    )
    write_runtime_endpoint_registry(path, refreshed_registry)
    return refreshed_registry, results
end

# [算法说明]
# IP刷新结果序列化算法：
# 1. 将刷新结果字段转换为字典
# 2. 包含端点标识、刷新前后IP、解析状态和错误信息
# 3. 返回完整的字典结构
"""
    runtime_endpoint_refresh_result_dict(result::RuntimeEndpointRefreshResult) -> Dict{String,Any}

把 IP 刷新结果序列化为字典。
"""
function runtime_endpoint_refresh_result_dict(
    result::RuntimeEndpointRefreshResult,
)::Dict{String,Any}
    return Dict{String,Any}(
        "endpoint" => result.endpoint,
        "runtime_name" => result.runtime_name,
        "runtime_hostname" => result.runtime_hostname,
        "previous_runtime_ip" => result.previous_runtime_ip,
        "runtime_ip" => result.runtime_ip,
        "resolved" => result.resolved,
        "error_message" => result.error_message,
    )
end
