"""Generates the cartoon character parts: scenes/characters/mii_head.tscn.
Run from the project root: python3 tools/gen_characters.py"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from scenegen import *

s = Scene("MiiHead", "Node3D", "res://scripts/characters/mii_head.gd")
# A slightly tall, round head (faces -Z).
s.node("Face", "MeshInstance3D", groups=["skin"], transform="Transform3D(1, 0, 0, 0, 1.1, 0, 0, 0, 1, 0, 0, 0)",
       mesh=s.sub("SphereMesh", radius="0.12", height="0.24", radial_segments="32", rings="16"))
# Hair: a cap over the top and back.
s.node("Hair", "MeshInstance3D", groups=["hair"], transform="Transform3D(1.06, 0, 0, 0, 0.9, 0, 0, 0, 1.08, 0, 0.035, 0.012)",
       mesh=s.sub("SphereMesh", radius="0.12", height="0.12", is_hemisphere="true", radial_segments="32", rings="10"))
s.node("Fringe", "MeshInstance3D", groups=["hair"], transform="Transform3D(1.25, 0, 0, 0, 0.3, 0.2, 0, -0.25, 0.55, 0.01, 0.085, -0.07)",
       mesh=s.sub("SphereMesh", radius="0.08", height="0.16", radial_segments="24", rings="12"))
for side, x in [("L", -0.043), ("R", 0.043)]:
    s.node("Eye" + side, "MeshInstance3D", groups=["eye_white"], transform=T(x, 0.02, -0.103), unique_name_in_owner="true",
           mesh=s.sub("SphereMesh", radius="0.02", height="0.034", radial_segments="16", rings="8"))
    s.node("Pupil" + side, "MeshInstance3D", "Eye" + side, groups=["pupil"], transform=T(0, 0, -0.014), unique_name_in_owner="true",
           mesh=s.sub("SphereMesh", radius="0.011", height="0.018", radial_segments="12", rings="6"))
    s.node("Brow" + side, "MeshInstance3D", transform=T(x, 0.068, -0.108), unique_name_in_owner="true",
           mesh=s.sub("BoxMesh", size=V3(0.036, 0.007, 0.008)))
    s.node("Cheek" + side, "MeshInstance3D", groups=["cheek"], transform=T(x * 1.65, -0.03, -0.098, rx=90),
           mesh=s.sub("CylinderMesh", top_radius="0.016", bottom_radius="0.016", height="0.002", radial_segments="16"))
s.node("Nose", "MeshInstance3D", groups=["skin"], transform=T(0, -0.012, -0.123),
       mesh=s.sub("SphereMesh", radius="0.013", height="0.022", radial_segments="12", rings="6"))
# Mouth: scaled by the script (x = width, y = how open); the capsule lies sideways.
s.node("Mouth", "Node3D", transform=T(0, -0.052, -0.11), unique_name_in_owner="true")
s.node("MouthShape", "MeshInstance3D", "Mouth", groups=["mouth"], transform="Transform3D(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 0, 0)",
       mesh=s.sub("CapsuleMesh", radius="0.006", height="0.045", radial_segments="12", rings="4"))
s.save("scenes/characters/mii_head.tscn")
