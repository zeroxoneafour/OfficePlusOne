extends RadialMenu
## Context menu for a spot on the floor or a seat (scenes/ui/menus/floor_menu.tscn):
## go there (or sit), add an object or a new AI right there, or summon an AI.


func _title() -> String:
	return "This seat" if target.get("type") == "seat" else "This spot"


func _root_items() -> Array:
	var items := []
	if target.get("type") == "seat":
		items.append({"label": "Sit here", "do": func():
			Office.request_action("sit", {"entity": int(target["entity_id"])})
			close()})
	items.append({"label": "Teleport here", "do": func():
		player.teleport_to_point(target["point"])
		close()})
	items.append({"label": "Add", "sub": _add_items, "enabled": Net.my_can("spawn") or Net.my_can("agents"),
			"why": "Adding things is limited to admins here."})
	var agents := Sync.entities_of_kind("agent")
	items.append({"label": "Summon AI", "sub": _agent_items, "enabled": not agents.is_empty(), "why": "There are no AI agents yet."})
	if target.get("type") == "seat":
		# A chair is also an object: lock / delete it like any other.
		var chair: NetBody = Sync.entities.get(int(target["entity_id"]))
		var locked := chair != null and chair.is_locked()
		if chair:
			items.append(grab_item(chair))
			items.append(rotate_item(chair))
		items.append({"label": "Unlock" if locked else "Lock in place", "enabled": Net.my_can("lock"),
				"why": "Locking and unlocking is limited to admins here.", "do": func():
					Office.request_action("lock", {"entity": int(target["entity_id"])})
					close()})
		items.append({"label": "Delete", "color": DANGER, "enabled": Net.my_can("decorate"), "why": "Only admins can delete objects here.",
				"sub": func(): return confirm("Delete it", func(): Office.request_action("delete", {"entity": int(target["entity_id"])}))})
	return items


const ADD := [["Chair", "chair"], ["Table", "table"], ["Plant", "plant"], ["Lamp", "lamp"],
		["Monitor", "monitor"], ["Drawers", "drawer"]]


## Objects appear where the ray hit the floor (furniture arrives locked); the
## menu closes once one is added.
func _add_items() -> Array:
	var items := []
	var can_spawn := Net.my_can("spawn")
	for a in ADD:
		var kind: String = a[1]
		items.append({"label": a[0], "enabled": can_spawn, "why": "Adding objects is limited to admins here.",
				"do": func():
					Office.request_action("spawn", {"kind": kind, "point": target["point"]})
					close()})
	items.append({"label": "New AI", "color": SUBMENU, "enabled": Net.my_can("agents"), "why": "Adding AIs is limited to admins here.",
			"do": func():
				Office.request_action("spawn", {"kind": "agent", "point": target["point"]})
				close()})
	return items


func _agent_items() -> Array:
	var items := []
	for a in Sync.entities_of_kind("agent"):
		var agent_id: int = a.entity_id
		items.append({"label": str(a.data.get("name", "AI")), "do": func():
			Office.request_action("summon_to", {"agent": agent_id, "point": target["point"],
					"chair": int(target.get("entity_id", 0)) if target.get("type") == "seat" else 0})
			close()})
	return items
