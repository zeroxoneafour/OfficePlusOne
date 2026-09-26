class_name CalendarWidget extends Widget
## A wall calendar (scenes/widgets/calendar.tscn): a month of day cells, each
## with its date in the corner and a preview of what's on that day (today in
## green, days with entries in purple), and the next few entries underneath. Poke a day for its entries and to add one (with the keyboard);
## ◀ ▶ change the month. AIs write to it with widget_calendar.
## data: {entries: [{date: "YYYY-MM-DD", time: "HH:MM" or "", text}], month: "YYYY-MM"}

const MAX_ENTRIES := 300
const MONTHS := ["January", "February", "March", "April", "May", "June", "July",
		"August", "September", "October", "November", "December"]
const CELL := Vector2(0.125, 0.1)
const CELL_GAP := 0.006
## First grid row's centre, relative to the Grid node.
const GRID_TOP := 0.0
## Text inside a day cell (metres per pixel, font sizes).
const CELL_PX := 0.0006
const DAY_FONT := 40
const PREVIEW_FONT := 24
## Entries previewed in a cell, and characters per preview line.
const PREVIEW_LINES := 2
const PREVIEW_CHARS := 15
const TODAY := Color("#4caf50")
const BUSY := Color("#7b68ee")
const PLAIN := Color("#3d85c6")

var _days: Array[PokeButton] = []
## Per cell: [day number label, preview label].
var _cell_labels: Array = []


func _widget_build() -> void:
	%Prev.pressed.connect(func(): Widgets.request_op(entity_id, "month", {"month": _shift_month(_month(), -1)}))
	%Next.pressed.connect(func(): Widgets.request_op(entity_id, "month", {"month": _shift_month(_month(), 1)}))
	# 6 weeks x 7 days of buttons; each shows one date (or hides) per month.
	for i in 42:
		var col := i % 7
		var row := i / 7
		var pos := Vector3((col - 3) * (CELL.x + CELL_GAP), GRID_TOP - row * (CELL.y + CELL_GAP), 0.0)
		var b := PokeButton.make(%Grid, "", pos, PLAIN, CELL)
		b.pressed.connect(_on_day.bind(i))
		_days.append(b)
		# The date in the top-left corner, what's on underneath it.
		var face_z := PokeButton.CAP_FACE + 0.001
		var num := _cell_label(b, DAY_FONT, Vector3(-CELL.x * 0.5 + 0.006, CELL.y * 0.5 - 0.004, face_z))
		var preview := _cell_label(b, PREVIEW_FONT, Vector3(-CELL.x * 0.5 + 0.006, CELL.y * 0.5 - 0.034, face_z))
		_cell_labels.append([num, preview])
	_refresh()


static func _cell_label(parent: Node3D, font: int, pos: Vector3) -> Label3D:
	var l := Label3D.new()
	l.pixel_size = CELL_PX
	l.font_size = font
	l.outline_size = 0
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.line_spacing = -4
	l.position = pos
	parent.add_child(l)
	return l


func _widget_data(key: String, _value: Variant) -> void:
	if key in ["entries", "month"] and is_node_ready():
		_refresh()


func entries() -> Array:
	return data.get("entries", []) if data.get("entries") is Array else []


func entries_on(date: String) -> Array:
	return entries().filter(func(e): return e is Dictionary and str(e.get("date", "")) == date)


func _month() -> String:
	var m := str(data.get("month", ""))
	return m if _valid_month(m) else today().substr(0, 7)


func _refresh() -> void:
	if _days.is_empty():
		return
	var m := _month()
	var y := int(m.substr(0, 4))
	var mo := int(m.substr(5, 2))
	%Month.text = "%s %d" % [MONTHS[mo - 1], y]
	var first := Time.get_unix_time_from_datetime_dict({"year": y, "month": mo, "day": 1})
	var offset: int = Time.get_datetime_dict_from_unix_time(first)["weekday"] # 0 = Sunday
	var count := days_in_month(y, mo)
	var busy := {} # date -> [entries]
	for e in entries():
		if e is Dictionary:
			var d := str(e.get("date", ""))
			if not busy.has(d):
				busy[d] = []
			busy[d].append(e)
	var now := today()
	for i in 42:
		var day := i - offset + 1
		var b := _days[i]
		b.visible = day >= 1 and day <= count
		b.set_deferred("monitoring", b.visible) # may run inside a button's own press
		if not b.visible:
			continue
		var date := "%s-%02d" % [m, day]
		var on_day: Array = busy.get(date, [])
		b.color = TODAY if date == now else (BUSY if on_day.size() else PLAIN)
		b.set_text("")
		b.set_meta("date", date)
		_cell_labels[i][0].text = str(day)
		_cell_labels[i][1].text = cell_preview(on_day)
	var lines := []
	for e in upcoming(3):
		lines.append("%s %s  %s" % [_short_date(e["date"]), e.get("time", ""), e["text"]])
	%Upcoming.text = "Next:  " + ("\n".join(lines) if lines.size() else "nothing planned")


func _on_day(i: int) -> void:
	var b := _days[i]
	if not b.has_meta("date"):
		return
	var player := get_tree().get_first_node_in_group("local_player")
	if player:
		var at := b.global_position + global_basis.z * 0.15
		player.open_context_menu({"type": "calendar_day", "entity_id": entity_id, "date": b.get_meta("date"), "point": at}, at)


## What a day cell shows: its first entries, shortened, and how many more.
static func cell_preview(on_day: Array) -> String:
	var lines := []
	for e in on_day.slice(0, PREVIEW_LINES):
		var line := ("%s %s" % [str(e.get("time", "")).trim_suffix(":00") if str(e.get("time", "")).ends_with(":00") else e.get("time", ""), e.get("text", "")]).strip_edges()
		lines.append(line if line.length() <= PREVIEW_CHARS else line.substr(0, PREVIEW_CHARS - 1) + "…")
	if on_day.size() > PREVIEW_LINES:
		lines[-1] = "+%d more" % (on_day.size() - PREVIEW_LINES + 1)
	return "\n".join(lines)


## Entries from today on, soonest first.
func upcoming(limit: int) -> Array:
	var now := today()
	var out := entries().filter(func(e): return e is Dictionary and str(e.get("date", "")) >= now)
	return out.slice(0, limit)


func widget_menu_items(_menu: RadialMenu) -> Array:
	return [{"label": "This month", "do": func(): Widgets.request_op(entity_id, "month", {"month": today().substr(0, 7)})}]


# --- Operations ---------------------------------------------------------------------------

func op_perm(op: String) -> String:
	return "interact" if op in ["add_entry", "remove_entry", "month"] else ""


func server_op(peer: int, op: String, args: Dictionary) -> String:
	match op:
		"month":
			var m := str(args.get("month", ""))
			if _valid_month(m):
				Sync.set_data(entity_id, "month", m)
		"add_entry":
			return server_add_entry(str(args.get("date", "")), str(args.get("time", "")), str(args.get("text", "")), peer)
		"remove_entry":
			return server_remove_entries(str(args.get("date", "")), str(args.get("time", "")), str(args.get("text", "")), peer)
	return ""


## Server: add an entry. Returns "Error: …" or a confirmation.
func server_add_entry(date: String, time: String, text: String, by := 0) -> String:
	date = parse_date(date)
	if date == "":
		return "Error: the date must look like 2026-09-30 (or today / tomorrow)."
	var t := normalize_time(time)
	if t == "!":
		return "Error: the time must look like 14:30 or 2:30pm (or leave it empty for all day)."
	text = text.strip_edges().substr(0, 200)
	if text == "":
		return "Error: the entry needs some text."
	var list := entries().duplicate(true)
	if list.size() >= MAX_ENTRIES:
		list.pop_front()
	list.append({"date": date, "time": t, "text": text})
	list.sort_custom(func(a, b): return str(a["date"]) + str(a["time"]) < str(b["date"]) + str(b["time"]))
	Sync.set_data(entity_id, "entries", list)
	Sync.set_data(entity_id, "month", date.substr(0, 7))
	var line := "%s %s %s" % [date, t, text]
	AI.widget_note("%s added to calendar \"%s\": %s" % [Widgets._who(by), widget_name(), line.replace("  ", " ")])
	return "Added to %s: %s" % [widget_name(), line.replace("  ", " ")]


## Server: remove entries on `date` (at `time` if given, with `text` if given).
func server_remove_entries(date: String, time: String, text: String, by := 0) -> String:
	date = parse_date(date)
	var t := normalize_time(time)
	var keep := []
	var removed := 0
	for e in entries():
		var hit: bool = e is Dictionary and str(e.get("date", "")) == date \
				and (time.strip_edges() == "" or str(e.get("time", "")) == t) \
				and (text.strip_edges() == "" or str(e.get("text", "")) == text.strip_edges())
		if hit:
			removed += 1
		else:
			keep.append(e)
	if removed == 0:
		return "Error: no entry on %s%s." % [date, " at " + t if time.strip_edges() != "" else ""]
	Sync.set_data(entity_id, "entries", keep)
	AI.widget_note("%s removed %d entr%s on %s from calendar \"%s\"." % [Widgets._who(by), removed, "y" if removed == 1 else "ies", date, widget_name()])
	return "Removed %d entr%s." % [removed, "y" if removed == 1 else "ies"]


func ai_summary() -> String:
	var lines := []
	for e in upcoming(12):
		lines.append(("%s %s %s" % [e["date"], e.get("time", ""), e["text"]]).replace("  ", " "))
	return "%d entries; upcoming: %s" % [entries().size(), "; ".join(lines) if lines.size() else "none"]


# --- Dates ----------------------------------------------------------------------------------

static func today() -> String:
	return Time.get_date_string_from_system()


static func days_in_month(y: int, m: int) -> int:
	if m == 2:
		return 29 if (y % 4 == 0 and y % 100 != 0) or y % 400 == 0 else 28
	return 30 if m in [4, 6, 9, 11] else 31


static func _valid_month(m: String) -> bool:
	return m.length() == 7 and m[4] == "-" and m.substr(0, 4).is_valid_int() and int(m.substr(5, 2)) in range(1, 13)


static func _shift_month(m: String, by: int) -> String:
	var n := int(m.substr(0, 4)) * 12 + int(m.substr(5, 2)) - 1 + by
	return "%04d-%02d" % [n / 12, n % 12 + 1]


static func _short_date(date: String) -> String:
	return "%s %d" % [MONTHS[int(date.substr(5, 2)) - 1].substr(0, 3), int(date.substr(8, 2))]


## "YYYY-MM-DD" (also accepts today / tomorrow / YYYY/MM/DD), or "" if invalid.
static func parse_date(s: String) -> String:
	s = s.strip_edges().to_lower().replace("/", "-")
	var now := Time.get_unix_time_from_system()
	if s == "today":
		return today()
	if s == "tomorrow":
		return Time.get_date_string_from_unix_time(int(now) + 86400 + Time.get_time_zone_from_system()["bias"] * 60)
	var parts := s.split("-")
	if parts.size() != 3 or not (parts[0].is_valid_int() and parts[1].is_valid_int() and parts[2].is_valid_int()):
		return ""
	var y := int(parts[0])
	var m := int(parts[1])
	var d := int(parts[2])
	if y < 1970 or y > 2200 or m < 1 or m > 12 or d < 1 or d > days_in_month(y, m):
		return ""
	return "%04d-%02d-%02d" % [y, m, d]


## "HH:MM" (24 h) from "14:30", "2:30pm", "2pm", "9"; "" for none; "!" if invalid.
static func normalize_time(s: String) -> String:
	s = s.strip_edges().to_lower().replace(" ", "").replace(".", ":")
	if s == "" or s == "allday":
		return ""
	var pm := s.ends_with("pm")
	var am := s.ends_with("am")
	if pm or am:
		s = s.substr(0, s.length() - 2)
	var parts := s.split(":")
	if parts.size() > 2 or not parts[0].is_valid_int() or (parts.size() == 2 and not parts[1].is_valid_int()):
		return "!"
	var h := int(parts[0])
	var mi := int(parts[1]) if parts.size() == 2 else 0
	if pm and h < 12:
		h += 12
	elif am and h == 12:
		h = 0
	if h < 0 or h > 23 or mi < 0 or mi > 59:
		return "!"
	return "%02d:%02d" % [h, mi]


## Keyboard input "14:30 Team sync" / "2pm Lunch" / "Offsite" -> [time, text].
static func split_time_text(s: String) -> Array:
	s = s.strip_edges()
	var first := s.get_slice(" ", 0)
	var t := normalize_time(first)
	if first != "" and t != "!" and t != "" and (first[0].is_valid_int()):
		return [t, s.substr(first.length()).strip_edges()]
	return ["", s]
