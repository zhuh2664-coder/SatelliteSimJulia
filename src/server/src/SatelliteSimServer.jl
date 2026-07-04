# ============================================================
# SatelliteSimServer — WebSocket 物理服务
#
# 把 SatelliteSimCore/Lab 的物理层通过 WebSocket 暴露给 Unity 客户端。
# 协议：纯 WebSocket 文本帧（JSON），5 个 endpoint。
# 架构：叶子消费方，只调原子工具，不污染现有 11 个包。
#
# 依赖方向：Server → Lab/Net → Core → {Foundation, Orbit, Link, Metrics}
# ============================================================

module SatelliteSimServer

# 全部模块就绪：协议 + 会话 + 推流 + handlers。

include("protocol.jl")
include("sessions.jl")
include("streamer.jl")
include("handlers.jl")

export parse_request, ListConstellationsReq, DescribeConstellationReq,
       StartSimulationReq, StopSimulationReq,
       ListConstellationsResp, DescribeConstellationResp,
       StartSimulationResp, StopSimulationResp, ErrorResponse,
       start_session, stop_session!, get_session,
       SimulationSession, SESSIONS,
       frame_payload, stream_end_payload,
       ws_handler, http_handler, serve,
       dispatch_request, handle_list_constellations,
       handle_describe_constellation, handle_start_simulation,
       handle_stop_simulation

end # module
