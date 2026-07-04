#!/usr/bin/env julia
# ============================================================
# SatelliteSimServer 启动脚本
#
# 用法：
#   julula --project=src/server bin/serve.jl              # 默认 127.0.0.1:8080
#   julia --project=src/server bin/serve.jl 9000           # 指定端口
#   julia --project=src/server bin/serve.jl 0.0.0.0 9000   # 指定 host:port
# ============================================================

# 注意：用 `julia --project=src/server src/server/bin/serve.jl` 启动，
# --project 已激活 src/server 环境，脚本里不需要再 Pkg.activate。

using SatelliteSimServer

# 解析参数
host = "127.0.0.1"
port = 8080
args = ARGS
if length(args) ≥ 1
    global port = parse(Int, args[1])
end
if length(args) ≥ 2
    global host = args[1]
    global port = parse(Int, args[2])
end

println("=" ^ 60)
println("  SatelliteSimServer")
println("  WebSocket: ws://$host:$port")
println("  Press Ctrl+C to stop")
println("=" ^ 60)

# 启动（阻塞）
SatelliteSimServer.serve(; host = host, port = port)
