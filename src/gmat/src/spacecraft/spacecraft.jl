# ===== 航天器模型（GMAT Spacecraft）=====
#
# GMAT 的 Spacecraft 含质量/面积/系数等，被力模型（阻力/光压）和积分器使用。
# 本包的 Spacecraft 是精简版（GMAT 的含推进/姿态/热控等，这里只留动力学必需）。

export Spacecraft, mass

"""
    Spacecraft

航天器动力学模型（精简版 GMAT Spacecraft）。

# 字段
- `mass_dry::Float64`: 干质量（kg，不含推进剂）
- `mass_fuel::Float64`: 推进剂质量（kg）
- `area_drag_m2::Float64`: 迎风面积（m²，阻力计算用）
- `area_srp_m2::Float64`: 迎光面积（m²，光压计算用）
- `cd::Float64`: 阻力系数（典型 2.2）
- `cr::Float64`: 光压系数（典型 1.3）
"""
Base.@kwdef struct Spacecraft
    mass_dry::Float64 = 100.0       # 干质量 kg
    mass_fuel::Float64 = 0.0        # 推进剂 kg
    area_drag_m2::Float64 = 2.0     # 阻力面积 m²
    area_srp_m2::Float64 = 2.0      # 光压面积 m²
    cd::Float64 = 2.2               # 阻力系数
    cr::Float64 = 1.3               # 光压系数
end

"""航天器总质量（干重 + 推进剂）。力模型用此计算面质比。"""
mass(sc::Spacecraft) = sc.mass_dry + sc.mass_fuel

# hasproperty 支持（让 drag/srp 用 hasproperty(sc, :mass) 检查）
# Spacecraft 是 struct，自动有 property，但 mass 是函数不是字段，需特殊处理：
# drag.jl/srp.jl 用 hasproperty(sc, :mass) → Spacecraft 无 mass 字段，会 false。
# 改为：直接调 mass(sc) 函数。修正 drag/srp 的判断。
