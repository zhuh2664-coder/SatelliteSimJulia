#!/usr/bin/env julia
# 端到端客户端测试：连 SatelliteSimServer，走完整 list → start → frames 流程。

using WebSockets, JSON3

const URI = get(ENV, "SATSIM_URI", "ws://127.0.0.1:8080")

function run_e2e()
    WebSockets.open(URI) do ws
        # 1. list_constellations
        WebSockets.writeguarded(ws, JSON3.write(Dict("type" => "list_constellations")))
        data, ok = WebSockets.readguarded(ws)
        ok || error("list_constellations read failed")
        resp = JSON3.read(String(data))
        @assert resp["type"] == "list_constellations_response"
        names = resp["names"]
        println("✓ list_constellations: $(length(names)) names")

        # 2. start_simulation（短时长，快速验证）
        req = Dict(
            "type" => "start_simulation",
            "name" => "iridium",
            "tspan" => [0.0, 60.0],
            "step_s" => 10.0,
            "propagator" => "j2",
            "fps" => 10.0,
        )
        WebSockets.writeguarded(ws, JSON3.write(req))
        data, ok = WebSockets.readguarded(ws)
        ok || error("start_simulation read failed")
        start = JSON3.read(String(data))
        @assert start["type"] == "start_simulation_response"
        n_sat = start["n_sat"]
        n_time = start["n_time"]
        println("✓ start_simulation: n_sat=$n_sat n_time=$n_time fps=$(start["fps"])")

        # 3. 收 frame
        frame_count = 0
        while !eof(ws)
            data, ok = WebSockets.readguarded(ws)
            ok || break
            msg = JSON3.read(String(data))
            t = msg["type"]
            if t == "stream_end"
                println("✓ stream_end received")
                break
            end
            @assert t == "frame"
            frame_count += 1
            if frame_count == 1 || frame_count == n_time
                avail = count(msg["isl_avail"])
                total = length(msg["isl_pairs"])
                println("  frame $(msg["frame_index"])/$(msg["n_total"]): t=$(msg["t"]) ISL=$avail/$total positions=$(length(msg["positions"]))")
            end
        end

        println("✓ total frames received: $frame_count / $n_time")
        frame_count == n_time || error("frame count mismatch")
    end
end

run_e2e()
