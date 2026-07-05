extends Node
class_name GameBootstrap
# ============================================================
# GameBootstrap.gd — 总控：WS 消息路由 + 播放控制
# ============================================================
#
# 流程：
#   1. 连 WsClient → OnOpen → 发 list_constellations → 填充 UI 下拉
#   2. UI 选星座点 Start → 发 start_simulation
#   3. 收 start_response → 等 frame 推流
#   4. 收到首帧 → 初始化 SandboxWorld（拿到 ISL 边集）→ 入缓冲
#   5. 后续帧入缓冲 → _process 按 speed 推进
#   6. UI 点 Stop → 关 WS、清缓冲
#
# 节点结构：
#   Main (Node)        - this
#     SandboxWorld      - 3D 渲染
#     SandboxUI         - uGUI 面板
# ============================================================

@export var server_uri: String = "ws://127.0.0.1:8080"
@export var max_frame_history: int = 300

var _ws: Node
var _world: Node3D
var _ui: Control

var _session_id: String = ""
var _n_sat: int = 0
var _n_total: int = 0
var _server_fps: float = 1.0
var _step_s: float = 1.0
var _speed: float = 1.0
var _running: bool = false
var _paused: bool = false
var _got_first_frame: bool = false
var _isl_a: PackedInt32Array = PackedInt32Array()
var _isl_b: PackedInt32Array = PackedInt32Array()
var _last_isl_avail: PackedByteArray = PackedByteArray()
var _coverage_ratio: float = -1.0
var _covered_ground: int = 0
var _total_ground: int = 0

class Frame:
	var positions: PackedFloat32Array
	var isl_avail: PackedByteArray
	var ground_stations: Array = []
	var gsl_pairs: Array = []
	var coverage_summary: Dictionary = {}
	var frame_index: int = 0
	var sim_time_s: float = 0.0

var _buffer: Array[Frame] = []
var _history: Array[Frame] = []
var _accum: float = 0.0
var _displayed_frame: int = 0
var _displayed_time_s: float = 0.0

func _ready() -> void:
	_ws = get_node("/root/WsClient")
	_world = $SandboxWorld
	_ui = $SandboxUI

	_ws.connected.connect(_on_ws_open)
	_ws.message_received.connect(_on_ws_message)
	_ws.closed.connect(_on_ws_closed)
	_ui.start_clicked.connect(_on_ui_start)
	_ui.stop_clicked.connect(_on_ui_stop)
	_ui.pause_toggled.connect(_on_ui_pause)
	_ui.speed_changed.connect(_on_ui_speed)
	_ui.show_isl_changed.connect(_on_ui_show_isl)
	_ui.show_unavailable_isl_changed.connect(_on_ui_show_unavailable_isl)
	_ui.show_trails_changed.connect(_on_ui_show_trails)
	_ui.show_earth_grid_changed.connect(_on_ui_show_earth_grid)
	_ui.show_ground_changed.connect(_on_ui_show_ground)
	_ui.show_gsl_changed.connect(_on_ui_show_gsl)
	_ui.show_coverage_changed.connect(_on_ui_show_coverage)
	_world.satellite_selected.connect(_on_satellite_selected)
	_world.selection_cleared.connect(_on_selection_cleared)

	_ws.connect_to(server_uri)
	_ui.set_status("Connecting…")

func _process(delta: float) -> void:
	if not _running or _paused or _buffer.is_empty() or _speed <= 0.0 or not _world.is_initialised():
		return
	_accum += delta * _speed
	var interval = 1.0 / _server_fps
	while _accum >= interval and not _buffer.is_empty():
		_accum -= interval
		var f: Frame = _buffer.pop_front()
		_display_frame(f)

func _display_frame(f: Frame) -> void:
	_world.update_frame(f.positions, f.isl_avail, f.ground_stations, f.gsl_pairs, f.coverage_summary)
	_last_isl_avail = f.isl_avail
	_displayed_frame = f.frame_index
	_displayed_time_s = f.sim_time_s
	if not f.coverage_summary.is_empty():
		_coverage_ratio = float(f.coverage_summary.get("ratio", -1.0))
		_covered_ground = int(f.coverage_summary.get("covered", 0))
		_total_ground = int(f.coverage_summary.get("total", 0))
	_history.append(f)
	if _history.size() > max_frame_history:
		_history.pop_front()
	_update_hud()

func _update_hud() -> void:
	var avail_count = 0
	for b in _last_isl_avail:
		if b != 0:
			avail_count += 1
	_ui.set_hud(_n_sat, _displayed_frame, _n_total, avail_count, _isl_a.size(), _displayed_time_s, _step_s, _speed, _paused, _coverage_ratio, _covered_ground, _total_ground)

# ── WS 事件 ───────────────────────────────────────────────

func _on_ws_open() -> void:
	_ui.set_status("Connected")
	_send({"type": "list_constellations"})

func _on_ws_closed() -> void:
	_ui.set_status("Disconnected")

func _on_ws_message(json_text: String) -> void:
	var msg = JSON.parse_string(json_text)
	if msg == null or not msg is Dictionary:
		return
	var t = msg.get("type", "")
	match t:
		"list_constellations_response":
			var names = msg.get("names", [])
			var p: PackedStringArray = []
			for n in names:
				p.append(n)
			_ui.set_constellation_list(p)
			_ui.set_status("%d constellations" % names.size())
		"start_simulation_response":
			_session_id = msg.get("session_id", "")
			_n_sat = int(msg.get("n_sat", 0))
			_n_total = int(msg.get("n_time", 0))
			_server_fps = max(1.0, float(msg.get("fps", 1.0)))
			_step_s = float(msg.get("step_s", 1.0))

			_got_first_frame = false
			_buffer.clear()
			_history.clear()
			_accum = 0.0
			_displayed_frame = 0
			_displayed_time_s = 0.0
			_last_isl_avail = PackedByteArray()
			_coverage_ratio = -1.0
			_covered_ground = 0
			_total_ground = 0
			_ui.set_status("Session %s — %d frames" % [_session_id, _n_total])


			_update_hud()
		"frame":
			_handle_frame(msg)
		"stream_end":
			_running = false
			_paused = false
			_ui.set_running(false)
			_ui.set_status("Stream ended")
		"error":
			_ui.set_status("Error: " + str(msg.get("message", "")))

func _handle_frame(msg: Dictionary) -> void:
	var positions = msg.get("positions", [])
	var pairs = msg.get("isl_pairs", [])
	var avail = msg.get("isl_avail", [])

	# 第一次收到 frame 时初始化世界（拿到 ISL 边集）
	if not _got_first_frame:
		_isl_a = PackedInt32Array()
		_isl_b = PackedInt32Array()
		for p in pairs:
			_isl_a.append(int(p[0]))
			_isl_b.append(int(p[1]))
		_world.init(_n_sat, _isl_a, _isl_b)
		_got_first_frame = true

	# 入缓冲
	var p_pkd = PackedFloat32Array()
	for v in positions:
		p_pkd.append(float(v))
	var a_pkd = PackedByteArray()
	for v in avail:
		a_pkd.append(1 if v else 0)

	var f = Frame.new()
	f.positions = p_pkd
	f.isl_avail = a_pkd
	f.ground_stations = msg.get("ground_stations", [])
	f.gsl_pairs = msg.get("gsl_pairs", [])
	f.coverage_summary = msg.get("coverage_summary", {})
	f.frame_index = int(msg.get("frame_index", 0))
	f.sim_time_s = float(msg.get("t", max(0, f.frame_index - 1) * _step_s))
	_buffer.append(f)

	# HUD（用最新收到帧的 frame_index + ISL 数；真正播放时会再刷新）
	_displayed_frame = f.frame_index if _displayed_frame == 0 else _displayed_frame
	_update_hud()

func _send(obj: Dictionary) -> void:
	_ws.send_text(JSON.stringify(obj))

func _default_ground_stations() -> Array:
	return [
		{"id": "beijing", "name": "Beijing", "lat_deg": 39.9042, "lon_deg": 116.4074, "alt_km": 0.0},
		{"id": "san_francisco", "name": "San Francisco", "lat_deg": 37.7749, "lon_deg": -122.4194, "alt_km": 0.0},
		{"id": "new_york", "name": "New York", "lat_deg": 40.7128, "lon_deg": -74.0060, "alt_km": 0.0},
		{"id": "london", "name": "London", "lat_deg": 51.5074, "lon_deg": -0.1278, "alt_km": 0.0},
		{"id": "singapore", "name": "Singapore", "lat_deg": 1.3521, "lon_deg": 103.8198, "alt_km": 0.0},
		{"id": "sydney", "name": "Sydney", "lat_deg": -33.8688, "lon_deg": 151.2093, "alt_km": 0.0},
	]

# ── UI 事件 ───────────────────────────────────────────────

func _on_ui_start(constellation: String) -> void:
	if _running:
		return
	_reset_session()
	_running = true
	_paused = false
	_ui.set_status("Starting…")
	_send({
		"type": "start_simulation",
		"name": constellation,
		"tspan": [0.0, 7200.0],
		"step_s": 1.0,
		"propagator": "j2",
		"fps": 1.0,
		"ground_stations": _default_ground_stations(),
		"include_gsl": true,
		"include_coverage": true,
	})

func _on_ui_stop() -> void:
	if not _running:
		return
	_running = false
	_paused = false
	_ui.set_status("Stopped")
	_ws.close()
	_buffer.clear()

func _on_ui_pause(paused: bool) -> void:
	_paused = paused
	_ui.set_status("Paused" if paused else "Streaming…")
	_update_hud()

func _on_ui_speed(v: float) -> void:
	_speed = v
	_update_hud()

func _on_ui_show_isl(enabled: bool) -> void:
	_world.set_show_isl(enabled)

func _on_ui_show_unavailable_isl(enabled: bool) -> void:
	_world.set_show_unavailable_isl(enabled)

func _on_ui_show_trails(enabled: bool) -> void:
	_world.set_show_trails(enabled)

func _on_ui_show_earth_grid(enabled: bool) -> void:
	_world.set_show_earth_grid(enabled)

func _on_ui_show_ground(enabled: bool) -> void:
	_world.set_show_ground_stations(enabled)

func _on_ui_show_gsl(enabled: bool) -> void:
	_world.set_show_gsl(enabled)

func _on_ui_show_coverage(enabled: bool) -> void:
	_world.set_show_coverage_heat(enabled)

func _on_satellite_selected(info: Dictionary) -> void:
	var pos = info.get("ecef_km", Vector3.ZERO)
	_ui.set_satellite_info("selected: sat %d\nalt: %.1f km    ISL: %d\nECEF km: %.1f, %.1f, %.1f" % [
		int(info.get("id", 0)),
		float(info.get("altitude_km", 0.0)),
		int(info.get("connected_isl", 0)),
		pos.x,
		pos.y,
		pos.z,
	])

func _on_selection_cleared() -> void:
	_ui.clear_satellite_info()

func _reset_session() -> void:
	_session_id = ""
	_buffer.clear()
	_history.clear()
	_accum = 0.0
	_displayed_frame = 0
	_displayed_time_s = 0.0
	_got_first_frame = false
	_last_isl_avail = PackedByteArray()
	_coverage_ratio = -1.0
	_covered_ground = 0
	_total_ground = 0
	_ui.clear_satellite_info()
	_world.clear_selection()
