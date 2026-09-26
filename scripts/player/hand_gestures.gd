class_name HandGestures extends RefCounted
## Per-hand gesture state, recomputed every frame from either OpenXR hand
## tracking (XRHandTracker joints) or a controller, so the pointer/context-menu
## logic doesn't care which one is in use.
##
## Hand tracking: finger "straightness" = straight-line distance from the
## proximal knuckle to the tip divided by the summed bone lengths (1.0 = fully
## straight, ~0.6 = curled). Pointing = index straight AND the middle, ring
## and pinky tucked into the palm (tips close to the palm joint), so a relaxed
## or half-open hand reaching for something never counts as pointing.
##
## The pointing ray is anchored to the rigid part of the hand: a frame built
## from the wrist and the index and little-finger knuckles. By default it runs
## from the wrist through the index knuckle. While the index finger is fully
## straight, the ray learns the finger's own direction (knuckle -> tip)
## relative to that frame, so it points where the finger points. What it
## learns takes effect AIM_REWIND later, and the moment the finger bends it
## stops learning and keeps the direction it was using (a curl starts at the
## base knuckle, before the finger stops looking straight, so the start of a
## curl never reaches the ray). It keeps that direction relative to the hand,
## so bending, retracting or pinching can't move it; only moving or turning
## the hand does. The ray is then smoothed with an
## adaptive (One-Euro-style) filter: heavy smoothing when the hand is nearly
## still, light when it moves fast, with the speed estimate itself smoothed so
## tracking noise doesn't read as motion.
## Where Meta's XR_FB_hand_tracking_aim is available (/user/fbhandaim/*), its
## index pinch is used for clicking.

const AIM_TRACKERS := [&"/user/fbhandaim/left", &"/user/fbhandaim/right"]
const FINGER_BASE := {"index": 6, "middle": 11, "ring": 16, "pinky": 21}
const POINT_INDEX_STRAIGHT := 0.9
const POINT_OTHERS_CURLED := 0.8
## Fingertip-to-palm distance (m) for a finger to count as tucked in:
## [to become tucked, to stay tucked] (hysteresis against flicker).
const TUCK_DIST := [0.07, 0.085]
## Adaptive smoothing: filter rate (1/s) at rest and when moving fast.
const SMOOTH_MIN_RATE := 3.5
## Index straightness at which the finger counts as fully straight (the ray
## learns its direction): [to start, to keep] (hysteresis).
const AIM_STRAIGHT := [0.985, 0.975]
## On bending, the learned direction goes back this far (s).
const AIM_REWIND := 0.2
## How quickly (1/s) the learned finger direction follows the finger.
const AIM_LEARN_RATE := 6.0
const SMOOTH_MAX_RATE := 40.0
## Speeds below the noise floor count as "still"; at FAST they get SMOOTH_MAX_RATE.
const ANGULAR_NOISE := 0.6 # rad/s
const FAST_ANGULAR_SPEED := 3.0 # rad/s
const LINEAR_NOISE := 0.15 # m/s
const FAST_LINEAR_SPEED := 1.2 # m/s
## How quickly the speed estimate itself follows (1/s).
const SPEED_RATE := 12.0

var hand_index := 0
## "hand" | "controller" | "none"
var source := "none"
var pointing := false
## Middle, ring and pinky are folded into the palm (required for pointing).
var others_tucked := false
## 0 = open/pointing hand, 1 = tight fist (or grip fully squeezed).
var clench := 0.0
var pinch := false
var pinch_started := false
## Controller trigger held (hands: always false).
var trigger := false
var trigger_started := false
var ray_origin := Vector3.ZERO
var ray_dir := Vector3.FORWARD
## Tests only: use this frame time (s) instead of the real clock.
var fixed_dt := 0.0

var _was_pinch := false
var _was_trigger := false
var _speed_est := 0.0
# Filter state (world space).
## The finger's direction in the hand frame (see _hand_frame); -Z = the
## wrist -> index knuckle line, used until the finger has been straight.
var _aim_local := Vector3.FORWARD
var _finger_straight := false
## Recent [time, _aim_local] while learning (the ray uses them AIM_REWIND late).
var _aim_history: Array = []
## The direction in use when learning (re)started: used until the finger has
## been straight for AIM_REWIND (so a brief flicker to "straight" changes nothing).
var _aim_held := Vector3.FORWARD
var _clock := 0.0
var _smooth_dir := Vector3.ZERO
var _smooth_origin := Vector3.ZERO
var _last_update_us := 0


func _init(index: int) -> void:
	hand_index = index


## Update from optical hand tracking. `origin` = XROrigin3D global transform.
func update_from_hand(tracker: XRHandTracker, origin: Transform3D) -> void:
	if source != "hand":
		_reset_aim() # (re)acquired the hand: don't smooth from a stale ray
	source = "hand"
	var s := {}
	for finger in FINGER_BASE:
		s[finger] = _straightness(tracker, FINGER_BASE[finger])
	var others: float = maxf(s["middle"], maxf(s["ring"], s["pinky"]))
	others_tucked = others < POINT_OTHERS_CURLED and _others_tucked(tracker, others_tucked)
	pointing = s["index"] > POINT_INDEX_STRAIGHT and others_tucked
	# Clench: how far the index has curled from straight, only with the others
	# tucked, so closing an open hand around an object isn't a "clench".
	clench = clampf(inverse_lerp(0.95, 0.62, s["index"]), 0.0, 1.0) if others_tucked else 0.0
	var thumb_tip := _joint(tracker, origin, XRHandTracker.HAND_JOINT_THUMB_TIP).origin
	var index_tip := _joint(tracker, origin, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
	var wrist := _joint(tracker, origin, XRHandTracker.HAND_JOINT_WRIST).origin
	var knuckle := _joint(tracker, origin, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL).origin
	var little_knuckle := _joint(tracker, origin, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL).origin
	_update_aim(wrist, knuckle, little_knuckle, index_tip, s["index"])
	var aim := XRServer.get_tracker(AIM_TRACKERS[hand_index]) as XRPositionalTracker
	if aim and aim.get_pose(&"default") and aim.get_pose(&"default").has_tracking_data:
		_set_pinch(aim.get_input(&"index_pinch") == true)
	else:
		_set_pinch(thumb_tip.distance_to(index_tip) < (0.04 if pinch else 0.022))
	_set_trigger(false)


## The learned direction from AIM_REWIND ago (what the ray uses while learning).
func _aim_used() -> Vector3:
	var used := _aim_held
	for sample in _aim_history:
		if sample[0] <= _clock - AIM_REWIND:
			used = sample[1]
	return used


## A frame fixed to the rigid part of the hand: -Z from the wrist to the index
## knuckle, X across the knuckles. All zeros if the joints are implausible.
static func _hand_frame(wrist: Vector3, knuckle: Vector3, little_knuckle: Vector3) -> Basis:
	var along := knuckle - wrist
	var across := knuckle - little_knuckle
	if along.length() < 0.02 or across.length() < 0.01:
		return Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var z := -along.normalized()
	var x := (across - z * across.dot(z))
	if x.length() < 0.005:
		return Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	x = x.normalized()
	return Basis(x, z.cross(x), z)


## The hand-anchored ray (learning the finger's direction while it's fully
## straight), adaptively smoothed.
func _update_aim(wrist: Vector3, knuckle: Vector3, little_knuckle: Vector3, index_tip: Vector3, index_straightness: float) -> void:
	var now := Time.get_ticks_usec()
	var dt := clampf((now - _last_update_us) / 1000000.0, 0.001, 0.1) if _last_update_us else 1.0 / 90.0
	if fixed_dt > 0.0:
		dt = fixed_dt
	_last_update_us = now
	var frame := _hand_frame(wrist, knuckle, little_knuckle)
	if is_zero_approx(frame.determinant()):
		return # implausible joints this frame: keep the last ray
	_clock += dt
	var was_straight := _finger_straight
	_finger_straight = index_straightness >= AIM_STRAIGHT[1 if _finger_straight else 0]
	var finger := index_tip - knuckle
	if _finger_straight and finger.length() > 0.02:
		if _aim_history.is_empty():
			_aim_held = _aim_local
		var local := (frame.inverse() * finger.normalized()).normalized()
		_aim_local = _aim_local.slerp(local, 1.0 - exp(-AIM_LEARN_RATE * dt)).normalized()
		_aim_history.append([_clock, _aim_local])
		while _aim_history.size() >= 2 and _aim_history[1][0] <= _clock - AIM_REWIND:
			_aim_history.pop_front() # keep one sample at least AIM_REWIND old
	elif was_straight and _aim_history.size():
		# Started bending: keep what the ray was using (not what the curl taught it).
		_aim_local = _aim_used()
		_aim_history.clear()
	var raw_dir := (frame * (_aim_used() if _finger_straight else _aim_local)).normalized()
	var raw_origin := knuckle + raw_dir * 0.09 # draw from about the fingertip
	if _smooth_dir == Vector3.ZERO:
		_smooth_dir = raw_dir
		_smooth_origin = raw_origin
	# Adaptive smoothing: faster motion -> higher cutoff (less lag), stillness ->
	# more smoothing. The speed estimate is low-passed and has a noise floor,
	# so tracking jitter isn't mistaken for movement.
	var ang_speed := inverse_lerp(ANGULAR_NOISE, FAST_ANGULAR_SPEED, _smooth_dir.angle_to(raw_dir) / dt)
	var lin_speed := inverse_lerp(LINEAR_NOISE, FAST_LINEAR_SPEED, _smooth_origin.distance_to(raw_origin) / dt)
	_speed_est = lerpf(_speed_est, clampf(maxf(ang_speed, lin_speed), 0.0, 1.0), 1.0 - exp(-SPEED_RATE * dt))
	var rate := lerpf(SMOOTH_MIN_RATE, SMOOTH_MAX_RATE, _speed_est)
	var k := 1.0 - exp(-rate * dt)
	_smooth_dir = _smooth_dir.slerp(raw_dir, k).normalized()
	_smooth_origin = _smooth_origin.lerp(raw_origin, k)
	ray_dir = _smooth_dir
	ray_origin = _smooth_origin


## Update from a controller: pointing = finger off the trigger and grip open;
## clench = grip squeeze; the ray comes from the controller's aim pose.
func update_from_controller(ctrl: XRController3D, aim: XRController3D) -> void:
	source = "controller"
	var grip := ctrl.get_float(&"grip")
	var touching_trigger := ctrl.is_button_pressed(&"trigger_touch")
	pointing = not touching_trigger and grip < 0.2
	clench = clampf(grip, 0.0, 1.0)
	ray_origin = aim.global_position
	ray_dir = -aim.global_basis.z.normalized()
	_set_pinch(false)
	_set_trigger(ctrl.get_float(&"trigger") > 0.6)


func clear() -> void:
	_reset_aim()
	source = "none"
	pointing = false
	others_tucked = false
	clench = 0.0
	_set_pinch(false)
	_set_trigger(false)


func _set_pinch(on: bool) -> void:
	pinch_started = on and not _was_pinch
	pinch = on
	_was_pinch = on


func _set_trigger(on: bool) -> void:
	trigger_started = on and not _was_trigger
	trigger = on
	_was_trigger = on


func _reset_aim() -> void:
	_smooth_dir = Vector3.ZERO
	_speed_est = 0.0
	_last_update_us = 0
	_aim_local = Vector3.FORWARD
	_aim_held = Vector3.FORWARD
	_finger_straight = false
	_aim_history.clear()


static func _joint(tracker: XRHandTracker, origin: Transform3D, joint: int) -> Transform3D:
	return origin * tracker.get_hand_joint_transform(joint)


## Are the middle, ring and pinky tips folded against the palm?
static func _others_tucked(tracker: XRHandTracker, was_tucked: bool) -> bool:
	var palm := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM).origin
	var limit: float = TUCK_DIST[1] if was_tucked else TUCK_DIST[0]
	for tip in [XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP, XRHandTracker.HAND_JOINT_RING_FINGER_TIP, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]:
		if tracker.get_hand_joint_transform(tip).origin.distance_to(palm) > limit:
			return false
	return true


## 1.0 = straight finger, lower = more curled. `base` is the metacarpal joint.
static func _straightness(tracker: XRHandTracker, base: int) -> float:
	var p: Array[Vector3] = []
	for j in range(base + 1, base + 5): # proximal, intermediate, distal, tip
		p.append(tracker.get_hand_joint_transform(j).origin)
	var bones := p[0].distance_to(p[1]) + p[1].distance_to(p[2]) + p[2].distance_to(p[3])
	return p[0].distance_to(p[3]) / bones if bones > 0.001 else 1.0
