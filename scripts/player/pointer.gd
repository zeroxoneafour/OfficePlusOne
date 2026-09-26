class_name Pointer extends Node3D
## One hand's pointing ray and the "pull back into a fist" context-menu
## gesture (scenes/player/pointer.tscn).
##
## 1. POINTING: while you point, a ray is cast from your hand; it remembers
##    what it hits (floor, seat, object, AI, person, or a menu button).
## 2. LOCKED: as you start to clench, the ray freezes on that target.
## 3. Pull the hand back along the ray (away from the target) while closing
##    your fist. After PULL_DISTANCE (~6 in) with a full fist,
##    menu_requested fires and the context menu appears around your hand.
##    Re-pointing unlocks; pushing forward, moving sideways or waiting cancels.
## While hovering a button, pinch (hands) or trigger (controllers) clicks it.
## On a whiteboard, holding the pinch/trigger draws where the ray meets it
## (draw_board / draw_point) as you move the ray.

signal menu_requested(target: Dictionary, at: Vector3)

const PULL_DISTANCE := 0.1524 # 6 inches
const MAX_RANGE := 15.0
const LOCK_CLENCH := 0.25
const FULL_CLENCH := 0.8
const POINT_MEMORY := 0.5 # s: clenching/clicking this soon after pointing still counts
const POINT_HOLD := 0.15 # s: must point this long before a clench can lock (not a pass-through pose)
const GRAB_OVERRIDE_PULL := 0.05 # m: an object in reach before this much pull-back wins (grab, not menu)
const LOCK_TIMEOUT := 5.0
## A pinch/trigger click goes to the button the ray was on this long before
## (the pinch itself nudges the hand, and so the ray, off small buttons).
const CLICK_REWIND := 0.15
const MASK := NetBody.LAYER_WORLD | NetBody.LAYER_PROPS | NetBody.LAYER_FLOATING | PokeButton.LAYER_BUTTONS | 64

enum State { IDLE, POINTING, LOCKED, DONE }

const COLORS := {
	"idle": Color(1, 1, 1, 0.45), "button": Color(0.3, 0.9, 1.0, 0.9),
	"locked": Color(1.0, 0.85, 0.2, 0.9), "ready": Color(0.3, 1.0, 0.45, 0.95),
}

var state := State.IDLE
## The hand this pointer belongs to, and the XROrigin (for origin-space tracking).
var hand: Hand
var rig: Node3D
## Palm-button toggle: show the ray (to you and others).
var ray_visible := true
## Last thing pointed at (see classify()).
var target := {}
## 0..1 progress of the pull-back while LOCKED.
var progress := 0.0
var ray_from := Vector3.ZERO
var ray_to := Vector3.ZERO
## The whiteboard the ray is drawing on this frame (null when not drawing).
var draw_board: WhiteboardWidget
var draw_point := Vector3.ZERO

var _hover: PokeButton
## Recent [time, button-or-null] samples of what the ray was on.
var _hover_history: Array = []
var _last_point_time := -10.0
var _point_start_time := -10.0
var _lock_time := 0.0
var _lock_hand_local := Vector3.ZERO
var _lock_dir_local := Vector3.FORWARD
var _lock_from_local := Vector3.ZERO
var _lock_to_local := Vector3.ZERO


## Run the state machine for this frame. Returns what the hand must ignore
## this frame: {"grip": bool, "trigger": bool}.
func update_pointer(g: HandGestures) -> Dictionary:
	var suppress := {"grip": false, "trigger": false}
	var now := Time.get_ticks_msec() / 1000.0
	draw_board = null
	if g.source == "none" or hand.held != null:
		_set_state(State.IDLE)
		_draw()
		return suppress
	# Drawing: pointing at a whiteboard, then holding a pinch (or the trigger)
	# keeps the ray live and draws where it lands. (It never locks into the
	# context-menu gesture meanwhile.)
	if state == State.POINTING and (g.pinch or g.trigger) and _board_under_ray() != null:
		_last_point_time = now
		_cast(g.ray_origin, g.ray_dir)
		draw_board = _board_under_ray()
		draw_point = ray_to
		suppress["grip"] = true
		suppress["trigger"] = true
		_draw()
		return suppress
	match state:
		State.IDLE, State.POINTING:
			if g.pointing:
				if state == State.IDLE:
					_point_start_time = now
				_set_state(State.POINTING)
				_last_point_time = now
				_cast(g.ray_origin, g.ray_dir)
			elif state == State.POINTING and g.clench >= LOCK_CLENCH and now - _last_point_time < POINT_MEMORY \
					and _last_point_time - _point_start_time >= POINT_HOLD \
					and target.get("type", "none") not in ["none", "button"] and not hand.has_grab_candidate():
				_lock(now)
				suppress["grip"] = true
			elif now - _last_point_time > POINT_MEMORY:
				_set_state(State.IDLE)
			# Clicking the button under the ray. Checked whether or not we're still
			# "pointing" this frame: pinching bends the index and pulling a
			# controller's trigger touches it, both of which end the point, and
			# the (frozen) ray is still on the button the user meant.
			var clicked := _hover_at(now - CLICK_REWIND)
			if clicked and state == State.POINTING:
				suppress["grip"] = true
				if g.pinch_started or g.trigger_started:
					clicked.press()
					hand.haptic(0.4)
					suppress["trigger"] = true
		State.LOCKED:
			suppress["grip"] = true
			suppress["trigger"] = true
			var moved: Vector3 = _lock_hand_local - rig.to_local(hand.global_position)
			var pull := moved.dot(_lock_dir_local)
			var sideways := (moved - _lock_dir_local * pull).length()
			progress = clampf(pull / PULL_DISTANCE, 0.0, 1.0)
			if pull < GRAB_OVERRIDE_PULL and hand.has_grab_candidate():
				# The hand closed on something within reach: that's a grab.
				_set_state(State.IDLE)
				suppress["grip"] = false
				suppress["trigger"] = false
			elif pull >= PULL_DISTANCE and g.clench >= FULL_CLENCH:
				_set_state(State.DONE)
				hand.haptic(0.8)
				menu_requested.emit(target, hand.global_position)
			elif g.pointing and g.clench < 0.1:
				_set_state(State.POINTING) # opened the hand again: keep pointing
			elif pull < -0.1 or sideways > 0.25 or now - _lock_time > LOCK_TIMEOUT:
				_set_state(State.IDLE)
			ray_from = rig.to_global(_lock_from_local)
			ray_to = rig.to_global(_lock_to_local)
		State.DONE:
			suppress["grip"] = true
			suppress["trigger"] = true
			if g.clench < 0.3:
				_set_state(State.IDLE)
	_draw()
	return suppress


## Stand down (this hand isn't the one that points).
func idle() -> void:
	_set_state(State.IDLE)
	draw_board = null
	_draw()


## [from, to] for other people to see, or null when there's nothing to show.
func net_ray() -> Variant:
	if not ray_visible or state == State.IDLE:
		return null
	return [ray_from, ray_to]


func _set_state(s: State) -> void:
	if s == state:
		return
	state = s
	progress = 0.0
	if s == State.IDLE:
		_hover = null
		_hover_history.clear()


func _lock(now: float) -> void:
	_set_state(State.LOCKED)
	_lock_time = now
	_lock_hand_local = rig.to_local(hand.global_position)
	_lock_from_local = rig.to_local(ray_from)
	_lock_to_local = rig.to_local(ray_to)
	_lock_dir_local = (_lock_to_local - _lock_from_local).normalized()
	hand.haptic(0.3)


func _cast(from: Vector3, dir: Vector3) -> void:
	ray_from = from
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * MAX_RANGE, MASK)
	q.collide_with_areas = true
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		ray_to = from + dir * 3.0
		target = {}
		_hover = null
		_remember_hover()
		return
	ray_to = hit["position"]
	target = classify(hit)
	_hover = target.get("button") if target.get("type") == "button" else null
	_remember_hover()


func _board_under_ray() -> WhiteboardWidget:
	return Sync.entities.get(int(target.get("entity_id", 0))) as WhiteboardWidget if target.get("type") == "widget" else null


func _remember_hover() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_hover_history.append([now, _hover])
	while _hover_history.size() > 2 and now - _hover_history[0][0] > CLICK_REWIND * 2.0:
		_hover_history.pop_front()


## The button the ray was on at time `t` (falling back to the one it's on now).
func _hover_at(t: float) -> PokeButton:
	var then: Variant = _hover_history[0][1] if _hover_history.size() else null
	for sample in _hover_history:
		if sample[0] <= t:
			then = sample[1]
	if is_instance_valid(then) and then is PokeButton:
		return then
	return _hover if is_instance_valid(_hover) else null


## What a ray hit is, for context menus and point-to-talk: type is "floor" |
## "wall" | "widget" | "seat" | "object" | "agent" | "player" | "button" |
## "none", plus entity_id / peer / point (walls: surface, normal). A button on
## a widget also carries the widget's entity_id.
static func classify(hit: Dictionary) -> Dictionary:
	var c: Object = hit.get("collider")
	var t := {"type": "none", "point": hit.get("position", Vector3.ZERO)}
	if c is PokeButton:
		t["type"] = "button"
		t["button"] = c
		var n: Node = c.get_parent()
		while n and not n is NetBody:
			n = n.get_parent()
		if n:
			t["entity_id"] = n.entity_id
	elif c is Widget:
		t["type"] = "widget"
		t["entity_id"] = c.entity_id
	elif c is AgentBody:
		t["type"] = "agent"
		t["entity_id"] = c.entity_id
	elif c is NetBody:
		t["type"] = "seat" if c.kind == "chair" else "object"
		t["entity_id"] = c.entity_id
	elif c is Node and c.has_meta("peer"):
		t["type"] = "player"
		t["peer"] = c.get_meta("peer")
	elif c is Node and c.get_meta("surface", "") == "floor":
		t["type"] = "floor"
	elif c is Node and c.get_meta("surface", "") in Widgets.WALLS:
		t["type"] = "wall"
		t["surface"] = c.get_meta("surface")
		t["normal"] = hit.get("normal", Vector3.ZERO)
	return t


func _draw() -> void:
	var show := ray_visible and state != State.IDLE
	%Beam.visible = show
	%Dot.visible = show and state != State.DONE
	if not show:
		return
	var c: Color = COLORS["idle"]
	if _hover:
		c = COLORS["button"]
	elif state == State.LOCKED:
		c = COLORS["locked"].lerp(COLORS["ready"], progress)
	elif state == State.DONE:
		c = COLORS["ready"]
	(%Beam.material_override as StandardMaterial3D).albedo_color = c
	(%Dot.material_override as StandardMaterial3D).albedo_color = Color(c, 1.0)
	var length := ray_from.distance_to(ray_to)
	if length < 0.001:
		%Beam.visible = false
		return
	var dir := (ray_to - ray_from) / length
	# CylinderMesh runs along Y: point Y down the ray and stretch it.
	var basis := _basis_y_along(dir).scaled_local(Vector3(1.0, length, 1.0))
	%Beam.global_transform = Transform3D(basis, (ray_from + ray_to) * 0.5)
	# The dot grows slightly as the pull-back progresses.
	%Dot.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * (1.0 + progress)), ray_to)


static func _basis_y_along(dir: Vector3) -> Basis:
	var x := dir.cross(Vector3.FORWARD if absf(dir.z) < 0.9 else Vector3.RIGHT).normalized()
	return Basis(x, dir, x.cross(dir).normalized())
