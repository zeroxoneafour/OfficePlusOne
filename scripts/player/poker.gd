extends Area3D
## Fingertip collider that presses PokeButtons: a small sphere right at the
## index fingertip, so only the tip presses (not the finger pad or knuckles).
## It remembers where it has just been, so buttons can tell a press straight
## down onto their face from a finger sliding in from the side.

## How far back past_position() looks (s).
const LOOKBACK := 0.035

var hand: Node
## [[time, global position], …] over the last ~0.1 s.
var _history: Array = []


func buzz() -> void:
	if hand and hand.has_method("haptic"):
		hand.haptic(0.6)


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_history.append([now, global_position])
	while _history.size() > 2 and now - _history[0][0] > 0.1:
		_history.pop_front()


## Where the fingertip was LOOKBACK seconds ago (or the oldest we know).
func past_position() -> Vector3:
	var t := Time.get_ticks_msec() / 1000.0 - LOOKBACK
	var best: Vector3 = _history[0][1] if _history.size() else global_position
	for sample in _history:
		if sample[0] <= t:
			best = sample[1]
	return best
