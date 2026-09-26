extends Node
## Headless smoke test, enabled with `-- --selftest=host` or `-- --selftest=client`
## (see tools/selftest.sh). Host: rooms, permissions, agents, tools, files.
## Client: knocks, gets let in, checks replication, permissions and file transfer.
## Exits with code 0 on success, 1 on failure.

var role := ""
var _failures: Array[String] = []
var _toasts: Array[String] = []
## Fake knock used to test the watch's Join requests (the host auto-admits every other knock).
const FAKE_KNOCK := 999
## After the save/load test the agent is a new entity.
var _restored_agent := 0
var _client_seen := false
## Time left on the running timer when the room was saved.
var _timer_left := -1.0


func _ready() -> void:
	role = str(Config.args.get("selftest", ""))
	Net.toast.connect(func(t: String): _toasts.append(t))
	await get_tree().create_timer(1.0).timeout
	if role == "host":
		await _host()
	elif role == "whisper":
		await _whisper()
	elif role == "buttons":
		await _button_latch()
	elif role == "lobby":
		await _lobby()
	elif role == "persist1":
		await _persist(1)
	elif role == "persist2":
		await _persist(2)
	else:
		await _client()
	print("[selftest:%s] %s" % [role, "PASS" if _failures.is_empty() else "FAIL: " + str(_failures)])
	get_tree().quit(0 if _failures.is_empty() else 1)


func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures.append(what)
		push_error("[selftest] failed: " + what)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _host() -> void:
	# Let the knocking client in (the physical card is bypassed here).
	Net.prompt_received.connect(func(kind: String, id: int, _t: String):
		if kind == "knock" and id != FAKE_KNOCK:
			Net.answer_prompt(id, true))
	if not Net.in_session:
		Net.host(false)
	# Loose toys are no longer in the Add menu, but old saves still hold them;
	# the tests use one of each as a handy loose object.
	Sync.spawn("cube", Transform3D(Basis.IDENTITY, Vector3(0.3, 1.0, 0.1)), {"color": "#4f86c6"})
	Sync.spawn("ball", Transform3D(Basis.IDENTITY, Vector3(-0.3, 1.0, 0.1)), {"color": "#e07a5f"})
	_check(not "cube" in Sync.SPAWNABLE and not "ball" in Sync.SPAWNABLE and not "paint" in Sync.SPAWNABLE and "chair" in Sync.SPAWNABLE,
			"cube, ball and paint aren't addable; chairs are")
	_check(Sync.entities_of_kind("monitor").size() == 1 and Sync.entities_of_kind("drawer").size() == 1, "new office has a monitor and drawers")
	_check(not Office.member_may("spawn") and not Office.member_may("agents") and not Office.member_may("lock"), "guests restricted by default")
	# When the client test joins: let it knock first, check it's refused, then
	# grant "Add objects" to guests and ask it over (it answers from its watch).
	Net.roster_changed.connect(func():
		var others := Net.players.keys().filter(func(p): return p != 1)
		if others.size() and not _client_seen:
			_client_seen = true
			var peer: int = others[0]
			get_tree().create_timer(6.0).timeout.connect(func():
				Office.request_action("member_perm", {"perm": "spawn", "on": true})
				Net._srv_request_summon(1, peer)))
	_check(Net.is_server() and Net.role(1) == "owner", "host is owner")
	_check(Office.node != null, "room built")
	_check(Sync.entities.size() >= 5, "room furnished")
	var w := Office.size().x
	Office.request_action("room", {"step": "w+"})
	_check(Office.size().x == w + 1.0, "owner can resize")
	# Agent + tools (no API key needed: tools are called directly).
	var id := AI.server_create_agent({"name": "Testy"}, 1)
	_check(Sync.entities.get(id) is AgentBody, "agent spawned")
	var brain = AI._brains["a%d" % id]
	var req := {"peer": 1, "text": ""}
	var r: String = await AI._run_tool(brain, req, "write_on_whiteboard", {"title": "Plan", "text": "1. test\n2. ship"})
	var main_board: WhiteboardWidget = Widgets.find("whiteboard", "Main board")
	_check(main_board != null and main_board.global_basis.z.dot(Vector3(0, 0, 1)) > 0.99, "a new office has a main whiteboard widget on the north wall")
	_check(Office.node.get_node_or_null("%Whiteboard") == null and not Office.state.has("board"), "…instead of the old built-in board")
	_check(main_board != null and main_board.data.get("title") == "Plan" and main_board.get_node("%Title").text == "Plan", "whiteboard text: " + r)
	r = await AI._run_tool(brain, req, "draw_on_whiteboard", {"title": "Diagram", "svg": "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100' viewBox='0 0 200 100'><rect x='10' y='10' width='80' height='40' fill='#3d85c6'/><text x='20' y='80'>hi</text></svg>"})
	_check(main_board != null and int(main_board.data.get("image", 0)) > 0 and main_board.get_node("%Picture").visible, "whiteboard svg: " + r)
	r = await AI._run_tool(brain, req, "write_on_whiteboard", {"whiteboard_name": "Nope", "title": "x", "text": "y"})
	_check(r.begins_with("Error") and r.contains("Main board"), "unknown whiteboard names the real ones: " + r)
	r = await AI._run_tool(brain, req, "hand_clipboard", {"title": "Notes", "pages": ["one", "two"]})
	var clips := Sync.entities_of_kind("clipboard")
	_check(clips.size() == 1 and clips[0].data.get("pinned") and int(clips[0].data.get("agent_holder", 0)) == 0, "clipboard handed to person: " + r)
	r = await AI._run_tool(brain, req, "create_document", {"filename": "memo.md", "content": "# Memo\nhello"})
	_check(r.begins_with("Handed"), "create_document: " + r)
	r = await AI._run_tool(brain, req, "export_slides", {"title": "Deck", "slides": [{"title": "Hello", "bullets": ["a", "b"]}]})
	_check(r.begins_with("Saved"), "export slides: " + r)
	# Person grabs the clipboard, flips a page, then hands it back to the agent.
	await _wait(1.2) # let the hand-over flight finish
	var clip: NetBody = clips[0]
	Sync.poses[1] = {"head": Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 2)), "l": Transform3D.IDENTITY,
			"r": Transform3D(Basis.IDENTITY, clip.global_position)}
	Sync.request_grab(clip.entity_id, 1, Transform3D.IDENTITY)
	_check(clip.held_by == 1 and not clip.data.get("pinned", true), "grab clipboard")
	Sync.request_use(clip.entity_id)
	_check(clip.data.get("page") == 1, "flip page")
	var agent: AgentBody = Sync.entities[id]
	clip.global_position = agent.global_position + Vector3(0, 1.1, 0.4)
	Sync.request_release(clip.entity_id, Vector3.ZERO, Vector3.ZERO)
	_check(int(clip.data.get("agent_holder", 0)) == id, "agent took the clipboard")
	# Agent gives it to... nobody by that name -> keeps it; then puts it down.
	r = await AI._run_tool(brain, req, "give_item", {"item": "Notes", "to": "Nobody"})
	_check(r.begins_with("Error") and int(clip.data.get("agent_holder", 0)) == id, "give to unknown keeps item")
	r = await AI._run_tool(brain, req, "put_down_item", {"item": "#%d" % clip.entity_id})
	_check(int(clip.data.get("agent_holder", 0)) == 0, "put down: " + r)
	# Import a file as the host; it appears as a document.
	var docs_before := Sync.entities_of_kind("document").size()
	Files.upload("hello.txt", "hi from the host".to_utf8_buffer())
	_check(Sync.entities_of_kind("document").size() == docs_before + 1, "host import creates a document")
	# Sitting: interact with a chair, the player lands on it, then stands up.
	var chair: NetBody = Sync.entities_of_kind("chair")[0]
	Sync.poses[1]["head"] = Transform3D(Basis.IDENTITY, chair.global_position + Vector3(0, 1.2, 0.8))
	Sync.request_interact(chair.entity_id)
	await _wait(0.2)
	var player: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	_check(int(chair.data.get("seated", 0)) == 1 and chair.freeze, "sat on chair (chair frozen)")
	if player:
		_check(player.get("_seat") == chair, "local player is seated")
	Sync.request_grab(chair.entity_id, 1, Transform3D.IDENTITY)
	_check(chair.held_by == 0, "can't grab an occupied chair")
	Sync.request_stand()
	await _wait(0.2)
	_check(int(chair.data.get("seated", 0)) == 0, "stood up")
	_check(chair.freeze and chair.is_locked(), "…the chair stays put (furniture is locked)")
	if player:
		_check(player.get("_seat") == null and player.global_position.y == 0.0, "player back on the floor")
	# An agent released onto a free chair sits down; grabbing it stands it up.
	var other_chair: NetBody = Sync.entities_of_kind("chair")[1]
	var ag: AgentBody = Sync.entities[id]
	Sync.poses[1]["r"] = Transform3D(Basis.IDENTITY, ag.global_position + Vector3(0, 1, 0))
	Sync.request_grab(id, 1, Transform3D.IDENTITY)
	ag.global_position = Sync.seat_xform(other_chair).origin + Vector3(0, 0.2, 0)
	Sync.request_release(id, Vector3.ZERO, Vector3.ZERO)
	_check(int(ag.data.get("sitting_on", 0)) == other_chair.entity_id and int(other_chair.data.get("seated", 0)) == -id, "agent sat on chair")
	Sync.request_grab(id, 1, Transform3D.IDENTITY)
	_check(int(ag.data.get("sitting_on", 0)) == 0 and int(other_chair.data.get("seated", 0)) == 0, "picking agent up stands it")
	Sync.request_release(id, Vector3.ZERO, Vector3.ZERO)
	# Lamp switch.
	Office.request_action("spawn", {"kind": "lamp", "point": Vector3(2.5, 0, 2.5)})
	var lamp: NetBody = Sync.entities_of_kind("lamp")[-1]
	Sync.poses[1]["head"] = Transform3D(Basis.IDENTITY, lamp.global_position + Vector3(0, 0.5, 0.8))
	Sync.request_interact(lamp.entity_id)
	_check(lamp.data.get("on") == false and not lamp.get_node("Light").visible, "lamp switched off")
	await _ray_stability()
	await _pointing_rules()
	await _pointer_and_menus(id)
	await _drag_and_grab()
	# Rapid spawns must not overlap (overlaps make bodies explode apart).
	var before := Sync.entities.keys()
	for i in 8:
		Office.request_action("spawn", {"kind": "chair", "point": Vector3(3, 0, 2)})
	await _wait(2.0)
	# Only the chairs spawned just now.
	var cubes := Sync.entities_of_kind("chair").filter(func(c): return not c.entity_id in before)
	_check(cubes.size() == 8, "spawned 8 chairs (%d; before=%d)" % [cubes.size(), before.size()])
	var min_d := INF
	var max_v := 0.0
	for a in cubes:
		if a.held_by == 0: # the client test may be carrying one around right now
			max_v = maxf(max_v, a.linear_velocity.length())
		for b in cubes:
			if a != b:
				min_d = minf(min_d, a.global_position.distance_to(b.global_position))
	_check(min_d > 0.29, "spawned chairs don't overlap (min distance %.2f)" % min_d)
	_check(max_v < 0.5, "physics settles after spawning (max speed %.2f)" % max_v)
	if max_v >= 0.5:
		for c in cubes:
			print("[selftest] chair %d pos=%s vel=%s sleeping=%s freeze=%s" % [c.entity_id, c.global_position, c.linear_velocity, c.sleeping, c.freeze])
		for e in Sync.entities.values():
			if e.linear_velocity.length() > 0.3:
				print("[selftest]   moving: %s %s v=%s" % [e.kind, e.global_position, e.linear_velocity])
	for c in cubes:
		_check(Office.contains(c.global_position) and c.global_position.y > -0.1, "chair stayed in the room")
	for c in cubes:
		Sync.server_delete(c.entity_id)
	await _watch_and_menus()
	await _widgets(id)
	await _drawer()
	await _room_features(id)
	id = _restored_agent
	await _point_to_talk(id)
	# Speech: best-tts voices (headless has no GPU, so only the bubble shows here).
	_check(AI.voice_for({"voice": "bm_george"}) == "bm_george" and AI.voice_for({"voice": "alloy", "name": "Testy"}) in AI.VOICES,
			"agents speak with best-tts voices (old voice names map to one)")
	_check(KokoroTTS.has_voice("af_heart"), "the best-tts addon is installed")
	AI._say(AI._brains["a%d" % id], "Hello there.")
	var bubble_brain = AI._brains["a%d" % id]
	_check(bubble_brain.speak_until > AI._now(), "…and a reply still shows as speaking without a voice engine")
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 24000
	var pcm := PackedByteArray()
	pcm.resize(24000 * 2) # 1 s of silence at the addon's 24 kHz
	wav.data = pcm
	var before_speak: float = maxf(bubble_brain.speak_until, AI._now())
	AI._stream_clip(bubble_brain, id, wav)
	_check(absf(bubble_brain.speak_until - before_speak - 1.0) < 0.05, "a synthesized clip is streamed at 16 kHz and keeps the AI 'speaking' as long as it plays")
	# The OpenAI fallback: translation both ways, then a real turn against a
	# fake OpenAI-compatible server (tests/fake_openai_server.py) while Claude
	# has no key.
	var chat := OpenAIClient.to_chat_request({"system": [{"type": "text", "text": "Be nice."}], "max_tokens": 100,
			"tools": [{"name": "gesture", "description": "d", "input_schema": {"type": "object", "properties": {}}}],
			"messages": [
				{"role": "user", "content": [{"type": "text", "text": "hi"}, {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAAA"}}]},
				{"role": "assistant", "content": [{"type": "thinking", "thinking": "hm"}, {"type": "text", "text": "ok"}, {"type": "tool_use", "id": "t1", "name": "gesture", "input": {"kind": "wave"}}]},
				{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "done"}, {"type": "text", "text": "thanks"}]}]}, "m")
	var cm: Array = chat["messages"]
	_check(cm.size() == 5 and cm[0] == {"role": "system", "content": "Be nice."} and cm[1]["content"][1]["image_url"]["url"].begins_with("data:image/png;base64,")
			and cm[2]["tool_calls"][0]["function"]["arguments"] == "{\"kind\":\"wave\"}" and cm[3] == {"role": "tool", "tool_call_id": "t1", "content": "done"}
			and cm[4]["content"][0]["text"] == "thanks" and chat["tools"][0]["function"]["name"] == "gesture" and chat["max_completion_tokens"] == 100,
			"OpenAI fallback: Messages API request translated to Chat Completions")
	var back := OpenAIClient.from_chat_response({"choices": [{"finish_reason": "tool_calls", "message": {"content": "Sure.",
			"tool_calls": [{"id": "c9", "function": {"name": "gesture", "arguments": "{\"kind\":\"nod\"}"}}]}}]})
	_check(back["stop_reason"] == "tool_use" and back["content"][0]["text"] == "Sure." and back["content"][1] == {"type": "tool_use", "id": "c9", "name": "gesture", "input": {"kind": "nod"}},
			"…and its response translated back")
	var saved_key: Variant = Config.get_value("ai", "anthropic_api_key")
	Config._cfg.set_value("ai", "anthropic_api_key", "")
	Config._cfg.set_value("ai", "openai_api_key", "test-key")
	Config._cfg.set_value("ai", "openai_base_url", "http://127.0.0.1:%d/v1" % int(Config.args.get("fake_openai", 7791)))
	var said := []
	var on_say := func(eid: int, ev: String, args: Dictionary):
		if eid == id and ev == "say":
			said.append(args.get("text"))
	Sync.entity_event.connect(on_say)
	AI.request_text(id, "hello")
	var waited := 0.0
	while said.is_empty() and waited < 8.0:
		await _wait(0.2)
		waited += 0.2
	Sync.entity_event.disconnect(on_say)
	_check(said.has("Hello from the fallback."), "with no Anthropic key, agents answer with the OpenAI fallback (%s)" % [said])
	Config._cfg.set_value("ai", "openai_api_key", "")
	Config._cfg.set_value("ai", "anthropic_api_key", saved_key)
	# Talking without any API key must fail gracefully.
	AI.request_text(id, "hello")
	await _wait(1.0)
	_check(Sync.entities[id].data.get("status") in ["idle", "speaking"], "agent status after no-key reply")
	AI.server_summon_agent(id, 1)
	if Config.has_arg("shot"):
		var p: Node3D = get_node("/root/Main/LocalPlayer")
		# Seat the agent across the table and the player in the near chair.
		var chairs := Sync.entities_of_kind("chair")
		var ab: AgentBody = Sync.entities[id]
		Sync.poses[1]["r"] = Transform3D(Basis.IDENTITY, ab.global_position + Vector3(0, 1, 0))
		Sync.request_grab(id, 1, Transform3D.IDENTITY)
		ab.global_position = Sync.seat_xform(chairs[1]).origin
		Sync.request_release(id, Vector3.ZERO, Vector3.ZERO)
		Sync.poses[1]["head"] = Transform3D(Basis.IDENTITY, chairs[0].global_position + Vector3(0, 1, 0.5))
		Sync.request_interact(chairs[0].entity_id)
		p.set("_pitch", -0.25)
		await _wait(2.0)
		get_viewport().get_texture().get_image().save_png(str(Config.args["shot"]))
		Sync.request_stand()
		await _wait(0.3)
		# A context menu floating in front of the player.
		var cam: Camera3D = p.camera
		p.set("_pitch", 0.0)
		await _wait(0.2)
		p._open_menu({"type": "floor", "point": Vector3(1, 0, 1)}, cam.global_position - cam.global_basis.z * 0.55)
		await _wait(0.9)
		p._menu._activate(p._menu._current[1]) # Summon AI submenu
		await _wait(0.6)
		get_viewport().get_texture().get_image().save_png(str(Config.args["shot"]).replace(".png", "_menu.png"))
		p._menu.close()
		# The watch (VR only) held up in front of the desktop camera, Room menu open.
		var stand_in := Node3D.new()
		add_child(stand_in)
		var eye := cam.global_position
		stand_in.global_position = eye - cam.global_basis.z * 0.3 + Vector3(0, -0.09, 0)
		stand_in.global_basis = _basis_with_y(-(eye - stand_in.global_position).normalized()) # palm away
		var wt: Watch = load("res://scenes/player/watch.tscn").instantiate()
		add_child(wt)
		wt.track(stand_in, cam) # controller path: shows while looked at
		wt.open_menu(Watch.ROOM_MENU, p)
		await _wait(0.6)
		wt.track(stand_in, cam) # controller path: shows while looked at
		get_viewport().get_texture().get_image().save_png(str(Config.args["shot"]).replace(".png", "_watch.png"))
		wt.queue_free()
		# The virtual keyboard, and a highlighted object.
		var kb: VirtualKeyboard = p.open_keyboard("Name this save", "Team room", func(_t: String): pass)
		var target_obj: NetBody = Sync.entities_of_kind("monitor")[0]
		p.highlight.set_node(target_obj)
		p.set("_pitch", -0.35)
		await _wait(0.6)
		get_viewport().get_texture().get_image().save_png(str(Config.args["shot"]).replace(".png", "_keyboard.png"))
		kb.cancel()
		# Aim the crosshair at the cube: the player highlights what it targets.
		var eye_pos: Vector3 = p.camera.global_position
		var d: Vector3 = (target_obj.global_position - eye_pos).normalized()
		p.set("_yaw", atan2(-d.x, -d.z))
		p.set("_pitch", asin(d.y))
		await _wait(0.5)
		get_viewport().get_texture().get_image().save_png(str(Config.args["shot"]).replace(".png", "_highlight.png"))
		p.set("_pitch", 0.0)
		p.set("_yaw", 0.3)
		p.set("_yaw", -1.3)
		await _wait(1.0)
		get_viewport().get_texture().get_image().save_png(str(Config.args["shot"]).replace(".png", "_panel.png"))
	# Keep serving so the client test can knock, join and inspect.
	var t := 0.0
	while t < 15.0 and not Config.has_arg("quick"):
		await _wait(0.5)
		t += 0.5
		if Net.players.size() > 1:
			var peer: int = Net.players.keys().filter(func(p): return p != 1)[0]
			_check(Net.role(peer) == "member", "client admitted as member")
			var k := 0.0
			while Net.players.size() > 1 and k < 12.0:
				await _wait(0.5)
				k += 0.5
			_check(Net._members.has("clientsam"), "client remembered as member")
			break


## A synthetic tracked hand: wrist at `wrist`, fingers along the wrist's -Z.
## `index_curl`: bend per index joint (rad); the other fingers are curled.
func _pose_hand(tr: XRHandTracker, wrist: Transform3D, index_curl: float, tip_noise := Vector3.ZERO, others_curl := 1.3) -> void:
	tr.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, wrist)
	tr.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, wrist.translated_local(Vector3(0, 0, -0.05)))
	var fingers := {6: [0.02, index_curl], 11: [0.0, others_curl], 16: [-0.02, others_curl], 21: [-0.04, others_curl]}
	for base in fingers:
		var x: float = fingers[base][0]
		var curl: float = fingers[base][1]
		tr.set_hand_joint_transform(base, wrist.translated_local(Vector3(x, 0, -0.03)))
		var pos := Vector3(x, 0, -0.09)
		var dir := Vector3.FORWARD
		tr.set_hand_joint_transform(base + 1, wrist.translated_local(pos))
		for seg in 3:
			dir = dir.rotated(Vector3.RIGHT, -curl)
			pos += dir * [0.04, 0.025, 0.02][seg]
			var p := wrist * pos
			if seg == 2 and base == 6:
				p += tip_noise
			tr.set_hand_joint_transform(base + 2 + seg, Transform3D(wrist.basis, p))
	# Thumb well away from the index tip (no pinch).
	tr.set_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP, wrist.translated_local(Vector3(0.07, 0, -0.04)))


## The hand ray: anchored to the hand, following the finger's direction only
## while it's fully straight (so curling/pinching can't move it), smoothed.
func _ray_stability() -> void:
	var tr := XRHandTracker.new()
	tr.has_tracking_data = true
	var g := HandGestures.new(1)
	g.fixed_dt = 1.0 / 90.0
	var wrist := Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))
	for i in 120: # point for a moment (the ray learns the finger's direction)
		_pose_hand(tr, wrist, 0.0)
		g.update_from_hand(tr, Transform3D.IDENTITY)
	var knuckle := tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL).origin
	var finger_dir := (tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin - knuckle).normalized()
	var knuckle_line := (knuckle - wrist.origin).normalized()
	_check(g.pointing and g.ray_dir.angle_to(finger_dir) < deg_to_rad(1.0),
			"a straight finger aims the ray along the finger (%.1f deg off; the wrist-knuckle line is %.1f deg off)" % [
			rad_to_deg(g.ray_dir.angle_to(finger_dir)), rad_to_deg(knuckle_line.angle_to(finger_dir))])
	var fresh := HandGestures.new(1)
	fresh.fixed_dt = 1.0 / 90.0
	_pose_hand(tr, wrist, 0.5)
	fresh.update_from_hand(tr, Transform3D.IDENTITY)
	_check(fresh.ray_dir.angle_to(knuckle_line) < deg_to_rad(0.5), "before the finger has been straight, the ray follows the wrist-knuckle line")
	_pose_hand(tr, wrist, 0.0)
	var aimed := g.ray_dir
	var tip_dir0 := (tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin - wrist.origin).normalized()
	# Curl the index into the hand (retracting / pinching): the raw wrist->tip
	# line swings a lot, the ray not at all.
	var max_dev := 0.0
	var raw_swing := 0.0
	for i in 40:
		var curl := 0.9 * i / 39.0
		_pose_hand(tr, wrist, curl, Vector3(0.003, -0.002, 0.004) * sin(i))
		g.update_from_hand(tr, Transform3D.IDENTITY)
		max_dev = maxf(max_dev, rad_to_deg(g.ray_dir.angle_to(aimed)))
		var t := tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
		raw_swing = maxf(raw_swing, rad_to_deg((t - wrist.origin).normalized().angle_to(tip_dir0)))
	print("[selftest] ray while the index curls: raw wrist->tip swings %.1f deg, ray moves %.2f deg" % [raw_swing, max_dev])
	_check(max_dev < 0.4 and raw_swing > 20.0, "curling the index finger doesn't move the ray (%.2f deg)" % max_dev)
	# Turning the wrist carries the ray.
	var turned := Transform3D(Basis(Vector3.UP, deg_to_rad(25)), wrist.origin)
	for i in 90:
		_pose_hand(tr, turned, 0.0)
		g.update_from_hand(tr, Transform3D.IDENTITY)
	var follow := rad_to_deg(g.ray_dir.angle_to(aimed))
	_check(absf(follow - 25.0) < 1.0, "the ray follows the hand (%.1f of 25 deg)" % follow)
	# Tracking noise of +-2 mm on the wrist and knuckle is smoothed out.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var dirs: Array[Vector3] = []
	for i in 180:
		var n := func() -> Vector3: return Vector3(rng.randf_range(-0.002, 0.002), rng.randf_range(-0.002, 0.002), rng.randf_range(-0.002, 0.002))
		_pose_hand(tr, turned.translated(n.call()), 0.0)
		var k := tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL)
		tr.set_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, k.translated(n.call()))
		g.update_from_hand(tr, Transform3D.IDENTITY)
		if i >= 90:
			dirs.append(g.ray_dir)
	var mean := Vector3.ZERO
	for d in dirs:
		mean += d
	mean = mean.normalized()
	var worst := 0.0
	for d in dirs:
		worst = maxf(worst, rad_to_deg(d.angle_to(mean)))
	print("[selftest] ray jitter with +-2 mm wrist/knuckle noise: max %.2f deg from mean" % worst)
	_check(worst < 0.6, "tracking jitter is smoothed (%.2f deg)" % worst)
	# ...but deliberate aiming isn't laggy: a quick 30 deg turn is followed within ~0.15 s.
	var start_dir := g.ray_dir
	var quick := Transform3D(Basis(Vector3.UP, deg_to_rad(55)), wrist.origin)
	var frames := 0
	for i in 45:
		var k := clampf(i / 6.0, 0.0, 1.0) # the turn itself takes ~65 ms
		_pose_hand(tr, turned.interpolate_with(quick, k), 0.0)
		g.update_from_hand(tr, Transform3D.IDENTITY)
		frames = i
		if rad_to_deg(g.ray_dir.angle_to(start_dir)) > 27.0:
			break
	print("[selftest] ray follows a quick 30 deg turn in %d ms" % int(frames * 1000.0 / 90.0))
	_check(frames * 1000.0 / 90.0 < 170.0, "smoothing doesn't lag deliberate aiming")
	# A pinch click lands on the button the ray was on just before the pinch.
	var rig := Node3D.new()
	add_child(rig)
	var hand := Hand.make(1)
	rig.add_child(hand)
	var ptr: Pointer = load("res://scenes/player/pointer.tscn").instantiate()
	ptr.hand = hand
	ptr.rig = rig
	rig.add_child(ptr)
	var b := PokeButton.make(rig, "X", Vector3(0, 1.5, -1.0), Color.WHITE, Vector2(0.06, 0.06))
	var presses := [0]
	b.pressed.connect(func(): presses[0] += 1)
	await get_tree().physics_frame
	var pg := HandGestures.new(1)
	pg.source = "hand"
	pg.pointing = true
	pg.ray_origin = Vector3(0, 1.5, 0)
	pg.ray_dir = Vector3.FORWARD
	ptr.update_pointer(pg)
	_check(ptr._hover == b, "ray on the button")
	await _wait(0.25)
	ptr.update_pointer(pg)
	pg.ray_dir = Vector3(0.1, 0, -1).normalized() # the pinch jerks the ray off it…
	ptr.update_pointer(pg)
	_check(ptr._hover == null, "…the pinch nudges the ray off")
	pg.pinch_started = true
	b._cooldown = 0.0
	ptr.update_pointer(pg)
	_check(presses[0] == 1, "…and still clicks the button it was on")
	rig.queue_free()


## The wrist watch: when it shows, and its Me / Room menus.
func _watch_and_menus() -> void:
	var up := Vector3.UP
	_check(Watch.should_show_back_of_hand(up, up, false), "back of the hand facing the eyes shows the watch")
	_check(not Watch.should_show_back_of_hand(Vector3.DOWN, up, false), "palm toward the eyes: no watch")
	_check(not Watch.should_show_back_of_hand(Vector3(1, 0.4, 0), up, false) and Watch.should_show_back_of_hand(Vector3(1, 0.4, 0), up, true),
			"hysteresis: a slightly turned wrist keeps a shown watch but doesn't show a hidden one")
	_check(Watch.should_show_looked_at(Vector3.FORWARD, Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(10)), false)
			and not Watch.should_show_looked_at(Vector3.FORWARD, Vector3.RIGHT, false), "controllers: shows when you look at your wrist")
	# Back-of-hand normal from joint positions (left hand, palm down, fingers forward: back is up).
	var n := Watch.back_of_left_hand(Vector3.ZERO, Vector3(0.03, 0, -0.08), Vector3(-0.04, 0, -0.07))
	_check(n.y > 0.99, "back-of-left-hand normal points out of the back (%s)" % n)
	_check(Watch.should_show_back_of_hand(Vector3.UP, Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(55)), false)
			and not Watch.should_show_back_of_hand(Vector3.UP, Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(65)), false),
			"shows within ~60 degrees")
	_check(Watch.should_show_back_of_hand(Vector3.UP, Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(65)), true),
			"once shown, stays until ~70 degrees")
	# A real watch on a synthetic tracked left hand, camera (your eyes) above it.
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = Vector3(20, 1.7, 0.3)
	var tr := XRHandTracker.new()
	tr.has_tracking_data = true
	var hand := Node3D.new()
	add_child(hand)
	var watch: Watch = load("res://scenes/player/watch.tscn").instantiate()
	add_child(watch)
	# Palm down (back of the hand up, toward the eyes): like looking at a watch.
	_pose_hand(tr, Transform3D(Basis.IDENTITY, Vector3(20, 1.3, 0)), 0.3, Vector3.ZERO, 0.6)
	watch.track(hand, cam, tr)
	_check(watch.shown and watch.visible, "back of the wrist toward your eyes shows the watch")
	var n_hand := watch.global_basis.y
	_check(n_hand.y > 0.9, "watch face sits on the back of the wrist (up), not the palm")
	await get_tree().process_frame
	_check(watch.get_node("%Time").text.contains(":"), "watch shows the time")
	var player: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	var m := watch.open_menu(Watch.ROOM_MENU, player)
	_check(is_instance_valid(m) and m.get_parent() == watch.get_node("%MenuAnchor"), "watch menu floats above the watch")
	_check(m.global_position.y > watch.get_node("%Face").global_position.y + 0.05, "…above it")
	# Palm turned up toward your face: no watch. (Its open menu stays.)
	_pose_hand(tr, Transform3D(Basis(Vector3.FORWARD, PI), Vector3(20, 1.3, 0)), 0.3, Vector3.ZERO, 0.6)
	watch.track(hand, cam, tr)
	await get_tree().process_frame
	_check(not watch.shown, "palm toward your face hides the watch")
	watch.close_menu()
	# A tilted wrist (50 degrees off) still shows it.
	_pose_hand(tr, Transform3D(Basis(Vector3.FORWARD, deg_to_rad(50)), Vector3(20, 1.3, 0)), 0.3, Vector3.ZERO, 0.6)
	watch.track(hand, cam, tr)
	_check(watch.shown, "a wrist tilted ~50 degrees still shows the watch")
	watch.queue_free()
	hand.queue_free()
	cam.queue_free()
	if not player:
		return
	# Room menu (desktop path of the same menus).
	var rm: RadialMenu = player.open_watch_menu("room")
	await _wait(0.8)
	var labels := rm._current.map(func(i): return i["label"])
	_check(labels == ["Room size", "Objects", "Rename room", "Permissions", "Saves", "Join requests"], "room menu: %s" % [labels])
	_check(not rm._current[5].get("enabled", true), "no join requests -> greyed out")
	var w := Office.size().x
	rm._activate(rm._current[0]) # Room size
	await _wait(0.4)
	rm._activate(rm._current.filter(func(i): return i["label"] == "Wider")[0])
	_check(Office.size().x == w + 1.0 and rm.get_node("%Hint").text.contains("wide"), "room menu: Room size > Wider (and shows the size)")
	# A knock appears under Join requests and can be answered there.
	Net._receive_prompt("knock", FAKE_KNOCK, "Zed is knocking.\nLet them in?")
	rm.home()
	await _wait(0.1)
	_check(rm._current[5]["label"] == "Join requests (1)" and rm._current[5].get("enabled", true), "join request listed")
	rm._armed_at = 0
	rm._activate(rm._current[5])
	await _wait(0.4)
	_check(rm._current[1]["label"] == "Zed", "knocking person listed by name")
	rm._activate(rm._current[1])
	await _wait(0.4)
	rm._activate(rm._current.filter(func(i): return i["label"] == "Decline")[0])
	_check(Net.prompts_of("knock").is_empty() and rm._current[5]["label"] == "Join requests", "answered from the watch")
	# Me menu: mute and ray toggles.
	var me: RadialMenu = player.open_watch_menu("me")
	_check(not is_instance_valid(rm) or rm.is_queued_for_deletion(), "opening another watch menu replaces the first")
	await _wait(0.8)
	var was_muted := Voice.muted
	var item := func(prefix: String) -> Dictionary:
		return me._current.filter(func(i): return str(i["label"]).begins_with(prefix))[0]
	me._activate(me._current[0])
	_check(Voice.muted != was_muted and me._current[0]["label"] == ("Unmute me" if Voice.muted else "Mute me"), "Me: mute toggles")
	me._activate(me._current[0])
	me._activate(item.call("Rays"))
	_check(not player.rays_visible() and not player.pointers[0].ray_visible, "Me: rays off")
	me._activate(item.call("Rays"))
	_check(player.rays_visible(), "Me: rays back on")
	me._activate(item.call("Highlight"))
	_check(not player.highlight.enabled and Config.pref("highlight_targets", true) == false, "Me: highlight off (remembered)")
	me._activate(item.call("Highlight"))
	_check(player.highlight.enabled, "Me: highlight back on")
	me._activate(item.call("Switch room"))
	await _wait(0.4)
	_check(not me._current[1].get("enabled", true) and me._current[1]["label"] == "My office", "Switch room: already in my office")
	me.close()


## Locking, guest permissions, highlight, keyboard, sitting from afar, saves.
func _room_features(agent_id: int) -> void:
	var chairs := Sync.entities_of_kind("chair")
	var table: NetBody = Sync.entities_of_kind("table")[0]
	_check(chairs.all(func(c): return c.is_locked()) and table.is_locked(), "furniture starts locked")
	var cube: NetBody = Sync.entities_of_kind("cube")[0] if Sync.entities_of_kind("cube").size() else Sync.entities_of_kind("ball")[0]
	var cube_kind := cube.kind
	_check(not cube.is_locked(), "loose objects start unlocked")
	Office.request_action("lock_all", {"on": true})
	_check(cube.is_locked() and table.is_locked(), "lock all")
	Office.request_action("lock_all", {"on": false})
	_check(not cube.is_locked() and not table.is_locked(), "unlock all")
	for c in chairs:
		Office.request_action("lock", {"entity": c.entity_id}) # back to locked
	Office.request_action("lock", {"entity": table.entity_id})
	# Guest permissions: off by default, admins toggle them.
	Office.request_action("member_perm", {"perm": "lock", "on": true})
	_check(Office.member_may("lock"), "admin can let guests lock/unlock")
	Office.request_action("member_perm", {"perm": "lock", "on": false})
	# Sitting via the menu works from across the room; direct interaction needs reach.
	var chair: NetBody = chairs[0]
	Sync.poses[1]["head"] = Transform3D(Basis.IDENTITY, chair.global_position + Vector3(4.0, 1.2, 3.0))
	_toasts.clear()
	Sync.request_interact(chair.entity_id)
	_check(int(chair.data.get("seated", 0)) == 0 and _toasts.any(func(t: String): return t.begins_with("Too far")), "trigger/E from 5 m: too far (and says so)")
	Office.request_action("sit", {"entity": chair.entity_id})
	_check(int(chair.data.get("seated", 0)) == 1, "menu 'Sit here' works from across the room")
	Sync.request_stand()
	var player: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	if player:
		# Highlight: outlines targets (not the floor), and can be turned off.
		var hl: TargetHighlight = player.highlight
		var mesh: MeshInstance3D = cube.find_children("*", "MeshInstance3D")[0]
		hl.show_target({"type": "object", "entity_id": cube.entity_id})
		_check(mesh.material_overlay != null, "the targeted object is outlined")
		hl.show_target({"type": "floor", "point": Vector3.ZERO})
		_check(mesh.material_overlay == null and hl.current() == null, "walls/floor are never outlined")
		player.set_highlight_enabled(false)
		hl.show_target({"type": "object", "entity_id": cube.entity_id})
		_check(mesh.material_overlay == null, "highlight off: no outline")
		player.set_highlight_enabled(true)
		_check(mesh.material_overlay != null, "highlight back on")
		hl.show_target({})
		# The virtual keyboard: poke keys, shift, delete, done.
		var got := [""]
		var kb: VirtualKeyboard = player.open_keyboard("Test", "", func(t: String): got[0] = t)
		await get_tree().process_frame
		var keys := kb.get_node("%Keys").get_children()
		var key := func(label: String) -> PokeButton:
			return keys.filter(func(k): return k.text == label)[0]
		key.call("Shift").press()
		key.call("H").press() # capital after Shift (one letter, like a phone)
		for ch in ["i", "x"]:
			key.call(ch).press()
		key.call("Del").press()
		key.call("space").press()
		key.call("2").press()
		key.call("Done").press()
		_check(got[0] == "Hi 2" and not VirtualKeyboard.is_open(), "keyboard typed 'Hi 2' (got '%s')" % got[0])
	# Saves: save, change things, load it back.
	var agent: NetBody = Sync.entities[agent_id]
	Office.request_action("rename", {"name": "Selftest HQ"})
	Widgets.find("whiteboard", "Main board").server_show({"title": "Saved plan", "text": "keep me"})
	cube.global_position = Vector3(1.23, 0.5, -1.5)
	var before := {"entities": Sync.entities.size(), "agents": Sync.entities_of_kind("agent").size(),
			"cube_locked": cube.is_locked(), "size": Office.size()}
	Saves.delete_file("selftest save")
	if Widgets.find("timer", ""):
		_timer_left = Widgets.find("timer", "").time_left()
	Saves.request_save_as("selftest save")
	_check(Saves.has_save("selftest save") and Saves.list_saves().any(func(v): return v["name"] == "selftest save"), "saved under a name")
	# Change the room: delete the cube and the agent, rename, resize.
	Sync.server_delete(cube.entity_id)
	AI.server_remove_agent(agent_id)
	Office.request_action("rename", {"name": "Changed"})
	Office.request_action("room", {"step": "w+"})
	_check(Sync.entities_of_kind("agent").size() == before["agents"] - 1, "changed the room")
	Saves.request_load("selftest save")
	_check(Office.state.get("name") == "Selftest HQ" and Office.size() == before["size"], "load restores the room's name and size")
	var restored_board: WhiteboardWidget = Widgets.find("whiteboard", "Main board")
	_check(restored_board != null and restored_board.data.get("title") == "Saved plan" and int(restored_board.data.get("image", 0)) > 0, "…and the whiteboard, with its picture")
	_check(Sync.entities.size() == before["entities"] and Sync.entities_of_kind("agent").size() == before["agents"], "…all objects and agents")
	var testy: Array = Sync.entities_of_kind("agent").filter(func(a): return a.data.get("name") == "Testy")
	_check(testy.size() == 1, "…including the AI agent (by profile)")
	var cubes_at := Sync.entities_of_kind(cube_kind).filter(func(c): return c.global_position.distance_to(Vector3(1.23, 0.5, -1.5)) < 0.05)
	_check(cubes_at.size() == 1, "…with objects where they were")
	_check(Sync.entities_of_kind("chair").all(func(c): return c.is_locked()), "…and their locked state")
	var cal := Widgets.find("calendar", "Team")
	_check(cal != null and cal.entries().size() >= 1 and Widgets.find("whiteboard", "Ideas") != null, "…and the wall widgets with their contents")
	var board := Widgets.find("whiteboard", "Ideas")
	if board:
		_check(board.strokes().size() >= 1, "…and the drawing")
	var tmr: TimerWidget = Widgets.find("timer", "")
	_check(tmr != null and not tmr.is_running() and absf(tmr.time_left() - _timer_left) < 0.5, "…and the timer, paused with the time it had left (%.1f of %.1f)" % [tmr.time_left() if tmr else -1.0, _timer_left])
	Saves.delete_file("selftest save")
	_check(not Saves.has_save("selftest save"), "delete a save")
	Saves.autosave()
	_check(Saves.has_save(Saves.AUTOSAVE), "autosave written")
	# The rest of the test keeps using the agent (it was recreated by the load).
	_restored_agent = testy[0].entity_id if testy.size() else agent_id
	AI._brains["a%d" % _restored_agent].profile["name"] = "Testy"


## Wall widgets: the wall menu, placement, names, each widget's operations,
## the whiteboard's brushes and pens, the timer, the MCP tools and skill, AI
## change notes, per-AI mute / point-to-talk, resizing, removal.
func _widgets(agent_id: int) -> void:
	var player: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	var north: Node = Office.node.get_node("%Shell").get_node("north")
	var hit := {"collider": north, "position": Vector3(-2.5, 1.6, -Office.size().z * 0.5), "normal": Vector3(0, 0, 1)}
	var t := Pointer.classify(hit)
	_check(t.get("type") == "wall" and t.get("surface") == "north", "pointing at a wall: %s" % [t])
	var brain = AI._brains["a%d" % agent_id]
	brain.widget_notes.clear()
	# Wall menu → Add widget → Calendar.
	if player:
		player._open_menu(t, Vector3(0, 1.4, 1))
		var menu: RadialMenu = player._menu
		_check(menu._current.map(func(i): return i["label"]) == ["Add widget", "Wall color", "All walls", "Teleport here"], "wall menu items")
		await _wait(0.8)
		menu._activate(menu._current[0])
		await _wait(0.4)
		_check(menu._current.map(func(i): return i["label"]) == ["Back", "Calendar", "Alarm", "Timer", "Whiteboard", "TV"], "Add widget: calendar, alarm, timer, whiteboard, TV")
		menu._activate(menu._current[1])
	else:
		Widgets.request_add("calendar", "north", hit["position"])
	var cal: CalendarWidget = Sync.entities_of_kind("calendar")[-1] if Sync.entities_of_kind("calendar").size() else null
	_check(cal != null and cal.widget_name() == "Calendar", "calendar hung on the wall")
	if not cal:
		return
	_check(cal.global_position.distance_to(Vector3(-2.5, 1.6, -Office.size().z * 0.5 + Widgets.WALL_GAP)) < 0.01, "…where the ray hit (%s)" % cal.global_position)
	_check(cal.global_basis.z.dot(Vector3(0, 0, 1)) > 0.99, "…facing into the room")
	# Paint this wall from the same menu.
	Office.request_action("paint", {"surface": "north", "color": "#81b29a"})
	_check(Office.state["colors"]["north"] == "#81b29a", "wall menu paints the wall")
	# More widgets; a second calendar gets a distinct default name.
	Widgets.request_add("calendar", "north", Vector3(1.0, 1.6, 0))
	Widgets.request_add("alarm", "east", Vector3(Office.size().x * 0.5, 1.5, 1.0))
	Widgets.request_add("whiteboard", "west", Vector3(-Office.size().x * 0.5, 1.5, 0.0))
	Widgets.request_add("tv", "south", Vector3(0, 1.7, Office.size().z * 0.5))
	_check(Widgets.names_of("calendar") == ["Calendar", "Calendar 2"], "duplicate widgets get distinct names: %s" % [Widgets.names_of("calendar")])
	var alarm: AlarmWidget = Widgets.find("alarm", "")
	var board: WhiteboardWidget = Widgets.find("whiteboard", "Whiteboard")
	var tv: TvWidget = Widgets.find("tv", "")
	_check(alarm != null and board != null and tv != null, "alarm, whiteboard and TV hung")
	# Renaming (the keyboard's result goes through the same request).
	Widgets.request_op(cal.entity_id, "rename", {"name": "Team"})
	Widgets.request_op(board.entity_id, "rename", {"name": "Ideas"})
	_toasts.clear()
	Widgets.request_op(Widgets.find("calendar", "Calendar 2").entity_id, "rename", {"name": "team"})
	_check(cal.widget_name() == "Team" and Widgets.names_of("calendar").has("Calendar 2") and _toasts.size() == 1, "rename; names stay unique per kind")
	if player:
		player._open_menu({"type": "widget", "entity_id": cal.entity_id, "point": cal.global_position}, Vector3(0, 1.4, 1))
		var labels: Array = player._menu._current.map(func(i): return i["label"])
		_check(labels.front() == "Rename…" and labels.back() == "Remove", "widget menu: Rename… … Remove (%s)" % [labels])
		player._menu.close()
		# Desktop right-click on a widget's button opens the widget's menu too.
		var day_button: PokeButton = cal.get_node("%Grid").get_child(10)
		var bt := Pointer.classify({"collider": day_button, "position": day_button.global_position})
		_check(bt.get("type") == "button" and int(bt.get("entity_id", 0)) == cal.entity_id, "a widget's button knows its widget")
	# Widgets can't be picked up.
	Sync.poses[1]["r"] = Transform3D(Basis.IDENTITY, cal.global_position)
	Sync.request_grab(cal.entity_id, 1, Transform3D.IDENTITY)
	_check(cal.held_by == 0, "widgets can't be picked up")
	# Calendar: entries from people, times parsed, a month of day buttons.
	var today := CalendarWidget.today()
	Widgets.request_op(cal.entity_id, "add_entry", {"date": today, "time": "2pm", "text": "Standup"})
	_check(cal.entries().size() == 1 and cal.entries()[0]["time"] == "14:00", "calendar entry added (2pm → 14:00)")
	_check(CalendarWidget.split_time_text("9:30 Coffee chat") == ["09:30", "Coffee chat"] and CalendarWidget.split_time_text("Offsite") == ["", "Offsite"], "keyboard entry parsing")
	var y := int(today.substr(0, 4))
	var m := int(today.substr(5, 2))
	var shown := cal.get_node("%Grid").get_children().filter(func(b): return b.visible).size()
	_check(shown == CalendarWidget.days_in_month(y, m), "a button for every day of the month (%d)" % shown)
	if player:
		var day: PokeButton = cal.get_node("%Grid").get_children().filter(func(b): return b.visible and b.get_meta("date", "") == today)[0]
		cal._on_day(cal.get_node("%Grid").get_children().find(day))
		var labels: Array = player._menu._current.map(func(i): return i["label"])
		_check(labels.size() == 2 and labels[0] == "Add…" and str(labels[1]).contains("Standup"), "poking a day lists its entries (%s)" % [labels])
		player._menu.close()
	# The MCP server: initialize, list tools, call them (as the agent would).
	var init := WidgetMcp.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}, 1)
	_check(init["result"]["serverInfo"]["name"] == "office-plus-one-widgets", "MCP initialize")
	var listed: Array = WidgetMcp.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, 1)["result"]["tools"]
	_check(listed.map(func(x): return x["name"]) == ["widget_list", "widget_calendar", "widget_alarm", "widget_timer", "widget_whiteboard"] and listed.all(func(x): return x.has("inputSchema")), "MCP tools/list")
	var req := {"peer": 1, "text": ""}
	var r: String = await AI._run_tool(brain, req, "widget_calendar", {"calendar_name": "team", "date": "tomorrow", "time": "09:00", "contents": "Demo"})
	_check(cal.entries().size() == 2 and r.begins_with("Added"), "AI writes on the calendar: " + r)
	r = await AI._run_tool(brain, req, "widget_calendar", {"calendar_name": "Nope", "date": "today", "contents": "x"})
	_check(r.begins_with("Error") and r.contains("\"Team\""), "unknown calendar lists the real names: " + r)
	r = await AI._run_tool(brain, req, "widget_alarm", {"alarm_name": "", "time": "7:30am"})
	_check(alarm.alarm_time() == "07:30" and alarm.is_enabled(), "AI sets the alarm: " + r)
	r = await AI._run_tool(brain, req, "widget_whiteboard", {"whiteboard_name": "Ideas", "text": "Ship it"})
	r = await AI._run_tool(brain, req, "widget_whiteboard", {"whiteboard_name": "Ideas", "text": "Then party", "mode": "append"})
	_check(str(board.data.get("text")) == "Ship it\nThen party" and board.get_node("%Text").text == "Ship it\nThen party", "AI writes on the whiteboard")
	var listing: String = await AI._run_tool(brain, req, "widget_list", {})
	_check(listing.contains("calendar \"Team\"") and listing.contains("alarm \"Alarm\"") and listing.contains("widget_whiteboard(whiteboard_name=\"Ideas\""), "widget_list names every widget and how to use it")
	# The agent is kept up to date: skill in its system prompt, changes in its context.
	_check(AI._system_prompt(brain).contains("widget_calendar(calendar_name"), "the widgets skill is preloaded into the system prompt")
	var ctx: String = AI._context(brain, 1)
	_check(ctx.contains("Wall widgets (updated)") and ctx.contains("HostPat added calendar") and ctx.contains("\"Team\""), "context lists the new widgets and what changed")
	_check(not ctx.contains("Testy set alarm"), "…but not the agent's own actions")
	_check(not AI._context(brain, 1).contains("(updated)"), "…and only the names once nothing's changed")
	# Alarm: goes off at its time, rings until stopped.
	var parts := alarm.alarm_time().split(":")
	var now := {"year": 2026, "month": 9, "day": 26, "hour": int(parts[0]), "minute": int(parts[1])}
	alarm.server_tick(now)
	_check(alarm.is_ringing() and alarm.get_node("%Stop").visible, "alarm rings at its time")
	Widgets.request_op(alarm.entity_id, "stop")
	alarm.server_tick(now)
	_check(not alarm.is_ringing(), "Stop silences it (and it doesn't ring again that minute)")
	Widgets.request_op(alarm.entity_id, "adjust", {"minutes": -60})
	_check(alarm.alarm_time() == "06:30", "−1h button")
	# Whiteboard: the palette picks your brush; pens draw with it.
	var palette: Array = board.get_children().filter(func(c): return c is PokeButton and c.has_meta("brush"))
	_check(palette.size() == 8, "whiteboard palette: 4 colours, 3 sizes, eraser (%d)" % palette.size())
	var red: PokeButton = palette.filter(func(b): return b.get_meta("brush").get("c") == "#c93a2a")[0]
	red._cooldown = 0.0
	red.press()
	var large: PokeButton = palette.filter(func(b): return b.get_meta("brush").get("w") == 18)[0]
	large.press()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(WhiteboardWidget.brush_ink() == "#c93a2a" and WhiteboardWidget.brush_width() == 18 and red.text == "•" and large.text == "[L]", "pressing palette buttons sets (and shows) your brush")
	var pen := BoardPen.new()
	pen.draw(board, board.face_point(Vector2(0.3, 0.5)), 0.01)
	pen.draw(board, board.face_point(Vector2(0.6, 0.55)), 0.06)
	pen.lift()
	var last: Dictionary = board.strokes()[-1] if board.strokes().size() else {}
	_check(last.get("c") == "#c93a2a" and int(last.get("w", 0)) == 18, "drawing uses your brush (%s)" % [last.get("c"), ])
	var px: Color = board._image.get_pixel(int(0.45 * WhiteboardWidget.TEX.x), int(0.525 * WhiteboardWidget.TEX.y))
	_check(px.r > 0.6 and px.g < 0.4, "…a red line across the board (%s)" % px)
	palette.filter(func(b): return b.get_meta("brush").get("erase") == true)[0].press()
	pen.draw(board, board.face_point(Vector2(0.45, 0.525)), 0.06)
	pen.lift()
	_check(board.strokes()[-1]["c"] == WhiteboardWidget.ERASE and board._image.get_pixel(int(0.45 * WhiteboardWidget.TEX.x), int(0.525 * WhiteboardWidget.TEX.y)).is_equal_approx(WhiteboardWidget.BG), "the eraser rubs it out")
	WhiteboardWidget.set_brush({"c": WhiteboardWidget.COLORS[0], "w": 4, "erase": false})
	pen.draw(board, board.face_point(Vector2(0.2, 0.2)), 0.06)
	pen.lift()
	# Drawing from afar: point at the board, then hold a pinch and move the ray.
	var rig := Node3D.new()
	add_child(rig)
	var dhand := Hand.make(1)
	rig.add_child(dhand)
	var ptr: Pointer = load("res://scenes/player/pointer.tscn").instantiate()
	ptr.hand = dhand
	ptr.rig = rig
	rig.add_child(ptr)
	var dg := HandGestures.new(1)
	dg.source = "hand"
	dg.pointing = true
	dg.ray_origin = board.global_position + board.global_basis.z * 1.5
	dg.ray_dir = -board.global_basis.z
	await get_tree().physics_frame
	ptr.update_pointer(dg)
	_check(ptr.state == Pointer.State.POINTING and ptr.target.get("type") == "widget" and ptr.draw_board == null, "pointing at a board (not drawing yet)")
	dg.pointing = false
	dg.pinch = true
	var sup := ptr.update_pointer(dg)
	_check(ptr.draw_board == board and sup["grip"], "holding a pinch on it draws with the ray")
	dg.ray_dir = (board.face_point(Vector2(0.7, 0.3)) - dg.ray_origin).normalized()
	for i in 40:
		ptr.update_pointer(dg) # a pinch held for a while still draws (and never locks for a menu)
	_check(ptr.draw_board == board and ptr.state == Pointer.State.POINTING and ptr.draw_point.distance_to(board.face_point(Vector2(0.7, 0.3))) < 0.03, "…following the ray as it moves")
	dg.pinch = false
	ptr.update_pointer(dg)
	_check(ptr.draw_board == null, "letting go of the pinch stops drawing")
	rig.queue_free()
	# Timer: set by an AI (resets and starts), runs out and rings; people set, start, stop, reset.
	Widgets.request_add("timer", "east", Vector3(Office.size().x * 0.5, 1.5, -1.5))
	var timer: TimerWidget = Widgets.find("timer", "")
	_check(timer != null and not timer.is_running(), "timer hung")
	r = await AI._run_tool(brain, req, "widget_timer", {"timer_name": "", "time_minutes": 0, "time_seconds": 2})
	_check(timer.is_running() and timer.duration() == 2 and timer.time_left() <= 2.0, "AI sets the timer; it starts right away: " + r)
	await _wait(2.4)
	_check(timer.is_ringing() and not timer.is_running() and timer.time_left() == 0.0, "the timer rings when it runs out")
	Widgets.request_op(timer.entity_id, "stop")
	_check(not timer.is_ringing(), "Stop silences it")
	Widgets.request_op(timer.entity_id, "set", {"time": "1m30s"})
	_check(timer.duration() == 90 and not timer.is_running() and timer.time_left() == 90.0, "Set… 1m30s")
	Widgets.request_op(timer.entity_id, "adjust", {"seconds": -10})
	Widgets.request_op(timer.entity_id, "start")
	await _wait(0.3)
	_check(timer.is_running() and timer.time_left() < 80.0 and timer.time_left() > 79.0, "−10s, then Start counts down (%.2f)" % timer.time_left())
	Widgets.request_op(timer.entity_id, "stop")
	var paused := timer.time_left()
	await _wait(0.3)
	_check(not timer.is_running() and timer.time_left() == paused, "Stop pauses it")
	Widgets.request_op(timer.entity_id, "reset")
	_check(timer.time_left() == 80.0 and TimerWidget.parse_time("5:00") == 300 and TimerWidget.parse_time("1h5m") == 3900 and TimerWidget.format_time(75) == "01:15", "Reset, and time parsing")
	Widgets.request_op(timer.entity_id, "start") # (left running for the save test)
	# AIs: mute one or turn off point-to-talk for it (just for you). Muting
	# one mid-sentence stops its mouth too (it used to keep "talking").
	var ab: AgentBody = Sync.entities[agent_id]
	var tone := PackedFloat32Array()
	for i in 16000:
		tone.append(sin(i * 0.2) * 0.5)
	ab.voice.push_pcm(tone)
	await _wait(0.3)
	Voice.set_agent_muted(agent_id, true)
	_check(ab.voice.level == 0.0 and not ab.voice.is_talking(), "muting an AI while it talks stops its voice and talking animation")
	Voice._play_speech("agent", agent_id, VoiceCodec.encode_ulaw(tone))
	await _wait(0.3)
	_check(not ab.voice.is_talking(), "…and a muted AI's speech isn't played")
	Voice.set_agent_listens(agent_id, false)
	_check(Voice.is_agent_muted(agent_id) and LocalPlayer_talk(agent_id) == -1, "mute an AI, and turn point-to-talk off for it")
	Voice.set_agent_muted(agent_id, false)
	Voice.set_agent_listens(agent_id, true)
	_check(not Voice.is_agent_muted(agent_id) and LocalPlayer_talk(agent_id) == agent_id, "…and back on")
	# TV: connect via its menu's request, bad addresses refused.
	_toasts.clear()
	Widgets.request_op(tv.entity_id, "vnc", {"address": "not a host!", "password": ""})
	_check(not RemoteDisplay.is_connected_data(tv.data.get("vnc")) and _toasts.size() == 1, "TV refuses a bad address")
	Widgets.request_op(tv.entity_id, "vnc", {"address": "127.0.0.1:1", "password": "pw"})
	_check(tv.data["vnc"]["host"] == "127.0.0.1" and int(tv.data["vnc"]["port"]) == 5901, "TV set to host:display (:1 → 5901)")
	Widgets.request_op(tv.entity_id, "vnc", {"address": ""})
	_check(not RemoteDisplay.is_connected_data(tv.data.get("vnc")), "TV disconnect")
	var mon: NetBody = Sync.entities_of_kind("monitor")[0]
	if player:
		player._open_menu({"type": "object", "entity_id": mon.entity_id, "point": mon.global_position}, Vector3(0, 1.4, 1))
		_check(player._menu._current.any(func(i): return i["label"] == "Connect…"), "monitor menu: Connect… (same screen code as the TV)")
		player._menu.close()
	# Resizing the room keeps widgets on their walls.
	Office.request_action("room", {"step": "w+"})
	_check(absf(alarm.global_position.x - (Office.size().x * 0.5 - Widgets.WALL_GAP)) < 0.01, "a wider room moves the east wall's widgets with it")
	Office.request_action("room", {"step": "w-"})
	# Removing (the Remove confirm goes through the same request).
	var cal2 := Widgets.find("calendar", "Calendar 2")
	Widgets.request_op(cal2.entity_id, "remove")
	_check(not is_instance_valid(cal2) or cal2.is_queued_for_deletion() or not Sync.entities.has(cal2.entity_id), "remove a widget")
	# Leave Team, Ideas (with its drawing), the alarm and the TV for the save/load test.


## Drawers: a folder on the host, the file browser, pulling copies out.
static func LocalPlayer_talk(agent_id: int) -> int:
	return load("res://scripts/player/local_player.gd")._talk_target_of({"type": "agent", "entity_id": agent_id})


func _drawer() -> void:
	var dir := "/tmp/opo_selftest_drawer"
	DirAccess.make_dir_recursive_absolute(dir.path_join("sub"))
	FileAccess.open(dir.path_join("a.txt"), FileAccess.WRITE).store_string("drawer file A")
	FileAccess.open(dir.path_join("sub/b.md"), FileAccess.WRITE).store_string("# B")
	FileAccess.open(dir.path_join(".hidden"), FileAccess.WRITE).store_string("x")
	var drawer: FileDrawer = Sync.entities_of_kind("drawer")[0]
	var id := drawer.entity_id
	Widgets.request_op(id, "set_path", {"path": dir})
	_check(drawer.folder() == dir and drawer.get_node("%FolderLabel").text == "opo_selftest_drawer", "admin links the drawer to a folder")
	var got := []
	var on_list := func(d: int, rel: String, entries: Array, err: String): got.append([d, rel, entries, err])
	Widgets.listing_received.connect(on_list)
	Widgets.request_listing(id, "")
	_check(got.size() == 1 and got[0][2].map(func(e): return e["n"]) == ["sub", "a.txt"], "listing: folders first, hidden files skipped (%s)" % [got])
	_check(drawer.resolve("../etc") == "" and drawer.resolve("sub/../../x") == "" and drawer.resolve("sub") == dir + "/sub", "can't leave the drawer's folder")
	Widgets.request_listing(id, "..")
	_check(got.size() == 2 and got[1][3] != "", "listing outside the folder is refused")
	Widgets.listing_received.disconnect(on_list)
	# Opening it (trigger / E, or pulling the handle) opens the browser for whoever opened it.
	var player: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	Sync.poses[1]["head"] = Transform3D(Basis.IDENTITY, drawer.global_position + Vector3(0, 1.0, 1.0))
	Sync.request_interact(id)
	_check(drawer.is_open() and int(drawer.data.get("opened_by", 0)) == 1, "trigger/E opens the drawer")
	await get_tree().process_frame
	if player:
		var browser: RadialMenu = player._menu
		_check(browser != null and browser.get_script().resource_path.ends_with("file_browser.gd"), "the file browser opens")
		await _wait(0.1)
		var labels: Array = browser._current.map(func(i): return i["label"])
		_check(labels.size() == 2 and labels[0] == "sub/" and str(labels[1]).begins_with("a.txt"), "browser shows the folder (%s)" % [labels])
		_check(browser.get_node("%Buttons").get_children().filter(func(b): return not b.is_queued_for_deletion())[1].get_children().any(func(c): return c is GrabHandle), "file cards can be grabbed")
		# Poke a file: a copy floats out in front of you.
		var docs := Sync.entities_of_kind("document").size()
		await _wait(0.7)
		browser._activate(browser._current[1])
		_check(Sync.entities_of_kind("document").size() == docs + 1 and Sync.entities_of_kind("document")[-1].data.get("name") == "a.txt", "poking a file takes out a copy")
		_check(FileAccess.file_exists(dir.path_join("a.txt")), "…the original stays in the folder")
		# Into the subfolder and grab a file with a hand: it's put in that hand.
		browser._activate(browser._current[0])
		await _wait(0.1)
		_check(browser._current.map(func(i): return i["label"])[0] == "Up" and str(browser._current[1]["label"]).begins_with("b.md"), "open a subfolder")
		Sync.poses[1]["r"] = Transform3D(Basis.IDENTITY, Vector3(0.5, 1.2, 1.0))
		var adopted := []
		var on_adopt := func(b: NetBody, h: int): adopted.append([b, h])
		Sync.adopt_requested.connect(on_adopt)
		browser._pull(browser._current[1]["file"], 1)
		Sync.adopt_requested.disconnect(on_adopt)
		var doc: NetBody = Sync.entities_of_kind("document")[-1]
		_check(doc.data.get("name") == "b.md" and doc.global_position.distance_to(Vector3(0.5, 1.2, 1.0)) < 0.01 and adopted.size() == 1 and adopted[0][1] == 1,
				"grabbing a file pulls the copy into that hand")
	# Closing the drawer closes the browser.
	Sync.poses[1]["head"] = Transform3D(Basis.IDENTITY, drawer.global_position + Vector3(0, 1.0, 1.0))
	Sync.request_interact(id)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not drawer.is_open(), "trigger/E closes it")
	if player:
		_check(not is_instance_valid(player._menu) or player._menu.is_queued_for_deletion(), "closing the drawer closes the browser")
	# Pulling the handle opens it physically.
	var hand := Hand.make(1)
	add_child(hand)
	hand.global_position = drawer.get_node("%Handle").global_position
	drawer.get_node("%Handle").begin(hand)
	for i in 5:
		hand.global_position += drawer.global_basis.z * 0.05
		await get_tree().process_frame
	_check(drawer.is_open(), "pulling the handle opens the drawer")
	drawer.get_node("%Handle").end()
	for i in 5:
		hand.global_position -= drawer.global_basis.z * 0.06
		await get_tree().process_frame
	drawer.get_node("%Handle").begin(hand)
	hand.global_position -= drawer.global_basis.z * 0.3
	await get_tree().process_frame
	drawer.get_node("%Handle").end()
	_check(not drawer.is_open(), "pushing it back in closes it")
	hand.queue_free()
	for f in ["a.txt", "sub/b.md", ".hidden"]:
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir.path_join("sub"))
	DirAccess.remove_absolute(dir)


func _basis_with_y(y: Vector3) -> Basis:
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	return Basis(x, y, x.cross(y).normalized())


## Point-to-talk end to end: point at an agent, speak (a recorded clip streamed
## through the real voice path), stop pointing -> Whisper -> AI -> reply bubble.
func _point_to_talk(agent_id: int) -> void:
	# Mic policy: open for proximity chat with company, else only while pointing at an AI.
	_check(Voice.mic_should_be_on(true, false, -1), "mic open when others are present")
	_check(not Voice.mic_should_be_on(true, true, -1), "muted: mic closed for chat")
	_check(not Voice.mic_should_be_on(false, false, -1), "alone and not pointing: mic closed")
	_check(Voice.mic_should_be_on(false, false, agent_id) and Voice.mic_should_be_on(false, true, agent_id), "pointing at an AI: mic open (even if muted)")
	_check(AI._brain_for(0) == null, "the room doesn't listen (no room brain)")
	var agent: AgentBody = Sync.entities[agent_id]
	# 1) Point at the agent without saying anything: nothing is sent.
	_toasts.clear()
	Voice.set_ai_target(agent_id)
	await _wait(0.1)
	_check(AI._brains["a%d" % agent_id].listening, "agent is listening while pointed at")
	var silence := PackedFloat32Array()
	silence.resize(VoiceCodec.SAMPLE_RATE)
	_stream(VoiceCodec.encode_ulaw(silence))
	Voice.set_ai_target(-1)
	await _wait(0.5)
	_check(not AI._brains["a%d" % agent_id].listening and not _toasts.any(func(t: String): return t.begins_with("You:")),
			"pointing without speaking sends nothing")
	# 2) Point, speak, stop pointing.
	if not LocalWhisper.extension_available():
		print("[selftest] point-to-talk: skipping speech part (no godot-whisper addon)")
		return
	var bytes := FileAccess.get_file_as_bytes("res://tests/jfk.wav")
	var pcm := PackedFloat32Array()
	for i in range(44, mini(bytes.size() - 1, 44 + 16000 * 2 * 5), 2):
		pcm.append(bytes.decode_s16(i) / 32768.0)
	_toasts.clear()
	agent.get_node("%Bubble").text = ""
	Voice.set_ai_target(agent_id)
	_stream(VoiceCodec.encode_ulaw(pcm))
	Voice.set_ai_target(-1) # stop pointing -> transcribe and send
	var heard := ""
	var t := 0.0
	while t < 40.0 and heard == "":
		await _wait(0.25)
		t += 0.25
		for msg in _toasts:
			if msg.begins_with("You:"):
				heard = msg
	print("[selftest] point-to-talk heard: %s" % heard)
	_check(heard.to_lower().contains("fellow americans"), "speech was transcribed after pointing stopped")
	await _wait(1.0)
	_check(agent.get_node("%Bubble").text != "", "the agent replied with a speech bubble")


## Feed mu-law audio into the server's voice path as if it came from the host's mic.
func _stream(ulaw: PackedByteArray) -> void:
	for i in range(0, ulaw.size(), VoiceCodec.PACKET_SAMPLES):
		Voice._srv_voice(1, ulaw.slice(i, i + VoiceCodec.PACKET_SAMPLES))


## Pointing needs the other fingers tucked; grabbing must not start the menu
## gesture; the ray can click buttons (incl. the lobby's) even as the point ends.
func _pointing_rules() -> void:
	var tr := XRHandTracker.new()
	tr.has_tracking_data = true
	var g := HandGestures.new(1)
	g.fixed_dt = 1.0 / 90.0
	var wrist := Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))
	_pose_hand(tr, wrist, 0.0) # index out, others curled in
	g.update_from_hand(tr, Transform3D.IDENTITY)
	var palm := tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM).origin
	print("[selftest] tucked middle tip is %.3f m from the palm" % tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP).origin.distance_to(palm))
	_check(g.others_tucked and g.pointing, "index out + others tucked = pointing")
	for curl in [0.0, 0.35, 0.6]: # open, relaxed and half-closed reaching hands
		_pose_hand(tr, wrist, 0.0, Vector3.ZERO, curl)
		g.update_from_hand(tr, Transform3D.IDENTITY)
		_check(not g.pointing and g.clench == 0.0, "others not tucked (curl %.2f) -> not pointing, no clench" % curl)
	# Closing a relaxed hand around something (all fingers curling together) never clenches.
	for step in 10:
		var k := step / 9.0
		_pose_hand(tr, wrist, 0.9 * k, Vector3.ZERO, 0.4 + 0.5 * k)
		g.update_from_hand(tr, Transform3D.IDENTITY)
		_check(not g.pointing, "closing an open hand is never 'pointing' (step %d)" % step)

	# Ray clicks, using the real lobby scene placed off to the side.
	var lobby: Node3D = load("res://scenes/world/lobby.tscn").instantiate()
	add_child(lobby)
	lobby.global_position = Vector3(40, 0, 0)
	var host_btn: PokeButton = lobby.get_node("%Host")
	for c in host_btn.pressed.get_connections():
		host_btn.pressed.disconnect(c["callable"]) # don't actually host again
	var presses := [0]
	host_btn.pressed.connect(func(): presses[0] += 1)
	var rig := Node3D.new()
	add_child(rig)
	var hand := Hand.make(1)
	rig.add_child(hand)
	var ptr: Pointer = load("res://scenes/player/pointer.tscn").instantiate()
	ptr.hand = hand
	ptr.rig = rig
	rig.add_child(ptr)
	var pg := HandGestures.new(1)
	pg.source = "hand"
	hand.global_position = host_btn.global_position + Vector3(0.2, 0.3, 2.5)
	pg.ray_origin = hand.global_position
	pg.ray_dir = (host_btn.global_position - pg.ray_origin).normalized()
	pg.pointing = true
	await get_tree().physics_frame
	ptr.update_pointer(pg)
	_check(ptr.target.get("type") == "button" and ptr.target.get("button") == host_btn, "ray from 2.5 m finds the lobby Host button")
	# Pinching bends the index (the point ends) — the click must still land.
	pg.pointing = false
	pg._set_pinch(true)
	var sup := ptr.update_pointer(pg)
	_check(presses[0] == 1 and sup["grip"], "pinch clicks the lobby Host button from a distance (grab suppressed)")
	pg._set_pinch(false)
	ptr.update_pointer(pg)
	# Controller: pulling the trigger touches it (point ends) — still clicks.
	await _wait(0.6) # button cooldown
	pg.source = "controller"
	pg.pointing = true
	ptr.update_pointer(pg)
	pg.pointing = false
	pg._set_trigger(true)
	ptr.update_pointer(pg)
	_check(presses[0] == 2, "controller trigger clicks the lobby button from a distance")
	pg._set_trigger(false)
	lobby.queue_free()

	# A lock that finds an object in reach right away turns into a grab.
	ptr._set_state(Pointer.State.IDLE)
	var cube: NetBody = Sync.entities_of_kind("ball")[0]
	hand.global_position = cube.global_position + Vector3(0, 0.6, 1.5)
	pg.source = "hand"
	pg.ray_origin = hand.global_position
	pg.ray_dir = (cube.global_position - pg.ray_origin).normalized()
	pg.pointing = true
	ptr.update_pointer(pg)
	await _wait(0.2)
	ptr.update_pointer(pg)
	pg.pointing = false
	pg.clench = 0.4
	ptr.update_pointer(pg)
	_check(ptr.state == Pointer.State.LOCKED, "a held point + clench locks")
	hand.global_position = cube.global_position # hand arrives at the object
	await get_tree().physics_frame
	await get_tree().physics_frame
	sup = ptr.update_pointer(pg)
	_check(ptr.state == Pointer.State.IDLE and not sup["grip"], "object in reach before pulling back -> grab wins, no menu")
	rig.queue_free()


## Pointing -> clench -> pull back ~9 in -> context menu, and the menus' actions.
func _pointer_and_menus(agent_id: int) -> void:
	var rig := Node3D.new()
	add_child(rig)
	var hand := Hand.make(1)
	rig.add_child(hand)
	var ptr: Pointer = load("res://scenes/player/pointer.tscn").instantiate()
	ptr.hand = hand
	ptr.rig = rig
	rig.add_child(ptr)
	var opened := []
	ptr.menu_requested.connect(func(t: Dictionary, at: Vector3): opened.append([t, at]))
	var g := HandGestures.new(1)
	g.source = "hand"
	# Point at the floor from about chest height.
	var spot := Vector3(1.5, 0.0, 2.0)
	hand.global_position = spot + Vector3(0, 1.2, 1.2)
	g.ray_origin = hand.global_position
	g.ray_dir = (spot - g.ray_origin).normalized()
	g.pointing = true
	await get_tree().physics_frame
	ptr.update_pointer(g)
	_check(ptr.state == Pointer.State.POINTING and ptr.target.get("type") == "floor", "pointing at the floor: %s" % ptr.target.get("type"))
	# A point that's clenched straight away (a hand passing through the pose while
	# reaching for something) must not lock.
	g.pointing = false
	g.clench = 0.4
	ptr.update_pointer(g)
	_check(ptr.state != Pointer.State.LOCKED, "a momentary point doesn't lock")
	g.clench = 0.0
	ptr._set_state(Pointer.State.IDLE)
	g.pointing = true
	ptr.update_pointer(g)
	await _wait(0.2) # hold the point
	ptr.update_pointer(g)
	# Start clenching: the ray locks on the floor spot.
	g.pointing = false
	g.clench = 0.4
	var sup := ptr.update_pointer(g)
	_check(ptr.state == Pointer.State.LOCKED and sup["grip"], "clench locks the ray")
	# Pull back only partway (7 cm): nothing yet.
	hand.global_position -= g.ray_dir * 0.07
	g.clench = 1.0
	ptr.update_pointer(g)
	_check(opened.is_empty() and ptr.state == Pointer.State.LOCKED, "a partial pull doesn't open the menu")
	# ~6 in (16 cm total, less than the old 9 in) with a fist -> menu.
	hand.global_position -= g.ray_dir * 0.09
	ptr.update_pointer(g)
	_check(opened.size() == 1 and opened[0][0].get("type") == "floor", "pulling back 6 in with a fist opens the menu")
	print("[selftest] pointer: menu opened for ", opened[0][0].get("type") if opened.size() else "nothing")
	# The controller path of the gesture code (an untracked controller: open hand, no ray click).
	var ctrl := XRController3D.new()
	rig.add_child(ctrl)
	var cg := HandGestures.new(1)
	cg.update_from_controller(ctrl, ctrl)
	_check(cg.source == "controller" and cg.pointing and cg.clench == 0.0 and not cg.trigger_started, "controller gestures")
	# Classification of other targets.
	var chair: NetBody = Sync.entities_of_kind("chair")[0]
	var cube: NetBody = Sync.entities_of_kind("cube")[0] if Sync.entities_of_kind("cube").size() else Sync.entities_of_kind("ball")[0]
	_check(Pointer.classify({"collider": chair, "position": chair.global_position})["type"] == "seat", "chair is a seat")
	_check(Pointer.classify({"collider": cube, "position": cube.global_position})["type"] == "object", "prop is an object")
	_check(Pointer.classify({"collider": Sync.entities[agent_id], "position": Vector3.ZERO})["type"] == "agent", "agent is an agent")
	rig.queue_free()
	# Menus (opened on the local player; items driven directly once armed).
	var player: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	if not player:
		return
	var spot_at: Vector3 = player._menu_spot(Vector3(0, 1.2, 0))
	var cam_fwd: Vector3 = -player.camera.global_basis.z
	_check(is_equal_approx(Vector2(spot_at.x, spot_at.z).length(), player.MENU_AHEAD) and Vector2(spot_at.x, spot_at.z).dot(Vector2(cam_fwd.x, cam_fwd.z)) > 0.0,
			"a gesture's menu opens ahead of the hand, not around it")
	player._open_menu({"type": "floor", "point": spot}, Vector3(0, 1.4, 1))
	var floor_menu: RadialMenu = player._menu
	_check(floor_menu != null and floor_menu._current.map(func(i): return i["label"]) == ["Teleport here", "Add", "Summon AI"],
			"floor menu: Teleport here, Add, Summon AI")
	# Pie menu: each item is a slice from the middle button out to the rim, together filling the disc.
	await get_tree().process_frame
	var slices: Array = floor_menu.get_node("%Buttons").get_children().filter(func(b): return not b.is_queued_for_deletion())
	var total_angle := 0.0
	for b in slices:
		total_angle += b.angle_to - b.angle_from
	_check(slices.size() == 3 and slices.all(func(b): return b.slice and b.inner < 0.07 and b.outer > 0.2) and absf(total_angle - TAU) < 0.01,
			"menu items are pie slices filling the disc")
	var top: RadialButton = slices[0]
	_check(top._face_contains(Vector2(0, 0.14), 0.0) and not top._face_contains(Vector2(0, -0.14), 0.0) and not top._face_contains(Vector2(0, 0.02), 0.0),
			"a slice covers its own sector only (not the middle button)")
	await _wait(0.8)
	# Add > Plant: appears where the ray hit the floor. (No cubes, balls or paint any more.)
	var plants := Sync.entities_of_kind("plant").size()
	floor_menu._activate(floor_menu._current[1])
	await _wait(0.4)
	var add_labels: Array = floor_menu._current.map(func(i): return i["label"])
	_check(add_labels == ["Back", "Chair", "Table", "Plant", "Lamp", "Monitor", "Drawers", "New AI"], "Add menu: %s" % [add_labels])
	floor_menu._activate(floor_menu._current.filter(func(i): return i["label"] == "Plant")[0])
	var plant: NetBody = Sync.entities_of_kind("plant")[-1]
	_check(Sync.entities_of_kind("plant").size() == plants + 1 and Vector2(plant.global_position.x - spot.x, plant.global_position.z - spot.z).length() < 1.0,
			"floor menu: Add > Plant spawns it at the pointed spot")
	await get_tree().process_frame
	_check(not is_instance_valid(floor_menu) or floor_menu.is_queued_for_deletion(), "…and the menu closes once it's added")
	player._open_menu({"type": "floor", "point": spot}, Vector3(0, 1.4, 1))
	floor_menu = player._menu
	await _wait(0.4)
	var summon: Dictionary = floor_menu._current.filter(func(i): return i["label"] == "Summon AI")[0]
	floor_menu._activate(summon)
	await _wait(0.4)
	var pick: Dictionary = floor_menu._current.filter(func(i): return i["label"] == "Testy")[0]
	floor_menu._activate(pick)
	await _wait(0.1)
	var ag: NetBody = Sync.entities[agent_id]
	_check(Vector2(ag.global_position.x - spot.x, ag.global_position.z - spot.z).length() < 1.2, "summoned AI to the pointed spot")
	# Opening another menu replaces the first.
	player._open_menu({"type": "object", "entity_id": cube.entity_id, "point": cube.global_position}, Vector3(0, 1.4, 1))
	await get_tree().process_frame
	_check(not is_instance_valid(floor_menu) or floor_menu.is_queued_for_deletion(), "a new menu replaces the old one")
	var obj_menu: RadialMenu = player._menu
	await _wait(0.8)
	_check(obj_menu._current[0]["label"] == "Grab" and obj_menu._current[0].get("enabled", true), "object menu starts with Grab")
	obj_menu._activate(obj_menu._current.filter(func(i): return i["label"] == "Lock in place")[0])
	_check(cube.is_locked() and cube.freeze, "object locked in place")
	Sync.poses[1]["r"] = Transform3D(Basis.IDENTITY, cube.global_position)
	Sync.request_grab(cube.entity_id, 1, Transform3D.IDENTITY)
	_check(cube.held_by == 0, "can't pick up a locked object")
	player._open_menu({"type": "object", "entity_id": cube.entity_id, "point": cube.global_position}, Vector3(0, 1.4, 1))
	obj_menu = player._menu
	await _wait(0.8)
	_check(not obj_menu._current[0].get("enabled", true), "…Grab is greyed out while it's locked")
	obj_menu._activate(obj_menu._current.filter(func(i): return i["label"] == "Delete")[0]) # -> confirm
	await _wait(0.4)
	var cube_id := cube.entity_id
	obj_menu._activate(obj_menu._current[1]) # "Delete it"
	await get_tree().process_frame
	_check(not Sync.entities.has(cube_id), "object deleted after confirming")
	# Player teleport from the floor menu.
	player._open_menu({"type": "floor", "point": Vector3(-2, 0, -2)}, Vector3(0, 1.4, 1))
	await _wait(0.8)
	player._menu._activate(player._menu._current[0]) # Teleport here
	var head: Vector3 = player.camera.global_position
	_check(Vector2(head.x + 2, head.z + 2).length() < 0.05, "teleported to the pointed spot")


## Moving menus and the keyboard with a fist; Grab from a context menu.
func _drag_and_grab() -> void:
	var player: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	if not player:
		return
	var hand := Hand.make(1)
	add_child(hand)
	# A context menu: a fist on it drags it along; a pinch doesn't.
	player._open_menu({"type": "floor", "point": Vector3(1, 0, 1)}, Vector3(0, 1.4, 1))
	var menu: RadialMenu = player._menu
	hand.global_position = menu.global_position + Vector3(0.05, 0, 0.02)
	hand.hand_tracked = true
	hand.fisting = false
	for i in 3:
		await get_tree().physics_frame
	_check(hand._nearest_handle() == null, "a pinch on a menu doesn't take hold of it")
	hand.fisting = true
	var handle: GrabHandle = hand._nearest_handle()
	_check(handle != null and handle.drag_target == menu, "a fist on a menu takes hold of it")
	if handle:
		var start := menu.global_position
		handle.begin(hand)
		hand.global_position += Vector3(0.3, 0.1, 0)
		await _wait(0.05)
		_check(menu.global_position.distance_to(start + Vector3(0.3, 0.1, 0)) < 0.01, "…and moves it with the hand")
		handle.end()
		hand.global_position += Vector3(0.3, 0, 0)
		await _wait(0.05)
		_check(menu.global_position.distance_to(start + Vector3(0.3, 0.1, 0)) < 0.01, "…until you let go")
	menu.close()
	# The keyboard moves the same way, and keeps facing you.
	var kb: VirtualKeyboard = player.open_keyboard("Drag me", "", func(_t: String): pass)
	await get_tree().process_frame
	var kh: GrabHandle = kb.get_children().filter(func(c): return c is GrabHandle)[0]
	var kstart := kb.global_position
	kh.begin(hand)
	hand.global_position += Vector3(-0.4, 0, 0)
	await _wait(0.05)
	var to_eye: Vector3 = (player.camera.global_position - kb.global_position).normalized()
	_check(kb.global_position.distance_to(kstart + Vector3(-0.4, 0, 0)) < 0.01 and kb.global_basis.z.normalized().dot(to_eye) > 0.95, "the keyboard can be dragged and turns to face you")
	kh.end()
	kb.cancel()
	hand.queue_free()
	# Grab from the context menu: the object jumps into the hand and stays in
	# the open hand until it closes and opens again. (Its own test object: the
	# client test plays with the ball.)
	var ball: NetBody = Sync.entities[Sync.spawn("cube", Transform3D(Basis.IDENTITY, Vector3(-2, 0.2, 2)), {"color": "#e07a5f"})]
	player._open_menu({"type": "object", "entity_id": ball.entity_id, "point": ball.global_position, "hand": 1}, Vector3(0, 1.4, 1))
	var om: RadialMenu = player._menu
	await _wait(0.8)
	om._activate(om._current[0]) # Grab
	var right: Hand = player.hands[1]
	_check(right.held == ball and ball.held_by == 1, "Grab puts the object in the hand")
	_check(ball.global_transform.origin.distance_to((right.global_transform * right.hold_offset_for(ball)).origin) < 0.05, "…teleported there")
	# Held on the palm side, by its grab point, the same way round for everything.
	var tracked := Hand.make(0)
	tracked.controller = XRController3D.new()
	tracked.hand_tracked = true
	var palm_side: Vector3 = tracked.hold_frame().origin
	_check(palm_side.y < -0.03, "tracked hands hold things on the palm side (%s)" % palm_side)
	var chair0: NetBody = Sync.entities_of_kind("chair")[0]
	var held_at: Transform3D = tracked.hold_frame() * chair0.grab_point().affine_inverse()
	_check((held_at * chair0.grab_point()).origin.distance_to(palm_side) < 0.001 and chair0.grab_point().origin.y > 0.3, "…a chair by the top of its back")
	tracked.controller.free()
	tracked.free()
	await _wait(0.3) # the (open) desktop hand keeps reporting grip = false
	_check(right.held == ball and ball.held_by == 1, "…and it stays held while the hand is open")
	right.update_input(true, false) # close the hand…
	await _wait(0.05) # …and the desktop hand opens it again
	_check(right.held == null and ball.held_by == 0, "closing and opening the hand drops it")
	Sync.server_delete(ball.entity_id)


## Restart persistence: phase 1 changes the office and closes it (autosave);
## phase 2 is a fresh process that must find it all restored.
func _persist(phase: int) -> void:
	if not Net.in_session:
		Net.host(false)
	if phase == 1:
		Office.request_action("rename", {"name": "Persist Test"})
		Office.request_action("room", {"step": "d+"})
		Office.request_action("spawn", {"kind": "lamp", "point": Vector3(-2, 0, 2)})
		AI.server_create_agent({"name": "Keeper", "persona": "Remembers things."}, 1)
		var summary := {"entities": Sync.entities.size(), "depth": Office.size().z}
		FileAccess.open("user://selftest_persist.json", FileAccess.WRITE).store_string(JSON.stringify(summary))
		Net.leave("closing the office") # the host leaving autosaves
	else:
		var summary: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("user://selftest_persist.json"))
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://selftest_persist.json"))
		_check(Office.state.get("name") == "Persist Test", "restart: room name restored")
		_check(is_equal_approx(Office.size().z, float(summary["depth"])), "restart: room size restored")
		_check(Sync.entities.size() == int(summary["entities"]), "restart: every object and agent restored (%d/%d)" % [Sync.entities.size(), summary["entities"]])
		_check(Sync.entities_of_kind("agent").any(func(a): return a.data.get("name") == "Keeper"), "restart: the AI agent is back")
		_check(Sync.entities_of_kind("lamp").all(func(l): return l.is_locked()), "restart: furniture still locked")


## Physical buttons: index fingertip only, from the front, once per push.
func _button_latch() -> void:
	var presses := [0]
	var b := PokeButton.make(self, "Test", Vector3(30, 1, 0))
	b.pressed.connect(func(): presses[0] += 1)
	var finger := Area3D.new()
	finger.set_script(load("res://scripts/player/poker.gd"))
	finger.add_to_group("poker")
	finger.collision_layer = PokeButton.LAYER_POKERS
	finger.collision_mask = PokeButton.LAYER_BUTTONS
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.015
	cs.shape = sh
	finger.add_child(cs)
	add_child(finger)
	var at := func(z: float) -> void:
		finger.global_position = b.global_position + Vector3(0, 0, z)
	at.call(0.3)
	await _wait(0.35) # a new button needs a clear moment before it arms
	at.call(0.008) # push in from the front
	await _wait(0.1)
	_check(presses[0] == 1, "fingertip from the front presses once")
	# Shallow: a fingertip 2.5 cm in front of the face doesn't reach it.
	at.call(0.3)
	await _wait(0.35)
	at.call(0.035)
	await _wait(0.1)
	_check(presses[0] == 1, "buttons are shallow: hovering just above doesn't press")
	at.call(0.008)
	await _wait(0.1)
	presses[0] = 1
	# Rest on it (with a little jitter) for over a second: no repeats.
	for i in 60:
		at.call(0.004 + 0.008 * float(i % 2))
		await get_tree().physics_frame
	await _wait(0.6)
	_check(presses[0] == 1, "holding the finger in doesn't toggle it again (%d presses)" % presses[0])
	# Pull out only briefly: still latched.
	at.call(0.3)
	await _wait(0.08)
	at.call(0.008)
	await _wait(0.1)
	_check(presses[0] == 1, "a brief pull-out doesn't re-press")
	# Out properly, then in again: a second press.
	at.call(0.3)
	await _wait(0.35)
	at.call(0.008)
	await _wait(0.1)
	_check(presses[0] == 2, "release then push again presses again")
	# From behind (a hand passing through): nothing.
	at.call(0.3)
	await _wait(0.35)
	at.call(-0.015)
	await _wait(0.1)
	_check(presses[0] == 2, "entering from behind doesn't press")
	# Sliding in sideways from next to it (fat-fingering the next key): nothing.
	finger.global_position = b.global_position + Vector3(0.12, 0, 0.008)
	await _wait(0.35)
	for i in 6:
		finger.global_position = b.global_position + Vector3(0.12 - 0.02 * (i + 1), 0, 0.008)
		await get_tree().physics_frame
	await _wait(0.1)
	_check(presses[0] == 2, "sliding onto it from the side doesn't press")
	# Something that isn't a fingertip: nothing.
	at.call(0.3)
	finger.remove_from_group("poker")
	await _wait(0.35)
	at.call(0.008)
	await _wait(0.1)
	_check(presses[0] == 2, "non-finger areas don't press")
	finger.add_to_group("poker")
	# A button that appears under a resting fingertip (a menu opening there) stays quiet.
	var presses2 := [0]
	var b2 := PokeButton.make(self, "New", finger.global_position - Vector3(0, 0, 0.008))
	b2.pressed.connect(func(): presses2[0] += 1)
	await _wait(0.6)
	_check(presses2[0] == 0, "a button appearing under a finger doesn't press itself")
	b.queue_free()
	b2.queue_free()
	finger.queue_free()


## The lobby: close enough to tap, lists your saved rooms, opens one.
func _lobby() -> void:
	Saves.write_file("lobby test", {"format": Saves.FORMAT, "saved_at": Time.get_unix_time_from_system(),
			"room": {"name": "Lobby Test Room", "size": [7.0, 3.0, 7.0]}, "entities": [], "agents": [], "images": {}})
	await _wait(1.8) # the panel settles in front of you
	var lobby: Node3D = get_node("/root/Main").get("_lobby")
	_check(lobby != null, "lobby shown")
	if not lobby:
		return
	var cam := get_viewport().get_camera_3d()
	var panel: Node3D = lobby.get_node("%Panel")
	var d := cam.global_position.distance_to(panel.global_position)
	_check(d < 1.0, "the lobby panel is within reach (%.2f m)" % d)
	var tut: PokeButton = lobby.get_node("%TutorialButton")
	_check(tut.size.x >= 0.7 and tut.text.contains("tutorial") and lobby.get_node_or_null("%Help") == null, "one big tutorial button on the lobby panel")
	var rooms: Array = lobby.get_node("%Rooms").get_children()
	_check(rooms.size() == 1 and rooms[0].text == "lobby test (Lobby Test Room)", "the lobby lists saved rooms (%s)" % [rooms.map(func(r): return r.text)])
	if rooms.size():
		rooms[0].press()
		await _wait(1.0)
		_check(Net.in_session and Office.state.get("name") == "Lobby Test Room" and Office.size().x == 7.0, "opening a saved room from the lobby hosts it")
		_check(Saves.startup_save == "", "…just that once")
	Saves.delete_file("lobby test")
	# The tutorial world.
	Net.leave("") # (leaving your office autosaves it)
	await _wait(0.5)
	var saved_before := Saves.read_file(Saves.AUTOSAVE)
	lobby = get_node("/root/Main").get("_lobby")
	lobby.get_node("%TutorialButton").press()
	await _wait(1.0)
	_check(Net.in_session and Net.tutorial and Office.state.get("name") == "Tutorial", "Open the tutorial world hosts the tutorial")
	var boards := Sync.entities_of_kind("whiteboard")
	_check(boards.size() == 7 and boards.all(func(b): return str(b.data.get("title", "")) != "" and str(b.data.get("text", "")) != ""),
			"…with seven explanation boards (%d)" % boards.size())
	_check(boards.filter(func(b): return int(b.data.get("image", 0)) > 0).size() == 5, "…five with diagrams")
	var practice: PracticeWidget = Widgets.find("practice", "")
	_check(practice != null and Widgets.find("timer", "") != null and Widgets.find("alarm", "") != null and Widgets.find("calendar", "") != null and Widgets.find("tv", "") != null,
			"…a practice board and one of each widget")
	if practice:
		var targets: Array = practice.get_children().filter(func(c): return c is PokeButton and c.text.is_valid_int())
		targets[0].press()
		targets[5].press()
		_check(practice.hits() == 2 and practice.get_node("%Score").text.contains("2 / 6"), "hitting practice targets counts them")
	var drawer: FileDrawer = Sync.entities_of_kind("drawer")[0] if Sync.entities_of_kind("drawer").size() else null
	_check(drawer != null and FileDrawer.list_dir(drawer.folder()).size() == 3, "…drawers full of sample files")
	_check(Sync.entities_of_kind("chair").all(func(c): return not c.is_locked()) and Sync.entities_of_kind("agent").size() == 1, "…furniture to grab and a Tutor AI")
	Saves.autosave()
	Net.leave("")
	await _wait(0.3)
	var saved_after := Saves.read_file(Saves.AUTOSAVE)
	_check(not Net.tutorial and str(saved_after.get("room", {}).get("name", "")) != "Tutorial" and saved_after.get("saved_at") == saved_before.get("saved_at"),
			"the tutorial is never saved over your office")


## Offline speech recognition with the godot-whisper addon.
func _whisper() -> void:
	_check(LocalWhisper.extension_available(), "godot-whisper extension loaded")
	var bytes := FileAccess.get_file_as_bytes("res://tests/jfk.wav")
	var pcm := PackedFloat32Array()
	for i in range(44, mini(bytes.size() - 1, 44 + 16000 * 2 * 5), 2): # first 5 s
		pcm.append(bytes.decode_s16(i) / 32768.0)
	var w := LocalWhisper.new()
	add_child(w)
	var t0 := Time.get_ticks_msec()
	var text := await w.transcribe(pcm)
	print("[selftest] whisper (%d ms): %s" % [Time.get_ticks_msec() - t0, text])
	_check(text.to_lower().contains("fellow americans"), "whisper transcribed the clip")
	# Repetition-loop cleanup.
	var loop := "And so my fellow Americans ask not And so my fellow Americans ask not And so my fellow Americans ask not Ask not Ask not Ask not Ask not"
	_check(LocalWhisper.collapse_repeats(loop) == "And so my fellow Americans ask not", "whisper loop collapsed: %s" % LocalWhisper.collapse_repeats(loop))
	for normal in ["Can you put the plan on the board please", "That that is is fine", "I think we should ship it, ship it today"]:
		_check(LocalWhisper.collapse_repeats(normal) == normal, "normal speech untouched: %s" % normal)


func _client() -> void:
	var t := 0.0
	while not Net.in_session and t < 10.0:
		await _wait(0.25)
		t += 0.25
	_check(Net.in_session, "knocked and was let in")
	await _wait(2.0)
	_check(Net.role(Net.my_id()) == "member", "I am a member")
	_check(Office.node != null, "sees the room")
	_check(Sync.entities_of_kind("agent").size() == 1, "sees agent")
	_check(Sync.images.size() >= 1, "received whiteboard image")
	var boards := Sync.entities_of_kind("whiteboard").filter(func(b): return b.widget_name() == "Main board")
	_check(boards.size() == 1 and boards[0].data.get("title") == "Diagram", "board replicated")
	_check(Sync.avatars.has(1), "host avatar exists")
	# Members can't redecorate but can add props.
	var w := Office.size().x
	var n := Sync.entities.size()
	Office.request_action("room", {"step": "w+"})
	Office.request_action("spawn", {"kind": "plant", "point": Vector3(-3, 0, -3)}) # (the host test counts cubes)
	await _wait(0.7)
	_check(Office.size().x == w, "member cannot resize")
	_check(Sync.entities_of_kind("plant").size() == 0 or Sync.entities.size() <= n, "guests can't add objects by default")
	# The host grants "Add objects" to guests (Room → Permissions); then it works.
	var waited_perm := 0.0
	while not Office.member_may("spawn") and waited_perm < 15.0:
		await _wait(0.25)
		waited_perm += 0.25
	_check(Net.my_can("spawn"), "the host let guests add objects")
	var plants := Sync.entities_of_kind("plant").size()
	Office.request_action("spawn", {"kind": "plant", "point": Vector3(-3, 0, -3)})
	await _wait(0.7)
	_check(Sync.entities_of_kind("plant").size() == plants + 1, "guest can add objects once allowed")
	_check(not Net.my_can("lock"), "…but still can't lock/unlock (not granted)")
	# Save a copy of the host's room to our own saves; guests can't load in someone else's room.
	Saves.delete_file("selftest copy")
	Saves.request_save_as("selftest copy")
	var waited_save := 0.0
	while not Saves.has_save("selftest copy") and waited_save < 10.0:
		await _wait(0.25)
		waited_save += 0.25
	var copy := Saves.read_file("selftest copy")
	_check(copy.get("entities", []).size() > 3 and copy.get("room", {}).get("name", "") == Office.state.get("name"), "guest saved a copy of the host's room")
	_check(not Saves.can_load(), "guests can't load a room into someone else's office")
	Saves.delete_file("selftest copy")
	# Grab a cube remotely.
	var prop: NetBody
	for e in Sync.entities.values():
		if e.kind == "ball": # the host test never touches the ball
			prop = e
	if prop:
		var hand := Node3D.new()
		add_child(hand)
		hand.global_position = prop.global_position
		Sync._pose_timer = 0
		Sync.send_pose(Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0)), Transform3D.IDENTITY, hand.global_transform)
		Sync.request_grab(prop.entity_id, 1, Transform3D.IDENTITY)
		await _wait(0.5)
		_check(prop.held_by == Net.my_id(), "remote grab acknowledged")
		_check(Sync.entities.values().any(func(e): return e._snaps.size() > 0), "client receives timestamped snapshots")
		Sync.request_release(prop.entity_id, Vector3.ZERO, Vector3.ZERO)
		await _wait(0.5)
		_check(prop.held_by == 0, "remote release acknowledged")
	# Player context menu on the host: local mute/volume; kicking the owner isn't allowed.
	var player: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	if player:
		player._open_menu({"type": "player", "peer": 1, "point": Vector3.ZERO}, Vector3(0, 1.4, 0))
		var pm: RadialMenu = player._menu
		await _wait(0.8)
		var items: Array = pm._current
		_check(items.map(func(i): return i["label"]) == ["Mute", "Volume", "Ask over", "Make admin", "Kick"]
				and not items[3].get("enabled", true) and not items[4].get("enabled", true),
				"player menu: Mute, Volume, Ask over, Make admin, Kick (roles/kick disabled for members)")
		pm._activate(items[0])
		_check(Voice.is_player_muted(1), "muted the host locally")
		player._open_menu({"type": "player", "peer": 1, "point": Vector3.ZERO}, Vector3(0, 1.4, 0))
		pm = player._menu
		await _wait(0.8)
		pm._activate(pm._current[1]) # Volume
		await _wait(0.4)
		pm._activate(pm._current.filter(func(i): return str(i["label"]).contains("50%"))[0])
		_check(is_equal_approx(Voice.player_volume(1), 0.5) and not Voice.is_player_muted(1), "set host volume to 50%")
		Office.request_action("kick", {"peer": 1})
		await _wait(0.5)
		_check(Net.in_session, "members can't kick the owner")
	# Upload a (multi-chunk) file, then "use" it to download it back.
	var docs := Sync.entities_of_kind("document").size()
	var big := PackedByteArray()
	big.resize(150 * 1024)
	big.fill(65)
	Files.upload("big notes.txt", big)
	await _wait(1.5)
	var mine: NetBody
	for e in Sync.entities_of_kind("document"):
		if e.data.get("name") == "big notes.txt":
			mine = e
	# (Only our own file: the host test may be taking files out of a drawer meanwhile.)
	_check(Sync.entities_of_kind("document").size() > docs and mine != null and int(mine.data.get("size", 0)) == big.size(), "chunked upload became a document")
	if mine:
		_toasts.clear()
		Sync.request_use(mine.entity_id)
		await _wait(1.5)
		_check(_toasts.any(func(s: String): return s.begins_with("Saved") and s.contains("big notes")), "download via trigger saved the file: %s" % [_toasts])
	# The host asks us to come over: the request waits for us in the Me menu.
	var cp: Node3D = get_node_or_null("/root/Main/LocalPlayer")
	var waited := 0.0
	while Net.prompts_of("summon").is_empty() and waited < 10.0:
		await _wait(0.25)
		waited += 0.25
	_check(not Net.prompts_of("summon").is_empty(), "come-over request is waiting on the watch")
	if cp and not Net.prompts_of("summon").is_empty():
		var teleported := [false]
		Net.teleport_requested.connect(func(_xf: Transform3D): teleported[0] = true)
		var me: RadialMenu = cp.open_watch_menu("me")
		await _wait(0.8)
		var req: Dictionary = me._current.filter(func(i): return str(i["label"]).begins_with("Requests"))[0]
		_check(req.get("enabled", true) and req["label"] == "Requests (1)", "Me menu shows 1 request")
		me._activate(req)
		await _wait(0.4)
		me._activate(me._current[1]) # the host's name
		await _wait(0.4)
		me._activate(me._current.filter(func(i): return i["label"] == "Go to them")[0])
		await _wait(0.8)
		_check(teleported[0] and Net.prompts_of("summon").is_empty(), "accepting from the watch teleports you to them")
