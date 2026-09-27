"""Generates scenes/world/lobby.tscn: a lectern-style panel at arm's reach.
Run from the project root: python3 tools/gen_lobby.py"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from scenegen import *

BUTTON = "res://scenes/world/poke_button.tscn"
s = Scene("Lobby", "Node3D", "res://scripts/world/lobby.gd")
s.node("Floor", "StaticBody3D")
s.box("Mesh", (10, 0.2, 10), "#3a3f4b", parent="Floor", pos=(0, -0.1, 0))
s.node("MeshShape", "CollisionShape3D", "Floor", transform=T(0, -0.1, 0), shape=s.sub("BoxShape3D", size=V3(10, 0.2, 10)))
# Close enough to touch (about 45 cm ahead, waist-to-chest high), tilted up
# toward you like a lectern.
s.node("Panel", "Node3D", transform=T(0, 1.05, -0.45, rx=-35), unique_name_in_owner="true")
s.box("Backing", (0.9, 0.72, 0.02), "#2a2d34", parent="Panel", pos=(0, 0, -0.02))
s.label("Title", "Office Plus One", 60, parent="Panel", pos=(0, 0.315, 0), pixel=0.0008)
s.label("Hint", "", 22, parent="Panel", pos=(0, 0.27, 0), pixel=0.0006, width=1400)


def button(name, text, pos, size, color):
    s.node(name, None, "Panel", instance=s.ext_res("PackedScene", BUTTON), transform=T(*pos),
           unique_name_in_owner="true", text=q(text), size=V2(*size), color=C(color), label_size="26")


# The way in for newcomers: big, bright and first.
s.node("TutorialButton", None, "Panel", instance=s.ext_res("PackedScene", BUTTON), transform=T(0, 0.195, 0),
       unique_name_in_owner="true", text=q("New here? Open the tutorial"), size=V2(0.8, 0.09), color=C("#f0a020"), label_size="40")
button("Host", "Host my office", (-0.2, 0.1, 0), (0.36, 0.07), "#4caf50")
button("JoinLocal", "Join localhost", (0.2, 0.1, 0), (0.36, 0.07), "#3d85c6")
s.label("RoomsTitle", "Or open one of your saved rooms:", 24, parent="Panel", pos=(0, 0.045, 0), pixel=0.0006)
s.node("Rooms", "Node3D", "Panel", transform=T(0, 0.0, 0), unique_name_in_owner="true")
s.label("ServersTitle", "Offices on your network:", 24, parent="Panel", pos=(0, -0.145, 0), pixel=0.0006)
s.node("Servers", "Node3D", "Panel", transform=T(0, -0.2, 0), unique_name_in_owner="true")
s.label("Status", "", 24, parent="Panel", pos=(0, -0.345, 0), pixel=0.0006, color="#f2d06b")

s.save("scenes/world/lobby.tscn")
