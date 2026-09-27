class_name FloatingScreen extends NetBody
## A floating monitor (scenes/entities/floating_screen.tscn): a screen that
## shows someone's computer over VNC, like a TV or monitor (see
## RemoteDisplay), but that hangs in the air wherever you put it. No physics
## at all: grab it and it follows your hand exactly; let go and it stays
## there. No gravity, no inertia, and it doesn't bump into anything. Its
## menu: Connect…, Keyboard, Grab, Rotate, Lock, Delete; the Keyboard
## button under it shows a live keyboard for the computer.
## data: {vnc: {host, port, password, by}, locked}


func _build() -> void:
	%KeyboardButton.pressed.connect(func():
		RemoteDisplay.toggle_keyboard(get_tree().get_first_node_in_group("local_player"), self))
	RemoteDisplay.apply(%Screen, data.get("vnc"))


func _data_changed(key: String, value: Variant) -> void:
	if key == "vnc" and is_node_ready():
		RemoteDisplay.apply(%Screen, value)


## Always floating: never collides (hands and rays still find it) and never
## moves on its own; on the server it's moved only by the hand holding it.
func _refresh_physics_state() -> void:
	collision_layer = LAYER_FLOATING if not is_stowed() else 0
	collision_mask = 0
	gravity_scale = 0.0
	freeze = true


func is_parked() -> bool:
	return true


func server_grab(peer: int, hand: int, offset: Transform3D) -> void:
	super(peer, hand, offset)
	freeze = true # moved by transform below, not by physics


func server_release(_lin_vel: Vector3, _ang_vel: Vector3) -> void:
	held_by = 0 # stays exactly where it was let go: no throw, no fall


func _physics_process(_delta: float) -> void:
	if not is_server_side or held_by == 0:
		return
	var h: Variant = Sync.hand_xform_smooth(held_by, _hold_hand)
	if h is Transform3D:
		global_transform = (h as Transform3D) * _hold_offset


func menu_items(menu: RadialMenu) -> Array:
	return RemoteDisplay.menu_items(menu, self)


func op_perm(op: String) -> String:
	return RemoteDisplay.op_perm(op)


func server_op(peer: int, op: String, args: Dictionary) -> String:
	return RemoteDisplay.server_op(self, peer, args, op) if RemoteDisplay.op_perm(op) != "" else ""
