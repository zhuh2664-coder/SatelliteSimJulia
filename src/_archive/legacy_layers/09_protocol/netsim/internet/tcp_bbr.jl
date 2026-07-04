"""
    TcpBbr — TCP BBR 构造器
使用统一 TcpSocket + CC_BBR 算法。
"""
function TcpBbr(id::UInt32; mss=1460)
    return TcpSocket(id; cc=CC_BBR, mss=mss)
end
