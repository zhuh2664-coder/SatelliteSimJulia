# auth.jl — 注册 / 登录路由

using HTTP
using JSON
using SHA
using Base64
using UUIDs
using Storage

function _hash_token(token::String)::String
    return base64encode(sha256(token))
end

function _json_response(data; status = 200)
    return HTTP.Response(status, JSON.json(data))
end

function _generate_token()::String
    return base64encode(rand(UInt8, 32))
end

function register(req::HTTP.Request)
    body = JSON.parse(String(req.body))
    email = get(body, "email", "")
    isempty(email) && return _json_response(Dict("error" => "email required"); status = 400)

    token = _generate_token()
    token_hash = _hash_token(token)
    user = Storage.create_user(email, token_hash)
    return _json_response(Dict(
        "id" => string(user.id),
        "email" => user.email,
        "token" => token,
    ))
end

function login(req::HTTP.Request)
    body = JSON.parse(String(req.body))
    email = get(body, "email", "")
    isempty(email) && return _json_response(Dict("error" => "email required"); status = 400)

    user = Storage.get_user_by_email(email)
    user === nothing && return _json_response(Dict("error" => "user not found"); status = 404)
    # 登录直接返回已有 token_hash（第一期简化：不支持 token 轮换）
    return _json_response(Dict(
        "id" => string(user.id),
        "email" => user.email,
        "token_hash" => user.token_hash,
    ))
end

function me(req::HTTP.Request)
    user = Storage.current_user(req)
    return _json_response(Dict(
        "id" => string(user.id),
        "email" => user.email,
    ))
end
