extends Node
## AI agents, server side. Flow: client -> server (voice, text or a handed
## item) -> STT -> Claude (with embodied tools) -> server executes tools in the
## world -> TTS -> voice streamed from the agent's head to everyone.
##
## Each agent is an NPC body (AgentBody entity) + a Brain with its own
## persona, voice and conversation history. Only agents listen: the room
## itself is controlled through the watch and context menus, never
## by voice. Tools are permission checked against the human who started the
## request.

const NAMES := ["Adi", "Eric", "Jeffrey", "Krish", "Verity", "Danny",
	"Danielle", "Lily", "Mariam", "Grace", "Emma", "Serena"]
const COLORS := ["#7b68ee", "#e07a5f", "#3d85c6", "#81b29a", "#f2cc8f", "#c06c84", "#6c5b7b", "#355c7d"]
const GESTURES := ["wave", "point", "offer", "think", "shrug", "nod"]
const TOOLS := preload("res://scripts/ai/tools.gd")
## Skills preloaded into every agent's system prompt (shipped via the export
## presets' include filter).
const SKILLS := ["res://ai/skills/widgets/SKILL.md"]
## Widget change notes kept per agent until its next turn.
const MAX_NOTES := 15
## Agent-to-agent handoffs start a new turn only this many levels deep (no ping-pong loops).
const MAX_DEPTH := 2
const MAX_TEXT_CHARS := 100000
const MAX_INLINE_BYTES := 5 * 1024 * 1024
## Minimum permission (Net.PERMS) for each tool; unlisted tools need "interact".
const TOOL_PERMS := {
	"update_my_profile": "agents",
}

## English best-tts (Kokoro) voices, handed out in turn to new agents. Names
## encode accent and gender: af_ = American female, bm_ = British male…
const VOICES := ["am_michael", "am_adam", "bm_george", "am_fenrir", "bm_lewis", "am_puck",
	"af_heart", "bf_emma", "af_bella", "af_nicole", "bf_isabella", "af_sarah"]
const TTS_RATE := 24000

class Brain:
	var key := ""
	var agent_id := 0 # entity id; 0 for the room assistant
	var profile := {}
	var history: Array = []
	var queue: Array = []
	var busy := false
	var listening := false
	var speak_until := 0.0
	var status := ""
	## Which NAMES/VOICES pair it was given (-1: its own name), so it isn't reused.
	var name_voice_idx := -1
	## What happened to the wall widgets since this agent last took a turn.
	var widget_notes: Array[String] = []
	## The widget list as of this agent's last turn (to spot changes).
	var widgets_seen := ""


var claude: ClaudeClient
## Fallback for when Claude can't answer (see OpenAIClient).
var openai: OpenAIClient
var speech_to_text: LocalWhisper
## Neural text-to-speech (the best-tts addon: Kokoro-82M on the GPU, fully
## offline). Runs on the host; each line is streamed to everyone and plays
## from the agent's head. Null where there's no GPU renderer (headless).
var text_to_speech: KokoroTTS
var _brains := {}
var _skills_text := ""


func _ready() -> void:
	claude = ClaudeClient.new()
	add_child(claude)
	openai = OpenAIClient.new()
	add_child(openai)
	speech_to_text = LocalWhisper.new()
	add_child(speech_to_text)
	if DisplayServer.get_name() != "headless":
		text_to_speech = KokoroTTS.new()
		text_to_speech.preload_on_ready = false # only the host loads the model (server_init)
		text_to_speech.default_voice = VOICES[0]
		add_child(text_to_speech)
	for path in SKILLS:
		var text := FileAccess.get_file_as_string(path)
		if text == "":
			push_warning("[AI] Missing skill %s (is ai/skills/* in the export include filter?)" % path)
		else:
			_skills_text += "\n\n<skill path=\"%s\">\n%s\n</skill>" % [path.trim_prefix("res://"), text.strip_edges()]


func server_init() -> void:
	if not claude.is_configured() and not openai.is_configured():
		push_warning("[AI] No Anthropic or OpenAI API key: agents will explain they can't think yet.")
	elif not claude.is_configured():
		push_warning("[AI] No Anthropic API key: agents think with OpenAI (%s)." % openai.model_name())
	speech_to_text.ensure_ready() # load/download the model in the background now
	if text_to_speech:
		text_to_speech.start() # load the voice model in the background now
	else:
		push_warning("[AI] No GPU renderer (headless): agents' replies show as speech bubbles only.")


## (Agents are saved and restored with the rest of the room: see Saves.)
func reset() -> void:
	_brains.clear()


# --- Agent lifecycle (server) --------------------------------------------------------

func server_create_agent(profile: Dictionary, near_peer: int, xform: Variant = null) -> int:
	var unused_names := range(0, NAMES.size())
	for b: Brain in _brains.values():
		unused_names.erase(b.name_voice_idx)
	var n := _brains.size()
	var name_voice_idx := randi_range(0, NAMES.size() - 1)
	if unused_names.size() > 0:
		name_voice_idx = unused_names[randi_range(0, unused_names.size() - 1)]
	var p := {
		"name": NAMES[name_voice_idx], "persona": "A friendly, capable colleague who is happy to help with anything.",
		# best-tts voice and speaking speed (0.5-2.0).
		"voice": VOICES[name_voice_idx % VOICES.size()], "speed": "1.0",
		"model": Config.get_value("ai", "model"), "effort": Config.get_value("ai", "effort"),
		"color": COLORS[n % COLORS.size()],
	}
	for k in profile:
		if str(profile[k]) != "":
			p[k] = str(profile[k])
		if k == "name" and NAMES.find(p["name"]) != -1:
			name_voice_idx = NAMES.find(p["name"])
	var xf: Transform3D = xform if xform is Transform3D else _front_of(near_peer, 1.6)
	var id := Sync.spawn("agent", xf, {"name": p["name"], "color": p["color"], "status": "idle"})
	var brain := Brain.new()
	brain.key = "a%d" % id
	brain.agent_id = id
	brain.profile = p
	brain.name_voice_idx = name_voice_idx if NAMES.find(p["name"]) == name_voice_idx else -1
	_brains[brain.key] = brain
	if near_peer != 0:
		Sync.event(id, "look", {"peer": near_peer})
		Sync.event(id, "gesture", {"kind": "wave"})
	return id


func server_remove_agent(agent_id: int) -> void:
	for item in Sync.carried_by(agent_id):
		Sync.drop_item(item.entity_id)
	_brains.erase("a%d" % agent_id)
	Sync.despawn(agent_id)


func server_summon_agent(agent_id: int, peer: int) -> void:
	var e: NetBody = Sync.entities.get(agent_id)
	if not e or not Net.players.has(peer):
		return
	if e.held_by != 0:
		Sync._srv_release(e.held_by, agent_id, Vector3.ZERO, Vector3.ZERO, false)
	Sync.server_unsit_agent(agent_id)
	e.global_transform = _front_of(peer, 1.3)
	e.linear_velocity = Vector3.ZERO
	Sync.event(agent_id, "look", {"peer": peer})
	Sync.event(agent_id, "gesture", {"kind": "wave"})
	Net.send_toast(peer, "%s is here." % e.data.get("name", "AI"))


## Summon an agent to a point (e.g. picked with the pointer), facing the
## person who asked; if `chair_id` is a free chair, the agent sits on it.
func server_summon_agent_to(agent_id: int, peer: int, point: Vector3, chair_id := 0) -> void:
	var e: NetBody = Sync.entities.get(agent_id)
	if not e or not Net.players.has(peer):
		return
	if e.held_by != 0:
		Sync._srv_release(e.held_by, agent_id, Vector3.ZERO, Vector3.ZERO, false)
	Sync.server_unsit_agent(agent_id)
	var chair: NetBody = Sync.entities.get(chair_id)
	if chair and chair.kind == "chair" and Sync.seat_agent(e, chair):
		pass
	else:
		var half := Office.size() * 0.5 - Vector3(0.4, 0, 0.4)
		var pos := Sync.free_spot(Vector3(clampf(point.x, -half.x, half.x), 0.02, clampf(point.z, -half.z, half.z)), 0.4)
		var head: Variant = Sync.head_xform(peer)
		var face := Vector3.FORWARD
		if head is Transform3D:
			face = Vector3((head as Transform3D).origin.x, pos.y, (head as Transform3D).origin.z) - pos
		e.global_transform = Transform3D(Basis.looking_at(face if face.length() > 0.05 else Vector3.FORWARD, Vector3.UP), pos)
		e.linear_velocity = Vector3.ZERO
	Sync.event(agent_id, "look", {"peer": peer})
	Sync.event(agent_id, "gesture", {"kind": "wave"})


## Transform on the floor `dist` in front of a player, facing them.
func _front_of(peer: int, dist: float) -> Transform3D:
	var head: Variant = Sync.head_xform(peer)
	if not head is Transform3D:
		var s := Office.spawn_xform()
		return Transform3D(Basis(Vector3.UP, PI), s.origin + Vector3(0, 0, -2.0))
	var h: Transform3D = head
	var fwd := -h.basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var half := Office.size() * 0.5 - Vector3(0.5, 0, 0.5)
	var pos := h.origin + fwd * dist
	pos = Vector3(clampf(pos.x, -half.x, half.x), 0.02, clampf(pos.z, -half.z, half.z))
	pos = Sync.free_spot(pos, 0.4)
	var to_player := Vector3(h.origin.x, pos.y, h.origin.z) - pos
	if to_player.length() < 0.05:
		to_player = -fwd
	return Transform3D(Basis.looking_at(to_player, Vector3.UP), pos)


# --- Input from players ------------------------------------------------------------

func server_listening(peer: int, agent_id: int, on: bool) -> void:
	var brain := _brain_for(agent_id)
	if not brain:
		return
	brain.listening = on
	if on:
		Sync.event(brain.agent_id, "look", {"peer": peer})


func server_handle_speech(peer: int, agent_id: int, pcm: PackedFloat32Array) -> void:
	var brain := _brain_for(agent_id)
	if not brain:
		return # only AI agents listen
	brain.listening = false
	if not LocalWhisper.extension_available():
		Net.send_toast(peer, "No speech recognition on this server (the godot-whisper addon is missing). You can type instead (T).")
		return
	if not speech_to_text._stt:
		Net.send_toast(peer, "Preparing on-device speech recognition (the first time downloads the %s model)…" % speech_to_text.model_name())
	brain.busy = true # show "thinking" while transcribing
	var text := await speech_to_text.transcribe(pcm)
	brain.busy = brain.queue.size() > 0
	if text == "":
		Net.send_toast(peer, "Sorry, I didn't catch that.")
		return
	#Net.send_toast(peer, "You: " + text)
	_enqueue(brain, {"peer": peer, "text": "%s says: %s" % [Net.player_name(peer), text]})


## Client API: send typed text to an agent.
func request_text(agent_id: int, text: String) -> void:
	if Net.is_server():
		_srv_text(Net.my_id(), agent_id, text)
	elif Net.mode == "client":
		_text.rpc_id(1, agent_id, text)


@rpc("any_peer", "reliable")
func _text(agent_id: int, text: String) -> void:
	if Net.is_server() and Net.players.has(multiplayer.get_remote_sender_id()):
		_srv_text(multiplayer.get_remote_sender_id(), agent_id, text.substr(0, 4000))


func _srv_text(peer: int, agent_id: int, text: String) -> void:
	var brain := _brain_for(agent_id)
	if not brain:
		Net.send_toast(peer, "Point at (or face) an AI agent to talk to it.")
		return
	_enqueue(brain, {"peer": peer, "text": "%s says: %s" % [Net.player_name(peer), text]})


## A person (or another agent) handed `item_id` to an agent. The agent takes it
## and reacts. `from_agent` is set for agent-to-agent handoffs.
func server_receive_item(agent_id: int, item_id: int, peer: int, from_agent := 0, depth := 0) -> void:
	var brain: Brain = _brains.get("a%d" % agent_id)
	var item: NetBody = Sync.entities.get(item_id)
	if not brain or not item:
		return
	Sync.give_to_agent(item_id, agent_id)
	Sync.event(agent_id, "look", {"peer": peer})
	var giver := Net.player_name(peer) if from_agent == 0 else str(_brains.get("a%d" % from_agent).profile.get("name", "An agent"))
	if depth > MAX_DEPTH:
		return # keep it, but don't start another turn
	var blocks := _item_blocks(item)
	_enqueue(brain, {"peer": peer, "depth": depth, "blocks": blocks,
			"text": "%s hands you %s. It's now in your hand." % [giver, _describe(item)]})


## An item was pressed onto the whiteboard by a person.
func server_show_on_board(item_id: int, peer: int, board: WhiteboardWidget) -> void:
	var item: NetBody = Sync.entities.get(item_id)
	if item and board and Net.can(peer, "interact"):
		board.server_show(_board_for(item))
		Net.send_toast(peer, "Pinned %s to %s." % [item.data.get("name", item.data.get("title", "it")), board.widget_name()])


func _board_for(item: NetBody) -> Dictionary:
	if item.kind == "clipboard":
		var pages: Array = item.data.get("pages", [])
		var p: Dictionary = pages[0] if pages.size() and pages[0] is Dictionary else {}
		return {"title": str(item.data.get("title", "")), "text": str(p.get("text", "")), "image": int(p.get("image", 0))}
	return {"title": str(item.data.get("name", "")), "text": str(item.data.get("preview", "")), "image": int(item.data.get("image", 0))}


## The agent's brain, or null (nothing else listens).
func _brain_for(agent_id: int) -> Brain:
	return _brains.get("a%d" % agent_id)


## req: {"peer": int, "text": String, "blocks": Array (optional), "depth": int (optional)}
func _enqueue(brain: Brain, req: Dictionary) -> void:
	brain.queue.append(req)
	if not brain.busy:
		_drain(brain)


func _drain(brain: Brain) -> void:
	brain.busy = true
	while brain.queue.size() > 0:
		await _run_turn(brain, brain.queue.pop_front())
	brain.busy = false


# --- The model loop ------------------------------------------------------------------

func _run_turn(brain: Brain, req: Dictionary) -> void:
	var peer: int = req["peer"]
	var start_len := brain.history.size()
	var content: Array = [{"type": "text", "text": _context(brain, peer)}]
	content.append_array(req.get("blocks", []))
	content.append({"type": "text", "text": req["text"]})
	if brain.history.size() > 0 and brain.history[-1]["role"] == "user":
		brain.history[-1]["content"].append_array(content)
	else:
		brain.history.append({"role": "user", "content": content})
	var tools: Array = TOOLS.AGENT + WidgetMcp.anthropic_tools()
	# Once Claude has failed in a turn, the rest of the turn uses the fallback.
	var use_fallback := not claude.is_configured() and openai.is_configured()
	for step in 8:
		var body := {
			"model": brain.profile.get("model", Config.get_value("ai", "model")),
			"max_tokens": int(Config.get_value("ai", "max_tokens")),
			"system": [{"type": "text", "text": _system_prompt(brain)}],
			"tools": tools,
			"messages": brain.history,
			"thinking": {"type": "adaptive"},
			"output_config": {"effort": brain.profile.get("effort", "low")},
			"cache_control": {"type": "ephemeral"},
		}
		var res: Dictionary = await openai.create_message(body) if use_fallback else await claude.create_message(body)
		if res.has("error") and not use_fallback and openai.is_configured() and _brains.has(brain.key):
			push_warning("[AI] %s: Claude failed (%s); falling back to OpenAI (%s)" % [brain.profile.get("name"), res["error"], openai.model_name()])
			use_fallback = true
			res = await openai.create_message(body)
		if not _brains.has(brain.key):
			return # agent was removed mid-turn
		if res.has("error"):
			push_warning("[AI] %s: %s" % [brain.profile.get("name"), res["error"]])
			brain.history.resize(start_len)
			_say(brain, "Sorry, I can't think right now. " + str(res["error"]).substr(0, 160))
			return
		if res.get("stop_reason") == "refusal":
			brain.history.resize(start_len)
			_say(brain, "I'm not able to help with that one.")
			return
		var out: Array = res.get("content", [])
		brain.history.append({"role": "assistant", "content": out})
		var tool_uses := []
		for block in out:
			if block.get("type") == "text":
				_say(brain, str(block.get("text", "")))
			elif block.get("type") == "tool_use":
				tool_uses.append(block)
		if tool_uses.is_empty():
			break
		var results := []
		for tu in tool_uses:
			var input: Dictionary = tu.get("input") if tu.get("input") is Dictionary else {}
			var r: String = await _run_tool(brain, req, str(tu.get("name")), input)
			if not _brains.has(brain.key):
				return
			results.append({"type": "tool_result", "tool_use_id": tu["id"], "content": r, "is_error": r.begins_with("Error")})
		brain.history.append({"role": "user", "content": results})
	_trim_history(brain)


func _trim_history(brain: Brain) -> void:
	if brain.history.size() <= 60:
		return
	# Drop whole old exchanges; restart at a user message that isn't tool results.
	for i in range(brain.history.size() - 40, brain.history.size()):
		var m: Dictionary = brain.history[i]
		if m["role"] == "user" and m["content"][0].get("type") == "text":
			brain.history = brain.history.slice(i)
			return


func _system_prompt(brain: Brain) -> String:
	var p := brain.profile
	return """You are %s, an AI agent with a physical body inside Office Plus One, a shared multiplayer VR office where humans and AI agents work together.

How you communicate:
- People speak to you and your text replies are spoken aloud by a text-to-speech voice. Talk like a person: short, natural sentences. Never use markdown, bullet lists, code blocks, URLs or emoji in what you say. Usually one to three sentences.
- For anything visual, detailed or long (lists, tables, code, plans, diagrams, summaries), use your tools: write or draw on the room's whiteboard, or hand someone a clipboard. Then just summarize aloud.
- Files are physical objects here. People hand you documents, images and clipboards; you can read them, keep holding them, pass them to a person or another agent, put them down, or pin them to the whiteboard. You can also create new documents and hand them over.
- When someone wants something usable outside the app (notes, a document, slides, data, code), use the export tools; the file is handed to them and saved on their device.
- You have a body: you can gesture. You can't walk on your own; people can carry you or summon you.
- Several people may be present; each message says who is speaking or handing you something. Address them by name when natural.

Your persona: %s

Skills you have (follow them when they apply):%s""" % [p.get("name", "Agent"), p.get("persona", ""), _skills_text]


func _context(brain: Brain, peer: int) -> String:
	var people := []
	for p in Net.players:
		people.append("%s (%s)" % [Net.player_name(p), Net.role(p)])
	var agents := []
	for b in _brains.values():
		if b.agent_id and b != brain:
			agents.append(str(b.profile.get("name")))
	var holding := []
	if brain.agent_id:
		for item in Sync.carried_by(brain.agent_id):
			holding.append(_describe(item))
	var loose := []
	for e in Sync.entities.values():
		if e.kind in Sync.HANDABLE and int(e.data.get("agent_holder", 0)) == 0:
			loose.append(_describe(e))
	var size := Office.size()
	return "[Context: room %.1fm wide x %.1fm deep x %.1fm high. People: %s. Other AI agents: %s. %sItems lying around or held by people: %s. %s Current request from: %s.]" % [
		size.x, size.z, size.y, ", ".join(people), ", ".join(agents) if agents.size() else "none",
		("You are holding: %s. " % ", ".join(holding)) if holding.size() else "You are holding nothing. ",
		", ".join(loose.slice(0, 20)) if loose.size() else "none", _widget_context(brain), Net.player_name(peer)]


## The wall widgets for this agent's context: the full list with how to use
## each one when they've changed since its last turn (plus what changed), else
## just their names.
func _widget_context(brain: Brain) -> String:
	var names := WidgetMcp.names_line()
	var changed := names != brain.widgets_seen
	brain.widgets_seen = names
	var notes := brain.widget_notes.duplicate()
	brain.widget_notes.clear()
	var out := ""
	if changed or notes.size():
		out = "Wall widgets (updated):\n%s" % WidgetMcp.listing()
	else:
		out = "Wall widgets: %s. Today is %s, %s." % [names, CalendarWidget.today(), Time.get_time_string_from_system().substr(0, 5)]
	if notes.size():
		out += "\nWidget changes since you last spoke: %s" % " ".join(notes)
	return out


## Server: tell every agent about a widget change (they see it on their next turn).
func widget_note(text: String) -> void:
	for b in _brains.values():
		if Widgets.acting_ai != "" and str(b.profile.get("name", "")) == Widgets.acting_ai:
			continue # it knows what it just did
		b.widget_notes.append(text)
		if b.widget_notes.size() > MAX_NOTES:
			b.widget_notes.pop_front()


func _describe(item: NetBody) -> String:
	if item.kind == "clipboard":
		return "item #%d: clipboard \"%s\" (%d pages)" % [item.entity_id, item.data.get("title", ""), item.data.get("pages", []).size()]
	return "item #%d: file \"%s\" (%s, %s)" % [item.entity_id, item.data.get("name", "?"), item.data.get("mime", "?"),
			Files.human_size(int(item.data.get("size", 0)))]


## Content blocks that let Claude actually read a handed item.
func _item_blocks(item: NetBody) -> Array:
	if item.kind == "clipboard":
		var text := ""
		for p in item.data.get("pages", []):
			text += str(p.get("text", "")) + "\n\n"
		return [{"type": "text", "text": "<clipboard title=\"%s\">\n%s</clipboard>" % [item.data.get("title", ""), text]}]
	var f := Files.server_get(int(item.data.get("file_id", 0)))
	if f.is_empty():
		return []
	var mime: String = f["mime"]
	var bytes: PackedByteArray = f["bytes"]
	if Files.is_image(mime) and bytes.size() <= MAX_INLINE_BYTES:
		return [{"type": "image", "source": {"type": "base64", "media_type": mime, "data": Marshalls.raw_to_base64(bytes)}}]
	if mime == "application/pdf" and bytes.size() <= MAX_INLINE_BYTES * 4:
		return [{"type": "document", "source": {"type": "base64", "media_type": mime, "data": Marshalls.raw_to_base64(bytes)}}]
	if Files.is_text(mime):
		var text := bytes.get_string_from_utf8()
		var note := ""
		if text.length() > MAX_TEXT_CHARS:
			note = "\n[Only the first %d of %d characters are included; tell the person the file was too long to read fully.]" % [MAX_TEXT_CHARS, text.length()]
			text = text.substr(0, MAX_TEXT_CHARS)
		return [{"type": "text", "text": "<file name=\"%s\">\n%s\n</file>%s" % [f["name"], text, note]}]
	return [{"type": "text", "text": "[%s is a %s file (%s). You can hold, pass or pin it, but you can't read its contents.]" % [f["name"], mime, Files.human_size(bytes.size())]}]


# --- Speech output ------------------------------------------------------------------

func _say(brain: Brain, text: String) -> void:
	text = text.strip_edges()
	if text == "":
		return
	Sync.event(brain.agent_id, "say", {"text": text})
	var speed := clampf(float(brain.profile.get("speed", 1.0)), 0.5, 2.0)
	if not text_to_speech:
		brain.speak_until = maxf(brain.speak_until, _now()) + text.length() * 0.065 / speed
		return
	# Synthesized clause by clause; each piece is streamed as soon as it's ready.
	var agent_id := brain.agent_id
	var sent := [0]
	var req := text_to_speech.say(text, voice_for(brain.profile), speed, KokoroTTS.Priority.HIGH)
	req.chunk_ready.connect(func(clip: AudioStreamWAV, _i: int, _n: int):
		sent[0] += 1
		_stream_clip(brain, agent_id, clip))
	req.finished.connect(func(clip: AudioStreamWAV):
		if sent[0] == 0 and clip:
			_stream_clip(brain, agent_id, clip) # a cached line comes back whole
		elif not clip and req.error != "cancelled":
			push_warning("[AI] Text-to-speech failed: %s" % req.error))
	if req.is_done() and req.stream and sent[0] == 0:
		_stream_clip(brain, agent_id, req.stream)


## Send a synthesized clip to everyone (16 kHz, from the agent's head) and
## keep the "speaking" status up until it has played.
func _stream_clip(brain: Brain, agent_id: int, clip: AudioStreamWAV) -> void:
	if not _brains.has(brain.key) or not Sync.entities.has(agent_id) or clip == null:
		return
	var pcm := VoiceCodec.pcm16le_to_float(clip.data)
	if clip.stereo:
		var mono := PackedFloat32Array()
		mono.resize(pcm.size() / 2)
		for i in mono.size():
			mono[i] = (pcm[i * 2] + pcm[i * 2 + 1]) * 0.5
		pcm = mono
	var pcm16k := VoiceCodec.resample(pcm, clip.mix_rate, VoiceCodec.SAMPLE_RATE)
	Voice.server_play_speech("agent", agent_id, pcm16k)
	# Clips play back to back: this one ends after whatever is still playing.
	brain.speak_until = maxf(brain.speak_until, _now()) + pcm16k.size() / float(VoiceCodec.SAMPLE_RATE)


## An agent's best-tts voice: its profile's, if that's a bundled English one,
## else a stable pick from its name (profiles from before best-tts named
## other voices).
static func voice_for(profile: Dictionary) -> String:
	var v := str(profile.get("voice", ""))
	if v.length() > 3 and v[0] in "ab" and KokoroTTS.has_voice(v):
		return v
	return VOICES[absi(hash(str(profile.get("name", "")))) % VOICES.size()]

## First sentence alone (fast first audio), then ~250-char groups.
static func _chunk_sentences(text: String) -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.create_from_string("[^.!?]+[.!?]*\\s*")
	var cur := ""
	for m in re.search_all(text):
		cur += m.get_string()
		if out.is_empty() or cur.length() > 250:
			out.append(cur.strip_edges())
			cur = ""
	if cur.strip_edges() != "":
		out.append(cur.strip_edges())
	return out


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	if not Net.is_server():
		return
	var now := _now()
	for b: Brain in _brains.values():
		var s := "idle"
		if now < b.speak_until:
			s = "speaking"
		elif b.busy:
			s = "thinking"
		elif b.listening:
			s = "listening"
		if s != b.status:
			b.status = s
			Sync.set_data(b.agent_id, "status", s)


# --- Tools ------------------------------------------------------------------------

func _run_tool(brain: Brain, req: Dictionary, tool: String, input: Dictionary) -> String:
	var peer: int = req["peer"]
	var perm: String = TOOL_PERMS.get(tool, "interact")
	if not Net.can(peer, perm):
		return "Error: %s doesn't have permission for this (needs %s)." % [Net.player_name(peer), Net.PERMS[perm]]
	if WidgetMcp.has_tool(tool):
		var res := WidgetMcp.call_tool(tool, input, peer, str(brain.profile.get("name", "An AI")))
		if not res.begins_with("Error") and tool != "widget_list":
			_gesture(brain, "point")
		return res
	var board: WhiteboardWidget = null
	if tool in ["write_on_whiteboard", "draw_on_whiteboard", "show_image_on_whiteboard", "clear_whiteboard", "pin_item_to_whiteboard"]:
		var boards := Widgets.all().filter(func(w): return w is WhiteboardWidget)
		board = Widgets.find("whiteboard", str(input.get("whiteboard_name", ""))) if str(input.get("whiteboard_name", "")) != "" else (boards[0] if boards.size() else null)
		if not board:
			return "Error: no such whiteboard. The whiteboards are: %s." % (", ".join(boards.map(func(w): return "\"%s\"" % w.widget_name())) if boards.size() else "none (people add them from a wall's menu)")
		Widgets.acting_ai = str(brain.profile.get("name", "An AI"))
	var result: String = await _run_agent_tool(brain, req, tool, input, board)
	Widgets.acting_ai = ""
	return result


func _run_agent_tool(brain: Brain, req: Dictionary, tool: String, input: Dictionary, board: WhiteboardWidget) -> String:
	var peer: int = req["peer"]
	match tool:
		# --- Agent: whiteboards (widgets)
		"write_on_whiteboard":
			board.server_show({"title": str(input.get("title", "")), "text": str(input.get("text", "")), "image": 0})
			AI.widget_note("%s wrote \"%s\" on whiteboard \"%s\"." % [brain.profile.get("name", "An AI"), input.get("title", ""), board.widget_name()])
			_gesture(brain, "point")
			return "Written on %s." % board.widget_name()
		"draw_on_whiteboard":
			var img := Sync.add_svg(str(input.get("svg", "")))
			if img == 0:
				return "Error: the SVG could not be rendered. Use a simple standalone <svg> with width, height and viewBox, basic shapes and text."
			board.server_show({"title": str(input.get("title", "")), "text": str(input.get("caption", "")), "image": img})
			_gesture(brain, "point")
			return "Drawn on %s." % board.widget_name()
		"show_image_on_whiteboard":
			var url := str(input.get("url", ""))
			if not url.begins_with("http"):
				return "Error: url must be http(s)."
			var res: Dictionary = await Http.request(self, url, PackedStringArray(["User-Agent: OfficePlusOne/1.0"]), HTTPClient.METHOD_GET, PackedByteArray(), 30.0)
			var img := Sync.add_image(res["body"]) if res["ok"] else 0
			if img == 0:
				return "Error: could not download a PNG/JPEG/WebP image from that URL (%s)." % res["error"]
			board.server_show({"title": str(input.get("title", "")), "text": str(input.get("caption", "")), "image": img})
			_gesture(brain, "point")
			return "Image shown on %s." % board.widget_name()
		"clear_whiteboard":
			board.server_clear("all", -1)
			return "%s wiped." % board.widget_name()
		# --- Agent: physical items
		"hand_clipboard":
			var pages := []
			for p in (input.get("pages") if input.get("pages") is Array else []):
				pages.append({"text": str(p), "image": 0})
			if str(input.get("svg", "")) != "":
				var img := Sync.add_svg(str(input["svg"]))
				if img:
					pages.insert(0, {"text": "", "image": img})
			if pages.is_empty():
				return "Error: provide at least one page."
			var id := _spawn_in_hand(brain, "clipboard", {"title": str(input.get("title", "")), "pages": pages, "page": 0})
			return _hand_over(brain, id, str(input.get("to", "")), peer)
		"create_document":
			var fid := Files.server_add(str(input.get("filename", "notes.md")), str(input.get("content", "")).to_utf8_buffer())
			var id := _spawn_document(brain, fid)
			return _hand_over(brain, id, str(input.get("to", "")), peer)
		"give_item":
			var item := _find_item(brain, str(input.get("item", "")))
			if not item:
				return "Error: you aren't holding that item. You hold: %s" % _held_list(brain)
			return _hand_over(brain, item.entity_id, str(input.get("to", "")), peer, req.get("depth", 0))
		"put_down_item":
			var item := _find_item(brain, str(input.get("item", "")))
			if not item:
				return "Error: you aren't holding that item."
			Sync.drop_item(item.entity_id)
			return "Put down."
		"pin_item_to_whiteboard":
			var item := _find_item(brain, str(input.get("item", "")))
			if not item:
				return "Error: you aren't holding that item."
			board.server_show(_board_for(item))
			_gesture(brain, "point")
			return "Pinned to %s." % board.widget_name()
		# --- Agent: exports (handed over + saved on the requester's device)
		"export_document":
			var f: Dictionary = Exporter.make_text(str(input.get("filename", "notes.md")), str(input.get("content", "")))
			return _export(brain, peer, [f])
		"export_slides":
			var files: Array = Exporter.make_slides(str(input.get("title", "Slides")), input.get("slides") if input.get("slides") is Array else [])
			return _export(brain, peer, files)
		"gesture":
			_gesture(brain, str(input.get("kind", "")))
			return "ok"
		"update_my_profile":
			if str(input.get("voice", "")) != "" and voice_for({"voice": str(input["voice"])}) != str(input["voice"]):
				return "Error: unknown voice. Pick one of: %s (af/am = American female/male, bf/bm = British)." % ", ".join(Array(KokoroTTS.list_voices()).filter(func(v): return v[0] in "ab"))
			for k in ["name", "persona", "voice", "speed", "color"]:
				if str(input.get(k, "")) != "":
					brain.profile[k] = str(input[k])
			Sync.set_data(brain.agent_id, "name", brain.profile["name"])
			Sync.set_data(brain.agent_id, "color", brain.profile.get("color", "#7b68ee"))
			return "Profile updated."
	return "Error: unknown tool %s" % tool


func _find_agent(agent_name: String) -> int:
	var n := agent_name.strip_edges().to_lower()
	if n == "":
		return 0
	for b in _brains.values():
		if b.agent_id and str(b.profile.get("name", "")).to_lower() == n:
			return b.agent_id
	for b in _brains.values():
		if b.agent_id and str(b.profile.get("name", "")).to_lower().begins_with(n):
			return b.agent_id
	return 0


## An item this agent carries, by "#12", "12" or (part of) its name/title.
func _find_item(brain: Brain, key: String) -> NetBody:
	var carried := Sync.carried_by(brain.agent_id)
	var k := key.strip_edges().trim_prefix("#").to_lower()
	for item in carried:
		if str(item.entity_id) == k:
			return item
	for item in carried:
		var label := str(item.data.get("name", item.data.get("title", ""))).to_lower()
		if k != "" and (label == k or label.contains(k)):
			return item
	return carried[0] if carried.size() == 1 and k == "" else null


func _held_list(brain: Brain) -> String:
	var names := []
	for item in Sync.carried_by(brain.agent_id):
		names.append(_describe(item))
	return ", ".join(names) if names.size() else "nothing"


func _gesture(brain: Brain, kind: String) -> void:
	if brain.agent_id and kind in GESTURES:
		Sync.event(brain.agent_id, "gesture", {"kind": kind})


## Create an item already in the agent's hand (or in front of the room entrance for the room assistant).
func _spawn_in_hand(brain: Brain, kind: String, data: Dictionary) -> int:
	var a: AgentBody = Sync.entities.get(brain.agent_id)
	var xf := a.hold_xform(Sync.carried_by(brain.agent_id).size()) if a else Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))
	data["pinned"] = true
	if a:
		data["agent_holder"] = brain.agent_id
	return Sync.spawn(kind, xf, data)


func _spawn_document(brain: Brain, file_id: int) -> int:
	var a: AgentBody = Sync.entities.get(brain.agent_id)
	var xf := a.hold_xform(Sync.carried_by(brain.agent_id).size()) if a else Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))
	var extra := {"pinned": true}
	if a:
		extra["agent_holder"] = brain.agent_id
	return Files.server_spawn_document(file_id, xf, extra)


## Give an item the agent holds to a person or another agent (by name). Empty
## `to` means the person who asked.
func _hand_over(brain: Brain, item_id: int, to: String, peer: int, depth := 0) -> String:
	if item_id == 0:
		return "Error: could not create the item."
	var item: NetBody = Sync.entities.get(item_id)
	var label := _describe(item)
	var other := _find_agent(to) if to != "" else 0
	if other != 0 and other != brain.agent_id:
		_gesture(brain, "offer")
		server_receive_item(other, item_id, peer, brain.agent_id, depth + 1)
		return "Handed %s to %s." % [label, _brains["a%d" % other].profile.get("name")]
	var target := Net.find_peer_by_name(to) if to != "" else peer
	if target == 0 or not Net.players.has(target):
		return "Error: nobody called %s is here; the item stays in your hand." % to
	_gesture(brain, "offer")
	Sync.give_to_player(item_id, target)
	return "Handed %s to %s; it's floating in front of them to take." % [label, Net.player_name(target)]


func _export(brain: Brain, peer: int, files: Array) -> String:
	if files.is_empty():
		return "Error: nothing to export."
	var names := []
	var first_id := 0
	for f in files:
		var fid := Files.server_add(f["filename"], f["bytes"])
		Files.server_send_to(peer, fid)
		names.append(Files.server_get(fid)["name"])
		# Hand over the most useful one physically (pptx for decks).
		if first_id == 0 or str(f["filename"]).ends_with(".pptx"):
			first_id = fid
	_hand_over(brain, _spawn_document(brain, first_id), "", peer)
	return "Saved on %s's device and handed to them: %s" % [Net.player_name(peer), ", ".join(names)]
