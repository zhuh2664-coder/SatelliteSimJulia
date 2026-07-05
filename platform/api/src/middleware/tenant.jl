# tenant.jl — 多租户隔离中间件

using HTTP
using Storage

function tenant_middleware(handler)
    return function(req::HTTP.Request)
        if haskey(req.context, :current_user)
            req.context[:owner_id] = Storage.current_user(req).id
        end
        return handler(req)
    end
end
