class_name MiiHead extends Node3D
## A friendly cartoon head (scenes/characters/mii_head.tscn), Wii-Mii style,
## shared by people's avatars and AI agents so everyone looks like they
## belong together. Big eyes that blink and glance around, eyebrows and a
## mouth that show a mood, a mouth that moves when talking, rosy cheeks.
## Faces -Z. Colours come from skin / hair / tint (see look_for()).

const SKINS := ["#f6d7bf", "#efc19c", "#d99f78", "#b87a53", "#8d5836", "#f3c9a9"]
const HAIRS := ["#2b1d14", "#5a3825", "#8a5a2b", "#e0b060", "#1b1b1b", "#b5523a", "#7a7a7a", "#3b2a5a"]
const MOUTH := Color("#8a2c3a")
const CHEEK := Color(1.0, 0.45, 0.55, 0.45)

## Mood: "idle" | "listening" | "thinking" | "speaking" | "happy". Brows, eyes
## and mouth shape follow it.
var mood := "idle"
var _talk := 0.0
var _blink_in := 2.0
var _blink_left := 0.0
var _glance := Vector2.ZERO
var _glance_target := Vector2.ZERO
var _glance_in := 1.0
var _brow_l := 0.0
var _brow_r := 0.0
var _brow_y := 0.0


## Stable skin and hair colours for someone, from their name (or id).
static func look_for(key: String) -> Dictionary:
	var h := absi(hash(key))
	return {"skin": Color(SKINS[h % SKINS.size()]), "hair": Color(HAIRS[(h / 7) % HAIRS.size()])}


func set_colors(skin: Color, hair: Color) -> void:
	for m in find_children("*", "MeshInstance3D", true, false):
		if m.is_in_group("skin"):
			m.material_override = Mk.toon(skin)
		elif m.is_in_group("hair"):
			m.material_override = Mk.toon(hair)
		elif m.is_in_group("eye_white"):
			m.material_override = Mk.toon(Color.WHITE)
		elif m.is_in_group("pupil"):
			m.material_override = Mk.toon(Color("#1a1a2a"))
		elif m.is_in_group("mouth"):
			m.material_override = Mk.toon(MOUTH)
		elif m.is_in_group("cheek"):
			m.material_override = Mk.mat(CHEEK)
	%BrowL.material_override = Mk.toon(hair.darkened(0.25))
	%BrowR.material_override = Mk.toon(hair.darkened(0.25))


## How loud they're talking right now (0..1): the mouth opens with it.
func set_talk(level: float) -> void:
	_talk = clampf(level, 0.0, 1.0)


func set_mood(m: String) -> void:
	mood = m


func _process(delta: float) -> void:
	# Blink every few seconds.
	_blink_in -= delta
	if _blink_in <= 0.0:
		_blink_in = randf_range(2.0, 5.0)
		_blink_left = 0.12
	_blink_left -= delta
	var open := 0.12 if _blink_left > 0.0 else (1.15 if mood == "listening" else 1.0)
	for e in [%EyeL, %EyeR]:
		e.scale.y = lerpf(e.scale.y, open, 1.0 - exp(-30.0 * delta))
	# Glance around now and then; look up while thinking.
	_glance_in -= delta
	if _glance_in <= 0.0:
		_glance_in = randf_range(0.8, 2.5)
		_glance_target = Vector2(randf_range(-1, 1), randf_range(-0.6, 0.6)) * 0.004
	var want := Vector2(0.004, 0.006) if mood == "thinking" else _glance_target
	_glance = _glance.lerp(want, 1.0 - exp(-8.0 * delta))
	for p in [%PupilL, %PupilR]:
		p.position = Vector3(_glance.x, _glance.y, p.position.z)
	# Brows: raised and tilted when listening, one up when thinking.
	var bl := 0.0
	var br := 0.0
	var by := 0.0
	match mood:
		"listening":
			by = 0.008
			bl = 0.15
			br = -0.15
		"thinking":
			by = 0.004
			bl = -0.25
			br = 0.05
		"happy", "speaking":
			by = 0.004
	var k := 1.0 - exp(-10.0 * delta)
	_brow_l = lerpf(_brow_l, bl, k)
	_brow_r = lerpf(_brow_r, br, k)
	_brow_y = lerpf(_brow_y, by, k)
	%BrowL.rotation.z = _brow_l
	%BrowR.rotation.z = _brow_r
	%BrowL.position.y = 0.068 + _brow_y
	%BrowR.position.y = 0.068 + _brow_y
	# Mouth: a smile at rest, opening as they talk; a small "o" when thinking.
	var talk := _talk
	var wide := 1.0 if mood != "thinking" else 0.55
	%Mouth.scale = %Mouth.scale.lerp(Vector3(wide * (1.0 - talk * 0.25), 1.0 + talk * 3.5, 1.0), 1.0 - exp(-25.0 * delta))
