extends Node3D
class_name SandboxWorld
# ============================================================
# SandboxWorld.gd — 3D 地球 + 卫星 + ISL 连线
# ============================================================
#
# Init(n_sat, isl_a, isl_b)：
#   - 建地球 Sphere（按 EARTH_RADIUS_UNITS 半径）
#   - 建 1 个 MultiMesh 批量绘制 N 个卫星 Sphere
#   - 建 M 条 ISL 线（ImmediateMesh 动态两点）
#
# UpdateFrame(positions, isl_avail)：
#   - 更新每颗卫星 transform
#   - 更新每条 ISL 线的端点 + 可见性
#
# 坐标系：ECEF (X→0°赤道, Y→90°E, Z→北极) → Godot 左手系
#   Godot.X =  ECEF.X
#   Godot.Y =  ECEF.Z（北极朝上）
#   Godot.Z = -ECEF.Y
#   单位 1 unit = 100 km
# ============================================================

# ── 可调参数（Inspector）────────────────────────────────
@export var scale_km_per_unit: float = 100.0   # 1 unit = ? km
@export var earth_radius_units: float = 63.78137   # 6378.137 / 100
@export var sat_scale: float = 0.4             # radius in units
@export var earth_color: Color = Color(0.20, 0.40, 0.85)
@export var sat_color: Color = Color(1.0, 0.85, 0.3)
@export var sat_emission: Color = Color(1.0, 0.9, 0.4)
@export var isl_color: Color = Color(0.3, 0.9, 1.0, 0.6)
@export var isl_unavailable_color: Color = Color(0.4, 0.4, 0.45, 0.3)
@export var isl_pulse_speed: float = 2.0            # M4.2: cycles per second
@export var isl_pulse_min_alpha: float = 0.4
@export var isl_pulse_max_alpha: float = 0.9

var _earth: MeshInstance3D
var _satellite_multimesh: MultiMesh
var _satellite_positions: PackedVector3Array = []
var _isl_lines: Array[MeshInstance3D] = []
var _isl_meshes: Array[ImmediateMesh] = []
var _isl_materials: Array[StandardMaterial3D] = []   # M4.1: per-line mat
var _isl_avail_state: PackedByteArray = []          # M4.2: track for pulse
var _isl_a: PackedInt32Array
var _isl_b: PackedInt32Array
var _initialised: bool = false

func is_initialised() -> bool:
	return _initialised

func init(n_sat: int, isl_a: PackedInt32Array, isl_b: PackedInt32Array) -> void:
	_build_earth()
	_build_satellites(n_sat)
	_build_isl_lines(isl_a, isl_b)
	_initialised = true


# ── 子方法：建场景对象 ─────────────────────────────────

func _build_earth() -> void:
	_earth = MeshInstance3D.new()
	_earth.name = "Earth"
	_earth.mesh = SphereMesh.new()
	_earth.mesh.radius = earth_radius_units
	_earth.mesh.height = earth_radius_units * 2.0
	var earth_mat = StandardMaterial3D.new()
	earth_mat.albedo_color = earth_color
	_earth.material_override = earth_mat
	add_child(_earth)

func _build_satellites(n_sat: int) -> void:
	# M7.4: 1 个 MultiMeshInstance3D 批量绘制卫星，避免大星座 N 个节点。
	var sat_mesh = SphereMesh.new()
	sat_mesh.radius = sat_scale
	sat_mesh.height = sat_scale * 2.0

	var sat_mat = StandardMaterial3D.new()
	sat_mat.albedo_color = sat_color
	sat_mat.emission_enabled = true
	sat_mat.emission = sat_emission
	sat_mat.emission_energy_multiplier = 1.2
	sat_mesh.material = sat_mat

	_satellite_multimesh = MultiMesh.new()
	_satellite_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_satellite_multimesh.mesh = sat_mesh
	_satellite_multimesh.instance_count = n_sat
	_satellite_positions.resize(n_sat)

	var inst = MultiMeshInstance3D.new()
	inst.name = "Satellites"
	inst.multimesh = _satellite_multimesh
	add_child(inst)

func _build_isl_lines(isl_a: PackedInt32Array, isl_b: PackedInt32Array) -> void:
	_isl_a = isl_a
	_isl_b = isl_b
	_isl_avail_state.resize(isl_a.size())   # M4.2
	# M4.1: 每条 ISL 自己一个材质（颜色独立可变）
	for k in isl_a.size():
		var im = ImmediateMesh.new()
		var line = MeshInstance3D.new()
		line.name = "Isl%d" % (k + 1)
		line.mesh = im
		var mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = isl_unavailable_color
		line.material_override = mat
		line.visible = true   # M4.1: 所有候选都画，颜色区分
		add_child(line)
		_isl_lines.append(line)
		_isl_meshes.append(im)
		_isl_materials.append(mat)

func update_frame(positions: PackedFloat32Array, isl_avail: PackedByteArray) -> void:
	if not _initialised:
		return
	# 卫星位置
	for i in _satellite_positions.size():
		var p = i * 3
		var pos = ecef_km_to_unity(positions[p], positions[p + 1], positions[p + 2])
		_satellite_positions[i] = pos
		_satellite_multimesh.set_instance_transform(i, Transform3D(Basis(), pos))

	# ISL 颜色 + 端点（M4.1: 用颜色区分，不切 visibility）
	for k in _isl_lines.size():
		var avail = k < isl_avail.size() and isl_avail[k] != 0
		_isl_avail_state[k] = 1 if avail else 0   # M4.2
		var mat = _isl_materials[k]
		if not avail:
			mat.albedo_color = isl_unavailable_color
		# 可用边的颜色在 _process 里被脉动覆盖
		var a = _isl_a[k] - 1
		var b = _isl_b[k] - 1
		var pa = _satellite_positions[a]
		var pb = _satellite_positions[b]
		var im: ImmediateMesh = _isl_meshes[k]
		im.clear_surfaces()
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		im.surface_add_vertex(pa)
		im.surface_add_vertex(pb)
		im.surface_end()


# ── M4.2: 可用 ISL 脉动动画 ─────────────────────────
#
# 在 _process 里覆盖可用 ISL 的 alpha（颜色基础值从 update_frame 来）。
# 频率/振幅通过 @export 控制。
func _process(_delta: float) -> void:
	if not _initialised:
		return
	var t = Time.get_ticks_msec() / 1000.0
	var phase = sin(t * isl_pulse_speed * TAU) * 0.5 + 0.5   # 0..1
	var alpha = lerp(isl_pulse_min_alpha, isl_pulse_max_alpha, phase)
	for k in _isl_materials.size():
		if _isl_avail_state[k] != 0:
			var c = isl_color
			c.a = alpha
			_isl_materials[k].albedo_color = c


# ── 坐标变换（ECEF km → Godot 左手系） ─────────────────
#
# ECEF（地心地固）：
#   X → 赤道面 0 经度
#   Y → 90°E
#   Z → 北极
#
# Godot 4 左手系：
#   X → 右
#   Y → 上
#   Z → 前
#
# 映射（地球观测自然朝向）：
#   Godot.X =  ECEF.X
#   Godot.Y =  ECEF.Z（北极朝上）
#   Godot.Z = -ECEF.Y
#
# 单位：1 unit = scale_km_per_unit km
#
# 非 static（要访问实例变量 scale_km_per_unit）。
func ecef_km_to_unity(x_km: float, y_km: float, z_km: float) -> Vector3:
	return Vector3(
		x_km / scale_km_per_unit,
		z_km / scale_km_per_unit,
		-y_km / scale_km_per_unit
	)
