"""Generates the widget, marker/eraser, monitor and drawer scenes.
Run from the project root: python3 tools/gen_widget_scenes.py
(After that they're ordinary scenes; edit them in Godot if you prefer.)"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from scenegen import *

BUTTON = "res://scenes/world/poke_button.tscn"
VNC = "res://scenes/vnc/vnc_screen.tscn"
DARK = "#222222"


def button(s, name, text, pos, size, color="#3d85c6", label_size=34, parent="."):
    s.node(name, None, parent, instance=s.ext_res("PackedScene", BUTTON), transform=T(*pos),
           unique_name_in_owner="true", text=q(text), size=V2(*size), label_size=str(label_size), color=C(color))


def widget(name, script, w, h, face=None):
    s = Scene(name, "RigidBody3D", script, {"mass": "20.0", "size": V2(w, h)})
    s.box("Frame", (w + 0.05, h + 0.05, 0.03), "#2b2f3a", pos=(0, 0, -0.015), collide=True)
    if face:
        s.box("Face", (w, h, 0.004), face, pos=(0, 0, 0.002), unique=True)
    s.label("Name", "", 64, pos=(-w / 2, h / 2 + 0.065, 0.0), pixel=0.001, halign=0)
    button(s, "MenuButton", "Menu", (w / 2 - 0.055, h / 2 + 0.065, 0.005), (0.11, 0.06), "#555a66", 30)
    return s


# --- Calendar -----------------------------------------------------------------------------
w, h = 0.96, 0.92
s = widget("Calendar", "res://scripts/widgets/calendar.gd", w, h, "#f4f1ea")
button(s, "Prev", "<", (-w / 2 + 0.07, h / 2 - 0.06, 0.005), (0.09, 0.07), "#555a66", 40)
button(s, "Next", ">", (w / 2 - 0.07, h / 2 - 0.06, 0.005), (0.09, 0.07), "#555a66", 40)
s.label("Month", "", 52, pos=(0, h / 2 - 0.06, 0.006), pixel=0.001, color=DARK, outline=0)
for i, d in enumerate(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]):
    s.label("Day%d" % i, d, 30, pos=((i - 3) * 0.131, h / 2 - 0.13, 0.006), pixel=0.001, color="#666666", outline=0)
# Day cells are built in code (calendar.gd); the first row's centre is here.
s.node("Grid", "Node3D", transform=T(0, h / 2 - 0.2, 0.005), unique_name_in_owner="true")
s.label("Upcoming", "", 28, pos=(-w / 2 + 0.04, -h / 2 + 0.115, 0.006), pixel=0.001, width=(w - 0.08) / 0.001,
        color=DARK, outline=0, halign=0, valign=0)
s.save("scenes/widgets/calendar.tscn")

# --- Alarm --------------------------------------------------------------------------------
w, h = 0.56, 0.42
s = widget("Alarm", "res://scripts/widgets/alarm.gd", w, h, "#1d2230")
s.label("Clock", "", 34, pos=(0, 0.17, 0.006), pixel=0.001, color="#9aa3b5", outline=0)
s.label("Time", "07:00", 150, pos=(0, 0.07, 0.006), pixel=0.001, color="#ffffff", outline=0)
s.label("State", "", 36, pos=(0, -0.035, 0.006), pixel=0.001, color="#f2d06b", outline=0)
for name, text, x in [("HourDown", "-1h", -0.195), ("HourUp", "+1h", -0.065), ("MinDown", "-5m", 0.065), ("MinUp", "+5m", 0.195)]:
    button(s, name, text, (x, -0.1, 0.005), (0.1, 0.06))
button(s, "Toggle", "Turn on", (-0.11, -0.175, 0.005), (0.2, 0.05), "#4caf50", 32)
button(s, "Stop", "Stop", (0.11, -0.175, 0.005), (0.2, 0.05), "#e05050", 32)
s.save("scenes/widgets/alarm.tscn")

# --- Timer --------------------------------------------------------------------------------
w, h = 0.56, 0.42
s = widget("Timer", "res://scripts/widgets/timer.gd", w, h, "#1d2230")
s.label("Time", "05:00", 150, pos=(0, 0.1, 0.006), pixel=0.001, color="#ffffff", outline=0)
s.label("State", "", 36, pos=(0, -0.0, 0.006), pixel=0.001, color="#f2d06b", outline=0)
for name, text, x in [("MinDown", "-1m", -0.195), ("MinUp", "+1m", -0.065), ("SecDown", "-10s", 0.065), ("SecUp", "+10s", 0.195)]:
    button(s, name, text, (x, -0.075, 0.005), (0.1, 0.06))
for name, text, x, col in [("Start", "Start", -0.17, "#4caf50"), ("Stop", "Stop", 0.0, "#e05050"), ("Reset", "Reset", 0.17, "#555a66")]:
    button(s, name, text, (x, -0.155, 0.005), (0.15, 0.055), col, 32)
s.save("scenes/widgets/timer.tscn")

# --- Whiteboard ---------------------------------------------------------------------------
w, h = 1.6, 0.9
s = widget("Whiteboard", "res://scripts/widgets/whiteboard_widget.gd", w, h)
# The canvas: the drawing, with the text and picture layer over it (both
# scroll together; see whiteboard_widget.gd).
s.quad("Drawing", (w, h), pos=(0, 0, 0.004))
s.quad("Layer", (w, h), pos=(0, 0, 0.005))
s.node("LayerViewport", "SubViewport", unique_name_in_owner="true", transparent_bg="true", disable_3d="true",
       render_target_update_mode="1", size="Vector2i(1024, 576)")
s.node("Words", "RichTextLabel", "LayerViewport", unique_name_in_owner="true", bbcode_enabled="true",
       scroll_active="false", autowrap_mode="3", text=q(""))
s.node("Picture", "TextureRect", "LayerViewport", unique_name_in_owner="true", expand_mode="1", stretch_mode="5")
# The brush palette (built in code) sits on this strip under the board.
s.box("PaletteBar", (w + 0.05, 0.08, 0.02), "#2b2f3a", pos=(0, -h / 2 - 0.06, -0.012), collide=True)
# Scrolling, when the text makes the canvas taller than the board.
s.box("ScrollBar", (0.08, h + 0.05, 0.02), "#2b2f3a", pos=(w / 2 + 0.065, 0, -0.012), collide=True)
button(s, "ScrollUp", "^", (w / 2 + 0.065, h / 2 - 0.05, 0.0), (0.06, 0.07), "#555a66", 40)
button(s, "ScrollDown", "v", (w / 2 + 0.065, -h / 2 + 0.05, 0.0), (0.06, 0.07), "#555a66", 40)
s.box("ScrollTrack", (0.014, h - 0.26, 0.004), "#555a66", pos=(w / 2 + 0.065, 0, 0.001), unique=True)
s.box("ScrollThumb", (0.03, 0.1, 0.008), "#f2d06b", pos=(w / 2 + 0.065, 0, 0.005), unique=True)
s.save("scenes/widgets/whiteboard.tscn")

# --- Practice board (tutorial) ---------------------------------------------------------------
w, h = 1.0, 0.8
s = widget("Practice", "res://scripts/widgets/practice.gd", w, h, "#1d2230")
s.label("Score", "", 40, pos=(0, h / 2 - 0.06, 0.006), pixel=0.001, color="#f2d06b", outline=0)
button(s, "Reset", "Reset", (-0.3, -h / 2 + 0.07, 0.005), (0.2, 0.07), "#555a66", 34)
button(s, "TryKeyboard", "Try the keyboard", (0.2, -h / 2 + 0.07, 0.005), (0.4, 0.07), "#7b68ee", 34)
s.label("Typed", "", 30, pos=(0, -h / 2 + 0.16, 0.006), pixel=0.001, color="#ffffff", outline=0, width=(w - 0.1) / 0.001)
s.save("scenes/widgets/practice.tscn")

# --- TV -----------------------------------------------------------------------------------
w, h = 1.6, 0.95
s = widget("TV", "res://scripts/widgets/tv.gd", w, h, "#050505")
button(s, "KeyboardButton", "Keyboard", (w / 2 - 0.2, h / 2 + 0.065, 0.005), (0.16, 0.06), "#4caf50", 30)
s.node("Screen", None, ".", instance=s.ext_res("PackedScene", VNC), transform=T(0, 0, 0.006), unique_name_in_owner="true")
s.save("scenes/widgets/tv.tscn")

# --- Monitor (desk prop) ------------------------------------------------------------------------
s = Scene("Monitor", "RigidBody3D", "res://scripts/entities/monitor.gd", {"mass": "4.0"})
s.box("Base", (0.22, 0.015, 0.16), "#2b2f3a", pos=(0, 0.0075, 0), collide=True)
s.box("Neck", (0.04, 0.26, 0.03), "#2b2f3a", pos=(0, 0.14, -0.04))
s.box("Panel", (0.62, 0.38, 0.03), "#15171c", pos=(0, 0.42, -0.02), collide=True)
s.node("Screen", None, ".", instance=s.ext_res("PackedScene", VNC), transform=T(0, 0.42, -0.004),
       unique_name_in_owner="true", screen_size=V2(0.58, 0.34))
# Shows/hides a live keyboard for the connected computer.
button(s, "KeyboardButton", "Keyboard", (0.22, 0.2, 0.0), (0.14, 0.04), "#4caf50", 26)
# Where a hand holds it (context menu → Grab): by the stand.
s.node("GrabPoint", "Marker3D", transform=T(0, 0.14, -0.04))
s.save("scenes/entities/props/monitor.tscn")

# --- Floating screen (no physics; hangs where you put it) --------------------------------------
s = Scene("FloatingScreen", "RigidBody3D", "res://scripts/entities/floating_screen.gd", {"mass": "2.0", "gravity_scale": "0.0"})
s.box("Bezel", (0.9, 0.56, 0.025), "#2b2f3a", collide=True)
s.node("Screen", None, ".", instance=s.ext_res("PackedScene", VNC), transform=T(0, 0, 0.0135),
       unique_name_in_owner="true", screen_size=V2(0.86, 0.52))
button(s, "KeyboardButton", "Keyboard", (0.33, -0.31, 0.0), (0.18, 0.05), "#4caf50", 30)
# Held by its bottom edge, screen facing the palm's way.
s.node("GrabPoint", "Marker3D", transform=T(0, -0.28, 0))
s.save("scenes/entities/floating_screen.tscn")

# --- Drawers (furniture) ----------------------------------------------------------------------
s = Scene("Drawers", "RigidBody3D", "res://scripts/entities/drawer.gd", {"mass": "30.0"})
s.box("Cabinet", (0.5, 0.72, 0.5), "#8a6f55", collide=True)
for i, y in enumerate([0.0, -0.22]):
    s.box("Front%d" % (i + 2), (0.46, 0.2, 0.02), "#a4876a", pos=(0, y, 0.26))
    s.box("Pull%d" % (i + 2), (0.14, 0.02, 0.02), "#c0c4c8", pos=(0, y + 0.04, 0.28))
s.node("Drawer", "Node3D", unique_name_in_owner="true")
s.box("Front", (0.46, 0.2, 0.03), "#b08f70", parent="Drawer", pos=(0, 0.22, 0.265))
s.box("Bar", (0.18, 0.025, 0.03), "#d0d4d8", parent="Drawer", pos=(0, 0.25, 0.3))
s.box("Bottom", (0.44, 0.015, 0.44), "#8a6f55", parent="Drawer", pos=(0, 0.13, 0.03))
s.box("SideL", (0.015, 0.14, 0.44), "#8a6f55", parent="Drawer", pos=(-0.215, 0.2, 0.03))
s.box("SideR", (0.015, 0.14, 0.44), "#8a6f55", parent="Drawer", pos=(0.215, 0.2, 0.03))
s.box("Back", (0.44, 0.14, 0.015), "#8a6f55", parent="Drawer", pos=(0, 0.2, -0.19))
s.node("Handle", "Area3D", "Drawer", transform=T(0, 0.23, 0.3), unique_name_in_owner="true",
       script=s.ext_res("Script", "res://scripts/world/grab_handle.gd"))
s.node("Shape", "CollisionShape3D", "Drawer/Handle", shape=s.sub("BoxShape3D", size=V3(0.26, 0.12, 0.14)))
s.label("FolderLabel", "", 22, parent="Drawer", pos=(0, 0.185, 0.281), pixel=0.001, width=440, color="#2b2118", outline=0)
s.node("GrabPoint", "Marker3D", transform=T(0, 0.36, 0.25))
s.save("scenes/entities/props/drawer.tscn")

# --- VNC screen (shared by TVs and monitors) -------------------------------------------------
s = Scene("VncScreen", "Node3D", "res://scripts/vnc/vnc_screen.gd")
s.node("Picture", "MeshInstance3D", transform=T(0, 0, 0.001), unique_name_in_owner="true")
s.label("Status", "", 44, pos=(0, 0, 0.003), pixel=0.001, color="#c8ccd4", outline=0)
s.save("scenes/vnc/vnc_screen.tscn")

# --- Scrolling text panel (documents, clipboards) ------------------------------------------------
s = Scene("ScrollText", "Node3D", "res://scripts/ui/scroll_text.gd")
s.node("Viewport", "SubViewport", unique_name_in_owner="true", transparent_bg="true", disable_3d="true",
       render_target_update_mode="1", size="Vector2i(320, 320)")
s.node("Background", "ColorRect", "Viewport", unique_name_in_owner="true")
s.node("Scroll", "ScrollContainer", "Viewport", unique_name_in_owner="true")
s.node("Text", "Label", "Viewport/Scroll", unique_name_in_owner="true", text=q(""))
s.node("Quad", "MeshInstance3D", unique_name_in_owner="true", mesh=s.sub("QuadMesh", size=V2(0.2, 0.2)))
for name, text in [("Up", "^"), ("Down", "v"), ("Left", "<"), ("Right", ">")]:
    button(s, name, text, (0, 0, 0), (0.026, 0.026), "#555a66", 22)
s.save("scenes/ui/scroll_text.tscn")
