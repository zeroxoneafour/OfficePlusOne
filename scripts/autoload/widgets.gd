extends Node
## Wall widgets (calendar, alarm, timer, whiteboard, TV) and operations on entities.
##
## Widgets are entities (scenes/widgets/*.tscn, scripts/widgets/*) mounted flat
## on a wall: people add them from a wall's context menu (point at a wall, pull
## back), name them with the keyboard, and configure or remove them from the
## widget's own context menu (or its ⚙ button). AIs use them through the
## widget MCP tools (scripts/ai/widget_mcp.gd).
##
## A widget remembers where it hangs as (wall, u = offset along the wall,
## h = height), so it stays on its wall when the room is resized.
##
## Operations: anything a menu or widget does to an entity (set an alarm, draw
## a stroke, connect a screen, open a drawer…) goes through request_op(); the
## server checks the entity's op_perm() and calls its server_op().

## A drawer's folder listing arrived (for the file browser).
signal listing_received(drawer_id: int, rel: String, entries: Array, error: String)

const KINDS := {
	"calendar": {"label": "Calendar", "size": Vector2(0.96, 0.92)},
	"alarm": {"label": "Alarm", "size": Vector2(0.56, 0.42)},
	"timer": {"label": "Timer", "size": Vector2(0.56, 0.42)},
	"whiteboard": {"label": "Whiteboard", "size": Vector2(1.6, 0.9)},
	"tv": {"label": "TV", "size": Vector2(1.6, 0.95)},
	# The tutorial's practice board (not in the Add widget menu).
	"practice": {"label": "Practice", "size": Vector2(1.0, 0.8)},
}
const WALLS := ["north", "south", "east", "west"]
## Widgets hang this far off the wall surface.
const WALL_GAP := 0.03
const MAX_NAME := 32

var _tick := 0.0
## Name of the AI agent whose tool call is running (for change notes).
var acting_ai := ""


func _ready() -> void:
	Office.changed.connect(_on_room_changed)


# --- Wall geometry -----------------------------------------------------------------

static func wall_normal(surface: String) -> Vector3:
	match surface:
		"north": return Vector3(0, 0, 1)
		"south": return Vector3(0, 0, -1)
		"west": return Vector3(1, 0, 0)
		"east": return Vector3(-1, 0, 0)
	return Vector3.ZERO


static func wall_length(surface: String) -> float:
	var s := Office.size()
	return s.x if surface in ["north", "south"] else s.z


## Position along a wall (u) of a world point.
static func wall_u(surface: String, point: Vector3) -> float:
	return point.x if surface in ["north", "south"] else point.z


## Keep a widget of `size` wholly on its wall. Returns [u, h].
static func clamp_on_wall(surface: String, u: float, h: float, size: Vector2) -> Array:
	var half := maxf(wall_length(surface) * 0.5 - size.x * 0.5 - 0.05, 0.0)
	var top := Office.size().y - size.y * 0.5 - 0.05
	return [clampf(u, -half, half), clampf(h, minf(size.y * 0.5 + 0.3, top), top)]


## Where a widget hangs: centred at (u, h) on the wall, its face (+Z) toward the room.
static func wall_xform(surface: String, u: float, h: float) -> Transform3D:
	var s := Office.size()
	var n := wall_normal(surface)
	var p := Vector3.ZERO
	match surface:
		"north": p = Vector3(u, h, -s.z * 0.5)
		"south": p = Vector3(u, h, s.z * 0.5)
		"west": p = Vector3(-s.x * 0.5, h, u)
		"east": p = Vector3(s.x * 0.5, h, u)
	return Transform3D(Basis.looking_at(-n, Vector3.UP), p + n * WALL_GAP)


# --- Finding widgets ----------------------------------------------------------------

func all() -> Array:
	var out := []
	for e in Sync.entities.values():
		if e is Widget:
			out.append(e)
	out.sort_custom(func(a, b): return a.entity_id < b.entity_id)
	return out


## The widget of `kind` called `widget_name` (case-insensitive), or null. If
## there's just one of that kind, an empty name finds it.
func find(kind: String, widget_name: String) -> Widget:
	var n := widget_name.strip_edges().to_lower()
	var of_kind := all().filter(func(w): return w.kind == kind)
	for w in of_kind:
		if w.widget_name().to_lower() == n:
			return w
	if n == "" and of_kind.size() == 1:
		return of_kind[0]
	return null


func names_of(kind: String) -> Array:
	return all().filter(func(w): return w.kind == kind).map(func(w): return w.widget_name())


func _unique_name(kind: String, wanted: String, except_id := 0) -> String:
	var taken := {}
	for w in all():
		if w.kind == kind and w.entity_id != except_id:
			taken[w.widget_name().to_lower()] = true
	if not taken.has(wanted.to_lower()):
		return wanted
	var i := 2
	while taken.has(("%s %d" % [wanted, i]).to_lower()):
		i += 1
	return "%s %d" % [wanted, i]


# --- Requests -----------------------------------------------------------------------

## Put a new widget of `kind` on `surface` where the ray hit it.
func request_add(kind: String, surface: String, point: Vector3) -> void:
	request_op(0, "add_widget", {"kind": kind, "surface": surface, "point": point})


## Do `op` on entity `id` (see NetBody.op_perm / server_op).
func request_op(id: int, op: String, args := {}) -> void:
	if Net.is_server():
		_srv_op(Net.my_id(), id, op, args)
	elif Net.mode == "client":
		_op.rpc_id(1, id, op, args)


@rpc("any_peer", "reliable")
func _op(id: int, op: String, args: Dictionary) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if Net.is_server() and Net.players.has(peer):
		_srv_op(peer, id, op, args)


func _srv_op(peer: int, id: int, op: String, args: Dictionary) -> void:
	if op == "add_widget":
		if Office._allowed(peer, "spawn"):
			var msg := server_add(str(args.get("kind", "")), str(args.get("surface", "")),
					args.get("point") if args.get("point") is Vector3 else Vector3.ZERO, "", peer)
			if msg.begins_with("Error"):
				Net.send_toast(peer, msg.trim_prefix("Error: "))
		return
	var e: NetBody = Sync.entities.get(id)
	if not e:
		return
	var perm := ""
	if e is Widget and op in ["rename", "remove"]:
		perm = "decorate" if op == "remove" else "interact"
	else:
		perm = e.op_perm(op)
	if perm == "" or not Office._allowed(peer, perm):
		return
	var msg := ""
	if e is Widget and op == "rename":
		msg = server_rename(e, str(args.get("name", "")), peer)
	elif e is Widget and op == "remove":
		server_remove(e, peer)
	else:
		msg = e.server_op(peer, op, args)
	if msg != "":
		Net.send_toast(peer, msg.trim_prefix("Error: "))


# --- Server --------------------------------------------------------------------------

## Server: hang a new widget. `by` is the peer who added it (0 = an AI).
## Returns "Error: …" or the widget's name.
func server_add(kind: String, surface: String, point: Vector3, wanted_name := "", by := 0) -> String:
	if not KINDS.has(kind):
		return "Error: unknown widget kind %s" % kind
	if not surface in WALLS:
		return "Error: widgets go on walls."
	var size: Vector2 = KINDS[kind]["size"]
	var uh := clamp_on_wall(surface, wall_u(surface, point), point.y, size)
	var n := wanted_name.strip_edges().substr(0, MAX_NAME)
	n = _unique_name(kind, n if n != "" else str(KINDS[kind]["label"]))
	var data := {"name": n, "wall": surface, "u": uh[0], "h": uh[1]}
	var id := Sync.spawn(kind, wall_xform(surface, uh[0], uh[1]), data)
	var w: Widget = Sync.entities.get(id)
	if w:
		w.server_added()
	AI.widget_note("%s added %s \"%s\" on the %s wall." % [_who(by), KINDS[kind]["label"].to_lower(), n, surface])
	return n


func server_rename(w: Widget, wanted: String, by := 0) -> String:
	var n := wanted.strip_edges().substr(0, MAX_NAME)
	if n == "":
		return "Error: a name can't be empty."
	if n.to_lower() != w.widget_name().to_lower() and find(w.kind, n) != null:
		return "Error: there's already a %s called %s." % [KINDS[w.kind]["label"].to_lower(), n]
	var old := w.widget_name()
	Sync.set_data(w.entity_id, "name", n)
	AI.widget_note("%s renamed %s \"%s\" to \"%s\"." % [_who(by), KINDS[w.kind]["label"].to_lower(), old, n])
	return ""


func server_remove(w: Widget, by := 0) -> void:
	AI.widget_note("%s removed %s \"%s\"." % [_who(by), KINDS[w.kind]["label"].to_lower(), w.widget_name()])
	w.server_removing()
	Sync.despawn(w.entity_id)


func _who(peer: int) -> String:
	if peer > 0:
		return Net.player_name(peer)
	return acting_ai if acting_ai != "" else "Someone"


## Keep widgets on their walls when the room is resized.
func _on_room_changed() -> void:
	if not Net.is_server():
		return
	for w: Widget in all():
		var surface := str(w.data.get("wall", ""))
		if not surface in WALLS:
			continue
		var uh := clamp_on_wall(surface, float(w.data.get("u", 0.0)), float(w.data.get("h", 1.5)), w.size)
		var xf := wall_xform(surface, uh[0], uh[1])
		if not xf.is_equal_approx(w.global_transform):
			w.global_transform = xf
			w.server_moved()


func _process(delta: float) -> void:
	if not Net.in_session or not Net.is_server():
		return
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = 1.0
	var now := Time.get_datetime_dict_from_system()
	for w: Widget in all():
		w.server_tick(now)


# --- Drawer listings ---------------------------------------------------------------------

## Ask the server for the files in a drawer's folder (`rel` below its root).
func request_listing(drawer_id: int, rel: String) -> void:
	request_op(drawer_id, "list", {"rel": rel})


## Server: send a listing to whoever asked.
func server_send_listing(peer: int, drawer_id: int, rel: String, entries: Array, error := "") -> void:
	if peer == Net.my_id():
		listing_received.emit(drawer_id, rel, entries, error)
	else:
		_listing.rpc_id(peer, drawer_id, rel, entries, error)


@rpc("authority", "reliable")
func _listing(drawer_id: int, rel: String, entries: Array, error: String) -> void:
	listing_received.emit(drawer_id, rel, entries, error)
