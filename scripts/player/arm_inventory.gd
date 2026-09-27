class_name ArmInventory extends Node3D
## One big inventory slot on each forearm, used by the other hand: let go of
## something over the slot to put it there (if the slot was full, what was in
## it drops out), and close an empty hand on the slot to take it back.
## Desktop: 1 = the slot on your left arm, 2 = the right; with something in
## your hand it goes in, with an empty hand it comes out.

## Items keep their size on your arm (only something huge, like furniture, is
## shrunk to fit), and they're inert there: you can't open, press or use
## them until you take them out.
##
## A stowed item is an ordinary entity with data "stowed" = [peer, arm, 0]
## (arm 0 = left, 1 = right): the server keeps it on that player's arm
## (Sync._update_stowed), everyone sees it there, and your own are placed
## here every frame from your tracked hands, so they don't lag behind.

const SLOTS := 2 # slot i is on arm i
## How close (m) a held item, or the hand, must be to a slot to use it.
const REACH := 0.14
const RING_EMPTY := Color(0.85, 0.9, 1.0, 0.45)
const RING_FULL := Color("#f2d06b")
const RING_TARGET := Color("#4cff7a")

## Both hands (the slots ride on their forearms).
var hands: Array = []
var _rings: Array[MeshInstance3D] = []
var _labels: Array[Label3D] = []
var _mats := {}

## A slot relative to the hand whose forearm it's on: on top of the forearm
## (+Y is the back of the hand) a hand's length back from the palm (+Z).
static func slot_local(arm: int) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0, -0.22, -0.06)).rotated_local(Vector3(0, 1, 0), deg_to_rad(180)).rotated_local(Vector3(0, 0, 1), deg_to_rad(90 - 180 * arm))


## Desktop (no arms): the two slots sit at the lower corners of your view,
## relative to your head (camera).
const DESKTOP_SLOTS := [Transform3D(Basis.IDENTITY, Vector3(-0.3, -0.28, -0.55)), Transform3D(Basis.IDENTITY, Vector3(0.3, -0.28, -0.55))]


## Where slot `arm` is for a player's pose (Sync.poses entry), or null.
## Used by the server for everyone, and here for you.
static func slot_transform(pose: Dictionary, arm: int) -> Variant:
	if pose.get("physical", true) == false:
		var head: Variant = pose.get("head")
		return (head as Transform3D) * DESKTOP_SLOTS[arm] if head is Transform3D else null
	var h: Variant = pose.get("l" if arm == 0 else "r")
	return (h as Transform3D) * slot_local(arm) if h is Transform3D else null

func _ready() -> void:
	for i in SLOTS:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.06
		torus.outer_radius = 0.072
		torus.rings = 32
		torus.ring_segments = 8
		ring.mesh = torus
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(ring)
		_rings.append(ring)

func _ring_mat(c: Color) -> StandardMaterial3D:
	if not _mats.has(c):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mats[c] = m
	return _mats[c]


## The slot a hand uses: the one on its other arm.
static func slot_for(hand: Hand) -> int:
	return 1 - hand.index

func slot_world(slot: int) -> Transform3D:
	var hand: Hand = hands[slot]
	if not hand.controller: # desktop
		var cam := get_viewport().get_camera_3d()
		if cam:
			return cam.global_transform * DESKTOP_SLOTS[slot]
	return hand.global_transform * slot_local(slot)


## Your stowed items: slot -> NetBody.
func contents() -> Dictionary:
	var out := {}
	for e in Sync.entities.values():
		var s: Variant = e.data.get("stowed")
		if s is Array and s.size() == 3 and int(s[0]) == Net.my_id():
			out[int(s[1])] = e
	return out


## Is `hand` (or what it holds) over its slot?
func in_reach(hand: Hand) -> bool:
	if hands.size() < SLOTS:
		return false
	var p := slot_world(slot_for(hand)).origin
	if p.distance_to(hand.global_position) < REACH:
		return true
	return is_instance_valid(hand.held) and p.distance_to(hand.held.global_position) < REACH

## What an empty hand would take out if it closed now, or null.
func item_near(hand: Hand) -> NetBody:
	if hand.held or not in_reach(hand):
		return null
	return contents().get(slot_for(hand))


## Put what `hand` holds into its slot (what was there drops out). With
## `anywhere`, it doesn't have to be over the slot (desktop keys).
func stow(hand: Hand, anywhere := false, slot := 0) -> bool:
	var body := hand.held
	if not body or not (anywhere or in_reach(hand)):
		return false
	hand.let_go_quietly()
	if not Net.is_server():
		body.end_local_hold()
	Sync.request_stow(body.entity_id, slot_for(hand), slot)
	hand.haptic(0.4)
	return true


func _process(_delta: float) -> void:
	visible = Net.in_session and hands.size() == SLOTS
	if not visible:
		return
	var full := contents()
	var target := {}
	for h: Hand in hands:
		if in_reach(h) and (h.held or full.has(slot_for(h))):
			target[slot_for(h)] = true
	for i in SLOTS:
		_rings[i].visible = (hands[i] as Hand).controller != null # desktop: no arms to show them on
		_rings[i].global_transform = slot_world(i) # (the torus lies flat on the arm)
		_rings[i].material_override = _ring_mat(RING_TARGET if target.has(i) else (RING_FULL if full.has(i) else RING_EMPTY))
	# Your own stowed items ride on your arms exactly (not a network round trip behind).
	for i in full:
		var e: NetBody = full[i]
		if e.local_holder or e.held_by != 0:
			continue # being taken out
		e.stow_local = true
		e.global_transform = slot_world(i) * e.stow_offset()
