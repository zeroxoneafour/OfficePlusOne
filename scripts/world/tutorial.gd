class_name Tutorial extends RefCounted
## The tutorial world (lobby → "New here? Open the tutorial"): a private
## practice office that's never saved (Net.tutorial). Boards on every wall
## explain one thing each, with diagrams, and next to them is something to
## try it on: targets for the ray, a board to draw on, widgets, furniture to
## grab and lock, drawers full of sample files, a long document to scroll, a
## floating screen, and a Tutor AI. The boards' own text scrolls too.
##
## You arrive facing the north wall: Welcome in the middle, pointing on the
## left, menus on the right; then the east (right), west (left) and south
## (behind you) walls.

const SIZE := [12.0, 3.0, 12.0]
const FILES_DIR := "user://tutorial_files"
const SAMPLE_FILES := {
	"Welcome.txt": "Hello! This file came out of the drawer.\nHand it to someone, or to the Tutor AI (let go of it next to them).\nPull the trigger while holding it (desktop: E) to save a copy to your device.",
	"Meeting notes.md": "# Monday sync\n- Ship the widgets\n- Try the tutorial\n- Lunch at 12:30",
	"Ideas.txt": "1. Whiteboard wall\n2. A timer for stand-ups\n3. Show my screen on the TV",
}
## A long file, to practise scrolling (it's on the table).
const LONG_FILE := "Scroll me! Long files scroll: the ^ v < > buttons beside the text appear when there's more to see (desktop: the mouse wheel over it).\n\n"

const BOARDS := [
	# [wall, u, height, title, text, diagram]
	["north", 0.0, 1.6, "Welcome to Office Plus One",
		"This is a practice room: nothing here is saved.\nEach board teaches one thing; try it on what's next to it.\nStart with pointing (left) and menus (right), then the\nwalls to your right, your left and behind you.\nYou point with your right hand; if you're left-handed,\nswitch in the watch's Me menu (Dominant hand).\nLeave any time: back of your watch wrist to your eyes\n→ Me → Switch room → Lobby (desktop: press Q).\n\nLong text on a board scrolls: use the ^ and v buttons\non the board's right edge (desktop: the mouse wheel).\nDrawings scroll along with the text.", ""],
	["north", -3.8, 1.6, "1 · Point and click",
		"Point: index finger out,\nother fingers curled in.\nA ray comes from your\npointing (dominant) hand.\nClick: keep the ray on a\nbutton and pinch (thumb to\nindex; controller: trigger),\nor poke it with your\nfingertip.\nDesktop: aim + left click.", "point"],
	["north", 3.8, 1.6, "2 · Context menus",
		"Point at anything: the floor,\na wall, an object, an AI.\nStart to clench: the ray\nturns yellow and holds.\nPull your fist back ~15 cm\nand a pie menu opens.\nPoke or pinch a slice.\nFist on a menu moves it.\nDesktop: right-click.", "menu"],
	["east", 0.4, 1.6, "4 · Draw on me",
		"Pick a colour and a size on the strip under this board.\nDraw with your fingertip on the board, or point at it\nand hold a pinch (controller: trigger) while you move.\nDesktop: hold the left button and drag.\nMenu (top right) → Wipe clears it.", ""],
	["west", -3.0, 1.6, "5 · Grab and files",
		"Grab: make a fist near\nsomething (controller: grip).\nLet go mid-swing to throw.\nOr point → menu → Grab: it\njumps into your palm; close\nand open your hand to drop it.\nArm slots: each forearm has\none (the ring). Let go of\nsomething over it to carry it\nthere; close an empty hand on\nit to take it back. Putting a\nnew thing in drops the old.\nDesktop: keys 1 and 2.\nDrawers (below): pull the\nhandle to browse files, grab\none to take a copy.", "grab"],
	["south", -3.5, 1.6, "6 · Your watch and AIs",
		"Watch: turn the back of your\nother wrist to your eyes.\nMe: mute, rays, dominant\nhand, switch room.\nRoom: size, saves, guests.\nAIs: point at one and talk;\nstop pointing to send.\nDesktop: aim at it and talk,\nor press T to type.\nIts menu: Mute, Point-to-talk.", "watch"],
	["south", 3.5, 1.6, "7 · Widgets and typing",
		"Point at a wall → menu →\nAdd widget: calendar, alarm,\ntimer, whiteboard or TV.\nEach widget's Menu button:\nrename, settings, remove.\nThe keyboard: poke keys,\n#+= for symbols, and a fist\non it moves it.\nPoke a calendar day to add.\nFloating screens (by the\ntable): grab one and let go\nanywhere; it stays put, in\nmid-air. Add more from the\nfloor's menu → Add. TVs and\nscreens show a computer\n(Menu → Connect…); their\nKeyboard button types on it.", "widgets"],
]

## Shape-only diagrams (SVG text isn't rendered): hands, rays, menus.
const DIAGRAMS := {
	"point": "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='300' viewBox='0 0 400 300'><rect width='400' height='300' fill='#ffffff'/>" \
		+ "<rect x='40' y='140' width='90' height='80' rx='26' fill='#e0b890'/><circle cx='62' cy='222' r='14' fill='#c99a6e'/><circle cx='90' cy='226' r='14' fill='#c99a6e'/><circle cx='116' cy='220' r='13' fill='#c99a6e'/>" \
		+ "<rect x='120' y='148' width='95' height='26' rx='13' fill='#e0b890'/><rect x='70' y='112' width='22' height='44' rx='11' fill='#c99a6e'/>" \
		+ "<line x1='215' y1='161' x2='330' y2='112' stroke='#3399ff' stroke-width='7' stroke-dasharray='16 9'/>" \
		+ "<rect x='318' y='70' width='70' height='52' rx='8' fill='#3d85c6'/><rect x='326' y='78' width='54' height='36' rx='6' fill='#5fa3e0'/>" \
		+ "<circle cx='72' cy='60' r='26' fill='#f2d06b'/><circle cx='112' cy='60' r='12' fill='#f2d06b'/><line x1='40' y1='60' x2='22' y2='60' stroke='#f2d06b' stroke-width='6'/></svg>",
	"menu": "<svg xmlns='http://www.w3.org/2000/svg' width='420' height='300' viewBox='0 0 420 300'><rect width='420' height='300' fill='#ffffff'/>" \
		+ "<rect x='10' y='120' width='70' height='60' rx='20' fill='#e0b890'/><rect x='72' y='128' width='60' height='20' rx='10' fill='#e0b890'/><line x1='132' y1='138' x2='175' y2='120' stroke='#3399ff' stroke-width='6'/>" \
		+ "<rect x='150' y='120' width='70' height='60' rx='24' fill='#c99a6e'/><line x1='220' y1='140' x2='265' y2='122' stroke='#f2c12e' stroke-width='6'/>" \
		+ "<line x1='300' y1='255' x2='250' y2='255' stroke='#1b1b1b' stroke-width='6'/><polygon points='240,255 258,245 258,265' fill='#1b1b1b'/>" \
		+ "<rect x='300' y='220' width='60' height='56' rx='22' fill='#c99a6e'/>" \
		+ "<circle cx='345' cy='110' r='62' fill='#2a2d34'/><path d='M345,110 L345,52 A58,58 0 0,1 395,139 Z' fill='#3d85c6'/><path d='M345,110 L395,139 A58,58 0 0,1 295,139 Z' fill='#7b68ee'/><path d='M345,110 L295,139 A58,58 0 0,1 345,52 Z' fill='#4caf50'/><circle cx='345' cy='110' r='18' fill='#c0504d'/></svg>",
	"grab": "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='300' viewBox='0 0 400 300'><rect width='400' height='300' fill='#ffffff'/>" \
		+ "<rect x='40' y='110' width='90' height='90' rx='30' fill='#c99a6e'/><rect x='120' y='118' width='30' height='70' rx='14' fill='#b88a5e'/>" \
		+ "<rect x='160' y='120' width='60' height='60' rx='6' fill='#4f86c6'/><line x1='230' y1='150' x2='300' y2='150' stroke='#1b1b1b' stroke-width='6'/><polygon points='310,150 292,140 292,160' fill='#1b1b1b'/>" \
		+ "<rect x='300' y='190' width='80' height='90' rx='4' fill='#a4876a'/><rect x='300' y='160' width='80' height='26' rx='3' fill='#b08f70'/><rect x='325' y='168' width='30' height='8' fill='#d0d4d8'/></svg>",
	"watch": "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='300' viewBox='0 0 400 300'><rect width='400' height='300' fill='#ffffff'/>" \
		+ "<rect x='60' y='150' width='260' height='70' rx='30' fill='#e0b890'/><rect x='150' y='140' width='70' height='90' rx='10' fill='#2a2d34'/><rect x='160' y='152' width='50' height='40' rx='6' fill='#3d85c6'/>" \
		+ "<rect x='160' y='198' width='22' height='18' fill='#3d85c6'/><rect x='188' y='198' width='22' height='18' fill='#7b68ee'/>" \
		+ "<circle cx='185' cy='50' r='30' fill='none' stroke='#1b1b1b' stroke-width='6'/><circle cx='185' cy='50' r='10' fill='#1b1b1b'/><line x1='185' y1='82' x2='185' y2='130' stroke='#1b1b1b' stroke-width='5' stroke-dasharray='10 6'/></svg>",
	"widgets": "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='300' viewBox='0 0 400 300'><rect width='400' height='300' fill='#e8e4dc'/>" \
		+ "<rect x='20' y='30' width='150' height='140' fill='#f4f1ea' stroke='#2b2f3a' stroke-width='6'/><rect x='34' y='60' width='28' height='22' fill='#3d85c6'/><rect x='68' y='60' width='28' height='22' fill='#7b68ee'/><rect x='102' y='60' width='28' height='22' fill='#4caf50'/><rect x='34' y='90' width='28' height='22' fill='#3d85c6'/><rect x='68' y='90' width='28' height='22' fill='#3d85c6'/>" \
		+ "<rect x='200' y='30' width='170' height='100' fill='#1d2230' stroke='#2b2f3a' stroke-width='6'/><rect x='225' y='55' width='120' height='40' fill='#ffffff'/>" \
		+ "<rect x='60' y='200' width='280' height='80' fill='#050505' stroke='#2b2f3a' stroke-width='6'/><rect x='80' y='215' width='240' height='50' fill='#3d85c6'/></svg>",
}


## Server: build the tutorial office (instead of loading your own).
static func server_build() -> void:
	var s := Office.default_state()
	s["name"] = "Tutorial"
	s["size"] = SIZE
	s["colors"]["north"] = "#dfe7ef"
	Office.replace_state(s)
	# Explanations.
	for b in BOARDS:
		var step: String = b[3].get_slice(" · ", 0)
		var name_ := Widgets.server_add("whiteboard", b[0], _wall_point(b[0], b[1], b[2]), "Step " + step if b[3].contains(" · ") else "Welcome")
		var board: WhiteboardWidget = Widgets.find("whiteboard", name_)
		if board:
			var img := Sync.add_svg(DIAGRAMS[b[5]]) if b[5] != "" else 0
			board.server_show({"title": b[3], "text": b[4], "image": img})
	# Things to try.
	Widgets.server_add("practice", "east", _wall_point("east", -3.3, 1.55), "3 · Practice")
	Widgets.server_add("timer", "east", _wall_point("east", 3.4, 1.95), "Practice timer")
	Widgets.server_add("alarm", "east", _wall_point("east", 3.4, 1.38), "Practice alarm")
	var cal_name := Widgets.server_add("calendar", "west", _wall_point("west", 0.6, 1.55), "Practice calendar")
	var cal: CalendarWidget = Widgets.find("calendar", cal_name)
	if cal:
		var tomorrow := CalendarWidget.parse_date("tomorrow")
		cal.server_add_entry(CalendarWidget.today(), "10:00", "Try the tutorial")
		cal.server_add_entry(CalendarWidget.today(), "12:30", "Lunch")
		cal.server_add_entry(tomorrow, "09:30", "Stand-up")
	Widgets.server_add("tv", "west", _wall_point("west", 3.6, 1.6), "Practice TV")
	# Furniture to grab, lock and sit on (unlocked, unlike a normal office).
	var table := Office.spawn_object("table", Vector3(2.2, 0, 0.3))
	for p in [[Vector3(2.2, 0, 1.2), 0.0], [Vector3(2.2, 0, -0.6), PI]]:
		Sync.server_set_locked(Office.spawn_object("chair", p[0], p[1]), false)
	Sync.server_set_locked(table, false)
	Sync.server_set_locked(Office.spawn_object("plant", Vector3(4.6, 0, 4.4)), false)
	Sync.server_set_locked(Office.spawn_object("lamp", Vector3(-4.6, 0, 4.4)), false)
	Office.spawn_object("monitor", Vector3(2.2, 0, 0.1))
	# Drawers of sample files, and one file already out on the table.
	_write_sample_files()
	var drawer_id := Office.spawn_object("drawer", Vector3(-5.5, 0, -3.0), PI * 0.5)
	Sync.set_data(drawer_id, "path", ProjectSettings.globalize_path(FILES_DIR))
	var fid := Files.server_add("Welcome.txt", str(SAMPLE_FILES["Welcome.txt"]).to_utf8_buffer())
	Files.server_spawn_document(fid, Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(2.0, Office.TABLE_TOP + 0.03, 0.5)))
	var long_text := LONG_FILE
	for i in 60:
		long_text += "Line %d: a long line that runs on past the edge of the page, so you can scroll sideways as well as down.\n" % (i + 1)
	var long_id := Files.server_add("Long file.txt", long_text.to_utf8_buffer())
	Files.server_spawn_document(long_id, Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(2.45, Office.TABLE_TOP + 0.03, 0.5)))
	# A floating screen to grab and hang anywhere.
	Sync.spawn("floating_screen", Transform3D(Basis(Vector3.UP, -PI * 0.25), Vector3(3.4, 1.5, 1.8)))
	# Someone to talk to.
	AI.server_create_agent({"name": "Tutor", "persona": "You are the Office Plus One tutor, standing in the tutorial room. Help people learn the app: pointing a ray (index finger out, others curled; pinch to click), context menus (point, clench, pull back ~15 cm), the wrist watch on the non-pointing wrist (Me and Room menus; Me also picks the dominant hand), grabbing (fist, or Grab from a menu), the slot on each forearm for carrying things, scrolling long text, floating screens, wall widgets (add from a wall's menu), drawers of files, and talking to AIs (point and talk). Be encouraging and brief, and suggest what to try next."},
			0, Transform3D(Basis(Vector3.UP, PI), Vector3(-1.8, 0.02, -1.6))) # facing you as you arrive


## A point on a wall at offset `u` along it and `height`.
static func _wall_point(wall: String, u: float, height: float) -> Vector3:
	var half := Vector3(SIZE[0], 0, SIZE[2]) * 0.5
	match wall:
		"north": return Vector3(u, height, -half.z)
		"south": return Vector3(u, height, half.z)
		"west": return Vector3(-half.x, height, u)
		"east": return Vector3(half.x, height, u)
	return Vector3.ZERO


static func _write_sample_files() -> void:
	DirAccess.make_dir_recursive_absolute(FILES_DIR)
	for f in SAMPLE_FILES:
		var path := FILES_DIR.path_join(f)
		if not FileAccess.file_exists(path):
			var fa := FileAccess.open(path, FileAccess.WRITE)
			if fa:
				fa.store_string(SAMPLE_FILES[f])
