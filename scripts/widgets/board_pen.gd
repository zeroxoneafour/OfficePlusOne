class_name BoardPen extends RefCounted
## One way the local player draws on whiteboard widgets (a fingertip, a
## pointer ray, the desktop mouse). Each frame call draw() with the board and
## the world point it's drawing at, or lift() when it isn't. The stroke shows
## on your copy of the board immediately and goes to the server in small
## batches (which shares it with everyone). Uses your current brush
## (WhiteboardWidget.brush).

const FLUSH := 0.05

var _board: WhiteboardWidget
var _pending: Array = []
var _last := Vector2(-1, -1)
var _flush_left := FLUSH
var _ink := ""
var _width := 0


func draw(board: WhiteboardWidget, world: Vector3, delta: float) -> void:
	var hit := board.touch(world, INF)
	if hit.is_empty():
		lift()
		return
	var ink := WhiteboardWidget.brush_ink()
	var width := WhiteboardWidget.brush_width()
	if board != _board or ink != _ink or width != _width:
		lift()
		_board = board
		_ink = ink
		_width = width
	var px: Vector2 = hit["px"]
	if _last.x < 0 or px.distance_to(_last) >= 1.5:
		var seg := [int(px.x), int(px.y)] if _last.x < 0 else [int(_last.x), int(_last.y), int(px.x), int(px.y)]
		board.draw_local(_ink, _width, seg)
		if _pending.is_empty() and _last.x >= 0:
			_pending.append_array([int(_last.x), int(_last.y)]) # joins on to the previous batch
		_pending.append_array([int(px.x), int(px.y)])
		_last = px
	_flush_left -= delta
	if _flush_left <= 0.0:
		_flush()


## The pen left the board: send what's left of the stroke.
func lift() -> void:
	if _last.x >= 0 or not _pending.is_empty():
		_flush()
	_last = Vector2(-1, -1)
	_board = null


func is_drawing() -> bool:
	return _board != null


func _flush() -> void:
	_flush_left = FLUSH
	if _pending.size() >= 2 and is_instance_valid(_board):
		Widgets.request_op(_board.entity_id, "stroke", {"c": _ink, "w": _width, "p": _pending})
	_pending = []
