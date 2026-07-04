extends Camera3D
class_name OrbitCamera
# ============================================================
# OrbitCamera.gd — 鼠标轨道控制（M6）
# ============================================================
#
# 行为：
#   - 鼠标左键拖动 → 绕 target 旋转（yaw / pitch）
#   - 滚轮          → 缩放（限制 min/max distance）
#
# 用法：
#   1. 挂到 Camera3D 节点
#   2. 在 Inspector 设 `Target Path`（如 ../ 或具体 NodePath）
#   3. 调初始距离 / 俯仰角
#
# 坐标系：标准球坐标，y 轴朝上
# ============================================================

@export var target_path: NodePath
@export var min_distance: float = 80.0
@export var max_distance: float = 500.0
@export var rotate_speed: float = 0.4     # 度 / 像素
@export var zoom_speed: float = 8.0       # 单位 / 滚轮
@export var initial_distance: float = 150.0
@export var initial_yaw_deg: float = 0.0
@export var initial_pitch_deg: float = 30.0   # 略斜视，露出 3D 感

var _target: Node3D
var _yaw_deg: float
var _pitch_deg: float
var _distance: float

func _ready() -> void:
	if target_path.is_empty():
		_target = get_parent() as Node3D
	else:
		_target = get_node_or_null(target_path) as Node3D
	_yaw_deg = initial_yaw_deg
	_pitch_deg = initial_pitch_deg
	_distance = initial_distance
	_update_transform()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_yaw_deg -= event.relative.x * rotate_speed
			_pitch_deg = clamp(_pitch_deg - event.relative.y * rotate_speed, -89.0, 89.0)
			_update_transform()
	elif event is InputEventMouseButton:
		if event.pressed:
			match event.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					_distance = max(min_distance, _distance - zoom_speed)
					_update_transform()
				MOUSE_BUTTON_WHEEL_DOWN:
					_distance = min(max_distance, _distance + zoom_speed)
					_update_transform()

func _update_transform() -> void:
	if _target == null:
		return
	var yaw = deg_to_rad(_yaw_deg)
	var pitch = deg_to_rad(_pitch_deg)
	var x = _distance * cos(pitch) * sin(yaw)
	var y = _distance * sin(pitch)
	var z = _distance * cos(pitch) * cos(yaw)
	global_position = _target.global_position + Vector3(x, y, z)
	look_at(_target.global_position, Vector3.UP)
