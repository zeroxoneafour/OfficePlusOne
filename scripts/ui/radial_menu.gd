class_name RadialMenu extends Node3D
## A floating, circular context menu (scenes/ui/radial_menu.tscn): a pie menu.
## Each item is a slice of the disc reaching from the round Cancel button in
## the middle out to the rim; items may open submenus (with a Back slice). It stays until cancelled or replaced by another menu, and
## keeps turning to face you. Subclasses (scenes/ui/menus/*) build the items
## for what was pointed at.
##
## An item is a Dictionary:
##   label: String, color: Color (optional),
##   do: Callable            - run when pressed, or
##   sub: Callable -> Array  - items of a submenu,
##   enabled: bool (default true), why: String (toast when disabled)

signal closed

## Slices span from just outside the Cancel button to just inside the rim.
const INNER := 0.058
const OUTER := 0.228
const ACTION := Color("#3d85c6")
const DANGER := Color("#c0504d")
const SUBMENU := Color("#7b68ee")
const NEUTRAL := Color("#555a66")
const ARM_DELAY_MS := 250
const SUB_ARM_DELAY_MS := 150

## What the menu is about (from Pointer.classify): type, entity_id/peer, point…
var target := {}
## The local player (for things like teleporting).
var player: Node3D
var _stack: Array = []
var _current: Array = []
## Presses right after the menu (or a submenu) appears are ignored, so the
## gesture that opened it can't press something by accident. Kept short: the
## menu opens ahead of the hand, and buttons appearing under a fingertip
## already wait for it to leave (PokeButton).
var _armed_at := 0
## Make a fist on the menu to move it (not for menus fixed to something, e.g. the watch's).
var draggable := true


func setup(for_target: Dictionary, local_player: Node3D) -> void:
	target = for_target
	player = local_player


func _ready() -> void:
	%Cancel.pressed.connect(func():
		if _armed():
			close())
	%Title.text = _title()
	show_items(_root_items())
	if draggable:
		GrabHandle.make_drag(self, Vector3(0.5, 0.62, 0.12), Vector3(0, 0, 0.02))


## Override: the top-level items.
func _root_items() -> Array:
	return []


## Override: the heading above the ring.
func _title() -> String:
	return ""


## `rearm`: ignore presses briefly (false for in-place refreshes, e.g. toggles).
func show_items(items: Array, rearm := true) -> void:
	_current = items
	for c in %Buttons.get_children():
		c.queue_free()
	var n := items.size()
	for i in n:
		var item: Dictionary = items[i]
		# Start at the top and go clockwise; each item gets an equal slice.
		var a := PI * 0.5 - TAU * i / maxf(n, 1)
		var half := PI / maxf(n, 1)
		var c: Color = item.get("color", SUBMENU if item.has("sub") else ACTION)
		var b := RadialButton.make_slice(%Buttons, str(item.get("label", "")), a - half, a + half, INNER, OUTER, c)
		b.set_enabled(item.get("enabled", true))
		b.disabled_reason = str(item.get("why", ""))
		b.pressed.connect(_activate.bind(item))
	%Hint.text = "poke, pinch or click" if _stack.is_empty() else "Back returns to the previous menu"
	if rearm:
		_armed_at = Time.get_ticks_msec() + (ARM_DELAY_MS if _stack.is_empty() else SUB_ARM_DELAY_MS)


## Rebuild the current level in place (after a toggle changed its labels).
func refresh(items: Array) -> void:
	show_items(items, false)


func _armed() -> bool:
	return Time.get_ticks_msec() >= _armed_at


func _activate(item: Dictionary) -> void:
	if not _armed():
		return
	if item.has("sub"):
		var sub: Array = item["sub"].call()
		_stack.append(_current)
		show_items([{"label": "Back", "color": NEUTRAL, "do": back}] + sub)
	elif item.has("do"):
		item["do"].call()


## Back to a freshly built top level (e.g. after answering a request).
func home() -> void:
	_stack.clear()
	show_items(_root_items(), false)


func back() -> void:
	if _stack.size():
		show_items(_stack.pop_back(), false)
		_armed_at = Time.get_ticks_msec() + SUB_ARM_DELAY_MS


func close() -> void:
	if is_queued_for_deletion():
		return
	closed.emit()
	queue_free()


## "Grab": the object teleports into the hand that opened the menu and stays
## there until that hand closes and opens again.
func grab_item(e: NetBody) -> Dictionary:
	var id := e.entity_id
	return {"label": "Grab", "color": Color("#4caf50"), "enabled": not e.is_locked() and not e.is_occupied(),
			"why": "It's locked in place (unlock it first)." if e.is_locked() else "Someone is sitting there.",
			"do": func():
				player.fetch_to_hand(id, int(target.get("hand", 1)))
				close()}


## "Rotate": turn the object about the vertical (upright to the floor) in
## steps of 15° or 90°. Stays open to keep turning.
func rotate_item(e: NetBody) -> Dictionary:
	var id := e.entity_id
	var perm := "lock" if e.is_locked() else "interact"
	return {"label": "Rotate", "enabled": Net.my_can(perm), "why": "Only admins can turn locked furniture here.", "sub": func():
		var items := []
		for step in [-90, -15, 15, 90]:
			var deg: int = step
			items.append({"label": ("%+d°" % deg), "do": func(): Office.request_action("rotate", {"entity": id, "degrees": deg})})
		return items}


## A confirmation submenu for destructive actions.
func confirm(label: String, action: Callable) -> Array:
	return [{"label": label, "color": DANGER, "do": func():
		action.call()
		close()}]


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam:
		var away := global_position - cam.global_position
		away.y *= 0.5 # tilt a little toward the viewer, mostly stay upright
		if away.length() > 0.01:
			var scale_now := global_basis.get_scale()
			global_basis = Basis.looking_at(away.normalized(), Vector3.UP).scaled(scale_now)
