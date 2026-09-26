extends Node3D
## Entry point (scenes/main.tscn). Sets up XR (or desktop fallback), hands the
## world containers to the autoloads, then hosts/joins based on the command
## line or shows the physical lobby.
##
##   godot -- --host              host your office and play
##   godot -- --join=192.168.1.5  join (knock on) someone's office
##   godot --headless --xr-mode off -- --server   dedicated server (no player)
##   add --desktop to force mouse/keyboard mode, --name=Ada to set your name

const PlayerScene := preload("res://scenes/player/local_player.tscn")
const LobbyScene := preload("res://scenes/world/lobby.tscn")

var player: Node3D
var _lobby: Node3D


func _ready() -> void:
	Office.root = %RoomRoot
	Sync.root = %Entities
	Sync.avatars_root = %Avatars

	var dedicated := Config.has_arg("server")
	if not dedicated and not Config.has_arg("desktop"):
		var xr := XRServer.find_interface("OpenXR")
		if xr and xr.is_initialized():
			get_viewport().use_xr = true
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			print("[Main] OpenXR active")
		else:
			print("[Main] No OpenXR runtime/headset: desktop mode")
	if not dedicated:
		player = PlayerScene.instantiate()
		add_child(player)

	Net.session_started.connect(_on_session_started)
	Net.session_ended.connect(_on_session_ended)
	if Config.has_arg("selftest"):
		var test: GDScript = load("res://tests/selftest.gd")
		if not test or not test.can_instantiate():
			# A broken test script would otherwise leave the app idling until the runner's timeout.
			printerr("[selftest:%s] FAIL: tests/selftest.gd doesn't compile (see the errors above)" % Config.args.get("selftest"))
			get_tree().quit(1)
			return
		add_child(test.new())
	if dedicated:
		Net.host(true)
	elif Config.has_arg("host"):
		Net.host(false)
	elif Config.has_arg("join"):
		_show_lobby()
		Net.join(str(Config.args["join"]))
	else:
		_show_lobby()


func _show_lobby() -> void:
	if _lobby or not Net.has_local_player():
		return
	_lobby = LobbyScene.instantiate()
	add_child(_lobby)
	if player:
		player.global_transform = Transform3D.IDENTITY
	Net.start_listening()


func _on_session_started() -> void:
	if _lobby:
		_lobby.queue_free()
		_lobby = null
	if Net.has_local_player():
		Net.start_listening() # keep finding other offices (watch: Switch room)
		Voice.start_capture()


func _on_session_ended(reason: String) -> void:
	_show_lobby()
	if player and reason != "":
		player.show_toast(reason, 6.0)
