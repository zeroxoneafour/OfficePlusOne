extends SceneTree
## VNC viewer test against tests/fake_vnc_server.py (see tests/vnc_selftest.sh):
## connects a VncScreen, checks the decoded pixels (Raw, CopyRect), the
## desktop resize, letterboxing, disconnecting, and a refused connection.
## Usage: godot --headless --xr-mode off --script tests/vnc_test.gd -- PORT [PASSWORD]

var _fails: Array[String] = []


func _check(cond: bool, what: String) -> void:
	print("[vnc] %s %s" % ["ok  " if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _init() -> void:
	_run.call_deferred()


func _frames_until(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while t < seconds:
		if cond.call():
			return true
		await process_frame
		t += 1.0 / 60.0
		OS.delay_msec(16)
	return cond.call()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var port := int(args[0]) if args.size() else 5977
	var password := args[1] if args.size() > 1 else ""
	var des := VncDes.encrypt_block("133457799BBCDFF1".hex_decode(), "0123456789ABCDEF".hex_decode())
	_check(des.hex_encode() == "85e813540f0ab405", "DES matches the FIPS test vector")
	var screen: VncScreen = load("res://scenes/vnc/vnc_screen.tscn").instantiate()
	screen.screen_size = Vector2(1.6, 0.9)
	root.add_child(screen)
	screen.client.max_fps = 30.0
	screen.show_remote("127.0.0.1", port, password)
	_check(screen.status() == "connecting" and screen.get_node("%Status").text.begins_with("Connecting"), "connecting…")
	var c := screen.client
	await _frames_until(func(): return c.status == "connected" and c.texture != null and c.desktop_size == Vector2i(64, 48), 10.0)
	_check(c.status == "connected" and c.desktop_name == "fake desktop", "connected to '%s' (%s)" % [c.desktop_name, c.status])
	await _frames_until(func(): return c._image.get_pixel(40, 10).b > 0.9, 5.0)
	var img: Image = c._image
	_check(img.get_pixel(10, 10).r > 0.9 and img.get_pixel(10, 10).b < 0.1, "Raw rect: left half red %s" % img.get_pixel(10, 10))
	_check(img.get_pixel(40, 10).b > 0.9 and img.get_pixel(40, 10).r < 0.1, "Raw rect: right half blue %s" % img.get_pixel(40, 10))
	_check(img.get_pixel(60, 44).r > 0.9 and img.get_pixel(60, 44).b < 0.1, "CopyRect: red corner copied bottom-right %s" % img.get_pixel(60, 44))
	var quad := screen.get_node("%Picture").mesh as QuadMesh
	_check(absf(quad.size.x / quad.size.y - 64.0 / 48.0) < 0.01 and quad.size.y <= 0.9 + 0.001, "letterboxed to the desktop's shape %s" % quad.size)
	_check(screen.get_node("%Picture").visible and screen.get_node("%Status").text == "", "picture shown, no status text")
	await _frames_until(func(): return c.desktop_size == Vector2i(80, 60) and c._image.get_pixel(5, 5).g > 0.9, 5.0)
	_check(c.desktop_size == Vector2i(80, 60) and c._image.get_pixel(5, 5).g > 0.9, "desktop resize, then a green frame")
	_check((screen.get_node("%Picture").material_override as StandardMaterial3D).albedo_texture == c.texture, "screen shows the resized texture")
	# Keyboard (when a screen's keyboard is on): key presses go to the computer.
	_check(VncClient.keysym_for("H") == 0x48 and VncClient.keysym_for("Return") == 0xff0d and VncClient.keysym_for("é") == 0xe9
			and VncClient.keysym_for("€") == 0x010020ac, "keysyms for characters and named keys")
	c.send_key("H")
	c.type_text("i")
	c.send_key("Return")
	await _frames_until(func(): return false, 0.3)
	screen.clear_remote()
	_check(screen.status() == "idle" and not screen.get_node("%Picture").visible, "disconnect")
	# Nothing listening on port+1: a clear error, not a hang.
	screen.show_remote("127.0.0.1", port + 1, "")
	await _frames_until(func(): return c.status.begins_with("error"), 10.0)
	_check(c.status.begins_with("error") and screen.get_node("%Status").text.begins_with("Couldn't show"), "refused connection reported: %s" % c.status)
	print("[vnc] %s" % ("PASS" if _fails.is_empty() else "FAIL: %s" % [_fails]))
	quit(0 if _fails.is_empty() else 1)
