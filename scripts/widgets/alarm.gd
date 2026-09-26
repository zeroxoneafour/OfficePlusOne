class_name AlarmWidget extends Widget
## A wall alarm clock (scenes/widgets/alarm.tscn): the alarm time in big
## digits, the current time, ±1 h / ±5 min buttons, On/Off and Stop. Set… in
## its menu types an exact time. When it goes off it flashes and beeps for
## everyone until someone presses Stop (or a minute passes). Times are the
## host's local time. AIs set it with widget_alarm.
## data: {time: "HH:MM", enabled: bool, ringing: bool, fired: "YYYY-MM-DD HH:MM"}

const RING_SECONDS := 60.0
const RING_COLOR := Color("#e05050")

var _ring_left := 0.0
var _flash := 0.0
var _beep: AudioStreamPlayer3D


func _widget_build() -> void:
	%HourUp.pressed.connect(func(): Widgets.request_op(entity_id, "adjust", {"minutes": 60}))
	%HourDown.pressed.connect(func(): Widgets.request_op(entity_id, "adjust", {"minutes": -60}))
	%MinUp.pressed.connect(func(): Widgets.request_op(entity_id, "adjust", {"minutes": 5}))
	%MinDown.pressed.connect(func(): Widgets.request_op(entity_id, "adjust", {"minutes": -5}))
	%Toggle.pressed.connect(func(): Widgets.request_op(entity_id, "toggle"))
	%Stop.pressed.connect(func(): Widgets.request_op(entity_id, "stop"))
	_beep = AudioStreamPlayer3D.new()
	_beep.stream = _make_beep()
	_beep.unit_size = 6.0
	add_child(_beep)
	_refresh()


func _widget_data(key: String, _value: Variant) -> void:
	if key in ["time", "enabled", "ringing"] and is_node_ready():
		_refresh()


func alarm_time() -> String:
	var t := str(data.get("time", ""))
	return t if t.length() == 5 else "07:00"


func is_enabled() -> bool:
	return data.get("enabled", false) == true


func is_ringing() -> bool:
	return data.get("ringing", false) == true


func _refresh() -> void:
	if not _beep:
		return
	%Time.text = alarm_time()
	%Time.modulate = Color.WHITE if is_enabled() else Color(1, 1, 1, 0.35)
	%Toggle.color = Color("#555a66") if is_enabled() else Color("#4caf50")
	%Toggle.set_text("Turn off" if is_enabled() else "Turn on")
	%Stop.visible = is_ringing()
	%Stop.set_deferred("monitoring", is_ringing())
	%State.text = "RINGING" if is_ringing() else ("alarm on" if is_enabled() else "alarm off")
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
	var t := Time.get_time_dict_from_system()
	%Clock.text = "now %02d:%02d" % [t["hour"], t["minute"]]
	if is_ringing():
		_flash += delta
		%Face.material_override = Mk.mat(RING_COLOR) if fmod(_flash, 0.6) < 0.3 else null


func widget_menu_items(menu: RadialMenu) -> Array:
	var id := entity_id
	var items := [{"label": "Set time…", "do": func():
		var current := alarm_time()
		menu.close()
		menu.player.open_keyboard("Alarm time, e.g. 07:30 or 2:15pm", current,
				func(t: String): Widgets.request_op(id, "set_time", {"time": t}))}]
	items.append({"label": "Turn off" if is_enabled() else "Turn on", "do": func():
		Widgets.request_op(id, "toggle")
		menu.close()})
	if is_ringing():
		items.append({"label": "Stop", "color": RING_COLOR, "do": func():
			Widgets.request_op(id, "stop")
			menu.close()})
	return items


# --- Operations ---------------------------------------------------------------------------

func op_perm(op: String) -> String:
	return "interact" if op in ["set_time", "adjust", "toggle", "stop"] else ""


func server_op(peer: int, op: String, args: Dictionary) -> String:
	match op:
		"set_time":
			return server_set(str(args.get("time", "")), peer)
		"adjust":
			var parts := alarm_time().split(":")
			var total := posmod(int(parts[0]) * 60 + int(parts[1]) + int(args.get("minutes", 0)), 24 * 60)
			_set_time("%02d:%02d" % [total / 60, total % 60])
			Sync.set_data(entity_id, "enabled", true)
		"toggle":
			Sync.set_data(entity_id, "enabled", not is_enabled())
			if is_ringing():
				_stop()
		"stop":
			_stop()
	return ""


## Server: set the alarm to `time` ("HH:MM", "2:30pm"…) and turn it on, or
## "off" to turn it off. Returns "Error: …" or a confirmation.
func server_set(time: String, by := 0) -> String:
	if time.strip_edges().to_lower() in ["off", "none", "disable", "disabled"]:
		Sync.set_data(entity_id, "enabled", false)
		_stop()
		AI.widget_note("%s turned alarm \"%s\" off." % [Widgets._who(by), widget_name()])
		return "Alarm %s is off." % widget_name()
	var t := CalendarWidget.normalize_time(time)
	if t == "" or t == "!":
		return "Error: the time must look like 07:30 or 2:15pm (or \"off\")."
	_set_time(t)
	Sync.set_data(entity_id, "enabled", true)
	AI.widget_note("%s set alarm \"%s\" for %s." % [Widgets._who(by), widget_name(), t])
	return "Alarm %s set for %s." % [widget_name(), t]


func _set_time(t: String) -> void:
	Sync.set_data(entity_id, "time", t)
	Sync.set_data(entity_id, "fired", "") # a changed time may go off again today


func _stop() -> void:
	_ring_left = 0.0
	if is_ringing():
		Sync.set_data(entity_id, "ringing", false)


func server_tick(now: Dictionary) -> void:
	if is_ringing():
		_ring_left -= 1.0
		if _ring_left <= 0.0:
			_stop()
		return
	var hm := "%02d:%02d" % [now["hour"], now["minute"]]
	var stamp := "%04d-%02d-%02d %s" % [now["year"], now["month"], now["day"], hm]
	if is_enabled() and hm == alarm_time() and str(data.get("fired", "")) != stamp:
		Sync.set_data(entity_id, "fired", stamp)
		Sync.set_data(entity_id, "ringing", true)
		_ring_left = RING_SECONDS
		AI.widget_note("Alarm \"%s\" went off (%s)." % [widget_name(), hm])


func ai_summary() -> String:
	return "set for %s, %s%s" % [alarm_time(), "on" if is_enabled() else "off", ", RINGING now" if is_ringing() else ""]


## Two short beeps and a pause, looped.
static func _make_beep() -> AudioStreamWAV:
	var rate := 22050
	var pcm := PackedByteArray()
	pcm.resize(rate * 2) # 1 s of 16-bit mono
	for i in rate:
		var t := float(i) / rate
		var on := t < 0.12 or (t > 0.2 and t < 0.32)
		var v := int(sin(t * TAU * 880.0) * 9000.0) if on else 0
		pcm.encode_s16(i * 2, v)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = pcm
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_end = rate
	return w
