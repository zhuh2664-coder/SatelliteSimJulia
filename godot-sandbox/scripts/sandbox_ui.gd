extends Control
class_name SandboxUI
# ============================================================
# SandboxUI.gd — 顶部控制面板 + 底部 HUD（纯代码生成）
# ============================================================
#
# 包含：星座下拉 / 开始-停止 / 暂停 / 速度滑块 / 视图开关 / HUD
#
# 信号：
#   start_clicked(constellation: String)
#   stop_clicked
#   pause_toggled(paused: bool)
#   speed_changed(speed: float)
#   show_isl_changed(enabled: bool)
#   show_unavailable_isl_changed(enabled: bool)
#   show_trails_changed(enabled: bool)
#   show_earth_grid_changed(enabled: bool)
#   show_ground_changed(enabled: bool)
#   show_gsl_changed(enabled: bool)
#   show_coverage_changed(enabled: bool)
#   show_shells_changed(enabled: bool)
#   show_orbit_rings_changed(enabled: bool)
#   show_deployment_changed(enabled: bool)
# ============================================================

signal start_clicked(constellation: String)
signal stop_clicked
signal pause_toggled(paused: bool)
signal speed_changed(speed: float)
signal show_isl_changed(enabled: bool)
signal show_unavailable_isl_changed(enabled: bool)
signal show_trails_changed(enabled: bool)
signal show_earth_grid_changed(enabled: bool)
signal show_ground_changed(enabled: bool)
signal show_gsl_changed(enabled: bool)
signal show_coverage_changed(enabled: bool)
signal show_shells_changed(enabled: bool)
signal show_orbit_rings_changed(enabled: bool)
signal show_deployment_changed(enabled: bool)

# M5.1: 状态主题色（顶部面板背景）
@export var theme_idle: Color = Color(0.0, 0.0, 0.0, 0.55)
@export var theme_connecting: Color = Color(0.15, 0.20, 0.40, 0.65)
@export var theme_connected: Color = Color(0.0, 0.30, 0.10, 0.55)
@export var theme_streaming: Color = Color(0.10, 0.45, 0.10, 0.65)
@export var theme_error: Color = Color(0.55, 0.10, 0.10, 0.65)

var _constellation_dropdown: OptionButton
var _start_button: Button
var _pause_button: Button
var _speed_slider: HSlider
var _real_speed_button: Button
var _demo_speed_button: Button
var _fast_speed_button: Button
var _show_isl_check: CheckBox
var _show_unavailable_check: CheckBox
var _show_trails_check: CheckBox
var _show_grid_check: CheckBox
var _show_ground_check: CheckBox
var _show_gsl_check: CheckBox
var _show_coverage_check: CheckBox
var _show_shells_check: CheckBox
var _show_rings_check: CheckBox
var _show_deploy_check: CheckBox
var _status_label: Label
var _hud_label: Label
var _sat_info_label: Label
var _panel_stylebox: StyleBoxFlat    # M5.1: 实例字段，用于换色

var _names: PackedStringArray = []
var _running: bool = false

func _ready() -> void:
	_build_ui()
	_start_button.pressed.connect(_on_button_pressed)
	_pause_button.toggled.connect(_on_pause_toggled)
	_speed_slider.value_changed.connect(_on_speed_changed)
	_real_speed_button.pressed.connect(func(): _set_speed(1.0))
	_demo_speed_button.pressed.connect(func(): _set_speed(60.0))
	_fast_speed_button.pressed.connect(func(): _set_speed(300.0))
	_show_isl_check.toggled.connect(show_isl_changed.emit)
	_show_unavailable_check.toggled.connect(show_unavailable_isl_changed.emit)
	_show_trails_check.toggled.connect(show_trails_changed.emit)
	_show_grid_check.toggled.connect(show_earth_grid_changed.emit)
	_show_ground_check.toggled.connect(show_ground_changed.emit)
	_show_gsl_check.toggled.connect(show_gsl_changed.emit)
	_show_coverage_check.toggled.connect(show_coverage_changed.emit)
	_show_shells_check.toggled.connect(show_shells_changed.emit)
	_show_rings_check.toggled.connect(show_orbit_rings_changed.emit)
	_show_deploy_check.toggled.connect(show_deployment_changed.emit)

func _build_ui() -> void:
	# 全屏 Control
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_PASS

	# 顶部面板
	var panel = PanelContainer.new()
	panel.name = "TopPanel"
	# M5.1: 用 StyleBoxFlat 让背景色可变
	_panel_stylebox = StyleBoxFlat.new()
	_panel_stylebox.bg_color = theme_idle
	_panel_stylebox.content_margin_top = 6
	_panel_stylebox.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", _panel_stylebox)
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	panel.add_child(hbox)
	add_child(panel)

	# 星座下拉
	_constellation_dropdown = OptionButton.new()
	_constellation_dropdown.custom_minimum_size = Vector2(180, 0)
	hbox.add_child(_constellation_dropdown)

	# 开始/停止
	_start_button = Button.new()
	_start_button.text = "Start"
	_start_button.custom_minimum_size = Vector2(80, 0)
	hbox.add_child(_start_button)

	# 暂停/继续
	_pause_button = Button.new()
	_pause_button.text = "Pause"
	_pause_button.toggle_mode = true
	_pause_button.disabled = true
	_pause_button.custom_minimum_size = Vector2(80, 0)
	hbox.add_child(_pause_button)

	# 速度滑块
	_speed_slider = HSlider.new()
	_speed_slider.min_value = 0.25
	_speed_slider.max_value = 300.0
	_speed_slider.value = 60.0
	_speed_slider.custom_minimum_size = Vector2(160, 0)
	hbox.add_child(_speed_slider)

	_real_speed_button = _new_speed_button("Real", 1.0)
	hbox.add_child(_real_speed_button)
	_demo_speed_button = _new_speed_button("Demo", 60.0)
	hbox.add_child(_demo_speed_button)
	_fast_speed_button = _new_speed_button("Fast", 300.0)
	hbox.add_child(_fast_speed_button)

	_show_isl_check = _new_check("ISL", true)
	hbox.add_child(_show_isl_check)
	_show_unavailable_check = _new_check("Unavailable", true)
	hbox.add_child(_show_unavailable_check)
	_show_trails_check = _new_check("Trails", false)
	hbox.add_child(_show_trails_check)
	_show_grid_check = _new_check("Grid", true)
	hbox.add_child(_show_grid_check)
	_show_ground_check = _new_check("Ground", true)
	hbox.add_child(_show_ground_check)
	_show_gsl_check = _new_check("GSL", true)
	hbox.add_child(_show_gsl_check)
	_show_coverage_check = _new_check("Coverage", true)
	hbox.add_child(_show_coverage_check)
	_show_shells_check = _new_check("Shells", true)
	hbox.add_child(_show_shells_check)
	_show_rings_check = _new_check("Rings", true)
	hbox.add_child(_show_rings_check)
	_show_deploy_check = _new_check("Deploy", true)
	hbox.add_child(_show_deploy_check)

	# 状态文本
	_status_label = Label.new()
	_status_label.text = "Idle"
	_status_label.custom_minimum_size = Vector2(210, 0)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(_status_label)

	# 同步初始状态（所有 UI 节点建好之后）
	_set_running(false)

	# 卫星信息面板
	_sat_info_label = Label.new()
	_sat_info_label.name = "SatelliteInfo"
	_sat_info_label.text = "selected: none"
	_sat_info_label.anchor_left = 0.0
	_sat_info_label.anchor_right = 0.0
	_sat_info_label.anchor_top = 1.0
	_sat_info_label.anchor_bottom = 1.0
	_sat_info_label.offset_left = 12.0
	_sat_info_label.offset_top = -96.0
	_sat_info_label.offset_right = 360.0
	_sat_info_label.offset_bottom = -36.0
	add_child(_sat_info_label)

	# 底部 HUD
	_hud_label = Label.new()
	_hud_label.name = "Hud"
	_hud_label.text = "sats: -"
	_hud_label.anchor_left = 0.0
	_hud_label.anchor_right = 1.0
	_hud_label.anchor_top = 1.0
	_hud_label.anchor_bottom = 1.0
	_hud_label.offset_top = -30.0
	_hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_hud_label)

func _new_check(text: String, pressed: bool) -> CheckBox:
	var check = CheckBox.new()
	check.text = text
	check.button_pressed = pressed
	return check

func _new_speed_button(text: String, speed: float) -> Button:
	var button = Button.new()
	button.text = "%s %.0fx" % [text, speed]
	button.custom_minimum_size = Vector2(80, 0)
	return button

func _set_speed(speed: float) -> void:
	_speed_slider.set_value_no_signal(speed)
	speed_changed.emit(speed)

func _on_button_pressed() -> void:
	if _running:
		stop_clicked.emit()
		_set_running(false)
	else:
		var name = _get_selected_name()
		start_clicked.emit(name)
		_set_running(true)

func _on_pause_toggled(paused: bool) -> void:
	_pause_button.text = "Resume" if paused else "Pause"
	pause_toggled.emit(paused)

func _on_speed_changed(v: float) -> void:
	speed_changed.emit(v)

func _get_selected_name() -> String:
	var idx = _constellation_dropdown.selected
	if idx < 0 or idx >= _names.size():
		return ""
	return _names[idx]

func set_constellation_list(names: PackedStringArray) -> void:
	_names = names
	_constellation_dropdown.clear()
	for n in names:
		_constellation_dropdown.add_item(n)

func set_running(running: bool) -> void:
	# 外部调用方（如 GameBootstrap）同步状态
	_set_running(running)

func _set_running(running: bool) -> void:
	_running = running
	_start_button.text = "Stop" if running else "Start"
	_pause_button.disabled = not running
	if not running:
		_pause_button.button_pressed = false
		_pause_button.text = "Pause"
	_status_label.text = "Streaming…" if running else "Idle"

func set_status(s: String) -> void:
	_status_label.text = s
	# M5.1: 根据状态文本切换主题色
	if s.begins_with("Error") or s.find("Error:") >= 0:
		_panel_stylebox.bg_color = theme_error
	elif s.begins_with("Connecting"):
		_panel_stylebox.bg_color = theme_connecting
	elif s.begins_with("Connected"):
		_panel_stylebox.bg_color = theme_connected
	elif s.begins_with("Streaming") or s.begins_with("Starting") or s.begins_with("Paused"):
		_panel_stylebox.bg_color = theme_streaming
	else:
		_panel_stylebox.bg_color = theme_idle

func set_hud(sats: int, frame: int, total: int, isl_avail: int, isl_total: int, sim_time_s: float = 0.0, step_s: float = 1.0, speed: float = 1.0, paused: bool = false, coverage_ratio: float = -1.0, covered_ground: int = 0, total_ground: int = 0) -> void:
	var state = "paused" if paused else "play"
	var coverage = "-" if coverage_ratio < 0.0 else "%d/%d %.0f%%" % [covered_ground, total_ground, coverage_ratio * 100.0]
	_hud_label.text = "sats: %d    frame: %d/%d    t: %s    step: %.1fs    speed: %.2fx    ISL: %d/%d    GSL coverage: %s    fps: %d    %s" % [
		sats,
		frame,
		total,
		_format_time(sim_time_s),
		step_s,
		speed,
		isl_avail,
		isl_total,
		coverage,
		int(Engine.get_frames_per_second()),
		state,
	]

func set_satellite_info(text: String) -> void:
	_sat_info_label.text = text

func clear_satellite_info() -> void:
	_sat_info_label.text = "selected: none"

func _format_time(seconds: float) -> String:
	var total = max(0, int(seconds))
	var h = total / 3600
	var m = (total % 3600) / 60
	var s = total % 60
	return "%02d:%02d:%02d" % [h, m, s]
