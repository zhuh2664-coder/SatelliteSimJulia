# 设备端归约/聚合变体（KernelAbstractions，后端无关）
#
# ── 动机（真机基准发现）─────────────────────────────────────────────────────────
# 覆盖核（标量输出）加速极好；但 GSL/ISL 的端到端加速被"下载 (N,M,NT) / (pairs,NT)
# 大数组"吃掉——传输是最大瓶颈。很多调用方只需要**聚合量**而非完整链路矩阵：
#   - 每 (站,时) 可见卫星计数 / 每站可见时间比（GSL）
#   - 每时刻可用链路数 / 每跳平均可用度（ISL）
#
# 本文件提供**设备端归约核**：在设备上把可见性/可用性直接聚合成小结果，只下载
# 小数组（O(M·NT) / O(NT) / O(pairs)），不物化也不下载完整 (N,M,NT)/(pairs,NT)。
# 每个核**融合"评估 + 归约"为一趟**：逐输出槽内联重算与 `_gsl_kernel!` /
# `_isl_kernel!` **逐位一致**的几何/约束，因此聚合结果与"完整数组再 host 归约"完全相等
# （见 runtests.jl 的一致性测试）。
#
# 归约维度的选择均使每个 work-item 独占一个输出槽、沿被归约维内层循环，故**无需原子**，
# 在 CPU/GPU 后端上都正确。计数用 Int32，比值为 `count / n` 的浮点（与 host 归约同为
# 整数比，逐位一致）。
#
# 说明：本文件被 `SatelliteSimGPU.jl` 在 isl.jl 之后 include，
# `_gsl_elevation_deg_gpu`、`_isl_*_gpu`、`_SPEED_OF_LIGHT_KM_S`、`_wait_event`、
# `_WGS84_EQUATORIAL_RADIUS_KM` 等在模块作用域内可见。

export gsl_visible_counts_gpu, gsl_station_visible_ratio_gpu,
       isl_available_counts_gpu, isl_pair_available_ratio_gpu,
       isl_satellite_degree_gpu

# ── GSL 设备内联可见性（与 `_gsl_kernel!` 的 available 逐位一致）─────────────────
# 复刻 `_gsl_kernel!`：distance = |s-g|，elevation 由 NED 分量算，
# available = distance ≤ max_range && elevation ≥ min_elevation。
@inline function _gsl_visible_gpu(
    sx::T, sy::T, sz::T,
    gx::T, gy::T, gz::T,
    r11::T, r12::T, r13::T,
    r21::T, r22::T, r23::T,
    r31::T, r32::T, r33::T,
    min_elevation::T, max_range::T,
) where {T<:AbstractFloat}
    dx = sx - gx
    dy = sy - gy
    dz = sz - gz
    north = r11 * dx + r12 * dy + r13 * dz
    east = r21 * dx + r22 * dy + r23 * dz
    down = r31 * dx + r32 * dy + r33 * dz
    distance = sqrt(dx * dx + dy * dy + dz * dz)
    elevation = _gsl_elevation_deg_gpu(north, east, down)
    return (distance <= max_range) & (elevation >= min_elevation)
end

# ── ISL 设备内联可用性（与 `_isl_kernel!` 的 available 逐位一致）─────────────────
# 复刻 `_isl_kernel!` 的判定序列：距离 + LOS + 距离约束，若有速度再叠加 RTN 仰角 /
# 方位（激光终端）/ 直线外推持续时长。只返回 available（聚合无需中间物理量）。
@inline function _isl_available_gpu(
    ax::T, ay::T, az::T, bx::T, by::T, bz::T,
    has_vel::Bool, vax::T, vay::T, vaz::T, vbx::T, vby::T, vbz::T,
    max_range::T, require_los::Bool, earth_radius::T,
    cone_angle_deg::T, min_duration::T, time_horizon::T, terminal_id::Int,
) where {T<:AbstractFloat}
    dx, dy, dz = ax - bx, ay - by, az - bz
    d = sqrt(dx * dx + dy * dy + dz * dz)
    los = _isl_has_los_gpu(ax, ay, az, bx, by, bz, earth_radius)
    los_ok = (!require_los) | los
    avail = (d <= max_range) & los_ok

    if has_vel && avail
        rtn_valid, r, t, n =
            _isl_rtn_gpu(ax, ay, az, vax, vay, vaz, bx, by, bz)
        if rtn_valid
            elevation = _isl_elev_from_rtn_gpu(r, t, n)
            avail = avail & (elevation <= cone_angle_deg)
            if avail
                cos_psi = _isl_azim_from_rtn_gpu(t, n)
                avail = avail & _isl_azimuth_ok_gpu(cos_psi, terminal_id, cone_angle_deg)
                if avail
                    duration = _isl_duration_gpu(
                        ax, ay, az, vax, vay, vaz,
                        bx, by, bz, vbx, vby, vbz,
                        max_range, time_horizon,
                    )
                    avail = avail & (duration >= min_duration)
                end
            end
        else
            avail = false
        end
    end
    return avail
end

# ── GSL 归约核 ───────────────────────────────────────────────────────────────

# 每 (站, 时) 可见卫星计数：work-item 独占 (station, time)，内层遍历卫星累加。
@kernel function _gsl_visible_counts_kernel!(
    counts, positions, ground_ecef, ned_rotation,
    min_elevation, max_range, n_satellites, n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    station_index = linear_index ÷ n_times + 1

    gx = ground_ecef[station_index, 1]
    gy = ground_ecef[station_index, 2]
    gz = ground_ecef[station_index, 3]
    r11 = ned_rotation[station_index, 1, 1]
    r12 = ned_rotation[station_index, 1, 2]
    r13 = ned_rotation[station_index, 1, 3]
    r21 = ned_rotation[station_index, 2, 1]
    r22 = ned_rotation[station_index, 2, 2]
    r23 = ned_rotation[station_index, 2, 3]
    r31 = ned_rotation[station_index, 3, 1]
    r32 = ned_rotation[station_index, 3, 2]
    r33 = ned_rotation[station_index, 3, 3]

    c = zero(eltype(counts))
    for satellite_index in 1:n_satellites
        sx = positions[satellite_index, time_index, 1]
        sy = positions[satellite_index, time_index, 2]
        sz = positions[satellite_index, time_index, 3]
        visible = _gsl_visible_gpu(
            sx, sy, sz, gx, gy, gz,
            r11, r12, r13, r21, r22, r23, r31, r32, r33,
            min_elevation, max_range,
        )
        c += ifelse(visible, one(eltype(counts)), zero(eltype(counts)))
    end
    counts[station_index, time_index] = c
end

# 每站可见时间比：work-item 独占 station，内层遍历 (时刻 × 卫星)，
# 统计"至少可见一颗"的时刻数，除以 n_times。
@kernel function _gsl_station_visible_ratio_kernel!(
    ratio, positions, ground_ecef, ned_rotation,
    min_elevation, max_range, n_satellites, n_times,
)
    station_index = @index(Global)
    T = eltype(ratio)

    gx = ground_ecef[station_index, 1]
    gy = ground_ecef[station_index, 2]
    gz = ground_ecef[station_index, 3]
    r11 = ned_rotation[station_index, 1, 1]
    r12 = ned_rotation[station_index, 1, 2]
    r13 = ned_rotation[station_index, 1, 3]
    r21 = ned_rotation[station_index, 2, 1]
    r22 = ned_rotation[station_index, 2, 2]
    r23 = ned_rotation[station_index, 2, 3]
    r31 = ned_rotation[station_index, 3, 1]
    r32 = ned_rotation[station_index, 3, 2]
    r33 = ned_rotation[station_index, 3, 3]

    visible_times = 0
    for time_index in 1:n_times
        any_visible = false
        for satellite_index in 1:n_satellites
            sx = positions[satellite_index, time_index, 1]
            sy = positions[satellite_index, time_index, 2]
            sz = positions[satellite_index, time_index, 3]
            any_visible |= _gsl_visible_gpu(
                sx, sy, sz, gx, gy, gz,
                r11, r12, r13, r21, r22, r23, r31, r32, r33,
                min_elevation, max_range,
            )
        end
        visible_times += ifelse(any_visible, 1, 0)
    end
    ratio[station_index] = T(visible_times) / T(n_times)
end

# ── ISL 归约核（两阶段，高并行度）──────────────────────────────────────────────
#
# 旧实现：ndrange = n_times，每个 work-item 串行扫全部 pairs，GPU 严重欠饱和。
# 新实现：第一阶段把 (pair, time) 网格展开，每个 work-item 评估一个 pair-time；
# 第二阶段沿 pair 维求和得到每个时刻的可用链路数。所有加法都是 Int32，满足
# 整数结合律，因此结果与"完整矩阵 host 求和"逐位相等。

# 可调块大小：默认值 128，可通过环境变量 SATSIM_ISL_COUNT_WG 覆盖。
const _ISL_AVAILABLE_COUNTS_WG_DEFAULT = 128

function _isl_available_counts_workgroup()
    v = get(ENV, "SATSIM_ISL_COUNT_WG", nothing)
    return v === nothing ? _ISL_AVAILABLE_COUNTS_WG_DEFAULT : parse(Int, v)
end

# 第一阶段：输出 (padded_pairs, n_times) 的 Int32 局部计数，超出 n_pairs 的槽置零。
@kernel function _isl_available_counts_partial_kernel!(
    partial, positions, velocities, pair_src, pair_dst,
    has_vel, max_range, require_los, earth_radius,
    cone_angle_deg, min_duration, time_horizon, terminal_id, n_pairs, padded_pairs, n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index ÷ padded_pairs + 1
    pair_index = linear_index % padded_pairs + 1

    if pair_index <= n_pairs
        i = pair_src[pair_index]
        j = pair_dst[pair_index]
        ax = positions[i, time_index, 1]
        ay = positions[i, time_index, 2]
        az = positions[i, time_index, 3]
        bx = positions[j, time_index, 1]
        by = positions[j, time_index, 2]
        bz = positions[j, time_index, 3]
        vax = velocities[i, time_index, 1]
        vay = velocities[i, time_index, 2]
        vaz = velocities[i, time_index, 3]
        vbx = velocities[j, time_index, 1]
        vby = velocities[j, time_index, 2]
        vbz = velocities[j, time_index, 3]
        avail = _isl_available_gpu(
            ax, ay, az, bx, by, bz,
            has_vel, vax, vay, vaz, vbx, vby, vbz,
            max_range, require_los, earth_radius,
            cone_angle_deg, min_duration, time_horizon, terminal_id,
        )
        partial[pair_index, time_index] = ifelse(avail, one(eltype(partial)), zero(eltype(partial)))
    else
        partial[pair_index, time_index] = zero(eltype(partial))
    end
end

# 第二阶段：沿 pair 维求和，得到 (n_times,)。
@kernel function _isl_available_counts_reduce_kernel!(
    counts, partial, padded_pairs,
)
    time_index = @index(Global)
    c = zero(eltype(counts))
    for pair_index in 1:padded_pairs
        c += partial[pair_index, time_index]
    end
    counts[time_index] = c
end

# 每跳平均可用度：work-item 独占 pair，内层遍历时刻，统计可用时刻数除以 n_times。
@kernel function _isl_pair_ratio_kernel!(
    ratio, positions, velocities, pair_src, pair_dst,
    has_vel, max_range, require_los, earth_radius,
    cone_angle_deg, min_duration, time_horizon, terminal_id, n_times,
)
    pair_index = @index(Global)
    T = eltype(ratio)
    i = pair_src[pair_index]
    j = pair_dst[pair_index]

    avail_times = 0
    for time_index in 1:n_times
        ax = positions[i, time_index, 1]
        ay = positions[i, time_index, 2]
        az = positions[i, time_index, 3]
        bx = positions[j, time_index, 1]
        by = positions[j, time_index, 2]
        bz = positions[j, time_index, 3]
        vax = velocities[i, time_index, 1]
        vay = velocities[i, time_index, 2]
        vaz = velocities[i, time_index, 3]
        vbx = velocities[j, time_index, 1]
        vby = velocities[j, time_index, 2]
        vbz = velocities[j, time_index, 3]
        avail = _isl_available_gpu(
            ax, ay, az, bx, by, bz,
            has_vel, vax, vay, vaz, vbx, vby, vbz,
            max_range, require_los, earth_radius,
            cone_angle_deg, min_duration, time_horizon, terminal_id,
        )
        avail_times += ifelse(avail, 1, 0)
    end
    ratio[pair_index] = T(avail_times) / T(n_times)
end

# ── GSL 主机入口 ─────────────────────────────────────────────────────────────

"""
    gsl_visible_counts_gpu(positions, ground_ecef, ned_rotation;
        gsl_min_elevation_deg, gsl_max_range_km) -> counts::(M, NT) Int32

设备端聚合：每 (地面站, 时刻) 的**可见卫星计数**。融合"GSL 评估 + 计数"，逐 (站,时)
内联重算与 `evaluate_gsl_batch_gpu` 完全一致的可见性，只输出 `(M, NT)` 计数——
既不物化也不下载完整 `(N, M, NT)` 数组。输入设备数组即得设备数组（可经 `device_pipeline`
只下载这份小结果）。与"完整数组沿卫星维 host 求和"逐位相等。
"""
function gsl_visible_counts_gpu(
    positions::AbstractArray{T,3},
    ground_ecef::AbstractMatrix{T},
    ned_rotation::AbstractArray{T,3};
    gsl_min_elevation_deg::T=T(25.0),
    gsl_max_range_km::T=T(2000.0),
) where {T<:AbstractFloat}
    _validate_gsl_inputs(positions, ground_ecef, ned_rotation)
    n_satellites, n_times, _ = size(positions)
    n_stations = size(ground_ecef, 1)
    backend = get_backend(positions)
    counts = similar(positions, Int32, (n_stations, n_times))
    _wait_event(_gsl_visible_counts_kernel!(backend)(
        counts, positions, ground_ecef, ned_rotation,
        gsl_min_elevation_deg, gsl_max_range_km, n_satellites, n_times;
        ndrange=n_stations * n_times,
    ))
    return counts
end

"""
    gsl_station_visible_ratio_gpu(positions, ground_ecef, ned_rotation;
        gsl_min_elevation_deg, gsl_max_range_km) -> ratio::(M,) T

设备端聚合：每个地面站的**可见时间比**——至少可见一颗卫星的时刻数 / 总时刻数。
融合评估 + 归约，只输出 `(M,)`，不下载 `(N, M, NT)`。与"完整数组先按时刻判 any、
再统计时刻比"逐位相等（整数比）。
"""
function gsl_station_visible_ratio_gpu(
    positions::AbstractArray{T,3},
    ground_ecef::AbstractMatrix{T},
    ned_rotation::AbstractArray{T,3};
    gsl_min_elevation_deg::T=T(25.0),
    gsl_max_range_km::T=T(2000.0),
) where {T<:AbstractFloat}
    _validate_gsl_inputs(positions, ground_ecef, ned_rotation)
    n_satellites, n_times, _ = size(positions)
    n_stations = size(ground_ecef, 1)
    backend = get_backend(positions)
    ratio = similar(positions, T, n_stations)
    _wait_event(_gsl_station_visible_ratio_kernel!(backend)(
        ratio, positions, ground_ecef, ned_rotation,
        gsl_min_elevation_deg, gsl_max_range_km, n_satellites, n_times;
        ndrange=n_stations,
    ))
    return ratio
end

# ── ISL 主机入口 ─────────────────────────────────────────────────────────────

# 共享：对 pairs 做校验并把 (src, dst) 上设备，返回 (n_pairs, pair_src, pair_dst, has_vel, vel_arg)。
function _isl_reduction_setup(positions, isl_pairs, velocities)
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    n_satellites, n_times, _ = size(positions)
    n_satellites > 0 && n_times > 0 ||
        throw(ArgumentError("positions must be non-empty"))
    if velocities !== nothing
        size(velocities) == size(positions) ||
            throw(ArgumentError("velocities must match positions shape (N, NT, 3)"))
    end
    for (i, j) in isl_pairs
        (1 <= i <= n_satellites && 1 <= j <= n_satellites) ||
            throw(ArgumentError("isl_pairs indices must be within 1:$(n_satellites)"))
        i != j || throw(ArgumentError("ISL pair endpoints must be distinct"))
    end
    backend = get_backend(positions)
    pair_src = adapt(backend, Int[first(p) for p in isl_pairs])
    pair_dst = adapt(backend, Int[last(p) for p in isl_pairs])
    has_vel = velocities !== nothing
    vel_arg = has_vel ? velocities : positions   # 占位；has_vel=false 时不读取
    return n_satellites, n_times, length(isl_pairs), pair_src, pair_dst, has_vel, vel_arg
end

"""
    isl_available_counts_gpu(positions, isl_pairs; velocities=nothing, kwargs...)
        -> counts::(NT,) Int32

设备端聚合：每个**时刻**的可用 ISL 链路数。融合"ISL 评估 + 计数"，逐时刻内层遍历
链路对，只输出 `(NT,)`，不物化/下载完整 `(pairs, NT)`。`kwargs` 同 `evaluate_isl_batch_gpu`。
与"完整数组沿 pair 维 host 求和"逐位相等。
"""
function isl_available_counts_gpu(
    positions::AbstractArray{T,3},
    isl_pairs::AbstractVector{<:Tuple{Integer,Integer}};
    velocities::Union{Nothing,AbstractArray{T,3}}=nothing,
    isl_max_range_km::Real=5000.0,
    isl_require_los::Bool=true,
    isl_max_cone_angle_deg::Real=60.0,
    isl_min_duration_s::Real=10.0,
    time_horizon_s::Real=300.0,
    terminal_id::Integer=4,
    earth_radius_km::Real=_WGS84_EQUATORIAL_RADIUS_KM,
) where {T<:AbstractFloat}
    n_satellites, n_times, n_pairs, pair_src, pair_dst, has_vel, vel_arg =
        _isl_reduction_setup(positions, isl_pairs, velocities)
    options = _normalize_isl_options(
        T;
        isl_max_range_km=isl_max_range_km,
        isl_max_cone_angle_deg=isl_max_cone_angle_deg,
        isl_min_duration_s=isl_min_duration_s,
        time_horizon_s=time_horizon_s,
        earth_radius_km=earth_radius_km,
    )
    backend = get_backend(positions)
    counts = similar(positions, Int32, n_times)
    fill!(counts, zero(Int32))
    if n_pairs > 0
        workgroup = _isl_available_counts_workgroup()
        padded_pairs = cld(n_pairs, workgroup) * workgroup
        partial = fill!(similar(positions, Int32, (padded_pairs, n_times)), zero(Int32))
        _wait_event(_isl_available_counts_partial_kernel!(backend)(
            partial, positions, vel_arg, pair_src, pair_dst,
            has_vel, options.max_range, isl_require_los, options.earth_radius,
            options.cone_angle, options.min_duration, options.time_horizon,
            Int(terminal_id), n_pairs, padded_pairs, n_times;
            ndrange=padded_pairs * n_times,
            workgroupsize=workgroup,
        ))
        _wait_event(_isl_available_counts_reduce_kernel!(backend)(
            counts, partial, padded_pairs;
            ndrange=n_times,
        ))
    end
    return counts
end

"""
    isl_pair_available_ratio_gpu(positions, isl_pairs; velocities=nothing, kwargs...)
        -> ratio::(pairs,) T

设备端聚合：每条链路对（"跳"）的**平均可用度**——可用时刻数 / 总时刻数。融合评估 +
归约，逐 pair 内层遍历时刻，只输出 `(pairs,)`，不下载 `(pairs, NT)`。与"完整数组沿时刻维
host 求均值"逐位相等（整数比）。
"""
function isl_pair_available_ratio_gpu(
    positions::AbstractArray{T,3},
    isl_pairs::AbstractVector{<:Tuple{Integer,Integer}};
    velocities::Union{Nothing,AbstractArray{T,3}}=nothing,
    isl_max_range_km::Real=5000.0,
    isl_require_los::Bool=true,
    isl_max_cone_angle_deg::Real=60.0,
    isl_min_duration_s::Real=10.0,
    time_horizon_s::Real=300.0,
    terminal_id::Integer=4,
    earth_radius_km::Real=_WGS84_EQUATORIAL_RADIUS_KM,
) where {T<:AbstractFloat}
    n_satellites, n_times, n_pairs, pair_src, pair_dst, has_vel, vel_arg =
        _isl_reduction_setup(positions, isl_pairs, velocities)
    options = _normalize_isl_options(
        T;
        isl_max_range_km=isl_max_range_km,
        isl_max_cone_angle_deg=isl_max_cone_angle_deg,
        isl_min_duration_s=isl_min_duration_s,
        time_horizon_s=time_horizon_s,
        earth_radius_km=earth_radius_km,
    )
    backend = get_backend(positions)
    ratio = similar(positions, T, n_pairs)
    if n_pairs > 0
        _wait_event(_isl_pair_ratio_kernel!(backend)(
            ratio, positions, vel_arg, pair_src, pair_dst,
            has_vel, options.max_range, isl_require_los, options.earth_radius,
            options.cone_angle, options.min_duration, options.time_horizon,
            Int(terminal_id), n_times;
            ndrange=n_pairs,
        ))
    end
    return ratio
end

# ── ISL 下游：每 (卫星,时) 可用链路度（邻接/连通度指标，设备常驻）─────────────────
# "度"= 与该卫星相连且可用的 ISL 数。为避免 scatter 原子，先在 host 建 CSR 关联表
# （每颗卫星的入射 pair 索引），核逐 (卫星,时) 只遍历自身入射 pair，各自独占输出槽。

# host 端 CSR：offsets(N+1) + incident(2·n_pairs)，incident[offsets[s]:offsets[s+1]-1]
# 为卫星 s 的入射 pair 索引（1-based）。
function _isl_incidence_csr(isl_pairs, n_satellites)
    counts = zeros(Int, n_satellites)
    for (i, j) in isl_pairs
        counts[i] += 1
        counts[j] += 1
    end
    offsets = Vector{Int}(undef, n_satellites + 1)
    offsets[1] = 1
    for s in 1:n_satellites
        offsets[s + 1] = offsets[s] + counts[s]
    end
    incident = Vector{Int}(undef, offsets[end] - 1)
    cursor = offsets[1:n_satellites]
    for (p, (i, j)) in enumerate(isl_pairs)
        incident[cursor[i]] = p
        cursor[i] += 1
        incident[cursor[j]] = p
        cursor[j] += 1
    end
    return offsets, incident
end

@kernel function _isl_degree_kernel!(
    degree, positions, velocities, pair_src, pair_dst,
    incident_offsets, incident_pairs,
    has_vel, max_range, require_los, earth_radius,
    cone_angle_deg, min_duration, time_horizon, terminal_id, n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    sat_index = linear_index ÷ n_times + 1

    c = zero(eltype(degree))
    lo = incident_offsets[sat_index]
    hi = incident_offsets[sat_index + 1] - 1
    for k in lo:hi
        pair_index = incident_pairs[k]
        i = pair_src[pair_index]
        j = pair_dst[pair_index]
        ax = positions[i, time_index, 1]
        ay = positions[i, time_index, 2]
        az = positions[i, time_index, 3]
        bx = positions[j, time_index, 1]
        by = positions[j, time_index, 2]
        bz = positions[j, time_index, 3]
        vax = velocities[i, time_index, 1]
        vay = velocities[i, time_index, 2]
        vaz = velocities[i, time_index, 3]
        vbx = velocities[j, time_index, 1]
        vby = velocities[j, time_index, 2]
        vbz = velocities[j, time_index, 3]
        avail = _isl_available_gpu(
            ax, ay, az, bx, by, bz,
            has_vel, vax, vay, vaz, vbx, vby, vbz,
            max_range, require_los, earth_radius,
            cone_angle_deg, min_duration, time_horizon, terminal_id,
        )
        c += ifelse(avail, one(eltype(degree)), zero(eltype(degree)))
    end
    degree[sat_index, time_index] = c
end

"""
    isl_satellite_degree_gpu(positions, isl_pairs; velocities=nothing, kwargs...)
        -> degree::(N, NT) Int32

设备端下游聚合：每 (卫星, 时刻) 的**可用 ISL 链路度**（连通度/邻接度指标）。这是把一个
下游指标做成设备常驻的示例——从 `isl_pairs` 在 host 建 CSR 入射表，核逐 (卫星,时) 只遍历
自身入射链路并重算可用性累加，**无原子**、只下载 `(N, NT)`（而非 `(pairs, NT)`）。`kwargs`
同 `evaluate_isl_batch_gpu`。与"完整数组按卫星入射求和"逐位相等。
"""
function isl_satellite_degree_gpu(
    positions::AbstractArray{T,3},
    isl_pairs::AbstractVector{<:Tuple{Integer,Integer}};
    velocities::Union{Nothing,AbstractArray{T,3}}=nothing,
    isl_max_range_km::Real=5000.0,
    isl_require_los::Bool=true,
    isl_max_cone_angle_deg::Real=60.0,
    isl_min_duration_s::Real=10.0,
    time_horizon_s::Real=300.0,
    terminal_id::Integer=4,
    earth_radius_km::Real=_WGS84_EQUATORIAL_RADIUS_KM,
) where {T<:AbstractFloat}
    n_satellites, n_times, n_pairs, pair_src, pair_dst, has_vel, vel_arg =
        _isl_reduction_setup(positions, isl_pairs, velocities)
    options = _normalize_isl_options(
        T;
        isl_max_range_km=isl_max_range_km,
        isl_max_cone_angle_deg=isl_max_cone_angle_deg,
        isl_min_duration_s=isl_min_duration_s,
        time_horizon_s=time_horizon_s,
        earth_radius_km=earth_radius_km,
    )
    backend = get_backend(positions)
    degree = similar(positions, Int32, (n_satellites, n_times))
    fill!(degree, zero(Int32))
    if n_pairs > 0
        offsets_host, incident_host = _isl_incidence_csr(isl_pairs, n_satellites)
        incident_offsets = adapt(backend, offsets_host)
        incident_pairs = adapt(backend, incident_host)
        _wait_event(_isl_degree_kernel!(backend)(
            degree, positions, vel_arg, pair_src, pair_dst,
            incident_offsets, incident_pairs,
            has_vel, options.max_range, isl_require_los, options.earth_radius,
            options.cone_angle, options.min_duration, options.time_horizon,
            Int(terminal_id), n_times;
            ndrange=n_satellites * n_times,
        ))
    end
    return degree
end
