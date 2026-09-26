extends RadialMenu
## The watch's Me menu (scenes/ui/menus/personal_menu.tscn): mute yourself to
## other people, show/hide your pointer rays and the target highlight, pick
## your dominant hand (the one that points; the watch and inventory go on the
## other arm), answer
## "come over" requests, bring files in from your inbox, switch to another
## office, or close the app. The toggles are remembered.


func _title() -> String:
	return "Me"


func _root_items() -> Array:
	var summons := Net.prompts_of("summon")
	return [
		{"label": "Unmute me" if Voice.muted else "Mute me", "do": func():
			Voice.set_muted(not Voice.muted)
			Net.toast.emit("Others can't hear you." if Voice.muted else "Others can hear you.")
			refresh(_root_items())},
		{"label": "Rays off" if player.rays_visible() else "Rays on", "do": func():
			player.set_rays_visible(not player.rays_visible())
			refresh(_root_items())},
		{"label": "Highlight off" if player.highlight.enabled else "Highlight on", "do": func():
			player.set_highlight_enabled(not player.highlight.enabled)
			refresh(_root_items())},
		{"label": "Dominant hand: %s" % ("right" if player.dominant == 1 else "left"), "do": func():
			player.set_dominant(1 - player.dominant)
			Net.toast.emit("You point with your %s hand; the watch and inventory are on your %s arm." % [
					"right" if player.dominant == 1 else "left", "left" if player.dominant == 1 else "right"])
			close()},
		{"label": "Requests (%d)" % summons.size() if summons.size() else "Requests", "sub": _request_items,
				"enabled": not summons.is_empty(), "why": "No requests right now."},
		{"label": "Import files", "do": func():
			Files.import_inbox()
			close()},
		{"label": "Switch room", "sub": _room_items},
		{"label": "Close app", "color": DANGER, "sub": func(): return confirm("Quit", _quit)},
	]


## "Come over" requests: accept (you're teleported to them) or decline.
func _request_items() -> Array:
	var items := []
	for p in Net.prompts_of("summon"):
		var id: int = p[0]
		var who: String = str(p[1]).get_slice("\n", 0).get_slice(" would", 0)
		items.append({"label": who, "sub": func(): return [
			{"label": "Go to them", "do": func():
				Net.answer_prompt(id, true)
				close()},
			{"label": "Decline", "color": DANGER, "do": func():
				Net.answer_prompt(id, false)
				home()},
		]})
	return items


func _room_items() -> Array:
	var items := [
		{"label": "My office", "enabled": Net.mode != "host" or Net.tutorial, "why": "You're already in your office.", "do": func():
			_leave_then(func(): Net.host(false))},
		{"label": "Lobby", "do": func(): _leave_then(Callable())},
	]
	for sv in Net.other_servers().slice(0, 6):
		var ip: String = sv["ip"]
		var port: int = sv["port"]
		items.append({"label": "%s%s" % [sv["name"], " ✓" if sv["invited"] else ""], "do": func():
			_leave_then(func(): Net.join(ip, port))})
	return items


## Close the menu first, then leave this office (and optionally go elsewhere).
func _leave_then(next: Callable) -> void:
	close()
	var go := func():
		Net.leave("")
		if next.is_valid():
			next.call()
	go.call_deferred()


func _quit() -> void:
	var tree := get_tree()
	var go := func():
		Net.leave("")
		tree.quit()
	go.call_deferred()
