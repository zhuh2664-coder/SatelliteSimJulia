# results.jl — 结果下载路由

using HTTP
using JSON
using UUIDs
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

function download_file(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.context[:id])
    job = Storage.get_job(owner_id, id)
    job === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))

    filename = HTTP.URIs.queryparams(req.target)["file"]
    prefix = (job.result_key === nothing || isempty(job.result_key)) ?
             "s3://results/$(id)/" : job.result_key
    key = rstrip(prefix, '/') * "/$(filename)"
    data = Storage.download_result(key)
    return HTTP.Response(200, ["Content-Type" => "application/octet-stream"], data)
end
