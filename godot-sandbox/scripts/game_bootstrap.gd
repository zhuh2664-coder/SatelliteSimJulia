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

var _ws: Node
var _world: Node3D
var _ui: Control

var _session_id: String = ""
var _n_sat: int = 0
var _n_total: int = 0
var _server_fps: float = 10.0
var _speed: float = 1.0
var _running: bool = false
var _got_first_frame: bool = false
var _isl_a: PackedInt32Array
var _isl_b: PackedInt32Array

class Frame:
	var positions: PackedFloat32Array
	var isl_avail: PackedByteArray

var _buffer: Array[Frame] = []
var _accum: float = 0.0
var _displayed_frame: int = 0

func _ready() -> void:
	_ws = get_node("/root/WsClient")
	_world = $SandboxWorld
	_ui = $SandboxUI

	_ws.connected.connect(_on_ws_open)
	_ws.message_received.connect(_on_ws_message)
	_ws.closed.connect(_on_ws_closed)
	_ui.start_clicked.connect(_on_ui_start)
	_ui.stop_clicked.connect(_on_ui_stop)
	_ui.speed_changed.connect(_on_ui_speed)

	_ws.connect_to(server_uri)
	_ui.set_status("Connecting…")

func _process(delta: float) -> void:
	if not _running or _buffer.is_empty() or _speed <= 0.0 or not _world.is_initialised():
		return
	_accum += delta * _speed
	var interval = 1.0 / _server_fps
	while _accum >= interval and not _buffer.is_empty():
		_accum -= interval
		var f: Frame = _buffer.pop_front()
		_world.update_frame(f.positions, f.isl_avail)
		_displayed_frame += 1
		var avail_count = 0
		for b in f.isl_avail:
			if b != 0:
				avail_count += 1
		_ui.set_hud(_n_sat, _displayed_frame, _n_total, avail_count, _isl_a.size())

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
			_server_fps = max(1.0, float(msg.get("fps", 10.0)))
			_got_first_frame = false
			_buffer.clear()
			_accum = 0.0
			_displayed_frame = 0
			_ui.set_status("Session %s — %d frames" % [_session_id, _n_total])
			_ui.set_hud(_n_sat, 0, _n_total, 0, 0)
		"frame":
			_handle_frame(msg)
		"stream_end":
			_running = false
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
	_buffer.append(f)

	# HUD（用最新帧的 frame_index + ISL 数）
	var frame_idx = int(msg.get("frame_index", 0))
	var avail_count = 0
	for b in a_pkd:
		if b != 0:
			avail_count += 1
	_ui.set_hud(_n_sat, frame_idx, _n_total, avail_count, _isl_a.size())

func _send(obj: Dictionary) -> void:
	_ws.send_text(JSON.stringify(obj))

# ── UI 事件 ───────────────────────────────────────────────

func _on_ui_start(constellation: String) -> void:
	if _running:
		return
	_reset_session()
	_running = true
	_ui.set_status("Starting…")
	_send({
		"type": "start_simulation",
		"name": constellation,
		"tspan": [0.0, 600.0],
		"step_s": 10.0,
		"propagator": "j2",
		"fps": 10.0,
	})

func _on_ui_stop() -> void:
	if not _running:
		return
	_running = false
	_ui.set_status("Stopped")
	_ws.close()
	_buffer.clear()

func _on_ui_speed(v: float) -> void:
	_speed = v

func _reset_session() -> void:
	_session_id = ""
	_buffer.clear()
	_accum = 0.0
	_displayed_frame = 0
	_got_first_frame = false
