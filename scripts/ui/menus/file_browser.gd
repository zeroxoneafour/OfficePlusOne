extends RadialMenu
## A drawer's floating file browser (scenes/ui/menus/file_browser.tscn), opened
## when you pull the drawer open. Folders and files sit around the ring: poke a
## folder to go in (Up goes back out), grab a file to pull a copy of it into
## your hand, or poke it to have the copy float out in front of you. It closes
## when the drawer closes.

const PAGE := 9

var _rel := ""
var _entries: Array = []
var _page := 0
var _error := ""
var _loading := true


func _drawer() -> FileDrawer:
	return Sync.entities.get(int(target.get("entity_id", 0))) as FileDrawer


func _ready() -> void:
	Widgets.listing_received.connect(_on_listing)
	super()
	_load("")


func _title() -> String:
	var d := _drawer()
	var root := d.folder().get_file() if d and d.folder() != "" else "Drawer"
	return root + ("/" + _rel if _rel != "" else "")


func _load(rel: String) -> void:
	_rel = rel
	_loading = true
	_page = 0
	Widgets.request_listing(int(target.get("entity_id", 0)), rel)
	if is_inside_tree():
		%Title.text = _title()
		refresh(_root_items())


func _on_listing(drawer_id: int, rel: String, entries: Array, error: String) -> void:
	if drawer_id != int(target.get("entity_id", 0)) or rel != _rel:
		return
	_entries = entries
	_error = error
	_loading = false
	refresh(_root_items())


func _root_items() -> Array:
	var items := []
	if _rel != "":
		items.append({"label": "Up", "color": NEUTRAL, "do": func(): _load(_rel.get_base_dir() if _rel.contains("/") else "")})
	if _loading:
		items.append({"label": "Opening…", "color": NEUTRAL, "do": func(): pass})
		return items
	if _error != "":
		items.append({"label": _error, "color": NEUTRAL, "do": func(): pass})
		return items
	if _entries.is_empty():
		items.append({"label": "(empty)", "color": NEUTRAL, "do": func(): pass})
	var pages := maxi(1, ceili(_entries.size() / float(PAGE)))
	for e in _entries.slice(_page * PAGE, _page * PAGE + PAGE):
		var entry: Dictionary = e
		var path := _rel.path_join(str(entry["n"])) if _rel != "" else str(entry["n"])
		if entry.get("d", false) == true:
			items.append({"label": _short(str(entry["n"])) + "/", "color": Color("#c9a227"), "do": _load.bind(path)})
		else:
			items.append({"label": "%s\n%s" % [_short(str(entry["n"])), Files.human_size(int(entry.get("s", 0)))],
					"color": Color("#81b29a"), "file": path, "do": func(): _pull(path, -1)})
	if pages > 1:
		items.append({"label": "More (%d/%d)" % [_page + 1, pages], "color": SUBMENU, "do": func():
			_page = (_page + 1) % pages
			refresh(_root_items())})
	return items


func show_items(items: Array, rearm := true) -> void:
	super(items, rearm)
	%Hint.text = "grab a file to take a copy · poke a folder to open it"
	# File buttons can also be grabbed: closing your hand on one pulls the copy into it.
	var buttons := %Buttons.get_children().filter(func(b): return not b.is_queued_for_deletion())
	for i in mini(items.size(), buttons.size()):
		if items[i].has("file"):
			var path: String = items[i]["file"]
			var h := GrabHandle.make(buttons[i], Vector3(0.07, 0.07, 0.08), (buttons[i] as RadialButton).face_center())
			h.drag_started.connect(func(hand: Hand): _pull(path, hand.index))


func _pull(path: String, hand: int) -> void:
	Widgets.request_op(int(target.get("entity_id", 0)), "pull", {"rel": path, "hand": hand})


static func _short(n: String) -> String:
	return n if n.length() <= 16 else n.substr(0, 13) + "…"


func _process(delta: float) -> void:
	super(delta)
	var d := _drawer()
	if not d or not d.is_open():
		close()
