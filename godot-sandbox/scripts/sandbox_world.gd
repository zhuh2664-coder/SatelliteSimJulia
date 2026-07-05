extends Node3D
class_name SandboxWorld
# ============================================================
# SandboxWorld.gd — 3D 地球 + 卫星 + ISL 连线
# ============================================================
#
# Init(n_sat, isl_a, isl_b)：
#   - 建地球 Sphere（按 WGS84 半径 / 显示比例）
#   - 建地球参考网格
#   - 建 1 个 MultiMesh 批量绘制 N 个卫星 Sphere
#   - 建 2 条 ISL 批量线（可用/不可用各一个 ImmediateMesh）
#
# UpdateFrame(positions, isl_avail)：
#   - 更新每颗卫星 transform
#   - 更新每条 ISL 线的端点 + 可见性
#   - 可选更新轨迹拖尾和选中卫星高亮
#
# 坐标系：ECEF (X→0°赤道, Y→90°E, Z→北极) → Godot 左手系
#   Godot.X =  ECEF.X
#   Godot.Y =  ECEF.Z（北极朝上）
#   Godot.Z = -ECEF.Y
#   单位 1 unit = scale_km_per_unit km
# ============================================================

signal satellite_selected(info: Dictionary)
signal selection_cleared

const EARTH_EQUATORIAL_RADIUS_KM := 6378.137

# ── 可调参数（Inspector）────────────────────────────────
@export var scale_km_per_unit: float = 100.0   # 1 unit = ? km
@export var satellite_marker_radius_units: float = 0.4 # visual marker, not physical radius
@export var trail_max_frames: int = 30
@export var earth_color: Color = Color(0.20, 0.40, 0.85)
@export var earth_grid_color: Color = Color(0.75, 0.85, 1.0, 0.25)
@export var sat_color: Color = Color(1.0, 0.85, 0.3)
@export var sat_emission: Color = Color(1.0, 0.9, 0.4)
@export var selected_sat_color: Color = Color(1.0, 0.25, 0.15)
@export var isl_color: Color = Color(0.3, 0.9, 1.0, 0.6)
@export var isl_unavailable_color: Color = Color(0.4, 0.4, 0.45, 0.3)
@export var selected_isl_color: Color = Color(1.0, 0.45, 0.1, 0.9)
@export var trail_color: Color = Color(1.0, 0.85, 0.3, 0.22)
@export var ground_uncovered_color: Color = Color(0.55, 0.15, 0.10)
@export var ground_covered_color: Color = Color(0.1, 1.0, 0.35)
@export var gsl_color: Color = Color(0.4, 1.0, 0.45, 0.65)
@export var isl_pulse_speed: float = 2.0            # M4.2: cycles per second
@export var isl_pulse_min_alpha: float = 0.4
@export var isl_pulse_max_alpha: float = 0.9

var _earth: MeshInstance3D
var _earth_grid_mesh: ImmediateMesh
var _earth_grid_instance: MeshInstance3D
var _satellite_multimesh: MultiMesh
var _satellite_positions: PackedVector3Array = []
var _satellite_positions_ecef: PackedVector3Array = []
var _isl_available_mesh: ImmediateMesh
var _isl_unavailable_mesh: ImmediateMesh
var _isl_available_instance: MeshInstance3D
var _isl_unavailable_instance: MeshInstance3D
var _isl_available_material: StandardMaterial3D
var _trail_mesh: ImmediateMesh
var _trail_instance: MeshInstance3D
var _selected_marker: MeshInstance3D
var _selected_isl_mesh: ImmediateMesh
var _selected_isl_instance: MeshInstance3D
var _ground_station_root: Node3D
var _ground_station_nodes: Array = []
var _ground_station_positions: PackedVector3Array = []
var _gsl_mesh: ImmediateMesh
var _gsl_instance: MeshInstance3D
var _isl_a: PackedInt32Array
var _isl_b: PackedInt32Array
var _last_isl_avail: PackedByteArray
var _trail_history: Array = []
var _selected_satellite: int = -1
var _initialised: bool = false
var _show_isl: bool = true
var _show_unavailable_isl: bool = true
var _show_trails: bool = false
var _show_earth_grid: bool = true
var _show_ground_stations: bool = true
var _show_gsl: bool = true
var _show_coverage_heat: bool = true

func is_initialised() -> bool:
	return _initialised

func init(n_sat: int, isl_a: PackedInt32Array, isl_b: PackedInt32Array) -> void:
	_clear_generated_nodes()
	_build_earth()
	_build_earth_grid()
	_build_satellites(n_sat)
	_build_isl_lines(isl_a, isl_b)
	_build_trails()
	_build_selection_marker()
	_build_ground_layer()
	_initialised = true


# ── 子方法：建场景对象 ─────────────────────────────────

func _clear_generated_nodes() -> void:
	for name in ["Earth", "EarthGrid", "Satellites", "IslAvailable", "IslUnavailable", "Trails", "SelectedSatellite", "SelectedIsl", "GroundStations", "GslLinks"]:
		var n = get_node_or_null(NodePath(name))
		if n != null:
			remove_child(n)
			n.queue_free()
	_initialised = false
	_selected_satellite = -1
	_trail_history.clear()
	_ground_station_nodes.clear()
	_ground_station_positions = PackedVector3Array()
	_last_isl_avail = PackedByteArray()

func _build_earth() -> void:
	_earth = MeshInstance3D.new()
	_earth.name = "Earth"
	_earth.mesh = SphereMesh.new()
	var earth_radius_units = EARTH_EQUATORIAL_RADIUS_KM / scale_km_per_unit
	_earth.mesh.radius = earth_radius_units
	_earth.mesh.height = earth_radius_units * 2.0
	var earth_mat = StandardMaterial3D.new()
	earth_mat.albedo_color = earth_color
	_earth.material_override = earth_mat
	add_child(_earth)

func _build_earth_grid() -> void:
	_earth_grid_mesh = ImmediateMesh.new()
	var radius = EARTH_EQUATORIAL_RADIUS_KM / scale_km_per_unit * 1.002
	var segments = 96
	_earth_grid_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for lat_deg in [-60, -30, 0, 30, 60]:
		for s in segments:
			_earth_grid_mesh.surface_add_vertex(_sphere_point(radius, float(lat_deg), 360.0 * float(s) / float(segments)))
			_earth_grid_mesh.surface_add_vertex(_sphere_point(radius, float(lat_deg), 360.0 * float(s + 1) / float(segments)))
	for lon_deg in range(0, 180, 30):
		for s in segments:
			var lat0 = -90.0 + 180.0 * float(s) / float(segments)
			var lat1 = -90.0 + 180.0 * float(s + 1) / float(segments)
			_earth_grid_mesh.surface_add_vertex(_sphere_point(radius, lat0, float(lon_deg)))
			_earth_grid_mesh.surface_add_vertex(_sphere_point(radius, lat1, float(lon_deg)))
	_earth_grid_mesh.surface_end()

	_earth_grid_instance = MeshInstance3D.new()
	_earth_grid_instance.name = "EarthGrid"
	_earth_grid_instance.mesh = _earth_grid_mesh
	_earth_grid_instance.material_override = _line_material(earth_grid_color)
	_earth_grid_instance.visible = _show_earth_grid
	add_child(_earth_grid_instance)

func _sphere_point(radius: float, lat_deg: float, lon_deg: float) -> Vector3:
	var lat = deg_to_rad(lat_deg)
	var lon = deg_to_rad(lon_deg)
	return Vector3(
		radius * cos(lat) * cos(lon),
		radius * sin(lat),
		-radius * cos(lat) * sin(lon)
	)

func _build_satellites(n_sat: int) -> void:
	# M7.4: 1 个 MultiMeshInstance3D 批量绘制卫星，避免大星座 N 个节点。
	# 卫星球体是视觉标记；真实空间比例由 ECEF 位置和地球半径保证。
	var sat_mesh = SphereMesh.new()
	sat_mesh.radius = satellite_marker_radius_units
	sat_mesh.height = satellite_marker_radius_units * 2.0

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
	_satellite_positions_ecef.resize(n_sat)

	var inst = MultiMeshInstance3D.new()
	inst.name = "Satellites"
	inst.multimesh = _satellite_multimesh
	add_child(inst)

func _build_isl_lines(isl_a: PackedInt32Array, isl_b: PackedInt32Array) -> void:
	_isl_a = isl_a
	_isl_b = isl_b

	_isl_available_mesh = ImmediateMesh.new()
	_isl_unavailable_mesh = ImmediateMesh.new()

	_isl_available_material = _line_material(isl_color)
	var unavailable_mat = _line_material(isl_unavailable_color)

	_isl_available_instance = MeshInstance3D.new()
	_isl_available_instance.name = "IslAvailable"
	_isl_available_instance.mesh = _isl_available_mesh
	_isl_available_instance.material_override = _isl_available_material
	_isl_available_instance.visible = _show_isl
	add_child(_isl_available_instance)

	_isl_unavailable_instance = MeshInstance3D.new()
	_isl_unavailable_instance.name = "IslUnavailable"
	_isl_unavailable_instance.mesh = _isl_unavailable_mesh
	_isl_unavailable_instance.material_override = unavailable_mat
	_isl_unavailable_instance.visible = _show_unavailable_isl
	add_child(_isl_unavailable_instance)

func _build_trails() -> void:
	_trail_mesh = ImmediateMesh.new()
	_set_degenerate_line(_trail_mesh)
	_trail_instance = MeshInstance3D.new()
	_trail_instance.name = "Trails"
	_trail_instance.mesh = _trail_mesh
	_trail_instance.material_override = _line_material(trail_color)
	_trail_instance.visible = _show_trails
	add_child(_trail_instance)

func _build_selection_marker() -> void:
	var marker_mesh = SphereMesh.new()
	marker_mesh.radius = satellite_marker_radius_units * 1.8
	marker_mesh.height = satellite_marker_radius_units * 3.6
	var marker_mat = StandardMaterial3D.new()
	marker_mat.albedo_color = selected_sat_color
	marker_mat.emission_enabled = true
	marker_mat.emission = selected_sat_color
	marker_mat.emission_energy_multiplier = 1.5
	marker_mesh.material = marker_mat

	_selected_marker = MeshInstance3D.new()
	_selected_marker.name = "SelectedSatellite"
	_selected_marker.mesh = marker_mesh
	_selected_marker.visible = false
	add_child(_selected_marker)

	_selected_isl_mesh = ImmediateMesh.new()
	_set_degenerate_line(_selected_isl_mesh)
	_selected_isl_instance = MeshInstance3D.new()
	_selected_isl_instance.name = "SelectedIsl"
	_selected_isl_instance.mesh = _selected_isl_mesh
	_selected_isl_instance.material_override = _line_material(selected_isl_color)
	_selected_isl_instance.visible = false
	add_child(_selected_isl_instance)

func _build_ground_layer() -> void:
	_ground_station_root = Node3D.new()
	_ground_station_root.name = "GroundStations"
	_ground_station_root.visible = _show_ground_stations
	add_child(_ground_station_root)

	_gsl_mesh = ImmediateMesh.new()
	_set_degenerate_line(_gsl_mesh)
	_gsl_instance = MeshInstance3D.new()
	_gsl_instance.name = "GslLinks"
	_gsl_instance.mesh = _gsl_mesh
	_gsl_instance.material_override = _line_material(gsl_color)
	_gsl_instance.visible = _show_gsl
	add_child(_gsl_instance)

func _set_degenerate_line(im: ImmediateMesh) -> void:
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(Vector3.ZERO)
	im.surface_add_vertex(Vector3.ZERO)
	im.surface_end()

func _line_material(color: Color) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	return mat

func update_frame(positions: PackedFloat32Array, isl_avail: PackedByteArray, ground_stations: Array = [], gsl_pairs: Array = [], coverage_summary: Dictionary = {}) -> void:
	if not _initialised:
		return
	_last_isl_avail = isl_avail
	# 卫星位置
	for i in _satellite_positions.size():
		var p = i * 3
		var ecef = Vector3(positions[p], positions[p + 1], positions[p + 2])
		var pos = ecef_km_to_unity(ecef.x, ecef.y, ecef.z)
		_satellite_positions_ecef[i] = ecef
		_satellite_positions[i] = pos
		_satellite_multimesh.set_instance_transform(i, Transform3D(Basis(), pos))

	_update_trails()
	_update_isl_meshes(isl_avail)
	_update_ground_layer(ground_stations, gsl_pairs, coverage_summary)
	_update_selection_visual()

func _update_isl_meshes(isl_avail: PackedByteArray) -> void:
	# ISL 颜色 + 端点（M7.4: 可用/不可用各一个批量 mesh）
	var available_vertices = PackedVector3Array()
	var unavailable_vertices = PackedVector3Array()
	for k in _isl_a.size():
		var avail = k < isl_avail.size() and isl_avail[k] != 0
		var a = _isl_a[k] - 1
		var b = _isl_b[k] - 1
		var pa = _satellite_positions[a]
		var pb = _satellite_positions[b]
		if avail:
			available_vertices.append(pa)
			available_vertices.append(pb)
		else:
			unavailable_vertices.append(pa)
			unavailable_vertices.append(pb)
	_rebuild_isl_mesh(_isl_available_mesh, available_vertices)
	_rebuild_isl_mesh(_isl_unavailable_mesh, unavailable_vertices)

func _update_trails() -> void:
	var sample = PackedVector3Array()
	for p in _satellite_positions:
		sample.append(p)
	_trail_history.append(sample)
	while _trail_history.size() > max(1, trail_max_frames):
		_trail_history.pop_front()
	if _show_trails:
		_rebuild_trail_mesh()

func _rebuild_trail_mesh() -> void:
	_trail_mesh.clear_surfaces()
	if _trail_history.size() < 2:
		_set_degenerate_line(_trail_mesh)
		return
	_trail_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var n_sat = _satellite_positions.size()
	for t in range(1, _trail_history.size()):
		var prev: PackedVector3Array = _trail_history[t - 1]
		var curr: PackedVector3Array = _trail_history[t]
		for i in n_sat:
			_trail_mesh.surface_add_vertex(prev[i])
			_trail_mesh.surface_add_vertex(curr[i])
	_trail_mesh.surface_end()

func _rebuild_isl_mesh(im: ImmediateMesh, vertices: PackedVector3Array) -> void:
	im.clear_surfaces()
	if vertices.is_empty():
		_set_degenerate_line(im)
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for v in vertices:
		im.surface_add_vertex(v)
	im.surface_end()

func _update_ground_layer(ground_stations: Array, gsl_pairs: Array, _coverage_summary: Dictionary) -> void:
	if ground_stations.is_empty():
		_set_degenerate_line(_gsl_mesh)
		return
	if _ground_station_nodes.size() != ground_stations.size():
		_rebuild_ground_stations(ground_stations)
	_update_ground_heat(gsl_pairs)
	_rebuild_gsl_mesh(gsl_pairs)

func _rebuild_ground_stations(ground_stations: Array) -> void:
	for n in _ground_station_nodes:
		n.queue_free()
	_ground_station_nodes.clear()
	_ground_station_positions = PackedVector3Array()
	for i in ground_stations.size():
		var gs = ground_stations[i]
		var ecef = gs.get("ecef_km", [])
		if ecef.size() < 3:
			continue
		var pos = ecef_km_to_unity(float(ecef[0]), float(ecef[1]), float(ecef[2]))
		_ground_station_positions.append(pos)
		var marker = MeshInstance3D.new()
		marker.name = "Ground_%s" % str(gs.get("id", i + 1))
		var mesh = SphereMesh.new()
		mesh.radius = satellite_marker_radius_units * 1.2
		mesh.height = satellite_marker_radius_units * 2.4
		marker.mesh = mesh
		marker.position = pos
		marker.material_override = _ground_material(ground_uncovered_color, 0.8)
		_ground_station_root.add_child(marker)
		_ground_station_nodes.append(marker)

func _update_ground_heat(gsl_pairs: Array) -> void:
	var counts: Array[int] = []
	for _i in _ground_station_nodes.size():
		counts.append(0)
	for pair in gsl_pairs:
		if pair.size() >= 2:
			var g = int(pair[1]) - 1
			if g >= 0 and g < counts.size():
				counts[g] += 1
	for i in _ground_station_nodes.size():
		var marker: MeshInstance3D = _ground_station_nodes[i]
		var covered = counts[i] > 0
		var intensity = clamp(float(counts[i]) / 4.0, 0.0, 1.0)
		var color = ground_covered_color.lerp(Color(1.0, 1.0, 0.2), intensity) if covered else ground_uncovered_color
		marker.material_override = _ground_material(color if _show_coverage_heat else (ground_covered_color if covered else ground_uncovered_color), 1.0 if covered else 0.75)
		marker.scale = Vector3.ONE * (1.0 + 0.8 * intensity if _show_coverage_heat else 1.0)

func _rebuild_gsl_mesh(gsl_pairs: Array) -> void:
	var vertices = PackedVector3Array()
	for pair in gsl_pairs:
		if pair.size() < 2:
			continue
		var sat = int(pair[0]) - 1
		var ground = int(pair[1]) - 1
		if sat >= 0 and sat < _satellite_positions.size() and ground >= 0 and ground < _ground_station_positions.size():
			vertices.append(_satellite_positions[sat])
			vertices.append(_ground_station_positions[ground])
	_rebuild_isl_mesh(_gsl_mesh, vertices)

func _ground_material(color: Color, energy: float) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat


# ── 交互选择 ─────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not _initialised:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_pick_satellite(event.position)

func _pick_satellite(screen_pos: Vector2) -> void:
	var camera = get_viewport().get_camera_3d()
	if camera == null:
		return
	var origin = camera.project_ray_origin(screen_pos)
	var dir = camera.project_ray_normal(screen_pos).normalized()
	var best_idx = -1
	var best_dist = INF
	var threshold = max(1.5, satellite_marker_radius_units * 4.0)
	for i in _satellite_positions.size():
		var pos = _satellite_positions[i]
		var along = (pos - origin).dot(dir)
		if along < 0.0:
			continue
		var closest = origin + dir * along
		var dist = pos.distance_to(closest)
		if dist < best_dist:
			best_dist = dist
			best_idx = i
	if best_idx >= 0 and best_dist <= threshold:
		select_satellite(best_idx + 1)
	else:
		clear_selection()

func select_satellite(sat_id: int) -> void:
	var idx = sat_id - 1
	if idx < 0 or idx >= _satellite_positions.size():
		clear_selection()
		return
	_selected_satellite = idx
	_update_selection_visual()

func clear_selection() -> void:
	_selected_satellite = -1
	if _selected_marker != null:
		_selected_marker.visible = false
	if _selected_isl_mesh != null:
		_set_degenerate_line(_selected_isl_mesh)
	if _selected_isl_instance != null:
		_selected_isl_instance.visible = false
	selection_cleared.emit()

func _update_selection_visual() -> void:
	if _selected_satellite < 0 or _selected_satellite >= _satellite_positions.size():
		return
	_selected_marker.position = _satellite_positions[_selected_satellite]
	_selected_marker.visible = true
	var vertices = PackedVector3Array()
	for k in _isl_a.size():
		var a = _isl_a[k] - 1
		var b = _isl_b[k] - 1
		if a == _selected_satellite or b == _selected_satellite:
			vertices.append(_satellite_positions[a])
			vertices.append(_satellite_positions[b])
	_rebuild_isl_mesh(_selected_isl_mesh, vertices)
	_selected_isl_instance.visible = not vertices.is_empty()
	if _selected_satellite < _satellite_positions_ecef.size():
		satellite_selected.emit(_selected_info())

func _selected_info() -> Dictionary:
	var ecef = _satellite_positions_ecef[_selected_satellite]
	var connected = 0
	for k in _isl_a.size():
		var a = _isl_a[k] - 1
		var b = _isl_b[k] - 1
		var avail = k < _last_isl_avail.size() and _last_isl_avail[k] != 0
		if avail and (a == _selected_satellite or b == _selected_satellite):
			connected += 1
	return {
		"id": _selected_satellite + 1,
		"godot": _satellite_positions[_selected_satellite],
		"ecef_km": ecef,
		"altitude_km": ecef.length() - EARTH_EQUATORIAL_RADIUS_KM,
		"connected_isl": connected,
	}

# ── 显示开关 ─────────────────────────────────────────────

func set_show_isl(enabled: bool) -> void:
	_show_isl = enabled
	if _isl_available_instance != null:
		_isl_available_instance.visible = enabled

func set_show_unavailable_isl(enabled: bool) -> void:
	_show_unavailable_isl = enabled
	if _isl_unavailable_instance != null:
		_isl_unavailable_instance.visible = enabled

func set_show_trails(enabled: bool) -> void:
	_show_trails = enabled
	if _trail_instance != null:
		_trail_instance.visible = enabled
	if _trail_mesh != null:
		if enabled:
			_rebuild_trail_mesh()
		else:
			_set_degenerate_line(_trail_mesh)

func set_show_earth_grid(enabled: bool) -> void:
	_show_earth_grid = enabled
	if _earth_grid_instance != null:
		_earth_grid_instance.visible = enabled

func set_show_ground_stations(enabled: bool) -> void:
	_show_ground_stations = enabled
	if _ground_station_root != null:
		_ground_station_root.visible = enabled

func set_show_gsl(enabled: bool) -> void:
	_show_gsl = enabled
	if _gsl_instance != null:
		_gsl_instance.visible = enabled

func set_show_coverage_heat(enabled: bool) -> void:
	_show_coverage_heat = enabled


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
	var c = isl_color
	c.a = alpha
	_isl_available_material.albedo_color = c


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
