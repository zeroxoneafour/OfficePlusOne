class_name VoiceCodec extends RefCounted
## Small, dependency-free helpers for the voice-chat pipeline: G.711 mu-law
## codec, linear resampling, PCM/WAV conversion and an RMS meter.

const SAMPLE_RATE := 16000          # network voice rate, mono
const PACKET_SAMPLES := 640         # 40 ms per packet

const _ULAW_BIAS := 0x84
const _ULAW_CLIP := 32635

# Lazily-built 256 entry mu-law byte -> linear float table, shared by all callers.
static var _decode_table: PackedFloat32Array = PackedFloat32Array()


static func encode_ulaw(samples: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(samples.size())
	for i in samples.size():
		var s := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		out[i] = _linear_to_ulaw(s)
	return out


static func decode_ulaw(data: PackedByteArray) -> PackedFloat32Array:
	_ensure_decode_table()
	var out := PackedFloat32Array()
	out.resize(data.size())
	for i in data.size():
		out[i] = _decode_table[data[i]]
	return out


static func resample(samples: PackedFloat32Array, from_rate: float, to_rate: float) -> PackedFloat32Array:
	if samples.is_empty() or is_equal_approx(from_rate, to_rate):
		return samples
	var ratio := from_rate / to_rate
	var out_len := int(floor((samples.size() - 1) / ratio)) + 1
	if out_len <= 0:
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(out_len)
	for i in out_len:
		var src_pos := i * ratio
		var idx0 := int(floor(src_pos))
		var idx1 := mini(idx0 + 1, samples.size() - 1)
		var frac := src_pos - idx0
		out[i] = lerpf(samples[idx0], samples[idx1], frac)
	return out


static func pcm16le_to_float(bytes: PackedByteArray) -> PackedFloat32Array:
	var count := bytes.size() / 2
	var out := PackedFloat32Array()
	out.resize(count)
	for i in count:
		out[i] = bytes.decode_s16(i * 2) / 32768.0
	return out


static func float_to_wav16(samples: PackedFloat32Array, rate: int) -> PackedByteArray:
	const CHANNELS := 1
	const BITS_PER_SAMPLE := 16
	var pcm := PackedByteArray()
	pcm.resize(samples.size() * 2)
	for i in samples.size():
		var s: int = clampi(int(round(samples[i] * 32767.0)), -32768, 32767)
		pcm.encode_s16(i * 2, s)

	var byte_rate := rate * CHANNELS * BITS_PER_SAMPLE / 8
	var block_align := CHANNELS * BITS_PER_SAMPLE / 8

	var wav := PackedByteArray()
	wav.append_array("RIFF".to_ascii_buffer())
	wav.append_array(_u32(36 + pcm.size()))
	wav.append_array("WAVE".to_ascii_buffer())
	wav.append_array("fmt ".to_ascii_buffer())
	wav.append_array(_u32(16))          # fmt chunk size
	wav.append_array(_u16(1))           # PCM format
	wav.append_array(_u16(CHANNELS))
	wav.append_array(_u32(rate))
	wav.append_array(_u32(byte_rate))
	wav.append_array(_u16(block_align))
	wav.append_array(_u16(BITS_PER_SAMPLE))
	wav.append_array("data".to_ascii_buffer())
	wav.append_array(_u32(pcm.size()))
	wav.append_array(pcm)
	return wav


static func rms(samples: PackedFloat32Array) -> float:
	if samples.is_empty():
		return 0.0
	var sum := 0.0
	for s in samples:
		sum += s * s
	return sqrt(sum / samples.size())


static func _linear_to_ulaw(sample: int) -> int:
	var sign := 0x00
	if sample < 0:
		sample = -sample
		sign = 0x80
	if sample > _ULAW_CLIP:
		sample = _ULAW_CLIP
	sample += _ULAW_BIAS
	var exponent := 7
	var mask := 0x4000
	while (sample & mask) == 0 and exponent > 0:
		exponent -= 1
		mask >>= 1
	var mantissa := (sample >> (exponent + 3)) & 0x0F
	return ~(sign | (exponent << 4) | mantissa) & 0xFF


static func _ensure_decode_table() -> void:
	if _decode_table.size() == 256:
		return
	_decode_table.resize(256)
	for i in 256:
		_decode_table[i] = _ulaw_byte_to_float(i)


static func _ulaw_byte_to_float(ulaw_byte: int) -> float:
	var inverted := ~ulaw_byte & 0xFF
	var sign := inverted & 0x80
	var exponent := (inverted >> 4) & 0x07
	var mantissa := inverted & 0x0F
	var sample := (((mantissa << 3) + _ULAW_BIAS) << exponent) - _ULAW_BIAS
	if sign != 0:
		sample = -sample
	return clampf(sample / 32767.0, -1.0, 1.0)


static func _u32(value: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, value)
	return b


static func _u16(value: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, value)
	return b
