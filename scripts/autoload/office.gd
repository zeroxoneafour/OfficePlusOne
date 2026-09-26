extends Node
## The one room this server hosts. State is a plain Dictionary replicated from
## the server; every peer builds the geometry from it (scenes/world/room.tscn).
## It holds the room's size, colors, name and which extra
## permissions ordinary members have been granted. Saved with everything else
## by the Saves autoload. Changes are permission checked (see Net.PERMS).

signal changed

const MIN_SIZE := Vector3(4, 2.5, 4)
const MAX_SIZE := Vector3(30, 8, 30)
const PALETTE := ["#6b5b4b", "#e8e4dc", "#b8c9d9", "#c9d9b8", "#d9c3b8", "#8a9bb0", "#3d4455", "#f2d06b", "#e07a5f", "#81b29a"]
const RoomScene := preload("res://scenes/world/room.tscn")
const SURFACES := ["floor", "ceiling", "north", "south", "east", "west"]
## Furniture spawns locked in place (unlock it from its context menu or the watch).
const FURNITURE := ["chair", "table", "plant", "lamp", "monitor", "drawer"]
## Height of each kind's origin above the floor when spawned standing on it.
const SPAWN_HEIGHT := {"chair": 0.45, "table": 0.4, "plant": 0.15, "lamp": 0.62, "monitor": 0.01, "drawer": 0.36}
## Height of a table's top surface above the floor.
const TABLE_TOP := 0.775
## Size / color steps (watch: Room → Room size).
const ROOM_ACTIONS := ["w+", "w-", "d+", "d-", "h+", "h-", "floor"]

var state := {}
## The Room node (null outside a session). Set by main.gd's container.
var node: Node3D
var root: Node3D


static func default_state() -> Dictionary:
	return {
		"name": "",
		"size": [10.0, 3.0, 10.0],
		"colors": {"floor": "#6b5b4b", "north": "#e8e4dc", "south": "#e8e4dc", "east": "#e8e4dc", "west": "#e8e4dc", "ceiling": "#f4f4f4"},
		## Extra permissions granted to ordinary members (see Net.GRANTABLE).
		"member_perms": {},
	}


func server_init() -> void:
	if Net.tutorial:
		Tutorial.server_build()
		return
	if not Saves.server_load_startup():
		var s := default_state()
		s["name"] = Net.server_name()
		replace_state(s)
		furnish()


func reset() -> void:
	if node:
		node.queue_free()
		node = null
	state = {}


func size() -> Vector3:
	var s: Array = state.get("size", [10, 3, 10])
	return Vector3(s[0], s[1], s[2])


func spawn_xform() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0, 0, size().z * 0.5 - 1.2))


func contains(pos: Vector3) -> bool:
	var h := size() * 0.5
	return absf(pos.x) <= h.x + 0.5 and absf(pos.z) <= h.z + 0.5


## Has an admin granted ordinary members this permission here?
func member_may(perm: String) -> bool:
	return state.get("member_perms", {}).get(perm, false) == true


## A brand-new office's starting furniture.
func furnish() -> void:
	var s := size()
	spawn_object("table", Vector3(0, 0, 0))
	spawn_object("chair", Vector3(0, 0, 0.9))
	spawn_object("chair", Vector3(0, 0, -0.9), PI)
	# A monitor on the table, facing the first chair.
	Sync.spawn("monitor", Transform3D(Basis.IDENTITY, Vector3(0, TABLE_TOP + 0.01, -0.15)), {"locked": true})
	spawn_object("drawer", Vector3(-s.x * 0.5 + 0.4, 0, -1.5), PI * 0.5)
	add_main_board()


## Server: hang the room's main whiteboard (a whiteboard widget) centred on the
## north wall, showing `board` ({title, text, image}; e.g. an old-style room
## board's contents).
func add_main_board(board := {}) -> void:
	var name_ := Widgets.server_add("whiteboard", "north", Vector3(0, minf(1.6, size().y - 0.6), -size().z * 0.5), "Main board")
	var w := Widgets.find("whiteboard", name_)
	if w and not board.is_empty():
		(w as WhiteboardWidget).server_show(board)


## Server: spawn `kind` standing on the floor at `floor_point` (nudged into free
## space so it doesn't land inside something). Furniture starts locked.
## A spot on the top of a table near `point` (for monitors), or Vector3.INF.
func _on_table(point: Vector3) -> Vector3:
	for t: NetBody in Sync.entities_of_kind("table"):
		var local := t.to_local(Vector3(point.x, t.global_position.y, point.z))
		if absf(local.x) < 1.0 and absf(local.z) < 0.7:
			return t.to_global(Vector3(clampf(local.x, -0.5, 0.5), TABLE_TOP - SPAWN_HEIGHT["table"] + 0.01, clampf(local.z, -0.25, 0.25)))
	return Vector3.INF


func spawn_object(kind: String, floor_point: Vector3, yaw := 0.0) -> int:
	if kind == "monitor":
		var on_table := _on_table(floor_point)
		if on_table != Vector3.INF:
			return Sync.spawn(kind, Transform3D(Basis(Vector3.UP, yaw), on_table), {"locked": true})
	var radius := 0.9 if kind == "table" else 0.35
	var spot := Sync.free_spot(Vector3(floor_point.x, 0, floor_point.z), radius)
	var data := {"locked": true} if kind in FURNITURE else {}
	return Sync.spawn(kind, Transform3D(Basis(Vector3.UP, yaw), spot + Vector3(0, SPAWN_HEIGHT.get(kind, 0.2), 0)), data)


# --- Server-side changes -------------------------------------------------------------

## Server: replace the whole room state (new office, or a loaded save).
func replace_state(s: Dictionary) -> void:
	Net.broadcast(_state, [s])


func update(changes: Dictionary) -> void:
	var s: Dictionary = state.duplicate(true)
	for k in changes:
		if changes[k] is Dictionary and s.get(k) is Dictionary:
			s[k].merge(changes[k], true)
		else:
			s[k] = changes[k]
	Net.broadcast(_state, [s])


func resize(new_size: Vector3) -> void:
	new_size = new_size.clamp(MIN_SIZE, MAX_SIZE)
	update({"size": [snappedf(new_size.x, 0.5), snappedf(new_size.y, 0.25), snappedf(new_size.z, 0.5)]})


func paint(surface: String, color: String) -> void:
	if not Color.html_is_valid(color):
		return
	var colors := {}
	for s in (["north", "south", "east", "west"] if surface == "walls" else [surface]):
		if s in SURFACES:
			colors[s] = color
	update({"colors": colors})


func send_all_to(peer: int) -> void:
	_state.rpc_id(peer, state)


@rpc("authority", "reliable")
func _state(s: Dictionary) -> void:
	state = s
	if not node and root:
		node = RoomScene.instantiate()
		root.add_child(node)
	if node:
		node.apply(s)
	changed.emit()


# --- Requests from the watch and the context menus -------------------------------------------

func request_action(action: String, args: Dictionary = {}) -> void:
	if Net.is_server():
		_srv_action(Net.my_id(), action, args)
	elif Net.mode == "client":
		_action.rpc_id(1, action, args)


@rpc("any_peer", "reliable")
func _action(action: String, args: Dictionary) -> void:
	if Net.is_server() and Net.players.has(multiplayer.get_remote_sender_id()):
		_srv_action(multiplayer.get_remote_sender_id(), action, args)


func _srv_action(peer: int, action: String, args: Dictionary) -> void:
	var e: NetBody = Sync.entities.get(int(args.get("entity", 0)))
	match action:
		# Room shape and color (watch: Room → Room size).
		"room":
			if not _allowed(peer, "decorate"):
				return
			var s := size()
			match str(args.get("step", "")):
				"w+": resize(s + Vector3(1, 0, 0))
				"w-": resize(s - Vector3(1, 0, 0))
				"d+": resize(s + Vector3(0, 0, 1))
				"d-": resize(s - Vector3(0, 0, 1))
				"h+": resize(s + Vector3(0, 0.5, 0))
				"h-": resize(s - Vector3(0, 0.5, 0))
				"floor":
					var i := PALETTE.find(str(state["colors"]["floor"]))
					paint("floor", PALETTE[(i + 1) % PALETTE.size()])
		"paint":
			if _allowed(peer, "decorate"):
				paint(str(args.get("surface", "")), str(args.get("color", "")))
		"clear":
			if _allowed(peer, "decorate"):
				Sync.clear_props()
		"rename":
			var n := str(args.get("name", "")).strip_edges().substr(0, 40)
			if n != "" and _allowed(peer, "decorate"):
				update({"name": n})
		# Guest permissions (watch: Room → Permissions). Admins only.
		"member_perm":
			var perm := str(args.get("perm", ""))
			if perm in Net.GRANTABLE and _allowed(peer, "admit"):
				update({"member_perms": {perm: args.get("on", false) == true}})
		# Objects.
		"spawn":
			var kind := str(args.get("kind", ""))
			var point: Vector3 = args.get("point") if args.get("point") is Vector3 else spawn_xform().origin
			if kind == "agent":
				if _allowed(peer, "agents"):
					AI.server_create_agent({}, peer, _facing(peer, point))
			elif kind in Sync.SPAWNABLE and _allowed(peer, "spawn"):
				spawn_object(kind, point)
		"lock":
			if not e or e is AgentBody or not _allowed(peer, "lock"):
				return
			Sync.server_set_locked(e.entity_id, not e.is_locked())
		"rotate":
			if not e or e is Widget or not e.grabbable():
				return
			if _allowed(peer, "lock" if e.is_locked() else "interact"):
				Sync.server_rotate(e.entity_id, float(args.get("degrees", 0.0)))
		"lock_all":
			if _allowed(peer, "lock"):
				for body: NetBody in Sync.entities.values():
					if body is Prop:
						Sync.server_set_locked(body.entity_id, args.get("on", true) == true)
		"delete":
			if not e:
				return
			if e is AgentBody:
				if _allowed(peer, "agents"):
					AI.server_remove_agent(e.entity_id)
			elif _allowed(peer, "decorate"):
				Sync.server_delete(e.entity_id)
		# People and AIs.
		"sit":
			# From the context menu: no reach limit (it's like teleporting onto it).
			if e and e.kind == "chair" and _allowed(peer, "interact"):
				Sync.server_sit(peer, e)
		"summon_to":
			if _allowed(peer, "interact") and args.get("point") is Vector3:
				AI.server_summon_agent_to(int(args.get("agent", 0)), peer, args["point"], int(args.get("chair", 0)))
		"call":
			Net._srv_request_summon(peer, int(args.get("peer", 0)))
		"kick":
			Net.send_toast(peer, Net.server_kick(peer, int(args.get("peer", 0))))
		"role":
			Net.send_toast(peer, Net.server_set_role(peer, int(args.get("peer", 0)), str(args.get("role", ""))))


## A floor transform at `point` facing the player.
func _facing(peer: int, point: Vector3) -> Transform3D:
	var pos := Sync.free_spot(Vector3(point.x, 0.02, point.z), 0.4)
	var head: Variant = Sync.head_xform(peer)
	var face := Vector3.FORWARD
	if head is Transform3D:
		face = Vector3((head as Transform3D).origin.x, pos.y, (head as Transform3D).origin.z) - pos
	return Transform3D(Basis.looking_at(face if face.length() > 0.05 else Vector3.FORWARD, Vector3.UP), pos)


func _allowed(peer: int, perm: String) -> bool:
	if Net.can(peer, perm):
		return true
	Net.send_toast(peer, "Only %s can do that here." % ("the owner" if Net.PERMS.get(perm) == "owner" else "admins"))
	return false
