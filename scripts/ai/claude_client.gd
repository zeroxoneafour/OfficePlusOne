class_name ClaudeClient extends Node
## Raw-HTTP client for the Claude Messages API (GDScript has no official SDK).
## Server-side only: the API key never leaves the host.

const API_VERSION := "2023-06-01"
## Server-side fallback: if a request is declined by a safety classifier, the
## API re-runs it on Anthropic's recommended fallback model instead.
const BETAS := "server-side-fallback-2026-07-01"
const RETRY_CODES := [408, 409, 429, 500, 502, 503, 504, 529]


func is_configured() -> bool:
	return str(Config.get_value("ai", "anthropic_api_key")) != ""


## POST /v1/messages. Returns the parsed response, or {"error": String}.
func create_message(body: Dictionary) -> Dictionary:
	if not is_configured():
		return {"error": "No Anthropic API key configured on the server (set ANTHROPIC_API_KEY or edit config.cfg)."}
	body = body.duplicate()
	body["fallbacks"] = "default"
	var url := str(Config.get_value("ai", "anthropic_base_url")).trim_suffix("/") + "/v1/messages"
	var headers := PackedStringArray([
		"x-api-key: " + str(Config.get_value("ai", "anthropic_api_key")),
		"anthropic-version: " + API_VERSION,
		"anthropic-beta: " + BETAS,
	])
	var delay := 2.0
	for attempt in 3:
		var res: Dictionary = await Http.post_json(self, url, headers, body, 180.0)
		var parsed: Variant = JSON.parse_string(res["body"].get_string_from_utf8()) if res["body"].size() > 0 else null
		if res["ok"] and parsed is Dictionary:
			return parsed
		var msg: String = res["error"]
		if parsed is Dictionary and parsed.has("error"):
			msg = "%s: %s" % [res["code"], parsed["error"].get("message", "")]
		if res["code"] in RETRY_CODES or res["code"] == 0:
			push_warning("[Claude] %s (attempt %d), retrying" % [msg, attempt + 1])
			await get_tree().create_timer(delay).timeout
			delay *= 2.5
			continue
		return {"error": msg}
	return {"error": "The model service is busy; try again in a moment."}
