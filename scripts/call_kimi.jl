#!/usr/bin/env julia
# ===== 调用 Kimi API 做调研（Key 从文件读取）=====
using HTTP, JSON

const API_URL = "https://api.kimi.com/coding/v1/messages"
const KEY_FILE = joinpath(@__DIR__, ".kimi_env")

function read_key()
    if !isfile(KEY_FILE)
        println("❌ Key 文件不存在: $KEY_FILE")
        return nothing
    end
    key = strip(read(KEY_FILE, String))
    if isempty(key) || startswith(key, "#") || startswith(key, "sk-xxxx")
        println("❌ Key 无效或已被清空")
        return nothing
    end
    return key
end

function call_kimi(api_key, prompt; model="kimi-k2.7", max_tokens=4096)
    headers = [
        "Content-Type" => "application/json",
        "x-api-key" => api_key,
        "anthropic-version" => "2023-06-01",
    ]
    body = Dict(
        "model" => model,
        "max_tokens" => max_tokens,
        "messages" => [Dict("role" => "user", "content" => prompt)]
    )

    println("📤 发送请求到 Kimi...")
    resp = HTTP.post(API_URL, headers, JSON.json(body); connect_timeout=30, readtimeout=180)
    data = JSON.parse(String(resp.body))

    if haskey(data, "content") && length(data["content"]) > 0
        text = data["content"][1]["text"]
        println("\n📥 Kimi 回复:")
        println("─"^60)
        println(text)
        println("─"^60)
        usage = get(data, "usage", Dict())
        if !isempty(usage)
            println("Token 用量: $(get(usage, "input_tokens", "?")) in / $(get(usage, "output_tokens", "?")) out")
        end
        return text
    elseif haskey(data, "error")
        println("❌ 错误: $(data["error"])")
        return nothing
    else
        println("❌ 未知响应:")
        println(JSON.json(data, 4))
        return nothing
    end
end

# 主入口
key = read_key()
if key !== nothing
    prompt = isempty(ARGS) ? "调研LEO卫星网络仿真平台2025-2026年新进展" : join(ARGS, " ")
    call_kimi(key, prompt)
end
