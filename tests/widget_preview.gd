extends Node3D
## Renders the wall widgets, the drawers and a monitor side by side and saves
## a screenshot: `godot --xr-mode off tests/widget_preview.tscn -- --shot=/tmp/widgets.png`
## (needs a display; offline, touches no saved data).


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("#e8e4dc")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.8)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 20, 0)
	add_child(sun)
	var today := CalendarWidget.today()
	_make("calendar", Vector3(-1.9, 1.6, 0), {"name": "Team", "entries": [{"date": today, "time": "14:00", "text": "Standup"},
			{"date": today, "time": "16:30", "text": "Design review"}]})
	_make("alarm", Vector3(-0.9, 1.95, 0), {"name": "Lunch", "time": "12:30", "enabled": true})
	_make("timer", Vector3(-0.9, 1.35, 0), {"name": "Tea", "duration": 300, "remaining": 245.0})
	var board := _make("whiteboard", Vector3(0.6, 1.6, 0), {"name": "Main board", "title": "Q3 plan", "text": "- ship widgets\n- demo Friday",
			"strokes": [{"c": "#c93a2a", "w": 5, "p": [600, 300, 700, 250, 800, 320, 900, 260]}]})
	_make("tv", Vector3(2.5, 1.6, 0), {"name": "Pat's PC"})
	_make("drawer", Vector3(-0.6, 0.36, 0.6), {"path": "/home/pat/Shared", "open": true})
	_make("monitor", Vector3(1.0, 0.8, 0.8), {})
	# A pie menu and the keyboard, as they float in front of you.
	var menu: RadialMenu = load("res://scenes/ui/menus/floor_menu.tscn").instantiate()
	menu.setup({"type": "seat", "entity_id": 0, "point": Vector3.ZERO}, null)
	add_child(menu)
	menu.position = Vector3(-1.2, 0.9, 1.6)
	VirtualKeyboard.open(self, Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-20)), Vector3(0.9, 0.85, 1.7)), "Name this save", "Team room")
	var cam := Camera3D.new()
	cam.position = Vector3(0.3, 1.3, 4.6)
	cam.fov = 70
	add_child(cam)
	cam.make_current()
	for i in 20:
		await get_tree().process_frame
	var shot := "/tmp/widgets.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			shot = a.trim_prefix("--shot=")
	get_viewport().get_texture().get_image().save_png(shot)
	print("saved ", shot, " (board strokes: ", board.strokes().size(), ")")
	get_tree().quit()


func _make(kind: String, pos: Vector3, data: Dictionary) -> NetBody:
	var e: NetBody = Sync.Entities.create(kind)
	e.kind = kind
	e.data = data
	add_child(e)
	e.position = pos
	e.net_target = e.global_transform # client-side copies sit at their network position
	e.setup(false)
	return e
