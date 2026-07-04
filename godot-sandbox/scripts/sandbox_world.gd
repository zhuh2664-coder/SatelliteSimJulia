extends Node3D
class_name SandboxWorld
# ============================================================
# SandboxWorld.gd — 3D 地球 + 卫星 + ISL 连线
# ============================================================
#
# Init(n_sat, isl_a, isl_b)：
#   - 建地球 Sphere（按 EARTH_RADIUS_UNITS 半径）
#   - 建 N 个卫星 Sphere
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

const EARTH_RADIUS_UNITS := 63.78137   # 6378.137 km / 100
const SAT_SCALE := 0.4                 # radius in units
const SCALE_KM_PER_UNIT := 100.0

var _earth: MeshInstance3D
var _satellites: Array[MeshInstance3D] = []
var _isl_lines: Array[MeshInstance3D] = []
var _isl_meshes: Array[ImmediateMesh] = []
var _isl_a: PackedInt32Array
var _isl_b: PackedInt32Array
var _initialised: bool = false

func is_initialised() -> bool:
	return _initialised

func init(n_sat: int, isl_a: PackedInt32Array, isl_b: PackedInt32Array) -> void:
	_earth = MeshInstance3D.new()
	_earth.name = "Earth"
	_earth.mesh = SphereMesh.new()
	_earth.mesh.radius = EARTH_RADIUS_UNITS
	_earth.mesh.height = EARTH_RADIUS_UNITS * 2.0
	var earth_mat = StandardMaterial3D.new()
	earth_mat.albedo_color = Color(0.20, 0.40, 0.85)
	_earth.material_override = earth_mat
	add_child(_earth)

	# 卫星（共享材质）
	var sat_mat = StandardMaterial3D.new()
	sat_mat.albedo_color = Color(1.0, 0.85, 0.3)
	sat_mat.emission_enabled = true
	sat_mat.emission = Color(1.0, 0.9, 0.4)
	sat_mat.emission_energy_multiplier = 1.2
	for i in n_sat:
		var s = MeshInstance3D.new()
		s.name = "Sat%d" % (i + 1)
		s.mesh = SphereMesh.new()
		s.mesh.radius = SAT_SCALE
		s.mesh.height = SAT_SCALE * 2.0
		s.material_override = sat_mat
		add_child(s)
		_satellites.append(s)

	# ISL 线
	_isl_a = isl_a
	_isl_b = isl_b
	var line_mat = StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.3, 0.9, 1.0, 0.6)
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for k in isl_a.size():
		var im = ImmediateMesh.new()
		var line = MeshInstance3D.new()
		line.name = "Isl%d" % (k + 1)
		line.mesh = im
		line.material_override = line_mat
		line.visible = false
		add_child(line)
		_isl_lines.append(line)
		_isl_meshes.append(im)

	_initialised = true

func update_frame(positions: PackedFloat32Array, isl_avail: PackedByteArray) -> void:
	if not _initialised:
		return
	# 卫星位置
	for i in _satellites.size():
		var p = i * 3
		var xkm = positions[p]
		var ykm = positions[p + 1]
		var zkm = positions[p + 2]
		_satellites[i].position = Vector3(
			xkm / SCALE_KM_PER_UNIT,
			zkm / SCALE_KM_PER_UNIT,    # 北极 → Godot Y
			-ykm / SCALE_KM_PER_UNIT    # 90°E → Godot -Z
		)

	# ISL 可见性 + 端点
	for k in _isl_lines.size():
		var avail = k < isl_avail.size() and isl_avail[k] != 0
		if not avail:
			if _isl_lines[k].visible:
				_isl_lines[k].visible = false
			continue
		_isl_lines[k].visible = true
		var a = _isl_a[k] - 1
		var b = _isl_b[k] - 1
		var pa = _satellites[a].position
		var pb = _satellites[b].position
		var im: ImmediateMesh = _isl_meshes[k]
		im.clear_surfaces()
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		im.surface_add_vertex(pa)
		im.surface_add_vertex(pb)
		im.surface_end()
