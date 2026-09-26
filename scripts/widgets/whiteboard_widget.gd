class_name WhiteboardWidget extends Widget
## A wall whiteboard (scenes/widgets/whiteboard.tscn). A palette along its
## bottom picks your brush (colour, size, or the eraser; just for you). Then
## draw with your fingertip on the board, or from afar by pointing at it and
## holding a pinch (controller: trigger) while you move the ray; on desktop,
## hold the left button and drag. On top of the drawing it shows a title, text
## and a picture: AIs write and draw there (widget_whiteboard, and the
## whiteboard tools), people type with Write… in its menu, and pressing a
## document or clipboard against it pins it there.
## data: {title, text, image, strokes: [{c: "#rrggbb" | "erase", w: px, p: [x0, y0, x1, y1, …]}]}
## Strokes arrive as events (not whole-data updates), so drawing stays cheap.

const TEX := Vector2i(1024, 576)
const BG := Color("#f7f7f2")
const MAX_TEXT := 1500
## Oldest strokes are dropped past this many stored coordinates.
const MAX_POINTS := 200000
const ERASE := "erase"
const COLORS := ["#1b1b1b", "#2a62c9", "#c93a2a", "#2e8b57"]
const SIZES := [["S", 4], ["M", 9], ["L", 18]]
const ERASER_SCALE := 4
const TEXT_PX := 0.0012

## Your brush (local to you, shared by every board): colour, width in board
## pixels, and whether it erases.
static var brush := {"c": COLORS[0], "w": SIZES[0][1], "erase": false}
static var brush_version := 0

var _image: Image
var _texture: ImageTexture
var _dirty := false
var _palette: Array[PokeButton] = []
var _shown_version := -1


func _widget_build() -> void:
	_image = Image.create(TEX.x, TEX.y, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	(%Drawing.material_override as StandardMaterial3D).albedo_texture = _texture
	(%Drawing.mesh as QuadMesh).size = size
	Sync.image_added.connect(_on_image_added)
	_build_palette()
	_redraw()
	_layout()


func _on_image_added(_id: int) -> void:
	_layout()


func _widget_data(key: String, _value: Variant) -> void:
	if key in ["title", "text", "image"] and is_node_ready():
		_layout()
	elif key == "strokes" and _image:
		_redraw()


# --- Brush palette ---------------------------------------------------------------------------

func _build_palette() -> void:
	var y := -size.y * 0.5 - 0.06
	var x := -size.x * 0.5 + 0.06
	for c in COLORS:
		var color: String = c
		var b := PokeButton.make(self, "", Vector3(x, y, 0.0), Color(color), Vector2(0.075, 0.05))
		b.pressed.connect(func(): set_brush({"c": color, "erase": false}))
		b.set_meta("brush", {"c": color})
		_palette.append(b)
		x += 0.085
	x += 0.04
	for s in SIZES:
		var width: int = s[1]
		var b := PokeButton.make(self, s[0], Vector3(x, y, 0.0), Color("#555a66"), Vector2(0.075, 0.05))
		b.pressed.connect(func(): set_brush({"w": width}))
		b.set_meta("brush", {"w": width})
		_palette.append(b)
		x += 0.085
	x += 0.07
	var e := PokeButton.make(self, "Eraser", Vector3(x, y, 0.0), Color("#b8b8b0"), Vector2(0.13, 0.05))
	e.pressed.connect(func(): set_brush({"erase": true}))
	e.set_meta("brush", {"erase": true})
	_palette.append(e)
	for b in _palette:
		b.label_size = 30


## Change your brush (every board's palette shows it).
static func set_brush(changes: Dictionary) -> void:
	brush.merge(changes, true)
	brush_version += 1


func _show_palette() -> void:
	_shown_version = brush_version
	for b in _palette:
		var m: Dictionary = b.get_meta("brush")
		var on := false
		if m.has("c"):
			on = m["c"] == brush["c"] and brush["erase"] != true
			b.set_text("•" if on else "")
		elif m.has("w"):
			on = int(m["w"]) == int(brush["w"])
			b.set_text(("[%s]" if on else "%s") % ["S", "M", "L"][SIZES.map(func(s): return s[1]).find(int(m["w"]))])
		else:
			on = brush["erase"] == true
			b.set_text("[Eraser]" if on else "Eraser")


## The ink and width (board pixels) a stroke drawn with your brush uses now.
static func brush_ink() -> String:
	return ERASE if brush["erase"] == true else str(brush["c"])


static func brush_width() -> int:
	return int(brush["w"]) * (ERASER_SCALE if brush["erase"] == true else 1)


# --- Title, text and picture --------------------------------------------------------------------

func _layout() -> void:
	if not is_node_ready():
		return
	var title := str(data.get("title", ""))
	var text := str(data.get("text", ""))
	var tex: Texture2D = Sync.images.get(int(data.get("image", 0)))
	var has_words := title != "" or text != ""
	%Title.text = title
	%Text.text = text.substr(0, MAX_TEXT)
	%Picture.visible = tex != null
	var text_w := size.x - 0.1 if tex == null else size.x * 0.5 - 0.08
	%Title.width = text_w / %Title.pixel_size
	%Text.width = text_w / %Text.pixel_size
	%Text.position.y = size.y * 0.5 - (0.13 if title != "" else 0.04)
	if tex:
		var area := Vector2(size.x - 0.1, size.y - 0.1) if not has_words else Vector2(size.x * 0.5 - 0.08, size.y - 0.1)
		var aspect := float(tex.get_width()) / maxf(tex.get_height(), 1)
		var qs := Vector2(area.x, area.x / aspect)
		if qs.y > area.y:
			qs = Vector2(area.y * aspect, area.y)
		(%Picture.mesh as QuadMesh).size = qs
		%Picture.position.x = size.x * 0.25 if has_words else 0.0
		(%Picture.material_override as StandardMaterial3D).albedo_texture = tex


# --- Drawing -------------------------------------------------------------------------------------

func strokes() -> Array:
	if not data.get("strokes") is Array:
		data["strokes"] = []
	return data["strokes"]


func _redraw() -> void:
	_image.fill(BG)
	for s in strokes():
		if s is Dictionary:
			_paint(str(s.get("c", "#000000")), int(s.get("w", 4)), s.get("p", []))
	_dirty = true


func on_event(event_name: String, args: Dictionary) -> void:
	match event_name:
		"stroke":
			if not Net.is_server():
				strokes().append({"c": args["c"], "w": args["w"], "p": args["p"]})
			if int(args.get("by", 0)) != Net.my_id():
				_paint(str(args["c"]), int(args["w"]), args["p"])
		"clear_drawing":
			data["strokes"] = []
			_redraw()


func _process(delta: float) -> void:
	super(delta)
	if _dirty:
		_dirty = false
		_texture.update(_image)
	if _shown_version != brush_version and not _palette.is_empty():
		_show_palette()


## Draw a stroke on this peer's copy right away (the drawer's own pen does
## this before the server echoes it to everyone else).
func draw_local(c: String, w: int, pts: Array) -> void:
	_paint(c, w, pts)


func _paint(c: String, w: int, pts: Array) -> void:
	var col := BG if c == ERASE else Mk.color(c, Color.BLACK)
	var r := clampi(w, 1, 80) / 2
	var n := pts.size() / 2
	for i in n:
		var b := Vector2(float(pts[i * 2]), float(pts[i * 2 + 1]))
		var a := b if i == 0 else Vector2(float(pts[i * 2 - 2]), float(pts[i * 2 - 1]))
		var steps := maxi(1, ceili(a.distance_to(b) / maxf(r * 0.5, 1.0)))
		for k in steps + 1:
			var p := a.lerp(b, float(k) / steps)
			_image.fill_rect(Rect2i(int(p.x) - r, int(p.y) - r, r * 2 + 1, r * 2 + 1).intersection(Rect2i(Vector2i.ZERO, TEX)), col)
	_dirty = true


## Board pixel of a world point, if that point touches the face (within
## `reach` in front of it, or pushed a little way into it).
func touch(world: Vector3, reach: float) -> Dictionary:
	var p := to_local(world)
	if absf(p.x) > size.x * 0.5 or absf(p.y) > size.y * 0.5 or p.z > reach or p.z < -0.08:
		return {}
	return {"px": Vector2((p.x / size.x + 0.5) * TEX.x, (0.5 - p.y / size.y) * TEX.y)}


## Is a world position close to the face (for pinning documents to it)?
func is_near(world: Vector3) -> bool:
	var p := to_local(world)
	return absf(p.x) < size.x * 0.5 + 0.1 and absf(p.y) < size.y * 0.5 + 0.1 and p.z > -0.05 and p.z < 0.3


func widget_menu_items(menu: RadialMenu) -> Array:
	var id := entity_id
	return [
		{"label": "Write…", "do": func():
			menu.close()
			menu.player.open_keyboard("Add a line of text to the board", "", func(t: String):
				if t != "":
					Widgets.request_op(id, "write", {"text": t, "mode": "append"}))},
		{"label": "Wipe", "sub": func(): return [
			{"label": "Drawing", "do": func():
				Widgets.request_op(id, "clear", {"what": "drawing"})
				menu.close()},
			{"label": "Text & picture", "do": func():
				Widgets.request_op(id, "clear", {"what": "text"})
				menu.close()},
			{"label": "Everything", "color": RadialMenu.DANGER, "do": func():
				Widgets.request_op(id, "clear", {"what": "all"})
				menu.close()},
		]},
	]


# --- Operations ---------------------------------------------------------------------------

func op_perm(op: String) -> String:
	return "interact" if op in ["stroke", "write", "clear"] else ""


func server_op(peer: int, op: String, args: Dictionary) -> String:
	match op:
		"stroke":
			_server_stroke(peer, args)
		"write":
			return server_write(str(args.get("text", "")), str(args.get("mode", "replace")), peer)
		"clear":
			server_clear(str(args.get("what", "all")), peer)
	return ""


func _server_stroke(peer: int, args: Dictionary) -> void:
	var c := str(args.get("c", ""))
	if c != ERASE and not Color.html_is_valid(c):
		return
	var raw: Variant = args.get("p")
	if not (raw is Array or raw is PackedInt32Array) or raw.size() < 2 or raw.size() > 2000:
		return
	var pts := []
	for v in raw:
		pts.append(clampi(int(v), -64, maxi(TEX.x, TEX.y) + 64))
	if pts.size() % 2:
		pts.pop_back()
	var s := {"c": c, "w": clampi(int(args.get("w", 4)), 1, 80), "p": pts}
	var list := strokes()
	list.append(s)
	var total := 0
	for x in list:
		total += x["p"].size()
	while total > MAX_POINTS and list.size() > 1:
		total -= list[0]["p"].size()
		list.pop_front()
	var ev := s.duplicate()
	ev["by"] = peer
	Sync.event(entity_id, "stroke", ev)


## Server: wipe the "drawing", the "text" (title, text and picture) or "all".
func server_clear(what: String, by := 0) -> void:
	if what in ["drawing", "all"]:
		data["strokes"] = []
		Sync.event(entity_id, "clear_drawing")
	if what in ["text", "all"]:
		server_show({"title": "", "text": "", "image": 0})
	AI.widget_note("%s wiped the %s of whiteboard \"%s\"." % [Widgets._who(by), "whole board" if what == "all" else what, widget_name()])


## Server: set the board's text. `mode`: replace | append | clear.
func server_write(text: String, mode := "replace", by := 0) -> String:
	var current := str(data.get("text", ""))
	match mode:
		"clear":
			text = ""
		"append":
			text = (current + "\n" + text).strip_edges() if current != "" else text
	if text.length() > MAX_TEXT:
		return "Error: that's too much text for the board (max %d characters in total)." % MAX_TEXT
	Sync.set_data(entity_id, "text", text)
	AI.widget_note("%s %s whiteboard \"%s\"%s" % [Widgets._who(by), "wiped the text on" if text == "" else "wrote on",
			widget_name(), "" if text == "" else ". Its text is now: " + text.substr(0, 300)])
	return "Written on %s." % widget_name() if text != "" else "Text wiped from %s." % widget_name()


## Server: show a title, text and/or picture (image id) at once; keys left
## out stay as they are. (The AIs' whiteboard tools and pinned items use this.)
func server_show(board: Dictionary) -> void:
	for key in ["title", "text", "image"]:
		if board.has(key):
			Sync.set_data(entity_id, key, board[key] if key != "text" else str(board[key]).substr(0, MAX_TEXT))


func ai_summary() -> String:
	var t := str(data.get("text", ""))
	var title := str(data.get("title", ""))
	return "title: %s; text: %s; %s; %d hand-drawn strokes (you can't see drawings, only the text)" % [
			"\"%s\"" % title if title != "" else "(none)", "\"%s\"" % t.replace("\n", " / ") if t != "" else "(none)",
			"a picture is shown" if int(data.get("image", 0)) else "no picture", strokes().size()]
