extends Node
## Replicated physics entities (props, clipboards, AI agent bodies), player
## poses/avatars and shared images.
##
## The server simulates real RigidBodies; clients hold frozen copies that
## interpolate toward 20 Hz snapshots. Grabs are requests: the server drives
## the held body toward the holder's hand while the holder's client predicts
## it locally so it feels attached.

signal entities_changed
signal image_added(image_id: int)
## The local player sat down on (chair) or stood up (null).
signal seated_changed(chair: NetBody)
## Server spawned something straight into the local player's hand (e.g. a file
## pulled out of a drawer): `hand` 0 = left, 1 = right.
signal adopt_requested(body: NetBody, hand: int)
## A one-shot entity event (see event()) arrived on this peer.
signal entity_event(id: int, name: String, args: Dictionary)

const SNAP_INTERVAL := 1.0 / 20.0
const FULL_SNAP_INTERVAL := 1.0
const POSE_INTERVAL := 1.0 / 30.0
## What people can add from the floor's context menu. (Old saves may still
## hold cubes, balls and paint balls; those still load.)
const SPAWNABLE := ["chair", "table", "plant", "lamp", "monitor", "drawer", "floating_screen"]
const Entities := preload("res://scripts/entities/entities.gd")
## How far (head to object) direct interactions (trigger / E) reach.
const INTERACT_REACH := 4.5
## Items people can hand to an AI (release it next to them) or pin to the whiteboard.
const HANDABLE := ["document", "clipboard"]
const AvatarScript := preload("res://scripts/player/avatar.gd")


## Set by main.gd
var root: Node3D
var avatars_root: Node3D

## entity_id -> NetBody
var entities := {}
## peer -> {"head": Transform3D, "l": Transform3D, "r": Transform3D}
var poses := {}
## peer -> Avatar (remote players, drawn on every peer)
var avatars := {}
## image_id -> ImageTexture (and PNG bytes on the server for late joiners)
var images := {}
var _image_bytes := {}

var _next_id := 1
var _next_image := 1
var _snap_timer := 0.0
var _full_timer := 0.0
var _pose_timer := 0.0
var _last_sent := {}
## server: peer -> [left AnimatableBody3D, right AnimatableBody3D]
var _hand_proxies := {}
## server: peer -> {"t": arrival usec, "v": [left vel, right vel]} for smoothing remote hands
var _pose_meta := {}
## client: estimated (server clock - local clock), seconds
var _clock_offset := 0.0
var _clock_synced := false


func _ready() -> void:
	Net.roster_changed.connect(_update_avatars)


func reset() -> void:
	for id in entities:
		entities[id].queue_free()
	entities.clear()
	for p in avatars:
		avatars[p].queue_free()
	avatars.clear()
	for p in _hand_proxies:
		for b in _hand_proxies[p]:
			b.queue_free()
	_hand_proxies.clear()
	poses.clear()
	images.clear()
	_image_bytes.clear()
	_last_sent.clear()
	_next_id = 1
	_next_image = 1
	entities_changed.emit()


# --- Entity lifecycle (server) ----------------------------------------------------

func spawn(kind: String, xform: Transform3D, data := {}) -> int:
	assert(Net.is_server())
	var id := _next_id
	_next_id += 1
	Net.broadcast(_spawn, [id, kind, xform, data])
	return id


func despawn(id: int) -> void:
	if entities.has(id):
		Net.broadcast(_despawn, [id])


func set_data(id: int, key: String, value: Variant) -> void:
	if entities.has(id):
		Net.broadcast(_data, [id, key, value])


## One-shot event (speech bubble, gesture…) on every peer.
func event(id: int, name: String, args := {}) -> void:
	if entities.has(id):
		Net.broadcast(_event, [id, name, args])


func send_all_to(peer: int) -> void:
	for img_id in _image_bytes:
		_image.rpc_id(peer, img_id, _image_bytes[img_id])
	for id in entities:
		var e: NetBody = entities[id]
		_spawn.rpc_id(peer, id, e.kind, e.global_transform, e.data)


## Remove loose props (keeps agents and anything carrying information).
func clear_props() -> void:
	for id in entities.keys():
		if not entities[id].kind in ["agent", "document", "clipboard"] and not entities[id].is_locked() and entities[id].grabbable():
			despawn(id)


func entities_of_kind(kind: String) -> Array:
	var out := []
	for id in entities:
		if entities[id].kind == kind:
			out.append(entities[id])
	return out


@rpc("authority", "call_local", "reliable")
func _spawn(id: int, kind: String, xform: Transform3D, data: Dictionary) -> void:
	if entities.has(id) or not root:
		return
	var node: NetBody = Entities.create(kind)
	node.entity_id = id
	node.kind = kind
	node.data = data
	node.name = "%s_%d" % [kind, id]
	root.add_child(node)
	node.global_transform = xform
	node.net_target = xform
	node.setup(Net.is_server())
	entities[id] = node
	_next_id = max(_next_id, id + 1)
	entities_changed.emit()
	var adopt: Variant = data.get("adopt")
	if adopt is Array and adopt.size() == 2 and int(adopt[0]) == Net.my_id() and Net.has_local_player():
		adopt_requested.emit(node, int(adopt[1]))


@rpc("authority", "call_local", "reliable")
func _despawn(id: int) -> void:
	if entities.has(id):
		entities[id].queue_free()
		entities.erase(id)
		entities_changed.emit()


@rpc("authority", "call_local", "reliable")
func _data(id: int, key: String, value: Variant) -> void:
	if entities.has(id):
		entities[id].data[key] = value
		entities[id].on_data(key, value)
		if key == "name":
			entities_changed.emit()


@rpc("authority", "call_local", "reliable")
func _event(id: int, name: String, args: Dictionary) -> void:
	if entities.has(id):
		entities[id].on_event(name, args)
		entity_event.emit(id, name, args)


# --- Snapshots -----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not Net.in_session:
		return
	if Net.is_server():
		_update_hand_proxies()
		_update_carried()
		_update_stowed()
		_snap_timer -= delta
		_full_timer -= delta
		if _snap_timer <= 0.0:
			_snap_timer = SNAP_INTERVAL
			var full := _full_timer <= 0.0
			if full:
				_full_timer = FULL_SNAP_INTERVAL
			_send_snapshot(full)


func _send_snapshot(full: bool) -> void:
	var ids := PackedInt32Array()
	var xf := PackedFloat32Array()
	for id in entities:
		var e: NetBody = entities[id]
		var t := e.global_transform
		var last: Variant = _last_sent.get(id)
		if not full and last != null and (last as Transform3D).is_equal_approx(t):
			continue
		_last_sent[id] = t
		var q := t.basis.get_rotation_quaternion()
		ids.append(id)
		xf.append_array([t.origin.x, t.origin.y, t.origin.z, q.x, q.y, q.z, q.w])
	if ids.size() > 0:
		Net.broadcast(_snap, [_now(), ids, xf], false)
	Net.broadcast(_psnap, [poses], false)


@rpc("authority", "unreliable_ordered", "call_remote", 1)
func _snap(t: float, ids: PackedInt32Array, xf: PackedFloat32Array) -> void:
	_sync_clock(t)
	for i in ids.size():
		var e: NetBody = entities.get(ids[i])
		if e:
			var o := i * 7
			e.push_snapshot(t, Transform3D(Basis(Quaternion(xf[o + 3], xf[o + 4], xf[o + 5], xf[o + 6])),
					Vector3(xf[o], xf[o + 1], xf[o + 2])))


func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0


## Server clock as estimated on this peer (exact on the server).
func server_now() -> float:
	return _now() + _clock_offset


func _sync_clock(server_t: float) -> void:
	# Late packets make the offset look smaller; trust the largest recent sample
	# and let it decay slowly in case the clocks drift.
	var sample := server_t - _now()
	if not _clock_synced or sample > _clock_offset:
		_clock_offset = sample
		_clock_synced = true
	else:
		_clock_offset = lerpf(_clock_offset, sample, 0.002)


@rpc("authority", "unreliable_ordered", "call_remote", 1)
func _psnap(p: Dictionary) -> void:
	var mine: Variant = poses.get(Net.my_id())
	poses = p
	if mine != null:
		poses[Net.my_id()] = mine # our own pose is always freshest locally


# --- Player poses -----------------------------------------------------------------

## Called by the local player every frame with world-space transforms.
## `rays`: [left, right], each [from, to] (world) or null when not showing a pointer ray.
## `physical_hands`: false for desktop mode, whose "hand" is a cursor that jumps
## around with the view and must not shove things.
func send_pose(head: Transform3D, left: Transform3D, right: Transform3D, rays := [null, null], physical_hands := true) -> void:
	if Net.is_server():
		_record_pose(Net.my_id(), head, left, right, rays, physical_hands)
	else:
		poses[Net.my_id()] = {"head": head, "l": left, "r": right, "rays": rays, "physical": physical_hands}
	if Net.mode != "client":
		return
	_pose_timer -= get_process_delta_time()
	if _pose_timer <= 0.0:
		_pose_timer = POSE_INTERVAL
		_pose.rpc_id(1, head, left, right, rays, physical_hands)


@rpc("any_peer", "unreliable_ordered", "call_remote", 1)
func _pose(head: Transform3D, left: Transform3D, right: Transform3D, rays: Array, physical_hands: bool) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if Net.players.has(peer):
		_record_pose(peer, head, left, right, rays.slice(0, 2), physical_hands)


## Server: store a pose and estimate hand velocities from successive updates.
func _record_pose(peer: int, head: Transform3D, left: Transform3D, right: Transform3D, rays := [null, null], physical_hands := true) -> void:
	var now := Time.get_ticks_usec()
	var prev: Dictionary = poses.get(peer, {})
	var meta: Dictionary = _pose_meta.get(peer, {"t": now, "v": [Vector3.ZERO, Vector3.ZERO]})
	var dt := (now - int(meta["t"])) / 1000000.0
	if not prev.is_empty() and dt > 0.001:
		for i in 2:
			var key := "l" if i == 0 else "r"
			var nv: Vector3 = ((left if i == 0 else right).origin - (prev[key] as Transform3D).origin) / dt
			# Teleports/tracking glitches aren't motion.
			meta["v"][i] = Vector3.ZERO if nv.length() > 15.0 else meta["v"][i].lerp(nv, 0.5)
	meta["t"] = now
	_pose_meta[peer] = meta
	poses[peer] = {"head": head, "l": left, "r": right, "rays": rays, "physical": physical_hands}


func head_xform(peer: int) -> Variant:
	return poses.get(peer, {}).get("head")


func hand_xform(peer: int, hand: int) -> Variant:
	return poses.get(peer, {}).get("l" if hand == 0 else "r")


## Server: hand pose extrapolated between the ~30 Hz updates from remote players.
func hand_xform_smooth(peer: int, hand: int) -> Variant:
	var t: Variant = hand_xform(peer, hand)
	if not t is Transform3D or not _pose_meta.has(peer):
		return t
	var age := minf((Time.get_ticks_usec() - int(_pose_meta[peer]["t"])) / 1000000.0, 0.06)
	return (t as Transform3D).translated(hand_velocity(peer, hand) * age)


func hand_velocity(peer: int, hand: int) -> Vector3:
	return _pose_meta.get(peer, {}).get("v", [Vector3.ZERO, Vector3.ZERO])[hand]


func _update_avatars() -> void:
	if not avatars_root:
		return
	for p in avatars.keys():
		if not Net.players.has(p):
			avatars[p].queue_free()
			avatars.erase(p)
	for p in Net.players:
		if p == Net.my_id() and Net.has_local_player():
			continue
		if not avatars.has(p):
			var a: Node3D = AvatarScript.make(p)
			avatars_root.add_child(a)
			avatars[p] = a
		avatars[p].set_player_name(Net.players[p]["name"])


# --- Server-side hand colliders (so hands can push things) ------------------------------

func server_add_player(peer: int) -> void:
	var pair := []
	for i in 2:
		var b := AnimatableBody3D.new()
		b.sync_to_physics = true
		b.collision_layer = 4
		b.collision_mask = 0
		var cs := CollisionShape3D.new()
		var sh := SphereShape3D.new()
		sh.radius = 0.06
		cs.shape = sh
		b.add_child(cs)
		b.position = Vector3(0, -100, 0)
		root.add_child(b)
		pair.append(b)
	_hand_proxies[peer] = pair


func server_remove_player(peer: int) -> void:
	for id in entities:
		var e: NetBody = entities[id]
		if e.held_by == peer:
			_srv_release(peer, id, Vector3.ZERO, Vector3.ZERO, false)
		var s: Variant = e.data.get("stowed")
		if s is Array and s.size() == 3 and int(s[0]) == peer:
			_unstow(e) # their inventory drops where they stood
	for b in _hand_proxies.get(peer, []):
		b.queue_free()
	_hand_proxies.erase(peer)
	poses.erase(peer)
	_pose_meta.erase(peer)
	server_stand(peer)


func _update_hand_proxies() -> void:
	for peer in _hand_proxies:
		for i in 2:
			var t: Variant = hand_xform_smooth(peer, i)
			if not t is Transform3D:
				continue
			var b: AnimatableBody3D = _hand_proxies[peer][i]
			# A jump (teleport, tracking loss) would fling whatever it lands in:
			# move without colliding this tick. Desktop "hands" never collide.
			var jump := b.global_position.distance_to((t as Transform3D).origin) > 0.4
			var physical: bool = poses[peer].get("physical", true)
			b.collision_layer = 0 if jump or not physical else NetBody.LAYER_HANDS
			b.global_transform = t


# --- Grab / release / use requests ------------------------------------------------------

func request_grab(id: int, hand: int, offset: Transform3D) -> void:
	if Net.is_server():
		_srv_grab(Net.my_id(), id, hand, offset)
	else:
		_grab.rpc_id(1, id, hand, offset)


## Put an item into the arm inventory slot on arm `arm` (0 = left, 1 = right;
## see ArmInventory). Whatever was in that slot drops out.
func request_stow(id: int, arm: int, _slot := 0) -> void:
	if Net.is_server():
		_srv_stow(Net.my_id(), id, arm)
	else:
		_stow.rpc_id(1, id, arm)


@rpc("any_peer", "reliable")
func _stow(id: int, arm: int) -> void:
	_srv_stow(multiplayer.get_remote_sender_id(), id, arm)


func _srv_stow(peer: int, id: int, arm: int) -> void:
	var e: NetBody = entities.get(id)
	if not e or not Net.players.has(peer) or not e.grabbable() or e is AgentBody or e.is_locked() or e.is_occupied():
		return
	if arm < 0 or arm >= ArmInventory.SLOTS or (e.held_by != 0 and e.held_by != peer):
		return
	for other in entities.values():
		var s: Variant = other.data.get("stowed")
		if s is Array and s.size() == 3 and int(s[0]) == peer and int(s[1]) == arm and other != e:
			_unstow(other) # the slot was full: that drops out
	if e.held_by == peer:
		_srv_release(peer, id, Vector3.ZERO, Vector3.ZERO, false)
	_force_release(e)
	set_data(id, "agent_holder", 0)
	set_data(id, "pinned", false)
	set_data(id, "stowed", [peer, arm, 0])


## Take something out of an arm inventory (it drops, or goes wherever it's being put).
func _unstow(e: NetBody) -> void:
	if e.is_stowed():
		set_data(e.entity_id, "stowed", null)


## Keep stowed items on their owners' arms.
func _update_stowed() -> void:
	for e: NetBody in entities.values():
		if not e.is_stowed() or e.held_by != 0:
			continue
		var s: Array = e.data["stowed"]
		var slot: Variant = ArmInventory.slot_transform(poses.get(int(s[0]), {}), int(s[1]))
		if slot is Transform3D:
			e.global_transform = (slot as Transform3D) * e.stow_offset()


## Context menu → Grab: teleport the object into your hand (0 = left,
## 1 = right) and hold it there, at `offset` (object relative to the hand;
## see Hand.hold_offset_for).
func request_fetch(id: int, hand: int, offset: Transform3D) -> void:
	if Net.is_server():
		_srv_fetch(Net.my_id(), id, hand, offset)
	else:
		_fetch.rpc_id(1, id, hand, offset)


@rpc("any_peer", "reliable")
func _fetch(id: int, hand: int, offset: Transform3D) -> void:
	_srv_fetch(multiplayer.get_remote_sender_id(), id, hand, offset)


func _srv_fetch(peer: int, id: int, hand: int, offset: Transform3D) -> void:
	if offset.origin.length() > 1.5:
		return
	var e: NetBody = entities.get(id)
	var h: Variant = hand_xform(peer, clampi(hand, 0, 1))
	if not e or not Net.players.has(peer) or not e.grabbable() or e is AgentBody or not h is Transform3D:
		return
	if e.is_locked() or e.is_occupied():
		Net.send_toast(peer, "It's locked in place." if e.is_locked() else "Someone is sitting there.")
		return
	if not Net.can(peer, "interact"):
		return
	_force_release(e)
	if int(e.data.get("agent_holder", 0)):
		set_data(id, "agent_holder", 0)
	offset = offset.orthonormalized()
	e.global_transform = (h as Transform3D) * offset
	e.linear_velocity = Vector3.ZERO
	e.angular_velocity = Vector3.ZERO
	_srv_grab(peer, id, clampi(hand, 0, 1), offset)


func request_release(id: int, lin_vel: Vector3, ang_vel: Vector3) -> void:
	if Net.is_server():
		_srv_release(Net.my_id(), id, lin_vel, ang_vel)
	else:
		_release.rpc_id(1, id, lin_vel, ang_vel)


func request_use(id: int) -> void:
	if Net.is_server():
		_srv_use(Net.my_id(), id)
	else:
		_use.rpc_id(1, id)


## Interact with something you're not holding (sit on a chair, switch a lamp…).
func request_interact(id: int) -> void:
	if Net.is_server():
		_srv_interact(Net.my_id(), id)
	else:
		_interact.rpc_id(1, id)


func request_stand() -> void:
	if Net.is_server():
		server_stand(Net.my_id())
	else:
		_stand.rpc_id(1)


@rpc("any_peer", "reliable")
func _interact(id: int) -> void:
	_srv_interact(multiplayer.get_remote_sender_id(), id)


@rpc("any_peer", "reliable")
func _stand() -> void:
	if Net.players.has(multiplayer.get_remote_sender_id()):
		server_stand(multiplayer.get_remote_sender_id())


func _srv_interact(peer: int, id: int) -> void:
	var e: NetBody = entities.get(id)
	if not e or not Net.can(peer, "interact") or e.is_stowed():
		return
	# Must be within reach (the desktop crosshair reaches 4 m; allow for the
	# object's size). Menu "Sit here" uses Office's "sit" action instead: no limit.
	var head: Variant = head_xform(peer)
	if head is Transform3D and (head as Transform3D).origin.distance_to(e.global_position) > INTERACT_REACH:
		Net.send_toast(peer, "Too far away — get closer, or point at it and use its menu.")
		return
	e.server_interact(peer)


## Server: remove a stuck object from someone's hand.
func server_force_release(id: int) -> void:
	var e: NetBody = entities.get(id)
	if e and e.held_by != 0:
		Net.send_toast(e.held_by, "It's stuck, so you let go.")
		_srv_release(e.held_by, id, Vector3.ZERO, Vector3.ZERO, false)


@rpc("any_peer", "reliable")
func _grab(id: int, hand: int, offset: Transform3D) -> void:
	_srv_grab(multiplayer.get_remote_sender_id(), id, hand, offset)


@rpc("any_peer", "reliable")
func _release(id: int, lin_vel: Vector3, ang_vel: Vector3) -> void:
	_srv_release(multiplayer.get_remote_sender_id(), id, lin_vel, ang_vel)


@rpc("any_peer", "reliable")
func _use(id: int) -> void:
	_srv_use(multiplayer.get_remote_sender_id(), id)


func _srv_grab(peer: int, id: int, hand: int, offset: Transform3D) -> void:
	var e: NetBody = entities.get(id)
	if not e or not Net.players.has(peer) or not e.grabbable():
		return
	if e.is_occupied():
		Net.send_toast(peer, "Someone is sitting there.")
		return
	if e.is_locked():
		Net.send_toast(peer, "It's locked in place.")
		return
	if int(e.data.get("sitting_on", 0)):
		_unsit_agent(e) # picking an agent up stands it up
	if e.held_by != 0 and e.held_by != peer:
		_set_proxy_exceptions(e, e.held_by, false)
	_stop_flying(e)
	_unstow(e)
	e.server_grab(peer, hand, offset)
	_set_proxy_exceptions(e, peer, true)
	set_data(id, "held_by", peer)
	if e.data.get("pinned", false):
		set_data(id, "pinned", false)
	if int(e.data.get("agent_holder", 0)):
		set_data(id, "agent_holder", 0)


func _srv_release(peer: int, id: int, lin_vel: Vector3, ang_vel: Vector3, handoff := true) -> void:
	var e: NetBody = entities.get(id)
	if not e or e.held_by != peer:
		return
	e.server_release(lin_vel.limit_length(12.0), ang_vel.limit_length(30.0))
	set_data(id, "held_by", 0)
	if e is AgentBody and handoff:
		_try_seat_agent(e)
	if handoff and e.kind in HANDABLE and lin_vel.length() < 3.0:
		_check_handoff(peer, e)
	# Let the thrown object clear the hand before it can collide with it again.
	# (By id: it may be deleted meanwhile.)
	get_tree().create_timer(0.3).timeout.connect(func():
		if entities.has(id):
			_set_proxy_exceptions(entities[id], peer, false))


func _srv_use(peer: int, id: int) -> void:
	var e: NetBody = entities.get(id)
	if e and Net.players.has(peer):
		e.server_use(peer)


func _set_proxy_exceptions(e: NetBody, peer: int, add: bool) -> void:
	for b in _hand_proxies.get(peer, []):
		if add:
			e.add_collision_exception_with(b)
		else:
			e.remove_collision_exception_with(b)


# --- Images (whiteboards, clipboards) ----------------------------------------------------

## Server: register PNG/JPG/WebP bytes (or an Image) and share it. Returns id or 0.
func add_image(source: Variant) -> int:
	var img: Image
	if source is Image:
		img = source
	else:
		img = _decode_image(source)
	if img == null or img.is_empty():
		return 0
	var longest := maxi(img.get_width(), img.get_height())
	if longest > 1024:
		var s := 1024.0 / longest
		img.resize(int(img.get_width() * s), int(img.get_height() * s), Image.INTERPOLATE_BILINEAR)
	if img.detect_alpha() != Image.ALPHA_NONE:
		# Boards and pages are white; flatten transparency onto white.
		img.convert(Image.FORMAT_RGBA8)
		var bg := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
		bg.fill(Color.WHITE)
		bg.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
		img = bg
	var png := img.save_png_to_buffer()
	var id := _next_image
	_next_image += 1
	_image_bytes[id] = png
	Net.broadcast(_image, [id, png])
	return id


func add_svg(svg: String) -> int:
	var img := Image.new()
	if img.load_svg_from_string(svg, 1.0) != OK or img.is_empty():
		return 0
	var longest := maxi(img.get_width(), img.get_height())
	if longest > 0 and longest < 800:
		img = Image.new()
		img.load_svg_from_string(svg, 800.0 / longest)
	return add_image(img)


func _decode_image(bytes: PackedByteArray) -> Image:
	var img := Image.new()
	for loader in [img.load_png_from_buffer, img.load_jpg_from_buffer, img.load_webp_from_buffer]:
		if loader.call(bytes) == OK:
			return img
	return null


@rpc("authority", "call_local", "reliable")
func _image(id: int, png: PackedByteArray) -> void:
	var img := Image.new()
	if img.load_png_from_buffer(png) == OK:
		images[id] = ImageTexture.create_from_image(img)
		_next_image = max(_next_image, id + 1)
		image_added.emit(id)


# --- Handing things over ----------------------------------------------------------

## Where to float an item for a player: in front of their chest, facing them.
func hand_out_xform(peer: int) -> Transform3D:
	var head: Variant = head_xform(peer)
	if not head is Transform3D:
		return Transform3D(Basis.IDENTITY, Office.spawn_xform().origin + Vector3(0, 1.2, -0.5))
	var h: Transform3D = head
	var fwd := -h.basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var base := h.origin + fwd * 0.45 + Vector3(0, -0.3, 0)
	var right := fwd.cross(Vector3.UP)
	# Fan out beside anything already floating there: 0, +1, -1, +2, -2 …
	var pos := base
	for k in 9:
		pos = base + right * 0.26 * ceili(k / 2.0) * (1 if k % 2 else -1)
		var free := true
		for e in entities.values():
			if e.data.get("pinned", false) and int(e.data.get("agent_holder", 0)) == 0 \
					and (e.global_position.distance_to(pos) < 0.2 or (e.has_meta("fly_to") and e.get_meta("fly_to").distance_to(pos) < 0.2)):
				free = false
				break
		if free:
			break
	# Item content faces its +Z, so point -Z away from the person.
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)


## Released next to an AI -> the AI takes it. Released on the whiteboard -> pinned there.
func _check_handoff(peer: int, e: NetBody) -> void:
	for a in entities_of_kind("agent"):
		var d: Vector3 = e.global_position - a.global_position
		if Vector2(d.x, d.z).length() < 0.9 and d.y > 0.3 and d.y < 2.2:
			AI.server_receive_item(a.entity_id, e.entity_id, peer)
			return
	for board in entities_of_kind("whiteboard"):
		if board.is_near(e.global_position):
			AI.server_show_on_board(e.entity_id, peer, board)
			return


## Server: an AI agent takes an item; it flies into their hand.
func give_to_agent(item_id: int, agent_id: int) -> void:
	var e: NetBody = entities.get(item_id)
	var a: AgentBody = entities.get(agent_id)
	if not e or not a:
		return
	_force_release(e)
	set_data(item_id, "pinned", true)
	set_data(item_id, "agent_holder", agent_id)
	_fly(e, a.hold_xform(carried_by(agent_id).find(e)))


## Server: float an item over to hover in front of a player, ready to take.
func give_to_player(item_id: int, peer: int) -> void:
	var e: NetBody = entities.get(item_id)
	if not e:
		return
	_force_release(e)
	set_data(item_id, "pinned", true)
	set_data(item_id, "agent_holder", 0)
	_fly(e, hand_out_xform(peer))


## Server: put an item down on the floor in front of whoever is carrying it.
func drop_item(item_id: int) -> void:
	var e: NetBody = entities.get(item_id)
	if not e:
		return
	_force_release(e)
	set_data(item_id, "agent_holder", 0)
	set_data(item_id, "pinned", false)


func carried_by(agent_id: int) -> Array:
	var out := []
	for e in entities.values():
		if int(e.data.get("agent_holder", 0)) == agent_id:
			out.append(e)
	return out


func _force_release(e: NetBody) -> void:
	_stop_flying(e)
	_unstow(e)
	if e.held_by != 0:
		_srv_release(e.held_by, e.entity_id, Vector3.ZERO, Vector3.ZERO, false)


func _fly(e: NetBody, target: Transform3D) -> void:
	_stop_flying(e)
	e.freeze = true
	var from := e.global_transform
	var t := e.create_tween()
	e.set_meta("fly", t)
	e.set_meta("fly_to", target.origin)
	t.tween_method(func(k: float):
		var xf := from.interpolate_with(target, k)
		xf.origin.y += sin(k * PI) * 0.35
		e.global_transform = xf, 0.0, 1.0, 0.9).set_trans(Tween.TRANS_SINE)
	t.finished.connect(func():
		e.remove_meta("fly")
		e.remove_meta("fly_to"))


func _stop_flying(e: NetBody) -> void:
	if e.has_meta("fly"):
		(e.get_meta("fly") as Tween).kill()
		e.remove_meta("fly")
		e.remove_meta("fly_to")


## Keep items an agent carries in its hand as the agent is moved around.
func _update_carried() -> void:
	var slots := {}
	for e in entities.values():
		var holder := int(e.data.get("agent_holder", 0))
		if holder == 0 or e.held_by != 0:
			continue
		var a: AgentBody = entities.get(holder)
		if not a:
			set_data(e.entity_id, "agent_holder", 0)
			set_data(e.entity_id, "pinned", false)
			continue
		var slot: int = slots.get(holder, 0)
		slots[holder] = slot + 1
		if not e.has_meta("fly"):
			e.global_transform = a.hold_xform(slot)


# --- Sitting ------------------------------------------------------------------------

## World transform of a chair's seat surface; the sitter faces the chair's -Z.
func seat_xform(chair: NetBody) -> Transform3D:
	return chair.global_transform * Transform3D(Basis.IDENTITY, Vector3(0, 0.03, 0.03))


## Server: `who` (peer id, or -agent id) sits on `chair`, leaving any other seat first.
func server_sit(who: int, chair: NetBody) -> void:
	if chair.is_occupied():
		if int(chair.data.get("seated", 0)) != who and who > 0:
			Net.send_toast(who, "That seat is taken.")
		return
	server_stand(who)
	_force_release(chair)
	# Level the chair so nobody sits at an angle.
	chair.global_transform = Transform3D(Basis(Vector3.UP, chair.global_rotation.y), chair.global_position)
	chair.linear_velocity = Vector3.ZERO
	chair.angular_velocity = Vector3.ZERO
	set_data(chair.entity_id, "seated", who)


func server_stand(who: int) -> void:
	for e in entities.values():
		if int(e.data.get("seated", 0)) == who:
			set_data(e.entity_id, "seated", 0)


## Agents released onto a free chair sit down.
func _try_seat_agent(agent: AgentBody) -> void:
	for c in entities_of_kind("chair"):
		var d: Vector3 = agent.global_position - seat_xform(c).origin
		if Vector2(d.x, d.z).length() < 0.45 and absf(d.y) < 0.8 and not c.is_occupied():
			seat_agent(agent, c)
			return


## Server: sit an agent on a (free) chair. Returns false if the chair is taken.
func seat_agent(agent: NetBody, chair: NetBody) -> bool:
	if chair.is_occupied():
		return false
	server_sit(-agent.entity_id, chair)
	set_data(agent.entity_id, "sitting_on", chair.entity_id)
	agent.global_transform = seat_xform(chair)
	return true


func _unsit_agent(agent: NetBody) -> void:
	var chair: NetBody = entities.get(int(agent.data.get("sitting_on", 0)))
	set_data(agent.entity_id, "sitting_on", 0)
	if chair:
		set_data(chair.entity_id, "seated", 0)
		var front := seat_xform(chair).origin - chair.global_basis.z * 0.55
		agent.global_position = Vector3(front.x, 0.02, front.z)


## Server: stand an agent up (e.g. before summoning it elsewhere).
func server_unsit_agent(agent_id: int) -> void:
	var a: NetBody = entities.get(agent_id)
	if a and int(a.data.get("sitting_on", 0)):
		_unsit_agent(a)


# --- Spawning without overlaps ----------------------------------------------------------

## Server: a spot near `near` with nothing within `radius`, so new things don't
## spawn inside others (overlapping rigid bodies fly apart violently).
func free_spot(near: Vector3, radius := 0.45) -> Vector3:
	var half := Office.size() * 0.5 - Vector3(radius, 0, radius)
	for ring in 8:
		var count := 1 if ring == 0 else ring * 6
		for k in count:
			var a := TAU * k / count + ring * 0.5
			var p := near + Vector3(cos(a), 0, sin(a)) * ring * radius * 1.6
			p.x = clampf(p.x, -half.x, half.x)
			p.z = clampf(p.z, -half.z, half.z)
			if _clear_at(p, radius):
				return p
	return near


func _clear_at(p: Vector3, radius: float) -> bool:
	for e in entities.values():
		if e.is_parked():
			continue
		var d: Vector3 = e.global_position - p
		var r := 0.9 if e.kind == "table" else (0.4 if e.kind in ["agent", "chair"] else 0.2)
		if Vector2(d.x, d.z).length() < radius + r and absf(d.y) < 2.0:
			return false
	return true


# --- Admin actions ------------------------------------------------------------------------

func server_set_locked(id: int, on: bool) -> void:
	var e: NetBody = entities.get(id)
	if not e:
		return
	if on:
		_force_release(e)
		e.linear_velocity = Vector3.ZERO
		e.angular_velocity = Vector3.ZERO
	set_data(id, "locked", on)


## Server: turn an object about the vertical by `degrees`, standing it upright
## (perpendicular to the floor) if it had tipped over.
func server_rotate(id: int, degrees: float) -> void:
	var e: NetBody = entities.get(id)
	if not e:
		return
	_force_release(e)
	var yaw := e.global_rotation.y
	var tipped := e.global_basis.y.normalized().dot(Vector3.UP) < 0.95
	var pos := e.global_position
	if tipped and Office.SPAWN_HEIGHT.has(e.kind):
		pos.y = maxf(pos.y, Office.SPAWN_HEIGHT[e.kind]) # stood back up on the floor
	e.global_transform = Transform3D(Basis(Vector3.UP, yaw + deg_to_rad(degrees)), pos)
	e.linear_velocity = Vector3.ZERO
	e.angular_velocity = Vector3.ZERO
	e.sleeping = false


## Server: remove an item/prop (not agents: see AI.server_remove_agent).
func server_delete(id: int) -> void:
	var e: NetBody = entities.get(id)
	if not e or e is AgentBody:
		return
	_force_release(e)
	# Whoever sits on a deleted chair stands up first.
	var seated := int(e.data.get("seated", 0))
	if seated < 0 and entities.has(-seated):
		_unsit_agent(entities[-seated])
	elif seated > 0:
		set_data(id, "seated", 0)
	for item in carried_by(id):
		drop_item(item.entity_id)
	despawn(id)
