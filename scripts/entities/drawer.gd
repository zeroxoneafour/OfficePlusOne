class_name FileDrawer extends Prop
## A chest of drawers (scenes/entities/props/drawer.tscn) linked to a folder on
## the host's computer (admins: its menu → Set folder…). Pull the top drawer
## open by its handle (or trigger / E on it) and a file browser opens for you:
## poke a folder to go in, grab a file to pull a copy out into your hand (or
## poke it to have it float out). Originals are never changed. Closing the
## drawer closes the browser.
## data: {path, open, opened_by, locked}

const OPEN_DIST := 0.3
## Pulled this far, it opens; pushed back under CLOSE_AT, it closes.
const OPEN_AT := 0.14
const CLOSE_AT := 0.06
const MAX_LIST := 200

var _slide := 0.0
var _drag_from := 0.0
var _drag_hand_from := Vector3.ZERO
var _tween: Tween


func _build() -> void:
	super()
	%Handle.drag_started.connect(_on_drag_started)
	%Handle.drag_ended.connect(_on_drag_ended)
	_set_slide(OPEN_DIST if is_open() else 0.0)
	_show_folder()


func _data_changed(key: String, value: Variant) -> void:
	super(key, value)
	if key == "path" and is_node_ready():
		_show_folder()
	if key == "open" and is_node_ready():
		if not %Handle.hand:
			_animate_to(OPEN_DIST if value == true else 0.0)
		if value == true and int(data.get("opened_by", 0)) == Net.my_id() and Net.has_local_player():
			_show_browser.call_deferred()


func _show_folder() -> void:
	%FolderLabel.text = folder().get_file() if folder() != "" else "(no folder)"


func is_open() -> bool:
	return data.get("open", false) == true


func folder() -> String:
	return str(data.get("path", ""))


func _set_slide(d: float) -> void:
	_slide = d
	%Drawer.position.z = d


func _animate_to(d: float) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(_set_slide, _slide, d, 0.25).set_trans(Tween.TRANS_SINE)


func _on_drag_started(hand: Hand) -> void:
	if _tween:
		_tween.kill()
	_drag_from = _slide
	_drag_hand_from = hand.global_position


func _on_drag_ended(_hand: Hand) -> void:
	var want := _slide > (OPEN_AT if not is_open() else CLOSE_AT)
	_animate_to(OPEN_DIST if want else 0.0)
	if want != is_open():
		Widgets.request_op(entity_id, "open" if want else "close")


func _process(delta: float) -> void:
	super(delta)
	var hand: Hand = %Handle.hand
	if hand and is_instance_valid(hand):
		# The drawer follows the hand along its runners.
		_set_slide(clampf(_drag_from + (hand.global_position - _drag_hand_from).dot(global_basis.z), 0.0, OPEN_DIST))
		if not is_open() and _slide > OPEN_AT:
			Widgets.request_op(entity_id, "open")
			data["open"] = true # predicted until the server confirms
		elif is_open() and _slide < CLOSE_AT:
			Widgets.request_op(entity_id, "close")
			data["open"] = false


func _show_browser() -> void:
	var player := get_tree().get_first_node_in_group("local_player")
	if player:
		var at := global_position + global_basis.z * 0.55 + Vector3(0, 0.85, 0)
		player.open_context_menu({"type": "drawer_files", "entity_id": entity_id, "point": at}, at)


func server_interact(peer: int) -> void:
	server_op(peer, "close" if is_open() else "open", {})


func menu_items(menu: RadialMenu) -> Array:
	var id := entity_id
	var items := [{"label": "Close" if is_open() else "Open", "do": func():
		Widgets.request_op(id, "close" if is_open() else "open")
		menu.close()}]
	items.append({"label": "Set folder…", "enabled": Net.my_can("decorate"), "why": "Only admins can choose which folder a drawer shows.",
			"do": func():
				var current := folder()
				var player := menu.player
				menu.close()
				player.open_keyboard("Folder on the host's computer (e.g. ~/Documents)", current,
						func(t: String): Widgets.request_op(id, "set_path", {"path": t}))})
	return items


# --- Server ------------------------------------------------------------------------------------

func op_perm(op: String) -> String:
	match op:
		"open", "close", "list", "pull":
			return "interact"
		"set_path":
			return "decorate"
	return ""


func server_op(peer: int, op: String, args: Dictionary) -> String:
	match op:
		"open":
			Sync.set_data(entity_id, "opened_by", peer)
			Sync.set_data(entity_id, "open", true)
			if _root() == "":
				return "This drawer isn't linked to a folder yet (admins: its menu → Set folder…)."
		"close":
			Sync.set_data(entity_id, "open", false)
		"set_path":
			var p := expand(str(args.get("path", "")))
			if p != "" and not DirAccess.dir_exists_absolute(p):
				return "Error: there's no folder %s on the host's computer." % p
			Sync.set_data(entity_id, "path", p)
			return "Drawer linked to %s" % p if p != "" else "Drawer unlinked."
		"list":
			var rel := str(args.get("rel", ""))
			var full := resolve(rel)
			if full == "" or not DirAccess.dir_exists_absolute(full):
				Widgets.server_send_listing(peer, entity_id, rel, [], "This drawer isn't linked to a folder." if _root() == "" else "That folder isn't there any more.")
			else:
				Widgets.server_send_listing(peer, entity_id, rel, list_dir(full))
		"pull":
			return _server_pull(peer, str(args.get("rel", "")), int(args.get("hand", -1)))
	return ""


static func expand(p: String) -> String:
	p = p.strip_edges()
	if p.begins_with("~"):
		p = OS.get_environment("HOME" if OS.get_name() != "Windows" else "USERPROFILE") + p.substr(1)
	return p.simplify_path() if p != "" else ""


func _root() -> String:
	var r := folder()
	return r if r != "" and DirAccess.dir_exists_absolute(r) else ""


## Absolute path of `rel` inside the drawer's folder, or "" if it would leave it.
func resolve(rel: String) -> String:
	var root := _root()
	if root == "":
		return ""
	rel = rel.replace("\\", "/")
	for part in rel.split("/", false):
		if part == ".." or part == "." or part.contains(":"):
			return ""
	var full := root.path_join(rel).simplify_path() if rel != "" else root
	var base := root.trim_suffix("/")
	return full if full == root or full.begins_with(base + "/") else ""


## Folders first, then files; hidden entries skipped. [{n, d, s}]
static func list_dir(full: String) -> Array:
	var out := []
	var dirs := Array(DirAccess.get_directories_at(full))
	var files := Array(DirAccess.get_files_at(full))
	dirs.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	files.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	for d in dirs:
		if not d.begins_with(".") and out.size() < MAX_LIST:
			out.append({"n": d, "d": true, "s": 0})
	for f in files:
		if not f.begins_with(".") and out.size() < MAX_LIST:
			var fa := FileAccess.open(full.path_join(f), FileAccess.READ)
			out.append({"n": f, "d": false, "s": fa.get_length() if fa else 0})
	return out


## A copy of the file becomes a document: in the hand that pulled it
## (`hand` 0/1), or floating in front of the person (`hand` -1).
func _server_pull(peer: int, rel: String, hand: int) -> String:
	var full := resolve(rel)
	if full == "" or rel == "" or not FileAccess.file_exists(full):
		return "Error: that file isn't there any more."
	var limit := int(Config.get_value("server", "max_upload_mb")) * 1048576
	var fa := FileAccess.open(full, FileAccess.READ)
	if not fa:
		return "Error: couldn't read %s." % rel.get_file()
	if fa.get_length() > limit:
		return "Error: %s is too big to take out (limit %d MB)." % [rel.get_file(), limit / 1048576]
	var fid := Files.server_add(rel.get_file(), fa.get_buffer(fa.get_length()))
	var xf := Sync.hand_out_xform(peer)
	var extra := {"pinned": true}
	var h: Variant = Sync.hand_xform(peer, hand) if hand in [0, 1] else null
	if h is Transform3D:
		xf = Transform3D((h as Transform3D).basis.orthonormalized(), (h as Transform3D).origin)
		extra["adopt"] = [peer, hand]
	Files.server_spawn_document(fid, xf, extra)
	return ""
