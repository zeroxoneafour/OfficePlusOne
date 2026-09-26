extends Node
## Connection lifecycle, membership/permissions, summons and LAN discovery.
##
## One server = one office room. Whoever hosts owns it. Other people either
## are members (remembered, or invited by name) and walk straight in, or they
## "knock" and an owner/admin accepts or declines. Server authoritative:
## clients only ever *request* things from peer 1.

signal session_started
signal session_ended(reason: String)
signal roster_changed
signal servers_changed
signal waiting_changed(waiting: bool)
## A yes/no request for the local player: "summon" (come over) or "knock" (let
## someone in). They wait in `pending_prompts` and are answered from the watch.
signal prompt_received(kind: String, req_id: int, text: String)
signal prompts_changed
signal teleport_requested(xform: Transform3D)
signal toast(text: String)

const MAX_PLAYERS := 32
const PROTOCOL := 3
const MEMBERS_PATH := "user://members.json"
const ROLES := ["member", "admin", "owner"]
## Minimum role for each permission.
const PERMS := {
	"interact": "member", # grab, talk to AIs, summon agents, call people over, import files
	"spawn": "admin", # add objects and wall widgets
	"lock": "admin", # lock/unlock objects (one, or all)
	"decorate": "admin", # resize, paint, clear, wipe board, remove widgets, link drawers to folders
	"agents": "admin", # create/remove/reconfigure AI agents
	"admit": "admin", # accept knocks, invite, kick members
	"roles": "owner", # promote/demote admins
}

## "offline" | "host" (listen server + local player) | "server" (dedicated) | "client"
var mode := "offline"
var in_session := false
## Admitted players: peer_id -> {"name": String, "role": String}
var players := {}
## LAN servers found by discovery: "ip:port" -> {"ip", "port", "name", "players", "invited", "t"}
var servers := {}
## Client: requests waiting for our answer: id -> {"kind", "text", "t" (msec)}
var pending_prompts := {}
const PROMPT_TTL_MS := 90000

## server: peer -> name, connected but waiting to be let in
var _pending := {}
## server: lowercase name -> role, remembered across sessions
var _members := {}
var _prompts := {}
var _next_prompt := 1
var _beacon: PacketPeerUDP
## Hosting the tutorial world (see Tutorial): private (not advertised on the
## LAN) and never autosaved, so your own office is left alone.
var tutorial := false
var _listener: PacketPeerUDP
var _beacon_timer := 0.0


func _ready() -> void:
	multiplayer.peer_connected.connect(func(_p: int): pass)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): leave("Could not connect."))
	multiplayer.server_disconnected.connect(func(): leave("The server closed."))


func is_server() -> bool:
	return mode == "host" or mode == "server"


func has_local_player() -> bool:
	return mode != "server"


func my_id() -> int:
	return multiplayer.get_unique_id() if mode != "offline" else 1


func player_name(peer: int) -> String:
	return players.get(peer, {}).get("name", "?")


func role(peer: int) -> String:
	return players.get(peer, {}).get("role", "")


## Permissions admins may hand to ordinary members (Room → Permissions on the
## watch); the choices live in the room state and are saved with the room.
const GRANTABLE := {"spawn": "Add objects", "agents": "Add AIs", "lock": "Lock / unlock"}


## Does `peer` have permission `perm` (see PERMS, and GRANTABLE for members)?
func can(peer: int, perm: String) -> bool:
	if ROLES.find(role(peer)) >= ROLES.find(PERMS.get(perm, "owner")):
		return true
	return role(peer) == "member" and perm in GRANTABLE and Office.member_may(perm)


func my_can(perm: String) -> bool:
	return can(my_id(), perm)


func find_peer_by_name(pname: String) -> int:
	var n := pname.strip_edges().to_lower()
	if n == "":
		return 0
	for p in players:
		if players[p]["name"].to_lower() == n:
			return p
	for p in players:
		if players[p]["name"].to_lower().begins_with(n):
			return p
	return 0


## Send an RPC to every admitted remote player; also run it here when `local`.
## (Plain .rpc() would also reach people still knocking at the door.)
func broadcast(fn: Callable, args: Array = [], local := true) -> void:
	if local:
		fn.callv(args)
	var obj := fn.get_object()
	for p in players:
		if p != my_id():
			obj.rpc_id.callv([p, fn.get_method()] + args)


func server_name() -> String:
	if tutorial:
		return "Tutorial"
	var n := str(Config.get_value("server", "name"))
	return n if n != "" else ("%s's office" % Config.player_name() if mode == "host" else "Office server")


# --- Session control -------------------------------------------------------

## Open the tutorial world (from the lobby's help panel).
func host_tutorial() -> Error:
	tutorial = true
	var err := host(false)
	if err != OK:
		tutorial = false
	return err


func host(dedicated := false) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(int(Config.get_value("network", "port")), MAX_PLAYERS, 4)
	if err != OK:
		toast.emit("Could not host: %s" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	mode = "server" if dedicated else "host"
	_load_members()
	if not tutorial:
		_beacon = PacketPeerUDP.new()
		_beacon.set_broadcast_enabled(true)
		_beacon.set_dest_address("255.255.255.255", int(Config.get_value("network", "discovery_port")))
	in_session = true
	Office.server_init()
	AI.server_init()
	if not dedicated:
		_admit(1, Config.player_name(), "owner")
	print("[Net] Hosting '%s' on port %s" % [server_name(), Config.get_value("network", "port")])
	session_started.emit()
	return OK


func join(address: String, port := -1) -> Error:
	if mode != "offline":
		leave()
	if port < 0:
		port = int(Config.get_value("network", "port"))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port, 4)
	if err != OK:
		toast.emit("Could not join: %s" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	mode = "client"
	toast.emit("Connecting to %s…" % address)
	print("[Net] Joining ", address, ":", port)
	return OK


func leave(reason := "") -> void:
	if mode == "offline":
		return
	if is_server():
		Saves.autosave() # the office is about to close
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = "offline"
	in_session = false
	players.clear()
	_pending.clear()
	_prompts.clear()
	pending_prompts.clear()
	prompts_changed.emit()
	_beacon = null
	tutorial = false
	Sync.reset()
	Office.reset()
	Files.reset()
	AI.reset()
	print("[Net] Left session: ", reason)
	waiting_changed.emit(false)
	session_ended.emit(reason)
	roster_changed.emit()


func _on_connected() -> void:
	_register.rpc_id(1, Config.player_name(), PROTOCOL)


@rpc("any_peer", "reliable")
func _register(pname: String, protocol: int) -> void:
	if not is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL:
		_disconnect(peer, "Version mismatch: update the app.")
		return
	pname = _unique_name(pname)
	var remembered: String = _members.get(pname.to_lower(), "")
	if remembered != "" or Config.get_value("server", "open") == true:
		_admit(peer, pname, remembered if remembered != "" else "member")
		return
	var admins := _peers_with("admit")
	if admins.is_empty():
		_disconnect(peer, "Nobody who can let you in is here right now.")
		return
	_pending[peer] = pname
	_waiting.rpc_id(peer, true)
	for a in admins:
		_send_prompt(a, "knock", peer, "%s is knocking.\nLet them in?" % pname)


@rpc("authority", "reliable")
func _waiting(on: bool) -> void:
	waiting_changed.emit(on)
	if on:
		toast.emit("Knocked. Waiting for someone to let you in…")


func _disconnect(peer: int, reason: String) -> void:
	_kicked.rpc_id(peer, reason)
	# Let the message arrive before dropping the connection.
	get_tree().create_timer(0.5).timeout.connect(func():
		if multiplayer.multiplayer_peer is ENetMultiplayerPeer and is_server():
			multiplayer.multiplayer_peer.disconnect_peer(peer))


@rpc("authority", "reliable")
func _kicked(reason: String) -> void:
	leave(reason)


@rpc("authority", "reliable")
func _welcome() -> void:
	in_session = true
	waiting_changed.emit(false)
	session_started.emit()


func _admit(peer: int, pname: String, player_role: String) -> void:
	_pending.erase(peer)
	players[peer] = {"name": pname, "role": player_role}
	if player_role != "owner" and not _members.has(pname.to_lower()):
		_remember(pname, "member")
	if peer != 1:
		Office.send_all_to(peer)
		Sync.send_all_to(peer)
		_welcome.rpc_id(peer)
	Sync.server_add_player(peer)
	_broadcast_roster()
	place_player(peer)
	for p in players:
		if p != peer:
			send_toast(p, "%s joined." % pname)


func _unique_name(pname: String) -> String:
	pname = pname.strip_edges().substr(0, 24)
	if pname == "":
		pname = "Guest"
	var base := pname
	var n := 2
	while _name_taken(pname):
		pname = "%s %d" % [base, n]
		n += 1
	return pname


func _name_taken(pname: String) -> bool:
	for p in players:
		if players[p]["name"].to_lower() == pname.to_lower():
			return true
	for p in _pending:
		if _pending[p].to_lower() == pname.to_lower():
			return true
	return false


func _peers_with(perm: String) -> Array:
	var out := []
	for p in players:
		if can(p, perm):
			out.append(p)
	return out


func _on_peer_disconnected(peer: int) -> void:
	if not is_server():
		return
	_pending.erase(peer)
	if not players.has(peer):
		return
	Sync.server_remove_player(peer)
	Voice.server_remove_player(peer)
	var pname := player_name(peer)
	players.erase(peer)
	_broadcast_roster()
	for p in players:
		send_toast(p, "%s left." % pname)


func _broadcast_roster() -> void:
	broadcast(_roster, [players], false)
	roster_changed.emit()


@rpc("authority", "reliable")
func _roster(p: Dictionary) -> void:
	players = p
	roster_changed.emit()


# --- Membership (server) --------------------------------------------------------

func _load_members() -> void:
	_members = {}
	if FileAccess.file_exists(MEMBERS_PATH):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(MEMBERS_PATH))
		if d is Dictionary:
			_members = d
	for a in Config.get_value("server", "admins", []):
		_members[str(a).to_lower()] = "admin"
	if mode == "host":
		_members[Config.player_name().to_lower()] = "owner"


func _remember(pname: String, player_role: String) -> void:
	_members[pname.to_lower()] = player_role
	_save_members()


func _save_members() -> void:
	var f := FileAccess.open(MEMBERS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_members, "\t"))


## Server: let `pname` walk straight in next time they join.
func server_invite(by: int, pname: String) -> String:
	if not can(by, "admit"):
		return "Only an admin or the owner can invite people."
	pname = pname.strip_edges()
	if pname == "":
		return "Who should I invite?"
	if not _members.has(pname.to_lower()):
		_remember(pname, "member")
	return "%s can now join without knocking." % pname


func server_kick(by: int, target: int) -> String:
	if not players.has(target) or target == by:
		return "Nobody by that name is here."
	if not can(by, "admit") or ROLES.find(role(target)) >= ROLES.find(role(by)):
		return "You don't have permission to remove %s." % player_name(target)
	_members.erase(player_name(target).to_lower())
	_save_members()
	_disconnect(target, "You were removed from this office by %s." % player_name(by))
	return "%s was removed." % player_name(target)


func server_set_role(by: int, target: int, new_role: String) -> String:
	if not players.has(target) or not new_role in ["member", "admin"]:
		return "Can't do that."
	if not can(by, "roles") or role(target) == "owner":
		return "Only the owner can change roles."
	players[target]["role"] = new_role
	_remember(player_name(target), new_role)
	_broadcast_roster()
	send_toast(target, "You are now %s %s here." % ["an" if new_role == "admin" else "a", new_role])
	return "%s is now %s." % [player_name(target), new_role]


# --- Prompts: summon invites and knock requests ----------------------------------------

func _send_prompt(to: int, kind: String, subject: int, text: String) -> void:
	var id := _next_prompt
	_next_prompt += 1
	_prompts[id] = {"kind": kind, "to": to, "subject": subject}
	if to == my_id() and has_local_player():
		_receive_prompt(kind, id, text)
	else:
		_prompt.rpc_id(to, kind, id, text)


@rpc("authority", "reliable")
func _prompt(kind: String, id: int, text: String) -> void:
	_receive_prompt(kind, id, text)


func _receive_prompt(kind: String, id: int, text: String) -> void:
	pending_prompts[id] = {"kind": kind, "text": text, "t": Time.get_ticks_msec()}
	prompts_changed.emit()
	prompt_received.emit(kind, id, text)


## Requests of `kind` still waiting (oldest first): [[id, text], …]
func prompts_of(kind: String) -> Array:
	var out := []
	for id in pending_prompts.keys():
		var p: Dictionary = pending_prompts[id]
		if Time.get_ticks_msec() - int(p["t"]) > PROMPT_TTL_MS:
			pending_prompts.erase(id)
		elif p["kind"] == kind:
			out.append([id, p["text"]])
	return out


func answer_prompt(id: int, accept: bool) -> void:
	pending_prompts.erase(id)
	prompts_changed.emit()
	_call_server("_srv_answer_prompt", [id, accept])


## Server told us a request was dealt with elsewhere (another admin answered it).
@rpc("authority", "reliable")
func _prompt_closed(id: int) -> void:
	_close_prompt_locally(id)


func _close_prompt_locally(id: int) -> void:
	if pending_prompts.erase(id):
		prompts_changed.emit()


func _srv_answer_prompt(peer: int, id: int, accept: bool) -> void:
	var pr: Dictionary = _prompts.get(id, {})
	if pr.is_empty() or pr["to"] != peer:
		return
	var subject: int = pr["subject"]
	match pr["kind"]:
		"knock":
			if not _pending.has(subject):
				return # someone else already answered
			for other in _prompts.keys():
				if _prompts[other]["kind"] == "knock" and _prompts[other]["subject"] == subject:
					var to: int = _prompts[other]["to"]
					_prompts.erase(other)
					if to == my_id() and has_local_player():
						_close_prompt_locally(other)
					elif players.has(to):
						_prompt_closed.rpc_id(to, other)
			if accept and can(peer, "admit"):
				_admit(subject, _pending[subject], "member")
			else:
				_pending.erase(subject)
				_disconnect(subject, "%s didn't let you in this time." % player_name(peer))
		"summon":
			_prompts.erase(id)
			if not players.has(subject):
				return
			if accept:
				place_player(peer, Sync.head_xform(subject))
				send_toast(subject, "%s is here." % player_name(peer))
			else:
				send_toast(subject, "%s declined." % player_name(peer))


## Ask another human in the room to come over to me.
func request_summon_player(target: int) -> void:
	_call_server("_srv_request_summon", [target])


func _srv_request_summon(peer: int, target: int) -> void:
	if not players.has(target) or target == peer or not can(peer, "interact"):
		return
	send_toast(peer, "Asked %s to come over…" % player_name(target))
	_send_prompt(target, "summon", peer, "%s would like you\nto come over" % player_name(peer))


# --- Placement ------------------------------------------------------------------

## Server: move a player to the room entrance, or in front of `near` (a head transform).
func place_player(peer: int, near: Variant = null) -> void:
	if not players.has(peer):
		return
	var xf: Transform3D = Office.spawn_xform()
	if near is Transform3D:
		var fwd: Vector3 = -near.basis.z
		fwd.y = 0
		fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
		var pos: Vector3 = near.origin + fwd * 1.3
		pos.y = 0.0
		var look := Vector3(near.origin.x, 0.0, near.origin.z)
		xf = Transform3D(Basis.looking_at(look - pos, Vector3.UP), pos)
	if peer == my_id() and has_local_player():
		teleport_requested.emit(xf)
	else:
		_teleport.rpc_id(peer, xf)


@rpc("authority", "reliable")
func _teleport(xf: Transform3D) -> void:
	teleport_requested.emit(xf)


func send_toast(peer: int, text: String) -> void:
	if peer == my_id() and has_local_player():
		toast.emit(text)
	elif players.has(peer) or _pending.has(peer):
		_toast.rpc_id(peer, text)


@rpc("authority", "reliable")
func _toast(text: String) -> void:
	toast.emit(text)


# --- Generic client->server request plumbing ------------------------------------

## Calls `method(sender_peer, ...args)` on the server, locally when we are the server.
func _call_server(method: String, args: Array = []) -> void:
	if is_server():
		callv(method, [my_id()] + args)
	elif mode == "client":
		_request.rpc_id(1, method, args)


const _ALLOWED := ["_srv_request_summon", "_srv_answer_prompt"]


@rpc("any_peer", "reliable")
func _request(method: String, args: Array) -> void:
	if is_server() and method in _ALLOWED and players.has(multiplayer.get_remote_sender_id()):
		callv(method, [multiplayer.get_remote_sender_id()] + args)


# --- LAN discovery ---------------------------------------------------------------

## Listen for LAN servers (lobby list, and the watch's "Switch room").
func start_listening() -> void:
	if _listener:
		return
	_listener = PacketPeerUDP.new()
	if _listener.bind(int(Config.get_value("network", "discovery_port"))) != OK:
		push_warning("[Net] LAN discovery unavailable (port in use?)")
		_listener = null


## Other offices on the LAN (not the one we're in): [{ip, port, name, players, invited}]
func other_servers() -> Array:
	var here: String = str(Office.state.get("name", "")) if in_session else ""
	var out := []
	for key in servers:
		var sv: Dictionary = servers[key]
		if in_session and sv["name"] == here and sv["port"] == int(Config.get_value("network", "port")):
			continue
		out.append(sv)
	return out


func _stop_listening() -> void:
	if _listener:
		_listener.close()
		_listener = null
	servers.clear()
	servers_changed.emit()


func _process(delta: float) -> void:
	if _beacon:
		_beacon_timer -= delta
		if _beacon_timer <= 0.0:
			_beacon_timer = 1.0
			var msg := JSON.stringify({"app": "OfficePlusOne", "v": PROTOCOL, "name": server_name(),
					"port": Config.get_value("network", "port"), "players": players.size(),
					"open": Config.get_value("server", "open") == true, "members": _members.keys()})
			_beacon.put_packet(msg.to_utf8_buffer())
	if _listener:
		var changed := false
		while _listener.get_available_packet_count() > 0:
			var data: Variant = JSON.parse_string(_listener.get_packet().get_string_from_utf8())
			var ip := _listener.get_packet_ip()
			if data is Dictionary and data.get("app") == "OfficePlusOne":
				var key := "%s:%d" % [ip, int(data.get("port", 7777))]
				changed = changed or not servers.has(key)
				var members: Array = data.get("members", []) if data.get("members") is Array else []
				servers[key] = {"ip": ip, "port": int(data.get("port", 7777)), "name": str(data.get("name", ip)),
						"players": int(data.get("players", 0)),
						"invited": data.get("open", false) == true or Config.player_name().to_lower() in members,
						"t": Time.get_ticks_msec()}
		for key in servers.keys():
			if Time.get_ticks_msec() - servers[key]["t"] > 4000:
				servers.erase(key)
				changed = true
		if changed:
			servers_changed.emit()
