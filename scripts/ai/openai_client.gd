class_name OpenAIClient extends Node
## Fallback model provider: the OpenAI Chat Completions API (or any compatible
## endpoint via `openai_base_url`), used when a Claude request fails or no
## Anthropic key is configured. It takes and returns the same shapes as
## ClaudeClient.create_message (a Messages API body in, a Messages API
## response out), translating system prompt, text, images, tools, tool calls
## and tool results both ways, so the agent loop doesn't care which answered.
## Server-side only: the key never leaves the host.

const RETRY_CODES := [408, 409, 429, 500, 502, 503, 504]


func is_configured() -> bool:
	return str(Config.get_value("ai", "openai_api_key", "")) != ""


func model_name() -> String:
	return str(Config.get_value("ai", "openai_model", "gpt-5"))


## Messages API body -> Chat Completions -> Messages API response, or {"error": String}.
func create_message(body: Dictionary) -> Dictionary:
	if not is_configured():
		return {"error": "No OpenAI API key configured on the server (set OPENAI_API_KEY or edit config.cfg)."}
	var url := str(Config.get_value("ai", "openai_base_url", "https://api.openai.com/v1")).trim_suffix("/") + "/chat/completions"
	var headers := PackedStringArray(["Authorization: Bearer " + str(Config.get_value("ai", "openai_api_key"))])
	var req := to_chat_request(body, model_name())
	var delay := 2.0
	for attempt in 3:
		var res: Dictionary = await Http.post_json(self, url, headers, req, 180.0)
		var parsed: Variant = JSON.parse_string(res["body"].get_string_from_utf8()) if res["body"].size() > 0 else null
		if res["ok"] and parsed is Dictionary and parsed.get("choices") is Array and parsed["choices"].size():
			return from_chat_response(parsed)
		var msg: String = res["error"]
		if parsed is Dictionary and parsed.get("error") is Dictionary:
			msg = "%s: %s" % [res["code"], parsed["error"].get("message", "")]
		if res["code"] in RETRY_CODES or res["code"] == 0:
			push_warning("[OpenAI] %s (attempt %d), retrying" % [msg, attempt + 1])
			await get_tree().create_timer(delay).timeout
			delay *= 2.5
			continue
		return {"error": msg}
	return {"error": "The fallback model service is busy; try again in a moment."}


## A Messages API request body as a Chat Completions request.
static func to_chat_request(body: Dictionary, model: String) -> Dictionary:
	var messages := []
	var system := ""
	if body.get("system") is Array:
		for b in body["system"]:
			if b is Dictionary and b.get("type") == "text":
				system += str(b.get("text", "")) + "\n"
	elif body.get("system") is String:
		system = body["system"]
	if system.strip_edges() != "":
		messages.append({"role": "system", "content": system.strip_edges()})
	for m in body.get("messages", []):
		if not m is Dictionary:
			continue
		var blocks: Array = m["content"] if m.get("content") is Array else [{"type": "text", "text": str(m.get("content", ""))}]
		if m.get("role") == "assistant":
			var text := ""
			var calls := []
			for b in blocks:
				match b.get("type"):
					"text":
						text += str(b.get("text", ""))
					"tool_use":
						calls.append({"id": str(b.get("id", "")), "type": "function",
								"function": {"name": str(b.get("name", "")), "arguments": JSON.stringify(b.get("input", {}))}})
			var out := {"role": "assistant", "content": text if text != "" else null}
			if calls.size():
				out["tool_calls"] = calls
			messages.append(out)
		else:
			# Tool results first (they must follow the assistant's calls), then the rest.
			var parts := []
			for b in blocks:
				match b.get("type"):
					"tool_result":
						messages.append({"role": "tool", "tool_call_id": str(b.get("tool_use_id", "")), "content": _result_text(b.get("content", ""))})
					"text":
						parts.append({"type": "text", "text": str(b.get("text", ""))})
					"image":
						var src: Dictionary = b.get("source", {})
						if src.get("type") == "base64":
							parts.append({"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % [src.get("media_type", "image/png"), src.get("data", "")]}})
					"document":
						parts.append({"type": "text", "text": "[A PDF document was attached here, but this model can't read it.]"})
			if parts.size():
				messages.append({"role": "user", "content": parts})
	var req := {"model": model, "messages": messages}
	if body.has("max_tokens"):
		req["max_completion_tokens"] = int(body["max_tokens"])
	var tools := []
	for t in body.get("tools", []):
		if t is Dictionary and t.has("input_schema"):
			tools.append({"type": "function", "function": {"name": t["name"], "description": str(t.get("description", "")), "parameters": t["input_schema"]}})
	if tools.size():
		req["tools"] = tools
	return req


static func _result_text(content: Variant) -> String:
	if content is Array:
		var text := ""
		for c in content:
			if c is Dictionary and c.get("type") == "text":
				text += str(c.get("text", ""))
		return text
	return str(content)


## A Chat Completions response as a Messages API response.
static func from_chat_response(res: Dictionary) -> Dictionary:
	var choice: Dictionary = res["choices"][0]
	var msg: Dictionary = choice.get("message", {})
	var content := []
	if msg.get("content") is String and str(msg["content"]).strip_edges() != "":
		content.append({"type": "text", "text": msg["content"]})
	for call in (msg.get("tool_calls") if msg.get("tool_calls") is Array else []):
		var fn: Dictionary = call.get("function", {})
		var args: Variant = JSON.parse_string(str(fn.get("arguments", "{}")))
		content.append({"type": "tool_use", "id": str(call.get("id", "")), "name": str(fn.get("name", "")),
				"input": args if args is Dictionary else {}})
	var stop := "end_turn"
	match str(choice.get("finish_reason", "")):
		"tool_calls":
			stop = "tool_use"
		"length":
			stop = "max_tokens"
		"content_filter":
			stop = "refusal"
	return {"role": "assistant", "content": content, "stop_reason": stop, "model": res.get("model", "")}
