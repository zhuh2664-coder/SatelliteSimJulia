extends Control
class_name SandboxUI
# ============================================================
# SandboxUI.gd — 顶部控制面板 + 底部 HUD（纯代码生成）
# ============================================================
#
# 包含：星座下拉 / 开始-停止 / 速度滑块 / 状态文本 / HUD
#
# 信号：
#   start_clicked(constellation: String)
#   stop_clicked
#   speed_changed(speed: float)
# ============================================================

signal start_clicked(constellation: String)
signal stop_clicked
signal speed_changed(speed: float)

# M5.1: 状态主题色（顶部面板背景）
@export var theme_idle: Color = Color(0.0, 0.0, 0.0, 0.55)
@export var theme_connecting: Color = Color(0.15, 0.20, 0.40, 0.65)
@export var theme_connected: Color = Color(0.0, 0.30, 0.10, 0.55)
@export var theme_streaming: Color = Color(0.10, 0.45, 0.10, 0.65)
@export var theme_error: Color = Color(0.55, 0.10, 0.10, 0.65)

var _constellation_dropdown: OptionButton
var _start_button: Button
var _speed_slider: HSlider
var _status_label: Label
var _hud_label: Label
var _panel_stylebox: StyleBoxFlat    # M5.1: 实例字段，用于换色

var _names: PackedStringArray = []
var _running: bool = false

func _ready() -> void:
	_build_ui()
	_start_button.pressed.connect(_on_button_pressed)
	_speed_slider.value_changed.connect(_on_speed_changed)

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
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)
	add_child(panel)

	# 星座下拉
	_constellation_dropdown = OptionButton.new()
	_constellation_dropdown.custom_minimum_size = Vector2(200, 0)
	hbox.add_child(_constellation_dropdown)

	# 开始/停止
	_start_button = Button.new()
	_start_button.text = "Start"
	_start_button.custom_minimum_size = Vector2(90, 0)
	hbox.add_child(_start_button)

	# 速度滑块
	_speed_slider = HSlider.new()
	_speed_slider.min_value = 0.25
	_speed_slider.max_value = 5.0
	_speed_slider.value = 1.0
	_speed_slider.custom_minimum_size = Vector2(200, 0)
	hbox.add_child(_speed_slider)

	# 状态文本
	_status_label = Label.new()
	_status_label.text = "Idle"
	_status_label.custom_minimum_size = Vector2(250, 0)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(_status_label)

	# 同步初始状态（所有 UI 节点建好之后）
	_set_running(false)

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

func _on_button_pressed() -> void:
	if _running:
		stop_clicked.emit()
		_set_running(false)
	else:
		var name = _get_selected_name()
		start_clicked.emit(name)
		_set_running(true)

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
	elif s.begins_with("Streaming") or s.begins_with("Starting"):
		_panel_stylebox.bg_color = theme_streaming
	else:
		_panel_stylebox.bg_color = theme_idle

func set_hud(sats: int, frame: int, total: int, isl_avail: int, isl_total: int) -> void:
	_hud_label.text = "sats: %d    frame: %d/%d    ISL: %d/%d" % [sats, frame, total, isl_avail, isl_total]
