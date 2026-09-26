class_name GrabHandle extends Area3D
## Something a hand can take hold of without picking up a whole object: a
## drawer's handle, a file card in a drawer's browser, a floating menu or the
## keyboard. Close your hand (grip / fist) on it: drag_started, then
## drag_ended when you let go. While held, `hand` is the Hand holding it.
## With `drag_target` set, that node follows the hand while held (menus and
## the keyboard are moved this way).

signal drag_started(hand: Hand)
signal drag_ended(hand: Hand)

const LAYER := 128

var hand: Hand
## Only a real fist takes hold (not a pinch), so pinch-clicking a menu's
## buttons never drags it. (Controllers: the grip button.)
var fist_only := false
## Moved along with the hand while held.
var drag_target: Node3D
## Keep drag_target turned toward your eyes while it's moved.
var face_viewer := false

var _offset := Vector3.ZERO


func _init() -> void:
	collision_layer = LAYER
	collision_mask = 0
	monitoring = false
	monitorable = true


## A box-shaped handle of `size` at `pos` under `parent`.
static func make(parent: Node, size: Vector3, pos := Vector3.ZERO) -> GrabHandle:
	var h := GrabHandle.new()
	h.position = pos
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	h.add_child(cs)
	parent.add_child(h)
	return h


## A handle covering `size` of `target`, which then follows the hand that
## grabs it (fist only).
static func make_drag(target: Node3D, size: Vector3, pos := Vector3.ZERO, keep_facing := false) -> GrabHandle:
	var h := make(target, size, pos)
	h.drag_target = target
	h.fist_only = true
	h.face_viewer = keep_facing
	return h


func begin(by: Hand) -> void:
	hand = by
	if drag_target:
		_offset = drag_target.global_position - by.global_position
	drag_started.emit(by)


func end() -> void:
	var by := hand
	hand = null
	if is_instance_valid(by):
		drag_ended.emit(by)


func _process(_delta: float) -> void:
	if not drag_target or not is_instance_valid(hand):
		return
	drag_target.global_position = hand.global_position + _offset
	if face_viewer:
		var cam := get_viewport().get_camera_3d()
		var away := drag_target.global_position - cam.global_position if cam else Vector3.ZERO
		if away.length() > 0.05:
			var scale_now := drag_target.global_basis.get_scale()
			drag_target.global_basis = Basis.looking_at(away.normalized(), Vector3.UP).scaled(scale_now)
