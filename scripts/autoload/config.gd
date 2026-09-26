extends Node
## Settings from (lowest to highest priority): defaults, user://config.cfg,
## environment variables, command line (`godot -- --host --name=Ada`).
## API keys only matter on the machine that hosts the server.

const CONFIG_PATH := "user://config.cfg"
## Personal choices made in-app (watch toggles…), kept separate from config.cfg.
const PREFS_PATH := "user://prefs.cfg"

const DEFAULTS := {
	"player": {
		"name": "",
	},
	"network": {
		"port": 7777,
		"discovery_port": 7778,
		"default_join": "",
	},
	"server": {
		# Shown in the LAN server list (defaults to "<name>'s office").
		"name": "",
		# true: anyone may walk in. false: non-members knock and an owner/admin decides.
		"open": false,
		# Names that are admins on this server (mainly for dedicated servers,
		# which have no owner playing). Note: names are not authenticated.
		"admins": [],
		"max_upload_mb": 16,
	},
	"ai": {
		"anthropic_api_key": "",
		"anthropic_base_url": "https://api.anthropic.com",
		"model": "claude-opus-5",
		# Voice conversation is latency sensitive; raise per agent for deeper work.
		"effort": "low",
		"max_tokens": 16000,
		# Fallback when a Claude request fails (or no Anthropic key is set):
		# the OpenAI Chat Completions API, or any compatible endpoint.
		"openai_api_key": "",
		"openai_base_url": "https://api.openai.com/v1",
		"openai_model": "gpt-5",
	},
	"speech": {
		# Local Whisper model (ggml name). Looked up in res://addons/godot_whisper/models/
		# then user://models/, and downloaded there on first use when allowed.
		# tiny.en-q5_1 (31 MB, fastest) · base.en-q5_1 (57 MB) · small.en-q5_1 (181 MB) · drop ".en" for other languages
		"whisper_model": "base.en-q5_1",
		"whisper_language": "English",
		"whisper_auto_download": true,
	},
}

const ENV_OVERRIDES := {
	"ANTHROPIC_API_KEY": ["ai", "anthropic_api_key"],
	"ANTHROPIC_BASE_URL": ["ai", "anthropic_base_url"],
	"OPO_MODEL": ["ai", "model"],
	"OPENAI_API_KEY": ["ai", "openai_api_key"],
	"OPENAI_BASE_URL": ["ai", "openai_base_url"],
	"OPO_OPENAI_MODEL": ["ai", "openai_model"],
}

var _cfg := ConfigFile.new()
var _prefs := ConfigFile.new()
## Parsed `--key=value` / `--flag` user args.
var args := {}


func _init() -> void:
	for section in DEFAULTS:
		for key in DEFAULTS[section]:
			_cfg.set_value(section, key, DEFAULTS[section][key])
	var file_cfg := ConfigFile.new()
	if file_cfg.load(CONFIG_PATH) == OK:
		for section in file_cfg.get_sections():
			for key in file_cfg.get_section_keys(section):
				_cfg.set_value(section, key, file_cfg.get_value(section, key))
	else:
		_write_template()
	for env_name in ENV_OVERRIDES:
		var v := OS.get_environment(env_name)
		if v != "":
			_cfg.set_value(ENV_OVERRIDES[env_name][0], ENV_OVERRIDES[env_name][1], v)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else true
	if args.has("name"):
		_cfg.set_value("player", "name", str(args["name"]))
	if args.has("port"):
		_cfg.set_value("network", "port", int(args["port"]))
	if str(_cfg.get_value("player", "name")) == "":
		var user := OS.get_environment("USER")
		_cfg.set_value("player", "name", user.capitalize() if user != "" else "Guest%d" % (randi() % 1000))
	_prefs.load(PREFS_PATH)


func get_value(section: String, key: String, default: Variant = null) -> Variant:
	return _cfg.get_value(section, key, default)


## A remembered personal preference (e.g. "highlight_targets").
func pref(key: String, default: Variant) -> Variant:
	return _prefs.get_value("prefs", key, default)


func set_pref(key: String, value: Variant) -> void:
	_prefs.set_value("prefs", key, value)
	_prefs.save(PREFS_PATH)


func player_name() -> String:
	return str(_cfg.get_value("player", "name"))


func has_arg(name: String) -> bool:
	return args.has(name)


func _write_template() -> void:
	# A config file without secrets so users can find and fill it in.
	var t := ConfigFile.new()
	for section in DEFAULTS:
		for key in DEFAULTS[section]:
			t.set_value(section, key, DEFAULTS[section][key])
	t.save(CONFIG_PATH)
	print("[Config] Wrote template config to ", ProjectSettings.globalize_path(CONFIG_PATH))
