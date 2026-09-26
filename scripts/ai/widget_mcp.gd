class_name WidgetMcp extends RefCounted
## The widget MCP server: how AI agents use the room's wall widgets.
##
## It speaks MCP (JSON-RPC 2.0: initialize, tools/list, tools/call, with MCP
## tool definitions and results), but runs inside the host rather than as a
## separate process, because it acts directly on the live room, and because
## Claude's hosted MCP connector can only reach servers on the public internet.
## The AI autoload lists these tools to Claude (anthropic_tools()) and routes
## the calls back here (call_tool()). The agents' preloaded skill,
## ai/skills/widgets/SKILL.md, explains when and how to use them.

const PROTOCOL_VERSION := "2025-06-18"
const SERVER_INFO := {"name": "office-plus-one-widgets", "version": "1.0.0"}

const TOOLS := [
	{
		"name": "widget_list",
		"title": "List widgets",
		"description": "List every widget on the room's walls (calendars, alarms, timers, whiteboards, TVs) with its name, what's on it now and how to use it.",
		"inputSchema": {"type": "object", "properties": {}},
	},
	{
		"name": "widget_calendar",
		"title": "Write on a calendar",
		"description": "Add an entry to a wall calendar. Everyone sees it on the calendar. Give contents \"\" to remove the entries on that date (at that time, if a time is given).",
		"inputSchema": {"type": "object", "properties": {
			"calendar_name": {"type": "string", "description": "The calendar's name, as listed (case-insensitive). May be empty if there's only one calendar."},
			"date": {"type": "string", "description": "YYYY-MM-DD, or today / tomorrow."},
			"time": {"type": "string", "description": "24-hour HH:MM (2:30pm also works). Empty for an all-day entry."},
			"contents": {"type": "string", "description": "What goes in the entry (up to 200 characters). Empty removes entries instead."},
		}, "required": ["calendar_name", "date", "contents"]},
	},
	{
		"name": "widget_alarm",
		"title": "Set an alarm",
		"description": "Set a wall alarm clock to go off at a time (the host's local time) and turn it on, or pass \"off\" to turn it off. When it goes off it rings for everyone until someone stops it.",
		"inputSchema": {"type": "object", "properties": {
			"alarm_name": {"type": "string", "description": "The alarm's name, as listed. May be empty if there's only one alarm."},
			"time": {"type": "string", "description": "24-hour HH:MM (7:30am also works), or \"off\"."},
		}, "required": ["alarm_name", "time"]},
	},
	{
		"name": "widget_timer",
		"title": "Set a timer",
		"description": "Set a wall countdown timer to a length of time, which resets it and starts it counting down right away. When it reaches zero it rings for everyone until someone stops it. People can also start, stop and reset it by hand.",
		"inputSchema": {"type": "object", "properties": {
			"timer_name": {"type": "string", "description": "The timer's name, as listed. May be empty if there's only one timer."},
			"time_minutes": {"type": "integer", "minimum": 0, "description": "Minutes (may be more than 59)."},
			"time_seconds": {"type": "integer", "minimum": 0, "description": "Seconds."},
		}, "required": ["timer_name", "time_minutes", "time_seconds"]},
	},
	{
		"name": "widget_whiteboard",
		"title": "Write on a whiteboard",
		"description": "Write text on a wall whiteboard widget (people draw on these by hand; you write the text layer). Plain text, up to ~1500 characters in total; use short lines. (For a title, a diagram or a picture, use the write_on_whiteboard / draw_on_whiteboard / show_image_on_whiteboard tools.)",
		"inputSchema": {"type": "object", "properties": {
			"whiteboard_name": {"type": "string", "description": "The whiteboard's name, as listed. May be empty if there's only one whiteboard."},
			"text": {"type": "string", "description": "The text to write."},
			"mode": {"type": "string", "enum": ["replace", "append", "clear"], "description": "replace (default) the board's text, append a line to it, or clear it."},
		}, "required": ["whiteboard_name", "text"]},
	},
]

const USAGE := {
	"calendar": "widget_calendar(calendar_name=\"%s\", date, time, contents)",
	"alarm": "widget_alarm(alarm_name=\"%s\", time)",
	"timer": "widget_timer(timer_name=\"%s\", time_minutes, time_seconds)",
	"whiteboard": "widget_whiteboard(whiteboard_name=\"%s\", text, mode)",
	"tv": "people connect it to a computer from its menu; you can't control or see it",
}

static var _anthropic_tools: Array = []


## MCP tool definitions as Claude Messages API tools.
static func anthropic_tools() -> Array:
	if _anthropic_tools.is_empty():
		for t in TOOLS:
			_anthropic_tools.append({"name": t["name"], "description": t["description"], "input_schema": t["inputSchema"]})
	return _anthropic_tools


static func has_tool(tool_name: String) -> bool:
	return TOOLS.any(func(t): return t["name"] == tool_name)


## Handle one MCP JSON-RPC request on behalf of `peer` (the person the agent is
## working for; their permissions apply). Returns the JSON-RPC response.
static func handle(request: Dictionary, peer: int) -> Dictionary:
	var id: Variant = request.get("id")
	var params: Dictionary = request.get("params") if request.get("params") is Dictionary else {}
	match str(request.get("method", "")):
		"initialize":
			return _result(id, {"protocolVersion": PROTOCOL_VERSION, "capabilities": {"tools": {"listChanged": false}}, "serverInfo": SERVER_INFO})
		"ping":
			return _result(id, {})
		"tools/list":
			return _result(id, {"tools": TOOLS})
		"tools/call":
			var tool_name := str(params.get("name", ""))
			if not has_tool(tool_name):
				return {"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": "Unknown tool: %s" % tool_name}}
			var args: Dictionary = params.get("arguments") if params.get("arguments") is Dictionary else {}
			var text := _call(tool_name, args, peer)
			return _result(id, {"content": [{"type": "text", "text": text.trim_prefix("Error: ")}], "isError": text.begins_with("Error")})
	return {"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "Method not found"}}


## Call a tool for agent `agent_name`; returns its text (starting "Error: " on
## failure), for the AI autoload.
static func call_tool(tool_name: String, args: Dictionary, peer: int, agent_name := "") -> String:
	Widgets.acting_ai = agent_name
	var res := handle({"jsonrpc": "2.0", "id": 0, "method": "tools/call", "params": {"name": tool_name, "arguments": args}}, peer)
	Widgets.acting_ai = ""
	if res.has("error"):
		return "Error: " + str(res["error"]["message"])
	var text := str(res["result"]["content"][0]["text"])
	return ("Error: " + text) if res["result"]["isError"] == true else text


static func _result(id: Variant, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


static func _call(tool_name: String, args: Dictionary, peer: int) -> String:
	if tool_name == "widget_list":
		return listing()
	var kind: String = {"widget_calendar": "calendar", "widget_alarm": "alarm", "widget_timer": "timer", "widget_whiteboard": "whiteboard"}[tool_name]
	var key: String = {"calendar": "calendar_name", "alarm": "alarm_name", "timer": "timer_name", "whiteboard": "whiteboard_name"}[kind]
	var w := Widgets.find(kind, str(args.get(key, "")))
	if not w:
		var names := Widgets.names_of(kind)
		if names.is_empty():
			return "Error: there's no %s on the walls. A person can add one: point at a wall, pull back, Add widget." % kind
		return "Error: no %s called \"%s\". The %ss are: %s." % [kind, args.get(key, ""), kind, ", ".join(names.map(func(n): return "\"%s\"" % n))]
	var by := -1 # an AI
	match kind:
		"calendar":
			var contents := str(args.get("contents", ""))
			if contents.strip_edges() == "":
				return (w as CalendarWidget).server_remove_entries(str(args.get("date", "")), str(args.get("time", "")), "", by)
			return (w as CalendarWidget).server_add_entry(str(args.get("date", "")), str(args.get("time", "")), contents, by)
		"alarm":
			return (w as AlarmWidget).server_set(str(args.get("time", "")), by)
		"timer":
			var secs := int(args.get("time_minutes", 0)) * 60 + int(args.get("time_seconds", 0))
			if secs <= 0 or secs > TimerWidget.MAX_SECONDS:
				return "Error: give a length between 1 second and 24 hours."
			return (w as TimerWidget).server_set(secs, true, by)
		"whiteboard":
			var mode := str(args.get("mode", "replace"))
			if not mode in ["replace", "append", "clear"]:
				mode = "replace"
			return (w as WhiteboardWidget).server_write(str(args.get("text", "")), mode, by)
	return "Error: unknown widget"


## Every widget: name, where, what's on it, and how to use it.
static func listing() -> String:
	var all := Widgets.all()
	if all.is_empty():
		return "There are no widgets on the walls yet. (People add them: point at a wall, pull back, Add widget.)"
	var lines := ["Widgets on the walls (%d). Today is %s, the host's time is %s." % [all.size(), CalendarWidget.today(), Time.get_time_string_from_system().substr(0, 5)]]
	for w: Widget in all:
		lines.append("- %s \"%s\" (%s wall): %s. Use: %s" % [w.kind, w.widget_name(), w.data.get("wall", "?"), w.ai_summary(),
				str(USAGE.get(w.kind, "not for you")) % w.widget_name() if str(USAGE.get(w.kind, "")).contains("%s") else str(USAGE.get(w.kind, "not for you"))])
	return "\n".join(lines)


## A short list of names (for context when nothing has changed).
static func names_line() -> String:
	var parts := []
	for w: Widget in Widgets.all():
		parts.append("%s \"%s\"" % [w.kind, w.widget_name()])
	return ", ".join(parts) if parts.size() else "none"
