# results.jl — 结果下载路由

using HTTP
using JSON
using UUIDs
using SHA
using Dates
using Storage

function get_result_json(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.context[:id])
    job = Storage.get_job(owner_id, id)
    job === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))
    job.status != "succeeded" && return HTTP.Response(400, JSON.json(Dict("error" => "job not succeeded")))

    prefix = (job.result_key === nothing || isempty(job.result_key)) ?
             "s3://results/$(id)/" : job.result_key
    key = rstrip(prefix, '/') * "/result.json"
    data = Storage.download_result(key)
    return HTTP.Response(200, ["Content-Type" => "application/json"], data)
end

function _result_prefix(job, id::UUID)
    return (job.result_key === nothing || isempty(job.result_key)) ?
           "s3://results/$(id)/" : job.result_key
end

const PRIMARY_RESULT_ARTIFACTS = ["result.json", "config.snapshot.json", "run_metadata.json"]

_result_key(prefix::AbstractString, name::AbstractString) = rstrip(prefix, '/') * "/$(name)"

function _is_missing_artifact_error(err)::Bool
    msg = lowercase(sprint(showerror, err))
    return occursin("not found", msg) ||
           occursin("notfound", msg) ||
           occursin("nosuchkey", msg) ||
           occursin("no such key", msg) ||
           occursin("404", msg)
end

function _try_download_artifact(key::AbstractString; downloader = Storage.download_result)
    try
        return downloader(key)
    catch err
        _is_missing_artifact_error(err) && return nothing
        rethrow()
    end
end

function _artifact_role(name::AbstractString)::String
    name == "result.json" && return "result"
    name == "config.snapshot.json" && return "config"
    name == "run_metadata.json" && return "metadata"
    return "artifact"
end

_artifact_content_type(name::AbstractString)::String =
    endswith(name, ".json") ? "application/json" : "application/octet-stream"

function _artifact_entry(name::AbstractString, data::AbstractVector{UInt8})
    return Dict(
        "path" => name,
        "name" => name,
        "role" => _artifact_role(name),
        "content_type" => _artifact_content_type(name),
        "bytes" => length(data),
        "size_bytes" => length(data),
        "sha256" => bytes2hex(sha256(data)),
    )
end

function _artifact_index_json(prefix::AbstractString; downloader = Storage.download_result)::String
    files = Dict{String,Any}[]
    for name in PRIMARY_RESULT_ARTIFACTS
        data = _try_download_artifact(_result_key(prefix, name); downloader = downloader)
        data === nothing && continue
        push!(files, _artifact_entry(name, data))
    end
    isempty(files) && error("artifact index missing and no primary artifacts found")
    return JSON.json(Dict(
        "schema_version" => "1",
        "generated_at" => string(now()),
        "files" => files,
        "artifacts" => files,
    ), 2)
end

function _artifact_index_data(prefix::AbstractString; downloader = Storage.download_result)::Vector{UInt8}
    key = _result_key(prefix, "artifacts.index.json")
    data = _try_download_artifact(key; downloader = downloader)
    data !== nothing && return data
    return Vector{UInt8}(codeunits(_artifact_index_json(prefix; downloader = downloader)))
end

function get_artifacts_json(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.context[:id])
    job = Storage.get_job(owner_id, id)
    job === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))
    job.status != "succeeded" && return HTTP.Response(400, JSON.json(Dict("error" => "job not succeeded")))

    data = _artifact_index_data(_result_prefix(job, id))
    return HTTP.Response(200, ["Content-Type" => "application/json"], data)
end

function _target_queryparams(target::AbstractString)
    parts = split(String(target), "?"; limit = 2)
    length(parts) == 2 || return Dict{String,String}()
    return HTTP.URIs.queryparams(parts[2])
end

function _safe_result_filename(filename::AbstractString)::Bool
    isempty(filename) && return false
    startswith(filename, "/") && return false
    occursin("..", filename) && return false
    occursin('\\', filename) && return false
    return true
end

function download_file(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.context[:id])
    job = Storage.get_job(owner_id, id)
    job === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))
    job.status != "succeeded" && return HTTP.Response(400, JSON.json(Dict("error" => "job not succeeded")))

    params = _target_queryparams(req.target)
    filename = get(params, "file", "")
    _safe_result_filename(filename) || return HTTP.Response(400, JSON.json(Dict("error" => "invalid file")))

    prefix = _result_prefix(job, id)
    if filename == "artifacts.index.json"
        data = _artifact_index_data(prefix)
        return HTTP.Response(200, ["Content-Type" => "application/json"], data)
    end

    key = _result_key(prefix, filename)
    data = Storage.download_result(key)
    content_type = endswith(filename, ".json") ? "application/json" : "application/octet-stream"
    return HTTP.Response(200, ["Content-Type" => content_type], data)
end
