# results.jl — 结果下载路由

using HTTP
using JSON
using UUIDs
using Storage

function _owner_id(req)::UUID
    return req.context[:owner_id]
end

function get_result_json(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.params["id"])
    job = Storage.get_job(owner_id, id)
    job === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))
    job.status != "succeeded" && return HTTP.Response(400, JSON.json(Dict("error" => "job not succeeded")))

    key = "results/$(id)/result.json"
    data = Storage.download_result(key)
    return HTTP.Response(200, data; headers = ["Content-Type" => "application/json"])
end

function download_file(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.params["id"])
    job = Storage.get_job(owner_id, id)
    job === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))

    filename = HTTP.URIs.queryparams(req.target)["file"]
    key = "results/$(id)/$(filename)"
    data = Storage.download_result(key)
    return HTTP.Response(200, data; headers = ["Content-Type" => "application/octet-stream"])
end
