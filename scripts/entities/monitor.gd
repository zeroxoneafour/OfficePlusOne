class_name Monitor extends Prop
## A desk monitor (scenes/entities/props/monitor.tscn): furniture that shows
## someone's computer read-only over VNC, like a wall TV (see RemoteDisplay).
## Point at it and pull back → Connect… / Disconnect.
## data: {vnc: {host, port, password, by}, locked}


func _build() -> void:
	super()
	%KeyboardButton.pressed.connect(func():
		RemoteDisplay.toggle_keyboard(get_tree().get_first_node_in_group("local_player"), self))
	RemoteDisplay.apply(%Screen, data.get("vnc"))


func _data_changed(key: String, value: Variant) -> void:
	super(key, value)
	if key == "vnc" and is_node_ready():
		RemoteDisplay.apply(%Screen, value)


func menu_items(menu: RadialMenu) -> Array:
	return RemoteDisplay.menu_items(menu, self)


func op_perm(op: String) -> String:
	return RemoteDisplay.op_perm(op)


func server_op(peer: int, op: String, args: Dictionary) -> String:
	return RemoteDisplay.server_op(self, peer, args, op) if RemoteDisplay.op_perm(op) != "" else ""
