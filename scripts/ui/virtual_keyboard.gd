class_name VirtualKeyboard extends Node3D
## A floating, reusable text-entry keyboard (scenes/ui/virtual_keyboard.tscn).
## Keys are physical buttons: poke them with a fingertip, point and pinch /
## pull the trigger, or click them on desktop — where the real keyboard types
## into it too (Enter = Done, Esc = Cancel).
##
## Use it from anywhere:
##     VirtualKeyboard.open(parent, where, "Name this save", "", func(text): …)
## `submitted(text)` / `cancelled` are also emitted; the keyboard frees itself.
##
## Live mode (open_live) sends every key as it's pressed instead, for typing
## on a remote computer: `key_pressed(key)` with a character or a key name
## ("Return", "BackSpace", "Tab", "Escape", "Left", "Up", "Right", "Down"), and
## an extra row of those keys. Done closes it.

signal submitted(text: String)
signal cancelled
signal key_pressed(key: String)

const SCENE_PATH := "res://scenes/ui/virtual_keyboard.tscn"
const ROWS := ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
## The letter rows' keys on the symbols page (#+=), for addresses and paths.
const SYMBOL_ROWS := ["1234567890", "/:._-@~#&%", "()[]{}!?=", "+*$,;\"\\"]
const KEY := 0.05
const GAP := 0.056
const SPECIAL := Color("#555a66")

## The keyboard currently taking input (only one at a time).
static var active: VirtualKeyboard

@export var max_length := 40
var prompt := ""
var text := ""
var _shift := false
var _symbols := false
var live := false
var _letter_keys: Array[PokeButton] = []
## Keys of the letter rows, in order (relabelled by the symbols page).
var _row_keys: Array[PokeButton] = []


## Open a keyboard at `where` (its +Z faces the user). `on_submit(text)` runs
## on Done. Any keyboard already open is cancelled.
static func open(parent: Node, where: Transform3D, prompt_text := "", initial := "", on_submit := Callable(), max_len := 40) -> VirtualKeyboard:
	if is_instance_valid(active):
		active.cancel()
	var kb: VirtualKeyboard = load(SCENE_PATH).instantiate()
	kb.prompt = prompt_text
	kb.text = initial.substr(0, max_len)
	kb.max_length = max_len
	if on_submit.is_valid():
		kb.submitted.connect(on_submit)
	parent.add_child(kb)
	kb.global_transform = where
	return kb


## A live keyboard: every key goes to `on_key(key)` as it's pressed.
static func open_live(parent: Node, where: Transform3D, prompt_text: String, on_key: Callable) -> VirtualKeyboard:
	if is_instance_valid(active):
		active.cancel()
	var kb: VirtualKeyboard = load(SCENE_PATH).instantiate()
	kb.prompt = prompt_text
	kb.live = true
	kb.max_length = 60 # (only the echo of what was typed)
	kb.key_pressed.connect(on_key)
	parent.add_child(kb)
	kb.global_transform = where
	return kb


static func is_open() -> bool:
	return is_instance_valid(active)


func _ready() -> void:
	active = self
	# Make a fist on it to move it.
	GrabHandle.make_drag(self, Vector3(0.68, 0.44, 0.1), Vector3(0, 0, 0.0), true)
	%Prompt.text = prompt
	var y := 0.045
	for r in ROWS.size():
		var row: String = ROWS[r]
		var x0 := -(row.length() - 1) * GAP * 0.5 + r * 0.012 # slight stagger, like a real keyboard
		for i in row.length():
			var ch := row[i]
			var key := _key(ch, Vector3(x0 + i * GAP, y, 0), Color("#3d85c6"))
			key.pressed.connect(func(): type_text(key.text))
			if ch.to_upper() != ch:
				_letter_keys.append(key)
			if r > 0:
				_row_keys.append(key)
		y -= GAP
	# Bottom row: Shift, symbols, - ' , space, backspace, Cancel, Done.
	var bottom := [["Shift", 0.08, SPECIAL, _toggle_shift], ["#+=", 0.07, SPECIAL, _toggle_symbols], ["-", KEY, Color("#3d85c6"), type_text.bind("-")],
			["'", KEY, Color("#3d85c6"), type_text.bind("'")], ["space", 0.1, Color("#3d85c6"), type_text.bind(" ")],
			["Del", 0.07, SPECIAL, backspace], ["Cancel", 0.08, Color("#c0504d"), cancel], ["Done", 0.08, Color("#4caf50"), submit]]
	var total := 0.0
	for b in bottom:
		total += b[1] + (GAP - KEY)
	var x := -total * 0.5
	for b in bottom:
		var w: float = b[1]
		var key := _key(b[0], Vector3(x + w * 0.5, y, 0), b[2], w)
		key.pressed.connect(b[3])
		x += w + (GAP - KEY)
	if live:
		# Keys a text field doesn't need but a computer does.
		y -= GAP
		var special := [["Enter", "Return", 0.1], ["Tab", "Tab", 0.07], ["Esc", "Escape", 0.07],
				["Left", "Left", 0.06], ["Up", "Up", KEY], ["Down", "Down", 0.06], ["Right", "Right", 0.06]]
		total = 0.0
		for sp in special:
			total += sp[2] + (GAP - KEY)
		x = -total * 0.5
		for sp in special:
			var w: float = sp[2]
			var name_: String = sp[1]
			_key(sp[0], Vector3(x + w * 0.5, y, 0), SPECIAL, w).pressed.connect(func(): _send_key(name_))
			x += w + (GAP - KEY)
		# Room for the extra row.
		$Backing.scale.y = 0.46 / 0.4
		$Backing.position.y -= 0.03
	_show()


func _key(label: String, pos: Vector3, c: Color, width := KEY) -> PokeButton:
	var b: PokeButton = load(PokeButton.SCENE_PATH).instantiate()
	b.text = label
	b.color = c
	b.size = Vector2(width, KEY)
	b.label_size = 26
	b.position = pos
	%Keys.add_child(b)
	return b


func type_text(s: String) -> void:
	if s == "space":
		s = " "
	if live:
		for ch in (s.to_upper() if _shift and not _symbols else s):
			_send_key(ch)
		if _shift:
			_toggle_shift()
		return
	if text.length() + s.length() > max_length:
		return
	text += s.to_upper() if _shift and not _symbols else s
	if _shift:
		_toggle_shift() # one capital, like a phone keyboard
	_show()


func backspace() -> void:
	if live:
		_send_key("BackSpace")
		return
	text = text.substr(0, maxi(text.length() - 1, 0))
	_show()


## Live mode: send a key and echo it in the field.
func _send_key(key: String) -> void:
	key_pressed.emit(key)
	if key.length() == 1:
		text = (text + key).right(max_length)
	elif key == "BackSpace":
		text = text.substr(0, maxi(text.length() - 1, 0))
	elif key == "Return":
		text = ""
	_show()


func submit() -> void:
	if not is_inside_tree():
		return
	var t := text.strip_edges()
	_close()
	submitted.emit(t)


func cancel() -> void:
	if not is_inside_tree():
		return
	_close()
	cancelled.emit()


func _close() -> void:
	if active == self:
		active = null
	queue_free()


func _toggle_shift() -> void:
	_shift = not _shift
	if _symbols:
		return
	for k in _letter_keys:
		k.set_text(k.text.to_upper() if _shift else k.text.to_lower())


## Swap the letter rows for symbols (and back).
func _toggle_symbols() -> void:
	_symbols = not _symbols
	var chars := "".join(SYMBOL_ROWS.slice(1) if _symbols else ROWS.slice(1))
	for i in _row_keys.size():
		var ch := chars[i]
		_row_keys[i].set_text(ch.to_upper() if _shift and not _symbols else ch)


func _show() -> void:
	%Text.text = text + "|"


## Desktop: the physical keyboard types into the virtual one.
func _unhandled_input(event: InputEvent) -> void:
	if active != self or not event is InputEventKey or not event.pressed:
		return
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			if live:
				_send_key("Return")
			else:
				submit()
		KEY_ESCAPE:
			cancel()
		KEY_BACKSPACE:
			backspace()
		KEY_TAB when live:
			_send_key("Tab")
		KEY_LEFT when live:
			_send_key("Left")
		KEY_RIGHT when live:
			_send_key("Right")
		KEY_UP when live:
			_send_key("Up")
		KEY_DOWN when live:
			_send_key("Down")
		_:
			if event.unicode >= 32:
				var was_shift := _shift
				_shift = false
				type_text(char(event.unicode))
				_shift = was_shift
	get_viewport().set_input_as_handled()
