class_name ArmInventory extends Node3D
## Inventory slots on your non-dominant forearm (a quickbelt on the arm): a row
## of rings from the wrist toward the elbow. Let go of something you're holding
## near an empty ring and it shrinks into that slot and rides on your arm;
## close your pointing hand on a filled ring to take it out again, full size.
## Desktop: 1-4 put what you hold into that slot, or take its item out.
##
## Stowed items are ordinary entities with data "stowed" = [peer, hand, slot]:
## the server keeps them on that player's arm (Sync._update_stowed), everyone
## sees them there, small (NetBody shrinks its visuals). Your own are placed
## here every frame from your tracked hand, so they don't lag behind it.

const SLOTS := 4
## How close (m) a held item (or the hand holding it) must be to a ring to go in.
const STOW_REACH := 0.1
## How close (m) your hand must be to a filled ring to take its item.
const TAKE_REACH := 0.07
const RING_EMPTY := Color(0.8, 0.85, 0.95, 0.55)
const RING_FULL := Color("#f2d06b")
const RING_TARGET := Color("#4cff7a")

## The arm the slots are on (the non-dominant hand).
var hand: Hand
var _rings: Array[MeshInstance3D] = []
var _labels: Array[Label3D] = []
var _mats := {}


## A slot relative to the hand it's on: +Z runs from the palm back toward the
## elbow, +Y is the back of the hand (tracked palm joint; for a controller's
## grip pose, the top of your fist).
static func slot_local(slot: int) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0, 0.045, 0.07 + slot * 0.055))


func _ready() -> void:
	for i in SLOTS:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.024
		torus.outer_radius = 0.03
		torus.rings = 24
		torus.ring_segments = 6
		ring.mesh = torus
		ring.material_override = _ring_mat(RING_EMPTY)
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(ring)
		_rings.append(ring)
		var l := Mk.label(ring, str(i + 1), 28, Vector3(0.036, 0.0, 0.0))
		l.pixel_size = 0.0006
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		_labels.append(l)


func _ring_mat(c: Color) -> StandardMaterial3D:
	if not _mats.has(c):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mats[c] = m
	return _mats[c]


## World transform of a slot on this arm.
func slot_world(slot: int) -> Transform3D:
	return hand.global_transform * slot_local(slot)


## What's in each slot (yours): slot -> NetBody.
func contents() -> Dictionary:
	var out := {}
	for e in Sync.entities.values():
		var s: Variant = e.data.get("stowed")
		if s is Array and s.size() == 3 and int(s[0]) == Net.my_id():
			out[int(s[2])] = e
	return out


## The empty slot a held item would go into if let go now, or -1.
func free_slot_near(body: NetBody, holding_hand: Node3D) -> int:
	if not hand or not is_instance_valid(body):
		return -1
	var full := contents()
	var best := -1
	var best_d := STOW_REACH
	for i in SLOTS:
		if full.has(i):
			continue
		var p := slot_world(i).origin
		var d := minf(p.distance_to(body.global_position), p.distance_to(holding_hand.global_position))
		if d < best_d:
			best_d = d
			best = i
	return best


## The stowed item within reach of `pos` (your other hand), or null.
func item_near(pos: Vector3) -> NetBody:
	if not hand:
		return null
	var best: NetBody = null
	var best_d := TAKE_REACH
	var full := contents()
	for i in full:
		var d := slot_world(i).origin.distance_to(pos)
		if d < best_d:
			best_d = d
			best = full[i]
	return best


## Put what `from` holds into `slot` (or the nearest free one if -1).
func stow(from: Hand, slot := -1) -> bool:
	var body := from.held
	if not body:
		return false
	if slot < 0:
		slot = free_slot_near(body, from)
	if slot < 0 or contents().has(slot):
		return false
	from.let_go_quietly()
	if not Net.is_server():
		body.end_local_hold()
	Sync.request_stow(body.entity_id, hand.index, slot)
	from.haptic(0.4)
	return true


func _process(_delta: float) -> void:
	visible = Net.in_session and hand != null
	if not visible:
		return
	var full := contents()
	var dom: Hand = get_parent().hands[1 - hand.index] if get_parent() and "hands" in get_parent() else null
	var target := free_slot_near(dom.held, dom) if dom and dom.held else -1
	var take: NetBody = item_near(dom.global_position) if dom and not dom.held else null
	for i in SLOTS:
		var xf := slot_world(i)
		# Rings lie flat on the arm (the torus's axis is its local Y).
		_rings[i].global_transform = xf
		var c := RING_TARGET if i == target or (take and full.get(i) == take) else (RING_FULL if full.has(i) else RING_EMPTY)
		_rings[i].material_override = _ring_mat(c)
	# Your own stowed items ride on your arm exactly (not a network round trip behind).
	for i in full:
		var e: NetBody = full[i]
		if e.local_holder or e.held_by != 0:
			continue # being taken out
		e.stow_local = true
		e.global_transform = slot_world(i) * e.stow_offset()
