extends RadialMenu
## The watch's Room menu (scenes/ui/menus/room_menu.tscn): the room's size and
## floor color, locking/clearing objects, renaming the room,
## what guests may do, saving/loading the room, and requests to join.
## Items you lack permission for are greyed out (the server checks too).
## (Adding objects and AIs is on the floor's context menu: point at the floor.)

const SIZE := [["Wider", "w+"], ["Narrower", "w-"], ["Deeper", "d+"], ["Shallower", "d-"],
		["Taller", "h+"], ["Lower", "h-"], ["Floor color", "floor"]]
## Saves listed at once (newest first).
const SAVES_SHOWN := 5

var _in_size := false


func _ready() -> void:
	super()
	Office.changed.connect(_show_size)


func _title() -> String:
	return str(Office.state.get("name", "Room"))


func _root_items() -> Array:
	_in_size = false
	var knocks := Net.prompts_of("knock")
	var admin_only := "Only admins can change the room."
	return [
		{"label": "Room size", "sub": _size_items, "enabled": Net.my_can("decorate"), "why": admin_only},
		{"label": "Objects", "sub": _object_items},
		{"label": "Rename room", "enabled": Net.my_can("decorate"), "why": admin_only, "do": _rename},
		{"label": "Permissions", "sub": _perm_items, "enabled": Net.my_can("admit"), "why": "Only admins can change what guests may do."},
		{"label": "Saves", "sub": _save_items},
		{"label": "Join requests (%d)" % knocks.size() if knocks.size() else "Join requests", "sub": _knock_items,
				"enabled": Net.my_can("admit") and not knocks.is_empty(),
				"why": "No one is waiting to join." if Net.my_can("admit") else "Only admins can let people in."},
	]


# --- Size ------------------------------------------------------------------------------

## Stays open; the hint shows the current size as it changes.
func _size_items() -> Array:
	_in_size = true
	var items := []
	for a in SIZE:
		var step: String = a[1]
		items.append({"label": a[0], "do": func(): Office.request_action("room", {"step": step})})
	_show_size.call_deferred()
	return items


func _show_size() -> void:
	if _in_size and not _stack.is_empty() and is_inside_tree():
		var sz := Office.size()
		%Hint.text = "%.1f m wide × %.1f m deep × %.2f m high" % [sz.x, sz.z, sz.y]


# --- Objects ---------------------------------------------------------------------------

func _object_items() -> Array:
	_in_size = false
	var lock_why := "Locking and unlocking is limited to admins here."
	return [
		{"label": "Lock all", "enabled": Net.my_can("lock"), "why": lock_why, "do": func():
			Office.request_action("lock_all", {"on": true})
			Net.toast.emit("Everything is locked in place.")},
		{"label": "Unlock all", "enabled": Net.my_can("lock"), "why": lock_why, "do": func():
			Office.request_action("lock_all", {"on": false})
			Net.toast.emit("Everything can be moved.")},
		{"label": "Clear loose", "color": DANGER, "enabled": Net.my_can("decorate"), "why": "Only admins can clear the room.",
				"sub": func(): return confirm("Remove unlocked objects", func(): Office.request_action("clear"))},
	]


func _rename() -> void:
	var p := player
	close()
	p.open_keyboard("Name this room", str(Office.state.get("name", "")), func(t: String):
		if t != "":
			Office.request_action("rename", {"name": t}))


# --- Guest permissions -------------------------------------------------------------------

## Toggle what ordinary members may do (admins always can).
func _perm_items() -> Array:
	_in_size = false
	var items := []
	for perm in Net.GRANTABLE:
		var p: String = perm
		var on := Office.member_may(p)
		items.append({"label": "%s: %s" % [Net.GRANTABLE[p], "guests yes" if on else "admins only"],
				"color": Color("#4caf50") if on else NEUTRAL, "do": func():
					Office.request_action("member_perm", {"perm": p, "on": not on})
					_refresh_perms.call_deferred()})
	return items


func _refresh_perms() -> void:
	# The change round-trips through the server; rebuild once it's applied.
	await get_tree().create_timer(0.15).timeout
	if is_inside_tree() and not _stack.is_empty():
		refresh([{"label": "Back", "color": NEUTRAL, "do": back}] + _perm_items())


# --- Saves ---------------------------------------------------------------------------------

func _save_items() -> Array:
	_in_size = false
	var items := [{"label": "Save as…", "color": Color("#4caf50"), "do": _save_as}]
	for sv in Saves.list_saves().slice(0, SAVES_SHOWN):
		var save_name: String = sv["name"]
		items.append({"label": "Autosave" if save_name == Saves.AUTOSAVE else save_name, "sub": func(): return _one_save(save_name)})
	if Net.mode != "host":
		%Hint.text = "Saves go to your own device; load them in your own office"
	return items


func _one_save(save_name: String) -> Array:
	var host := Saves.can_load()
	return [
		{"label": "Load", "enabled": host, "why": "Only the host can load a saved room, in their own office.",
				"sub": func(): return confirm("Replace this room", func(): Saves.request_load(save_name))},
		{"label": "Delete", "color": DANGER, "enabled": save_name != Saves.AUTOSAVE, "why": "The autosave is kept automatically.",
				"sub": func(): return confirm("Delete \"%s\"" % save_name, func(): Saves.delete_file(save_name))},
	]


func _save_as() -> void:
	var p := player
	close()
	p.open_keyboard("Name this save", str(Office.state.get("name", "")), func(t: String):
		if t != "":
			Saves.request_save_as(t))


# --- Join requests -------------------------------------------------------------------------

func _knock_items() -> Array:
	_in_size = false
	var items := []
	for k in Net.prompts_of("knock"):
		var id: int = k[0]
		var who: String = str(k[1]).get_slice(" is knocking", 0)
		items.append({"label": who, "sub": func(): return [
			{"label": "Let in", "do": func():
				Net.answer_prompt(id, true)
				home()},
			{"label": "Decline", "color": DANGER, "do": func():
				Net.answer_prompt(id, false)
				home()},
		]})
	return items
