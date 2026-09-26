class_name VoiceCapture extends Node
## Captures the microphone, downsamples to 16 kHz mono, mu-law encodes it and
## emits fixed-size packets gated by a simple RMS voice-activity detector.
##
## Muted-bus note: verified against Godot's engine source (servers/audio/
## audio_server.cpp) that AudioServer::_mix_step() runs all bus effects
## *before* applying the mute (mute just multiplies the already-processed
## buffer by 0). So muting the capture bus is enough to keep the mic
## inaudible locally — AudioEffectCapture still receives the full signal
## every mix step; no "-80 dB after effects" workaround is needed.

signal packet_ready(data: PackedByteArray)   # PACKET_SAMPLES mu-law bytes at 16 kHz

const BUS_NAME := "VoiceCapture"
const HANGOVER_SEC := 0.3   # keep sending this long after level drops below threshold
const ANDROID_RECORD_AUDIO := "android.permission.RECORD_AUDIO"

var enabled := true          # when false, nothing is emitted (mute)
var force_send := false      # when true, bypass the VAD gate (push-to-talk to AI)
var vad_threshold := 0.012   # RMS gate; keep sending for ~300 ms "hangover" after voice stops
var level := 0.0             # last packet RMS (for UI)

var _player: AudioStreamPlayer
var _capture: AudioEffectCapture
var _bus_idx := -1
var _running := false

# Resample state carried across _process calls so packets join without clicks.
var _resample_carry := PackedFloat32Array()
var _resample_pos := 0.0

var _pcm_buffer := PackedFloat32Array()   # 16 kHz mono samples waiting to form a packet
var _hangover_left := 0.0


func _ready() -> void:
	set_process(false)


func start() -> void:
	if _running:
		return
	_ensure_bus()
	if OS.get_name() == "Android":
		if not get_tree().on_request_permissions_result.is_connected(_on_permission_result):
			get_tree().on_request_permissions_result.connect(_on_permission_result)
		if OS.request_permission(ANDROID_RECORD_AUDIO):
			_begin()
		# else: OS is showing the prompt; _on_permission_result retries when it resolves.
	else:
		_begin()


func stop() -> void:
	_running = false
	set_process(false)
	if _player != null:
		_player.stop()
	_resample_carry.clear()
	_resample_pos = 0.0
	_pcm_buffer.clear()
	_hangover_left = 0.0


func _on_permission_result(permission: String, granted: bool) -> void:
	if permission == ANDROID_RECORD_AUDIO and granted and not _running:
		_begin()


func _ensure_bus() -> void:
	_bus_idx = AudioServer.get_bus_index(BUS_NAME)
	if _bus_idx == -1:
		_bus_idx = AudioServer.bus_count
		AudioServer.add_bus(_bus_idx)
		AudioServer.set_bus_name(_bus_idx, BUS_NAME)
	AudioServer.set_bus_mute(_bus_idx, true)   # see muted-bus note above

	_capture = null
	for i in AudioServer.get_bus_effect_count(_bus_idx):
		var fx := AudioServer.get_bus_effect(_bus_idx, i)
		if fx is AudioEffectCapture:
			_capture = fx
			break
	if _capture == null:
		_capture = AudioEffectCapture.new()
		AudioServer.add_bus_effect(_bus_idx, _capture)


func _begin() -> void:
	if _player == null:
		_player = AudioStreamPlayer.new()
		_player.stream = AudioStreamMicrophone.new()
		_player.bus = BUS_NAME
		add_child(_player)
	_player.play()
	_running = true
	_resample_carry.clear()
	_resample_pos = 0.0
	_pcm_buffer.clear()
	_hangover_left = 0.0
	set_process(true)


func _process(_delta: float) -> void:
	if _capture == null:
		return
	var avail := _capture.get_frames_available()
	if avail <= 0:
		return
	var stereo := _capture.get_buffer(avail)
	var mono := PackedFloat32Array()
	mono.resize(stereo.size())
	for i in stereo.size():
		mono[i] = (stereo[i].x + stereo[i].y) * 0.5

	var native_rate := AudioServer.get_mix_rate()
	var resampled: PackedFloat32Array
	if is_equal_approx(native_rate, float(VoiceCodec.SAMPLE_RATE)):
		resampled = mono
	else:
		resampled = _resample_stream(mono, native_rate)
	_pcm_buffer.append_array(resampled)

	var packet_sec := float(VoiceCodec.PACKET_SAMPLES) / float(VoiceCodec.SAMPLE_RATE)
	while _pcm_buffer.size() >= VoiceCodec.PACKET_SAMPLES:
		var packet := _pcm_buffer.slice(0, VoiceCodec.PACKET_SAMPLES)
		_pcm_buffer = _pcm_buffer.slice(VoiceCodec.PACKET_SAMPLES, _pcm_buffer.size())
		level = VoiceCodec.rms(packet)
		if not enabled:
			continue
		var voiced := level >= vad_threshold
		if voiced:
			_hangover_left = HANGOVER_SEC
		else:
			_hangover_left = maxf(0.0, _hangover_left - packet_sec)
		if force_send or voiced or _hangover_left > 0.0:
			packet_ready.emit(VoiceCodec.encode_ulaw(packet))


## Linear-interpolation resample that carries fractional phase (and a small
## tail of unconsumed input) across calls so packets join without clicks.
func _resample_stream(chunk: PackedFloat32Array, native_rate: float) -> PackedFloat32Array:
	var work := _resample_carry.duplicate()
	work.append_array(chunk)
	if work.size() < 2:
		_resample_carry = work
		return PackedFloat32Array()

	var ratio := native_rate / float(VoiceCodec.SAMPLE_RATE)
	var out := PackedFloat32Array()
	var pos := _resample_pos
	while pos + 1.0 < work.size():
		var idx0 := int(floor(pos))
		var frac := pos - idx0
		out.append(lerpf(work[idx0], work[idx0 + 1], frac))
		pos += ratio

	var idx_start := int(floor(pos))
	_resample_carry = work.slice(idx_start, work.size())
	_resample_pos = pos - idx_start
	return out
