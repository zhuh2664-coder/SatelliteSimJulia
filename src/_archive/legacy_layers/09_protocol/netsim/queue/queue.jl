"""
    Queue 抽象基类 — 网络队列

对标 ns-3 Queue。所有队列算法继承此接口。
"""
abstract type Queue end

"""
    Enqueue(q, pkt) → Bool
将包 pkt 入队。返回 true 成功，false 丢包。
"""
function Enqueue(q::Queue, pkt) end

"""
    Dequeue(q) → pkt | nothing
从队列头部取包。队列空返回 nothing。
"""
function Dequeue(q::Queue) end

"""
    Peek(q) → pkt | nothing
查看队列头部包（不移除）。
"""
function Peek(q::Queue) end

"""
    Drop(q, pkt)
丢包回调。子类可重写以统计丢包。
"""
function Drop(q::Queue, pkt)
    nothing
end

"""
    BytesInQueue(q) → Int
当前队列字节数。
"""
function BytesInQueue(q::Queue) end

"""
    PacketsInQueue(q) → Int
当前队列包数。
"""
function PacketsInQueue(q::Queue) end

"""
    SetCapacity(q, bytes)
设置队列容量（字节）
"""
function SetCapacity(q::Queue, bytes::Int) end
