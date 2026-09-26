extends Node
## Voice routing. Every client streams its mic (mu-law 16 kHz) to the server,
## which relays it to everyone in the office; playback is positional, so
## loudness falls off with distance (proximity chat).
##
## Mic policy (client): with other people in the office the mic is open (voice
## activity gated) for proximity chat; alone, it's only on while you point at
## an AI. Point-to-talk: while your pointer (desktop: crosshair) is on an AI,
## the server also records what you say; when you stop pointing at it, the
## recording goes to speech-to-text and the text to that AI, which replies
## with a speech bubble and text-to-speech.
## AI speech is synthesized on the server (best-tts / Kokoro, see the AI
## autoload) and streamed back through the same path, playing from the
## agent's head.

const MAX_PTT_BYTES := VoiceCodec.SAMPLE_RATE * 60
const AUDIO_CHUNK := 8000 # 0.5 s of mu-law per reliable packet

var muted := false
var capture: VoiceCapture

## Per-person listening settings, local to this client: peer -> linear volume / muted.
var _player_volume := {}
var _player_muted := {}

## Client: the AI agent we're talking to by pointing (entity id, or -1 for nobody).
var ai_target := -1
var _talk_session := 0

## server: peer -> {"agent": int, "session": int, "buf": PackedByteArray}
var _ptt := {}


func start_capture() -> void:
	if capture:
		return
	capture = VoiceCapture.new()
	add_child(capture)
	capture.packet_ready.connect(_on_packet)
	capture.enabled = false
	capture.start()


func set_muted(m: bool) -> void:
	muted = m


## Is anyone else here to hear us?
func others_present() -> bool:
	for p in Net.players:
		if p != Net.my_id():
			return true
	return false


## The mic is open for proximity chat when others are present (unless muted),
## and always while pointing at an AI (that's deliberate, so it overrides mute).
static func mic_should_be_on(others: bool, is_muted: bool, target: int) -> bool:
	return target != -1 or (others and not is_muted)


func _process(_delta: float) -> void:
	if capture:
		capture.enabled = Net.in_session and mic_should_be_on(others_present(), muted, ai_target)
		# Record everything (not just voiced packets) while talking to an AI, so
		# speech-to-text gets natural pauses.
		capture.force_send = ai_target != -1


## Point-to-talk: call every frame with what the pointer is on (-1 nobody,
## >0 agent id). Switching targets finishes the previous
## recording (it goes to speech-to-text) and starts a new one.
func set_ai_target(target: int) -> void:
	if target == ai_target or not Net.in_session:
		return
	if ai_target != -1:
		# Let the last packets arrive before closing the recording.
		get_tree().create_timer(0.25).timeout.connect(_call_server.bind("_srv_ptt_end", [_talk_session]))
	ai_target = target
	if target != -1:
		_talk_session += 1
		_call_server("_srv_ptt_begin", [target, _talk_session])


func _on_packet(data: PackedByteArray) -> void:
	if not Net.in_session:
		return
	if Net.is_server():
		_srv_voice(Net.my_id(), data)
	else:
		_voice_up.rpc_id(1, data)


@rpc("any_peer", "unreliable_ordered", "call_remote", 2)
func _voice_up(data: PackedByteArray) -> void:
	if Net.is_server():
		_srv_voice(multiplayer.get_remote_sender_id(), data)


func _srv_voice(peer: int, data: PackedByteArray) -> void:
	if not Net.players.has(peer):
		return
	if _ptt.has(peer) and _ptt[peer]["buf"].size() < MAX_PTT_BYTES:
		_ptt[peer]["buf"].append_array(data)
	for p in Net.players:
		if p == peer:
			continue
		if p == Net.my_id():
			_play_player(peer, data)
		else:
			_voice_down.rpc_id(p, peer, data)


@rpc("authority", "unreliable_ordered", "call_remote", 2)
func _voice_down(peer: int, data: PackedByteArray) -> void:
	_play_player(peer, data)


func _play_player(peer: int, data: PackedByteArray) -> void:
	var a: Node = Sync.avatars.get(peer)
	if a and not is_player_muted(peer):
		a.voice.push_ulaw(data)


# --- Per-person mute / volume (only affects what *you* hear) ----------------------------

func is_player_muted(peer: int) -> bool:
	return _player_muted.get(peer, false)


func set_player_muted(peer: int, on: bool) -> void:
	_player_muted[peer] = on
	var a: Node = Sync.avatars.get(peer)
	if a and on:
		a.voice.clear()


func player_volume(peer: int) -> float:
	return _player_volume.get(peer, 1.0)


func set_player_volume(peer: int, linear: float) -> void:
	_player_volume[peer] = clampf(linear, 0.0, 4.0)
	var a: Node = Sync.avatars.get(peer)
	if a:
		a.voice.volume_db = linear_to_db(maxf(_player_volume[peer], 0.0001))


# --- Per-AI settings (only for you; remembered by the agent's name) ---------------------

## Muted AIs: you don't hear their voice (their speech bubbles still show).
func is_agent_muted(agent_id: int) -> bool:
	return _agent_key(agent_id) in Config.pref("muted_agents", [])


func set_agent_muted(agent_id: int, on: bool) -> void:
	_set_agent_flag("muted_agents", agent_id, on)
	var a: Node = Sync.entities.get(agent_id)
	if on and a and a.get("voice"):
		a.voice.clear() # (stops its mouth too: that follows the audio)


## Does pointing at this AI talk to it? (Off: pointing at it is just pointing.)
func agent_listens(agent_id: int) -> bool:
	return not _agent_key(agent_id) in Config.pref("no_point_to_talk", [])


func set_agent_listens(agent_id: int, on: bool) -> void:
	_set_agent_flag("no_point_to_talk", agent_id, not on)


static func _agent_key(agent_id: int) -> String:
	var a: NetBody = Sync.entities.get(agent_id)
	return str(a.data.get("name", "")).to_lower() if a else ""


func _set_agent_flag(pref: String, agent_id: int, on: bool) -> void:
	var key := _agent_key(agent_id)
	if key == "":
		return
	var names: Array = Config.pref(pref, []).duplicate()
	names.erase(key)
	if on:
		names.append(key)
	Config.set_pref(pref, names)


# --- Push-to-talk to AI (server) ----------------------------------------------------

func _srv_ptt_begin(peer: int, agent_id: int, session: int) -> void:
	var prev: Dictionary = _ptt.get(peer, {})
	if not prev.is_empty():
		_finish(peer, prev) # a new target before the old recording was closed
	_ptt[peer] = {"agent": agent_id, "session": session, "buf": PackedByteArray()}
	AI.server_listening(peer, agent_id, true)


func _srv_ptt_end(peer: int, session: int) -> void:
	var p: Dictionary = _ptt.get(peer, {})
	if p.is_empty() or p["session"] != session:
		return # already finished, or a newer recording has started
	_ptt.erase(peer)
	_finish(peer, p)


## Send a finished recording to speech-to-text and the AI. Pointing at an AI
## without saying anything (under ~0.4 s of audio) quietly does nothing.
func _finish(peer: int, p: Dictionary) -> void:
	var pcm := VoiceCodec.decode_ulaw(p["buf"])
	if pcm.size() < VoiceCodec.SAMPLE_RATE * 0.4 or VoiceCodec.rms(pcm) < 0.004:
		AI.server_listening(peer, p["agent"], false)
		return
	AI.server_handle_speech(peer, p["agent"], pcm)


func server_remove_player(peer: int) -> void:
	_ptt.erase(peer)


# --- AI speech (server -> everyone) --------------------------------------------

## kind: "agent" (id = entity id)
func server_play_speech(kind: String, id: int, pcm16k: PackedFloat32Array) -> void:
	var ulaw := VoiceCodec.encode_ulaw(pcm16k)
	for p in Net.players:
		for i in range(0, ulaw.size(), AUDIO_CHUNK):
			var chunk := ulaw.slice(i, i + AUDIO_CHUNK)
			if p == Net.my_id() and Net.has_local_player():
				_play_speech(kind, id, chunk)
			else:
				_speech.rpc_id(p, kind, id, chunk)


@rpc("authority", "reliable", "call_remote", 3)
func _speech(kind: String, id: int, chunk: PackedByteArray) -> void:
	_play_speech(kind, id, chunk)


func _play_speech(kind: String, id: int, chunk: PackedByteArray) -> void:
	var node := _speaker(kind, id)
	if node and node.get("voice") and not (kind == "agent" and is_agent_muted(id)):
		node.voice.push_ulaw(chunk)


## The node an AI speaks from (its body).
func _speaker(kind: String, id: int) -> Node3D:
	return Sync.entities.get(id) if kind == "agent" else null


# --- Plumbing ----------------------------------------------------------------------

const _ALLOWED := ["_srv_ptt_begin", "_srv_ptt_end"]


func _call_server(method: String, args: Array) -> void:
	if Net.is_server():
		callv(method, [Net.my_id()] + args)
	elif Net.mode == "client":
		_request.rpc_id(1, method, args)


@rpc("any_peer", "reliable")
func _request(method: String, args: Array) -> void:
	if Net.is_server() and method in _ALLOWED and Net.players.has(multiplayer.get_remote_sender_id()):
		callv(method, [multiplayer.get_remote_sender_id()] + args)
