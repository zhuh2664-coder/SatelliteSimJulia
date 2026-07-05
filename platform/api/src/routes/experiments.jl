# experiments.jl — 实验 CRUD 路由

using HTTP
using JSON
using UUIDs
using Storage

function create_experiment(req::HTTP.Request)
    body = JSON.parse(String(req.body))
    name = get(body, "name", "")
    config = get(body, "config", Dict())
    isempty(name) && return HTTP.Response(400, JSON.json(Dict("error" => "name required")))

    owner_id = _owner_id(req)
    exp_id = uuid4()
    config_key = "$(exp_id)/config.json"

    # 上传配置到 MinIO；DB 存 bucket-relative key，跨组件传输时再补 s3:// URL
    Storage.upload_config(config_key, Vector{UInt8}(JSON.json(config, 2)))

    exp = Storage.create_experiment(owner_id, name, config_key)
    return HTTP.Response(201, JSON.json(Dict(
        "id" => string(exp.id),
        "name" => exp.name,
        "config_key" => exp.config_key,
        "created_at" => string(exp.created_at),
    )))
end

function list_experiments(req::HTTP.Request)
    owner_id = _owner_id(req)
    exps = Storage.list_experiments(owner_id)
    return HTTP.Response(200, JSON.json([
        Dict(
            "id" => string(e.id),
            "name" => e.name,
            "config_key" => e.config_key,
            "created_at" => string(e.created_at),
        ) for e in exps
    ]))
end

function get_experiment(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.context[:id])
    exp = Storage.get_experiment(owner_id, id)
    exp === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))
    return HTTP.Response(200, JSON.json(Dict(
        "id" => string(exp.id),
        "name" => exp.name,
        "config_key" => exp.config_key,
        "created_at" => string(exp.created_at),
    )))
end
