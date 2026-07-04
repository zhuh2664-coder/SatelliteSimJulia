# ===== 力模型抽象层（GMAT forcemodel 核心）=====
#
# GMAT 的力模型是可组合的：ForceModel = [GravityField, ThirdBody, Drag, SRP]
# 每个力模型实现 acceleration(r, v, t, sc) -> SVector{3}（m/s²，SI 单位）
# 总加速度 = Σ 各力模型加速度
#
# 多重分派：新增力模型 = 新子类型 + 新 acceleration 方法。

export AbstractForceModel, ForceModel, acceleration, combine_forces

"""力模型抽象类型。每个子类型代表一种摄动力。"""
abstract type AbstractForceModel end

"""
    ForceModel

可组合的力模型集合（GMAT 的 ODEModel 等价物）。
总加速度 = 所有子力模型加速度之和。
"""
struct ForceModel
    forces::Vector{AbstractForceModel}
end

# 便捷构造：ForceModel(f1, f2, ...) = ForceModel([f1, f2, ...])
ForceModel(forces::AbstractForceModel...) = ForceModel(collect(AbstractForceModel, forces))

"""组合多个力模型。"""
combine_forces(forces::AbstractForceModel...) = ForceModel(collect(AbstractForceModel, forces))

"""
    acceleration(fm::ForceModel, r, v, t, sc) -> SVector{3}

计算力模型集合的总加速度（累加所有子力）。

# 参数
- `r`: 位置 SVector{3}（m，ECI）
- `v`: 速度 SVector{3}（m/s，ECI）
- `t`: 时间（s，从历元起）
- `sc`: 航天器（Spacecraft，含质量/面积/系数）
"""
function acceleration(fm::ForceModel, r, v, t, sc)
    total = zero(SVector{3,Float64})
    for f in fm.forces
        total = total + acceleration(f, r, v, t, sc)
    end
    return total
end
