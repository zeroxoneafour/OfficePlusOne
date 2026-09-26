extends Node
## Room saves. A save is a JSON snapshot of the whole office:
## room size/colors/name/whiteboard and guest permissions; every object with its
## transform and state (locked, lamp on/off, paint color…); documents with their
## file contents; clipboards; AI agents with their profile (persona, voice…),
## position and the chair they sit on; and any images those use.
##
## The server autosaves (every AUTOSAVE_INTERVAL s, when you leave your office,
## and when the app closes or is paused) and loads the autosave on the next
## start. From the watch (Room → Saves) you can save under a name (typed on
## the virtual keyboard), load (only the host, in their own office) and
## delete. A guest's "Save as" downloads the host's room into the guest's own
## saves, so they can load it when hosting later.

signal saves_changed

const DIR := "user://saves"
const AUTOSAVE := "autosave"
const AUTOSAVE_INTERVAL := 60.0
## 2: the room's single whiteboard became a whiteboard widget ("Main board").
const FORMAT := 2
## Files from before saves existed (migrated on first start).
const LEGACY_ROOM := "user://room.json"
const LEGACY_AGENTS := "user://agents.json"

var _timer := AUTOSAVE_INTERVAL
## Set by the lobby: open this save (instead of the autosave) when hosting.
var startup_save := ""


# --- Files ------------------------------------------------------------------------------

static func sanitize(save_name: String) -> String:
	var out := ""
	for ch in save_name.strip_edges():
		if ch.is_valid_identifier() or ch in "0123456789 -_'":
			out += ch
	out = out.strip_edges().substr(0, 40)
	return out if out != "" else "room"


static func path_for(save_name: String) -> String:
	return DIR.path_join(sanitize(save_name) + ".json")


## [{"name", "saved_at" (unix), "room"}] newest first (the autosave included).
func list_saves() -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(DIR):
		return out
	for f in DirAccess.get_files_at(DIR):
		if not f.ends_with(".json"):
			continue
		var snap := read_file(f.get_basename())
		out.append({"name": f.get_basename(), "saved_at": float(snap.get("saved_at", 0)),
				"room": str(snap.get("room", {}).get("name", ""))})
	out.sort_custom(func(a, b): return a["saved_at"] > b["saved_at"])
	return out


func has_save(save_name: String) -> bool:
	return FileAccess.file_exists(path_for(save_name))


func write_file(save_name: String, snap: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := path_for(save_name)
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if not f:
		push_warning("[Saves] Can't write %s" % path)
		return ""
	f.store_string(JSON.stringify(snap))
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"), ProjectSettings.globalize_path(path))
	saves_changed.emit()
	return path


func read_file(save_name: String) -> Dictionary:
	var path := path_for(save_name)
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


func delete_file(save_name: String) -> void:
	if sanitize(save_name) != AUTOSAVE:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path_for(save_name)))
		saves_changed.emit()


# --- Server: snapshot / restore ----------------------------------------------------------

func snapshot() -> Dictionary:
	var images := {}
	var room: Dictionary = Office.state.duplicate(true)
	var entities := []
	var index_of := {} # entity id -> index in `entities`
	for e: NetBody in Sync.entities.values():
		if e is AgentBody:
			continue
		var data: Dictionary = e.saved_data()
		for transient in ["held_by", "agent_holder", "seated", "sitting_on", "adopt", "open", "opened_by", "ringing", "stowed"]:
			data.erase(transient)
		if int(e.data.get("agent_holder", 0)) != 0 or e.is_stowed():
			data["pinned"] = true # was in an AI's hand: keep it floating there
		var ent := {"kind": e.kind, "xform": _xf_to_array(e.global_transform), "data": data}
		match e.kind:
			"document":
				var f := Files.server_get(int(data.get("file_id", 0)))
				if not f.is_empty():
					ent["file"] = {"name": f["name"], "b64": Marshalls.raw_to_base64(f["bytes"])}
			"clipboard":
				for p in data.get("pages", []):
					if p is Dictionary:
						_note_image(images, int(p.get("image", 0)))
		_note_image(images, int(data.get("image", 0))) # documents, whiteboards
		index_of[e.entity_id] = entities.size()
		entities.append(ent)
	var agents := []
	for b in AI._brains.values():
		var a: NetBody = Sync.entities.get(b.agent_id)
		if not a:
			continue
		var entry := {"profile": b.profile.duplicate(true), "xform": _xf_to_array(a.global_transform)}
		var chair := int(a.data.get("sitting_on", 0))
		if index_of.has(chair):
			entry["sit_on"] = index_of[chair]
		agents.append(entry)
	var image_data := {}
	for id in images:
		if Sync._image_bytes.has(id):
			image_data[str(id)] = Marshalls.raw_to_base64(Sync._image_bytes[id])
	return {"format": FORMAT, "saved_at": Time.get_unix_time_from_system(), "room": room,
			"entities": entities, "agents": agents, "images": image_data}


## Server: replace the whole office with `snap`.
func apply(snap: Dictionary) -> void:
	for b in AI._brains.values().duplicate():
		AI.server_remove_agent(b.agent_id)
	for id in Sync.entities.keys():
		Sync.despawn(id)
	var remap := {} # saved image id -> new image id
	var saved_images: Dictionary = snap.get("images", {}) if snap.get("images") is Dictionary else {}
	for old in saved_images:
		remap[int(old)] = Sync.add_image(Marshalls.base64_to_raw(str(saved_images[old])))
	var room: Dictionary = Office.default_state()
	if snap.get("room") is Dictionary:
		room.merge(snap["room"], true)
	# Before format 2 the room had one built-in whiteboard: it becomes a widget.
	var old_board: Variant = room.get("board") if int(snap.get("format", 1)) < 2 else null
	room.erase("board")
	if str(room.get("name", "")) == "":
		room["name"] = Net.server_name()
	Office.replace_state(room)
	var ids := []
	for ent in snap.get("entities", []):
		if not ent is Dictionary or not str(ent.get("kind", "")) in Sync.Entities.SCENES:
			ids.append(0)
			continue
		var data: Dictionary = ent.get("data", {}).duplicate(true) if ent.get("data") is Dictionary else {}
		if data.has("image"):
			data["image"] = remap.get(int(data["image"]), 0)
		if data.get("pages") is Array:
			for p in data["pages"]:
				if p is Dictionary and p.has("image"):
					p["image"] = remap.get(int(p["image"]), 0)
		if ent["kind"] == "document":
			var f: Dictionary = ent.get("file", {})
			if f.is_empty():
				ids.append(0)
				continue
			data["file_id"] = Files.server_add(str(f.get("name", "file")), Marshalls.base64_to_raw(str(f.get("b64", ""))))
		ids.append(Sync.spawn(ent["kind"], _array_to_xf(ent.get("xform", [])), data))
	if old_board != null:
		var b: Dictionary = old_board.duplicate() if old_board is Dictionary else {}
		b["image"] = remap.get(int(b.get("image", 0)), 0)
		Office.add_main_board(b)
	for a in snap.get("agents", []):
		if not a is Dictionary:
			continue
		var agent_id: int = AI.server_create_agent(a.get("profile", {}) if a.get("profile") is Dictionary else {}, 0, _array_to_xf(a.get("xform", [])))
		var seat := int(a.get("sit_on", -1))
		if seat >= 0 and seat < ids.size() and Sync.entities.has(ids[seat]):
			Sync.seat_agent(Sync.entities[agent_id], Sync.entities[ids[seat]])


## Server start: restore the autosave (or migrate the pre-save files). Returns
## false when there's nothing to restore (a brand-new office).
func server_load_startup() -> bool:
	if startup_save != "":
		var chosen := read_file(startup_save)
		var chosen_name := startup_save
		startup_save = ""
		if not chosen.is_empty():
			apply(chosen)
			autosave()
			print("[Saves] Opened \"%s\"" % chosen_name)
			return true
	var snap := read_file(AUTOSAVE)
	if not snap.is_empty():
		apply(snap)
		print("[Saves] Restored the office from the autosave")
		return true
	return _migrate_legacy()


func autosave() -> void:
	if Net.is_server() and not Office.state.is_empty() and not Net.tutorial:
		write_file(AUTOSAVE, snapshot())


func _process(delta: float) -> void:
	if not Net.is_server() or Office.state.is_empty():
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = AUTOSAVE_INTERVAL
		autosave()


func _notification(what: int) -> void:
	# Closing the window, or the headset pausing the app (Android).
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		autosave()


# --- Watch actions -------------------------------------------------------------------

## Loading replaces the room, so only the host, in their own office, may do it.
func can_load() -> bool:
	return Net.mode == "host"


## Save the current room under `save_name` on *this* machine. As a guest, the
## host sends you a copy of their room.
func request_save_as(save_name: String) -> void:
	if Net.is_server():
		var path := write_file(save_name, snapshot())
		Net.toast.emit("Saved \"%s\"" % sanitize(save_name) if path != "" else "Couldn't save.")
	elif Net.in_session:
		_snapshot_request.rpc_id(1, sanitize(save_name))
		Net.toast.emit("Copying this room…")


@rpc("any_peer", "reliable")
func _snapshot_request(save_name: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if Net.is_server() and Net.players.has(peer):
		Files._send_blob(peer, "snapshot", {"name": save_name}, JSON.stringify(snapshot()).to_utf8_buffer())


## Client: a copy of the host's room arrived (see Files._chunk).
func receive_snapshot(save_name: String, bytes: PackedByteArray) -> void:
	var d: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if d is Dictionary:
		write_file(save_name, d)
		Net.toast.emit("Saved a copy of this room as \"%s\"" % sanitize(save_name))


func request_load(save_name: String) -> void:
	if not can_load():
		Net.toast.emit("Only the host can load a saved room, in their own office.")
		return
	var snap := read_file(save_name)
	if snap.is_empty():
		Net.toast.emit("That save couldn't be read.")
		return
	apply(snap)
	autosave()
	Net.toast.emit("Loaded \"%s\"" % sanitize(save_name))


# --- Helpers ---------------------------------------------------------------------------

func _note_image(images: Dictionary, id: int) -> void:
	if id > 0:
		images[id] = true


static func _xf_to_array(t: Transform3D) -> Array:
	var b := t.basis
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, t.origin.x, t.origin.y, t.origin.z]


static func _array_to_xf(a: Variant) -> Transform3D:
	if not a is Array or a.size() != 12:
		return Transform3D.IDENTITY
	return Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])).orthonormalized(),
			Vector3(a[9], a[10], a[11]))


## Before saves existed the room kept size/colors in room.json and agents in
## agents.json. Turn those into the new office once, then move them aside.
func _migrate_legacy() -> bool:
	if not FileAccess.file_exists(LEGACY_ROOM) and not FileAccess.file_exists(LEGACY_AGENTS):
		return false
	var room := Office.default_state()
	var old_room: Variant = JSON.parse_string(FileAccess.get_file_as_string(LEGACY_ROOM)) if FileAccess.file_exists(LEGACY_ROOM) else null
	if old_room is Dictionary:
		if old_room.get("size") is Array and old_room["size"].size() == 3:
			room["size"] = old_room["size"]
		if old_room.get("colors") is Dictionary:
			room["colors"].merge(old_room["colors"], true)
	room["name"] = Net.server_name()
	Office.replace_state(room)
	Office.furnish()
	var old_agents: Variant = JSON.parse_string(FileAccess.get_file_as_string(LEGACY_AGENTS)) if FileAccess.file_exists(LEGACY_AGENTS) else null
	if old_agents is Array:
		for a in old_agents:
			if a is Dictionary:
				var pos: Array = a.get("pos", [0, 0, -2])
				var xf := Transform3D(Basis(Vector3.UP, float(a.get("yaw", 0.0))), Vector3(pos[0], pos[1], pos[2]))
				AI.server_create_agent(a.get("profile", {}) if a.get("profile") is Dictionary else {}, 0, xf)
	for p in [LEGACY_ROOM, LEGACY_AGENTS]:
		if FileAccess.file_exists(p):
			DirAccess.rename_absolute(ProjectSettings.globalize_path(p), ProjectSettings.globalize_path(p + ".migrated"))
	autosave()
	print("[Saves] Migrated the old room.json/agents.json into the autosave")
	return true
