"""
    TcpCubic — TCP Cubic 构造器
使用统一 TcpSocket + CC_CUBIC 算法。
"""
function TcpCubic(id::UInt32; mss=1460)
    return TcpSocket(id; cc=CC_CUBIC, mss=mss)
end
