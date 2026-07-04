"""
    TcpReno — TCP Reno 构造器
使用统一 TcpSocket + CC_RENO 算法。
"""
function TcpReno(id::UInt32; mss=1460)
    return TcpSocket(id; cc=CC_RENO, mss=mss)
end
