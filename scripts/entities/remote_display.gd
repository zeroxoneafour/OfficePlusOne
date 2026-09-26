class_name RemoteDisplay extends RefCounted
## What TVs (wall widget) and monitors (furniture) share: each has a VncScreen
## (scenes/vnc/vnc_screen.tscn) showing someone's computer over VNC. There's
## never any mouse control; its Keyboard button (and menu item) shows a live
## keyboard whose keys go straight to that computer (sent by the typing
## person's own app, which has its own VNC connection).
## The address lives in the entity's data ("vnc": {host, port, password}) and
## every player's app connects to it itself, so the computer must be reachable
## from each headset/PC in the room (e.g. the same network). Connect… and
## Disconnect are in the entity's context menu.

const DEFAULT_PORT := 5900


## Show (or stop showing) the computer in `vnc` on this peer's `screen`.
static func apply(screen: Node, vnc: Variant) -> void:
	if not screen or not Net.has_local_player():
		return # a dedicated server has nobody to show it to
	var want := ""
	if vnc is Dictionary and str(vnc.get("host", "")) != "":
		want = "%s:%d:%s" % [vnc["host"], int(vnc.get("port", DEFAULT_PORT)), vnc.get("password", "")]
	if screen.get_meta("showing", "") == want:
		return
	screen.set_meta("showing", want)
	if want == "":
		screen.clear_remote()
	else:
		screen.show_remote(str(vnc["host"]), int(vnc.get("port", DEFAULT_PORT)), str(vnc.get("password", "")))


static func is_connected_data(vnc: Variant) -> bool:
	return vnc is Dictionary and str(vnc.get("host", "")) != ""


## Context menu items: Connect… (address, then password, on the keyboard) and Disconnect.
static func menu_items(menu: RadialMenu, e: NetBody) -> Array:
	var id := e.entity_id
	var vnc: Variant = e.data.get("vnc")
	var items := [{"label": "Connect…", "do": func():
		var previous := ""
		if is_connected_data(vnc):
			previous = str(vnc["host"]) + ("" if int(vnc.get("port", DEFAULT_PORT)) == DEFAULT_PORT else ":%d" % int(vnc["port"]))
		var player := menu.player
		menu.close()
		player.open_keyboard("Computer to show (VNC): address or address:port", previous, func(addr: String):
			if addr == "":
				return
			player.open_keyboard("VNC password for %s (leave empty if none)" % addr, "", func(pw: String):
				Widgets.request_op(id, "vnc", {"address": addr, "password": pw})))}]
	if is_connected_data(vnc):
		items.append({"label": "Keyboard", "color": Color("#4caf50"), "do": func():
			var player := menu.player
			menu.close()
			toggle_keyboard(player, e)})
		items.append({"label": "Disconnect", "color": RadialMenu.DANGER, "do": func():
			Widgets.request_op(id, "vnc", {"address": ""})
			menu.close()})
	return items


## The live keyboard open for a screen (one at a time), and which screen.
static var _keyboard: VirtualKeyboard
static var _keyboard_for := 0


## Show a live keyboard for this screen's computer (its keys go straight to
## it), or hide it if it's already showing.
static func toggle_keyboard(player: Node, e: NetBody) -> void:
	if is_instance_valid(_keyboard) and _keyboard_for == e.entity_id:
		_keyboard.cancel()
		return
	var screen: Node = e.get_node_or_null("%Screen")
	if not is_connected_data(e.data.get("vnc")) or not screen or not player:
		Net.toast.emit("Connect it to a computer first (Menu → Connect…).")
		return
	var cam: Camera3D = player.camera
	var fwd := -cam.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var pos := cam.global_position + fwd * 0.45 + Vector3(0, -0.25, 0)
	var name_ := str(e.data.get("name", "the computer"))
	_keyboard = VirtualKeyboard.open_live(player.get_parent(), Transform3D(Basis.looking_at(pos - cam.global_position, Vector3.UP), pos),
			"Typing on %s (%s)" % [name_, e.data.get("vnc", {}).get("host", "")], func(key: String):
				if not is_instance_valid(e) or not screen.client.send_key(key):
					Net.toast.emit("Not connected to that computer."))
	_keyboard_for = e.entity_id


static func keyboard_open_for(e: NetBody) -> bool:
	return is_instance_valid(_keyboard) and _keyboard_for == e.entity_id


## "host", "host:port" or "host:display" (VNC style: :1 = port 5901) -> [host, port],
## or [] if it isn't a usable address.
static func parse_address(addr: String) -> Array:
	addr = addr.strip_edges()
	var host := addr
	var port := DEFAULT_PORT
	var colon := addr.rfind(":")
	if colon > 0 and addr.count(":") == 1:
		host = addr.substr(0, colon)
		var p := addr.substr(colon + 1)
		if not p.is_valid_int():
			return []
		port = int(p)
		if port < 100:
			port += DEFAULT_PORT # a display number
	if host == "" or host.length() > 253 or port < 1 or port > 65535:
		return []
	for ch in host:
		if not (ch.is_valid_identifier() or ch.is_valid_int() or ch in ".-_"):
			return []
	return [host, port]


## Permission for a screen operation.
static func op_perm(op: String) -> String:
	return "interact" if op == "vnc" else ""


## Server: the "vnc" operation (connect / disconnect).
static func server_op(e: NetBody, peer: int, args: Dictionary, _op := "vnc") -> String:
	var addr := str(args.get("address", ""))
	if addr == "":
		Sync.set_data(e.entity_id, "vnc", {})
		return ""
	var hp := parse_address(addr)
	if hp.is_empty():
		return "Error: that doesn't look like a computer address (e.g. 192.168.1.20 or mypc.local:5901)."
	Sync.set_data(e.entity_id, "vnc", {"host": hp[0], "port": hp[1], "password": str(args.get("password", "")).substr(0, 64), "by": Net.player_name(peer)})
	return "Showing %s:%d" % [hp[0], hp[1]]


static func describe(vnc: Variant) -> String:
	if not is_connected_data(vnc):
		return "not showing anything"
	return "showing %s's computer (%s:%d), read-only" % [vnc.get("by", "someone"), vnc["host"], int(vnc.get("port", DEFAULT_PORT))]
