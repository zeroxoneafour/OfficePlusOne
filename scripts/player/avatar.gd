extends Node3D
## How other humans appear (scenes/player/avatar.tscn): a cartoon head
## (MiiHead) that talks when they do, hands, torso,
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
	# Their shirt colour; face and hands get a cartoon look from their name.
	%Torso.material_override = Mk.toon(Color.from_hsv(fmod(peer_id * 0.137, 1.0), 0.5, 0.85))
	_apply_look(str(peer_id))


func set_player_name(n: String) -> void:
	if %NameLabel.text != n:
		%NameLabel.text = n
		_apply_look(n)


func _apply_look(key: String) -> void:
	var look := MiiHead.look_for(key)
	%Face.set_colors(look["skin"], look["hair"])
	for h in [%HandL, %HandR]:
		h.material_override = Mk.toon(look["skin"])


func _process(delta: float) -> void:
	var pose: Dictionary = Sync.poses.get(peer_id, {})
	if pose.is_empty():
		return
	visible = true
	%Face.set_talk(clampf(voice.level * 12.0, 0.0, 1.0))
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
