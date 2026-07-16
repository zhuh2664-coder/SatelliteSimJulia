# ============================================================
# WebSocket handlers：5 个 endpoint 的处理 + WS 服务入口
# ============================================================
#
# WS 消息循环：
#   客户端连上 → server 读一条请求 JSON → dispatch_request 处理 →
#   写回响应 JSON。start_simulation 的响应写完后，
#   handler 在同连接上继续推 frame，直到推完或会话被 stop。
#
# 错误处理：任何异常都封装成 error 响应回写，不中断连接。
# ============================================================

using JSON3
using WebSockets
using SatelliteSimLab
using Base.Threads

# ── 单条请求的处理逻辑：返回响应对象 + 可选副作用（启动/停止会话） ──

"""处理 list_constellations：返回 catalog 全部星座名。"""
function handle_list_constellations()
    return ListConstellationsResp(names = streaming_constellation_names())
end

"""处理 describe_constellation：返回单星座参数。"""
function handle_describe_constellation(req::DescribeConstellationReq)
    metadata = streaming_constellation_metadata(req.name)
    return DescribeConstellationResp(
        name = req.name,
        T = metadata["T"], P = metadata["P"], F = metadata["F"],
        alt_km = metadata["alt_km"], inc_deg = metadata["inc_deg"],
    )
end

"""将 Server 协议中的 Walker DTO 转为 Lab streaming adapter 的配置。"""
_walker_config(spec::WalkerSpec) = streaming_walker_config(
    T = spec.T, P = spec.P, F = spec.F,
    alt_km = spec.alt_km, inc_deg = spec.inc_deg,
)

function handle_start_simulation(req::StartSimulationReq)
    config = req.walker === nothing ? nothing : _walker_config(req.walker)
    session = start_session(;
        name = req.name,
        config = config,
        tspan = req.tspan,
        step_s = req.step_s,
        propagator = req.propagator,
        fps = req.fps,
        ground_stations = req.ground_stations,
        include_gsl = req.include_gsl,
        include_coverage = req.include_coverage,
    )
    return session, StartSimulationResp(
        session_id = session.id,
        n_sat = size(session.positions, 1),
        n_time = size(session.positions, 2),
        fps = session.fps,
        step_s = session.step_s,
        tspan = session.tspan,
        n_ground_stations = length(session.ground_stations),
        gsl_enabled = session.include_gsl && !isempty(session.ground_stations),
        coverage_enabled = session.include_coverage && !isempty(session.ground_stations),
        constellation = streaming_constellation_metadata(session.simulation),
        shells = streaming_shell_metadata(session.simulation),
    )
end

"""处理 stop_simulation：停止会话。"""
function handle_stop_simulation(req::StopSimulationReq)
    ok = stop_session!(req.session_id)
    ok || throw(ArgumentError("session not found: $(req.session_id)"))
    return StopSimulationResp(session_id = req.session_id)
end

"""处理 ai_trace：返回 AI ledger timeline 或 replay plan。"""
function handle_ai_trace(req::AITraceReq)
    trace = SatelliteSimLab.load_agent_trace(req.session_id)
    items = if req.mode == "timeline"
        SatelliteSimLab.trace_timeline(trace)
    elseif req.mode == "replay_plan"
        [JSON3.write(item) for item in SatelliteSimLab.tool_replay_plan(trace)]
    else
        throw(ArgumentError("unknown ai_trace mode: $(req.mode)"))
    end
    return AITraceResp(session_id = req.session_id, mode = req.mode, items = String.(items))
end

"""处理 ai_checkpoint：返回 TeamGraph checkpoint 摘要 JSON。"""
function handle_ai_checkpoint(req::AICheckpointReq)
    path = joinpath("data", "sessions", req.session_id, "team_graph_checkpoint.json")
    summary = SatelliteSimLab.checkpoint_summary(path)
    return AICheckpointResp(session_id = req.session_id, summary_json = JSON3.write(summary))
end

# ── 主分发：把 Request 路由到 handler ────────────────────────

"""
    dispatch_request(req::Request) -> (response_obj, session_to_stream)

返回 (响应对象, 可能的待推流会话)。`session_to_stream === nothing` 表示不推流。
"""
function dispatch_request(req::Request)
    if req isa ListConstellationsReq
        return handle_list_constellations(), nothing
    elseif req isa DescribeConstellationReq
        return handle_describe_constellation(req), nothing
    elseif req isa StartSimulationReq
        session, resp = handle_start_simulation(req)
        return resp, session
    elseif req isa StopSimulationReq
        return handle_stop_simulation(req), nothing
    elseif req isa AITraceReq
        return handle_ai_trace(req), nothing
    elseif req isa AICheckpointReq
        return handle_ai_checkpoint(req), nothing
    else
        throw(ArgumentError("unhandled request type: $(typeof(req))"))
    end
end

# ── 推流循环：在 ws 上把会话所有帧推完 ──────────────────────

"""
    stream_session!(ws, session)

在 ws 连接上把 `session` 的所有帧推完。
- 按 session.fps 节流
- 检查 session.active[]，外部 stop 可中断
- 推完发 stream_end 消息
"""
function stream_session!(ws, session::SimulationSession)
    n_time = size(session.positions, 2)
    period_ms = session.fps > 0 ? Int(round(1000 / session.fps)) : 100

    while session.active[] && session.frame_index[] ≤ n_time
        payload = frame_payload(session, session.frame_index[])
        json = JSON3.write(payload)
        ok = WebSockets.writeguarded(ws, json)
        ok || return false   # 客户端断了
        session.frame_index[] += 1
        sleep(period_ms / 1000)
    end

    # 推流结束（除非中途被 stop）
    if session.active[]
        end_json = JSON3.write(stream_end_payload(session))
        WebSockets.writeguarded(ws, end_json)
    end
    return true
end

# ── WS handler：单连接的消息循环 ─────────────────────────────

"""
    ws_handler(ws)

每个 WS 连接进入此函数。循环读请求 → 分发 → 响应。
若是 start_simulation，写完响应后立即开始推流；
推流期间不再接受新请求，推完后回到消息循环等待下一条请求。
"""
function ws_handler(ws)
    @info "WebSocket connected" uri=string(ws)
    try
        while !eof(ws)
            data, ok = WebSockets.readguarded(ws)
            ok || break   # 客户端关闭
            isempty(data) && continue
            req_str = String(copy(data))

            req, resp, session_to_stream = try
                req = parse_request(req_str)
                resp, sess = dispatch_request(req)
                (req, resp, sess)
            catch e
                err = ErrorResponse(message = sprint(showerror, e))
                WebSockets.writeguarded(ws, JSON3.write(err))
                continue
            end

            # 写响应
            resp_json = JSON3.write(resp)
            ok2 = WebSockets.writeguarded(ws, resp_json)
            ok2 || break

            # 若是 start_simulation，开始推流；推完后继续等下一条请求
            if session_to_stream !== nothing
                ok3 = stream_session!(ws, session_to_stream)
                ok3 || break
            end
        end
    catch e
        @warn "ws_handler error" exception=(e, catch_backtrace())
    finally
        @info "WebSocket disconnected"
    end
end

# ── HTTP handler：非 WS 请求兜底（健康检查） ────────────────

"""HTTP 健康检查端点（GET /health）。"""
function http_handler(req)
    return """
    SatelliteSimServer is running.
    Connect via WebSocket to interact.
    """
end

# ── 服务启动入口 ────────────────────────────────────────────

"""
    serve(; host="127.0.0.1", port=8080) -> server

启动 WS 服务。阻塞当前任务（serve 在后台跑）。
返回 WebSockets.ServerWS 实例，可用 `close(server)` 停止。
"""
function serve(; host::String = "127.0.0.1", port::Int = 8080)
    server = WebSockets.ServerWS(http_handler, ws_handler)
    @info "SatelliteSimServer starting" host=host port=port
    WebSockets.serve(server, host, port)
    return server
end
