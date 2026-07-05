extends SceneTree
# ============================================================
# perf_gui_probe.gd — M7.3 GUI 性能探针
# ============================================================
#
# 捕获 server 推来的星座帧，加载真实 SandboxWorld 渲染对象，然后在
# Godot process loop 中循环 replay 帧并采样 Engine FPS。
#
# 用法：
#   julia --project=src/server src/server/bin/serve.jl
#   ~/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot-sandbox \
#       -s godot-sandbox/tests/perf_gui_probe.gd
#
# 可选：只跑指定星座（逗号分隔）：
#   SATSIM_PERF_CONSTS=iridium Godot ...
#
# 退出码 0 = 探针采样成功；非 0 = 连接/捕获/采样失败。

const URI := "ws://127.0.0.1:8080"
const DEFAULT_CONSTELLATIONS := ["iridium", "oneweb"]
const CAPTURE_TIMEOUT_S := 60.0
const WARMUP_S := 1.0
const SAMPLE_S := 5.0

class Frame:
	var positions: PackedFloat32Array
	var isl_avail: PackedByteArray

func _init() -> void:
	var test_names = _test_constellations()
	print("=== M7.3 GUI perf probe: %d constellations ===" % test_names.size())

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
	var current_world = null
	var frames: Array = []
	var n_sat := 0
	var n_time := 0
	var capture_start_ms := 0

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

	var deadline := Time.get_ticks_msec() + int(CAPTURE_TIMEOUT_S * 1000.0)
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
				print("  list: %d constellations" % msg.get("names", []).size())
				current_index = 0
				current_name = test_names[current_index]
				_send_start(client, current_name)
				capture_start_ms = Time.get_ticks_msec()
			elif t == "start_simulation_response":
				n_sat = int(msg.get("n_sat", 0))
				n_time = int(msg.get("n_time", 0))
				frames.clear()
				print("  [%d/%d] capture %s: n_sat=%d n_time=%d" % [
					current_index + 1,
					test_names.size(),
					current_name,
					n_sat,
					n_time,
				])
			elif t == "frame":
				if current_world == null:
					current_world = _new_world()
					_init_world(current_world, n_sat, msg.get("isl_pairs", []))
				var frame = _parse_frame(msg)
				frames.append(frame)
				current_world.update_frame(frame.positions, frame.isl_avail)
			elif t == "stream_end":
				if current_world == null or frames.is_empty():
					results.append({"name": current_name, "pass": false, "error": "no frames"})
				else:
					var stats = await _sample_world(current_world, frames)
					stats["name"] = current_name
					stats["n_sat"] = n_sat
					stats["n_time"] = n_time
					stats["frames"] = frames.size()
					results.append(stats)
					_print_stats(stats)
				current_world = null
				current_index += 1
				if current_index >= test_names.size():
					_report_and_quit(results)
					return
				current_name = test_names[current_index]
				_send_start(client, current_name)
				capture_start_ms = Time.get_ticks_msec()
			elif t == "error":
				results.append({"name": current_name, "pass": false, "error": str(msg.get("message", ""))})
				_report_and_quit(results)
				return

		if current_index >= 0 and capture_start_ms > 0:
			var elapsed_ms = Time.get_ticks_msec() - capture_start_ms
			if elapsed_ms > int(CAPTURE_TIMEOUT_S * 1000.0):
				print("TIMEOUT: %s after %.1fs" % [current_name, elapsed_ms / 1000.0])
				results.append({"name": current_name, "pass": false, "error": "timeout"})
				_report_and_quit(results)
				return

	print("GLOBAL TIMEOUT or CLOSED: opened=%s closed=%s listed=%s current=%s" % [opened, closed, listed, current_name])
	_report_and_quit(results)

func _test_constellations() -> Array:
	var env = OS.get_environment("SATSIM_PERF_CONSTS")
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

func _new_world():
	var world := Node3D.new()
	world.name = "PerfSandboxWorld"
	world.set_script(load("res://scripts/sandbox_world.gd"))
	get_root().add_child(world)

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.look_at_from_position(Vector3(0.0, 150.0, 40.0), Vector3.ZERO, Vector3.UP)
	camera.current = true
	world.add_child(camera)

	var light := DirectionalLight3D.new()
	light.name = "DirectionalLight3D"
	light.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	world.add_child(light)
	return world

func _init_world(world, n_sat: int, pairs: Array) -> void:
	var isl_a := PackedInt32Array()
	var isl_b := PackedInt32Array()
	for p in pairs:
		isl_a.append(int(p[0]))
		isl_b.append(int(p[1]))
	world.init(n_sat, isl_a, isl_b)

func _parse_frame(msg: Dictionary) -> Frame:
	var frame := Frame.new()
	frame.positions = PackedFloat32Array()
	for v in msg.get("positions", []):
		frame.positions.append(float(v))
	frame.isl_avail = PackedByteArray()
	for v in msg.get("isl_avail", []):
		frame.isl_avail.append(1 if v else 0)
	return frame

func _sample_world(world, frames: Array) -> Dictionary:
	var warmup_end := Time.get_ticks_msec() + int(WARMUP_S * 1000.0)
	var sample_end := warmup_end + int(SAMPLE_S * 1000.0)
	var frame_index := 0
	var samples := 0
	var updates := 0
	var sum_fps := 0.0
	var min_fps := INF
	var max_fps := 0.0

	while Time.get_ticks_msec() < sample_end:
		await process_frame
		var frame: Frame = frames[frame_index % frames.size()]
		world.update_frame(frame.positions, frame.isl_avail)
		frame_index += 1
		updates += 1
		if Time.get_ticks_msec() >= warmup_end:
			var fps := float(Engine.get_frames_per_second())
			sum_fps += fps
			min_fps = min(min_fps, fps)
			max_fps = max(max_fps, fps)
			samples += 1

	return {
		"pass": samples > 0,
		"error": "" if samples > 0 else "no samples",
		"avg_fps": sum_fps / max(1, samples),
		"min_fps": min_fps if samples > 0 else 0.0,
		"max_fps": max_fps,
		"samples": samples,
		"updates": updates,
	}

func _print_stats(stats: Dictionary) -> void:
	print("  %s: sats=%d frames=%d/%d avg_fps=%.1f min_fps=%.1f max_fps=%.1f samples=%d updates=%d" % [
		stats["name"],
		stats["n_sat"],
		stats["frames"],
		stats["n_time"],
		stats["avg_fps"],
		stats["min_fps"],
		stats["max_fps"],
		stats["samples"],
		stats["updates"],
	])

func _report_and_quit(results: Array) -> void:
	var failed := 0
	for r in results:
		if not r.get("pass", false):
			failed += 1
			print("  FAIL %s: %s" % [r.get("name", ""), r.get("error", "")])
	if failed == 0 and results.size() > 0:
		print("PASS")
		quit(0)
	else:
		print("FAIL: %d/%d" % [failed, results.size()])
		quit(1)
