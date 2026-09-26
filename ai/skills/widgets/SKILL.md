---
name: office-widgets
description: Use the room's wall widgets (calendars, alarms, timers, whiteboards, TVs) through the widget MCP tools. Use when someone asks you to schedule, remind, time, count down, note down, or show something on a wall, or asks what's on a calendar, alarm, timer or board.
---

# Wall widgets

The office's walls can hold widgets that people hang there (point at a wall, pull back, Add widget). Each one has a name people chose, like "Team" or "Kitchen". There can be several of the same kind, so always use the exact name. Every message you get starts with a context note listing the widgets. When widgets were added, removed, renamed or changed since you last spoke, the note has the full list with how to use each one, plus what changed.

Tools (from the office-plus-one-widgets MCP server):

- `widget_list()`: every widget, what's on it now, and how to use it. Call it if you're unsure of a name or what a widget currently shows.
- `widget_calendar(calendar_name, date, time, contents)`: add an entry. `date` is YYYY-MM-DD (or today / tomorrow). `time` is 24-hour HH:MM, or empty for all day. To remove entries, pass empty `contents` with the date (and time).
- `widget_alarm(alarm_name, time)`: set an alarm clock for a 24-hour HH:MM (host's local time) and turn it on, or pass "off". It rings for everyone in the room until someone stops it. A context note tells you when an alarm went off.
- `widget_timer(timer_name, time_minutes, time_seconds)`: set a countdown timer to that length. This resets it and starts it right away. It rings for everyone when it runs out, until someone stops it. People can also set, start, stop and reset it by hand. A context note tells you when a timer ran out.
- `widget_whiteboard(whiteboard_name, text, mode)`: write the text layer of a whiteboard widget. `mode` is replace (default), append (adds a line), or clear. People draw on these boards by hand; you can't see the drawings, only the text.
- TVs show someone's computer screen, read-only. People connect them from the TV's menu. You can't see or control them.

## How to use them well

- Resolve relative dates yourself: the context note gives today's date and the host's time. Confirm aloud in words ("Done, it's on the Team calendar for Tuesday at two"), not in ISO format.
- If a name is ambiguous or doesn't exist, the tool error lists the real names. Pick the obviously intended one, or ask.
- If there's no widget of the kind you need, say so and suggest someone add one from the wall's menu. You can't hang widgets yourself.
- The room's whiteboards are all widgets. The one a new office starts with is called "Main board". Your whiteboard tools (write_on_whiteboard for a title and text, draw_on_whiteboard for an SVG diagram, show_image_on_whiteboard, pin_item_to_whiteboard, clear_whiteboard) take an optional whiteboard_name and use the first board when you leave it out. widget_whiteboard only edits the text.
- Use a timer for "in 10 minutes" or "give us 5 minutes". Use an alarm for a clock time ("at 3pm").
- Keep whiteboard text short and scannable: a title line, then short lines. Use append to add to what's there instead of wiping other people's notes.
- Don't set alarms or add calendar entries nobody asked for.
