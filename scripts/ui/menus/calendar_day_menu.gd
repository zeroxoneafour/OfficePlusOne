extends RadialMenu
## One day of a wall calendar (scenes/ui/menus/calendar_day_menu.tscn), opened
## by poking the day: its entries (pick one to remove it) and Add… (type
## "14:30 Team sync" on the keyboard; leave the time off for all day).


func _calendar() -> CalendarWidget:
	return Sync.entities.get(int(target.get("entity_id", 0))) as CalendarWidget


func _date() -> String:
	return str(target.get("date", ""))


func _title() -> String:
	var c := _calendar()
	var d := _date()
	return "%s · %s %d" % [c.widget_name() if c else "Calendar", CalendarWidget.MONTHS[int(d.substr(5, 2)) - 1], int(d.substr(8, 2))]


func _root_items() -> Array:
	var c := _calendar()
	if not c:
		return []
	var id := c.entity_id
	var date := _date()
	var items := [{"label": "Add…", "color": Color("#4caf50"), "do": func():
		close()
		player.open_keyboard("%s: time and note, e.g. 14:30 Team sync" % date, "", func(t: String):
			var parts := CalendarWidget.split_time_text(t)
			if str(parts[1]) != "":
				Widgets.request_op(id, "add_entry", {"date": date, "time": parts[0], "text": parts[1]}))}]
	for e in c.entries_on(date).slice(0, 9):
		var entry: Dictionary = e
		var label := ("%s %s" % [entry.get("time", ""), entry.get("text", "")]).strip_edges()
		items.append({"label": label.substr(0, 28), "color": CalendarWidget.BUSY, "sub": func():
			return confirm("Remove this entry", func():
				Widgets.request_op(id, "remove_entry", {"date": date, "time": entry.get("time", ""), "text": entry.get("text", "")}))})
	return items
