extends Node3D
## How other humans appear (scenes/player/avatar.tscn): head, hands, torso,
## name tag, a 3D voice source for proximity chat, their pointing rays, and a
## hit body so they can be pointed at (for the context menu).

const SCENE_PATH := "res://scenes/player/avatar.tscn"

var peer_id := 0
@onready var voice: VoicePlayback = %Voice


static func make(peer: int) -> Node3D:
	var a: Node3D = load(SCENE_PATH).instantiate()
	a.peer_id = peer
	return a


func _ready() -> void:
	%HitBody.set_meta("peer", peer_id)
	voice.volume_db = linear_to_db(maxf(Voice.player_volume(peer_id), 0.0001))
	var c := Color.from_hsv(fmod(peer_id * 0.137, 1.0), 0.45, 0.85)
	for m in find_children("*", "MeshInstance3D"):
		if m.is_in_group("tint"):
			m.material_override = Mk.mat(c)
		elif m.is_in_group("tint_dark"):
			m.material_override = Mk.mat(c.darkened(0.2))
		elif m.is_in_group("tint_light"):
			m.material_override = Mk.mat(c.lightened(0.2))


func set_player_name(n: String) -> void:
	%NameLabel.text = n


func _process(delta: float) -> void:
	var pose: Dictionary = Sync.poses.get(peer_id, {})
	if pose.is_empty():
		return
	visible = true
	var w := 1.0 - exp(-20.0 * delta)
	var head: Transform3D = pose["head"]
	%Head.global_transform = %Head.global_transform.interpolate_with(head, w)
	var yaw := atan2(head.basis.z.x, head.basis.z.z)
	%Torso.global_transform = Transform3D(Basis(Vector3.UP, yaw), head.origin - Vector3(0, 0.6, 0) + Basis(Vector3.UP, yaw) * Vector3(0, 0, 0.08))
	for i in 2:
		var t: Transform3D = pose["l" if i == 0 else "r"]
		var hand: Node3D = %HandL if i == 0 else %HandR
		hand.global_position = hand.global_position.lerp(t.origin, w)
	%HitBody.global_position = %Head.global_position
	var rays: Array = pose.get("rays", [null, null])
	for i in 2:
		var beam: MeshInstance3D = %RayL if i == 0 else %RayR
		var r: Variant = rays[i] if i < rays.size() else null
		beam.visible = r is Array and r.size() == 2
		if beam.visible:
			var from: Vector3 = r[0]
			var to: Vector3 = r[1]
			var length := from.distance_to(to)
			beam.visible = length > 0.01
			if beam.visible:
				beam.global_transform = Transform3D(Pointer._basis_y_along((to - from) / length).scaled_local(Vector3(1, length, 1)), (from + to) * 0.5)
