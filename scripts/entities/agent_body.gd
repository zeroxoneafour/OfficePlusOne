class_name AgentBody extends NetBody
## The physical body of an AI agent (scenes/entities/agent.tscn). It never
## walks on its own; people can carry it around or summon it. The AI "acts"
## through its body: head turns to whoever talks to it, hands gesture and hold
## items, the mouth moves with its voice and a status light shows
## idle/listening/thinking/speaking.

const STATUS_COLORS := {
	"idle": Color("#888888"), "listening": Color("#33cc55"), "thinking": Color("#ffcc33"),
	"speaking": Color("#3399ff"), "error": Color("#ff3333"),
}
## Local position where carried items are held (right hand, slightly out front).
const HOLD_POINT := Vector3(0.22, 1.1, -0.38)
## How far a seated agent's upper body drops.
const SIT_DROP := 0.45
const OFFER_POINT := Vector3(0.18, 1.2, -0.5)

@onready var voice: VoicePlayback = %Voice
@onready var _head: Node3D = %Head
@onready var _hands: Array[MeshInstance3D] = [%HandL, %HandR]
var _hand_rest: Array[Vector3] = []
var _bubble_time := 0.0
var _look_peer := 0
var _look_time := 0.0
var _gesture_tween: Tween
var _sit_offset := 0.0


func _build() -> void:
	upright = true
	voice.low_latency = false
	_hand_rest = [_hands[0].position, _hands[1].position]


func _data_changed(key: String, value: Variant) -> void:
	match key:
		"name":
			%NameLabel.text = str(value)
		"status":
			%StatusLight.material_override = Mk.mat(STATUS_COLORS.get(value, Color.GRAY), 2.0)
		"sitting_on":
			# Seated: root sits on the seat, upper body lowered, body shortened.
			_sit_offset = SIT_DROP if int(value) != 0 else 0.0
			%Body.position.y = 0.75 - _sit_offset * 0.6
			%Body.scale.y = 1.0 - _sit_offset * 0.9
			_head.position.y = 1.58 - _sit_offset
			%NameLabel.position.y = 2.0 - _sit_offset
			%StatusLight.position.y = 1.84 - _sit_offset
			%Bubble.position.y = 2.3 - _sit_offset
			_hand_rest = [Vector3(-0.3, 0.95 - _sit_offset, -0.05), Vector3(0.3, 0.95 - _sit_offset, -0.05)]
			if _hands.size():
				_hands[0].position = _hand_rest[0]
				_hands[1].position = _hand_rest[1]
		"color":
			var c := Mk.color(value, Color("#7b68ee"))
			for m in find_children("*", "MeshInstance3D"):
				if m.is_in_group("tint"):
					m.material_override = Mk.mat(c)
				elif m.is_in_group("tint_light"):
					m.material_override = Mk.mat(c.lightened(0.3))


func on_event(event_name: String, args: Dictionary) -> void:
	match event_name:
		"say":
			%Bubble.text = str(args.get("text", "")).substr(0, 400)
			_bubble_time = clampf(%Bubble.text.length() * 0.07, 4.0, 20.0)
		"look":
			_look_peer = int(args.get("peer", 0))
			_look_time = 30.0
		"gesture":
			gesture(str(args.get("kind", "")))


## World transform for the `slot`-th item this agent carries: in its right
## hand, content facing whoever stands in front of the agent.
func hold_xform(slot: int) -> Transform3D:
	var local := Transform3D(Basis(Vector3.UP, PI), HOLD_POINT + Vector3(-0.05 * slot, 0.02 * slot - _sit_offset, 0.015 * slot))
	return global_transform * local


func gesture(kind: String) -> void:
	if _gesture_tween:
		_gesture_tween.kill()
	var t := create_tween()
	_gesture_tween = t
	var r := _hands[1]
	var l := _hands[0]
	match kind:
		"wave":
			for i in 3:
				t.tween_property(r, "position", Vector3(0.4, 1.75, -0.05), 0.25)
				t.tween_property(r, "position", Vector3(0.25, 1.7, -0.05), 0.25)
		"point", "point_board":
			t.tween_property(r, "position", Vector3(0.3, 1.45, -0.6), 0.3)
			t.tween_interval(1.5)
		"offer":
			t.tween_property(r, "position", OFFER_POINT, 0.3)
			t.tween_interval(1.5)
		"think":
			t.tween_property(r, "position", Vector3(0.08, 1.45, -0.18), 0.3)
			t.tween_interval(2.0)
		"shrug":
			t.set_parallel(true)
			t.tween_property(r, "position", Vector3(0.45, 1.25, -0.15), 0.25)
			t.tween_property(l, "position", Vector3(-0.45, 1.25, -0.15), 0.25)
			t.chain().tween_interval(0.8)
		"nod":
			t.tween_property(_head, "rotation:x", -0.35, 0.18)
			t.tween_property(_head, "rotation:x", 0.1, 0.18)
			t.tween_property(_head, "rotation:x", -0.3, 0.18)
			t.tween_property(_head, "rotation:x", 0.0, 0.18)
		_:
			t.kill()
			return
	t.set_parallel(false)
	t.tween_property(r, "position", _hand_rest[1], 0.4)
	t.parallel().tween_property(l, "position", _hand_rest[0], 0.4)


func _process(delta: float) -> void:
	super(delta)
	if _bubble_time > 0.0:
		_bubble_time -= delta
		if _bubble_time <= 0.0:
			%Bubble.text = ""
	var talk := voice.level * 60.0
	%Mouth.scale.y = 1.0 + clampf(talk, 0.0, 5.0)
	_update_look(delta)


func _update_look(delta: float) -> void:
	_look_time -= delta
	var target_yaw := 0.0
	var target_pitch := 0.0
	var head: Variant = Sync.head_xform(_look_peer) if _look_time > 0.0 else null
	if head is Transform3D:
		var local := to_local((head as Transform3D).origin) - _head.position
		target_yaw = clampf(atan2(-local.x, -local.z), -1.3, 1.3)
		target_pitch = clampf(atan2(local.y, Vector2(local.x, local.z).length()), -0.6, 0.6)
	var w := 1.0 - exp(-6.0 * delta)
	_head.rotation.y = lerp_angle(_head.rotation.y, target_yaw, w)
	if not (_gesture_tween and _gesture_tween.is_running()):
		_head.rotation.x = lerp_angle(_head.rotation.x, target_pitch, w)
