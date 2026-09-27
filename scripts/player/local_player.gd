extends XROrigin3D
## The local human (scenes/player/local_player.tscn). In VR each hand is driven
## by OpenXR hand tracking when real hands are tracked, otherwise by the
## controller. Without a headset it falls back to mouse/keyboard driving the
## same Hand logic from the crosshair, so everything stays physical.
##
## Pointing (hands: point your index finger; controllers: lift your finger
##   off the trigger) casts a ray at the floor, a seat, an object, an AI or a
##   person. Start clenching and the ray freezes on it; pull your hand ~6 in
##   straight back along the ray into a fist and a radial context menu opens
##   around your hand (teleport, summon AI, lock/delete, mute/volume/kick…).
##   Pinch/trigger while the ray is on a button clicks it. Ray visibility is
##   in the watch's Me menu.
## Point-to-talk: point at an AI agent and speak; stop pointing and it's
##   transcribed and sent. (The room itself doesn't listen.) Your
##   mic is open for proximity chat whenever someone else is in the office,
##   and only while pointing at an AI when you're alone.
## Controllers: left stick move · right stick snap-turn · grip grab ·
##   trigger: use held item, or interact with what the hand touches (sit on a
##   chair, switch a lamp) · poke buttons · X mute mic
## Hand tracking: pinch or fist near something grabs it · thumb-to-middle
##   pinch = trigger · poke with your index finger
## Desktop: WASD move · mouse look (click to capture, Esc to release) ·
##   LMB grab/throw or press buttons · RMB context menu for what's under the
##   crosshair · E use / interact (sit, lamp) / press · crosshair on an AI =
##   talk to it · T type to AI · M mute · wheel = hand distance · drop files to import

signal dominant_changed(side: int)

const PointerScene := preload("res://scenes/player/pointer.tscn")
const WatchScene := preload("res://scenes/player/watch.tscn")
const MENU_SCENES := {
	"floor": "res://scenes/ui/menus/floor_menu.tscn",
	"seat": "res://scenes/ui/menus/floor_menu.tscn",
	"object": "res://scenes/ui/menus/object_menu.tscn",
	"agent": "res://scenes/ui/menus/agent_menu.tscn",
	"player": "res://scenes/ui/menus/player_menu.tscn",
	"wall": "res://scenes/ui/menus/wall_menu.tscn",
	"widget": "res://scenes/ui/menus/widget_menu.tscn",
	"calendar_day": "res://scenes/ui/menus/calendar_day_menu.tscn",
	"drawer_files": "res://scenes/ui/menus/file_browser.tscn",
}
const HAND_TRACKERS := [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
## Seated eye height above the seat surface.
const SEATED_EYE := 0.75
const DESKTOP_EYE := 1.65
## How far in front of the hand a gesture's context menu opens (m).
const MENU_AHEAD := 0.2

var vr := false
var camera: Camera3D
var hands: Array[Hand] = []

var _controllers: Array[XRController3D] = []
var _aim_controllers: Array[XRController3D] = []
var gestures: Array[HandGestures] = []
var pointers: Array[Pointer] = []
## The open context menu (only one at a time).
var _menu: RadialMenu
## Left-wrist watch (VR): time + Me / Room menus.
var watch: Watch
var _rays_visible := true
## The hand that points (0 = left, 1 = right; watch → Me → Dominant hand).
## Rays and context menus come only from it; the watch and the inventory are
## on the other arm.
var dominant := 1
## Outlines whatever you're targeting (watch → Me → Highlight).
var highlight: TargetHighlight
## One inventory slot on each forearm (used by the other hand).
var inventory: ArmInventory
var _toast: Label3D
var _toast_time := 0.0
var _turn_latched := false
var _last_talk_target := -1
var _mute_was := false
var _yaw := 0.0
var _pitch := 0.0
var _hand_dist := 0.9
var _typing: LineEdit
var _crosshair: Label
var _help: Label
## The chair we're sitting on (null when standing).
var _seat: NetBody
var _seat_local := Vector3.ZERO
var _standing_up := false
## Drawing on whiteboards: one pen per source ("tip0", "tip1", "ray0", "ray1", "mouse").
var _pens := {}
## Desktop: [board, point] while the left button draws on a board.
var _mouse_draw: Array = []


func _ready() -> void:
	add_to_group("local_player")
	vr = get_viewport().use_xr
	current = true
	if vr:
		camera = XRCamera3D.new()
	else:
		camera = Camera3D.new()
		camera.position = Vector3(0, DESKTOP_EYE, 0)
		camera.fov = 75
	camera.near = 0.03
	add_child(camera)
	for i in 2:
		var hand := Hand.make(i)
		if vr:
			var c := XRController3D.new()
			c.tracker = &"left_hand" if i == 0 else &"right_hand"
			c.pose = &"grip"
			add_child(c)
			_controllers.append(c)
			hand.controller = c
			var aim := XRController3D.new()
			aim.tracker = c.tracker
			aim.pose = &"aim"
			add_child(aim)
			_aim_controllers.append(aim)
		add_child(hand)
		hands.append(hand)
		gestures.append(HandGestures.new(i))
		var ptr: Pointer = PointerScene.instantiate()
		ptr.hand = hand
		ptr.rig = self
		add_child(ptr)
		# Menus remember which hand asked (Grab puts things in that hand).
		ptr.menu_requested.connect(func(t: Dictionary, at: Vector3):
			t = t.duplicate()
			t["hand"] = i
			_open_menu(t, _menu_spot(at)))
		pointers.append(ptr)
	dominant = 0 if Config.pref("dominant_hand", "right") == "left" else 1
	inventory = ArmInventory.new()
	inventory.name = "ArmInventory"
	add_child(inventory)
	inventory.hands = hands
	for h in hands:
		h.inventory = inventory
	highlight = TargetHighlight.new()
	add_child(highlight)
	highlight.enabled = Config.pref("highlight_targets", true) == true
	set_rays_visible(Config.pref("show_rays", true) == true, false)
	if vr:
		watch = WatchScene.instantiate()
		add_child(watch)
		_update_watch_hand()
		watch.get_node("%MeButton").pressed.connect(open_watch_menu.bind("me"))
		watch.get_node("%RoomButton").pressed.connect(open_watch_menu.bind("room"))
	_toast = Mk.label(camera, "", 32, Vector3(0, -0.12, -0.7), 600.0)
	_toast.pixel_size = 0.0006
	_toast.no_depth_test = true
	_toast.render_priority = 10
	if not vr:
		_build_desktop_ui()
		hands[1].grabbed.connect(func(_b: NetBody): _hand_dist = camera.global_position.distance_to(hands[1].global_position))
		get_window().files_dropped.connect(_on_files_dropped)
	Net.teleport_requested.connect(_on_teleport)
	Net.toast.connect(show_toast)
	Net.prompt_received.connect(_on_prompt)
	Sync.seated_changed.connect(_on_seated_changed)
	Sync.adopt_requested.connect(func(body: NetBody, hand: int): hands[clampi(hand, 0, 1)].adopt(body))


func show_toast(text: String, seconds := 4.0) -> void:
	_toast.text = text
	_toast_time = seconds


func _process(delta: float) -> void:
	_toast_time -= delta
	if _toast_time <= 0.0:
		_toast.text = ""
	if vr:
		_process_vr(delta)
	else:
		_process_desktop(delta)
	if _seat and not is_instance_valid(_seat):
		_seat = null # the chair was deleted under us
		global_position.y = 0.0
	if _seat:
		global_position = _seat.to_global(_seat_local)
	else:
		_clamp_to_room()
	_update_talk_target()
	_update_pens(delta)
	highlight.show_target(current_target())
	if Net.in_session:
		var rays := [pointers[0].net_ray(), pointers[1].net_ray()] if vr else [null, null]
		Sync.send_pose(camera.global_transform, hands[0].global_transform, hands[1].global_transform, rays, vr)


# --- VR ----------------------------------------------------------------------

func _process_vr(delta: float) -> void:
	for i in 2:
		var tracker := XRServer.get_tracker(HAND_TRACKERS[i]) as XRHandTracker
		var real_hand := tracker != null and tracker.has_tracking_data \
				and tracker.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
		var input: Array
		if real_hand:
			input = hands[i].follow_hand_tracker(tracker, global_transform)
			gestures[i].update_from_hand(tracker, global_transform)
		else:
			var c := _controllers[i]
			hands[i].follow_controller(c.global_transform)
			gestures[i].update_from_controller(c, _aim_controllers[i])
			input = [c.get_float("grip") > 0.6, c.get_float("trigger") > 0.6]
		# The pointer gets first say: a locked context gesture or a ray click
		# must not also grab or interact. Only the dominant hand points.
		var suppress := {"grip": false, "trigger": false}
		if i == dominant:
			suppress = pointers[i].update_pointer(gestures[i])
		elif pointers[i].state != Pointer.State.IDLE:
			pointers[i].idle()
		hands[i].update_input(input[0] and not suppress["grip"], input[1] and not suppress["trigger"])
	# The watch reads the left hand's joints itself whenever there are any.
	var off := 1 - dominant
	watch.track(hands[off], camera, XRServer.get_tracker(HAND_TRACKERS[off]) as XRHandTracker, global_transform, off == 0)
	var left := _controllers[0]
	var right := _controllers[1]
	# Smooth locomotion relative to where the head looks.
	var stick := left.get_vector2("primary")
	if stick.length() > 0.15:
		if _stand_if_seated():
			return
		var fwd := -camera.global_basis.z
		fwd.y = 0
		fwd = fwd.normalized()
		var side := fwd.cross(Vector3.UP)
		global_position += (fwd * stick.y + side * stick.x) * 2.0 * delta
	# Snap turn around the head.
	var turn := right.get_vector2("primary").x
	if absf(turn) > 0.7 and not _turn_latched:
		_turn_latched = true
		_rotate_around_head(-signf(turn) * deg_to_rad(30))
	elif absf(turn) < 0.3:
		_turn_latched = false
	var mute := left.is_button_pressed("ax_button")
	if mute and not _mute_was:
		_toggle_mute()
	_mute_was = mute


# --- Pointer rays and context menus -----------------------------------------------

## Whiteboards: your fingertips draw where they touch a board, and a pointer
## ray draws while you hold a pinch/trigger on one (desktop: hold the left
## button on it). Each source has its own pen, lifted when it stops.
func _update_pens(delta: float) -> void:
	var active := {}
	if Net.in_session:
		if vr:
			for i in 2:
				var tip: Vector3 = hands[i].get_node("%Poker").global_position
				for e in Sync.entities.values():
					if e is WhiteboardWidget and not e.touch(tip, 0.012).is_empty():
						active["tip%d" % i] = [e, tip]
						break
				if pointers[i].draw_board:
					active["ray%d" % i] = [pointers[i].draw_board, pointers[i].draw_point]
		elif _mouse_draw.size():
			active["mouse"] = _mouse_draw
	for key in active:
		if not _pens.has(key):
			_pens[key] = BoardPen.new()
		_pens[key].draw(active[key][0], active[key][1], delta)
	for key in _pens:
		if not active.has(key):
			_pens[key].lift()


## Point with the other hand (0 = left, 1 = right): the watch and inventory
## move to the other arm. Remembered.
func set_dominant(side: int) -> void:
	dominant = clampi(side, 0, 1)
	Config.set_pref("dominant_hand", "left" if dominant == 0 else "right")
	for p in pointers:
		p.idle()
	if watch:
		watch.close_menu()
		_update_watch_hand()
	dominant_changed.emit(dominant)


## Only the pointing hand presses the watch's buttons (it's on the other wrist).
func _update_watch_hand() -> void:
	for b: PokeButton in [watch.get_node("%MeButton"), watch.get_node("%RoomButton")]:
		b.ignore_pokers = [hands[1 - dominant].get_node("Poker")]


## Show/hide your pointer rays (to you and others). Pointing still works when hidden.
func set_rays_visible(on: bool, remember := true) -> void:
	_rays_visible = on
	if remember:
		Config.set_pref("show_rays", on)
	for p in pointers:
		p.ray_visible = on


func rays_visible() -> bool:
	return _rays_visible


func set_highlight_enabled(on: bool) -> void:
	highlight.enabled = on
	Config.set_pref("highlight_targets", on)


## What you're pointing at right now (VR: a pointer that's pointing or locked;
## desktop: the crosshair). {} if nothing.
func current_target() -> Dictionary:
	if not Net.in_session:
		return {}
	if vr:
		for p in pointers:
			if p.state != Pointer.State.IDLE:
				return p.target
		return {}
	var hit := _ray()
	return Pointer.classify(hit) if not hit.is_empty() else {}


## Open the virtual keyboard in front of you; `on_submit(text)` gets the result.
func open_keyboard(prompt: String, initial: String, on_submit: Callable) -> VirtualKeyboard:
	var cam := camera.global_transform
	var fwd := -cam.basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var pos := cam.origin + fwd * (0.45 if vr else 0.55) + Vector3(0, -0.22 if vr else -0.05, 0)
	var facing := Basis.looking_at(pos - cam.origin, Vector3.UP) # +Z toward your eyes, tilted up at you
	return VirtualKeyboard.open(get_parent(), Transform3D(facing, pos), prompt, initial, on_submit)


## The watch's menus: "me" (personal) or "room". In VR they float above the
## watch; on desktop (Q / R) in front of you.
func open_watch_menu(which: String) -> RadialMenu:
	var path := Watch.PERSONAL_MENU if which == "me" else Watch.ROOM_MENU
	#if watch:
	#	return watch.open_menu(path, self)
	if is_instance_valid(_menu):
		_menu.close()
	_menu = load(path).instantiate()
	_menu.setup({}, self)
	get_parent().add_child(_menu)
	var cam := camera.global_transform
	_menu.global_position = cam.origin - cam.basis.z * 0.6
	return _menu


## Open the context menu for `target` (see Pointer.classify; widgets add
## "calendar_day" and "drawer_files") around `at`, replacing any open one.
func open_context_menu(target: Dictionary, at: Vector3) -> RadialMenu:
	_open_menu(target, at)
	return _menu


func _open_menu(target: Dictionary, at: Vector3) -> void:
	var path: String = MENU_SCENES.get(target.get("type", ""), "")
	if target.get("type") == "button" and Sync.entities.get(int(target.get("entity_id", 0))) is Widget:
		path = MENU_SCENES["widget"] # desktop right-click on a widget's button
	if path == "" or not Net.in_session:
		return
	if is_instance_valid(_menu):
		_menu.close()
	var menu: RadialMenu = load(path).instantiate()
	menu.setup(target, self)
	get_parent().add_child(menu)
	menu.global_position = at
	_menu = menu


## Where a gesture's menu opens: ahead of the hand (away from you), so the
## fist that summoned it isn't inside it and every slice is in front of your
## fingertip.
func _menu_spot(hand_pos: Vector3) -> Vector3:
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	return hand_pos + fwd * MENU_AHEAD


## Context menu → Grab: teleport an object into `hand` (default: the right one).
func fetch_to_hand(entity_id: int, hand := 1) -> void:
	var e: NetBody = Sync.entities.get(entity_id)
	if e:
		hands[clampi(hand, 0, 1)].fetch(e)


## Move so your head is over `point` (from the floor menu), standing up first if seated.
func teleport_to_point(point: Vector3) -> void:
	if _seat:
		Sync.request_stand()
		_on_seated_changed(null)
	var head := camera.global_position
	global_position += Vector3(point.x - head.x, -global_position.y, point.z - head.z)
	_clamp_to_room()


func _rotate_around_head(angle: float) -> void:
	var head := camera.global_position
	global_transform = Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO) * global_transform.translated(-head)
	global_position += head
	if _seat:
		_seat_local = _seat.to_local(global_position)


# --- Desktop -----------------------------------------------------------------

func _build_desktop_ui() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.add_theme_font_size_override("font_size", 28)
	ui.add_child(_crosshair)
	_help = Label.new()
	_help.text = "Desktop mode — click to look · WASD move · LMB grab/press, or drag on a whiteboard to draw · RMB context menu (walls: add widgets) · E use/sit/switch/open · 1/2 arm slots · aim at an AI and speak · T type to AI · M mute · Q Me menu · R Room menu · drop files here to import"
	_help.position = Vector2(10, 10)
	ui.add_child(_help)
	_typing = LineEdit.new()
	_typing.placeholder_text = "Type to the AI you're facing (Enter to send, Esc to cancel)"
	_typing.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_typing.custom_minimum_size = Vector2(700, 36)
	_typing.position = Vector2(-350, -60)
	_typing.visible = false
	_typing.text_submitted.connect(_on_typed)
	ui.add_child(_typing)


func _unhandled_input(event: InputEvent) -> void:
	if vr or VirtualKeyboard.is_open():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.003
		_pitch = clampf(_pitch - event.relative.y * 0.003, -1.4, 1.4)
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not _typing.visible:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
		elif event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and _scroll_under_crosshair(-1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0):
			pass # scrolled a board or a document's text
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_hand_dist = minf(_hand_dist + 0.1, 3.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_hand_dist = maxf(_hand_dist - 0.1, 0.4)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var hit := _ray()
			if hit.get("collider") is PokeButton:
				hit["collider"].press()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			var hit := _ray()
			if not hit.is_empty():
				var cam := camera.global_transform
				_open_menu(Pointer.classify(hit), cam.origin - cam.basis.z * 0.6)
	elif event is InputEventKey and event.pressed and not event.echo and not _typing.visible:
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_E:
				var hit := _ray()
				if hit.get("collider") is PokeButton:
					hit["collider"].press()
				elif hands[1].held:
					Sync.request_use(hands[1].held.entity_id)
				elif hit.get("collider") is NetBody:
					Sync.request_interact(hit["collider"].entity_id)
				elif _seat:
					Sync.request_stand()
			KEY_T:
				_typing.visible = true
				_typing.text = ""
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_typing.grab_focus()
				get_viewport().set_input_as_handled()
			KEY_M:
				_toggle_mute()
			KEY_1, KEY_2:
				_desktop_slot(event.keycode - KEY_1)
			KEY_Q:
				open_watch_menu("me")
			KEY_R:
				open_watch_menu("room")


## Desktop: the mouse wheel over a whiteboard or a document scrolls it (when
## you're not holding anything). Returns true if something scrolled.
func _scroll_under_crosshair(direction: float) -> bool:
	if hands[1].held:
		return false
	var c: Object = _ray().get("collider")
	if c is WhiteboardWidget:
		(c as WhiteboardWidget).scroll_by(direction * 0.25)
		return true
	if c is NetBody:
		for n in (c as Node).get_children():
			if n is ScrollText and n.visible and n.overflow().y > 0.0:
				(n as ScrollText).scroll_by(0.0, direction * 0.3)
				return true
	return false


## Desktop: 1 / 2 = the slot on your left / right arm: what you hold goes in
## (what was there drops out), or with an empty hand, its item comes out.
func _desktop_slot(slot: int) -> void:
	var hand := hands[1]
	var full := inventory.contents()
	if hand.held:
		var name_ := str(hand.held.data.get("name", hand.held.kind))
		inventory.stow(hand, true, slot)
		show_toast("%s is on your %s arm." % [name_, "left" if slot == 0 else "right"], 2.0)
	elif full.has(slot):
		hand.fetch(full[slot], false)
	else:
		show_toast("Your %s arm's slot is empty (hold something and press %d to put it there)." % ["left" if slot == 0 else "right", slot + 1], 3.0)


func _process_desktop(delta: float) -> void:
	basis = Basis(Vector3.UP, _yaw)
	camera.rotation = Vector3(_pitch, 0, 0)
	var typing := _typing.visible
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if not typing:
		var mv := Vector3.ZERO
		if Input.is_physical_key_pressed(KEY_W): mv.z -= 1
		if Input.is_physical_key_pressed(KEY_S): mv.z += 1
		if Input.is_physical_key_pressed(KEY_A): mv.x -= 1
		if Input.is_physical_key_pressed(KEY_D): mv.x += 1
		if mv != Vector3.ZERO and not VirtualKeyboard.is_open() and not _stand_if_seated():
			var speed := 5.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 2.5
			global_position += basis * mv.normalized() * speed * delta
	# Right hand floats where the crosshair points; left hand rests low.
	var cam := camera.global_transform
	var fwd := -cam.basis.z
	var right_pos: Vector3
	var hit := _ray()
	# Holding the left button on a whiteboard draws on it (instead of grabbing).
	var on_board: bool = captured and not typing and hands[1].held == null and hit.get("collider") is WhiteboardWidget \
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	_mouse_draw = [hit["collider"], hit["position"]] if on_board else []
	if hands[1].held:
		right_pos = cam.origin + fwd * _hand_dist
	else:
		# Hover just short of what the crosshair touches so the hand doesn't shove it;
		# a click grabs the object under the crosshair.
		var d: float = cam.origin.distance_to(hit["position"]) - 0.15 if hit else 1.0
		right_pos = cam.origin + fwd * clampf(d, 0.3, 3.0)
		hands[1].grab_hint = hit.get("collider") as NetBody
	hands[1].global_transform = Transform3D(cam.basis, right_pos)
	hands[0].global_transform = Transform3D(cam.basis, cam.origin + cam.basis * Vector3(-0.25, -0.35, -0.4))
	var over_button: bool = hit.get("collider") is PokeButton
	var lmb := captured and not typing and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and (hands[1].held != null or not over_button) and not on_board
	hands[1].update_input(lmb, false)
	hands[0].update_input(false, false)
	_crosshair.modulate = Color.YELLOW if over_button or hit.get("collider") is NetBody else Color.WHITE
	# The floating desktop hand would cover the button under the crosshair.
	hands[1].visible = hands[1].held != null or not over_button


func _ray() -> Dictionary:
	var cam := camera.global_transform
	var q := PhysicsRayQueryParameters3D.create(cam.origin, cam.origin - cam.basis.z * 4.0,
			Pointer.MASK)
	q.collide_with_areas = true
	var exclude: Array[RID] = []
	if hands[1].held:
		exclude.append(hands[1].held.get_rid())
	if _seat:
		exclude.append(_seat.get_rid())
	q.exclude = exclude
	return get_world_3d().direct_space_state.intersect_ray(q)


func _on_typed(text: String) -> void:
	_typing.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if text.strip_edges() != "":
		var target := talk_target()
		if target == -1:
			target = _pick_agent()
		if target <= 0:
			show_toast("Point at (or face) an AI agent to type to it.")
			return
		AI.request_text(target, text)

# --- Sitting ------------------------------------------------------------------

func _on_seated_changed(chair: NetBody) -> void:
	_standing_up = false
	if chair:
		var seat := Sync.seat_xform(chair)
		var fwd := -seat.basis.z
		fwd.y = 0
		fwd = fwd.normalized()
		var eye := seat.origin + Vector3(0, SEATED_EYE, 0)
		var target_yaw := atan2(-fwd.x, -fwd.z)
		if vr:
			# Face the way the chair faces, then put the head at seated eye height
			# (works whether the user is physically sitting or standing).
			var head_yaw := atan2(camera.transform.basis.z.x, camera.transform.basis.z.z)
			global_transform = Transform3D(Basis(Vector3.UP, target_yaw - head_yaw), global_position)
			global_position += eye - camera.global_position
		else:
			_yaw = target_yaw
			basis = Basis(Vector3.UP, _yaw)
			global_position = eye - Vector3(0, DESKTOP_EYE, 0)
		_seat = chair
		_seat_local = chair.to_local(global_position)
		show_toast("Sitting. Move, or trigger/E again, to stand up.", 3.0)
	elif _seat:
		var out := _seat.global_position - _seat.global_basis.z * 0.6
		_seat = null
		# Back on the floor, just in front of the chair.
		var head := camera.global_position
		global_position += Vector3(out.x - head.x, -global_position.y, out.z - head.z)


## Returns true if we were seated (and asked to stand instead of moving).
func _stand_if_seated() -> bool:
	if not _seat:
		return false
	if not _standing_up:
		_standing_up = true
		Sync.request_stand()
	return true


# --- Shared -------------------------------------------------------------------

## Point-to-talk: whichever AI agent a pointer ray (desktop: the crosshair) is
## on is who you're talking to (-1: nobody).
func talk_target() -> int:
	if not Net.in_session:
		return -1
	if vr:
		for p in pointers:
			if p.state == Pointer.State.POINTING:
				var t := _talk_target_of(p.target)
				if t != -1:
					return t
		return -1
	var hit := _ray()
	return _talk_target_of(Pointer.classify(hit)) if not hit.is_empty() else -1


## (AIs you've turned point-to-talk off for don't listen when pointed at.)
static func _talk_target_of(target: Dictionary) -> int:
	if target.get("type") != "agent" or not Voice.agent_listens(int(target["entity_id"])):
		return -1
	return int(target["entity_id"])


func _update_talk_target() -> void:
	var t := talk_target()
	Voice.set_ai_target(t)
	if t == _last_talk_target:
		return
	if t != -1:
		show_toast("Listening: %s (stop pointing to send)" % _target_name(t), 2.0)
		hands[1].haptic(0.2)
	_last_talk_target = t


## The AI agent the user is facing (entity id), or 0 for the room assistant.
func _pick_agent() -> int:
	var head := camera.global_transform
	var best := 0
	var best_score := -INF
	for a in Sync.entities_of_kind("agent"):
		var to: Vector3 = a.global_position + Vector3(0, 1.5 - a._sit_offset, 0) - head.origin
		var dist := to.length()
		if dist > 6.0:
			continue
		var facing := (-head.basis.z).dot(to.normalized())
		if facing < 0.5:
			continue
		var score := facing * 2.0 - dist * 0.3
		if score > best_score:
			best_score = score
			best = a.entity_id
	return best


func _target_name(agent_id: int) -> String:
	var a: NetBody = Sync.entities.get(agent_id)
	return str(a.data.get("name", "AI")) if a else "nobody"


func _toggle_mute() -> void:
	Voice.set_muted(not Voice.muted)
	show_toast("Mic muted" if Voice.muted else "Mic on", 1.5)


func _on_teleport(xf: Transform3D) -> void:
	for h in hands:
		h.release()
	if _seat:
		Sync.request_stand()
		_seat = null
	if vr:
		# Put the *head* at the target, facing the target direction.
		var head_local := camera.transform
		var yaw := atan2(head_local.basis.z.x, head_local.basis.z.z)
		var target_yaw := atan2(xf.basis.z.x, xf.basis.z.z)
		global_transform = Transform3D(Basis(Vector3.UP, target_yaw - yaw), xf.origin)
		var offset := camera.global_position - global_position
		global_position -= Vector3(offset.x, 0, offset.z)
	else:
		global_position = xf.origin
		_yaw = atan2(xf.basis.z.x, xf.basis.z.z)


func _clamp_to_room() -> void:
	# The lobby is 10x10; the office is whatever size the owner made it.
	var half := (Office.size() if Net.in_session else Vector3(10, 3, 10)) * 0.5 - Vector3(0.25, 0, 0.25)
	var head := camera.global_position
	var clamped := Vector3(clampf(head.x, -half.x, half.x), head.y, clampf(head.z, -half.z, half.z))
	global_position += Vector3(clamped.x - head.x, 0, clamped.z - head.z)


## Requests wait on the watch (Me: come-over requests, Room: join requests).
func _on_prompt(kind: String, _req_id: int, text: String) -> void:
	var where := "Me" if kind == "summon" else "Room"
	var how := "on your watch" if vr else "(%s)" % ("Q" if kind == "summon" else "R")
	show_toast("%s — answer in the %s menu %s" % [text.replace("\n", " "), where, how], 6.0)
	hands[0].haptic(0.8)
	hands[1].haptic(0.8)


func _on_files_dropped(paths: PackedStringArray) -> void:
	if not Net.in_session:
		show_toast("Join or host an office first.")
		return
	for p in paths:
		Files.upload_path(p)
	show_toast("Importing %d file(s)…" % paths.size())
