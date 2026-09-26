# Platforms: build & run

Office Plus One targets Linux desktop (SteamVR/Monado/WiVRn/ALVR) and Android
standalone headsets (Meta Quest primarily, plus Pico / Android XR / Khronos
generic devices) via OpenXR. This assumes `xr/openxr/enabled=true` and
`xr/shaders/enabled=true` are set under `[xr]` in `project.godot` (required
for OpenXR to activate at all, and for XR-aware shaders respectively).

Two export presets are defined in `export_presets.cfg`: **Linux** and
**Android XR (Quest)**.

## Linux desktop (with a headset)

You need a running OpenXR runtime before starting the app, so the OpenXR
loader can find an active session.

- **Monado** (native Linux OpenXR runtime, used directly with wired/Wi-Fi
  standalone headsets or PC VR hardware): start `monado-service` (or your
  distro's Monado session) before launching the game. Verify
  `XR_RUNTIME_JSON`/`XDG_CONFIG_HOME` points at Monado's
  `openxr_1.json` active runtime manifest, or use `monado-cli`/GUI to select it.
- **WiVRn** (streams OpenXR from this Linux box to a standalone headset,
  e.g. Quest, over Wi-Fi): start the `wivrn-server`, pair/connect the headset
  running the WiVRn client APK, then launch the app on the PC as usual - it
  talks to WiVRn's local Monado-compatible runtime.
- **SteamVR**: launch SteamVR first (with your headset's driver, e.g. a
  Quest via Steam Link/Virtual Desktop, or a wired PCVR headset) so it
  registers itself as the active OpenXR runtime, then launch the app.
- **ALVR**: start the ALVR streamer on this machine and connect the ALVR
  client on the headset; ALVR registers its own OpenXR runtime while
  streaming is active, then launch the app normally.

Run the exported binary (or `godot --path .` from the editor) with no extra
flags to go straight into VR via whichever runtime is currently active.

## Running without a headset (desktop fallback)

The app has a non-VR desktop fallback mode, started with an extra
`--desktop` user argument after `--`:

```sh
build/linux/OfficePlusOne.x86_64 -- --desktop
# or, running from the editor / source:
godot --path . -- --desktop
```

## Dedicated headless server

For a server-only instance (no rendering, no XR), run with `--headless` and
the `--server` user argument:

```sh
godot --headless -- --server
# or, for an exported build:
build/linux/OfficePlusOne.x86_64 --headless -- --server
```

## Android / Meta Quest export

1. **Install the OpenXR vendors addon** (one-time, or to update):
   ```sh
   tools/setup_android_xr.sh
   ```
   This downloads the latest `godot_openxr_vendors` release compatible with
   Godot 4.6+ (covers 4.7.x) from GitHub and installs it into
   `addons/godotopenxrvendors/`. It's a GDExtension (`plugin.gdextension`),
   so it does **not** need enabling in `project.godot`'s `[editor_plugins]`
   list - it loads automatically.
2. **Install the Android build template**, once, from the Godot editor:
   `Project > Install Android Build Template...` (writes `res://android/build`,
   already gitignored).
3. **Point the editor at your Android SDK/JDK**: `Editor Settings > Export >
   Android` - set `Android SDK Path` (and `Java SDK Path`/`Debug Keystore` if
   not auto-detected). Leaving the keystore fields blank makes Godot use the
   auto-generated debug keystore from Editor Settings, which is fine for
   sideloading during development.
4. **Enable Developer Mode** on the Quest and connect it (USB with a trusted
   computer, or `adb connect <headset-ip>:5555` over Wi-Fi). Confirm with
   `adb devices`.
5. **Export and install** using the "Android XR (Quest)" preset:
   - From the editor: `Project > Export...` -> select "Android XR (Quest)"
     -> Export Project (or use the one-click deploy/play button once a
     device is detected).
   - From the CLI:
     ```sh
     godot --headless --export-debug "Android XR (Quest)" build/android/OfficePlusOne.apk
     adb install -r build/android/OfficePlusOne.apk
     ```
6. **Grant the microphone permission** the first time it launches (Android
   asks at runtime for `RECORD_AUDIO` even though it's declared in the
   manifest): `adb shell pm grant xyz.vaughanm.officeplusone android.permission.RECORD_AUDIO`
   if it doesn't prompt automatically, or accept the in-headset permission
   dialog when voice chat first activates.

The preset is arm64-v8a only, uses the Gradle build (required for the
vendors plugin's AAR/native libraries), targets OpenXR mode with the Meta
vendor plugin enabled (hand tracking optional, passthrough off), and
declares: `INTERNET`, `RECORD_AUDIO`, `ACCESS_NETWORK_STATE`,
`ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` (LAN discovery/multicast
for finding other players on the local network), and `MODIFY_AUDIO_SETTINGS`.

## Speech on each platform

- **Native text-to-speech** (used when no speech API key is set) needs an OS
  speech engine on every client:
  - Linux: `speech-dispatcher` with a voice module (e.g. `espeak-ng`, or
    `piper` for better quality). Fedora: `sudo dnf install speech-dispatcher espeak-ng`.
    Check with `spd-say "hello"`.
  - Android/Quest: the system text-to-speech engine. Quest headsets may not
    ship one; install one (e.g. Google Speech Services or RHVoice as an APK)
    and select it in Android's TTS settings. Otherwise replies show as
    speech bubbles only.
  - Windows/macOS: built in.
- **Whisper speech-to-text** runs on the *server*. The addon ships Linux
  x86_64, Windows x86_64 and Android arm64 libraries
  (`addons/godot_whisper/godot_whisper.gdextension`). The first server start
  downloads the model to `user://models/` (needs internet once), or you can
  copy `ggml-<model>.bin` there yourself. To use the GPU, set
  `audio/input/transcribe/use_gpu=true` in Project Settings; it's off by
  default because the Vulkan backend crashed on an NVIDIA laptop GPU in
  testing.

## Hand tracking

`project.godot` enables `xr/openxr/extensions/hand_tracking` plus the
unobstructed/controller data-source extensions (so the app can tell real
hands from controller-driven hand poses) and the hand interaction profile.
The Quest preset requests hand tracking as *optional* at high frequency;
eye, face and body tracking and passthrough are off, so their permission
prompts don't appear. On Linux, hand tracking works with runtimes that expose
`XR_EXT_hand_tracking` (e.g. WiVRn or ALVR streaming from a Quest, or
SteamVR with supported hardware).
