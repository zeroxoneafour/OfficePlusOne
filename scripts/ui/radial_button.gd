class_name RadialButton extends PokeButton
## A radial menu's button (scenes/ui/radial_button.tscn). Menus use pie
## slices (make_slice): each fills its sector of the disc from the round
## Cancel button in the middle out to the rim, like a pie menu, so they're big
## targets for fingers and rays. The scene on its own is a small round button
## (the Cancel button). Poke it with a fingertip, pinch/trigger while your
## pointer ray is on it, or click it in desktop mode.

const RADIAL_SCENE_PATH := "res://scenes/ui/radial_button.tscn"
## Gap (m) between neighbouring slices.
const GAP := 0.005
const ARC_STEP := deg_to_rad(6.0)
const BASE_COLOR := Color("#1e2027")

## Slice geometry (angles in radians, counter-clockwise from +X; radii in m).
var slice := false
var angle_from := 0.0
var angle_to := 0.0
var inner := 0.0
var outer := 0.0


## A pie slice of the menu disc from `from_angle` to `to_angle`, between the
## radii `r_in` and `r_out`. Its origin is the menu's centre.
static func make_slice(parent: Node, label_text: String, from_angle: float, to_angle: float, r_in: float, r_out: float, c := Color("#3d85c6")) -> RadialButton:
	var b: RadialButton = load(RADIAL_SCENE_PATH).instantiate()
	b.text = label_text
	b.color = c
	b.slice = true
	b.angle_from = from_angle
	b.angle_to = to_angle
	b.inner = r_in
	b.outer = r_out
	parent.add_child(b)
	return b


## The middle of the slice's face (local), e.g. to put things on it.
func face_center() -> Vector3:
	if not slice:
		return Vector3(0, 0, CAP_FACE)
	var mid := (angle_from + angle_to) * 0.5
	return Vector3(cos(mid), sin(mid), 0) * (inner + outer) * 0.5 + Vector3(0, 0, CAP_FACE)


func _apply_size() -> void:
	if not slice:
		return # the scene's round button
	# Pull each edge in by half the gap (as an angle at that radius).
	var pad_in := GAP * 0.5 / maxf(inner, 0.01)
	var pad_out := GAP * 0.5 / outer
	$Base.transform = Transform3D.IDENTITY
	$Base.mesh = _sector(inner, outer, angle_from + pad_out * 0.5, angle_to - pad_out * 0.5, -BASE_DEPTH, BASE_DEPTH, BASE_COLOR)
	_cap.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, CAP_FACE - CAP_DEPTH))
	_cap.mesh = _sector(inner + 0.004, outer - 0.004, angle_from + maxf(pad_in, pad_out) + 0.004 / outer, angle_to - maxf(pad_in, pad_out) - 0.004 / outer, 0.0, CAP_DEPTH, Color.WHITE)
	# Collision: convex wedges (a sector wider than ~45° isn't convex enough in one piece).
	$Shape.queue_free()
	var pieces := maxi(1, ceili((angle_to - angle_from) / deg_to_rad(45.0)))
	for i in pieces:
		var a0 := lerpf(angle_from, angle_to, float(i) / pieces)
		var a1 := lerpf(angle_from, angle_to, float(i + 1) / pieces)
		var pts := PackedVector3Array()
		for a in [a0, (a0 + a1) * 0.5, a1]:
			for r in [inner, outer]:
				for z in [PRESS_BACK, PRESS_FRONT]:
					pts.append(Vector3(cos(a) * r, sin(a) * r, z))
		var shape := ConvexPolygonShape3D.new()
		shape.points = pts
		var cs := CollisionShape3D.new()
		cs.shape = shape
		add_child(cs)
	# Label in the middle of the slice, as wide as the slice there.
	var mid := (angle_from + angle_to) * 0.5
	var rm := (inner + outer) * 0.5
	_label.position = Vector3(cos(mid) * rm, sin(mid) * rm, CAP_FACE + 0.0008)
	var arc := minf((angle_to - angle_from) * rm, outer - inner + 0.04)
	_label.width = maxf(arc * 0.85, 0.05) / _label.pixel_size


func _face_contains(p: Vector2, margin: float) -> bool:
	if not slice:
		return p.length() <= 0.05 + margin
	var r := p.length()
	if r < inner - margin or r > outer + margin:
		return false
	var slack := margin / maxf(r, 0.01)
	var a := fposmod(p.angle() - angle_from + slack, TAU)
	return a <= (angle_to - angle_from) + slack * 2.0


## A flat annular sector facing +Z, `h` thick, from z0.
static func _sector(r0: float, r1: float, a0: float, a1: float, z0: float, h: float, c: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := maxi(1, ceili((a1 - a0) / ARC_STEP))
	var z1 := z0 + h
	for i in steps:
		var ta := lerpf(a0, a1, float(i) / steps)
		var tb := lerpf(a0, a1, float(i + 1) / steps)
		var ia := Vector3(cos(ta) * r0, sin(ta) * r0, 0)
		var oa := Vector3(cos(ta) * r1, sin(ta) * r1, 0)
		var ib := Vector3(cos(tb) * r0, sin(tb) * r0, 0)
		var ob := Vector3(cos(tb) * r1, sin(tb) * r1, 0)
		var up := Vector3(0, 0, z1)
		# Top face (counter-clockwise seen from +Z).
		_quad(st, ia + up, oa + up, ob + up, ib + up)
		# Outer and inner rims.
		_quad(st, oa + Vector3(0, 0, z0), ob + Vector3(0, 0, z0), ob + up, oa + up)
		_quad(st, ib + Vector3(0, 0, z0), ia + Vector3(0, 0, z0), ia + up, ib + up)
	# Side walls at the two ends.
	for t in [[a0, true], [a1, false]]:
		var a: float = t[0]
		var i0 := Vector3(cos(a) * r0, sin(a) * r0, z0)
		var o0 := Vector3(cos(a) * r1, sin(a) * r1, z0)
		if t[1]:
			_quad(st, i0, o0, o0 + Vector3(0, 0, h), i0 + Vector3(0, 0, h))
		else:
			_quad(st, o0, i0, i0 + Vector3(0, 0, h), o0 + Vector3(0, 0, h))
	st.generate_normals()
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, m)
	return mesh


## Two triangles a-b-c, a-c-d (winding chosen so the face points outward).
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for v in [a, c, b, a, d, c]:
		st.add_vertex(v)
