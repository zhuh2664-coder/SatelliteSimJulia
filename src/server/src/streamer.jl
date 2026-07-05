# ============================================================
# 帧推流：从会话 positions 切单帧 + 评估当前 ISL 可用性
# ============================================================
#
# 帧 JSON 结构（推流消息）：
#   {
#     "type": "frame",
#     "session_id": "...",
#     "t": <Float64, 距 epoch 秒>,
#     "frame_index": <Int>,
#     "n_total": <Int, 总帧数>,
#     "positions": [x1,y1,z1, x2,y2,z2, ...],   // 展平 ECEF km
#     "isl_pairs": [[i,j], ...],                 // 候选 ISL 边
#     "isl_avail": [true, false, ...]            // 与 isl_pairs 等长
#   }
#
# 帧由 streamer 在 ws 连接上发送，循环：
#   while session.active && frame_index ≤ n_time
#       payload = frame_payload(session, frame_index)
#       send(ws, JSON3.write(payload))
#       frame_index += 1
#       sleep(1/fps)
#   end
#   完成后发 stream_end 消息。
# ============================================================

using JSON3
using SatelliteSimCore

"""
    frame_payload(session, frame_index) -> Dict

构造第 `frame_index` 帧（1-based）的 JSON payload。

切片 positions[:, frame_index, :] → N×3 矩阵，
evaluate_isl_batch 算每条候选边的当前可用性。
"""
function frame_payload(session::SimulationSession, frame_index::Integer)
    n_time = size(session.positions, 2)
    1 ≤ frame_index ≤ n_time ||
        throw(BoundsError(session.positions, (:, frame_index, :)))

    # 切单帧：N×3 矩阵
    pos_frame = position_at_instant(session.positions, frame_index)

    # 评估当前帧的 ISL 可用性
    isl_results = evaluate_isl_batch(pos_frame, session.isl_edges; constraints = session.constraints)
    isl_avail = Bool[r.available for r in isl_results]

    # 展平 positions：[x1,y1,z1, x2,y2,z2, ...]
    positions_flat = Float64[]
    sizehint!(positions_flat, length(pos_frame))
    for i in 1:size(pos_frame, 1), j in 1:3
        push!(positions_flat, pos_frame[i, j])
    end

    # 时间戳：距 epoch 秒
    t = (frame_index - 1) * session.step_s

    # isl_pairs 输出为 [[i,j], ...]（JSON-friendly）
    isl_pairs_json = [[Int(a), Int(b)] for (a, b) in session.isl_edges]

    payload = Dict{String,Any}(
        "type"        => "frame",
        "session_id"  => session.id,
        "t"           => t,
        "frame_index" => Int(frame_index),
        "n_total"     => Int(n_time),
        "positions"   => positions_flat,
        "isl_pairs"   => isl_pairs_json,
        "isl_avail"   => isl_avail,
    )

    if session.include_gsl && !isempty(session.ground_station_tuples)
        _append_gsl_payload!(payload, session, pos_frame)
    end

    return payload
end

function _append_gsl_payload!(payload::Dict{String,Any}, session::SimulationSession, pos_frame)
    avail, _, _, _ = evaluate_gsl_batch(pos_frame, session.ground_station_tuples; constraints = session.constraints)
    n_sat, n_ground = size(avail)

    gsl_avail = Bool[]
    sizehint!(gsl_avail, n_sat * n_ground)
    gsl_pairs = Vector{Vector{Int}}()
    for i in 1:n_sat, g in 1:n_ground
        v = Bool(avail[i, g])
        push!(gsl_avail, v)
        v && push!(gsl_pairs, [Int(i), Int(g)])
    end

    covered = count(g -> any(@view avail[:, g]), 1:n_ground)
    payload["ground_stations"] = _ground_station_payload(session.ground_stations)
    payload["gsl_shape"] = [Int(n_sat), Int(n_ground)]
    payload["gsl_avail"] = gsl_avail
    payload["gsl_pairs"] = gsl_pairs
    if session.include_coverage
        payload["coverage_summary"] = Dict{String,Any}(
            "ratio" => n_ground == 0 ? 0.0 : covered / n_ground,
            "covered" => Int(covered),
            "total" => Int(n_ground),
        )
    end
    return payload
end

function _ground_station_payload(stations::Vector{GroundStationSpec})
    return [
        begin
            x, y, z = geodetic_to_ecef_km(gs.lat_deg, gs.lon_deg, gs.alt_km)
            Dict{String,Any}(
                "id" => gs.id,
                "name" => gs.name,
                "lat_deg" => gs.lat_deg,
                "lon_deg" => gs.lon_deg,
                "alt_km" => gs.alt_km,
                "ecef_km" => [x, y, z],
            )
        end
        for gs in stations
    ]
end

"""
    stream_end_payload(session) -> Dict

推流结束消息（到达最后一帧或会话被停止时发）。
"""
function stream_end_payload(session::SimulationSession)
    return Dict{String,Any}(
        "type"       => "stream_end",
        "session_id" => session.id,
    )
end
