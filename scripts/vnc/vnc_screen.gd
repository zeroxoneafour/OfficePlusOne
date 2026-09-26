class_name VncScreen extends Node3D
## A flat screen (scenes/vnc/vnc_screen.tscn, facing +Z) that shows a remote
## computer read-only through a VncClient, letterboxed to keep its shape, with
## a status line while it isn't showing anything. Used by TVs and monitors
## (see RemoteDisplay).

## The screen's size in metres.
@export var screen_size := Vector2(1.6, 0.9):
	set(v):
		screen_size = v
		if is_node_ready():
			_fit()

var client: VncClient
var _target := ""
var _material: StandardMaterial3D


func _ready() -> void:
	client = VncClient.new()
	add_child(client)
	client.status_changed.connect(func(_s: String): _refresh())
	client.frame_updated.connect(_on_frame)
	var quad := QuadMesh.new()
	%Picture.mesh = quad
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color.WHITE
	%Picture.material_override = _material
	_fit()
	_refresh()


## Connect to a computer's VNC server (replacing whatever was shown).
func show_remote(host: String, port: int, password := "") -> void:
	_target = "%s:%d" % [host, port]
	client.connect_to(host, port, password)
	_refresh()


func clear_remote() -> void:
	_target = ""
	client.disconnect_from()
	_refresh()


## "idle" | "connecting" | "connected" | "error: …"
func status() -> String:
	return client.status if client else "idle"


func _on_frame() -> void:
	if _material.albedo_texture != client.texture:
		_material.albedo_texture = client.texture
		_fit()
	%Picture.visible = true


func _refresh() -> void:
	var s := status()
	%Picture.visible = s == "connected" and client.texture != null
	if %Picture.visible:
		_material.albedo_texture = client.texture
		_fit()
	match s:
		"connected":
			%Status.text = ""
		"connecting":
			%Status.text = "Connecting to %s…" % _target
		"idle":
			%Status.text = "No computer connected\nMenu → Connect…" if _target == "" else "Disconnected from %s" % _target
		_:
			%Status.text = "Couldn't show %s:\n%s" % [_target, s.trim_prefix("error: ")]


## Letterbox the picture to the remote desktop's shape.
func _fit() -> void:
	var quad := %Picture.mesh as QuadMesh
	if not quad:
		return
	var size := screen_size
	if client and client.desktop_size.x > 0:
		var aspect := float(client.desktop_size.x) / client.desktop_size.y
		size = Vector2(screen_size.x, screen_size.x / aspect)
		if size.y > screen_size.y:
			size = Vector2(screen_size.y * aspect, screen_size.y)
	quad.size = size
	%Status.width = screen_size.x * 0.9 / %Status.pixel_size
