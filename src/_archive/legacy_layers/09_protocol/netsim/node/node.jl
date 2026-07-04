"""
    Node — 节点抽象

对标 ns-3 Node。每颗卫星/地面站是一个 Node。
- 持有 Application 列表
- 持有 NetDevice 列表
- 持有协议处理器 (IPv4, Arp, etc.)
- 全局唯一 ID
"""
mutable struct Node
    id::UInt32
    devices::Vector{Any}
    applications::Vector{Any}
    protocol_handlers::Dict{Symbol, Any}
end

# 全局节点计数器
const _node_counter = Ref{UInt32}(0)

"""
    NodeContainer — 节点工厂

对标 ns-3 NodeContainer。
"""
mutable struct NodeContainer
    nodes::Vector{Node}
end

function NodeContainer()
    NodeContainer(Vector{Node}())
end

"""
    Create(nc, n)
创建 n 个新节点，加入容器。
"""
function Create(nc::NodeContainer, n::Int)
    for i in 1:n
        _node_counter[] += 1
        node = Node(
            _node_counter[],
            Any[],
            Any[],
            Dict{Symbol, Any}()
        )
        push!(nc.nodes, node)
    end
    nothing
end

"""
    Get(nc, i)
获取第 i 个节点 (1-indexed)
"""
function Get(nc::NodeContainer, i::Int)
    return nc.nodes[i]
end

"""
    GetId(node)
返回节点 ID
"""
GetId(node::Node) = node.id

"""
    AddDevice(node, device)
给节点安装网卡。
"""
function AddDevice(node::Node, device)
    push!(node.devices, device)
    nothing
end

"""
    AddApplication(node, app)
给节点安装应用。
"""
function AddApplication(node::Node, app)
    push!(node.applications, app)
    nothing
end

"""
    SetProtocolHandler(node, key, handler)
注册协议处理器 (例如 :ipv4, :arp)
"""
function SetProtocolHandler(node::Node, key::Symbol, handler)
    node.protocol_handlers[key] = handler
    nothing
end

"""
    GetProtocolHandler(node, key)
获取协议处理器
"""
function GetProtocolHandler(node::Node, key::Symbol)
    get(node.protocol_handlers, key, nothing)
end

# 打印
function Base.show(io::IO, node::Node)
    print(io, "Node($(node.id), devices=$(length(node.devices)), apps=$(length(node.applications)))")
end
