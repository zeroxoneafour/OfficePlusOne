class_name Hand extends Node3D
## One hand (scenes/player/hand.tscn). Grabs replicated NetBodies (grip),
## uses held items or interacts with what it touches (trigger: flip pages,
## save a document, sit on a chair, switch a lamp), and pokes buttons with a
## fingertip. Driven by a tracked controller, OpenXR hand tracking (pinch/fist
## gestures, fingertip at the real index finger), or the desktop crosshair.

signal grabbed(body: NetBody)
signal released(body: NetBody)

const SCENE_PATH := "res://scenes/player/hand.tscn"
## Poker offset from the hand origin when using a controller.
const CONTROLLER_TIP := Vector3(0, -0.01, -0.07)
# Gesture thresholds (metres) with hysteresis: [engage, release].
const PINCH := [0.022, 0.04]
const FIST := [0.075, 0.095]
const INDEX_FIST := [0.09, 0.11]

var index := 0 # 0 = left, 1 = right
var controller: XRController3D # null in desktop mode
var held: NetBody
## Desktop mode: the body under the crosshair, grabbed if nothing is in reach.
var grab_hint: NetBody
## True while this hand is driven by optical hand tracking rather than a controller.
var hand_tracked := false
## Hand-tracking gestures this frame.
var pinching := false
var middle_pinching := false
var fisting := false

var _history: Array = [] # [time, position, basis] samples for throw velocity
var _was_grip := false
## The handle (drawer handle, file card…) this hand is holding, if any.
var _handle: GrabHandle
## Holding something fetched from its context menu: it stays in the hand
## (open or not) until the hand closes and opens again.
var _sticky := false
var _sticky_closed := false
## The arm inventory this hand stows into and takes from (set on the pointing
## hand; the inventory is on the other arm). Null for the inventory's own hand.
var inventory: ArmInventory
var _was_trigger := false
var _joints: Array[MeshInstance3D] = []
## --show-grab-points: axes at this hand's hold frame.
var _hold_gizmo: Node3D
@onready var _grab_area: Area3D = %GrabArea


static func make(hand_index: int) -> Hand:
	var h: Hand = load(SCENE_PATH).instantiate()
	h.index = hand_index
	return h


func _ready() -> void:
	%Poker.hand = self
	if Config.has_arg("show-grab-points"):
		_hold_gizmo = Mk.axes(self, 0.06)
	_grab_area.collision_mask = NetBody.LAYER_PROPS | NetBody.LAYER_FLOATING | GrabHandle.LAYER
	if index == 0:
		%Mesh.material_override = Mk.mat(Color("#e0b890"))


# --- Pose sources -------------------------------------------------------------------

func follow_controller(xf: Transform3D) -> void:
	global_transform = xf
	if hand_tracked:
		hand_tracked = false
		%Mesh.visible = true
		%Poker.position = CONTROLLER_TIP
		for j in _joints:
			j.visible = false


## Drive this hand from an XRHandTracker. `origin` is the XROrigin3D's global
## transform (joint poses are in tracking space). Returns [grip, trigger].
func follow_hand_tracker(tracker: XRHandTracker, origin: Transform3D) -> Array:
	if not hand_tracked:
		hand_tracked = true
		%Mesh.visible = false
	var palm := origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM)
	global_transform = palm
	var tip := origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	%Poker.global_position = tip.origin
	_update_joint_meshes(tracker, origin)
	var thumb := (origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP)).origin
	var middle := (origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP)).origin
	var ring := (origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_RING_FINGER_TIP)).origin
	var little := (origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP)).origin
	pinching = _hyst(pinching, thumb.distance_to(tip.origin), PINCH)
	middle_pinching = _hyst(middle_pinching, thumb.distance_to(middle), PINCH) and not pinching
	var curl := (middle.distance_to(palm.origin) + ring.distance_to(palm.origin) + little.distance_to(palm.origin)) / 3.0
	# A fist needs the index folded in too: a pointing hand (index out, others
	# tucked) must not grab.
	fisting = _hyst(fisting, curl, FIST) and _hyst(fisting, tip.origin.distance_to(palm.origin), INDEX_FIST)
	return [pinching or fisting, middle_pinching]


static func _hyst(on: bool, dist: float, thresholds: Array) -> bool:
	return dist < thresholds[1] if on else dist < thresholds[0]


func _update_joint_meshes(tracker: XRHandTracker, origin: Transform3D) -> void:
	if _joints.is_empty():
		var mat := Mk.mat(Color("#f0c8a0") if index == 1 else Color("#e0b890"))
		for j in XRHandTracker.HAND_JOINT_MAX:
			var mi := MeshInstance3D.new()
			var m := SphereMesh.new()
			m.radius = 0.5
			m.height = 1.0
			m.radial_segments = 8
			m.rings = 4
			mi.mesh = m
			mi.material_override = mat
			mi.top_level = true
			add_child(mi)
			_joints.append(mi)
	var flags_ok := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID
	for j in _joints.size():
		var valid := (tracker.get_hand_joint_flags(j) & flags_ok) != 0
		_joints[j].visible = valid
		if valid:
			var r := maxf(tracker.get_hand_joint_radius(j), 0.006)
			_joints[j].global_transform = Transform3D(Basis.from_scale(Vector3.ONE * r * 2.0), (origin * tracker.get_hand_joint_transform(j)).origin)


# --- Input ------------------------------------------------------------------------

## Called every frame by the player with the current button/gesture states.
func update_input(grip: bool, trigger: bool) -> void:
	if _hold_gizmo:
		_hold_gizmo.transform = hold_frame()
	var now := Time.get_ticks_msec() / 1000.0
	_history.append([now, global_position, global_basis])
	while _history.size() > 2 and now - _history[0][0] > 0.1:
		_history.pop_front()
	if held and not is_instance_valid(held):
		held = null
	if _handle and not is_instance_valid(_handle):
		_handle = null
	if held and _sticky:
		# Fetched: closing the hand takes hold "for real"; opening it again lets go.
		if grip and not _was_grip:
			_sticky_closed = true
		elif not grip and _was_grip and _sticky_closed:
			release()
	elif grip and not _was_grip:
		# Something stowed on your other arm, within reach, comes out first.
		var stowed := inventory.item_near(global_position) if inventory and not held else null
		# A handle in reach wins over picking the whole thing up.
		_handle = _nearest_handle() if not held and not stowed else null
		if stowed:
			fetch(stowed, false) # out of the slot, full size, held properly
		elif _handle:
			_handle.begin(self)
			haptic(0.3)
		else:
			try_grab()
	elif not grip and _was_grip:
		if _handle:
			_handle.end()
			_handle = null
		release()
	if trigger and not _was_trigger:
		if held:
			Sync.request_use(held.entity_id)
		else:
			var target := _nearest_body()
			if target:
				Sync.request_interact(target.entity_id)
				haptic(0.3)
	_was_grip = grip
	_was_trigger = trigger


## Returns true if something was grabbed.
func try_grab(target: NetBody = null) -> bool:
	if held:
		return true
	if target == null:
		target = _nearest_body()
	if target == null and is_instance_valid(grab_hint):
		target = grab_hint
	if target == null or not target.grabbable():
		return false
	if target.is_locked():
		Net.toast.emit("It's locked in place.")
		return false
	held = target
	if not Net.is_server():
		target.begin_local_hold(self)
	Sync.request_grab(target.entity_id, index, global_transform.affine_inverse() * target.global_transform)
	haptic(0.3)
	grabbed.emit(target)
	return true


## Where things put into this hand are held (the "hold frame"), relative to
## the hand node, for each way the hand is driven. An object's GrabPoint is
## placed exactly here: its +Y along the fingers, +Z facing out of the palm.
## Tune these by hand; see docs/GRAB_POINTS.md (and --show-grab-points).
## Tracked hand (the palm joint: -Z toward the fingers, +Y out of the back of
## the hand): just off the palm, on the palm side.
const HOLD_TRACKED := Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(0, -1, 0)), Vector3(0, -0.05, -0.02))
## Controller (the grip pose, whose origin is the middle of your fist): in the fist.
const HOLD_CONTROLLER := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3(0, 0, -0.02))
## Desktop (the hand follows the camera): right there, facing you.
const HOLD_DESKTOP := Transform3D.IDENTITY


func hold_frame() -> Transform3D:
	if not controller:
		return HOLD_DESKTOP
	return HOLD_TRACKED if hand_tracked else HOLD_CONTROLLER


## The object-relative-to-hand transform that holds `body` by its grab point.
func hold_offset_for(body: NetBody) -> Transform3D:
	return hold_frame() * body.grab_point().affine_inverse()


## Put `body` straight into this hand, held by its grab point (context menu →
## Grab, a file pulled from a drawer). `sticky`: it stays even with the hand
## open, until the hand closes and opens again (then it drops); otherwise it
## drops when the (already closed) hand opens.
func fetch(body: NetBody, sticky := true) -> void:
	if not is_instance_valid(body) or not body.grabbable():
		return
	if body.is_locked():
		Net.toast.emit("It's locked in place.")
		return
	release()
	held = body
	_sticky = sticky
	_sticky_closed = false
	var offset := hold_offset_for(body)
	if not Net.is_server():
		body.global_transform = global_transform * offset
		body.begin_local_hold(self)
	Sync.request_fetch(body.entity_id, index, offset)
	haptic(0.5)
	grabbed.emit(body)


func release() -> void:
	_sticky = false
	_sticky_closed = false
	if not held:
		return
	# Let go next to an empty slot on your other arm: it goes in there.
	if inventory and is_instance_valid(held) and inventory.free_slot_near(held, self) >= 0 and inventory.stow(self):
		return
	var body := held
	held = null
	if is_instance_valid(body):
		body.end_local_hold()
		Sync.request_release(body.entity_id, linear_velocity(), angular_velocity())
		released.emit(body)


## Stop holding without releasing on the server (it's being stowed instead).
func let_go_quietly() -> void:
	var body := held
	held = null
	_sticky = false
	_sticky_closed = false
	if is_instance_valid(body):
		released.emit(body)


func linear_velocity() -> Vector3:
	if _history.size() < 2:
		return Vector3.ZERO
	var a: Array = _history[0]
	var b: Array = _history[-1]
	var dt: float = b[0] - a[0]
	return (b[1] - a[1]) / dt if dt > 0.001 else Vector3.ZERO


func angular_velocity() -> Vector3:
	if _history.size() < 2:
		return Vector3.ZERO
	var a: Array = _history[0]
	var b: Array = _history[-1]
	var dt: float = b[0] - a[0]
	if dt <= 0.001:
		return Vector3.ZERO
	var q: Quaternion = ((b[2] as Basis) * (a[2] as Basis).inverse()).get_rotation_quaternion()
	var axis := q.get_axis()
	return axis * q.get_angle() / dt if axis.is_finite() else Vector3.ZERO


## Is anything within reach to grab? (A fist near an object grabs it rather
## than starting the pointer's context-menu gesture.)
func has_grab_candidate() -> bool:
	return _nearest_body() != null or _nearest_handle() != null or (inventory != null and inventory.item_near(global_position) != null)


## Something was spawned for this hand (a file pulled from a drawer): take
## hold of it if the hand is still closed, else leave it floating there.
func adopt(body: NetBody) -> void:
	if held or not _was_grip or not is_instance_valid(body):
		return
	if _handle:
		_handle.hand = null # let go of the file card without "releasing" it
		_handle = null
	fetch(body, false) # held the proper way round; drops when the hand opens


func _nearest_handle() -> GrabHandle:
	var best: GrabHandle
	var best_d := INF
	for a in _grab_area.get_overlapping_areas():
		if a is GrabHandle and a.is_visible_in_tree() and not (a.fist_only and hand_tracked and not fisting):
			var d := global_position.distance_to(a.global_position)
			if d < best_d:
				best_d = d
				best = a
	return best


func _nearest_body() -> NetBody:
	var best: NetBody
	var best_d := INF
	for b in _grab_area.get_overlapping_bodies():
		if b is NetBody:
			var d := global_position.distance_to(b.global_position)
			if d < best_d:
				best_d = d
				best = b
	return best


func haptic(strength := 0.5) -> void:
	if controller and not hand_tracked:
		controller.trigger_haptic_pulse("haptic", 0.0, strength, 0.08, 0.0)
