#=
本文件：src/deploy/model_generation/testbed_realization.jl

职责：
- 将 TestbedSpec 转换为 TestbedRealizationPlan。
- 验证测试床规格的完整性和一致性。
- 生成运行时所需的节点、网络和端点映射信息。

在项目流水线中的位置：
- 上游：testbed_model.jl 生成的 TestbedSpec。
- 下游：testbed_materialization.jl 将 TestbedRealizationPlan 转换为可部署的配置文件。

数据流说明：
- 输入：TestbedSpec 对象（来自 testbed_model.jl 的 load_testbed_spec()）
  → validate_testbed_spec(spec) 验证 ID 唯一性、IP 唯一性、引用完整性
  → effective_backend() 解析每个节点/网络的后端继承（:inherit → 环境后端）
  → runtime_name() 为每个节点/网络生成 Lima/Docker 合法的运行时名称
  → 遍历 spec.networks 生成 TestbedNetworkRealization 列表
  → 遍历 spec.nodes 生成 TestbedNodeRealization 列表
  → 遍历 spec.nodes 生成 TestbedEndpointMapping 列表（OEF端点→节点映射）
- 输出：TestbedRealizationPlan 对象（包含所有运行时配置信息）
  → 传递给 testbed_materialization.jl 的 write_lima_vm_files()
  → 由下游负责生成实际的 Lima VM 文件
- 辅助数据流：
  → print_testbed_realization_plan() 将计划格式化输出到 IO 流
  → ensure_unique() 被 image_catalog.jl 调用，验证镜像 ID 唯一性
  → effective_backend() 被 image_catalog.jl 间接使用，处理后端继承

[算法说明]
本文件的核心算法是将声明式的TestbedSpec转换为可执行的TestbedRealizationPlan。
主要处理逻辑包括：

1. **后端继承解析算法**：
   - 每个节点/网络的backend字段可以设置为:inherit
   - 当backend=:inherit时，使用环境级别的backend作为实际后端
   - 这种设计允许用户只在环境级别指定后端，节点自动继承
   - 函数effective_backend()实现此逻辑：local_backend == :inherit ? environment_backend : local_backend

2. **运行时名称生成算法**：
   - 格式："{name_prefix}-{node_id}"，其中下划线替换为连字符
   - 示例："mytest" + "ground_station_1" -> "mytest-ground-station-1"
   - 如果节点指定了namespace，则直接使用namespace作为运行时名称
   - 这种命名约定确保在Lima/Docker等环境中生成合法的资源名称

3. **端点映射算法**：
   - OEF(Orbital Event Format)定义了轨道事件中的端点标识
   - 每个端点由(endpoint_kind, endpoint_id)二元组唯一标识
   - 映射关系：OEF端点 -> TestbedNode -> 运行时VM实例
   - 这种映射使得轨道事件可以准确路由到对应的仿真节点

4. **完整性验证算法**：
   - ID唯一性检查：使用Set去重后比较长度
   - 引用完整性检查：确保所有引用的ID都存在于对应的集合中
   - 端点映射唯一性检查：确保每个OEF端点只映射到一个节点
=#

"""
    TestbedNodeRealization

测试床节点的运行时表示，包含节点在部署环境中的具体配置。

# 字段
- `node_id::String`：节点唯一标识符（来自 TestbedNode.id）
- `runtime_name::String`：运行时实例名称，用于在部署环境中唯一标识该节点
- `backend::Symbol`：节点后端类型，取值范围 `TESTBED_BACKENDS`
- `primary_network::String`：主网络 ID
- `primary_interface::String`：主网络接口名称
- `ip::String`：节点 IP 地址
- `endpoint_kind::Symbol`：OEF 端点类型（`:ground` 或 `:satellite`）
- `endpoint_id::Int`：OEF 端点编号
"""
struct TestbedNodeRealization
    node_id::String
    runtime_name::String
    backend::Symbol
    primary_network::String
    primary_interface::String
    ip::String
    endpoint_kind::Symbol
    endpoint_id::Int
end

"""
    TestbedNetworkRealization

测试床网络的运行时表示，包含网络在部署环境中的具体配置。

# 字段
- `network_id::String`：网络唯一标识符（来自 TestbedNetwork.id）
- `runtime_name::String`：运行时网络名称
- `backend::Symbol`：网络后端类型，取值范围 `TESTBED_BACKENDS`
- `kind::Symbol`：网络类型，取值范围 `TESTBED_NETWORK_KINDS`
- `subnet::String`：子网 CIDR（如 "192.168.1.0/24"）
"""
struct TestbedNetworkRealization
    network_id::String
    runtime_name::String
    backend::Symbol
    kind::Symbol
    subnet::String
end

"""
    TestbedEndpointMapping

OEF 端点到节点的映射，用于在运行时将轨道框架端点关联到具体节点。

# 字段
- `endpoint_kind::Symbol`：OEF 端点类型（`:ground` 或 `:satellite`）
- `endpoint_id::Int`：OEF 端点编号
- `node_id::String`：对应的节点 ID
"""
struct TestbedEndpointMapping
    endpoint_kind::Symbol
    endpoint_id::Int
    node_id::String
end

"""
    TestbedRealizationPlan

测试床实现计划，包含所有节点、网络和端点映射的运行时配置。

# 字段
- `scenario_id::String`：场景 ID
- `backend::Symbol`：默认后端类型，取值范围 `TESTBED_BACKENDS`
- `work_dir::String`：工作目录
- `nodes::Vector{TestbedNodeRealization}`：节点实现列表
- `networks::Vector{TestbedNetworkRealization}`：网络实现列表
- `endpoint_mappings::Vector{TestbedEndpointMapping}`：端点映射列表

# 说明
- 后端类型遵循继承规则：如果节点的 `backend` 设置为 `:inherit`，
  则使用环境的 `backend` 作为实际后端。
"""
struct TestbedRealizationPlan
    scenario_id::String
    backend::Symbol
    work_dir::String
    nodes::Vector{TestbedNodeRealization}
    networks::Vector{TestbedNetworkRealization}
    endpoint_mappings::Vector{TestbedEndpointMapping}
end

"""
    ensure_unique(values::Vector{String}, label::AbstractString) -> Nothing

确保字符串向量中的所有值都是唯一的，否则抛出错误。

# 参数
- `values::Vector{String}`：待检查的字符串向量
- `label::AbstractString`：标签名称，用于错误提示

# 返回
- `Nothing`

# 异常
- `ArgumentError`：当存在重复值时抛出
"""
function ensure_unique(values::Vector{String}, label::AbstractString)::Nothing
    length(values) == length(unique(values)) || throw(ArgumentError("$label must be unique"))
    return nothing
end

# [算法说明]
# 后端继承解析算法：实现配置的层级覆盖机制。
# 设计思想：允许在环境级别设置默认后端，节点级别可以覆盖或继承。
# 继承规则：
#   - local_backend=:inherit -> 使用environment_backend
#   - local_backend=其他值 -> 使用local_backend（覆盖）
# 这种设计减少了配置冗余，同时保持灵活性。
"""
    effective_backend(local_backend::Symbol, environment_backend::Symbol) -> Symbol

确定有效的后端类型，处理继承规则。

# 参数
- `local_backend::Symbol`：本地配置的后端类型
- `environment_backend::Symbol`：环境配置的后端类型

# 返回
- `Symbol`：有效的后端类型

# 说明
- 如果 `local_backend` 为 `:inherit`，则返回 `environment_backend`
- 否则返回 `local_backend`
"""
function effective_backend(local_backend::Symbol, environment_backend::Symbol)::Symbol
    return local_backend == :inherit ? environment_backend : local_backend
end

# [算法说明]
# 运行时名称生成算法：将内部ID转换为Lima/Docker等环境合法的资源名称。
# 规则："{prefix}-{id}"，其中下划线替换为连字符。
# 原因：Lima实例名、Docker容器名等不允许使用下划线，但支持连字符。
# 示例："mytest" + "ground_station_1" -> "mytest-ground-station-1"
"""
    runtime_name(prefix::String, id::String) -> String

生成运行时实例名称。

# 参数
- `prefix::String`：名称前缀
- `id::String`：原始 ID

# 返回
- `String`：生成的运行时名称，格式为 `prefix-id`，其中 `id` 中的下划线会被替换为连字符

# 示例
```julia
runtime_name("mytest", "ground_station_1")  # 返回 "mytest-ground-station-1"
```
"""
function runtime_name(prefix::String, id::String)::String
    return "$(prefix)-$(replace(id, "_" => "-"))"
end

# [算法说明]
# 完整性验证算法：确保TestbedSpec在部署前满足所有约束条件。
# 验证分为四类：
# 1. ID唯一性：使用Set去重后比较长度，O(n)时间复杂度
# 2. IP唯一性：确保网络配置无冲突
# 3. OEF端点唯一性：每个轨道事件端点只能映射到一个节点
# 4. 引用完整性：确保所有引用的ID都存在于对应集合中
# 验证失败时抛出ArgumentError，包含具体的错误位置信息。
"""
    validate_testbed_spec(spec::TestbedSpec) -> Nothing

验证测试床规格的完整性和一致性。

# 参数
- `spec::TestbedSpec`：待验证的测试床规格

# 返回
- `Nothing`

# 异常
- `ArgumentError`：当发现以下问题时抛出：
  - 节点 ID、网络 ID、链接 ID、服务 ID、检查 ID 存在重复
  - 节点 IP 地址存在重复
  - OEF 端点映射存在重复
  - 节点的主网络或控制网络不存在
  - 链接的端点或网络不存在
  - 服务的节点不存在
  - 检查的源或目标节点不存在

# 验证内容
1. ID 唯一性检查：
   - 所有节点 ID 必须唯一
   - 所有网络 ID 必须唯一
   - 所有链接 ID 必须唯一
   - 所有服务 ID 必须唯一
   - 所有检查 ID 必须唯一
2. IP 地址唯一性检查：
   - 所有指定 IP 地址的节点必须具有唯一的 IP
3. OEF 端点映射唯一性检查：
   - 所有 OEF 端点（kind:id 组合）必须唯一
4. 引用完整性检查：
   - 节点的主网络必须存在于网络列表中
   - 节点的控制网络（如果指定）必须存在于网络列表中
   - 链接的两个端点必须存在于节点列表中
   - 链接的网络必须存在于网络列表中
   - 服务的节点必须存在于节点列表中
   - 检查的源节点和目标节点必须存在于节点列表中
"""
function validate_testbed_spec(spec::TestbedSpec)::Nothing
    # [执行流程]
    # 步骤1: 提取所有 ID 和关键字段列表
    node_ids = [node.id for node in spec.nodes]
    network_ids = [network.id for network in spec.networks]
    link_ids = [link.id for link in spec.links]
    service_ids = [service.id for service in spec.services]
    check_ids = [check.id for check in spec.checks]
    node_ips = [node.ip for node in spec.nodes if !isempty(node.ip)]
    endpoint_keys = ["$(node.endpoint_kind):$(node.endpoint_id)" for node in spec.nodes]

    # 步骤2: ID 唯一性检查（节点、网络、链接、服务、检查）
    ensure_unique(node_ids, "node ids")
    ensure_unique(network_ids, "network ids")
    ensure_unique(link_ids, "link ids")
    ensure_unique(service_ids, "service ids")
    ensure_unique(check_ids, "check ids")
    # 步骤3: IP 地址唯一性检查
    ensure_unique(node_ips, "node IP addresses")
    # 步骤4: OEF 端点映射唯一性检查（每个 (kind, id) 组合只能映射到一个节点）
    ensure_unique(endpoint_keys, "OEF endpoint mappings")

    # 步骤5: 引用完整性检查 — 构建 ID 集合用于快速查找
    node_id_set = Set(node_ids)
    network_id_set = Set(network_ids)

    # 步骤6: 验证节点的主网络和控制网络是否存在
    for node in spec.nodes
        node.primary_network in network_id_set ||
            throw(ArgumentError("node $(node.id) primary_network $(node.primary_network) does not exist"))
        if !isempty(node.control_network)
            node.control_network in network_id_set ||
                throw(ArgumentError("node $(node.id) control_network $(node.control_network) does not exist"))
        end
    end

    # 步骤7: 验证链接的端点和网络是否存在
    for link in spec.links
        link.endpoint_a in node_id_set ||
            throw(ArgumentError("link $(link.id) endpoint_a $(link.endpoint_a) does not exist"))
        link.endpoint_b in node_id_set ||
            throw(ArgumentError("link $(link.id) endpoint_b $(link.endpoint_b) does not exist"))
        link.network in network_id_set ||
            throw(ArgumentError("link $(link.id) network $(link.network) does not exist"))
    end

    # 步骤8: 验证服务绑定的节点是否存在
    for service in spec.services
        service.node in node_id_set ||
            throw(ArgumentError("service $(service.id) node $(service.node) does not exist"))
    end

    # 步骤9: 验证检查的源节点和目标节点是否存在
    for check in spec.checks
        check.from in node_id_set ||
            throw(ArgumentError("check $(check.id) from node $(check.from) does not exist"))
        check.to in node_id_set ||
            throw(ArgumentError("check $(check.id) to node $(check.to) does not exist"))
    end

    return nothing
end

"""
    realize_testbed_spec(spec::TestbedSpec) -> TestbedRealizationPlan

将测试床规格转换为测试床实现计划。

# 参数
- `spec::TestbedSpec`：测试床规格

# 返回
- `TestbedRealizationPlan`：测试床实现计划

# 处理流程
1. 验证测试床规格的完整性和一致性
2. 从环境配置获取默认后端和名称前缀
3. 为每个网络生成运行时网络实现：
   - 使用 `effective_backend` 处理继承规则
   - 生成运行时网络名称
4. 为每个节点生成运行时节点实现：
   - 使用 `effective_backend` 处理继承规则
   - 如果指定了命名空间则使用命名空间，否则生成运行时名称
   - 记录主网络、主接口、IP、端点等信息
5. 生成端点映射列表
6. 返回完整的实现计划

# 说明
- 网络的运行时名称格式为 `prefix-network-id`，其中下划线替换为连字符
- 节点的运行时名称：
  - 如果节点指定了 `namespace`，则使用该命名空间
  - 否则格式为 `prefix-node-id`，其中下划线替换为连字符
- 端点映射用于后续将 OEF 轨道框架的端点与具体节点关联
"""
function realize_testbed_spec(spec::TestbedSpec)::TestbedRealizationPlan
    # [执行流程]
    # 步骤1: 验证测试床规格的完整性和一致性（ID唯一性、引用完整性等）
    validate_testbed_spec(spec)
    # 步骤2: 从环境配置获取默认后端和名称前缀
    environment_backend = spec.environment.backend
    prefix = spec.environment.name_prefix

    # 步骤3: 为每个网络生成运行时网络实现
    # - 使用 effective_backend() 处理继承规则（:inherit → 环境后端）
    # - 使用 runtime_name() 生成 Lima/Docker 合法的网络名称
    networks = [
        TestbedNetworkRealization(
            network.id,                              # 保留原始网络 ID
            runtime_name(prefix, network.id),        # 生成运行时名称：prefix-network-id
            effective_backend(network.backend, environment_backend),  # 解析后端继承
            network.kind,                            # 保留网络类型
            network.subnet,                          # 保留子网配置
        )
        for network in spec.networks
    ]

    # 步骤4: 为每个节点生成运行时节点实现
    # - 如果节点指定了 namespace，直接使用；否则生成运行时名称
    # - 记录主网络、主接口、IP、OEF 端点等运行时信息
    nodes = [
        TestbedNodeRealization(
            node.id,                                 # 保留原始节点 ID
            isempty(node.namespace) ? runtime_name(prefix, node.id) : node.namespace,  # 运行时名称
            effective_backend(node.backend, environment_backend),  # 解析后端继承
            node.primary_network,                    # 主网络 ID
            node.primary_interface,                  # 主网络接口
            node.ip,                                 # 静态 IP 地址
            node.endpoint_kind,                      # OEF 端点类型
            node.endpoint_id,                        # OEF 端点编号
        )
        for node in spec.nodes
    ]

    # 步骤5: 生成端点映射列表
    # - 建立 OEF 端点 (kind, id) → 节点 ID 的映射关系
    # - 用于后续将轨道事件准确路由到对应的仿真节点
    endpoint_mappings = [
        TestbedEndpointMapping(node.endpoint_kind, node.endpoint_id, node.id)
        for node in spec.nodes
    ]

    # 步骤6: 组装并返回完整的 TestbedRealizationPlan
    return TestbedRealizationPlan(
        spec.scenario.id,
        environment_backend,
        spec.environment.work_dir,
        nodes,
        networks,
        endpoint_mappings,
    )
end

"""
    print_testbed_realization_plan(io::IO, plan::TestbedRealizationPlan) -> Nothing

以可读格式打印测试床实现计划到指定的 IO 流。

# 参数
- `io::IO`：输出 IO 流
- `plan::TestbedRealizationPlan`：待打印的测试床实现计划

# 返回
- `Nothing`

# 输出格式
```
TestbedRealizationPlan: <scenario_id>
  backend: <backend>
  work_dir: <work_dir>
  networks:
    <network_id> runtime=<runtime_name> kind=<kind> backend=<backend> subnet=<subnet>
  nodes:
    <node_id> runtime=<runtime_name> backend=<backend> ip=<ip> <primary_network>/<primary_interface>
  OEF endpoint mappings:
    <endpoint_kind>:<endpoint_id> -> <node_id>
```
"""
function print_testbed_realization_plan(io::IO, plan::TestbedRealizationPlan)::Nothing
    println(io, "TestbedRealizationPlan: $(plan.scenario_id)")
    println(io, "  backend: $(plan.backend)")
    println(io, "  work_dir: $(plan.work_dir)")

    println(io, "  networks:")
    for network in plan.networks
        subnet = isempty(network.subnet) ? "none" : network.subnet
        println(io, "    $(network.network_id) runtime=$(network.runtime_name) kind=$(network.kind) backend=$(network.backend) subnet=$subnet")
    end

    println(io, "  nodes:")
    for node in plan.nodes
        println(
            io,
            "    $(node.node_id) runtime=$(node.runtime_name) backend=$(node.backend) ip=$(node.ip) $(node.primary_network)/$(node.primary_interface)",
        )
    end

    println(io, "  OEF endpoint mappings:")
    for mapping in plan.endpoint_mappings
        println(io, "    $(mapping.endpoint_kind):$(mapping.endpoint_id) -> $(mapping.node_id)")
    end
    return nothing
end

"""
    print_testbed_realization_plan(plan::TestbedRealizationPlan) -> Nothing

以可读格式打印测试床实现计划到标准输出。

# 参数
- `plan::TestbedRealizationPlan`：待打印的测试床实现计划

# 返回
- `Nothing`
"""
print_testbed_realization_plan(plan::TestbedRealizationPlan)::Nothing =
    print_testbed_realization_plan(stdout, plan)