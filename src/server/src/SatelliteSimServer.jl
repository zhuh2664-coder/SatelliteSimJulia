# ============================================================
# SatelliteSimServer — WebSocket 物理服务
#
# 把 SatelliteSimLab 的 transport-neutral streaming adapter 通过 WebSocket 暴露给 Unity 客户端。
# 协议：纯 WebSocket 文本帧（JSON），5 个 endpoint。
# 架构：叶子传输适配器；协议和会话留在 Server，领域仿真委托给 Lab。
#
# 依赖方向：Server → Lab → {Core, Net, Foundation, Orbit, Link, Metrics}
# ============================================================

module SatelliteSimServer

using SatelliteSimLab

# 全部模块就绪：协议 + 会话 + 推流 + handlers。

include("protocol.jl")
include("sessions.jl")
include("streamer.jl")
include("handlers.jl")

export parse_request, ListConstellationsReq, DescribeConstellationReq,
       GroundStationSpec, WalkerSpec, StartSimulationReq, StopSimulationReq, AITraceReq, AICheckpointReq,
       ListConstellationsResp, DescribeConstellationResp,
       StartSimulationResp, StopSimulationResp, AITraceResp, AICheckpointResp, ErrorResponse,
       start_session, stop_session!, get_session,
       SimulationSession, SESSIONS,
       frame_payload, stream_end_payload,
       ws_handler, http_handler, serve,
       dispatch_request, handle_list_constellations,
       handle_describe_constellation, handle_start_simulation,
       handle_stop_simulation, handle_ai_trace, handle_ai_checkpoint

end # module
