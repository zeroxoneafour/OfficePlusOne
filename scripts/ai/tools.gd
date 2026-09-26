extends RefCounted
## Tool definitions sent to Claude. Agents act through their body and the
## room's shared surfaces. (The room itself isn't voice controlled.)

const AGENT := [
	{
		"name": "write_on_whiteboard",
		"description": "Replace a whiteboard's title and text (lists, notes, tables as aligned text). Everyone sees it. Keep it under ~1200 characters. (Hand-drawn strokes stay.)",
		"input_schema": {"type": "object", "properties": {
			"whiteboard_name": {"type": "string", "description": "Which whiteboard widget (by name). Omit for the first one (usually \"Main board\")."},
			"title": {"type": "string"},
			"text": {"type": "string"},
		}, "required": ["title", "text"]},
	},
	{
		"name": "draw_on_whiteboard",
		"description": "Draw a diagram/chart/sketch on a whiteboard as a standalone SVG (include width, height and viewBox; use basic shapes and <text>; no external references or scripts). Optional short caption shown beside it.",
		"input_schema": {"type": "object", "properties": {
			"whiteboard_name": {"type": "string", "description": "Which whiteboard widget (by name). Omit for the first one (usually \"Main board\")."},
			"title": {"type": "string"},
			"svg": {"type": "string"},
			"caption": {"type": "string"},
		}, "required": ["title", "svg"]},
	},
	{
		"name": "show_image_on_whiteboard",
		"description": "Download a PNG/JPEG/WebP image from a public http(s) URL and show it on a whiteboard. Only use URLs you are confident exist.",
		"input_schema": {"type": "object", "properties": {
			"whiteboard_name": {"type": "string", "description": "Which whiteboard widget (by name). Omit for the first one (usually \"Main board\")."},
			"url": {"type": "string"},
			"title": {"type": "string"},
			"caption": {"type": "string"},
		}, "required": ["url"]},
	},
	{
		"name": "clear_whiteboard",
		"description": "Wipe a whiteboard completely (text, picture and drawings).",
		"input_schema": {"type": "object", "properties": {
			"whiteboard_name": {"type": "string", "description": "Which whiteboard widget (by name). Omit for the first one (usually \"Main board\")."},
		}},
	},
	{
		"name": "hand_clipboard",
		"description": "Hand a physical clipboard to someone (default: the person you're talking with; or name a person or another agent). People can carry it and flip pages. Use for personal notes, checklists, drafts, or anything to keep in hand. Each page holds ~600 characters. Optional SVG becomes an illustrated first page.",
		"input_schema": {"type": "object", "properties": {
			"title": {"type": "string"},
			"pages": {"type": "array", "items": {"type": "string"}},
			"svg": {"type": "string"},
			"to": {"type": "string", "description": "Name of a person or agent. Omit for the person you're talking with."},
		}, "required": ["title", "pages"]},
	},
	{
		"name": "create_document",
		"description": "Create a file as a physical document in the room and hand it to someone (default: the person you're talking with; or name a person or another agent). They can pass it on, give it to agents, pin it to the whiteboard or save it to their device. Use export_document instead when they explicitly want it saved outside the app right away.",
		"input_schema": {"type": "object", "properties": {
			"filename": {"type": "string"},
			"content": {"type": "string"},
			"to": {"type": "string"},
		}, "required": ["filename", "content"]},
	},
	{
		"name": "give_item",
		"description": "Hand an item you are holding (see 'You are holding' in the context) to a person or another AI agent by name. Another agent will read it.",
		"input_schema": {"type": "object", "properties": {
			"item": {"type": "string", "description": "Item number like #12, or its name."},
			"to": {"type": "string", "description": "Person or agent name. Omit for the person you're talking with."},
		}, "required": ["item"]},
	},
	{
		"name": "put_down_item",
		"description": "Put down an item you are holding.",
		"input_schema": {"type": "object", "properties": {"item": {"type": "string"}}, "required": ["item"]},
	},
	{
		"name": "pin_item_to_whiteboard",
		"description": "Pin an item you're holding (an image, document or clipboard) to a whiteboard so everyone can see it.",
		"input_schema": {"type": "object", "properties": {"item": {"type": "string"},
			"whiteboard_name": {"type": "string", "description": "Which whiteboard widget (by name). Omit for the first one (usually \"Main board\")."},
		}, "required": ["item"]},
	},
	{
		"name": "export_document",
		"description": "Export a file for use outside the app: it is saved on the requesting person's device and a physical copy is handed to them. Pick the extension that fits: .md, .txt, .csv, .json, .html, .svg, .py, etc.",
		"input_schema": {"type": "object", "properties": {
			"filename": {"type": "string"},
			"content": {"type": "string"},
		}, "required": ["filename", "content"]},
	},
	{
		"name": "export_slides",
		"description": "Export a slide deck: .pptx, a self-contained .html presentation and .md are saved on the requesting person's device, and the .pptx is handed to them physically.",
		"input_schema": {"type": "object", "properties": {
			"title": {"type": "string"},
			"slides": {"type": "array", "items": {"type": "object", "properties": {
				"title": {"type": "string"},
				"bullets": {"type": "array", "items": {"type": "string"}},
				"notes": {"type": "string"},
				"svg": {"type": "string", "description": "Optional inline SVG diagram (HTML deck only)."},
			}, "required": ["title", "bullets"]}},
		}, "required": ["title", "slides"]},
	},
	{
		"name": "gesture",
		"description": "Make a body gesture: wave (greeting), point (at the board), offer (hold out a hand), think, shrug, nod.",
		"input_schema": {"type": "object", "properties": {
			"kind": {"type": "string", "enum": ["wave", "point", "offer", "think", "shrug", "nod"]},
		}, "required": ["kind"]},
	},
	{
		"name": "update_my_profile",
		"description": "Change your own name, persona, voice, speaking speed or body color (hex) when someone asks you to.",
		"input_schema": {"type": "object", "properties": {
			"name": {"type": "string"},
			"persona": {"type": "string"},
			"voice": {"type": "string", "description": "Your voice. American female: af_heart, af_bella, af_nicole, af_sarah, af_sky, af_nova, af_alloy, af_aoede, af_jessica, af_kore, af_river. American male: am_michael, am_adam, am_fenrir, am_puck, am_echo, am_eric, am_liam, am_onyx. British female: bf_emma, bf_isabella, bf_alice, bf_lily. British male: bm_george, bm_lewis, bm_daniel, bm_fable."},
			"speed": {"type": "string", "description": "Speaking speed, 0.5 (slow) to 2.0 (fast); 1.0 is normal."},
			"color": {"type": "string"},
		}},
	},
]
