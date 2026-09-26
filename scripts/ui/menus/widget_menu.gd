extends RadialMenu
## Context menu for a wall widget (scenes/ui/menus/widget_menu.tscn): rename it
## with the keyboard, the widget's own settings (set an alarm, connect a TV…),
## or remove it.


func _widget() -> Widget:
	return Sync.entities.get(int(target.get("entity_id", 0))) as Widget


func _title() -> String:
	var w := _widget()
	return "%s · %s" % [w.widget_name(), Widgets.KINDS[w.kind]["label"]] if w else "Widget"


func _root_items() -> Array:
	var w := _widget()
	if not w:
		return []
	var id := w.entity_id
	var items := [{"label": "Rename…", "do": func():
		var current := w.widget_name()
		close()
		player.open_keyboard("Name this %s" % Widgets.KINDS[w.kind]["label"].to_lower(), current,
				func(t: String): Widgets.request_op(id, "rename", {"name": t}))}]
	items.append_array(w.widget_menu_items(self))
	items.append({"label": "Remove", "color": DANGER, "enabled": Net.my_can("decorate"), "why": "Only admins can remove widgets here.",
			"sub": func(): return confirm("Remove it", func(): Widgets.request_op(id, "remove"))})
	return items
