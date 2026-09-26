class_name VncClient extends Node
## A VNC (RFB) viewer: connects to a VNC server and decodes the screen into
## `texture`. It never sends mouse input; keyboard input only when asked
## (send_key / type_text, used when a screen's keyboard is turned on).
##
## Speaks RFB 3.8 (also 3.7 / 3.3 servers), with no-password or VNC-password
## authentication, and the Raw and CopyRect encodings plus desktop resizes. It
## asks for 32-bit little-endian RGBX pixels, so a Raw rectangle's bytes go
## straight into an RGBA8 image; the screen's material is opaque, so the
## padding byte (alpha) doesn't matter. Everything runs in _process on a
## non-blocking socket.

signal status_changed(status: String)
signal frame_updated

const ENC_RAW := 0
const ENC_COPYRECT := 1
const ENC_DESKTOP_SIZE := -223
## Bytes read per frame at most (keeps a big first frame from stalling a VR frame).
const READ_BUDGET := 4 * 1024 * 1024
const CONNECT_TIMEOUT := 8.0

## Updates asked for per second at most.
@export var max_fps := 10.0

## "idle" | "connecting" | "connected" | "error: …"
var status := "idle"
var texture: ImageTexture
var desktop_size := Vector2i.ZERO
var desktop_name := ""

enum Stage { NONE, VERSION, SEC_TYPES, SEC_TYPE_33, CHALLENGE, SEC_RESULT, SEC_REASON, SERVER_INIT, RUNNING }

var _tcp: StreamPeerTCP
var _stage := Stage.NONE
var _buf := PackedByteArray()
var _pos := 0
var _password := ""
var _minor := 8
var _image: Image
var _dirty := false
var _connect_time := 0.0
var _since_request := 0.0
var _awaiting_update := false
## Rectangles left in the current FramebufferUpdate (0 = between messages).
var _rects_left := 0


func connect_to(host: String, port: int, password := "") -> void:
	disconnect_from()
	_password = password
	_tcp = StreamPeerTCP.new()
	if _tcp.connect_to_host(host, port) != OK:
		_fail("can't reach %s:%d" % [host, port])
		return
	_stage = Stage.VERSION
	_connect_time = 0.0
	_set_status("connecting")


func disconnect_from() -> void:
	if _tcp:
		_tcp.disconnect_from_host()
	_tcp = null
	_stage = Stage.NONE
	_buf = PackedByteArray()
	_pos = 0
	_rects_left = 0
	_awaiting_update = false
	if status != "idle" and not status.begins_with("error"):
		_set_status("idle")


func _set_status(s: String) -> void:
	if s != status:
		status = s
		status_changed.emit(s)


func _fail(why: String) -> void:
	disconnect_from()
	_set_status("error: " + why)


func _process(delta: float) -> void:
	if not _tcp:
		return
	_tcp.poll()
	var st := _tcp.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTING:
		_connect_time += delta
		if _connect_time > CONNECT_TIMEOUT:
			_fail("no answer (is the VNC server running and reachable?)")
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		_fail("connection lost" if _stage == Stage.RUNNING else "couldn't connect")
		return
	if _connect_time >= 0.0:
		_connect_time = -1.0 # connected: small messages (update requests) go out at once
		_tcp.set_no_delay(true)
	var avail := mini(_tcp.get_available_bytes(), READ_BUDGET)
	if avail > 0:
		var got := _tcp.get_data(avail)
		if got[0] != OK:
			_fail("connection lost")
			return
		_compact()
		_buf.append_array(got[1])
	while _tcp and _step():
		pass
	if _stage == Stage.RUNNING:
		_since_request += delta
		if not _awaiting_update and _since_request >= 1.0 / maxf(max_fps, 0.5):
			_request_update(true)
	if _dirty and texture:
		_dirty = false
		texture.update(_image)
		frame_updated.emit()


# --- Reading ------------------------------------------------------------------------

func _avail() -> int:
	return _buf.size() - _pos


func _compact() -> void:
	if _pos > 0:
		_buf = _buf.slice(_pos)
		_pos = 0


func _u8(at: int) -> int:
	return _buf[_pos + at]


func _u16(at: int) -> int:
	return (_buf[_pos + at] << 8) | _buf[_pos + at + 1]


func _u32(at: int) -> int:
	return (_buf[_pos + at] << 24) | (_buf[_pos + at + 1] << 16) | (_buf[_pos + at + 2] << 8) | _buf[_pos + at + 3]


func _s32(at: int) -> int:
	var v := _u32(at)
	return v - 0x100000000 if v >= 0x80000000 else v


func _take(n: int) -> PackedByteArray:
	var out := _buf.slice(_pos, _pos + n)
	_pos += n
	return out


func _send(bytes: PackedByteArray) -> void:
	if _tcp:
		_tcp.put_data(bytes)


static func _be16(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 8) & 255, v & 255])


static func _be32(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255])


## Handle one protocol step if enough bytes have arrived. Returns true to keep going.
func _step() -> bool:
	match _stage:
		Stage.VERSION:
			if _avail() < 12:
				return false
			var v := _take(12).get_string_from_ascii()
			if not v.begins_with("RFB "):
				_fail("that isn't a VNC server")
				return false
			var major := int(v.substr(4, 3))
			var minor := int(v.substr(8, 3))
			_minor = 3 if major == 3 and minor < 7 else (7 if major == 3 and minor == 7 else 8)
			_send(("RFB 003.%03d\n" % _minor).to_ascii_buffer())
			_stage = Stage.SEC_TYPE_33 if _minor == 3 else Stage.SEC_TYPES
		Stage.SEC_TYPES:
			if _avail() < 1:
				return false
			var n := _u8(0)
			if n == 0:
				_stage = Stage.SEC_REASON
				_pos += 1
				return true
			if _avail() < 1 + n:
				return false
			var types := _take(1 + n).slice(1)
			if 1 in types and _password == "":
				_choose_security(1)
			elif 2 in types:
				_choose_security(2)
			elif 1 in types:
				_choose_security(1)
			else:
				_fail("the server wants a login this viewer doesn't support (turn on plain VNC password auth)")
				return false
		Stage.SEC_TYPE_33:
			if _avail() < 4:
				return false
			var t := _u32(0)
			_pos += 4
			if t == 0:
				_stage = Stage.SEC_REASON
			elif t == 1:
				_client_init()
			elif t == 2:
				_stage = Stage.CHALLENGE
			else:
				_fail("unsupported security type %d" % t)
				return false
		Stage.CHALLENGE:
			if _avail() < 16:
				return false
			_send(VncDes.vnc_response(_password, _take(16)))
			_stage = Stage.SEC_RESULT
		Stage.SEC_RESULT:
			if _avail() < 4:
				return false
			var ok := _u32(0) == 0
			_pos += 4
			if ok:
				_client_init()
			elif _minor >= 8:
				_stage = Stage.SEC_REASON
			else:
				_fail("wrong password")
				return false
		Stage.SEC_REASON:
			if _avail() < 4 or _avail() < 4 + _u32(0):
				return false
			var n := _u32(0)
			_pos += 4
			var reason := _take(n).get_string_from_utf8()
			_fail(reason if reason != "" else "refused")
			return false
		Stage.SERVER_INIT:
			if _avail() < 24 or _avail() < 24 + _u32(20):
				return false
			var w := _u16(0)
			var h := _u16(2)
			var name_len := _u32(20)
			_pos += 24
			desktop_name = _take(name_len).get_string_from_utf8()
			_resize(w, h)
			_set_pixel_format()
			_set_encodings()
			_stage = Stage.RUNNING
			_set_status("connected")
			_request_update(false)
		Stage.RUNNING:
			return _read_message()
		_:
			return false
	return true


func _choose_security(t: int) -> void:
	_send(PackedByteArray([t]))
	if t == 2:
		_stage = Stage.CHALLENGE
	elif _minor >= 8:
		_stage = Stage.SEC_RESULT # 3.8 confirms even "no password"
	else:
		_client_init()


func _client_init() -> void:
	_send(PackedByteArray([1])) # shared: don't kick other viewers off
	_stage = Stage.SERVER_INIT


func _set_pixel_format() -> void:
	# 32 bpp, depth 24, little endian, true color, 8 bits each: R at bit 0, G at 8, B at 16.
	var msg := PackedByteArray([0, 0, 0, 0, 32, 24, 0, 1])
	msg.append_array(_be16(255))
	msg.append_array(_be16(255))
	msg.append_array(_be16(255))
	msg.append_array(PackedByteArray([0, 8, 16, 0, 0, 0]))
	_send(msg)


func _set_encodings() -> void:
	var encs := [ENC_COPYRECT, ENC_RAW, ENC_DESKTOP_SIZE]
	var msg := PackedByteArray([2, 0])
	msg.append_array(_be16(encs.size()))
	for e in encs:
		msg.append_array(_be32(e & 0xFFFFFFFF))
	_send(msg)


## X11 keysyms for named keys (everything printable is sent by character).
const KEYSYMS := {
	"Return": 0xff0d, "BackSpace": 0xff08, "Tab": 0xff09, "Escape": 0xff1b, "Delete": 0xffff,
	"Left": 0xff51, "Up": 0xff52, "Right": 0xff53, "Down": 0xff54, "Home": 0xff50, "End": 0xff57,
	"Page_Up": 0xff55, "Page_Down": 0xff56,
}


## The keysym for a named key ("Return", "Left"…) or a single character.
static func keysym_for(key: String) -> int:
	if KEYSYMS.has(key):
		return KEYSYMS[key]
	if key.length() != 1:
		return 0
	var c := key.unicode_at(0)
	if c == 10 or c == 13:
		return KEYSYMS["Return"]
	# Latin-1 characters are their own keysyms; the rest are 0x01000000 + code point.
	return c if (c >= 0x20 and c <= 0x7e) or (c >= 0xa0 and c <= 0xff) else 0x01000000 + c


## Press and release one key (see keysym_for). False if not connected.
func send_key(key: String) -> bool:
	var sym := keysym_for(key)
	if _stage != Stage.RUNNING or sym == 0:
		return false
	for down in [1, 0]:
		var msg := PackedByteArray([4, down, 0, 0])
		msg.append_array(_be32(sym))
		_send(msg)
	return true


## Type text, character by character.
func type_text(text: String) -> void:
	for ch in text:
		send_key(ch)


func _request_update(incremental: bool) -> void:
	var msg := PackedByteArray([3, 1 if incremental else 0])
	msg.append_array(_be16(0))
	msg.append_array(_be16(0))
	msg.append_array(_be16(desktop_size.x))
	msg.append_array(_be16(desktop_size.y))
	_send(msg)
	_awaiting_update = true
	_since_request = 0.0


func _resize(w: int, h: int) -> void:
	desktop_size = Vector2i(maxi(w, 1), maxi(h, 1))
	_image = Image.create(desktop_size.x, desktop_size.y, false, Image.FORMAT_RGBA8)
	texture = ImageTexture.create_from_image(_image)
	_dirty = false


## One server message (or one rectangle of a framebuffer update).
func _read_message() -> bool:
	if _rects_left > 0:
		return _read_rect()
	if _avail() < 1:
		return false
	match _u8(0):
		0: # FramebufferUpdate
			if _avail() < 4:
				return false
			_rects_left = _u16(2)
			_pos += 4
			if _rects_left == 0:
				_awaiting_update = false
			return true
		1: # SetColourMapEntries (not used with true color): skip
			if _avail() < 6 or _avail() < 6 + _u16(4) * 6:
				return false
			_pos += 6 + _u16(4) * 6
			return true
		2: # Bell
			_pos += 1
			return true
		3: # ServerCutText (clipboard): ignored
			if _avail() < 8 or _avail() < 8 + _u32(4):
				return false
			_pos += 8 + _u32(4)
			return true
	_fail("unexpected message %d from the server" % _u8(0))
	return false


func _read_rect() -> bool:
	if _avail() < 12:
		return false
	var x := _u16(0)
	var y := _u16(2)
	var w := _u16(4)
	var h := _u16(6)
	var enc := _s32(8)
	match enc:
		ENC_RAW:
			var n := w * h * 4
			if _avail() < 12 + n:
				return false
			_pos += 12
			var px := _take(n)
			if w > 0 and h > 0:
				_image.blit_rect(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px), Rect2i(0, 0, w, h), Vector2i(x, y))
				_dirty = true
		ENC_COPYRECT:
			if _avail() < 16:
				return false
			var sx := _u16(12)
			var sy := _u16(14)
			_pos += 16
			if w > 0 and h > 0:
				_image.blit_rect(_image.get_region(Rect2i(sx, sy, w, h)), Rect2i(0, 0, w, h), Vector2i(x, y))
				_dirty = true
		ENC_DESKTOP_SIZE:
			_pos += 12
			_resize(w, h)
			_status_refresh()
		_:
			_fail("the server used an encoding this viewer didn't ask for (%d)" % enc)
			return false
	_rects_left -= 1
	if _rects_left == 0:
		_awaiting_update = false
	return true


func _status_refresh() -> void:
	status_changed.emit(status) # size changed: let the screen refit
