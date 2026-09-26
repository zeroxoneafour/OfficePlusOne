class_name TvWidget extends Widget
## A wall TV (scenes/widgets/tv.tscn): shows someone's computer screen over
## VNC (no mouse). Menu → Connect… to pick the computer; the Keyboard button
## shows a live keyboard that types on it. Shares its screen
## code with desk monitors (see RemoteDisplay).
## data: {vnc: {host, port, password, by}}


func _widget_build() -> void:
	%KeyboardButton.pressed.connect(func():
		RemoteDisplay.toggle_keyboard(get_tree().get_first_node_in_group("local_player"), self))
	%Screen.screen_size = size - Vector2(0.04, 0.1)
	RemoteDisplay.apply(%Screen, data.get("vnc"))


func _widget_data(key: String, value: Variant) -> void:
	if key == "vnc" and is_node_ready():
		RemoteDisplay.apply(%Screen, value)


func widget_menu_items(menu: RadialMenu) -> Array:
	return RemoteDisplay.menu_items(menu, self)


func op_perm(op: String) -> String:
	return RemoteDisplay.op_perm(op)


func server_op(peer: int, op: String, args: Dictionary) -> String:
	if RemoteDisplay.op_perm(op) == "":
		return ""
	var msg := RemoteDisplay.server_op(self, peer, args, op)
	if not msg.begins_with("Error"):
		AI.widget_note("%s: TV \"%s\" is now %s." % [Widgets._who(peer), widget_name(), RemoteDisplay.describe(data.get("vnc"))])
	return msg


func ai_summary() -> String:
	return RemoteDisplay.describe(data.get("vnc")) + " (you can't see the picture)"
