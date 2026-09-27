class_name Document extends NetBody
## A file as a physical object (scenes/entities/document.tscn). Hand it to
## people or AIs, press it on the whiteboard, or pull the trigger while
## holding it to save a copy to your device.
## data: {file_id, name, mime, size, preview, image}

const TAB_COLORS := {"image": "#e07a5f", "pdf": "#c0504d", "text": "#3d85c6", "office": "#81b29a", "other": "#888888"}


func _build() -> void:
	Sync.image_added.connect(_on_image_added) # (a method: disconnects itself when this is deleted)


func _on_image_added(_id: int) -> void:
	_refresh()


func _data_changed(key: String, _value: Variant) -> void:
	if key in ["name", "preview", "image", "mime", "size"]:
		_refresh()


func _refresh() -> void:
	var mime := str(data.get("mime", ""))
	%Title.text = str(data.get("name", "file"))
	var tex: Texture2D = Sync.images.get(int(data.get("image", 0)))
	%Picture.visible = tex != null
	if tex:
		var aspect := float(tex.get_width()) / maxf(tex.get_height(), 1)
		(%Picture.mesh as QuadMesh).size = Vector2(0.2, 0.2 / aspect) if aspect >= 1.0 else Vector2(0.2 * aspect, 0.2)
		(%Picture.material_override as StandardMaterial3D).albedo_texture = tex
	%Preview.visible = tex == null
	%Preview.set_text("" if tex else str(data.get("preview", "")))
	%Info.text = "%s · %s · trigger: save" % [mime.get_slice("/", 1).substr(0, 20), Files.human_size(int(data.get("size", 0)))]
	var family := "other"
	if Files.is_image(mime) or mime == "image/svg+xml":
		family = "image"
	elif mime == "application/pdf":
		family = "pdf"
	elif Files.is_text(mime):
		family = "text"
	elif mime.contains("officedocument"):
		family = "office"
	%Tab.material_override = Mk.mat(Color(TAB_COLORS[family]))


func server_use(peer: int) -> void:
	Files.server_send_to(peer, int(data.get("file_id", 0)))
