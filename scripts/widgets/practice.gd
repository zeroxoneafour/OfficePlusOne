class_name PracticeWidget extends Widget
## The tutorial's practice board (scenes/widgets/practice.tscn): six targets
## from big to tiny to hit with the pointer ray (point, then pinch;
## controller: trigger) or a fingertip; each turns green when hit. Reset
## starts over, and "Try the keyboard" opens the keyboard and shows what you
## typed. Just for you: nothing here is shared.

const TARGETS := [0.16, 0.12, 0.09, 0.07, 0.05, 0.035]
const OFF := Color("#3d85c6")
const HIT := Color("#4caf50")

var _targets: Array[PokeButton] = []
var _hits := 0


func _widget_build() -> void:
	for i in TARGETS.size():
		var s: float = TARGETS[i]
		var pos := Vector3(-0.3 + (i % 3) * 0.3, 0.13 - (i / 3) * 0.24, 0.0)
		var b := PokeButton.make(self, str(i + 1), pos, OFF, Vector2(s, s))
		b.label_size = int(clampf(s * 400.0, 22.0, 48.0))
		b.pressed.connect(_on_hit.bind(b))
		_targets.append(b)
	%Reset.pressed.connect(_reset)
	%TryKeyboard.pressed.connect(_try_keyboard)
	_reset()


func _try_keyboard() -> void:
	var player := get_tree().get_first_node_in_group("local_player")
	if player:
		player.open_keyboard("Type anything, then Done", "", _show_typed)


func _show_typed(t: String) -> void:
	%Typed.text = "You typed: %s" % t if t != "" else ""


func _on_hit(b: PokeButton) -> void:
	if b.color == HIT:
		return
	b.color = HIT
	b.set_text("Hit!")
	_hits += 1
	_show_score()


func _reset() -> void:
	_hits = 0
	for i in _targets.size():
		_targets[i].color = OFF
		_targets[i].set_text(str(i + 1))
	_show_score()


func _show_score() -> void:
	%Score.text = "All six! Try the smallest again from further away." if _hits == TARGETS.size() else "Targets hit: %d / %d" % [_hits, TARGETS.size()]


func hits() -> int:
	return _hits


func ai_summary() -> String:
	return "a practice board for people learning to point and click (nothing for you to do)"
