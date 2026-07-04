"""
    Time — 仿真时间类型

ns-3 对齐：
- 内部用 Float64 秒存储
- Second/Milli/Micro/Nano 构造器
- 支持算术运算和比较
"""
struct Time
    val::Float64
end

# 构造器
Second(t::Real) = Time(Float64(t))
Milli(t::Real)  = Time(Float64(t) / 1e3)
Micro(t::Real)  = Time(Float64(t) / 1e6)
Nano(t::Real)   = Time(Float64(t) / 1e9)

# 单位转换
seconds(t::Time) = t.val
milliseconds(t::Time) = t.val * 1e3
microseconds(t::Time) = t.val * 1e6
nanoseconds(t::Time)  = t.val * 1e9

# 算术
Base.:+(a::Time, b::Time) = Time(a.val + b.val)
Base.:-(a::Time, b::Time) = Time(a.val - b.val)
Base.:*(a::Time, b::Number) = Time(a.val * b)
Base.:*(a::Number, b::Time) = Time(a * b.val)
Base.:/(a::Time, b::Time) = a.val / b.val
Base.:/(a::Time, b::Number) = Time(a.val / b)

# 比较
Base.isless(a::Time, b::Time) = a.val < b.val
Base.:(==)(a::Time, b::Time) = a.val == b.val

# 零值
const ZERO = Time(0.0)
const INF  = Time(Inf)

# 打印
Base.show(io::IO, t::Time) = print(io, round(t.val, digits=9), "s")
Base.print(io::IO, t::Time) = print(io, round(t.val, digits=9), "s")
