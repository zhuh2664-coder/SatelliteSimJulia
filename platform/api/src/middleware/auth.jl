# auth.jl — Bearer token 校验中间件

using HTTP
using JSON
using SHA
using Base64
using Storage

function _hash_token(token::AbstractString)::String
    return base64encode(sha256(token))
end

function _unauthorized(msg = "unauthorized")
    return HTTP.Response(401, JSON.json(Dict("error" => msg, "code" => 401)))
end

function auth_middleware(handler)
    return function(req::HTTP.Request)
        auth = HTTP.header(req, "Authorization")
        isempty(auth) && return _unauthorized("missing Authorization header")

        parts = split(auth)
        if length(parts) != 2 || lowercase(parts[1]) != "bearer"
            return _unauthorized("invalid Authorization format")
        end

        token = parts[2]
        token_hash = _hash_token(token)
        user = Storage.get_user_by_token(token_hash)
        user === nothing && return _unauthorized("invalid token")

        req.context[:current_user] = user
        return handler(req)
    end
end

function current_user(req)::Storage.User
    return req.context[:current_user]
end
