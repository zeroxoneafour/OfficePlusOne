# Office Plus One

A multiplayer VR office (Godot 4.7, pure GDScript, OpenXR) where humans and
AI agents work in the same room. Every AI agent is an NPC with a body; you
talk to it by voice, it answers with its own voice, uses the whiteboard, and
passes files back and forth with people (and other agents) by hand.

Visuals are deliberately barebones for now.

## Running

```bash
godot                                   # lobby: host your office, open a saved room, or join one on the LAN
godot -- --host                         # host your office and play
godot -- --join=192.168.1.20            # knock on someone's office
godot --headless --xr-mode off -- --server   # dedicated server, no player
# extra flags: --desktop (force mouse/keyboard), --name=Ada, --port=7777
```

Without a headset (or with `--desktop`) you get a mouse/keyboard mode that
drives the same physical hand, so everything stays testable on a desktop.
Platform/runtime/Android details: [docs/PLATFORMS.md](docs/PLATFORMS.md)
(run `tools/setup_android_xr.sh` once for Quest builds).

### AI keys (server only)

Models run in the cloud and are only ever called by the server:
Client → Server → Model → Server → Client. Set on the hosting machine:

| Env var | Used for |
|---|---|
| `ANTHROPIC_API_KEY` | Agent thinking (Claude Messages API, default model `claude-opus-5`) |
| `OPENAI_API_KEY` | Optional fallback: when a Claude request fails (or there's no Anthropic key), agents think with the OpenAI Chat Completions API instead |
| `OPENAI_BASE_URL`, `OPO_OPENAI_MODEL` | Optional: any OpenAI-compatible endpoint, and its model (default `gpt-5`) |

Everything is also configurable in `user://config.cfg` (written on first run;
on Linux `~/.local/share/godot/app_userdata/Office Plus One/config.cfg`):
models, effort, `openai_api_key` / `openai_base_url` / `openai_model`, port
and default server. The fallback gets the same system prompt, tools (converted
to function tools), images and history, and once it takes over it answers the
rest of that turn. Without any key the app still runs; agents say they can't
think yet.

### Speech (all on the host, offline)

Claude has no audio input or output, so speech is handled around it, on the
hosting machine:

- **Speech-to-text: Whisper.** The bundled
  [godot-whisper](https://github.com/appsinacup/godot-whisper) GDExtension
  (whisper.cpp; Linux x86_64, Windows x86_64, Android arm64) transcribes
  point-to-talk audio on a worker thread (with trailing silence added and
  repetition loops cleaned up). The model (`whisper_model`, default
  `base.en-q5_1`, 57 MB) is downloaded to `user://models` the first time a
  server starts; or put `ggml-<name>.bin` in `addons/godot_whisper/models/`.
  `tiny.en-q5_1` is about twice as fast but less accurate; drop `.en` for
  other languages and set `whisper_language`. It runs on the CPU
  (`audio/input/transcribe/use_gpu=false`): the GPU is busy rendering.
- **Text-to-speech: [best-tts](https://github.com/studio-ransom/best-tts-godot)**
  (`addons/best-tts`, Apache-2.0): the Kokoro-82M neural voice model running
  in pure GDScript and GPU compute shaders, fully offline. The host
  synthesizes each reply clause by clause and streams it to everyone; it
  plays from the agent's head (3D), so everyone hears the same voice, and
  muting an AI (its menu) works per person. Agents get English voices in turn
  (`af_heart`, `am_michael`, `bf_emma`, …); ask one to change its voice or
  speaking speed. Needs a Vulkan-capable GPU on the host (about 190 MB of
  VRAM); a headless dedicated server has none, so its agents answer with
  speech bubbles only.

## Controls

**Pointing and context menus** (hands or controllers):

1. **Point**: index finger out with your **middle, ring and pinky tucked into
   your palm**. A relaxed or half-open hand never counts, so reaching for
   and grabbing things doesn't start the gesture. On a controller, lift your
   finger off the trigger. A ray is cast from your hand at whatever
   you point at: the floor, a wall, a widget, a seat, an object, an AI or a person. Others
   see your ray too.
2. **Start clenching.** The ray freezes on that target (it turns yellow).
3. **Pull your hand straight back along the ray about 6 inches while making
   a fist** (on a controller, squeeze grip). The ray turns green and a round
   menu appears around your hand.
   - Floor: *Teleport here*, *Add* (chair, table, plant, lamp, monitor,
     drawers, floating screen, *New AI*: it appears right where you pointed
     and the menu closes; furniture arrives locked, and a monitor added next
     to a table goes on the table), *Summon AI* (pick which).
   - Wall: *Add widget* (calendar, alarm, timer, whiteboard, TV: it hangs where you
     pointed), *Wall color*, *All walls*, *Teleport here*.
   - Widget (or its **Menu** button): *Rename…* (keyboard), its own settings
     (see [Wall widgets](#wall-widgets)), *Remove* (admins; asks to confirm).
   - Seat: *Sit here* (works from anywhere), *Teleport here*, *Add*, *Summon
     AI* (they sit in it), *Grab* (when unlocked), *Lock in place* / *Unlock*, *Delete*.
   - Object: *Grab* (it jumps into the palm of the hand that opened the menu,
     held by its handle where it has one (a chair by its back, a table by its
     edge…), and stays there even with your hand open; close and open that
     hand to drop it. Not for locked things), its own items (monitor: *Connect…* / *Keyboard* / *Disconnect*; drawers:
     *Open* / *Close*, *Set folder…*), *Rotate* (turn it ±15° or ±90° about
     the vertical, standing it upright; stays open to keep turning), *Lock in
     place* / *Unlock*, *Delete* (admins; asks to confirm). How *Grab* holds
     things is tuned by hand: see [docs/GRAB_POINTS.md](docs/GRAB_POINTS.md).
   - AI: *Mute* / *Unmute* its voice and *Point-to-talk: on / off* (whether
     pointing at it talks to it); both just for you, remembered by its name.
     *Delete* (admins; asks to confirm).
   - Person: *Mute* / *Unmute* and *Volume* (just for you), *Ask over*,
     *Make admin* / *Make member* (owner), *Kick* (admins, only people ranked
     below you).

   Menus are **pie menus**: each item is a slice of the disc, from the round
   **Cancel** button in the middle out to the rim; submenus have a **Back**
   slice. A menu stays until you cancel it or open another. **Make a fist on
   a menu to move it** (and on the keyboard; the watch's menus stay on the
   watch). Press its
   buttons by poking them, or by pointing at them and pinching (controller:
   trigger). A pinch clicks the button the ray was on just before the pinch,
   so the pinch itself nudging your hand doesn't make you miss. The same ray-click works on every button, including the lobby's
   Host/Join buttons, so you don't have to walk up to them. Open your hand again to keep pointing, or push forward or wander
   off to abandon the gesture. A fist *near* an object grabs it instead.
4. **Hide or show your ray** from the watch's *Me* menu. Pointing still
   works while it's hidden.

Whatever you're targeting (objects, seats, AIs, people; never walls, floor or
ceiling) gets a **yellow outline**, even with the ray hidden, so you always
know what a click or menu will act on. Turn it off in *Me → Highlight*.

**Dominant hand.** You point, and get rays and context menus, with your
dominant hand only: the right by default, or the left (watch → *Me* →
*Dominant hand*; remembered). The watch goes on the other wrist.

**Arm slots.** Each forearm has one big slot, a ring on top of it, for
carrying something while your hands are busy. It's used by the other hand:
let go of what you're holding over the ring to put it there (if something
was already in it, that drops out), and close an empty hand on the ring to
take it back. Things keep their size on your arm (only huge things, like
furniture, shrink to fit) and are inert there: you can't open a drawer or
press a button on something on your arm. Desktop: **1** and **2** put what
you hold on your left / right slot, or take it back with an empty hand.

**The watch** (your non-dominant wrist): turn the **back of that wrist
toward your eyes** (on controllers, raise it and look at it) and a watch
appears with the time and two buttons underneath. Press them with your
pointing hand's index finger, or point and pinch or trigger. A red dot means a request is
waiting. Menus float above the watch, have **Cancel** in the middle and
**Back** in submenus, and disappear when you lower your wrist.
- **Me** (left button): *Mute me* (to other people) · *Rays on/off* ·
  *Highlight on/off* · *Requests* (someone asked you to come over: *Go to
  them* / *Decline*) · *Import files* (from your inbox folder) · *Switch
  room* (*My office*, the *Lobby*, or another office found on your network) ·
  *Close app*. The toggles are remembered.
- **Room** (right button): *Room size* (wider, narrower, deeper, shallower,
  taller, lower, floor color; shows the current size) · *Objects* (*Lock all*,
  *Unlock all*, *Clear loose*) · *Wipe board* · *Rename room* · *Permissions*
  (let guests *add objects*, *add AIs*, or *lock/unlock*; each is admins-only
  by default) · *Saves* (see below) · *Join requests* (someone is knocking:
  *Let in* / *Decline*; admins).

Anything that needs typing (room names, save names) opens a **virtual
keyboard** in front of you: poke the keys, or point and pinch. On desktop
you can type on your real keyboard (Enter = Done, Esc = Cancel).

Items you're not allowed to use are greyed out and say why. On desktop, **Q**
opens the Me menu and **R** the Room menu, in front of you.

**Controllers:** left stick move · right stick snap turn · **grip**
grab/throw · **trigger** use the held item (flip clipboard pages, save a
document to your device), or with an empty hand **interact** with what it
touches (sit on a chair, switch a lamp) · **poke** buttons with your
fingertip · **X** mute mic (for other people).

**Hand tracking** (put the controllers down; Quest and other OpenXR runtimes
with hand tracking): move with the context menu's *Teleport here* ·
**pinch or make a fist near something** to grab it · **thumb to middle
finger** = trigger (use/interact) · poke buttons with your real index
finger (only the very tip presses, and only when it comes down onto a
button's face: sliding across from the next key doesn't press it. Buttons
are shallow, like a keyboard's: a key fires when your fingertip reaches its
face, not before). Your hand
joints are drawn so you can see what's tracked. The pointer ray runs from
your wrist through your index finger's knuckle, both on the rigid part of
the hand, so bending, retracting or pinching with the finger can't move it;
only moving or turning your hand does. It's smoothed adaptively: steady when
you're still, responsive when you move. On Meta headsets the system pinch
(`XR_FB_hand_tracking_aim`) is used for clicking.

**Talking to AIs (point-to-talk):** point at an AI agent (desktop: put the
crosshair on it) and just talk. Its status light turns green while it
listens. Stop pointing at it and what you said is transcribed and sent. The
AI answers with a speech bubble and its voice. Only AI agents listen: the
room itself doesn't take voice commands (use the watch's Room menu or the
wall panel). Pointing at an AI without saying anything sends nothing.

**Your mic:** when anyone else is in the office, your mic is open for
proximity chat (voice-activated; X / M mutes it). When you're alone it's off,
except while you're pointing at an AI. Pointing at an AI turns the mic on
even when you're muted, since that's a deliberate "talk to this AI".

**Sitting:** trigger (or E) on a chair to sit; the view drops to seated
height facing the chair's front, and you move with the chair. Move, or
trigger the chair again, to stand. Drop an AI agent onto a chair and it sits
too; pick it up to stand it.

**Desktop:** click to capture mouse · WASD · LMB grab/throw or press ·
**RMB** context menu for whatever is under the crosshair · E use / interact
(sit, lamp) / press · aim at an AI and speak · T type to AI · M mute · mouse wheel
changes held-object distance · drop files on the window to bring them in.

**The lobby** (before you're in an office) is a panel that appears within
arm's reach in front of you, tilted up like a lectern, so you can tap it:
*Host my office* (as you left it), **your saved rooms** (tap one to host
your office with that room), and offices found on your network. The big
**New here? Open the tutorial** button at the top takes you to a practice
office: boards with explanations and diagrams on every wall, ray targets to
hit, a board to draw on, every widget, furniture to grab and lock, drawers of
sample files, a long file to scroll, a floating screen and a Tutor AI. The tutorial is private and never saved, so your office is
untouched; leave with watch → Me → Switch room.

## One office per server, and who controls it

Each server hosts exactly one room. Whoever hosts it is the **owner**; to
get back to your own office, leave and host your own. Others join by
**knocking**: everyone inside who may admit people gets a buzz and a badge on
their watch, and lets them in (or not) from the Room menu's *Join requests*.
Admitted people are remembered as members and walk straight in next time;
offices that already know you are marked "invited" in your lobby.

| Role | Can |
|---|---|
| member | grab and throw unlocked things, sit, talk to AIs, summon agents, call people over, bring in files, save a copy of the room |
| admin | + add objects and AIs, lock/unlock, resize/paint/clear the room, rename it, wipe the board, delete/reconfigure agents, let people in, remove members, choose what guests may do |
| owner | + make people admins or members, load saved rooms |

Admins can give ordinary members *Add objects*, *Add AIs* or *Lock / unlock*
from *Room → Permissions*; the choice is saved with the room.

## Saving the room

The whole office is saved: size, colors and name; every object and widget
with its position, rotation, lock state and settings (lamp on/off, paint
color…); documents with their file contents; clipboards; AI agents with their
persona, voice and position (and the chair they're sitting on); and the
guest permissions. The server **autosaves** every minute, when you leave your
office and when the app closes, and **loads the autosave** when you host
again. (The old `room.json`/`agents.json` are migrated automatically the
first time.)

*Room → Saves* on the watch:
- **Save as…** names a save on the virtual keyboard. As a guest, this copies
  the host's room into *your own* saves, so you can load it in your office
  later.
- Each save: **Load** (only the host, in their own office; replaces the room,
  asks to confirm) or **Delete**.

Saves are JSON files in `user://saves/` (Linux:
`~/.local/share/godot/app_userdata/Office Plus One/saves/`).

Dedicated servers (no owner playing) take admins from `[server] admins` in
`config.cfg`; set `open=true` there to skip knocking. Buttons you can't use
are greyed out, and the server re-checks every request. Names are not
authenticated yet, so this is suitable for trusted groups and LANs.

## Wall widgets

Point at a wall, pull back, *Add widget*. Widgets hang flat on the wall
(and stay on it when the room is resized), can't be knocked off, and each
has a name along its top, which is set with the keyboard (*Rename…*) so you
can tell two calendars apart. The **Menu** button in a widget's corner opens
the same menu as pointing at it. People use them physically; AI agents use
them through the widget MCP tools (below).

- **Calendar:** a month of day cells, each with its date in the corner and
  a preview of what's on that day (today green, days with entries purple),
  and the next few entries underneath. `<` `>` change the month. Poke a day to
  see its entries (pick one to remove it) or *Add…*: type
  `14:30 Team sync` (leave the time off for all day).
- **Alarm:** the alarm time, the current time, **±1h / ±5m** buttons,
  **Turn on/off**, and *Set time…* in its menu (keyboard: `7:30` or
  `2:15pm`). At its time (the host's clock) it flashes and beeps for
  everyone until someone presses **Stop** (or a minute passes).
- **Timer:** counts down minutes and seconds: **±1m / ±10s** buttons,
  **Start**, **Stop** (pause) and **Reset**, and *Set time…* in its menu
  (keyboard: `5:00`, `90s`, `1m30s`). When it runs out it flashes and beeps
  for everyone until someone presses **Stop** (or a minute passes). An AI
  setting it resets and starts it. A running timer is saved paused, with the
  time it had left.
- **Whiteboard:** the palette under it picks **your** brush: a colour,
  a size (S/M/L) or the eraser. Then draw with your **fingertip** on the
  board, or from across the room by **pointing at it and holding a pinch**
  (controller: trigger) while you move the ray. Desktop: hold the left
  button on it and drag. It also shows a title, text and a picture: AIs
  write and draw there, *Write…* in its menu types text, and pressing a
  document or clipboard against it pins it there. Long text never spills off
  the board: the board's canvas becomes as tall as the text needs (drawing
  never makes it bigger), and **^ / v** on its right edge (desktop: the mouse
  wheel over it) scroll it, drawings and all, just for you. *Wipe* clears the drawing,
  the text and picture, or everything. Every office starts with one, the
  **Main board**, on the north wall. It replaces the old built-in board, and
  older saved rooms get their old board's contents moved onto it.
- **TV:** shows someone's computer over VNC. Menu →
  *Connect…*: type the computer's address (`192.168.1.20`, `mypc.local:5901`
  or `host:1` for display 1), then its VNC password (empty if none). Each
  person's app connects to that computer itself, so it must be reachable from
  every headset/PC in the room (e.g. the same network), with a VNC server
  running (e.g. `wayvnc`, `x11vnc`, TigerVNC, macOS Screen Sharing with a VNC
  password, TightVNC on Windows) that allows plain VNC-password or no
  authentication. There's no mouse control. Its **Keyboard** button (also
  in its menu) shows or hides a live keyboard (with Enter, Tab, Esc and
  arrow keys; desktop: your real keyboard) whose keys go straight to that
  computer. The password is shared with the room and saved with it.

**Monitors** are furniture that do the same as a TV (the same screen code:
`scripts/vnc/`, `scripts/entities/remote_display.gd`): point at one →
*Connect…*. **Floating screens** (floor menu → *Add*) are the same screen
without any physics: grab one and let go anywhere; it stays exactly there,
in mid-air (no gravity, no inertia, no bumping into things).

**Documents and clipboards** show their whole text; when it doesn't fit, it
scrolls, down and (for documents, whose lines don't wrap) sideways: small
**^ v < >** buttons appear beside the text (desktop: the mouse wheel over it).

**Drawers** are furniture that open onto a folder on the host's computer.
An admin sets it: point at the drawers → *Set folder…* (keyboard; its
**#+=** page has `/ ~ . _`; e.g. `~/Documents/Shared`). Pull the top drawer
open by its handle (grip/fist on it; or trigger / E on the drawers) and a
file browser opens around you: poke a folder to go in (*Up* to go back), and
**grab a file to pull a copy of it into your hand** (or poke it and the copy
floats out in front of you). The copy is an ordinary document: hand it to
people or AIs. The folder itself is never changed, nothing outside it can be
reached, and hidden files aren't shown. Closing the drawer closes the
browser.

### AIs and widgets (MCP)

Agents get the widget tools from an in-process MCP server
(`scripts/ai/widget_mcp.gd`: JSON-RPC `initialize`, `tools/list`,
`tools/call`, with MCP tool schemas and results). It runs inside the host
rather than as a separate process because it acts on the live room, and
because Claude's hosted MCP connector can only reach public internet
servers. Tools:

- `widget_list()`
- `widget_calendar(calendar_name, date, time, contents)` (empty contents removes entries)
- `widget_alarm(alarm_name, time)` (`"off"` turns it off)
- `widget_timer(timer_name, time_minutes, time_seconds)` (sets it, resets it and starts it)
- `widget_whiteboard(whiteboard_name, text, mode)` (replace / append / clear)

A preloaded skill, `ai/skills/widgets/SKILL.md`, is part of every agent's
system prompt and explains when and how to use them. Each message an agent
gets lists the widgets. When any were added, removed, renamed or changed
since its last turn, that list is the full one, with what's on each widget
and how to use it, plus a note of what changed (e.g. "Pat added calendar
"Team" on the north wall", "Alarm "Standup" went off"). The tools run with
the permissions of the person the agent is working for. The agents' older
whiteboard tools (write, draw an SVG, show an image, pin an item, clear) now
act on whiteboard widgets too: they take an optional `whiteboard_name` and
use the first board (usually *Main board*) without one.

## Files are physical

- **Bring files in:** drop them on the desktop window, or put them in the
  inbox folder (`~/Documents/OfficePlusOne/inbox` on desktop,
  `user://inbox` on Android) and press **Import files** on the panel. Each
  file appears as a document floating in front of you.
- **Pass them around:** people hand documents and clipboards to each other
  by grabbing them. **Let go of one next to an AI** and it takes it and
  reads it: text and code as text, images and PDFs as images/documents
  for Claude. **Press one against the whiteboard** to pin it there.
- **AIs do the same:** they create documents and clipboards, hold them,
  give them to a person (the item floats over to them) or to another agent
  (which then reads it), put them down, or pin them to the board.
- **Take them out:** pull the trigger (desktop: E) while holding a document
  to save a copy on your device. Exports requested from an AI are saved
  automatically as well as handed over.

## What's in it

- **Server–client multiplayer** (ENet). Any copy can host or join; LAN
  servers are auto-discovered. The server is authoritative for physics,
  the room, agents, files and AI; clients interpolate snapshots and predict
  what they hold.
- **The room:** saved (see above). Admins resize and decorate it from the
  watch's Room menu and a wall's context menu (colors), and add furniture
  from the floor's context menu and widgets from a wall's. (Cubes, balls and
  paint balls in old saves still load; they just can't be added any more.)
- **AI agents as NPCs:** create them from the floor's context menu (*Add →
  New AI*), then tell the agent who to be ("you're Ada, a patent lawyer with
  a calm British voice"). Each has its own
  persona, voice (a best-tts voice) and speaking speed, model and effort, and
  is saved with the room. They never move on their own, but anyone can grab
  and carry them (agents are never locked), or summon them (point at the
  floor → *Summon AI*). Their head turns to
  whoever talks to them; a light on their antenna shows
  listening/thinking/speaking.
- **Look:** people and AIs share one cartoon style (Wii-Mii-like,
  `scenes/characters/mii_head.tscn`): round heads with big blinking eyes that
  glance around, eyebrows, rosy cheeks and a mouth that moves when they talk,
  toon-shaded bodies and hands. Skin and hair come from their name; shirts
  from their colour. AIs also wear their mood on their face (brows up when
  listening, a thoughtful look while thinking) and have an antenna.
- **Talking:** point at an agent and speak; when you stop pointing, the
  server transcribes it (on-device Whisper), runs Claude with tools (the
  OpenAI fallback if that fails), and the answer comes back as a speech
  bubble plus a best-tts voice streamed from the agent's head.
- **Physics:** server-authoritative Jolt at 90 Hz. Clients render
  timestamped snapshots 100 ms behind the server, with interpolation.
  Held objects follow your hand's velocity and are pulled toward it, so they
  still collide and heavy ones lag believably; anything stuck behind a wall
  is let go. Remote hands are extrapolated between network updates. New
  objects are placed in free space, small objects use continuous collision,
  and floating or carried items don't collide.
- **Non-verbal output:** agents write or draw (SVG) on the whiteboard, show
  images from URLs, and hand over clipboards and documents.
- **Exports:** documents (md/txt/csv/json/html/…) or slide decks (.pptx +
  standalone .html + .md), saved to `~/Documents/OfficePlusOne` (desktop,
  when the OS reports a Documents folder) or `user://exports`, and handed over
  physically.
- **Calling people over:** point at them → *Ask over*; they get a buzz and
  answer from their watch's Me menu (*Requests*).
- **Proximity voice chat:** mic audio is relayed by the server to everyone
  in the office and played positionally from each avatar's head.
- **Shared state:** the room, bodies, items, agent states, the board and
  avatars are replicated so everyone sees the same thing.

## Layout

```
scenes/main.tscn            environment + world containers
scenes/entities/            agent · document · clipboard · props/{chair,table,plant,lamp,monitor,drawer} (+ legacy cube,ball,paint)
scenes/widgets/             calendar · alarm · timer · whiteboard · tv (wall widgets)
scenes/vnc/vnc_screen.tscn  read-only remote screen (TVs and monitors)
scenes/player/              local_player · hand · avatar · pointer (ray) · watch
scenes/ui/                  radial_menu · radial_button · menus/{floor,wall,widget,calendar_day,object,agent,player,personal,room}_menu, file_browser (inherit radial_menu)
scenes/world/               room · poke_button · lobby
scenes/ui/virtual_keyboard.tscn   reusable text entry (VirtualKeyboard.open(...))
shaders/outline.gdshader    target highlight
scripts/autoload/  config · net (sessions, membership/roles, knocks, summons, LAN discovery)
                   office (the room + its actions, guest permissions) · files (file store, chunked transfer)
                   saves (snapshot/restore, autosave, named saves)
                   sync (entities, snapshots, grabs, handoffs, poses, images)
                   voice (routing) · ai (brains, tools, permissions, skills, widget notes)
                   widgets (wall placement, entity operations, alarm clock, drawer listings)
scripts/ai/        claude_client · openai_client (fallback, Messages <-> Chat Completions) · local_whisper
                   tools (schemas) · widget_mcp (widget MCP server) · exporter · http
ai/skills/widgets/SKILL.md   the agents' preloaded widgets skill (exported via include_filter)
scripts/widgets/   widget (base) · calendar · alarm · timer · whiteboard_widget · board_pen (drawing) · tv · practice (tutorial)
scripts/vnc/       vnc_client (RFB 3.3–3.8, Raw/CopyRect/resize, keyboard, no mouse) · des (VNC auth) · vnc_screen
addons/            godotopenxrvendors (Android XR loaders) · godot_whisper (offline STT) · best-tts (offline neural TTS)
scripts/entities/  net_body (replicated rigid body) · prop · document · clipboard · agent_body
                   monitor · drawer · remote_display (shared TV/monitor screen logic)
scripts/player/    local_player (VR + desktop rig) · hand · avatar
                   hand_gestures (pointing/clench/pinch from joints or controller) · pointer (ray + menu gesture)
                   watch (time + Me/Room menus on the left wrist)
scripts/ui/        radial_menu · radial_button · menus/ (one script per context menu)
scripts/world/     room · poke_button · grab_handle · lobby · tutorial (the tutorial world)
scripts/voice/     voice_codec (mu-law, resample, wav) · voice_capture · voice_playback
tests/selftest.gd  headless host + knocking client + Whisper smoke tests (tools/selftest.sh; runs in a
                   throwaway data folder, so it's safe while the app is open)
tests/fake_openai_server.py              stand-in for the OpenAI fallback test
tests/vnc_test.gd + fake_vnc_server.py   VNC viewer test (tests/vnc_selftest.sh; also run by tools/selftest.sh)
tools/scenegen.py, gen_widget_scenes.py  dev helpers that generated the widget/prop scenes
```

Scenes hold the layout and look; scripts add behaviour. The room's walls and
the keyboard's keys are generated in code because they depend on runtime
values (room size, key layout).

## Known limits / next steps

- Voice uses 16 kHz mu-law (~128 kbit/s per talker) because Godot has no
  built-in Opus encoder; swapping in an Opus GDExtension is the upgrade path.
- Speech is point-to-talk (no wake word); your words are sent when you stop
  pointing, and replies are spoken after the model finishes (sentences are
  synthesized one after another to start sooner).
- Identity is just a name; add a password or key exchange before using
  roles on an untrusted network.
- Saves embed documents and images as base64, so a room full of large files
  makes large save files.
- Room-scale body collision for players is not implemented (hands push
  objects; you can walk through furniture).
- best-tts needs a GPU on the host; a headless dedicated server's agents
  only show speech bubbles. Its G2P covers English (other voices exist, but
  need IPA input).
- Whisper runs on the server; a Quest acting as host can run it (arm64
  build included) but slowly. Prefer a PC host or a speech API.
- Hand-tracking gestures (pointing/clench thresholds, the 6 in pull, the
  watch's wrist angle) are
  first-pass values in `hand_gestures.gd`/`pointer.gd`/`watch.gd` and need tuning on a
  headset. Hand joints are shown locally; other people see your palm and
  your pointer ray.
- There's no smooth locomotion with bare hands (the old "grab the world"
  drag was replaced by the menu's *Teleport here*); controllers still have
  stick movement.
