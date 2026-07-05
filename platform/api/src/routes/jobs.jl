# jobs.jl — 任务提交与查询路由

using HTTP
using JSON
using UUIDs
using Storage
using K8sScheduler

function _owner_id(req)::UUID
    return req.context[:owner_id]
end

function create_job(req::HTTP.Request)
    owner_id = _owner_id(req)
    experiment_id = UUID(req.params["id"])

    exp = Storage.get_experiment(owner_id, experiment_id)
    exp === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "experiment not found")))

    job = Storage.create_job(owner_id, experiment_id)

    config_s3_url = "s3://configs/$(exp.config_key)"
    output_s3_url = "s3://results/$(job.id)/"

    # 异步提交 K8s Job（第一期：不等待完成）
    k8s_name = K8sScheduler.submit_job(job.id, config_s3_url, output_s3_url)
    Storage.update_job_status!(owner_id, job.id; status = "running",
                                k8s_job_name = k8s_name,
                                result_key = "results/$(job.id)/")

    return HTTP.Response(201, JSON.json(Dict(
        "id" => string(job.id),
        "experiment_id" => string(job.experiment_id),
        "status" => "running",
        "k8s_job_name" => k8s_name,
    )))
end

function list_jobs(req::HTTP.Request)
    owner_id = _owner_id(req)
    jobs = Storage.list_jobs(owner_id)
    return HTTP.Response(200, JSON.json([
        Dict(
            "id" => string(j.id),
            "experiment_id" => string(j.experiment_id),
            "status" => j.status,
            "k8s_job_name" => j.k8s_job_name,
            "result_key" => j.result_key,
            "created_at" => string(j.created_at),
        ) for j in jobs
    ]))
end

function get_job(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.params["id"])
    job = Storage.get_job(owner_id, id)
    job === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))
    return HTTP.Response(200, JSON.json(Dict(
        "id" => string(job.id),
        "experiment_id" => string(job.experiment_id),
        "status" => job.status,
        "k8s_job_name" => job.k8s_job_name,
        "result_key" => job.result_key,
        "runner_logs" => job.runner_logs,
        "created_at" => string(job.created_at),
        "completed_at" => job.completed_at === nothing ? nothing : string(job.completed_at),
    )))
end

function get_job_status(req::HTTP.Request)
    owner_id = _owner_id(req)
    id = UUID(req.params["id"])
    job = Storage.get_job(owner_id, id)
    job === nothing && return HTTP.Response(404, JSON.json(Dict("error" => "not found")))
    return HTTP.Response(200, JSON.json(Dict("status" => job.status)))
end
