extends SceneTree
# ============================================================
# regression_constellations.gd — M7.2 多星座回归测试
# ============================================================
#
# 通过同一个 ws://127.0.0.1:8080 连接连续运行多个星座：
#   list_constellations → start_simulation(name1) → frames → stream_end
#                       → start_simulation(name2) → frames → stream_end ...
#
# 前提：server ws_handler 在 stream_session! 完成后不再 break，而是继续
# 等下一条请求（M7.2.2）。
#
# 用法：
#   julia --project=src/server src/server/bin/serve.jl
#   ~/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot-sandbox \
#       -s godot-sandbox/tests/regression_constellations.gd
#
# 可选：只跑指定星座（逗号分隔）：
#   SATSIM_TEST_CONSTS=iridium,walker24 Godot ...
#
# 退出码 0 = 全部通过，非 0 = 有失败。

const URI := "ws://127.0.0.1:8080"
const DEFAULT_CONSTELLATIONS := [
	"walker24",
	"walker48",
	"walker72",
	"walker96",
	"iridium",
	"oneweb",
	"telesat",
]
const GLOBAL_TIMEOUT_S := 180.0
const SESSION_TIMEOUT_S := 30.0

func _init() -> void:
	var test_names = _test_constellations()
	print("=== M7.2 regression: %d constellations on one WS ===" % test_names.size())

	var client := Node.new()
	get_root().add_child(client)
	client.set_script(load("res://scripts/ws_client.gd"))

	var opened := false
	var closed := false
	var listed := false
	var msg_queue: Array = []
	var results: Array = []
	var current_index := -1
	var current_name := ""
	var start_resp: Dictionary = {}
	var frames_received := 0
	var isl_avail_count := 0
	var isl_avail_total := 0
	var error_msg := ""
	var session_start_ms := 0

	client.connected.connect(func():
		opened = true
		client.send_text(JSON.stringify({"type": "list_constellations"}))
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

	var deadline := Time.get_ticks_msec() + int(GLOBAL_TIMEOUT_S * 1000.0)
	while Time.get_ticks_msec() < deadline and not closed:
		await process_frame
		while msg_queue.size() > 0:
			var raw: String = msg_queue.pop_front()
			var msg = JSON.parse_string(raw)
			if msg == null:
				continue
			var t = msg.get("type", "")
			if t == "list_constellations_response" and not listed:
				listed = true
				var names = msg.get("names", [])
				print("  list: %d constellations" % names.size())
				current_index = 0
				_send_start(client, test_names[current_index])
				current_name = test_names[current_index]
				start_resp = {}
				frames_received = 0
				isl_avail_count = 0
				isl_avail_total = 0
				error_msg = ""
				session_start_ms = Time.get_ticks_msec()
			elif t == "start_simulation_response":
				start_resp = msg
				print("  [%d/%d] %s: n_sat=%d n_time=%d" % [
					current_index + 1,
					test_names.size(),
					current_name,
					int(start_resp.get("n_sat", 0)),
					int(start_resp.get("n_time", 0)),
				])
			elif t == "frame":
				frames_received += 1
				var avail = msg.get("isl_avail", [])
				for a in avail:
					isl_avail_total += 1
					if a:
						isl_avail_count += 1
			elif t == "stream_end":
				_append_result(results, current_name, start_resp, frames_received, isl_avail_count, isl_avail_total, error_msg)
				current_index += 1
				if current_index >= test_names.size():
					_report_and_quit(results)
					return
				current_name = test_names[current_index]
				_send_start(client, current_name)
				start_resp = {}
				frames_received = 0
				isl_avail_count = 0
				isl_avail_total = 0
				error_msg = ""
				session_start_ms = Time.get_ticks_msec()
			elif t == "error":
				error_msg = str(msg.get("message", ""))

		if current_index >= 0 and session_start_ms > 0:
			var elapsed_ms = Time.get_ticks_msec() - session_start_ms
			if elapsed_ms > int(SESSION_TIMEOUT_S * 1000.0):
				print("TIMEOUT: %s after %.1fs" % [current_name, elapsed_ms / 1000.0])
				_append_result(results, current_name, start_resp, frames_received, isl_avail_count, isl_avail_total, "timeout")
				_report_and_quit(results)
				return

	print("GLOBAL TIMEOUT or CLOSED: opened=%s closed=%s listed=%s current=%s" % [opened, closed, listed, current_name])
	_report_and_quit(results)

func _test_constellations() -> Array:
	var env = OS.get_environment("SATSIM_TEST_CONSTS")
	if env.is_empty():
		return DEFAULT_CONSTELLATIONS.duplicate()
	var names: Array = []
	for part in env.split(","):
		var name = part.strip_edges()
		if not name.is_empty():
			names.append(name)
	return names

func _send_start(client: Node, name: String) -> void:
	client.send_text(JSON.stringify({
		"type": "start_simulation",
		"name": name,
		"tspan": [0.0, 60.0],
		"step_s": 10.0,
		"propagator": "j2",
		"fps": 10.0,
	}))

func _append_result(results: Array, name: String, start_resp: Dictionary, frames: int, isl_avail: int, isl_total: int, error_msg: String) -> void:
	var n_time = int(start_resp.get("n_time", 0))
	var n_sat = int(start_resp.get("n_sat", 0))
	results.append({
		"name": name,
		"n_sat": n_sat,
		"n_time": n_time,
		"frames": frames,
		"isl_avail": isl_avail,
		"isl_total": isl_total,
		"error": error_msg,
		"pass": n_time > 0 and frames >= n_time and error_msg == "",
	})

func _report_and_quit(results: Array) -> void:
	print("=== RESULT ===")
	var failed := 0
	for r in results:
		var mark = "✓" if r["pass"] else "✗"
		print("  %s %s: sats=%d frames=%d/%d ISL=%d/%d error=%s" % [
			mark,
			r["name"],
			r["n_sat"],
			r["frames"],
			r["n_time"],
			r["isl_avail"],
			r["isl_total"],
			r["error"],
		])
		if not r["pass"]:
			failed += 1
	if failed == 0 and results.size() > 0:
		print("PASS")
		quit(0)
	else:
		print("FAIL: %d/%d" % [failed, results.size()])
		quit(1)
