"""
    NetDevice — 网卡抽象基类

对标 ns-3 NetDevice。
每个 Node 可以有多个 NetDevice，每个 NetDevice 连到一个 Channel。
"""
abstract type NetDevice end

"""
    GetNode(dev) → Node
返回此网卡所属的节点
"""
function GetNode end

"""
    GetChannel(dev) → Channel
返回此网卡连接的信道
"""
function GetChannel end

"""
    Send(dev, pkt, dst) → Bool
发送包（入队 + 调度传输）
"""
function Send end

"""
    Receive(dev, pkt, rx_device)
接收包（由信道触发）
"""
function Receive end

"""
    SetQueue(dev, queue)
设置队列
"""
function SetQueue end

"""
    GetQueue(dev) → Queue
获取队列
"""
function GetQueue end

"""
    SetRecvCallback(dev, cb)
设置接收回调（协议栈层使用）
"""
function SetRecvCallback end

"""
    IsLinkUp(dev) → Bool
链路状态
"""
function IsLinkUp end
