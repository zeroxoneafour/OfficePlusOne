class_name PokeButton extends Area3D
## A physical push button (scenes/world/poke_button.tscn). Pressed by an index
## fingertip (the small "poker" area at each index tip) pushing straight down
## onto its face, or by a ray/desktop click calling press(). A finger that
## slides in from the side (having just been beside the button, e.g. from the
## neighbouring key) doesn't press it.
##
## A finger press latches: it fires once, and the button re-arms only after the
## finger has been out of it for RELEASE_TIME. So resting on a button (or
## jittering at its edge) doesn't toggle it again and again, and a button that
## appears under a finger (a new menu, the watch showing) waits for the finger
## to leave before it can be pressed.

signal pressed

const LAYER_BUTTONS := 8
const LAYER_POKERS := 16
# Loaded lazily: a script preloading its own scene would be a cyclic load.
const SCENE_PATH := "res://scenes/world/poke_button.tscn"

@export var text := ""
@export var color := Color("#3d85c6")
@export var size := Vector2(0.14, 0.14)
## Greyed out buttons still exist (so the layout is stable) but say why they don't work.
@export var enabled := true
## Label font size (0 = the scene's default); small buttons need smaller text.
@export var label_size := 0

## Fingertips that must not press this (e.g. the hand a palm button is on).
var ignore_pokers: Array[Area3D] = []
## Text shown (as a toast) instead of acting when a disabled button is pressed.
var disabled_reason := ""
const RELEASE_TIME := 0.2
## Ray/desktop clicks closer together than this count once.
const COOLDOWN := 0.25
## Local z (the face is +Z) a finger must be in front of when it arrives.
const FRONT_Z := 0.0
## How far outside the face (m) the finger may have been just before, and
## still count as coming down onto it.
const FACE_MARGIN := 0.006
## Shallow, keyboard-like geometry (m): a thin base, a low cap whose face is at
## CAP_FACE, and a press volume that starts right at that face (so a key
## fires when your fingertip actually reaches it, not centimetres before).
const BASE_DEPTH := 0.006
const CAP_DEPTH := 0.008
const CAP_FACE := 0.01
const PRESS_FRONT := 0.012
const PRESS_BACK := -0.01
const PRESS_TRAVEL := 0.005

var _cooldown := 0.0
## Fingers currently inside, and whether the button is latched (already pressed).
var _touching: Array[Area3D] = []
var _latched := true # new buttons wait until no finger is in them
var _clear_time := 0.0
@onready var _cap: MeshInstance3D = %Cap
@onready var _label: Label3D = %Label


static func make(parent: Node, label_text: String, pos: Vector3, c := Color("#3d85c6"), button_size := Vector2(0.14, 0.14)) -> PokeButton:
	var b: PokeButton = load(SCENE_PATH).instantiate()
	b.text = label_text
	b.color = c
	b.size = button_size
	b.position = pos
	parent.add_child(b)
	return b


func _ready() -> void:
	_apply_size()
	_refresh()
	area_entered.connect(_on_area_entered)
	area_exited.connect(func(a: Area3D): _touching.erase(a))


## Fit the collision shape and meshes to `size` (round buttons override this).
func _apply_size() -> void:
	(($Shape as CollisionShape3D).shape as BoxShape3D).size = Vector3(size.x, size.y, PRESS_FRONT - PRESS_BACK)
	$Shape.position.z = (PRESS_FRONT + PRESS_BACK) * 0.5
	var rim := minf(0.01, minf(size.x, size.y) * 0.25)
	(($Base as MeshInstance3D).mesh as BoxMesh).size = Vector3(size.x + rim, size.y + rim, BASE_DEPTH)
	$Base.position.z = -BASE_DEPTH * 0.5
	(_cap.mesh as BoxMesh).size = Vector3(size.x, size.y, CAP_DEPTH)
	_cap.position.z = CAP_FACE - CAP_DEPTH * 0.5
	_label.position.z = CAP_FACE + 0.0008
	_label.width = size.x / _label.pixel_size * 0.95


## Is a point (local x/y) over the button's face, within `margin`?
func _face_contains(p: Vector2, margin: float) -> bool:
	return absf(p.x) <= size.x * 0.5 + margin and absf(p.y) <= size.y * 0.5 + margin


func set_text(t: String) -> void:
	text = t
	_refresh()


func set_enabled(on: bool) -> void:
	enabled = on
	_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	_label.text = text
	if label_size > 0:
		_label.font_size = label_size
	(_cap.material_override as StandardMaterial3D).albedo_color = color if enabled else color.darkened(0.6)
	_label.modulate = Color.WHITE if enabled else Color(1, 1, 1, 0.5)


func _on_area_entered(area: Area3D) -> void:
	# Only index fingertips count (the hands' "poker" areas).
	if not area.is_in_group("poker") or area in ignore_pokers:
		return
	_touching.append(area)
	if _latched or not is_visible_in_tree():
		return # still held from the last press, or just appeared under the finger
	if to_local(area.global_position).z < FRONT_Z:
		return # came through from behind (e.g. a hand passing through a menu)
	if area.has_method("past_position"):
		var before := to_local(area.past_position())
		if before.z < FRONT_Z or not _face_contains(Vector2(before.x, before.y), FACE_MARGIN):
			return # slid in from the side (e.g. off the next key), not pressed down
	_latched = true
	press()
	if area.has_method("buzz"):
		area.buzz()


func press() -> void:
	if _cooldown > 0.0:
		return
	_cooldown = COOLDOWN
	var rest := _cap.position.z
	_cap.position.z = rest - PRESS_TRAVEL
	create_tween().tween_property(_cap, "position:z", rest, 0.2).set_delay(0.1)
	if not enabled:
		if disabled_reason != "":
			Net.toast.emit(disabled_reason)
		return
	pressed.emit()


func _process(delta: float) -> void:
	_cooldown -= delta
	if not monitoring:
		# Hidden/disabled (e.g. the watch face): re-arm only once shown and clear.
		_touching.clear()
		_latched = true
		_clear_time = 0.0
		return
	if _latched:
		for i in range(_touching.size() - 1, -1, -1):
			if not is_instance_valid(_touching[i]):
				_touching.remove_at(i)
		_clear_time = _clear_time + delta if _touching.is_empty() else 0.0
		if _clear_time >= RELEASE_TIME:
			_latched = false
			_clear_time = 0.0
