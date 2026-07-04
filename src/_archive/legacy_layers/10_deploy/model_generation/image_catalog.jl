#= =============================================================================
    镜像目录模块 (Image Catalog)

    文件位置: src/deploy/model_generation/image_catalog.jl

    功能说明:
        本文件定义了测试床部署所需的镜像目录系统，用于管理和描述
        各种可部署的节点镜像。镜像目录从 TOML 配置文件加载，包含
        每个镜像的元数据（如类型、后端、资源需求、启动命令等）。

        镜像目录与测试床规格 (TestbedSpec) 配合使用：测试床规格中的
        节点可以引用镜像目录中的镜像，节点的实际资源配置（CPU、内存、
        VM 镜像等）可以通过镜像目录中的默认值来补充。

    数据流说明：
    - 输入：TOML 镜像目录配置文件（磁盘文件）
      → load_image_catalog(path) 读取并解析 TOML 文件
      → TOML.parsefile(path) 将文件内容解析为 Dict
      → 提取 catalog 元数据表和 images 数组
      → 逐个构造 ImageCatalogEntry 并验证字段合法性
      → validate_image_catalog() 验证目录非空、ID 唯一
    - 输出：ImageCatalog 对象（包含元数据和镜像条目列表）
      → 传递给 testbed_materialization.jl 的 write_lima_vm_files() 作为可选参数
      → 传递给 effective_*() 系列函数解析节点资源配置
    - 辅助数据流：
      → find_image() / has_image()：按 ID 查找镜像条目
      → node_image()：获取节点对应的镜像条目
      → effective_cpu_cores() / effective_memory_mb() / effective_vm_image() / effective_ssh_user()：
        根据优先级链解析节点的有效资源配置
      → validate_testbed_images()：验证 TestbedSpec 中所有节点引用的镜像是否存在于目录中
      → print_image_catalog()：将目录摘要输出到 IO 流

    [算法说明]
    镜像目录的核心算法是"优先级链"机制，用于解析节点的有效资源配置：

    **优先级链算法（从高到低）：**
    1. 节点自身配置（TestbedNode字段）
       - 如果节点明确指定了cpu_cores、memory_mb、vm_image、ssh_user等
       - 直接使用节点配置，忽略镜像目录的值
    2. 镜像目录默认值（ImageCatalogEntry字段）
       - 如果节点引用了镜像（node.image非空）
       - 使用镜像目录中对应条目的配置
    3. 全局默认值
       - cpu_cores默认为1
       - memory_mb默认为512
       - vm_image默认为"template:ubuntu-lts"
       - ssh_user默认为空字符串

    **资源解析函数：**
    - effective_cpu_cores()：解析CPU核心数
    - effective_memory_mb()：解析内存大小
    - effective_vm_image()：解析VM镜像标识
    - effective_ssh_user()：解析SSH用户名

    **设计优势：**
    - 减少配置冗余：常见配置可在镜像目录中统一定义
    - 支持个性化覆盖：特殊节点可在TestbedSpec中覆盖默认值
    - 灵活的镜像引用：节点通过image字段引用镜像目录中的条目

    依赖关系:
        - testbed_model.jl: 提供 TESTBED_BACKENDS 常量、TestbedSpec/
          TestbedNode 结构体，以及 TOML 解析辅助函数 (required_table、
          string_value、symbol_value、required_array 等)
        - testbed_realization.jl: 提供 ensure_unique 函数用于验证唯一性

    主要类型:
        - ImageCatalogEntry: 单个镜像条目
        - ImageCatalog: 镜像目录（包含多个条目）

    主要功能:
        - 从 TOML 文件加载镜像目录
        - 验证镜像目录的完整性和一致性
        - 在目录中查找镜像
        - 计算节点的有效资源配置（支持节点级覆盖和镜像级默认值）
============================================================================= =#

# 支持的镜像类型常量：地面站、REI、SOC、攻击者、通道管理器、通用
const IMAGE_CATALOG_KINDS = (:ground, :rei, :soc, :attacker, :channel_manager, :generic)

"""
    ImageCatalogEntry

镜像目录条目结构体，描述单个可部署镜像的完整配置信息。

# 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `String` | 镜像唯一标识符，用于在目录中引用该镜像 |
| `name` | `String` | 镜像的显示名称，人类可读 |
| `kind` | `Symbol` | 镜像类型，必须是 `:ground`、`:rei`、`:soc`、`:attacker`、`:channel_manager` 或 `:generic` 之一 |
| `backend` | `Symbol` | 部署后端类型，必须是 `TESTBED_BACKENDS` 中定义的值之一 |
| `base` | `String` | 基础镜像标识，作为回退使用的默认镜像 |
| `description` | `String` | 镜像的文字描述说明（可选，默认为空） |
| `container_image` | `String` | 容器镜像名称/地址（用于容器化部署，可选） |
| `vm_image` | `String` | 虚拟机镜像名称/模板（用于 VM 部署，可选） |
| `ssh_user` | `String` | SSH 登录用户名（可选） |
| `cpu_cores` | `Int` | 默认 CPU 核心数（必须为正整数，默认 1） |
| `memory_mb` | `Int` | 默认内存大小（单位 MB，必须为正整数，默认 512） |
| `startup_command` | `String` | 节点启动时执行的命令（可选） |
| `provision_script` | `String` | 节点初始化/配置脚本（可选） |
| `tags` | `Vector{String}` | 标签列表，用于分类和筛选镜像（可选） |

# 构造函数验证

构造函数会对以下字段进行验证，验证失败时抛出 `ArgumentError`：
- `cpu_cores` 和 `memory_mb` 必须为正整数
- `id`、`name`、`base` 必须为非空字符串（通过 `require_nonempty` 验证）
- `kind` 必须在 `IMAGE_CATALOG_KINDS` 允许范围内（通过 `require_allowed` 验证）
- `backend` 必须在 `TESTBED_BACKENDS` 允许范围内（通过 `require_allowed` 验证）
"""
struct ImageCatalogEntry
    id::String
    name::String
    kind::Symbol
    backend::Symbol
    base::String
    description::String
    container_image::String
    vm_image::String
    ssh_user::String
    cpu_cores::Int
    memory_mb::Int
    startup_command::String
    provision_script::String
    tags::Vector{String}

    function ImageCatalogEntry(;
        id::AbstractString,
        name::AbstractString,
        kind::Symbol,
        backend::Symbol,
        base::AbstractString,
        description::AbstractString = "",
        container_image::AbstractString = "",
        vm_image::AbstractString = "",
        ssh_user::AbstractString = "",
        cpu_cores::Int = 1,
        memory_mb::Int = 512,
        startup_command::AbstractString = "",
        provision_script::AbstractString = "",
        tags::Vector{String} = String[],
    )
        # 验证 CPU 核心数和内存大小必须为正数
        cpu_cores > 0 || throw(ArgumentError("image cpu_cores must be positive"))
        memory_mb > 0 || throw(ArgumentError("image memory_mb must be positive"))
        return new(
            require_nonempty(id, "image id"),
            require_nonempty(name, "image name"),
            require_allowed(kind, IMAGE_CATALOG_KINDS, "image kind"),
            require_allowed(backend, TESTBED_BACKENDS, "image backend"),
            require_nonempty(base, "image base"),
            String(description),
            String(strip(container_image)),
            String(strip(vm_image)),
            String(strip(ssh_user)),
            cpu_cores,
            memory_mb,
            String(startup_command),
            String(provision_script),
            tags,
        )
    end
end

"""
    ImageCatalog

镜像目录结构体，包含一组镜像条目的集合。

# 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `String` | 目录唯一标识符 |
| `name` | `String` | 目录的显示名称 |
| `description` | `String` | 目录的文字描述说明 |
| `images` | `Vector{ImageCatalogEntry}` | 目录中包含的镜像条目列表 |
"""
struct ImageCatalog
    id::String
    name::String
    description::String
    images::Vector{ImageCatalogEntry}
end

"""
    load_image_catalog(path::AbstractString)::ImageCatalog

从指定的 TOML 配置文件加载镜像目录。

# 参数

- `path::AbstractString`: TOML 配置文件的路径

# 返回值

- `ImageCatalog`: 加载并验证后的镜像目录对象

# 配置文件格式

TOML 文件应包含以下结构：
```toml
[catalog]
id = "my-catalog"
name = "My Image Catalog"
description = "..."

[[images]]
id = "ubuntu-node"
name = "Ubuntu Node"
kind = "generic"
backend = "docker"
base = "ubuntu:22.04"
cpu_cores = 2
memory_mb = 1024
# ... 其他可选字段
```

# 异常

- 若文件解析失败或缺少必需字段，抛出 `ArgumentError`
- 若目录验证失败（如镜像 ID 重复），抛出 `ArgumentError`
"""
function load_image_catalog(path::AbstractString)::ImageCatalog
    # [执行流程]
    # 步骤1: 解析 TOML 文件为嵌套字典
    raw = TOML.parsefile(path)
    # 步骤2: 提取目录元数据表（id, name, description）
    catalog = required_table(raw, "catalog")
    # 步骤3: 遍历 images 数组，逐个构造 ImageCatalogEntry
    # - 必需字段通过 string_value/symbol_value/int_value 校验
    # - 可选字段使用 get() 提供默认值
    images = [
        ImageCatalogEntry(
            id = string_value(image, "id"),
            name = string_value(image, "name"),
            kind = symbol_value(image, "kind"),
            backend = symbol_value(image, "backend"),
            base = string_value(image, "base"),
            description = String(get(image, "description", "")),
            container_image = String(get(image, "container_image", "")),
            vm_image = String(get(image, "vm_image", "")),
            ssh_user = String(get(image, "ssh_user", "")),
            cpu_cores = Int(get(image, "cpu_cores", 1)),
            memory_mb = Int(get(image, "memory_mb", 512)),
            startup_command = String(get(image, "startup_command", "")),
            provision_script = String(get(image, "provision_script", "")),
            tags = [String(tag) for tag in Vector(get(image, "tags", String[]))],
        )
        for image in required_array(raw, "images")
    ]
    # 步骤4: 构建 ImageCatalog 对象（包含元数据和镜像条目列表）
    catalog_obj = ImageCatalog(
        require_nonempty(string_value(catalog, "id"), "catalog id"),
        require_nonempty(string_value(catalog, "name"), "catalog name"),
        String(get(catalog, "description", "")),
        images,
    )
    # 步骤5: 对目录进行一致性验证（非空、ID 唯一）
    validate_image_catalog(catalog_obj)
    return catalog_obj
end

"""
    validate_image_catalog(catalog::ImageCatalog)::Nothing

验证镜像目录的完整性和一致性。

当前执行的验证规则：
1. 目录中必须至少包含一个镜像条目
2. 所有镜像的 ID 必须唯一（不重复）

# 参数

- `catalog::ImageCatalog`: 待验证的镜像目录

# 返回值

- `nothing`

# 异常

- 若目录为空，抛出 `ArgumentError`
- 若存在重复的镜像 ID，抛出 `ArgumentError`
"""
function validate_image_catalog(catalog::ImageCatalog)::Nothing
    # 验证目录非空：至少包含一个镜像
    !isempty(catalog.images) || throw(ArgumentError("image catalog must contain at least one image"))
    # 提取所有镜像 ID，验证唯一性
    ids = [image.id for image in catalog.images]
    ensure_unique(ids, "image ids")
    return nothing
end

"""
    find_image(catalog::ImageCatalog, image_id::AbstractString)::ImageCatalogEntry

在镜像目录中按 ID 查找指定的镜像条目。

# 参数

- `catalog::ImageCatalog`: 镜像目录对象
- `image_id::AbstractString`: 要查找的镜像 ID

# 返回值

- `ImageCatalogEntry`: 找到的镜像条目

# 异常

- 若找不到指定 ID 的镜像，抛出 `ArgumentError`
"""
function find_image(catalog::ImageCatalog, image_id::AbstractString)::ImageCatalogEntry
    wanted = String(image_id)
    # 线性搜索目录中的镜像列表
    for image in catalog.images
        image.id == wanted && return image
    end
    throw(ArgumentError("image \$wanted not found in image catalog \$(catalog.id)"))
end

"""
    has_image(catalog::ImageCatalog, image_id::AbstractString)::Bool

检查镜像目录中是否包含指定 ID 的镜像。

# 参数

- `catalog::ImageCatalog`: 镜像目录对象
- `image_id::AbstractString`: 要检查的镜像 ID

# 返回值

- `true`: 目录中存在该镜像
- `false`: 目录中不存在该镜像
"""
function has_image(catalog::ImageCatalog, image_id::AbstractString)::Bool
    wanted = String(image_id)
    return any(image -> image.id == wanted, catalog.images)
end

"""
    validate_testbed_images(spec::TestbedSpec, catalog::ImageCatalog)::Nothing

验证测试床规格中所有节点引用的镜像是否都在镜像目录中存在。

# 参数

- `spec::TestbedSpec`: 测试床规格对象
- `catalog::ImageCatalog`: 镜像目录对象

# 返回值

- `nothing`

# 异常

- 若有节点引用了目录中不存在的镜像，抛出 `ArgumentError`

# 说明

- 若节点的 `image` 字段为空字符串，则跳过该节点的验证
  （表示该节点不引用镜像目录中的镜像）
"""
function validate_testbed_images(spec::TestbedSpec, catalog::ImageCatalog)::Nothing
    for node in spec.nodes
        # 跳过未指定镜像的节点
        isempty(node.image) && continue
        has_image(catalog, node.image) ||
            throw(ArgumentError("node \$(node.id) references image \$(node.image), which is not in image catalog \$(catalog.id)"))
    end
    return nothing
end

"""
    node_image(catalog::ImageCatalog, node::TestbedNode)::Union{Nothing,ImageCatalogEntry}

获取测试床节点对应的镜像目录条目。

# 参数

- `catalog::ImageCatalog`: 镜像目录对象
- `node::TestbedNode`: 测试床节点对象

# 返回值

- `ImageCatalogEntry`: 节点引用的镜像条目（若节点指定了镜像且存在于目录中）
- `nothing`: 节点未指定镜像，或指定的镜像不存在
"""
function node_image(catalog::ImageCatalog, node::TestbedNode)::Union{Nothing,ImageCatalogEntry}
    isempty(node.image) && return nothing
    return find_image(catalog, node.image)
end

# [算法说明]
# CPU核心数解析算法：实现优先级链机制。
# 解析顺序（从高到低）：
# 1. 节点自身配置：node.cpu_cores > 0时直接使用
# 2. 镜像目录默认值：从node.image引用的ImageCatalogEntry获取
# 3. 全局默认值：1
# 这种设计允许用户在不同层级设置资源需求，特殊节点可以覆盖默认值。
"""
    effective_cpu_cores(node::TestbedNode, catalog::Union{Nothing,ImageCatalog}=nothing)::Int

计算测试床节点的有效 CPU 核心数。

解析优先级（从高到低）：
1. 节点自身配置的 `cpu_cores`（若大于 0，直接返回）
2. 节点引用的镜像目录条目中的 `cpu_cores`（若目录不为空且镜像存在）
3. 默认值 `1`

# 参数

- `node::TestbedNode`: 测试床节点对象
- `catalog::Union{Nothing,ImageCatalog}`: 可选的镜像目录对象（默认为 `nothing`）

# 返回值

- `Int`: 节点的有效 CPU 核心数
"""
function effective_cpu_cores(node::TestbedNode, catalog::Union{Nothing,ImageCatalog} = nothing)::Int
    # 优先级1: 节点自身配置
    node.cpu_cores > 0 && return node.cpu_cores
    # 优先级2: 镜像目录默认值
    if catalog !== nothing
        image = node_image(catalog, node)
        image !== nothing && return image.cpu_cores
    end
    # 优先级3: 全局默认值
    return 1
end

"""
    effective_memory_mb(node::TestbedNode, catalog::Union{Nothing,ImageCatalog}=nothing)::Int

计算测试床节点的有效内存大小（单位：MB）。

解析优先级（从高到低）：
1. 节点自身配置的 `memory_mb`（若大于 0，直接返回）
2. 节点引用的镜像目录条目中的 `memory_mb`（若目录不为空且镜像存在）
3. 默认值 `512`

# 参数

- `node::TestbedNode`: 测试床节点对象
- `catalog::Union{Nothing,ImageCatalog}`: 可选的镜像目录对象（默认为 `nothing`）

# 返回值

- `Int`: 节点的有效内存大小（MB）
"""
function effective_memory_mb(node::TestbedNode, catalog::Union{Nothing,ImageCatalog} = nothing)::Int
    # 优先级1: 节点自身配置
    node.memory_mb > 0 && return node.memory_mb
    # 优先级2: 镜像目录默认值
    if catalog !== nothing
        image = node_image(catalog, node)
        image !== nothing && return image.memory_mb
    end
    # 优先级3: 全局默认值
    return 512
end

# [算法说明]
# VM镜像解析算法：实现4级优先级链。
# 解析顺序（从高到低）：
# 1. 节点自身配置：node.vm_image非空时直接使用
# 2. 镜像目录的vm_image字段：从ImageCatalogEntry获取
# 3. 镜像目录的base字段：当vm_image为空时回退到base
# 4. 全局默认值："template:ubuntu-lts"
# base字段是镜像的基础标识，vm_image是专门的VM镜像标识。
"""
    effective_vm_image(node::TestbedNode, catalog::Union{Nothing,ImageCatalog}=nothing)::String

计算测试床节点的有效 VM 镜像标识。

解析优先级（从高到低）：
1. 节点自身配置的 `vm_image`（若非空，直接返回）
2. 节点引用的镜像目录条目中的 `vm_image`（若非空）
3. 节点引用的镜像目录条目中的 `base` 字段
4. 默认值 `"template:ubuntu-lts"`

# 参数

- `node::TestbedNode`: 测试床节点对象
- `catalog::Union{Nothing,ImageCatalog}`: 可选的镜像目录对象（默认为 `nothing`）

# 返回值

- `String`: 节点的有效 VM 镜像标识
"""
function effective_vm_image(node::TestbedNode, catalog::Union{Nothing,ImageCatalog} = nothing)::String
    # 优先级1: 节点自身配置的 VM 镜像
    !isempty(node.vm_image) && return node.vm_image
    # 优先级2/3: 从镜像目录获取
    if catalog !== nothing
        image = node_image(catalog, node)
        if image !== nothing
            # 优先使用镜像的 vm_image，否则回退到 base
            !isempty(image.vm_image) && return image.vm_image
            return image.base
        end
    end
    # 优先级4: 全局默认模板
    return "template:ubuntu-lts"
end

"""
    effective_ssh_user(node::TestbedNode, catalog::Union{Nothing,ImageCatalog}=nothing)::String

计算测试床节点的有效 SSH 用户名。

解析优先级（从高到低）：
1. 节点自身配置的 `ssh_user`（若非空，直接返回）
2. 节点引用的镜像目录条目中的 `ssh_user`（若非空）
3. 默认值 `""`（空字符串，表示未指定）

# 参数

- `node::TestbedNode`: 测试床节点对象
- `catalog::Union{Nothing,ImageCatalog}`: 可选的镜像目录对象（默认为 `nothing`）

# 返回值

- `String`: 节点的有效 SSH 用户名（可能为空字符串）
"""
function effective_ssh_user(node::TestbedNode, catalog::Union{Nothing,ImageCatalog} = nothing)::String
    # 优先级1: 节点自身配置的 SSH 用户
    !isempty(node.ssh_user) && return node.ssh_user
    # 优先级2: 从镜像目录获取
    if catalog !== nothing
        image = node_image(catalog, node)
        image !== nothing && !isempty(image.ssh_user) && return image.ssh_user
    end
    # 优先级3: 空字符串默认值
    return ""
end

"""
    print_image_catalog(io::IO, catalog::ImageCatalog)::Nothing

将镜像目录的摘要信息输出到指定的 IO 流。

输出格式包括目录 ID、名称，以及每个镜像条目的关键信息
（ID、类型、后端、基础镜像、CPU、内存）。

# 参数

- `io::IO`: 输出目标 IO 流（如 `stdout`、文件句柄等）
- `catalog::ImageCatalog`: 要输出的镜像目录对象

# 返回值

- `nothing`
"""
function print_image_catalog(io::IO, catalog::ImageCatalog)::Nothing
    println(io, "ImageCatalog: $(catalog.id)")
    println(io, "  name: $(catalog.name)")
    println(io, "  images:")
    for image in catalog.images
        println(
            io,
            "    $(image.id) kind=$(image.kind) backend=$(image.backend) base=$(image.base) cpu=$(image.cpu_cores) memory_mb=$(image.memory_mb)",
        )
    end
    return nothing
end

"""
    print_image_catalog(catalog::ImageCatalog)::Nothing

将镜像目录的摘要信息输出到标准输出（`stdout`）。

这是 `print_image_catalog(io::IO, catalog::ImageCatalog)` 的便捷包装，
默认输出到 `stdout`。

# 参数

- `catalog::ImageCatalog`: 要输出的镜像目录对象

# 返回值

- `nothing`
"""
print_image_catalog(catalog::ImageCatalog)::Nothing = print_image_catalog(stdout, catalog)
