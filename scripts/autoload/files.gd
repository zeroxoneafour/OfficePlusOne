extends Node
## Files that exist physically in the room as "document" items. The server
## keeps the bytes; the item only carries metadata and a preview. People bring
## files in (drag onto the desktop window, or watch → Me → Import files, which
## reads the inbox folder), pass them around by hand, give them to AIs, and
## pull the trigger while holding one to save a copy to their device.

const CHUNK := 48 * 1024
const MIME := {
	"txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "json": "application/json",
	"html": "text/html", "htm": "text/html", "xml": "application/xml", "svg": "image/svg+xml",
	"py": "text/x-python", "gd": "text/plain", "js": "text/javascript", "ts": "text/plain",
	"c": "text/plain", "cpp": "text/plain", "h": "text/plain", "rs": "text/plain", "java": "text/plain",
	"yaml": "text/yaml", "yml": "text/yaml", "toml": "text/plain", "ini": "text/plain", "log": "text/plain",
	"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif",
	"pdf": "application/pdf",
	"pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
	"docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	"xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	"zip": "application/zip",
}

## server: file_id -> {"name": String, "mime": String, "bytes": PackedByteArray}
var _store := {}
var _next_id := 1
var _next_transfer := 1
## "sender:transfer" -> {"kind", "meta", "parts": Array, "got": int, "n": int}
var _incoming := {}


func reset() -> void:
	_store.clear()
	_incoming.clear()
	_next_id = 1


static func mime_for(filename: String) -> String:
	return MIME.get(filename.get_extension().to_lower(), "application/octet-stream")


static func is_text(mime: String) -> bool:
	return mime.begins_with("text/") or mime in ["application/json", "application/xml", "image/svg+xml"]


static func is_image(mime: String) -> bool:
	return mime in ["image/png", "image/jpeg", "image/webp", "image/gif"]


static func human_size(n: int) -> String:
	return "%d B" % n if n < 1024 else ("%.0f KB" % (n / 1024.0) if n < 1048576 else "%.1f MB" % (n / 1048576.0))


# --- Server store -------------------------------------------------------------

func server_add(filename: String, bytes: PackedByteArray) -> int:
	var id := _next_id
	_next_id += 1
	filename = Exporter.sanitize_filename(filename, ".bin")
	_store[id] = {"name": filename, "mime": mime_for(filename), "bytes": bytes}
	return id


func server_get(file_id: int) -> Dictionary:
	return _store.get(file_id, {})


## Spawn a physical document for a stored file. Returns the entity id.
func server_spawn_document(file_id: int, xform: Transform3D, extra := {}) -> int:
	var f := server_get(file_id)
	if f.is_empty():
		return 0
	var data := {"file_id": file_id, "name": f["name"], "mime": f["mime"], "size": f["bytes"].size(), "preview": "", "image": 0}
	if is_text(f["mime"]) and f["mime"] != "image/svg+xml":
		data["preview"] = f["bytes"].slice(0, 2000).get_string_from_utf8().substr(0, 700)
	elif f["mime"] == "image/svg+xml":
		data["image"] = Sync.add_svg(f["bytes"].get_string_from_utf8())
	elif is_image(f["mime"]):
		data["image"] = Sync.add_image(f["bytes"])
	data.merge(extra, true)
	return Sync.spawn("document", xform, data)


## Send a stored file to a player's device (they save it locally).
func server_send_to(peer: int, file_id: int) -> void:
	var f := server_get(file_id)
	if f.is_empty():
		return
	if peer == Net.my_id() and Net.has_local_player():
		Net.toast.emit("Saved %s" % Exporter.save_local({"filename": f["name"], "bytes": f["bytes"]}))
	else:
		_send_blob(peer, "download", {"name": f["name"]}, f["bytes"])


# --- Client: bringing files in -----------------------------------------------------

func upload(filename: String, bytes: PackedByteArray) -> void:
	if Net.is_server():
		_srv_upload(Net.my_id(), filename, bytes)
	elif Net.in_session:
		_send_blob(1, "upload", {"name": filename}, bytes)


func upload_path(path: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		Net.toast.emit("Couldn't read %s" % path.get_file())
		return
	upload(path.get_file(), bytes)


## Folder whose files watch → Me → Import files brings into the room.
static func inbox_dir() -> String:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if OS.get_name() != "Android" and docs != "" and docs.is_absolute_path():
		return docs.path_join("OfficePlusOne").path_join("inbox")
	return ProjectSettings.globalize_path("user://inbox")


## Uploads every file in the inbox, then moves them to inbox/imported.
func import_inbox() -> int:
	var dir := inbox_dir()
	DirAccess.make_dir_recursive_absolute(dir.path_join("imported"))
	var count := 0
	for fname in DirAccess.get_files_at(dir):
		upload_path(dir.path_join(fname))
		DirAccess.rename_absolute(dir.path_join(fname), dir.path_join("imported").path_join(fname))
		count += 1
	Net.toast.emit("Imported %d file(s)." % count if count else "Inbox is empty: put files in %s" % dir)
	return count


func _srv_upload(peer: int, filename: String, bytes: PackedByteArray) -> void:
	if not Net.can(peer, "interact"):
		return
	var id := server_add(filename, bytes)
	var eid := server_spawn_document(id, Sync.hand_out_xform(peer), {"pinned": true})
	Net.send_toast(peer, "%s is floating in front of you." % server_get(id)["name"] if eid else "Upload failed.")


# --- Chunked transfers -----------------------------------------------------------

func _send_blob(to: int, kind: String, meta: Dictionary, bytes: PackedByteArray) -> void:
	var tid := _next_transfer
	_next_transfer += 1
	var n := maxi(1, ceili(bytes.size() / float(CHUNK)))
	for i in n:
		_chunk.rpc_id(to, tid, kind, meta if i == 0 else {}, i, n, bytes.slice(i * CHUNK, (i + 1) * CHUNK))


@rpc("any_peer", "reliable", "call_remote", 3)
func _chunk(tid: int, kind: String, meta: Dictionary, i: int, n: int, data: PackedByteArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if Net.is_server():
		if kind != "upload" or not Net.players.has(sender):
			return
		if n * CHUNK > int(Config.get_value("server", "max_upload_mb")) * 1048576 + CHUNK:
			if i == 0:
				Net.send_toast(sender, "That file is too big for this server.")
			return
	elif not kind in ["download", "snapshot"] or sender != 1:
		return
	var key := "%d:%d" % [sender, tid]
	if not _incoming.has(key):
		_incoming[key] = {"kind": kind, "meta": {}, "parts": [], "got": 0, "n": n}
		_incoming[key]["parts"].resize(n)
	var t: Dictionary = _incoming[key]
	if i == 0:
		t["meta"] = meta
	if i < n and t["parts"][i] == null:
		t["parts"][i] = data
		t["got"] += 1
	if t["got"] < t["n"]:
		return
	_incoming.erase(key)
	var bytes := PackedByteArray()
	for p in t["parts"]:
		bytes.append_array(p)
	if kind == "upload":
		_srv_upload(sender, str(t["meta"].get("name", "file")), bytes)
	elif kind == "snapshot":
		Saves.receive_snapshot(str(t["meta"].get("name", "room")), bytes)
	else:
		Net.toast.emit("Saved %s" % Exporter.save_local({"filename": str(t["meta"].get("name", "file")), "bytes": bytes}))
