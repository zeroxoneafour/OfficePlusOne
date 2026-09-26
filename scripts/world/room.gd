extends Node3D
## The office room (scenes/world/room.tscn). Walls/floor/ceiling are built
## from the replicated size (each is paintable). Whiteboards, calendars and
## the like are wall widgets (see the Widgets autoload). (Room controls live
## on the watch.)

const WALL_T := 0.2

var state := {}
var _built_size := Vector3.ZERO


func apply(s: Dictionary) -> void:
	state = s
	var size := Office.size()
	if size != _built_size:
		_built_size = size
		_build_shell(size)
		%Light.position.y = size.y - 0.3
		%Light.omni_range = maxf(size.x, size.z) * 1.2
		%OfficeName.position = Vector3(0, size.y - 0.35, size.z * 0.5 - 0.02)
	%OfficeName.text = str(s.get("name", ""))
	_apply_colors()


func _build_shell(size: Vector3) -> void:
	for c in %Shell.get_children():
		%Shell.remove_child(c) # (now, so the new walls get their names)
		c.queue_free()
	var w := size.x
	var h := size.y
	var d := size.z
	_surface("floor", Vector3(w + WALL_T * 2, WALL_T, d + WALL_T * 2), Vector3(0, -WALL_T * 0.5, 0))
	_surface("ceiling", Vector3(w + WALL_T * 2, WALL_T, d + WALL_T * 2), Vector3(0, h + WALL_T * 0.5, 0))
	_surface("north", Vector3(w, h, WALL_T), Vector3(0, h * 0.5, -d * 0.5 - WALL_T * 0.5))
	_surface("south", Vector3(w, h, WALL_T), Vector3(0, h * 0.5, d * 0.5 + WALL_T * 0.5))
	_surface("west", Vector3(WALL_T, h, d), Vector3(-w * 0.5 - WALL_T * 0.5, h * 0.5, 0))
	_surface("east", Vector3(WALL_T, h, d), Vector3(w * 0.5 + WALL_T * 0.5, h * 0.5, 0))


func _surface(surface_name: String, size: Vector3, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = surface_name
	body.position = pos
	body.collision_layer = NetBody.LAYER_WORLD
	body.collision_mask = 0
	body.set_meta("surface", surface_name)
	Mk.box(body, size, Color.WHITE, Vector3.ZERO, true)
	%Shell.add_child(body)


func _apply_colors() -> void:
	var colors: Dictionary = state.get("colors", {})
	for body in %Shell.get_children():
		if body.is_queued_for_deletion():
			continue
		var mi: MeshInstance3D = body.get_child(0)
		mi.material_override = Mk.mat(Mk.color(colors.get(body.get_meta("surface")), Color("#dddddd")))
