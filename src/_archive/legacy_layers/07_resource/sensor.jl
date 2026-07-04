"""
    资源层 / 传感器数据采集模块

    仿真星载传感器（光学、SAR、通信监测等）的数据生成、压缩和传输过程。
    使用 Distributions.jl 进行随机建模。
"""

using Distributions
import Random

export SensorSpec, SensorReading, SensorFleet,
       generate_sensor_readings!, compress_reading!,
       total_sensor_data_gb, simulate_sensor_network

"""
    SensorSpec

传感器规格。

# 字段
- `sensor_type::Symbol`: 传感器类型（:optical, :sar, :sigint, :weather）
- `data_rate_mbps::Float64`: 原始数据生成速率 (Mbps)
- `compression_ratio::Float64`: 压缩比 (0~1)，压缩后 = 原始 × ratio
- `duty_cycle::Float64`: 工作周期 (0~1)，仅在该比例时间内采集
- `power_w::Float64`: 传感器功耗 (W)
"""
struct SensorSpec
    sensor_type::Symbol
    data_rate_mbps::Float64
    compression_ratio::Float64
    duty_cycle::Float64
    power_w::Float64
end

# 预定义传感器类型
const OPTICAL_SENSOR = SensorSpec(:optical, 500.0, 0.3, 0.4, 150.0)
const SAR_SENSOR = SensorSpec(:sar, 1000.0, 0.5, 0.2, 300.0)
const SIGINT_SENSOR = SensorSpec(:sigint, 50.0, 0.8, 0.8, 50.0)
const WEATHER_SENSOR = SensorSpec(:weather, 10.0, 0.6, 1.0, 20.0)

"""
    SensorReading

单次传感器读数。

# 字段
- `satellite_id::Int`: 载体卫星
- `time_step::Int`: 采集时间
- `sensor_type::Symbol`: 传感器类型
- `raw_size_mb::Float64`: 原始数据大小 (MB)
- `compressed_size_mb::Float64`: 压缩后数据大小 (MB)
- `priority::Int`: 优先级 (1=最高, 5=最低)
"""
mutable struct SensorReading
    satellite_id::Int
    time_step::Int
    sensor_type::Symbol
    raw_size_mb::Float64
    compressed_size_mb::Float64
    priority::Int
end

"""
    SensorFleet

卫星群的所有传感器。

# 字段
- `sensor_map::Dict{Int, Vector{SensorSpec}}`: 卫星ID → 搭载的传感器列表
- `readings::Vector{SensorReading}`: 累积的传感器读数
- `total_raw_gb::Float64`: 总原始数据量
- `total_compressed_gb::Float64`: 总压缩后数据量
"""
mutable struct SensorFleet
    sensor_map::Dict{Int, Vector{SensorSpec}}
    readings::Vector{SensorReading}
    total_raw_gb::Float64
    total_compressed_gb::Float64
end

function SensorFleet(n_sats::Int; seed::Int = 42)
    rng = MersenneTwister(seed)
    smap = Dict{Int, Vector{SensorSpec}}()
    sensor_types = [OPTICAL_SENSOR, SAR_SENSOR, SIGINT_SENSOR, WEATHER_SENSOR]
    type_dist = DiscreteUniform(1, 4)
    count_dist = DiscreteUniform(1, 3)
    for i in 1:n_sats
        sensors = SensorSpec[]
        n_types = rand(rng, count_dist)
        for _ in 1:n_types
            push!(sensors, sensor_types[rand(rng, type_dist)])
        end
        smap[i] = sensors
    end
    return SensorFleet(smap, SensorReading[], 0.0, 0.0)
end

"""
    compress_reading!(reading::SensorReading, spec::SensorSpec)

对传感器读数进行压缩。
"""
function compress_reading!(reading::SensorReading, spec::SensorSpec)
    reading.compressed_size_mb = reading.raw_size_mb * spec.compression_ratio
end

"""
    generate_sensor_readings!(fleet::SensorFleet, n_time_steps::Int; seed::Int = 42)

生成所有卫星在仿真时间内的传感器数据。

# 参数
- `fleet::SensorFleet`: 传感器群
- `n_time_steps::Int`: 时间步数
"""
function generate_sensor_readings!(fleet::SensorFleet, n_time_steps::Int; seed::Int = 42)
    rng = Random.MersenneTwister(seed)
    empty!(fleet.readings)
    fleet.total_raw_gb = 0.0
    fleet.total_compressed_gb = 0.0

    for (sid, sensors) in fleet.sensor_map
        for t in 1:n_time_steps
            for spec in sensors
                rand(rng) > spec.duty_cycle && continue  # 非工作周期
                dt_min = 1.0  # 时间步长 1min
                raw_mb = spec.data_rate_mbps * dt_min * 60 / 8  # Mbps → MB
                reading = SensorReading(sid, t, spec.sensor_type, raw_mb, raw_mb, rand(rng, 1:5))
                compress_reading!(reading, spec)
                push!(fleet.readings, reading)
                fleet.total_raw_gb += raw_mb / 1000
                fleet.total_compressed_gb += reading.compressed_size_mb / 1000
            end
        end
    end
end

"""
    total_sensor_data_gb(fleet::SensorFleet; compressed::Bool = false) -> Float64

获取传感器数据总量。
"""
function total_sensor_data_gb(fleet::SensorFleet; compressed::Bool = false)::Float64
    return compressed ? fleet.total_compressed_gb : fleet.total_raw_gb
end
