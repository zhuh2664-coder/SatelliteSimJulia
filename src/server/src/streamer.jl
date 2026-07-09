# ============================================================
# Frame streaming: Server adds protocol/session state to Lab frame data
# ============================================================

using SatelliteSimLab

"""
    frame_payload(session, frame_index) -> Dict

Build one protocol payload.  Physical propagation and ISL/GSL/coverage
calculation live in `SatelliteSimLab.streaming_frame`; Server adds only its
WebSocket message envelope and session identity.
"""
function frame_payload(session::SimulationSession, frame_index::Integer)
    payload = streaming_frame(session.simulation, frame_index)
    payload["type"] = "frame"
    payload["session_id"] = session.id
    return payload
end

"""Protocol envelope for the end of a Server-owned stream."""
stream_end_payload(session::SimulationSession) = Dict{String,Any}(
    "type" => "stream_end", "session_id" => session.id,
)
