class_name LocalWhisper extends Node
## Offline speech-to-text using the godot-whisper GDExtension (whisper.cpp,
## addons/godot_whisper). Runs on the server, on a worker thread, one
## utterance at a time. The model is a ggml .bin loaded as a WhisperResource;
## it is downloaded to user://models on first use if missing.
##
## GPU use is controlled by the extension's project setting
## audio/input/transcribe/use_gpu (off by default here: the GPU is busy
## rendering VR, and some drivers crash in ggml's Vulkan backend).

const MODEL_URL := "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-%s.bin?download=true"
const RATE := 16000

var _stt: Node
var _loading := false
var _busy := false


static func extension_available() -> bool:
	return ClassDB.class_exists("SpeechToText") and ClassDB.class_exists("WhisperResource")


func model_name() -> String:
	return str(Config.get_value("speech", "whisper_model"))


func _find_model() -> String:
	for p in ["res://addons/godot_whisper/models/ggml-%s.bin" % model_name(), "user://models/ggml-%s.bin" % model_name()]:
		if FileAccess.file_exists(p):
			return p
	return ""


## Loads (downloading if needed) the model. Returns false if unavailable.
func ensure_ready() -> bool:
	if _stt:
		return true
	if not extension_available():
		return false
	while _loading:
		await get_tree().process_frame
	if _stt:
		return true
	_loading = true
	var path := _find_model()
	if path == "" and Config.get_value("speech", "whisper_auto_download") == true:
		path = await _download()
	if path != "":
		var model := ResourceLoader.load(path, "WhisperResource")
		if model:
			_stt = ClassDB.instantiate("SpeechToText")
			_stt.set("language_model", model)
			var lang := str(Config.get_value("speech", "whisper_language"))
			if ClassDB.class_has_integer_constant("SpeechToText", lang):
				_stt.set("language", ClassDB.class_get_integer_constant("SpeechToText", lang))
			add_child(_stt)
			print("[Whisper] Loaded ", path)
	_loading = false
	return _stt != null


func _download() -> String:
	DirAccess.make_dir_recursive_absolute("user://models")
	var dest := "user://models/ggml-%s.bin" % model_name()
	var req := HTTPRequest.new()
	req.use_threads = true
	req.download_file = dest + ".part"
	add_child(req)
	print("[Whisper] Downloading model ", model_name(), " (first use only)…")
	req.request(MODEL_URL % model_name())
	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		push_warning("[Whisper] Model download failed (result %d, HTTP %d)" % [res[0], res[1]])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dest + ".part"))
		return ""
	DirAccess.rename_absolute(ProjectSettings.globalize_path(dest + ".part"), ProjectSettings.globalize_path(dest))
	return dest


## Transcribe 16 kHz mono samples. Returns "" on failure or silence.
func transcribe(pcm: PackedFloat32Array) -> String:
	if not await ensure_ready():
		return ""
	while _busy:
		await get_tree().process_frame
	_busy = true
	# Trailing silence lets Whisper close its last segment cleanly (audio that
	# stops mid-word invites repetition loops); it also needs >= ~1 s of audio.
	var padded := pcm.duplicate()
	padded.resize(maxi(pcm.size() + RATE / 2, RATE + 1600))
	pcm = padded
	# Whisper's cost scales with the audio context; size it to the utterance
	# (1500 = a full 30 s window) instead of always processing 30 s.
	var ctx := clampi(ceili(pcm.size() / float(RATE) / 30.0 * 1500.0) + 64, 256, 1500)
	var out := [""]
	var thread := Thread.new()
	thread.start(func(): out[0] = _run(pcm, ctx))
	while thread.is_alive():
		await get_tree().process_frame
	thread.wait_to_finish()
	_busy = false
	return out[0]


func _run(pcm: PackedFloat32Array, ctx: int) -> String:
	var tokens: Array = _stt.call("transcribe", pcm, "", ctx)
	if tokens.is_empty():
		return ""
	return _clean(str(tokens[0]))


## Strip whisper's non-speech annotations ([BLANK_AUDIO], (music), ♪…) and
## its repetition loops.
static func _clean(text: String) -> String:
	var re := RegEx.create_from_string("\\[[^\\]]*\\]|<[^>]*>|\\([^)]*\\)|♪[^♪]*♪|♪")
	text = re.sub(text, "", true)
	for junk in [". you.", ". You."]:
		text = text.replace(junk, "")
	return collapse_repeats(text.strip_edges())


## Whisper sometimes loops ("ask not ask not ask not…"). Any run of words that
## repeats 3+ times back to back is kept once.
static func collapse_repeats(text: String) -> String:
	var words := text.split(" ", false)
	var norm: Array[String] = []
	for w in words:
		norm.append(w.to_lower().strip_edges().trim_suffix(",").trim_suffix(".").trim_suffix("?").trim_suffix("!"))
	var out: Array[String] = []
	var out_norm: Array[String] = []
	var i := 0
	while i < words.size():
		var skipped := false
		for n in range(1, 13): # phrase lengths up to 12 words
			if i + n * 3 > words.size():
				break
			var reps := 1
			while i + n * (reps + 1) <= words.size() and norm.slice(i + n * reps, i + n * (reps + 1)) == norm.slice(i, i + n):
				reps += 1
			# Also swallow repeats of a phrase we just emitted.
			var tail_match := out_norm.size() >= n and out_norm.slice(out_norm.size() - n) == norm.slice(i, i + n)
			if reps >= 3 or (tail_match and reps >= 2):
				if not tail_match:
					out.append_array(words.slice(i, i + n))
					out_norm.append_array(norm.slice(i, i + n))
				i += n * reps
				skipped = true
				break
		if not skipped:
			out.append(words[i])
			out_norm.append(norm[i])
			i += 1
	return " ".join(out)
