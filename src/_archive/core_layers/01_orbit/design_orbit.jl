"""
    网络层 / 星座构建子模块

负责把设计型星座规格（DesignConstellationSpec）转化为轨道六根数。
本文件定义了默认的轨道生成规则，包括 RAAN 展开范围、轨道面 RAAN、卫星平均近点角以及卫星命名规则，
并提供将规则注册为系统变量的入口。上游由 builders.jl 中的 DesignConstellationBuilder 调用，
输出为 Constellation 中的 Satellite 与 OrbitPlane 静态身份与轨道参数。

# 算法说明

## Walker 星座轨道参数生成

### RAAN（升交点赤经）分布
Walker 星座的轨道面在赤道面上均匀分布。

- 极地轨道（倾角 ≈ 90°）：RAAN 展开范围为 180°
  原因：极地轨道的升交点和降交点关于地轴对称，
  180° 的 RAAN 展开即可覆盖全球。若使用 360° 会导致轨道面在极点附近过度密集。

- 非极地轨道：RAAN 展开范围为 360°
  原因：非极地轨道需要完整覆盖所有经度方向。

- RAAN 计算公式：
  RAAN_i = (i - 1) × RAAN_span / N_planes
  其中 i 为轨道面序号（从 1 开始），N_planes 为轨道面总数。

### 平均近点角（Mean Anomaly）计算
Walker 星座使用相位偏移（phase_shift）实现相邻轨道面的卫星错位。

- 基础位置：M_i = (i - 1) × 360° / N_satellites
  其中 i 为卫星在轨道面内的槽位序号。

- 相位偏移：ΔM = (plane_index - 1) × phase_shift × 360° / (N_planes × N_satellites)
  相位偏移确保相邻轨道面的卫星不会同时处于相同纬度，
  提高网络覆盖均匀性和链路稳定性。

- 最终平均近点角：
  M = mod(M_i + ΔM, 360°)

### 相位偏移（phase_shift）的作用
phase_shift 参数控制相邻轨道面之间的相位关系：
- phase_shift = 0：所有轨道面的同槽位卫星对齐（无相位偏移）
- phase_shift = 1：相邻轨道面错开一个槽位（最常见配置）
- phase_shift = F（Walker 星座标准符号 T/P/F 中的 F）

这种相位交错确保了：
1. 网络拓扑的均匀性：避免所有卫星同时经过极点区域
2. 覆盖的连续性：相邻轨道面的卫星交替覆盖同一区域
3. 链路的稳定性：减少因卫星同时进入极区导致的链路中断
"""

"""
    DesignOrbitGenerationRules

设计型星座轨道参数生成规则集合。

# 字段
- `raan_span_fn::Function`: 根据轨道倾角（度）决定升交点赤经（RAAN）总展开范围。
- `raan_deg_fn::Function`: 根据轨道面序号、轨道面总数和 RAAN 展开范围计算该面 RAAN。
- `mean_anomaly_deg_fn::Function`: 根据卫星槽位、轨道面序号与相位偏移计算平均近点角。
- `satellite_name_fn::Function`: 生成卫星可读名称的规则。

# 依赖
默认实现使用本文件中的 `default_raan_span_deg`、`default_raan_deg`、`default_mean_anomaly_deg`、
`default_satellite_name`；构造后由 `build_design_constellation` 消费。
"""
struct DesignOrbitGenerationRules
    raan_span_fn::Function
    raan_deg_fn::Function
    mean_anomaly_deg_fn::Function
    satellite_name_fn::Function
end

"""
    default_raan_span_deg(inclination_deg::Real)::Float64

根据轨道倾角返回默认 RAAN 展开范围。

# 参数
- `inclination_deg`: 轨道倾角（度）。

# 返回值
- 当倾角接近 90°（极地/ Walker 星座常见）时返回 180°，否则返回 360°。
  这样可在相邻轨道面之间实现均匀 Walker 式分布。
"""
# [算法说明]
# RAAN 展开范围决策
# 根据轨道倾角决定 RAAN 的总展开范围。
#
# 极地轨道（80° < 倾角 < 100°）使用 180° 展开：
#   极地轨道的升交点和降交点关于地轴对称。
#   当倾角 ≈ 90° 时，轨道平面几乎通过两极。
#   180° 的 RAAN 展开即可使相邻轨道面在赤道上均匀分布，
#   同时在极点附近保持合理间距。
#   若使用 360°，会导致轨道面在极点附近过度密集（收敛到同一点）。
#
# 非极地轨道使用 360° 展开：
#   非极地轨道的升交点不会在极点收敛，
#   需要完整的 360° 展开来覆盖所有经度方向。
function default_raan_span_deg(inclination_deg::Real)::Float64
    return 80 < Float64(inclination_deg) < 100 ? 180.0 : 360.0
end

"""
    default_raan_deg(orbit_index::Int, orbit_count::Int, raan_span_deg::Real)::Float64

计算单个轨道面的 RAAN（升交点赤经）。

# 参数
- `orbit_index`: 轨道面序号，从 1 开始。
- `orbit_count`: 该壳层轨道面总数。
- `raan_span_deg`: RAAN 总展开范围（度）。

# 返回值
- 将 `raan_span_deg` 均分到各轨道面后得到的该面 RAAN（度）。
"""
# [算法说明]
# 轨道面 RAAN 计算
# 将 RAAN 展开范围均匀分配到各轨道面。
#
# 数学公式：
#   RAAN_i = (i - 1) × RAAN_span / N_planes
#
# 例如：4 个轨道面，RAAN 展开 180°
#   RAAN_1 = 0°
#   RAAN_2 = 45°
#   RAAN_3 = 90°
#   RAAN_4 = 135°
#
# 这种均匀分布确保相邻轨道面之间的夹角相等，
# 使网络拓扑和覆盖尽可能均匀。
function default_raan_deg(orbit_index::Int, orbit_count::Int, raan_span_deg::Real)::Float64
    orbit_index > 0 || throw(ArgumentError("orbit_index must be positive"))
    orbit_count > 0 || throw(ArgumentError("orbit_count must be positive"))
    return (orbit_index - 1) * Float64(raan_span_deg) / orbit_count
end

"""
    default_mean_anomaly_deg(
        satellite_index::Int,
        satellites_per_orbit::Int,
        orbit_index::Int,
        orbit_count::Int,
        phase_shift::Int,
    )::Float64

计算设计星座中某颗卫星的默认平均近点角。

# 参数
- `satellite_index`: 卫星在轨道面内的槽位序号，从 1 开始。
- `satellites_per_orbit`: 每轨道面卫星数。
- `orbit_index`: 轨道面序号，从 1 开始。
- `orbit_count`: 轨道面总数。
- `phase_shift`: 相邻轨道面之间的槽位相位偏移（槽位数），用于实现 Walker 星座的相位交错。

# 返回值
- 该卫星的平均近点角（度），已归一化到 [0, 360)。
"""
# [算法说明]
# Walker 星座平均近点角计算
# 实现 Walker 星座的相位交错（Phasing）。
#
# 数学公式：
#   M = mod(M_base + ΔM, 360°)
#
# 其中：
#   M_base = (satellite_index - 1) × 360° / satellites_per_orbit
#     同一轨道面内卫星的均匀分布角度
#
#   ΔM = (orbit_index - 1) × phase_shift × 360° / (orbit_count × satellites_per_orbit)
#     相邻轨道面之间的相位偏移量
#
# 例如：Walker 24/4/1（24颗卫星，4个轨道面，相位偏移1）
#   satellites_per_orbit = 6, orbit_count = 4, phase_shift = 1
#   轨道面1的卫星：0°, 60°, 120°, 180°, 240°, 300°
#   轨道面2的卫星：15°, 75°, 135°, 195°, 255°, 315°（偏移15°）
#   轨道面3的卫星：30°, 90°, 150°, 210°, 270°, 330°（偏移30°）
#   轨道面4的卫星：45°, 105°, 165°, 225°, 285°, 345°（偏移45°）
#
# 这种相位交错确保了网络覆盖的均匀性和链路的稳定性。
function default_mean_anomaly_deg(
    satellite_index::Int,
    satellites_per_orbit::Int,
    orbit_index::Int,
    orbit_count::Int,
    phase_shift::Int,
)::Float64
    satellite_index > 0 || throw(ArgumentError("satellite_index must be positive"))
    satellites_per_orbit > 0 ||
        throw(ArgumentError("satellites_per_orbit must be positive"))
    orbit_index > 0 || throw(ArgumentError("orbit_index must be positive"))
    orbit_count > 0 || throw(ArgumentError("orbit_count must be positive"))
    phase_shift >= 0 || throw(ArgumentError("phase_shift must be non-negative"))

    return mod(
        (satellite_index - 1) * 360.0 / satellites_per_orbit +
        (orbit_index - 1) * phase_shift * 360.0 / (orbit_count * satellites_per_orbit),
        360.0,
    )
end

"""
    default_satellite_name(shell_name::AbstractString, orbit_index::Int, satellite_index::Int)::String

生成设计星座中卫星的默认名称。

# 参数
- `shell_name`: 壳层名称。
- `orbit_index`: 轨道面序号。
- `satellite_index`: 轨道面内卫星序号。

# 返回值
- 形如 "ShellName-orbit3-sat5" 的可读字符串。
"""
default_satellite_name(shell_name::AbstractString, orbit_index::Int, satellite_index::Int)::String =
    "$(shell_name)-orbit$(orbit_index)-sat$(satellite_index)"

"""
    default_design_orbit_generation_rules()::DesignOrbitGenerationRules

返回一套默认的设计轨道生成规则。

# 返回值
- 包含本文件默认 `raan_span_fn`、`raan_deg_fn`、`mean_anomaly_deg_fn`、`satellite_name_fn` 的规则对象。
"""
function default_design_orbit_generation_rules()::DesignOrbitGenerationRules
    return DesignOrbitGenerationRules(
        default_raan_span_deg,
        default_raan_deg,
        default_mean_anomaly_deg,
        default_satellite_name,
    )
end

"""
    orbit_system_variable(
        id::AbstractString,
        name::Symbol,
        value,
        value_type::DataType,
        description::AbstractString;
        source::Symbol = :system_rule,
        physical_verify_targets::Vector{Symbol} = Symbol[],
        runtime_verify_targets::Vector{Symbol} = Symbol[],
    )::SystemVariable

将一条轨道生成规则或默认值封装为系统变量 `SystemVariable`。

# 参数
- `id`: 变量唯一标识字符串。
- `name`: 变量名称符号。
- `value`: 变量值（可为函数或标量）。
- `value_type`: 变量值类型。
- `description`: 中文描述文本。
- `source`: 变量来源，默认为 `:system_rule`。
- `physical_verify_targets`: 物理验证目标符号列表。
- `runtime_verify_targets`: 运行时验证目标符号列表。

# 返回值
- 构造好的 `SystemVariable` 实例。

# 依赖
- 依赖外部类型 `SystemVariable`、`VariableMeta`（定义于系统变量模块）。
"""
function orbit_system_variable(
    id::AbstractString,
    name::Symbol,
    value,
    value_type::DataType,
    description::AbstractString;
    source::Symbol = :system_rule,
    physical_verify_targets::Vector{Symbol} = Symbol[],
    runtime_verify_targets::Vector{Symbol} = Symbol[],
)::SystemVariable
    return SystemVariable(
        VariableMeta(
            Symbol(id),
            name,
            :orbit,
            value_type,
            :none,
            String(description),
            source,
            :readonly,
            physical_verify_targets,
            runtime_verify_targets,
        ),
        value,
    )
end

"""
    design_orbit_generation_system_variables()::Vector{SystemVariable}

返回设计星座轨道生成相关的默认系统变量列表。

# 返回值
- 包含 RAAN 展开、RAAN 计算、平均近点角、卫星命名以及默认偏心率和近地点幅角的系统变量。
  这些变量可供配置系统或验证模块统一消费。
"""
function design_orbit_generation_system_variables()::Vector{SystemVariable}
    return SystemVariable[
        orbit_system_variable(
            "orbit.raan_span_fn",
            :raan_span_fn,
            default_raan_span_deg,
            Function,
            "根据轨道倾角决定 RAAN 展开范围的系统规则",
            physical_verify_targets = [:raan_deg],
        ),
        orbit_system_variable(
            "orbit.raan_deg_fn",
            :raan_deg_fn,
            default_raan_deg,
            Function,
            "根据轨道面序号、轨道面数量和 RAAN 展开范围计算 RAAN 的系统规则",
            physical_verify_targets = [:raan_deg],
        ),
        orbit_system_variable(
            "orbit.mean_anomaly_deg_fn",
            :mean_anomaly_deg_fn,
            default_mean_anomaly_deg,
            Function,
            "根据卫星槽位、轨道面序号和相位偏移计算 mean anomaly 的系统规则",
            physical_verify_targets = [:mean_anomaly_deg],
        ),
        orbit_system_variable(
            "orbit.satellite_name_fn",
            :satellite_name_fn,
            default_satellite_name,
            Function,
            "设计星座卫星命名规则",
            physical_verify_targets = [:satellite_name],
        ),
        orbit_system_variable(
            "orbit.default_eccentricity",
            :default_eccentricity,
            0.0,
            Float64,
            "设计星座默认圆轨道偏心率",
            source = :default,
            physical_verify_targets = [:orbit_elements],
        ),
        orbit_system_variable(
            "orbit.default_argument_of_perigee_deg",
            :default_argument_of_perigee_deg,
            0.0,
            Float64,
            "设计星座默认近地点幅角",
            source = :default,
            physical_verify_targets = [:orbit_elements],
        ),
    ]
end

"""
    build_design_constellation(
        spec::ConstellationSpec,
        builder::DesignConstellationBuilder;
        rules::DesignOrbitGenerationRules = default_design_orbit_generation_rules(),
    )::Constellation

根据设计型星座规格构建完整的静态星座对象 `Constellation`。

# 参数
- `spec`: 星座规格，包含一个或多个壳层（Shell）参数。
- `builder`: 设计型构建器，携带数据来源标签。
- `rules`: 轨道生成规则，默认为 `default_design_orbit_generation_rules()`。

# 返回值
- 构造好的 `Constellation`，其中每个 `Satellite` 都分配了全局唯一 `SatelliteId` 和基于规则的轨道六根数。

# 依赖
- 调用 `DesignOrbitElementSet` 构造轨道元素。
- 调用 `OrbitPlane`、`Shell`、`Constellation` 等类型（定义于星座核心类型模块）。
"""
# [算法说明]
# 设计型星座构建主函数
# 根据设计规格生成完整的静态星座对象。
#
# 构建流程（对每个壳层）：
#   1. 根据轨道倾角确定 RAAN 展开范围（180° 或 360°）
#   2. 对每个轨道面：
#      a. 计算该面的 RAAN（均匀分布）
#      b. 对面内每颗卫星：
#         - 计算 Walker 式相位交错后的平均近点角
#         - 构造轨道六根数（高度、倾角、RAAN、平均近点角等）
#         - 分配分层 SatelliteId
#   3. 构造 OrbitPlane 和 Shell 对象
#
# 轨道六根数说明：
#   - altitude_km：轨道高度（假设圆轨道，偏心率为 0）
#   - inclination_deg：轨道倾角
#   - raan_deg：升交点赤经
#   - mean_anomaly_deg：平均近点角（Walker 相位交错后）
#   - eccentricity：偏心率（设计星座默认为 0，即圆轨道）
#   - argument_of_perigee_deg：近地点幅角（圆轨道无意义，默认为 0）
function build_design_constellation(
    spec::ConstellationSpec,
    builder::DesignConstellationBuilder;
    rules::DesignOrbitGenerationRules = default_design_orbit_generation_rules(),
)::Constellation
    shells = Shell[]
    global_satellite_id = 1
    metadata = SourceMetadata(builder.source)

    for shell_spec in spec.shells
        orbit_planes = OrbitPlane[]
        # 根据当前壳层的轨道倾角确定 RAAN 展开范围
        raan_span = rules.raan_span_fn(shell_spec.inclination_deg)
        shell_local_satellite_id = 1

        for orbit_index in 1:shell_spec.orbit_count
            raan_deg = rules.raan_deg_fn(orbit_index, shell_spec.orbit_count, raan_span)
            satellites = Satellite[]

            for satellite_index in 1:shell_spec.satellites_per_orbit
                # 计算 Walker 式相位交错后的平均近点角
                mean_anomaly_deg = rules.mean_anomaly_deg_fn(
                    satellite_index,
                    shell_spec.satellites_per_orbit,
                    orbit_index,
                    shell_spec.orbit_count,
                    shell_spec.phase_shift,
                )

                orbit_elements = DesignOrbitElementSet(
                    altitude_km = shell_spec.altitude_km,
                    inclination_deg = shell_spec.inclination_deg,
                    raan_deg = raan_deg,
                    mean_anomaly_deg = mean_anomaly_deg,
                    metadata = metadata,
                )

                push!(
                    satellites,
                    Satellite(
                        identifier = SatelliteId(
                            global_id = global_satellite_id,
                            shell_id = shell_spec.id,
                            shell_local_id = shell_local_satellite_id,
                            orbit_plane_id = orbit_index,
                            plane_local_slot = satellite_index,
                        ),
                        name = rules.satellite_name_fn(shell_spec.name, orbit_index, satellite_index),
                        orbit_elements = orbit_elements,
                    ),
                )
                global_satellite_id += 1
                shell_local_satellite_id += 1
            end

            push!(orbit_planes, OrbitPlane(orbit_index, shell_spec.id, raan_deg, satellites))
        end

        push!(
            shells,
            Shell(
                id = shell_spec.id,
                name = shell_spec.name,
                altitude_km = shell_spec.altitude_km,
                inclination_deg = shell_spec.inclination_deg,
                orbit_planes = orbit_planes,
            ),
        )
    end

    return Constellation(spec.name, shells, SourceMetadata(spec.source))
end
