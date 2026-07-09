extends SceneTree
# ============================================================
# regression_constellations.gd — M7.1 回归测试
# ============================================================
#
# 通过 ws://127.0.0.1:8080 连接 SatelliteSimServer，验证单次连接
# 内的 start_simulation → frames → stream_end 流程通畅。
#
# **多星座遍历不在本测试范围**：服务端每个连接只支持一个
# start_simulation（stream 完后 ws_handler 会 break 关连接）。
# 改 server 支持多 sim 是 M7.2+ 的工作。
#
# 用法：
#   julia --project=src/server src/server/bin/serve.jl
#   ~/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot-sandbox \
#       -s godot-sandbox/tests/regression_constellations.gd
#
# 退出码 0 = 通过，非 0 = 失败。

const URI := "ws://127.0.0.1:8080"
const DEFAULT_CONSTELLATION := "iridium"
const FRAME_TIMEOUT_S := 20.0

func _init() -> void:
	var const_name: String = OS.get_environment("SATSIM_TEST_CONST")
	if const_name.is_empty():
		const_name = DEFAULT_CONSTELLATION
	print("=== M7.1 regression: %s ===" % const_name)

	var client := Node.new()
	get_root().add_child(client)
	client.set_script(load("res://scripts/ws_client.gd"))

	var opened := false
	var closed := false
	var msg_queue: Array = []
	var start_resp: Dictionary = {}
	var frames_received := 0
	var isl_avail_count := 0
	var isl_avail_total := 0
	var error_msg := ""
	var start_ms: int = 0

	client.connected.connect(func():
		opened = true
		client.send_text(JSON.stringify({
			"type": "list_constellations",
		}))
	)
	client.message_received.connect(func(s: String):
		msg_queue.append(s)
	)
	client.closed.connect(func():
		closed = true
	)

	var err = client.connect_to(URI)
	if err != OK:
		print("CONNECT FAILED: ", err)
		quit(1)
		return

	var deadline := Time.get_ticks_msec() + 30_000
	var listed := false
	while Time.get_ticks_msec() < deadline and not closed:
		await process_frame
		while msg_queue.size() > 0:
			var s: String = msg_queue.pop_front()
			var msg = JSON.parse_string(s)
			if msg == null: continue
			var t = msg.get("type", "")
			if t == "list_constellations_response" and not listed:
				listed = true
				var names = msg.get("names", [])
				print("  list: %d constellations" % names.size())
				# 发送 start
				client.send_text(JSON.stringify({
					"type": "start_simulation",
					"name": const_name,
					"tspan": [0.0, 60.0],
					"step_s": 10.0,
					"propagator": "j2",
					"fps": 10.0,
				}))
			elif t == "start_simulation_response":
				start_resp = msg
				start_ms = Time.get_ticks_msec()
			elif t == "frame":
				frames_received += 1
				var avail = msg.get("isl_avail", [])
				for a in avail:
					isl_avail_total += 1
					if a: isl_avail_count += 1
			elif t == "stream_end":
				pass
			elif t == "error":
				error_msg = str(msg.get("message", ""))
		if start_resp.size() > 0:
			var n_time = int(start_resp.get("n_time", 0))
			if frames_received >= n_time:
				break
			if start_ms > 0 and Time.get_ticks_msec() - start_ms > FRAME_TIMEOUT_S * 1000:
				print("TIMEOUT %d/%d" % [frames_received, n_time])
				break

	client.queue_free()

	var n_time = int(start_resp.get("n_time", 0))
	var n_sat = int(start_resp.get("n_sat", 0))
	print("=== RESULT ===")
	print("  constellation: %s" % const_name)
	print("  n_sat: %d" % n_sat)
	print("  n_time: %d" % n_time)
	print("  frames received: %d" % frames_received)
	print("  ISL: %d/%d available" % [isl_avail_count, isl_avail_total])
	if error_msg != "":
		print("  error: %s" % error_msg)

	var pass_ok = (n_time > 0 and frames_received >= n_time and error_msg == "")
	if pass_ok:
		print("PASS")
		quit(0)
	else:
		print("FAIL")
		quit(1)
