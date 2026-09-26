extends RadialMenu
## Context menu for an interactable object (scenes/ui/menus/object_menu.tscn):
## its own items (a monitor's Connect…, a drawer's Open / Set folder…), lock it
## in place / unlock it (admins, or members if allowed), or delete it
## (admins). The server checks too.


func _entity() -> NetBody:
	return Sync.entities.get(int(target.get("entity_id", 0)))


func _title() -> String:
	var e := _entity()
	if not e:
		return "Object"
	return str(e.data.get("name", e.data.get("title", e.kind.capitalize())))


func _root_items() -> Array:
	var e := _entity()
	var locked := e != null and e.is_locked()
	var items: Array = e.menu_items(self) if e else []
	if e and e.grabbable():
		items.push_front(grab_item(e))
		items.append(rotate_item(e))
	return items + [
		{"label": "Unlock" if locked else "Lock in place", "enabled": Net.my_can("lock"),
				"why": "Locking and unlocking is limited to admins here.", "do": func():
			Office.request_action("lock", {"entity": int(target["entity_id"])})
			close()},
		{"label": "Delete", "color": DANGER, "enabled": Net.my_can("decorate"), "why": "Only admins can delete objects here.",
				"sub": func(): return confirm("Delete it", func(): Office.request_action("delete", {"entity": int(target["entity_id"])}))},
	]
