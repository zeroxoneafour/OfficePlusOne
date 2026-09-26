extends RadialMenu
## Context menu for a spot on a wall (scenes/ui/menus/wall_menu.tscn): hang a
## widget there (calendar, alarm, timer, whiteboard, TV), repaint this wall or all of
## them, or teleport to it.

const WIDGETS := [["Calendar", "calendar"], ["Alarm", "alarm"], ["Timer", "timer"], ["Whiteboard", "whiteboard"], ["TV", "tv"]]


func _title() -> String:
	return "%s wall" % str(target.get("surface", "")).capitalize()


func _root_items() -> Array:
	var admin_only := "Only admins can repaint the office."
	return [
		{"label": "Add widget", "sub": _widget_items, "enabled": Net.my_can("spawn"), "why": "Adding widgets is limited to admins here."},
		{"label": "Wall color", "sub": _color_items.bind(str(target.get("surface", ""))), "enabled": Net.my_can("decorate"), "why": admin_only},
		{"label": "All walls", "sub": _color_items.bind("walls"), "enabled": Net.my_can("decorate"), "why": admin_only},
		{"label": "Teleport here", "do": func():
			var n: Vector3 = Widgets.wall_normal(str(target.get("surface", "")))
			player.teleport_to_point(target["point"] + n * 0.7)
			close()},
	]


func _widget_items() -> Array:
	var items := []
	for w in WIDGETS:
		var kind: String = w[1]
		items.append({"label": w[0], "do": func():
			Widgets.request_add(kind, str(target.get("surface", "")), target["point"])
			close()})
	return items


## Stays open so you can try colors.
func _color_items(surface: String) -> Array:
	var items := []
	for c in Office.PALETTE:
		var color: String = c
		items.append({"label": "", "color": Color(color), "do": func(): Office.request_action("paint", {"surface": surface, "color": color})})
	return items
