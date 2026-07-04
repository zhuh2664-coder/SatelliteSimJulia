#=
本文件：src/deploy/materialization/testbed_materialization.jl

职责：
- 定义测试床物化计划（TestbedMaterializationPlan）及其节点记录。
- 将 TestbedRealizationPlan 转换为可在 Lima 上运行的 VM 配置：
  为每个节点生成 YAML、start/stop 脚本，并创建运行时端点注册表。
- 提供 Lima VM YAML 组装、启动脚本生成、镜像配置读取等工具函数。

在项目流水线中的位置：
- 上游：deploy/model_generation/testbed_realization.jl 生成的 TestbedRealizationPlan。
- 下游：生成 runtime_endpoints.json（供 channel_manager 使用）与 Lima VM 文件。

数据流说明：
- 输入：TestbedRealizationPlan 对象（来自 testbed_realization.jl 的 realize_testbed_spec()）
  + TestbedSpec 对象（用于查找节点详细配置）
  + 可选 ImageCatalog（用于解析节点资源配置）
  → write_lima_vm_files() 是核心入口函数
  → 验证 backend 为 :vm（当前仅支持 VM 后端）
  → 验证镜像引用（如果提供了 ImageCatalog）
  → 遍历 plan.nodes，对每个 :vm 后端节点：
    → find_spec_node() 查找原始节点规格
    → effective_*() 系列函数解析 CPU/内存/镜像等资源
    → lima_vm_yaml() 生成 Lima VM YAML 配置文件
    → 写入磁盘：vm/<runtime_name>.yaml
  → 生成启动脚本 start_vms.sh（使用 limactl start 启动每个 VM）
  → 生成停止脚本 stop_vms.sh（使用 limactl stop 停止每个 VM）
  → 生成运行时端点注册表 runtime_endpoints.json（供通道管理器使用）
- 输出：TestbedMaterializationPlan 对象（包含所有 VM 节点、脚本路径和注册表路径）
  → 传递给 runtime_endpoint_registry.jl 的 build_runtime_endpoint_registry()
  → 传递给 channel_manager.jl 的 VMRouteChannelManager
  → 实际生成的文件（YAML、脚本、JSON）写入磁盘供后续使用
- 辅助数据流：
  → find_materialized_endpoint()：按 OEF 端点查找物化后的 VM 节点
  → print_testbed_materialization_plan()：将计划格式化输出到 IO 流

[算法说明]
本文件的核心算法是将抽象的TestbedRealizationPlan转换为具体的可部署文件。
主要处理逻辑包括：

1. **Lima VM YAML生成算法**：
   - Lima是一个轻量级虚拟机管理器，使用YAML配置文件定义VM规格
   - YAML配置包含：基础镜像、CPU/内存资源、网络配置、启动脚本
   - 核心配置参数：
     * minimumLimaVersion: 最低Lima版本要求
     * base: 基础镜像标识（如ubuntu-22.04）
     * vmType: 虚拟机类型（当前硬编码为"vz"，支持Apple Silicon）
     * arch: 架构（硬编码为"aarch64"）
     * cpus: CPU核心数（从节点配置或镜像目录获取）
     * memory: 内存大小（从MB转换为GiB，向上取整）
     * disk: 磁盘大小（固定为8GiB）
   - Provision脚本在VM启动时执行，负责：
     * 写入节点环境变量文件(/etc/ssj-node.env)
     * 设置主机名
     * 执行镜像特定的provision脚本

2. **Shell heredoc引号算法**：
   - shell_single_quote()：对字符串做单引号转义
     * 规则：内部单引号替换为'\"'\"'
     * 原理：单引号字符串内不能直接包含单引号
     * 示例："it's" -> "'it'\"'\"'s'"
   - shell_heredoc_quote()：对字符串做YAML heredoc缩进
     * 规则：每行前添加4个空格缩进
     * 用途：嵌入YAML的provision脚本中
     * 示例："line1\nline2" -> "    line1\n    line2"

3. **VM文件收集算法**：
   - 遍历TestbedRealizationPlan中的所有节点
   - 过滤出backend=:vm的节点（当前仅支持VM后端）
   - 为每个节点生成Lima YAML配置文件
   - 生成启动脚本(start_vms.sh)和停止脚本(stop_vms.sh)
   - 生成运行时端点注册表(runtime_endpoints.json)
   - 文件结构：
     <work_dir>/
       vm/
         <node1>.yaml
         <node2>.yaml
         ...
         start_vms.sh
         stop_vms.sh
       runtime_endpoints.json

4. **内存单位转换算法**：
   - memory_gib()：将MB转换为GiB
   - 公式：max(1, cld(memory_mb, 1024))
   - cld是向上取整除法，确保VM有足够内存
   - 最小值为1GiB，避免分配过小的内存
=#

"""
    TestbedVMNodeMaterialization

单个节点在物化后的 VM 记录。

# 字段
- `node_id::String`：TestbedSpec 中的节点 id。
- `runtime_name::String`：运行时实例名（Lima 实例名）。
- `endpoint_kind::Symbol`：OEF endpoint 类型（`:ground` 或 `:satellite`）。
- `endpoint_id::Int`：OEF endpoint 编号。
- `configured_ip::String`：节点配置的静态 IP。
- `lima_hostname::String`：Lima 内部网络主机名（`lima-<runtime_name>.internal`）。
- `config_path::String`：生成的 Lima YAML 文件路径。
"""
struct TestbedVMNodeMaterialization
    node_id::String
    runtime_name::String
    endpoint_kind::Symbol
    endpoint_id::Int
    configured_ip::String
    lima_hostname::String
    config_path::String
end

"""
    TestbedMaterializationPlan

测试床物化计划，包含所有 VM 节点、启动/停止脚本与运行时注册表路径。

# 字段
- `scenario_id::String`：场景 id。
- `backend::Symbol`：后端类型，当前实现主要支持 `:vm`。
- `work_dir::String`：工作目录。
- `vm_dir::String`：存放 VM YAML 与启动脚本的子目录。
- `network::String`：Lima 网络名称。
- `nodes::Vector{TestbedVMNodeMaterialization}`：物化后的节点列表。
- `start_script_path::String`：启动脚本路径。
- `stop_script_path::String`：停止脚本路径。
- `runtime_registry_path::String`：运行时端点注册表 JSON 路径。

# 说明
- 物化计划是实际部署文件的集合，包括：
  - 每个节点的 Lima VM YAML 配置文件
  - 启动所有 VM 的脚本
  - 停止所有 VM 的脚本
  - 运行时端点注册表（供通道管理器使用）
"""
struct TestbedMaterializationPlan
    scenario_id::String
    backend::Symbol
    work_dir::String
    vm_dir::String
    network::String
    nodes::Vector{TestbedVMNodeMaterialization}
    start_script_path::String
    stop_script_path::String
    runtime_registry_path::String
end

"""
    endpoint_label(kind::Symbol, id::Int) -> String

生成 OEF 端点标签，格式为 `"kind:id"`。

# 参数
- `kind::Symbol`：OEF 端点类型（`:ground` 或 `:satellite`）
- `id::Int`：OEF 端点编号

# 返回
- `String`：端点标签，格式为 `"kind:id"`

# 示例
```julia
endpoint_label(:ground, 1)  # 返回 "ground:1"
endpoint_label(:satellite, 5)  # 返回 "satellite:5"
```
"""
function endpoint_label(kind::Symbol, id::Int)::String
    return "$(kind):$(id)"
end

"""
    lima_internal_hostname(runtime_name::AbstractString) -> String

根据 Lima 实例名生成 Lima 内部主机名（`lima-<runtime_name>.internal`）。

# 参数
- `runtime_name::AbstractString`：Lima 实例名

# 返回
- `String`：Lima 内部主机名

# 说明
- Lima 使用 `lima-<instance>.internal` 作为内部网络主机名
- 这个名称可以用于 VM 之间的内部通信

# 示例
```julia
lima_internal_hostname("mytest-ground-station-1")
# 返回 "lima-mytest-ground-station-1.internal"
```
"""
function lima_internal_hostname(runtime_name::AbstractString)::String
    return "lima-$(runtime_name).internal"
end

# [算法说明]
# 内存单位转换算法：将MB转换为GiB。
# 公式：max(1, cld(memory_mb, 1024))
# - cld是向上取整除法，确保VM有足够内存
# - max(1, ...)确保最小值为1GiB
# 示例：512MB -> 1GiB, 1024MB -> 1GiB, 1536MB -> 2GiB
"""
    memory_gib(memory_mb::Int) -> Int

将内存从 MB 转换为 GiB，向上取整且至少为 1。

# 参数
- `memory_mb::Int`：内存大小（MB）

# 返回
- `Int`：内存大小（GiB）

# 异常
- `ArgumentError`：当 memory_mb 不为正整数时抛出

# 说明
- 向上取整确保 VM 有足够内存
- 最小值为 1 GiB

# 示例
```julia
memory_gib(512)    # 返回 1
memory_gib(1024)   # 返回 1
memory_gib(1536)   # 返回 2
memory_gib(2048)   # 返回 2
```
"""
function memory_gib(memory_mb::Int)::Int
    memory_mb > 0 || throw(ArgumentError("memory_mb must be positive"))
    return max(1, cld(memory_mb, 1024))
end

"""
    find_spec_node(spec::TestbedSpec, node_id::AbstractString) -> TestbedNode

在 TestbedSpec 中按节点 id 查找对应的 Spec 节点；未找到则抛出错误。

# 参数
- `spec::TestbedSpec`：测试床规格
- `node_id::AbstractString`：节点 ID

# 返回
- `TestbedNode`：找到的节点

# 异常
- `ArgumentError`：当节点不存在时抛出
"""
function find_spec_node(spec::TestbedSpec, node_id::AbstractString)::TestbedNode
    for node in spec.nodes
        node.id == node_id && return node
    end
    throw(ArgumentError("node $node_id not found in testbed spec"))
end

# [算法说明]
# Shell单引号转义算法：安全地将字符串嵌入shell命令。
# 规则：外部用单引号包裹，内部单引号替换为'\"'\"'
# 原理：单引号字符串内不能直接包含单引号，需要通过以下方式转义：
#   ' -> '\''
#   即：结束当前单引号 -> 双引号包裹单引号 -> 开始新单引号
# 示例："it's" -> "'it'\"'\"'s'"
# 用途：在limactl命令中安全传递参数
"""
    shell_single_quote(value::AbstractString) -> String

对字符串做单引号转义，便于嵌入 shell 命令。

# 参数
- `value::AbstractString`：待转义的字符串

# 返回
- `String`：用单引号包裹的字符串，其中原有的单引号被转义为 `'\"'\"'`

# 说明
- 单引号是 shell 中最安全的字符串引用方式
- 但单引号内无法直接包含单引号，需要用 `'\"'\"'` 转义

# 示例
```julia
shell_single_quote("hello")  # 返回 "'hello'"
shell_single_quote("it's")   # 返回 "'it'\"'\"'s'"
```
"""
function shell_single_quote(value::AbstractString)::String
    return "'" * replace(String(value), "'" => "'\"'\"'") * "'"
end

# [算法说明]
# Heredoc缩进算法：为YAML heredoc中的多行脚本添加缩进。
# 规则：每行前添加4个空格缩进
# 原因：YAML heredoc（使用|标识）对缩进敏感，需要保持一致性
# 示例："line1\nline2" -> "    line1\n    line2"
# 用途：嵌入Lima YAML的provision脚本中
"""
    shell_heredoc_quote(value::AbstractString) -> String

将字符串每一行缩进 4 个空格，便于嵌入 YAML heredoc 脚本块。

# 参数
- `value::AbstractString`：待格式化的字符串

# 返回
- `String`：每行缩进 4 个空格的字符串

# 说明
- YAML 中的 heredoc 使用 `|` 或 `|`- 标识多行字符串
- 为了保持缩进一致性，需要在每一行前添加缩进

# 示例
```julia
shell_heredoc_quote("line1\nline2")
# 返回 "    line1\n    line2"
```
"""
function shell_heredoc_quote(value::AbstractString)::String
    return replace(String(value), "\n" => "\n    ")
end

"""
    default_project_root() -> String

返回项目根目录，使用 `Base.pkgdir(SatelliteSimJulia)` 解析。

# 返回
- `String`：项目根目录路径

# 说明
- 使用 Julia 的包管理器来确定 SatelliteSimJulia 包的根目录
- 适用于作为包安装的场景
"""
function default_project_root()::String
    return Base.pkgdir(SatelliteSimJulia)
end

# [算法说明]
# 项目根目录定位算法：
# 1. 假设工作目录位于项目根目录下的某个子目录中
# 2. 向上回溯三级：work_dir/../../..
# 3. 检查候选目录是否包含src和config子目录
# 4. 如果包含，认为是项目根目录
# 5. 否则使用default_project_root()作为备选
# 用途：允许用户在任意子目录中工作，自动定位项目根目录。
"""
    project_root_from_work_dir(work_dir::AbstractString) -> String

尝试从工作目录反向定位项目根目录（需包含 `src` 与 `config` 目录）；
失败时回退到 `default_project_root()`。

# 参数
- `work_dir::AbstractString`：工作目录

# 返回
- `String`：项目根目录路径

# 说明
- 假设工作目录位于项目根目录下的某个子目录中
- 向上回溯三级查找项目根目录
- 如果找到的目录包含 `src` 和 `config` 子目录，则认为是项目根目录
- 否则使用 `default_project_root()` 作为备选

# 用途
- 允许用户在任意子目录中工作，自动定位项目根目录
- 用于解析相对于项目根目录的配置文件路径
"""
function project_root_from_work_dir(work_dir::AbstractString)::String
    # 假设 work_dir 位于项目根目录下的某个子目录中，向上回溯三级
    candidate = abspath(joinpath(String(work_dir), "..", "..", ".."))
    isdir(joinpath(candidate, "src")) && isdir(joinpath(candidate, "config")) && return candidate
    return default_project_root()
end

"""
    image_provision_script(
        node::TestbedNode,
        catalog::Union{Nothing,ImageCatalog},
    ) -> String

返回节点对应镜像的 provision 脚本路径；无镜像或目录时返回空字符串。

# 参数
- `node::TestbedNode`：测试床节点
- `catalog::Union{Nothing,ImageCatalog}`：镜像目录（可为 nil）

# 返回
- `String`：provision 脚本路径，如果未找到则返回空字符串

# 说明
- 如果未提供镜像目录，返回空字符串
- 如果节点没有关联镜像，返回空字符串
- 否则返回镜像配置中指定的 provision 脚本路径
"""
function image_provision_script(node::TestbedNode, catalog::Union{Nothing,ImageCatalog})::String
    catalog === nothing && return ""
    image = node_image(catalog, node)
    image === nothing && return ""
    return image.provision_script
end

# [算法说明]
# Provision脚本读取算法：
# 1. 调用image_provision_script()获取脚本路径
# 2. 如果路径为空，返回空字符串
# 3. 判断路径类型：
#    - 绝对路径：直接使用
#    - 相对路径：相对于项目根目录解析
# 4. 验证文件存在性
# 5. 读取文件内容并返回
# 用途：在Lima VM YAML中嵌入镜像特定的初始化脚本。
"""
    read_image_provision_script(
        node::TestbedNode,
        catalog::Union{Nothing,ImageCatalog},
        project_root::AbstractString,
    ) -> String

读取节点对应镜像的 provision 脚本内容。支持绝对路径与相对于项目根目录的相对路径。

# 参数
- `node::TestbedNode`：测试床节点
- `catalog::Union{Nothing,ImageCatalog}`：镜像目录（可为 nil）
- `project_root::AbstractString`：项目根目录，用于解析相对路径

# 返回
- `String`：provision 脚本内容

# 异常
- `ArgumentError`：当脚本路径不为空但文件不存在时抛出

# 说明
- 如果未提供镜像目录或节点没有关联镜像，返回空字符串
- 如果 provision 脚本路径为绝对路径，直接使用
- 如果是相对路径，相对于项目根目录解析
- 读取文件内容并返回
"""
function read_image_provision_script(
    node::TestbedNode,
    catalog::Union{Nothing,ImageCatalog},
    project_root::AbstractString,
)::String
    script_path = image_provision_script(node, catalog)
    isempty(script_path) && return ""
    resolved_path = isabspath(script_path) ? script_path : joinpath(project_root, script_path)
    isfile(resolved_path) || throw(ArgumentError("provision script $script_path for image $(node.image) was not found at $resolved_path"))
    return read(resolved_path, String)
end

# [算法说明]
# Lima VM YAML生成算法：将节点配置转换为Lima可执行的YAML配置。
# 核心逻辑：
# 1. 从节点配置和镜像目录获取资源参数（CPU、内存、镜像等）
# 2. 生成provision脚本，用于VM初始化：
#    - 写入环境变量文件(/etc/ssj-node.env)
#    - 设置主机名
#    - 执行镜像特定的provision脚本（如有）
# 3. 使用shell_heredoc_quote()处理嵌入脚本的缩进
# 4. 返回完整的YAML字符串
#
# YAML结构说明：
# - minimumLimaVersion: 确保Lima版本兼容性
# - base: 基础镜像，支持Lima模板语法
# - vmType/arch: 针对Apple Silicon优化（vz + aarch64）
# - provision: VM启动时执行的脚本列表
"""
    lima_vm_yaml(
        node::TestbedNode,
        realized_node::TestbedNodeRealization;
        image_catalog::Union{Nothing,ImageCatalog} = nothing,
        project_root::AbstractString = pwd(),
    ) -> String

为单个 Lima VM 生成 YAML 配置文件。

# 参数
- `node::TestbedNode`：测试床节点规格
- `realized_node::TestbedNodeRealization`：已实现的节点
- `image_catalog::Union{Nothing,ImageCatalog} = nothing`：镜像目录（可选）
- `project_root::AbstractString = pwd()`：项目根目录（默认当前目录）

# 返回
- `String`：Lima VM YAML 配置文件内容

# 配置内容包括
- `minimumLimaVersion`：最低 Lima 版本要求
- `base`：基础镜像
- `vmType`：虚拟机类型（硬编码为 `"vz"`，用于 Apple Silicon）
- `arch`：架构（硬编码为 `"aarch64"`，用于 ARM64）
- `cpus`：CPU 核心数
- `memory`：内存大小（GiB）
- `disk`：磁盘大小（固定为 8GiB）
- `mounts`：挂载点（空数组）
- `containerd`：容器运行时配置（禁用）
- `provision`：配置脚本，包括：
  - 节点环境变量 `/etc/ssj-node.env`，写入：
    - `SSJ_NODE_ID`：节点 ID
    - `SSJ_NODE_KIND`：节点类型
    - `SSJ_NODE_ROLE`：节点角色
    - `SSJ_OEF_ENDPOINT`：OEF 端点标签
    - `SSJ_CONFIGURED_IP`：配置的 IP 地址
    - `SSJ_IMAGE_ID`：镜像 ID
    - `SSJ_SSH_USER`：SSH 用户名
  - 主机名设置
  - 可选的镜像级 provision 脚本（来自 ImageCatalog）

# 说明
- 当前硬编码 `vmType: "vz"` 与 `arch: "aarch64"`，面向 Apple Silicon 的 Lima 后端
- 每个节点都会获得一个独立的环境变量文件
- provision 脚本在 VM 启动时执行

# 示例
生成的 YAML 示例：
```yaml
minimumLimaVersion: 2.0.0

base:
- ubuntu-22.04

vmType: "vz"
arch: "aarch64"
cpus: 2
memory: "2GiB"
disk: "8GiB"

mounts: []

containerd:
  system: false
  user: false

provision:
- mode: system
  script: |
    #!/bin/sh
    set -eux
    cat >/etc/ssj-node.env <<'EOF'
    SSJ_NODE_ID=ground_station_1
    SSJ_NODE_KIND=ground
    SSJ_NODE_ROLE=data_center
    SSJ_OEF_ENDPOINT=ground:1
    SSJ_CONFIGURED_IP=192.168.1.10
    SSJ_IMAGE_ID=ubuntu-base
    SSJ_SSH_USER=ubuntu
    EOF
    hostnamectl set-hostname mytest-ground-station-1 || true
```
"""
function lima_vm_yaml(
    node::TestbedNode,
    realized_node::TestbedNodeRealization;
    image_catalog::Union{Nothing,ImageCatalog} = nothing,
    project_root::AbstractString = pwd(),
)::String
    hostname = realized_node.runtime_name
    # [执行流程]
    # 步骤1: 从节点配置和镜像目录解析资源参数（优先级链：节点配置 > 镜像目录 > 全局默认）
    cpu_cores = effective_cpu_cores(node, image_catalog)
    memory = memory_gib(effective_memory_mb(node, image_catalog))
    base_image = effective_vm_image(node, image_catalog)
    ssh_user = effective_ssh_user(node, image_catalog)
    # 步骤2: 生成 OEF 端点标签（格式："kind:id"）
    endpoint = endpoint_label(node.endpoint_kind, node.endpoint_id)
    # 步骤3: 读取镜像特定的 provision 脚本（如果有）
    provision_script = read_image_provision_script(node, image_catalog, project_root)
    # 步骤4: 构建镜像特定的 provision 脚本块（如果有）
    # - 使用 shell_heredoc_quote() 处理嵌入脚本的缩进
    image_provision_block = isempty(provision_script) ? "" : """

- mode: system
  script: |
    $(shell_heredoc_quote(provision_script))
"""
    # 步骤5: 组装完整的 Lima VM YAML 配置
    # - YAML 包含：基础镜像、VM 类型、架构、CPU/内存/磁盘、挂载点、provision 脚本
    # - provision 脚本在 VM 启动时执行：写入环境变量文件、设置主机名、执行镜像 provision
    return """
minimumLimaVersion: 2.0.0

base:
- $(base_image)

vmType: "vz"
arch: "aarch64"
cpus: $(cpu_cores)
memory: "$(memory)GiB"
disk: "8GiB"

mounts: []

containerd:
  system: false
  user: false

provision:
- mode: system
  script: |
    #!/bin/sh
    set -eux
    cat >/etc/ssj-node.env <<'EOF'
    SSJ_NODE_ID=$(node.id)
    SSJ_NODE_KIND=$(node.kind)
    SSJ_NODE_ROLE=$(node.role)
    SSJ_OEF_ENDPOINT=$(endpoint)
    SSJ_CONFIGURED_IP=$(node.ip)
    SSJ_IMAGE_ID=$(node.image)
    SSJ_SSH_USER=$(ssh_user)
    EOF
    hostnamectl set-hostname $(hostname) || true
$(image_provision_block)
"""
end

# [算法说明]
# 可执行文件写入算法：
# 1. 使用write()写入文件内容
# 2. 使用chmod()设置权限为0o755
#    - 所有者：读+写+执行（rwx）
#    - 组用户：读+执行（r-x）
#    - 其他用户：读+执行（r-x）
# 用途：写入shell脚本并使其可执行。
"""
    write_executable(path::AbstractString, content::AbstractString) -> Nothing

将内容写入文件并设置可执行权限（0o755）。

# 参数
- `path::AbstractString`：文件路径
- `content::AbstractString`：文件内容

# 返回
- `Nothing`

# 说明
- 写入文件后设置权限为 0o755（所有者可读写执行，其他用户可读执行）
- 常用于写入 shell 脚本并使其可执行
"""
function write_executable(path::AbstractString, content::AbstractString)::Nothing
    write(path, content)
    chmod(path, 0o755)
    return nothing
end

# [算法说明]
# Lima VM文件生成算法：将TestbedRealizationPlan转换为可部署的文件集合。
# 核心流程：
# 1. 验证后端类型（当前仅支持:vm）
# 2. 验证镜像引用（如果提供了ImageCatalog）
# 3. 创建VM配置目录
# 4. 为每个VM后端节点生成Lima YAML配置文件
# 5. 生成启动脚本(start_vms.sh)：
#    - 使用limactl start启动每个VM
#    - 使用--name指定实例名，--network指定网络
#    - 末尾执行limactl list查看实例状态
# 6. 生成停止脚本(stop_vms.sh)：
#    - 使用limactl stop停止每个VM
#    - || true忽略停止失败（VM可能未运行）
# 7. 生成运行时端点注册表(runtime_endpoints.json)
# 8. 返回TestbedMaterializationPlan
#
# 文件结构：
# <work_dir>/
#   vm/
#     <node1>.yaml
#     <node2>.yaml
#     ...
#     start_vms.sh
#     stop_vms.sh
#   runtime_endpoints.json
"""
    write_lima_vm_files(
        spec::TestbedSpec,
        plan::TestbedRealizationPlan;
        network::AbstractString = "lima:user-v2",
        image_catalog::Union{Nothing,ImageCatalog} = nothing,
        project_root::AbstractString = project_root_from_work_dir(plan.work_dir),
    ) -> TestbedMaterializationPlan

将 TestbedRealizationPlan 物化为 Lima VM 文件。

# 参数
- `spec::TestbedSpec`：测试床规格
- `plan::TestbedRealizationPlan`：测试床实现计划
- `network::AbstractString = "lima:user-v2"`：Lima 网络名称（默认）
- `image_catalog::Union{Nothing,ImageCatalog} = nothing`：镜像目录（可选）
- `project_root::AbstractString = project_root_from_work_dir(plan.work_dir)`：项目根目录

# 返回
- `TestbedMaterializationPlan`：测试床物化计划

# 异常
- `ArgumentError`：当 `plan.backend` 不为 `:vm` 时抛出

# 主要步骤
1. 确保 backend 为 `:vm`（当前只支持 VM 物化）
2. 验证所有引用的镜像（如果提供了 ImageCatalog）
3. 创建 VM 配置目录 `vm_dir`
4. 为每个 `:vm` 后端节点生成 Lima YAML：
   - 查找节点规格
   - 生成 YAML 文件路径
   - 写入 Lima VM YAML 配置
   - 记录物化节点信息
5. 生成启动脚本 `start_vms.sh`：
   - 为每个 VM 添加启动命令
   - 在末尾添加 `limactl list` 命令查看实例状态
6. 生成停止脚本 `stop_vms.sh`：
   - 为每个 VM 添加停止命令
   - 允许停止失败（使用 `|| true`）
7. 生成运行时端点注册表 `runtime_endpoints.json`
8. 返回物化计划

# 生成的文件结构
# ```
# <work_dir>/
#   vm/
#     <node1>.yaml          # Lima VM 配置文件
#     <node2>.yaml          # Lima VM 配置文件
#     ...
#     start_vms.sh          # 启动所有 VM 的脚本（可执行）
#     stop_vms.sh           # 停止所有 VM 的脚本（可执行）
#   runtime_endpoints.json # 运行时端点注册表
# ```
"""
function write_lima_vm_files(
    spec::TestbedSpec,
    plan::TestbedRealizationPlan;
    network::AbstractString = "lima:user-v2",
    image_catalog::Union{Nothing,ImageCatalog} = nothing,
    project_root::AbstractString = project_root_from_work_dir(plan.work_dir),
)::TestbedMaterializationPlan
    plan.backend == :vm || throw(ArgumentError("materialization currently expects plan.backend == :vm"))
    # [执行流程]
    # 步骤1: 验证后端类型（当前仅支持 :vm）
    # 步骤2: 如果提供了镜像目录，验证所有节点引用的镜像是否存在
    image_catalog !== nothing && validate_testbed_images(spec, image_catalog)

    # 步骤3: 创建 VM 配置目录（vm/）
    vm_dir = joinpath(plan.work_dir, "vm")
    mkpath(vm_dir)

    # 步骤4: 为每个 :vm 后端节点生成 Lima YAML 配置文件
    materialized_nodes = TestbedVMNodeMaterialization[]
    for realized_node in plan.nodes
        # 当前实现仅处理 VM 后端节点，跳过其他后端（如 :namespace, :docker）
        realized_node.backend == :vm || continue
        # 查找该节点在原始 TestbedSpec 中的详细配置
        spec_node = find_spec_node(spec, realized_node.node_id)
        # 生成 Lima YAML 配置文件路径：vm/<runtime_name>.yaml
        config_path = joinpath(vm_dir, "$(realized_node.runtime_name).yaml")
        # 调用 lima_vm_yaml() 生成完整的 Lima VM YAML 配置并写入磁盘
        write(config_path, lima_vm_yaml(spec_node, realized_node; image_catalog = image_catalog, project_root = project_root))
        # 记录物化后的节点信息（包含运行时名称、主机名、配置路径等）
        push!(
            materialized_nodes,
            TestbedVMNodeMaterialization(
                realized_node.node_id,
                realized_node.runtime_name,
                realized_node.endpoint_kind,
                realized_node.endpoint_id,
                realized_node.ip,
                lima_internal_hostname(realized_node.runtime_name),
                config_path,
            ),
        )
    end

    # 步骤5: 生成启动脚本 start_vms.sh
    # - 使用 limactl start 启动每个 VM，指定名称和网络
    # - 末尾执行 limactl list 查看实例状态
    start_script_path = joinpath(vm_dir, "start_vms.sh")
    # 步骤6: 生成停止脚本 stop_vms.sh
    # - 使用 limactl stop 停止每个 VM
    # - 使用 || true 忽略停止失败（VM 可能未运行）
    stop_script_path = joinpath(vm_dir, "stop_vms.sh")
    # 步骤7: 生成运行时端点注册表 runtime_endpoints.json
    runtime_registry_path = joinpath(plan.work_dir, "runtime_endpoints.json")

    # 步骤5: 组装启动脚本
    # 脚本结构：shebang → 设置选项 → SCRIPT_DIR → 逐个启动 VM → 列出状态
    start_lines = [
        "#!/usr/bin/env sh",
        "set -eu",
        "",
        "SCRIPT_DIR=\$(CDPATH= cd -- \"\$(dirname -- \"\$0\")\" && pwd)",
        "",
    ]
    for node in materialized_nodes
        push!(
            start_lines,
            "limactl start --name=$(shell_single_quote(node.runtime_name)) --network $(shell_single_quote(network)) \"\$SCRIPT_DIR/$(node.runtime_name).yaml\"",
        )
    end
    if !isempty(materialized_nodes)
        runtime_names = [shell_single_quote(node.runtime_name) for node in materialized_nodes]
        push!(start_lines, "limactl list " * join(runtime_names, " "))
    end
    write_executable(start_script_path, join(start_lines, "\n") * "\n")

    # 步骤6: 组装停止脚本
    # 脚本结构：shebang → 设置选项 → 逐个停止 VM（|| true 忽略失败）
    stop_lines = [
        "#!/usr/bin/env sh",
        "set -eu",
        "",
    ]
    for node in materialized_nodes
        push!(stop_lines, "limactl stop $(shell_single_quote(node.runtime_name)) || true")
    end
    write_executable(stop_script_path, join(stop_lines, "\n") * "\n")

    # 步骤8: 组装 TestbedMaterializationPlan 并生成运行时端点注册表
    materialization = TestbedMaterializationPlan(
        plan.scenario_id,
        plan.backend,
        plan.work_dir,
        vm_dir,
        String(network),
        materialized_nodes,
        start_script_path,
        stop_script_path,
        runtime_registry_path,
    )
    # 步骤9: 构建运行时端点注册表并写入 JSON 文件
    # - build_runtime_endpoint_registry() 合并规格和物化信息
    # - write_runtime_endpoint_registry() 序列化为 JSON
    write_runtime_endpoint_registry(
        runtime_registry_path,
        build_runtime_endpoint_registry(spec, materialization),
    )
    return materialization
end

"""
    print_testbed_materialization_plan(io::IO, plan::TestbedMaterializationPlan) -> Nothing

以可读格式打印物化计划到指定 IO。

# 参数
- `io::IO`：输出 IO 流
- `plan::TestbedMaterializationPlan`：测试床物化计划

# 返回
- `Nothing`

# 输出格式
```
TestbedMaterializationPlan: <scenario_id>
  backend: <backend>
  vm_dir: <vm_dir>
  network: <network>
  nodes:
    <node_id> runtime=<runtime_name> OEF=<endpoint_label> configured_ip=<ip> lima_host=<hostname>
    ...
  scripts:
    start: <start_script_path>
    stop: <stop_script_path>
  runtime registry: <runtime_registry_path>
```
"""
function print_testbed_materialization_plan(io::IO, plan::TestbedMaterializationPlan)::Nothing
    println(io, "TestbedMaterializationPlan: $(plan.scenario_id)")
    println(io, "  backend: $(plan.backend)")
    println(io, "  vm_dir: $(plan.vm_dir)")
    println(io, "  network: $(plan.network)")
    println(io, "  nodes:")
    if isempty(plan.nodes)
        println(io, "    none")
    else
        for node in plan.nodes
            println(
                io,
                "    $(node.node_id) runtime=$(node.runtime_name) OEF=$(endpoint_label(node.endpoint_kind, node.endpoint_id)) configured_ip=$(node.configured_ip) lima_host=$(node.lima_hostname)",
            )
        end
    end
    println(io, "  scripts:")
    println(io, "    start: $(plan.start_script_path)")
    println(io, "    stop: $(plan.stop_script_path)")
    println(io, "  runtime registry: $(plan.runtime_registry_path)")
    return nothing
end

"""
    print_testbed_materialization_plan(plan::TestbedMaterializationPlan) -> Nothing

默认输出到 `stdout`。

# 参数
- `plan::TestbedMaterializationPlan`：测试床物化计划

# 返回
- `Nothing`
"""
print_testbed_materialization_plan(plan::TestbedMaterializationPlan)::Nothing =
    print_testbed_materialization_plan(stdout, plan)

# [算法说明]
# OEF端点到VM节点的映射算法：
# 遍历物化计划中的所有节点，查找endpoint_kind和endpoint_id都匹配的节点。
# 这种映射使得轨道事件可以准确路由到对应的VM实例。
# 时间复杂度：O(n)，n为节点数量。
"""
    find_materialized_endpoint(
        plan::TestbedMaterializationPlan,
        endpoint::OrbitalLinkEndpoint,
    ) -> TestbedVMNodeMaterialization

在物化计划中按 OEF endpoint 查找对应的 VM 节点记录。

# 参数
- `plan::TestbedMaterializationPlan`：测试床物化计划
- `endpoint::OrbitalLinkEndpoint`：OEF 轨道链接端点

# 返回
- `TestbedVMNodeMaterialization`：匹配的 VM 节点物化记录

# 异常
- `ArgumentError`：当找不到匹配的节点时抛出

# 说明
- 根据端点的类型（kind）和 ID 查找对应的 VM 节点
- 用于在运行时将 OEF 端点映射到实际的 VM 实例
"""
function find_materialized_endpoint(
    plan::TestbedMaterializationPlan,
    endpoint::OrbitalLinkEndpoint,
)::TestbedVMNodeMaterialization
    for node in plan.nodes
        node.endpoint_kind == endpoint.kind && node.endpoint_id == endpoint.id && return node
    end
    throw(ArgumentError("no materialized VM node for OEF endpoint $(endpoint.kind):$(endpoint.id)"))
end