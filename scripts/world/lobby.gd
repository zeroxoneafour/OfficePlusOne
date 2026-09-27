extends Node3D
## Offline start area (scenes/world/lobby.tscn): a panel within arm's reach
## (poke it; or point and pinch). Host your own office (it opens as you left
## it), open one of your saved rooms instead, or join an office found on the
## LAN. Offices that already know you say "invited"; otherwise joining knocks
## and someone inside decides. "New here? Open the tutorial" (the big button
## at the top) opens the tutorial world (see Tutorial).


## Saved rooms and network offices shown (two columns each).
const ROOMS_SHOWN := 4
const SERVERS_SHOWN := 4
const CELL := Vector2(0.36, 0.065)
## Where the panel goes relative to your head: [distance ahead, drop below
## the eyes, tilt back (degrees)]. VR: within arm's reach, lectern-style;
## desktop: further off and nearly upright so it's in view.
const PLACE_VR := [0.42, 0.45, 35.0]
const PLACE_DESKTOP := [0.8, 0.2, 10.0]

func _ready() -> void:
	%Hint.text = "Hi %s. Tap a button with your fingertip (desktop: click)." % Config.player_name()
	%Host.pressed.connect(func(): Net.host(false))
	%JoinLocal.pressed.connect(func(): Net.join("127.0.0.1"))
	%TutorialButton.pressed.connect(func(): Net.host_tutorial())
	Net.servers_changed.connect(_refresh_servers)
	Net.waiting_changed.connect(_on_waiting)
	Saves.saves_changed.connect(_refresh_rooms)
	_refresh_rooms()
	_refresh_servers()

func _process(delta: float) -> void:
	_place_in_front()

func _on_waiting(waiting: bool) -> void:
	%Status.text = "Knocking… waiting to be let in." if waiting else ""

## Put the panel in front of wherever you're standing and looking.
func _place_in_front() -> void:
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return
	var fwd := -cam.global_basis.z
	fwd.y = 0.0
	if fwd.length() < 0.1:
		return
	fwd = fwd.normalized()
	var p: Array = PLACE_VR if get_viewport().use_xr else PLACE_DESKTOP
	var head := cam.global_position
	var pos := head + fwd * float(p[0])
	pos.y = maxf(head.y - float(p[1]), 0.6)
	%Panel.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP) * Basis(Vector3.RIGHT, deg_to_rad(-float(p[2]))), pos)


static func _cell(i: int) -> Vector3:
	return Vector3(-0.2 + (i % 2) * 0.4, -(i / 2) * (CELL.y + 0.012), 0)


## Your saved rooms (newest first): opening one hosts your office with it.
func _refresh_rooms() -> void:
	for c in %Rooms.get_children():
		c.queue_free()
	var saves := Saves.list_saves().filter(func(sv): return sv["name"] != Saves.AUTOSAVE)
	%RoomsTitle.text = "Or open one of your saved rooms:" if saves.size() else "(Saved rooms appear here: watch → Room → Saves → Save as…)"
	for i in mini(saves.size(), ROOMS_SHOWN):
		var save_name: String = saves[i]["name"]
		var room := str(saves[i]["room"])
		var label := save_name if room == "" or room == save_name else "%s (%s)" % [save_name, room]
		PokeButton.make(%Rooms, label, _cell(i), Color("#7b68ee"), CELL).pressed.connect(func():
			Saves.startup_save = save_name
			Net.host(false))


func _refresh_servers() -> void:
	for c in %Servers.get_children():
		c.queue_free()
	var entries := []
	var def := str(Config.get_value("network", "default_join"))
	if def != "":
		entries.append({"label": "Join " + def, "color": Color("#3d85c6"), "do": func(): Net.join(def)})
	for key in Net.servers:
		var s: Dictionary = Net.servers[key]
		var ip: String = s["ip"]
		var port: int = s["port"]
		entries.append({"label": "%s (%d)%s" % [s["name"], s["players"], " invited" if s["invited"] else ""],
				"color": Color("#7b68ee") if s["invited"] else Color("#555a66"), "do": func(): Net.join(ip, port)})
	%ServersTitle.text = "Offices on your network:" if entries.size() else "Offices on your network: (none found yet)"
	for i in mini(entries.size(), SERVERS_SHOWN):
		PokeButton.make(%Servers, entries[i]["label"], _cell(i), entries[i]["color"], CELL).pressed.connect(entries[i]["do"])
