class_name Widget extends NetBody
## Base for wall widgets (scenes/widgets/*.tscn): a framed panel fixed flat on
## a wall, facing +Z into the room, with its name along the top and a Menu
## button in the corner (the same menu you get by pointing at the widget and
## pulling back). It can't be picked up; it collides like a wall.
## data: {name, wall, u, h, …kind-specific}
##
## Subclasses override _widget_build(), _widget_data(), widget_menu_items(),
## and on the server server_added(), server_tick(), ai_summary() and the
## op_perm()/server_op() pair for what people and AIs can do with them.

## Face size (metres); the frame is a little bigger.
@export var size := Vector2(1, 0.6)


func _build() -> void:
	%MenuButton.pressed.connect(open_menu_here)
	_widget_build()


func _data_changed(key: String, value: Variant) -> void:
	if key == "name":
		%Name.text = str(value)
	_widget_data(key, value)


func _widget_build() -> void:
	pass


func _widget_data(_key: String, _value: Variant) -> void:
	pass


func widget_name() -> String:
	return str(data.get("name", ""))


func grabbable() -> bool:
	return false


## Mounted: never counts as something standing on the floor.
func is_parked() -> bool:
	return true


func _refresh_physics_state() -> void:
	collision_layer = LAYER_WORLD
	collision_mask = 0
	freeze = true


## Open this widget's context menu next to its Menu button.
func open_menu_here() -> void:
	var player := get_tree().get_first_node_in_group("local_player")
	if player:
		var at: Vector3 = %MenuButton.global_position + global_basis.z * 0.15
		player.open_context_menu({"type": "widget", "entity_id": entity_id, "point": at}, at)


## Client: this kind's items in the widget menu (Rename and Remove are added
## around them).
func widget_menu_items(_menu: RadialMenu) -> Array:
	return []


## A world position on the face from normalized coordinates (0,0 = top left).
func face_point(uv: Vector2) -> Vector3:
	return to_global(Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0.0))


# --- Server hooks ----------------------------------------------------------------------

## Just spawned by Widgets.server_add (spawn companions, e.g. markers).
func server_added() -> void:
	pass


## About to be removed.
func server_removing() -> void:
	pass


## Moved along with a resized wall.
func server_moved() -> void:
	pass


## About once a second, with the server's local date and time.
func server_tick(_now: Dictionary) -> void:
	pass


## One line for AIs: what's on it right now.
func ai_summary() -> String:
	return ""
