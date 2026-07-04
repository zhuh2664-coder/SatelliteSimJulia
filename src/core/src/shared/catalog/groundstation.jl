# 地面站目录 — 从 CSV 加载 109 个全球城市。
# 使用标准库 DelimitedFiles，无需 CSV + DataFrames。

export load_ground_stations, list_cities, filter_cities_by_country

using DelimitedFiles

const GROUND_STATIONS_CSV = joinpath(dirname(dirname(@__DIR__)), "data", "ground_stations.csv")
const _stations_cache = Ref{Union{Vector{Dict{String,String}},Nothing}}(nothing)

function load_ground_stations()
    if isnothing(_stations_cache[])
        raw = readdlm(GROUND_STATIONS_CSV, ',', String; header=true)
        header = raw[2]
        data = raw[1]
        stations = [Dict(header[j] => data[i,j] for j in 1:length(header)) for i in 1:size(data,1)]
        _stations_cache[] = stations
    end
    return _stations_cache[]
end

function list_cities()
    stations = load_ground_stations()
    return sort(unique([s["city"] for s in stations]))
end

function filter_cities_by_country(country::String)
    stations = load_ground_stations()
    return sort(unique([s["city"] for s in stations if s["country"] == country]))
end
