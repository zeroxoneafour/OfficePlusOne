class_name TimerWidget extends Widget
## A wall countdown timer (scenes/widgets/timer.tscn): minutes and seconds
## left in big digits, ±1 min / ±10 s buttons, Start, Stop and Reset, and
## Set… in its menu to type a time (5:00, 90, 1m30s). When it reaches zero it
## flashes and beeps for everyone until someone presses Stop (or a minute
## passes). AIs set it with widget_timer, which also resets and starts it.
## data: {duration: s, remaining: s (while stopped), running: bool,
##        ends_at: server clock (Sync.server_now) while running, ringing: bool}

const RING_SECONDS := 60.0
const RING_COLOR := Color("#e05050")
const MAX_SECONDS := 24 * 3600 - 1

var _ring_left := 0.0
var _flash := 0.0
var _beep: AudioStreamPlayer3D


func _widget_build() -> void:
	%MinUp.pressed.connect(func(): Widgets.request_op(entity_id, "adjust", {"seconds": 60}))
	%MinDown.pressed.connect(func(): Widgets.request_op(entity_id, "adjust", {"seconds": -60}))
	%SecUp.pressed.connect(func(): Widgets.request_op(entity_id, "adjust", {"seconds": 10}))
	%SecDown.pressed.connect(func(): Widgets.request_op(entity_id, "adjust", {"seconds": -10}))
	%Start.pressed.connect(func(): Widgets.request_op(entity_id, "start"))
	%Stop.pressed.connect(func(): Widgets.request_op(entity_id, "stop"))
	%Reset.pressed.connect(func(): Widgets.request_op(entity_id, "reset"))
	_beep = AudioStreamPlayer3D.new()
	_beep.stream = AlarmWidget._make_beep()
	_beep.unit_size = 6.0
	add_child(_beep)
	_refresh()


func _widget_data(key: String, _value: Variant) -> void:
	if key in ["running", "ringing", "duration", "remaining", "ends_at"] and is_node_ready():
		_refresh()


func duration() -> int:
	return int(data.get("duration", 300))


func is_running() -> bool:
	return data.get("running", false) == true


func is_ringing() -> bool:
	return data.get("ringing", false) == true


## Seconds left (counting down live while running).
func time_left() -> float:
	if is_running():
		return maxf(float(data.get("ends_at", 0.0)) - Sync.server_now(), 0.0)
	return maxf(float(data.get("remaining", duration())), 0.0)


static func format_time(seconds: float) -> String:
	var s := ceili(seconds)
	return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60] if s >= 3600 else "%02d:%02d" % [s / 60, s % 60]


## "5:00", "1:02:03", "90", "90s", "2m", "1m30s", "1h5m" -> seconds, or -1.
static func parse_time(text: String) -> int:
	var t := text.strip_edges().to_lower().replace(" ", "")
	if t == "":
		return -1
	if t.contains(":"):
		var total := 0
		for part in t.split(":"):
			if not part.is_valid_int():
				return -1
			total = total * 60 + int(part)
		return total
	if t.is_valid_int():
		return int(t)
	var total := 0
	var num := ""
	for ch in t:
		if ch.is_valid_int():
			num += ch
		elif ch in "hms" and num != "":
			total += int(num) * {"h": 3600, "m": 60, "s": 1}[ch]
			num = ""
		else:
			return -1
	return total if num == "" else -1


func _refresh() -> void:
	if not _beep:
		return
	%State.text = "TIME'S UP" if is_ringing() else ("running" if is_running() else ("paused" if time_left() < duration() and time_left() > 0 else "ready"))
	%Start.set_enabled(not is_running() and time_left() > 0)
	%Stop.set_enabled(is_running() or is_ringing())
	if is_ringing() and Net.has_local_player():
		if not _beep.playing:
			_beep.play()
	else:
		_beep.stop()
		%Face.material_override = null


func _process(delta: float) -> void:
	super(delta)
	if not is_node_ready():
		return
	%Time.text = format_time(time_left())
	if is_ringing():
		_flash += delta
		%Face.material_override = Mk.mat(RING_COLOR) if fmod(_flash, 0.6) < 0.3 else null
	if is_server_side:
		if is_running() and Sync.server_now() >= float(data.get("ends_at", 0.0)):
			_server_finish()
		elif is_ringing():
			_ring_left -= delta
			if _ring_left <= 0.0:
				Sync.set_data(entity_id, "ringing", false)


func widget_menu_items(menu: RadialMenu) -> Array:
	var id := entity_id
	return [
		{"label": "Set time…", "do": func():
			var current := format_time(duration())
			menu.close()
			menu.player.open_keyboard("Timer length, e.g. 5:00, 90s or 1m30s", current,
					func(t: String): Widgets.request_op(id, "set", {"time": t}))},
		{"label": "Stop" if is_running() or is_ringing() else "Start", "do": func():
			Widgets.request_op(id, "stop" if is_running() or is_ringing() else "start")
			menu.close()},
		{"label": "Reset", "do": func():
			Widgets.request_op(id, "reset")
			menu.close()},
	]


# --- Operations ---------------------------------------------------------------------------

func op_perm(op: String) -> String:
	return "interact" if op in ["set", "adjust", "start", "stop", "reset"] else ""


func server_op(peer: int, op: String, args: Dictionary) -> String:
	match op:
		"set":
			var secs := parse_time(str(args.get("time", "")))
			if secs <= 0 or secs > MAX_SECONDS:
				return "Error: the time must look like 5:00, 90s or 1m30s."
			server_set(secs, false, peer)
		"adjust":
			var by := int(args.get("seconds", 0))
			var d := clampi(duration() + by, 0, MAX_SECONDS)
			Sync.set_data(entity_id, "duration", d)
			if is_running():
				Sync.set_data(entity_id, "ends_at", maxf(float(data.get("ends_at", 0.0)) + by, Sync.server_now()))
			else:
				Sync.set_data(entity_id, "remaining", clampf(time_left() + by, 0.0, MAX_SECONDS))
		"start":
			server_start()
		"stop":
			server_stop()
		"reset":
			server_stop()
			Sync.set_data(entity_id, "remaining", float(duration()))
	return ""


## Server: set the length to `seconds` and reset; `start` it straight away if asked.
func server_set(seconds: int, start: bool, by := 0) -> String:
	server_stop()
	Sync.set_data(entity_id, "duration", clampi(seconds, 1, MAX_SECONDS))
	Sync.set_data(entity_id, "remaining", float(clampi(seconds, 1, MAX_SECONDS)))
	if start:
		server_start()
	AI.widget_note("%s set timer \"%s\" to %s%s." % [Widgets._who(by), widget_name(), format_time(seconds), " and started it" if start else ""])
	return "Timer %s set to %s%s." % [widget_name(), format_time(seconds), " and started" if start else ""]


func server_start() -> void:
	if is_ringing():
		Sync.set_data(entity_id, "ringing", false)
	var left := time_left()
	if is_running() or left <= 0.0:
		return
	Sync.set_data(entity_id, "ends_at", Sync.server_now() + left)
	Sync.set_data(entity_id, "running", true)


## Server: pause (keeping the time left) and silence it if it's ringing.
func server_stop() -> void:
	if is_running():
		Sync.set_data(entity_id, "remaining", time_left())
		Sync.set_data(entity_id, "running", false)
	if is_ringing():
		Sync.set_data(entity_id, "ringing", false)


func _server_finish() -> void:
	Sync.set_data(entity_id, "remaining", 0.0)
	Sync.set_data(entity_id, "running", false)
	Sync.set_data(entity_id, "ringing", true)
	_ring_left = RING_SECONDS
	AI.widget_note("Timer \"%s\" (%s) ran out." % [widget_name(), format_time(duration())])


## Saved paused, with the time that was left (the server clock restarts).
func saved_data() -> Dictionary:
	var d := data.duplicate(true)
	if is_running():
		d["remaining"] = time_left()
		d["running"] = false
	d.erase("ends_at")
	return d


func ai_summary() -> String:
	return "%s left of %s, %s" % [format_time(time_left()), format_time(duration()),
			"RINGING now (time's up)" if is_ringing() else ("running" if is_running() else "stopped")]
