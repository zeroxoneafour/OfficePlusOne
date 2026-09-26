class_name Watch extends Node3D
## A wristwatch on your non-dominant wrist (scenes/player/watch.tscn; the left
## by default): the time, with
## two buttons below it: Me (personal options) and Room (server/room options).
## Their menus float above the watch. The watch shows only while you hold the
## back of your wrist toward your eyes, and hides (closing its menu) otherwise.
## Badges on the buttons mean a request is waiting.
##
## "Back of the hand" is computed from joint *positions* (the plane through the
## wrist, index knuckle and pinky knuckle), not from any joint's orientation,
## so it doesn't depend on the runtime's axis conventions.

signal watch_menu_open(menu: RadialMenu)

const PERSONAL_MENU := "res://scenes/ui/menus/personal_menu.tscn"
const ROOM_MENU := "res://scenes/ui/menus/room_menu.tscn"
## Hand tracking: shows while the back-of-hand normal is within SHOW_DEG of the
## direction to your eyes; once shown, stays until it's beyond HIDE_DEG.
const SHOW_DEG := 60.0
const HIDE_DEG := 70.0
## Controllers (no hand joints): the watch sits here relative to the controller.
const CONTROLLER_OFFSET := Vector3(0, 0.02, 0.075)
## Controllers: show while you look at your raised wrist (angle off your gaze, degrees).
const LOOK_SHOW_DEG := 22.0
const LOOK_HIDE_DEG := 35.0
const MENU_SCALE := 0.55
## Face height above the wrist joint (on the back of the wrist, clear of the band).
const FACE_LIFT := 0.036

var shown := false
var menu: RadialMenu
@onready var face: Node3D = %Face
var _badge_timer := 0.0


func _ready() -> void:
	_set_buttons_active(false)


## Call every frame. With left-hand joint data (`tracker` has tracking data),
## the watch sits on the back of the wrist and shows when that faces your eyes.
## Without it (controllers), it rides on `hand` and shows while you look at it.
## `origin`: the XROrigin3D's global transform (joint poses are relative to it).
## `left_hand`: which wrist it's on (the back-of-hand normal flips for the right).
func track(hand: Node3D, cam: Camera3D, tracker: XRHandTracker = null, origin := Transform3D.IDENTITY, left_hand := true) -> void:
	var back: Vector3
	var want: bool
	if tracker and tracker.has_tracking_data:
		var wrist := origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).origin
		var index_knuckle := origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL).origin
		var pinky_knuckle := origin * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL).origin
		back = back_of_left_hand(wrist, index_knuckle, pinky_knuckle) * (1.0 if left_hand else -1.0)
		var along := (index_knuckle + pinky_knuckle) * 0.5 - wrist # wrist -> knuckles
		# Centred on the wrist joint (inside the wrist): the band wraps round it,
		# the face sits on the back of the wrist (FACE_LIFT).
		global_transform = Transform3D(_basis_from(back, along), wrist)
		want = should_show_back_of_hand(back, (cam.global_position - global_position).normalized(), shown)
	else:
		var basis := hand.global_basis.orthonormalized()
		global_transform = Transform3D(basis, hand.global_transform * CONTROLLER_OFFSET)
		back = basis.y
		want = should_show_looked_at(-cam.global_basis.z, (global_position - cam.global_position).normalized(), shown)
	var to_eye := (cam.global_position - global_position).normalized()
	set_shown(want)
	if shown:
		# The face turns toward your eyes (readable at any wrist angle), sitting
		# on top of the band on the back of the wrist.
		face.global_position = global_position + back * FACE_LIFT
		face.global_basis = Basis.looking_at(-to_eye, Vector3.UP)


## Normal out of the back of a LEFT hand, from joint positions. With the palm
## down and fingers forward, the index knuckle is to the right and the pinky
## to the left, so (index - wrist) x (pinky - wrist) points up, out of the back.
static func back_of_left_hand(wrist: Vector3, index_knuckle: Vector3, pinky_knuckle: Vector3) -> Vector3:
	return (index_knuckle - wrist).cross(pinky_knuckle - wrist).normalized()


## Like a real watch: shows when the back of the wrist (not the palm) faces
## you, within SHOW_DEG (and stays shown until beyond HIDE_DEG).
static func should_show_back_of_hand(back_of_hand: Vector3, to_eye: Vector3, currently_shown: bool) -> bool:
	return rad_to_deg(back_of_hand.angle_to(to_eye)) < (HIDE_DEG if currently_shown else SHOW_DEG)


static func _basis_from(up: Vector3, forward: Vector3) -> Basis:
	var x := forward.cross(up).normalized()
	if x.length() < 0.001:
		x = up.cross(Vector3.FORWARD).normalized()
	return Basis(x, up, x.cross(up)).orthonormalized()


static func should_show_looked_at(gaze: Vector3, to_watch: Vector3, currently_shown: bool) -> bool:
	return rad_to_deg(gaze.angle_to(to_watch)) < (LOOK_HIDE_DEG if currently_shown else LOOK_SHOW_DEG)


func set_shown(on: bool) -> void:
	if on == shown:
		return
	shown = on
	visible = on
	_set_buttons_active(on)

func _set_buttons_active(on: bool) -> void:
	for b: PokeButton in [%MeButton, %RoomButton]:
		b.monitoring = on
		b.collision_layer = PokeButton.LAYER_BUTTONS if on else 0


## Open a watch menu (replacing any open one), floating above the face.
func open_menu(path: String, player: Node3D) -> RadialMenu:
	close_menu()
	menu = load(path).instantiate()
	menu.setup({}, player)
	menu.draggable = false # it rides on the watch
	%MenuAnchor.add_child(menu)
	menu.scale = Vector3.ONE * MENU_SCALE
	return menu


func close_menu() -> void:
	if is_instance_valid(menu):
		menu.close()
	menu = null


func _process(delta: float) -> void:
	if not shown:
		return
	%Time.text = Time.get_time_string_from_system().substr(0, 5)
	_badge_timer -= delta
	if _badge_timer <= 0.0:
		_badge_timer = 0.5
		%MeBadge.visible = not Net.prompts_of("summon").is_empty()
		%RoomBadge.visible = not Net.prompts_of("knock").is_empty()
