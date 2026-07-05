# router.jl — HTTP 路由分发

using HTTP
using JSON
using SHA
using Base64

include("middleware/auth.jl")
include("middleware/tenant.jl")
include("routes/auth.jl")
include("routes/experiments.jl")
include("routes/jobs.jl")
include("routes/results.jl")

function _wrap(handler; auth = true)
    if auth
        return auth_middleware(tenant_middleware(handler))
    else
        return handler
    end
end

function _route_not_found(req::HTTP.Request)
    return HTTP.Response(404, "{}")
end

function router(req::HTTP.Request)
    path = req.target
    # strip query string for routing
    path = split(path, "?")[1]

    try
        # ── 无需认证 ──
        if path == "/api/register" && req.method == "POST"
            return register(req)
        elseif path == "/api/login" && req.method == "POST"
            return login(req)
        end

        # ── 需要认证 ──
        if path == "/api/me" && req.method == "GET"
            return _wrap(me)(req)

        elseif path == "/api/experiments" && req.method == "POST"
            return _wrap(create_experiment)(req)
        elseif path == "/api/experiments" && req.method == "GET"
            return _wrap(list_experiments)(req)
        elseif startswith(path, "/api/experiments/") && req.method == "GET"
            id = split(path, "/")[3]
            req.params["id"] = id
            return _wrap(get_experiment)(req)
        elseif startswith(path, "/api/experiments/") && endswith(path, "/jobs") && req.method == "POST"
            id = split(path, "/")[3]
            req.params["id"] = id
            return _wrap(create_job)(req)

        elseif path == "/api/jobs" && req.method == "GET"
            return _wrap(list_jobs)(req)
        elseif startswith(path, "/api/jobs/") && endswith(path, "/status") && req.method == "GET"
            id = split(path, "/")[3]
            req.params["id"] = id
            return _wrap(get_job_status)(req)
        elseif startswith(path, "/api/jobs/") && endswith(path, "/result.json") && req.method == "GET"
            id = split(path, "/")[3]
            req.params["id"] = id
            return _wrap(get_result_json)(req)
        elseif startswith(path, "/api/jobs/") && contains(path, "/download") && req.method == "GET"
            id = split(path, "/")[3]
            req.params["id"] = id
            return _wrap(download_file)(req)
        elseif startswith(path, "/api/jobs/") && req.method == "GET"
            id = split(path, "/")[3]
            req.params["id"] = id
            return _wrap(get_job)(req)

        else
            return _route_not_found(req)
        end
    catch e
        return HTTP.Response(500, JSON.json(Dict("error" => sprint(showerror, e), "code" => 500)))
    end
end
