extends RadialMenu
## Context menu for another person (scenes/ui/menus/player_menu.tscn): ask them
## over, mute them or set their volume (just for you), make them an admin or
## member (owner), or kick them (admins, and only people ranked below you).

const VOLUMES := [0.25, 0.5, 1.0, 1.5, 2.0]


func _peer() -> int:
	return int(target.get("peer", 0))


func _title() -> String:
	return Net.player_name(_peer())


func _root_items() -> Array:
	var muted := Voice.is_player_muted(_peer())
	var can_kick := Net.my_can("admit") and Net.ROLES.find(Net.role(_peer())) < Net.ROLES.find(Net.role(Net.my_id()))
	return [
		{"label": "Unmute" if muted else "Mute", "do": func():
			Voice.set_player_muted(_peer(), not muted)
			Net.toast.emit("%s %s (only for you)." % [Net.player_name(_peer()), "unmuted" if muted else "muted"])
			close()},
		{"label": "Volume", "sub": _volume_items},
		{"label": "Ask over", "do": func():
			Office.request_action("call", {"peer": _peer()})
			close()},
		{"label": "Make member" if Net.role(_peer()) == "admin" else "Make admin",
				"enabled": Net.my_can("roles") and Net.role(_peer()) != "owner", "why": "Only the owner can change roles.",
				"do": func():
					Office.request_action("role", {"peer": _peer(), "role": "member" if Net.role(_peer()) == "admin" else "admin"})
					close()},
		{"label": "Kick", "color": DANGER, "enabled": can_kick, "why": "Only admins can remove people, and not the owner or other admins.",
				"sub": func(): return confirm("Kick %s" % Net.player_name(_peer()), func(): Office.request_action("kick", {"peer": _peer()}))},
	]


func _volume_items() -> Array:
	var items := []
	var current := Voice.player_volume(_peer())
	for v in VOLUMES:
		var vol: float = v
		items.append({"label": ("• %d%%" if is_equal_approx(vol, current) else "%d%%") % int(vol * 100), "do": func():
			Voice.set_player_volume(_peer(), vol)
			Voice.set_player_muted(_peer(), false)
			back()})
	return items
