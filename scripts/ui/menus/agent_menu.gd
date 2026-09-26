extends RadialMenu
## Context menu for an AI agent (scenes/ui/menus/agent_menu.tscn): mute its
## voice or turn point-to-talk off for it (both just for you, remembered by
## its name), or delete it (admins; asks to confirm).


func _agent_id() -> int:
	return int(target.get("entity_id", 0))


func _title() -> String:
	var a: NetBody = Sync.entities.get(_agent_id())
	return "%s (AI)" % a.data.get("name", "Agent") if a else "AI agent"


func _root_items() -> Array:
	var id := _agent_id()
	var muted := Voice.is_agent_muted(id)
	var listens := Voice.agent_listens(id)
	return [
		{"label": "Unmute" if muted else "Mute", "do": func():
			Voice.set_agent_muted(id, not muted)
			Net.toast.emit("%s (only for you)." % ("Unmuted" if muted else "Muted: you won't hear its voice"))
			refresh(_root_items())},
		{"label": "Point-to-talk: off" if not listens else "Point-to-talk: on", "color": NEUTRAL if not listens else ACTION, "do": func():
			Voice.set_agent_listens(id, not listens)
			Net.toast.emit("Pointing at it %s (only for you)." % ("talks to it again" if not listens else "no longer talks to it"))
			refresh(_root_items())},
		{"label": "Delete", "color": DANGER, "enabled": Net.my_can("agents"), "why": "Only admins can delete AI agents.",
				"sub": func(): return confirm("Delete agent", func(): Office.request_action("delete", {"entity": id}))},
	]
