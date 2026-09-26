class_name Mk extends RefCounted
## Tiny helpers for building barebones geometry in code.

static var _mats := {}


static func mat(color: Color, emission := 0.0, unshaded := false) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [color.to_html(), emission, unshaded]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.8
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mats[key] = m
	return m


static func color(v: Variant, fallback := Color.WHITE) -> Color:
	if v is Color:
		return v
	if v is String and Color.html_is_valid(v):
		return Color.html(v)
	return fallback


static func box(parent: Node, size: Vector3, c: Color, pos := Vector3.ZERO, collide := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat(c)
	mi.position = pos
	parent.add_child(mi)
	if collide:
		shape(parent, _box_shape(size), pos)
	return mi


static func sphere(parent: Node, radius: float, c: Color, pos := Vector3.ZERO, collide := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 16
	m.rings = 8
	mi.mesh = m
	mi.material_override = mat(c)
	mi.position = pos
	parent.add_child(mi)
	if collide:
		var s := SphereShape3D.new()
		s.radius = radius
		shape(parent, s, pos)
	return mi


static func cylinder(parent: Node, radius: float, height: float, c: Color, pos := Vector3.ZERO, collide := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = 16
	mi.mesh = m
	mi.material_override = mat(c)
	mi.position = pos
	parent.add_child(mi)
	if collide:
		var s := CylinderShape3D.new()
		s.radius = radius
		s.height = height
		shape(parent, s, pos)
	return mi


static func shape(parent: Node, s: Shape3D, pos := Vector3.ZERO) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	cs.shape = s
	cs.position = pos
	parent.add_child(cs)
	return cs


static func _box_shape(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


static func label(parent: Node, text: String, font_size := 48, pos := Vector3.ZERO, width_px := 0.0) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = font_size
	l.outline_size = 8
	l.pixel_size = 0.001
	l.position = pos
	if width_px > 0.0:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.width = width_px
	parent.add_child(l)
	return l


## A textured quad facing +Z.
static func quad(parent: Node, size: Vector2, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)
	return mi


## Debug axes (X red, Y green, Z blue, `length` m) under `parent`, drawn on top.
static func axes(parent: Node, length := 0.08) -> Node3D:
	var root := Node3D.new()
	root.name = "DebugAxes"
	for a in [[Vector3.RIGHT, Color.RED], [Vector3.UP, Color.GREEN], [Vector3.BACK, Color.BLUE]]:
		var dir: Vector3 = a[0]
		var mi := MeshInstance3D.new()
		var m := BoxMesh.new()
		m.size = Vector3.ONE * 0.004 + dir.abs() * length
		mi.mesh = m
		var mat := StandardMaterial3D.new()
		mat.albedo_color = a[1]
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		mi.material_override = mat
		mi.position = dir * length * 0.5
		root.add_child(mi)
	parent.add_child(root)
	return root
