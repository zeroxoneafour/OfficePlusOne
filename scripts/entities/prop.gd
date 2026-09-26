class_name Prop extends NetBody
## Furniture and toys (scenes/entities/props/*.tscn). Meshes in the "tint"
## group take the entity's color. Paint balls recolor whatever surface they
## hit, if the person who threw them may decorate. Chairs can be sat on and
## lamps switched on/off (trigger on them in VR, E on desktop).

var _paint_cooldown := 0.0
var _last_speed := 0.0
var _seated_me := false


func _build() -> void:
	if data.has("color"):
		var c := Mk.color(data["color"])
		for m in find_children("*", "MeshInstance3D"):
			if m.is_in_group("tint"):
				m.material_override = Mk.mat(c, 0.3 if kind == "paint" else 0.0)
	if is_server_side and kind == "paint":
		contact_monitor = true
		max_contacts_reported = 2
		body_entered.connect(_on_paint_hit)


func _data_changed(key: String, value: Variant) -> void:
	match key:
		"seated":
			# Tell the local player when they sit down on / get up from this chair.
			var mine := int(value) == Net.my_id() and Net.has_local_player()
			if mine != _seated_me:
				_seated_me = mine
				Sync.seated_changed.emit(self if mine else null)
		"on":
			if has_node("Light"):
				$Light.visible = value == true
				$Bulb.material_override = Mk.mat(Color("#fff2c0"), 2.0 if value else 0.0)


func server_interact(peer: int) -> void:
	match kind:
		"chair":
			if int(data.get("seated", 0)) == peer:
				Sync.server_stand(peer)
			else:
				Sync.server_sit(peer, self)
		"lamp":
			Sync.set_data(entity_id, "on", data.get("on", true) != true)


func _process(delta: float) -> void:
	_paint_cooldown -= delta
	super(delta)


func _physics_process(delta: float) -> void:
	super(delta)
	_last_speed = linear_velocity.length()


func _on_paint_hit(body: Node) -> void:
	if _paint_cooldown > 0.0 or not body.has_meta("surface"):
		return
	# Paint when thrown or pressed against a surface by hand, not when just resting.
	if held_by == 0 and _last_speed < 3.5:
		return
	_paint_cooldown = 0.5
	if Net.can(last_holder, "decorate"):
		Office.paint(body.get_meta("surface"), str(data.get("color", "#ffffff")))
	else:
		Net.send_toast(last_holder, "Only admins can repaint this office.")
