class_name NetBody extends RigidBody3D
## Base for every replicated physics object (the root of each entity scene in
## scenes/entities/). Subclasses override _build(), _data_changed(),
## on_event(), server_use() (trigger while held) and server_interact()
## (trigger/E on it while not holding anything: sit, switch on…).
##
## Server: a real rigid body. Held bodies are driven toward the (smoothed,
## extrapolated) hand with velocity matching instead of teleporting, so they
## still collide sensibly; heavy things lag behind the hand a little.
## Clients: frozen copies that interpolate between timestamped snapshots
## rendered INTERP_DELAY behind the server, which hides network jitter.

const LAYER_WORLD := 1
const LAYER_PROPS := 2
const LAYER_HANDS := 4
## Items floating in the air or carried by an AI: grabbable, but they don't
## collide with anything (so they can't shove agents or props around).
const LAYER_FLOATING := 32
const INTERP_DELAY := 0.1
const RELEASE_BLEND := 0.25
## A held body further than this from the hand for a while is let go (stuck behind a wall…).
const MAX_HOLD_ERROR := 0.7

## Stowed items are shown this big at most (largest side, metres).
const STOW_SIZE := 0.07

var entity_id := 0
var kind := ""
var data := {}
## Latest server transform (clients interpolate toward it).
var net_target := Transform3D()
var is_server_side := false
## Peer currently holding this (0 = nobody).
var held_by := 0
## Upright bodies (agents) only translate when carried and never tip over.
var upright := false
## server: the last player who held this (for permission checks, e.g. paint).
var last_holder := 0

var _hold_hand := 0
var _hold_offset := Transform3D()
var _hold_pos_offset := Vector3.ZERO
var _stuck_time := 0.0
## Stowed in *our* arm inventory: ArmInventory places it each frame.
var stow_local := false
## Visual centre of the shrunken item (body space), to centre it on its slot.
var _stow_center := Vector3.ZERO

## Client-side prediction while *we* hold it.
var local_holder: Node3D
var local_offset := Transform3D()
var local_pos_offset := Vector3.ZERO

## Client snapshot buffer: [[server_time, Transform3D], …] oldest first.
var _snaps: Array = []
var _blend_from := Transform3D()
var _blend_left := 0.0


func setup(server: bool) -> void:
	is_server_side = server
	_build()
	if upright:
		axis_lock_angular_x = true
		axis_lock_angular_z = true
	# Small fast things (balls, paint, documents) must not tunnel through walls.
	continuous_cd = mass < 3.0
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	can_sleep = true
	held_by = data.get("held_by", 0)
	for k in data:
		_data_changed(k, data[k])
	_show_lock_badge(is_locked())
	if is_stowed():
		_show_stowed(true)
	_refresh_physics_state()
	if Config.has_arg("show-grab-points") and grabbable():
		Mk.axes(self, 0.08).transform = grab_point() # (docs/GRAB_POINTS.md)


func _build() -> void:
	pass


func _data_changed(_key: String, _value: Variant) -> void:
	pass


func on_event(_name: String, _args: Dictionary) -> void:
	pass


## Trigger while holding this.
func server_use(_peer: int) -> void:
	pass


## Trigger (VR) / E (desktop) on this while not holding anything.
func server_interact(_peer: int) -> void:
	pass


## Where a hand holds this when it's put into a hand (context menu → Grab, a
## file pulled from a drawer): the scene's "GrabPoint" Marker3D (its +Y runs
## along your fingers, +Z out of your palm), or the centre.
func grab_point() -> Transform3D:
	var gp := get_node_or_null("GrabPoint") as Node3D
	return gp.transform if gp else Transform3D.IDENTITY


## What a save stores for this (its data; timers store the time left instead
## of a clock reading).
func saved_data() -> Dictionary:
	return data.duplicate(true)


## Can people pick this up at all? (Wall widgets can't be; locked things say why.)
func grabbable() -> bool:
	return true


## Permission (Net.PERMS) an operation on this needs, or "" if there's no such
## operation. Operations come from menus and widgets via Widgets.request_op().
func op_perm(_op: String) -> String:
	return ""


## Server: carry out an operation (already permission checked). Returns a
## message for the requester, or "" for none.
func server_op(_peer: int, _op: String, _args: Dictionary) -> String:
	return ""


## Client: extra items for this entity's context menu (e.g. a monitor's
## Connect…). `menu` is the open RadialMenu.
func menu_items(_menu: RadialMenu) -> Array:
	return []


## Pinned in mid-air, carried by an AI, stowed on someone's arm, or otherwise parked (sat on…).
func is_parked() -> bool:
	return data.get("pinned", false) == true or int(data.get("agent_holder", 0)) != 0 or int(data.get("sitting_on", 0)) != 0 or is_stowed()


## In someone's arm inventory (data "stowed" = [peer, hand, slot]).
func is_stowed() -> bool:
	var s: Variant = data.get("stowed")
	return s is Array and s.size() == 3


## Where the body sits relative to its slot, so its shrunken look is centred there.
func stow_offset() -> Transform3D:
	return Transform3D(Basis.IDENTITY, -_stow_center)


## Shrink (or restore) the visible parts while stowed. Collision is off then.
func _show_stowed(on: bool) -> void:
	var parts: Array[Node3D] = []
	for c in get_children():
		if c is Node3D and not c is CollisionShape3D and c.name != "LockBadge":
			parts.append(c)
	if not on:
		for c in parts:
			if c.has_meta("unstowed"):
				c.transform = c.get_meta("unstowed")
				c.remove_meta("unstowed")
		stow_local = false
		return
	var box := AABB()
	var first := true
	for m in find_children("*", "VisualInstance3D", true, false):
		var b: AABB = (global_transform.affine_inverse() * (m as VisualInstance3D).global_transform) * (m as VisualInstance3D).get_aabb()
		box = b if first else box.merge(b)
		first = false
	var s := minf(1.0, STOW_SIZE / maxf(box.get_longest_axis_size(), 0.001)) if not first else 1.0
	_stow_center = box.get_center() * s
	for c in parts:
		if not c.has_meta("unstowed"):
			c.set_meta("unstowed", c.transform)
		var t: Transform3D = c.get_meta("unstowed")
		c.transform = Transform3D(t.basis.scaled(Vector3.ONE * s), t.origin * s)


## Locked in place by an admin: frozen, can't be picked up (still collides; can still be sat on).
func is_locked() -> bool:
	return data.get("locked", false) == true


## Something (a person or an agent) is sitting on this.
func is_occupied() -> bool:
	return int(data.get("seated", 0)) != 0


func on_data(key: String, value: Variant) -> void:
	if key == "held_by":
		held_by = value
		if held_by != Net.my_id():
			local_holder = null
	_data_changed(key, value)
	if key == "locked":
		_show_lock_badge(value == true)
	if key == "stowed":
		_show_stowed(is_stowed())
	if key in ["pinned", "agent_holder", "sitting_on", "seated", "held_by", "locked", "stowed"]:
		_refresh_physics_state()


func _show_lock_badge(on: bool) -> void:
	var badge: Label3D = get_node_or_null("LockBadge")
	if on and not badge:
		badge = Mk.label(self, "locked", 28, Vector3(0, 0.35, 0))
		badge.name = "LockBadge"
		badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		badge.pixel_size = 0.0007
		badge.modulate = Color("#f2d06b")
	elif badge and not on:
		badge.queue_free()


func _refresh_physics_state() -> void:
	var floating := is_parked() and held_by == 0
	collision_layer = LAYER_FLOATING if floating else LAYER_PROPS
	collision_mask = 0 if floating else (LAYER_WORLD | LAYER_PROPS | LAYER_HANDS)
	if is_stowed() and held_by == 0:
		collision_layer = 0 # on someone's arm: taken out through the inventory only
	if is_server_side:
		# Occupied chairs don't budge; parked items hang where they're put.
		freeze = held_by == 0 and (is_parked() or is_occupied() or is_locked())
	else:
		freeze = true


# --- Holding (server) -------------------------------------------------------------

func server_grab(peer: int, hand: int, offset: Transform3D) -> void:
	held_by = peer
	last_holder = peer
	_hold_hand = hand
	_hold_offset = offset
	_stuck_time = 0.0
	freeze = false
	gravity_scale = 0.0
	sleeping = false
	var h: Variant = Sync.hand_xform(peer, hand)
	_hold_pos_offset = global_position - (h as Transform3D).origin if h is Transform3D else Vector3.ZERO


func server_release(lin_vel: Vector3, ang_vel: Vector3) -> void:
	held_by = 0
	gravity_scale = 1.0
	linear_velocity = lin_vel
	angular_velocity = Vector3.ZERO if upright else ang_vel


func _physics_process(delta: float) -> void:
	if not is_server_side or held_by == 0:
		return
	var h: Variant = Sync.hand_xform_smooth(held_by, _hold_hand)
	if not h is Transform3D:
		return
	var hand: Transform3D = h
	var hand_vel: Vector3 = Sync.hand_velocity(held_by, _hold_hand)
	var target := Transform3D(global_basis, hand.origin + _hold_pos_offset) if upright else hand * _hold_offset
	var err := target.origin - global_position
	# Match the hand's velocity and close part of the gap each step; heavy
	# objects close it more slowly, so they feel heavy and don't bulldoze things.
	var gain := clampf(8.0 / mass, 0.12, 0.6)
	linear_velocity = (hand_vel + err / delta * gain).limit_length(14.0)
	if not upright:
		var q := (target.basis.get_rotation_quaternion() * global_basis.get_rotation_quaternion().inverse()).normalized()
		if q.w < 0.0:
			q = -q
		var axis := Vector3(q.x, q.y, q.z)
		if axis.length() > 0.00001:
			var angle := 2.0 * acos(clampf(q.w, -1.0, 1.0))
			angular_velocity = (axis.normalized() * angle / delta * 0.5).limit_length(25.0)
		else:
			angular_velocity = Vector3.ZERO
	_stuck_time = _stuck_time + delta if err.length() > MAX_HOLD_ERROR else 0.0
	if _stuck_time > 0.5:
		Sync.server_force_release(entity_id)


# --- Client side -------------------------------------------------------------------

func push_snapshot(server_time: float, xf: Transform3D) -> void:
	net_target = xf
	if _snaps.size() and server_time <= _snaps[-1][0]:
		return
	_snaps.append([server_time, xf])
	if _snaps.size() > 8:
		_snaps.pop_front()


func begin_local_hold(hand: Node3D) -> void:
	local_holder = hand
	local_offset = hand.global_transform.affine_inverse() * global_transform
	local_pos_offset = global_position - hand.global_position


func end_local_hold() -> void:
	local_holder = null
	# Ease from where we drew it to the server's (slightly delayed) view.
	_blend_from = global_transform
	_blend_left = RELEASE_BLEND


func _process(delta: float) -> void:
	if is_server_side:
		return
	if stow_local and is_stowed():
		return # ArmInventory places it on our arm
	if local_holder and is_instance_valid(local_holder):
		if upright:
			global_position = local_holder.global_position + local_pos_offset
		else:
			global_transform = local_holder.global_transform * local_offset
		return
	var xf := _interpolated()
	if _blend_left > 0.0:
		_blend_left -= delta
		xf = _blend_from.interpolate_with(xf, 1.0 - clampf(_blend_left / RELEASE_BLEND, 0.0, 1.0))
	global_transform = xf


func _interpolated() -> Transform3D:
	if _snaps.is_empty():
		return net_target
	var t := Sync.server_now() - INTERP_DELAY
	if t <= _snaps[0][0]:
		return _snaps[0][1]
	for i in range(_snaps.size() - 1):
		var a: Array = _snaps[i]
		var b: Array = _snaps[i + 1]
		if t <= b[0]:
			var k: float = (t - a[0]) / maxf(b[0] - a[0], 0.0001)
			return (a[1] as Transform3D).interpolate_with(b[1], k)
	return _snaps[-1][1]
