class_name VoicePlayback extends AudioStreamPlayer3D
## Plays a 16 kHz mono voice stream (live mic packets or AI TTS chunks)
## through an AudioStreamGenerator, with a small jitter buffer and a
## queue policy that differs for live voice vs. long AI speech.

var level := 0.0            # smoothed RMS of what is currently playing (for mouth animation)
var low_latency := true     # true: drop oldest on overflow (live mic). false: never drop (AI TTS).

const _PREBUFFER_SEC := 0.1        # wait for ~100 ms queued before feeding, when idle
const _PREBUFFER_MAX_WAIT := 0.25  # don't stall forever on short clips that never fill it
const _LOW_LATENCY_MAX_SEC := 0.6  # live voice: drop oldest past this much queued audio
const _AI_MAX_QUEUE_SEC := 30.0    # AI speech: hard cap so a runaway feed can't grow forever
const _LEVEL_SMOOTH := 0.35
const _LEVEL_DECAY_PER_SEC := 0.6
const _TALK_LEVEL_THRESHOLD := 0.008

var _playback: AudioStreamGeneratorPlayback
var _queue := PackedFloat32Array()
var _prebuffering := true
var _prebuffer_elapsed := 0.0


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = VoiceCodec.SAMPLE_RATE
	gen.buffer_length = 0.5
	stream = gen
	attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	unit_size = 3.0
	max_distance = 25.0
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback


func push_ulaw(data: PackedByteArray) -> void:
	_enqueue(VoiceCodec.decode_ulaw(data))


func push_pcm(samples: PackedFloat32Array) -> void:
	_enqueue(samples)


func is_talking() -> bool:
	return not _prebuffering and level > _TALK_LEVEL_THRESHOLD


func clear() -> void:
	_queue.clear()
	_prebuffering = true
	_prebuffer_elapsed = 0.0
	level = 0.0
	# AudioStreamGeneratorPlayback.clear_buffer() errors while the playback is
	# active (and stop() doesn't deactivate it synchronously), so restart the
	# node instead: play() creates a fresh playback with an empty ring buffer.
	stop()
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback


func _enqueue(samples: PackedFloat32Array) -> void:
	if samples.is_empty():
		return
	_queue.append_array(samples)
	var cap_sec: float = _LOW_LATENCY_MAX_SEC if low_latency else _AI_MAX_QUEUE_SEC
	var cap := int(cap_sec * VoiceCodec.SAMPLE_RATE)
	if _queue.size() > cap:
		# Drop oldest samples: for live voice this bounds latency; for AI speech
		# it is only a safety ceiling and should not trigger in normal use.
		_queue = _queue.slice(_queue.size() - cap, _queue.size())


func _process(delta: float) -> void:
	if _playback == null:
		return

	if _prebuffering:
		if _queue.is_empty():
			_prebuffer_elapsed = 0.0
			return
		_prebuffer_elapsed += delta
		var needed := int(_PREBUFFER_SEC * VoiceCodec.SAMPLE_RATE)
		if _queue.size() < needed and _prebuffer_elapsed < _PREBUFFER_MAX_WAIT:
			return
		_prebuffering = false

	if _queue.is_empty():
		# Starved: stop feeding (keep the stream playing silence) and re-arm the
		# jitter prebuffer for the next burst instead of trickling single samples.
		level = maxf(level - _LEVEL_DECAY_PER_SEC * delta, 0.0)
		_prebuffering = true
		_prebuffer_elapsed = 0.0
		return

	var can_push := _playback.get_frames_available()
	if can_push <= 0:
		return
	var take := mini(can_push, _queue.size())
	var chunk := _queue.slice(0, take)
	_queue = _queue.slice(take, _queue.size())

	var frames := PackedVector2Array()
	frames.resize(chunk.size())
	for i in chunk.size():
		frames[i] = Vector2(chunk[i], chunk[i])
	_playback.push_buffer(frames)

	level = lerpf(level, VoiceCodec.rms(chunk), _LEVEL_SMOOTH)
