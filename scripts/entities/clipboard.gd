class_name Clipboard extends NetBody
## A handheld page stack (scenes/entities/clipboard.tscn) that AIs and people
## pass around. Pull the trigger while holding it to flip pages.
## data: {title, pages: [{text, image}], page}


func _build() -> void:
	Sync.image_added.connect(_on_image_added) # (a method: disconnects itself when this is deleted)


func _on_image_added(_id: int) -> void:
	_refresh()


func _data_changed(key: String, _value: Variant) -> void:
	if key in ["title", "pages", "page"]:
		_refresh()


func _refresh() -> void:
	var pages: Array = data.get("pages", [])
	var page: int = clampi(int(data.get("page", 0)), 0, maxi(pages.size() - 1, 0))
	%Title.text = str(data.get("title", ""))
	var p: Dictionary = pages[page] if page < pages.size() and pages[page] is Dictionary else {}
	var text := str(p.get("text", "")) # (scrolls if it's long)
	var tex: Texture2D = Sync.images.get(int(p.get("image", 0)))
	%Picture.visible = tex != null
	if tex:
		(%Picture.material_override as StandardMaterial3D).albedo_texture = tex
	%Body.visible = text != "" or tex == null
	%Body.set_text(text)
	%Footer.text = "page %d / %d   (trigger: next)" % [page + 1, pages.size()] if pages.size() > 1 else ""


func server_use(_peer: int) -> void:
	var pages: Array = data.get("pages", [])
	if pages.size() > 1:
		Sync.set_data(entity_id, "page", (int(data.get("page", 0)) + 1) % pages.size())
