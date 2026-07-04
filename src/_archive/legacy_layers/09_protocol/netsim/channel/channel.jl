"""
    Channel — 信道抽象基类

对标 ns-3 Channel。物理传输介质。
"""
abstract type Channel end

"""
    GetDelay(ch) → Time
返回传播延迟
"""
function GetDelay end

"""
    GetDevice(ch, i) → NetDevice
返回第 i 个端设备
"""
function GetDevice end

"""
    GetNDevices(ch) → Int
返回连接设备数
"""
function GetNDevices end

"""
    Transmit(ch, pkt, sender, delay)
在信道上传输包：sender 发出，delay 后到达另一端。
子类实现具体传输逻辑。
"""
function Transmit end
