"""Dev helper for writing Godot 4 .tscn files (format=3) from Python.

Used to generate this project's scenes; after generation they're ordinary
scenes you can edit in the Godot editor. Example:

    import sys; sys.path.insert(0, "tools")
    from scenegen import *
    s = Scene("Thing", "Node3D", "res://scripts/thing.gd")
    s.box("Body", (0.2, 0.2, 0.2), "#3d85c6", collide=True)
    s.save("scenes/thing.tscn")
"""
import math, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def C(h, a=1.0):
    h = h.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"Color({r:.4g}, {g:.4g}, {b:.4g}, {a:g})"


def V3(x, y, z):
    return f"Vector3({x:g}, {y:g}, {z:g})"


def V2(x, y):
    return f"Vector2({x:g}, {y:g})"


def T(x=0, y=0, z=0, ry=0.0, rx=0.0):
    """Transform3D rotated rx about X then ry about Y (degrees)."""
    a, b = math.radians(rx), math.radians(ry)
    ca, sa, cb, sb = math.cos(a), math.sin(a), math.cos(b), math.sin(b)
    xc = (cb, 0, -sb)
    yc = (sb * sa, ca, cb * sa)
    zc = (sb * ca, -sa, cb * ca)
    vals = [*xc, *yc, *zc, x, y, z]
    return "Transform3D(" + ", ".join(f"{v:.6g}" if abs(v) > 1e-9 else "0" for v in vals) + ")"


class Scene:
    def __init__(self, name, type_, script=None, props=None, groups=None):
        self.ext, self.subs, self.nodes = [], [], []
        self._sub_id = 0
        # The script goes first so its exported properties apply.
        root_props = {"script": self.ext_res("Script", script)} if script else {}
        root_props.update(props or {})
        self.nodes.append((name, type_, None, root_props, groups, None))

    def ext_res(self, type_, path):
        for t, p, i in self.ext:
            if p == path:
                return f'ExtResource("{i}")'
        i = str(len(self.ext) + 1)
        self.ext.append((type_, path, i))
        return f'ExtResource("{i}")'

    def sub(self, type_, **props):
        self._sub_id += 1
        i = f"{type_}_{self._sub_id}"
        self.subs.append((type_, i, props))
        return f'SubResource("{i}")'

    def mat(self, color, emission=0.0, unshaded=False, local=False):
        p = {"albedo_color": C(color)}
        if emission:
            p.update(emission_enabled="true", emission=C(color), emission_energy_multiplier=f"{emission:g}")
        if unshaded:
            p["shading_mode"] = "0"
        if local:
            p["resource_local_to_scene"] = "true"
        return self.sub("StandardMaterial3D", **p)

    def node(self, name, type_=None, parent=".", groups=None, instance=None, **props):
        self.nodes.append((name, type_, parent, props, groups, instance))
        return name if parent == "." else f"{parent}/{name}"

    def box(self, name, size, color, parent=".", pos=(0, 0, 0), groups=None, unique=False, collide=False, emission=0.0, unshaded=False, rot=None):
        mesh = self.sub("BoxMesh", size=V3(*size), material=self.mat(color, emission, unshaded))
        props = {"transform": T(*pos, **(rot or {})), "mesh": mesh}
        if unique:
            props["unique_name_in_owner"] = "true"
        path = self.node(name, "MeshInstance3D", parent, groups, **props)
        if collide:
            self.node(name + "Shape", "CollisionShape3D", parent, transform=T(*pos, **(rot or {})), shape=self.sub("BoxShape3D", size=V3(*size)))
        return path

    def sphere(self, name, r, color, parent=".", pos=(0, 0, 0), groups=None, unique=False, collide=False, emission=0.0):
        mesh = self.sub("SphereMesh", radius=f"{r:g}", height=f"{2 * r:g}", radial_segments="16", rings="8", material=self.mat(color, emission))
        props = {"transform": T(*pos), "mesh": mesh}
        if unique:
            props["unique_name_in_owner"] = "true"
        path = self.node(name, "MeshInstance3D", parent, groups, **props)
        if collide:
            self.node(name + "Shape", "CollisionShape3D", parent, transform=T(*pos), shape=self.sub("SphereShape3D", radius=f"{r:g}"))
        return path

    def cylinder(self, name, r, h, color, parent=".", pos=(0, 0, 0), groups=None, collide=False, emission=0.0, rot=None, unique=False):
        mesh = self.sub("CylinderMesh", top_radius=f"{r:g}", bottom_radius=f"{r:g}", height=f"{h:g}", radial_segments="16", material=self.mat(color, emission))
        props = {"transform": T(*pos, **(rot or {})), "mesh": mesh}
        if unique:
            props["unique_name_in_owner"] = "true"
        path = self.node(name, "MeshInstance3D", parent, groups, **props)
        if collide:
            self.node(name + "Shape", "CollisionShape3D", parent, transform=T(*pos, **(rot or {})),
                      shape=self.sub("CylinderShape3D", radius=f"{r:g}", height=f"{h:g}"))
        return path

    def label(self, name, text, font_size, parent=".", pos=(0, 0, 0), pixel=0.001, width=0, color=None, outline=8, billboard=False, halign=None, valign=None):
        props = {"transform": T(*pos), "pixel_size": f"{pixel:g}", "text": q(text),
                 "font_size": str(font_size), "outline_size": str(outline), "unique_name_in_owner": "true"}
        if billboard:
            props["billboard"] = "1"
        if color:
            props["modulate"] = C(color)
        if width:
            props["autowrap_mode"] = "3"
            props["width"] = f"{width:g}"
        if halign is not None:
            props["horizontal_alignment"] = str(halign)
        if valign is not None:
            props["vertical_alignment"] = str(valign)
        return self.node(name, "Label3D", parent, **props)

    def quad(self, name, size, parent=".", pos=(0, 0, 0)):
        mesh = self.sub("QuadMesh", resource_local_to_scene="true", size=V2(*size))
        m = self.sub("StandardMaterial3D", resource_local_to_scene="true", shading_mode="0")
        return self.node(name, "MeshInstance3D", parent, transform=T(*pos), mesh=mesh, material_override=m, unique_name_in_owner="true")

    def save(self, rel):
        out = ["[gd_scene format=3]", ""]
        for t, p, i in self.ext:
            out.append(f'[ext_resource type="{t}" path="{p}" id="{i}"]')
        if self.ext:
            out.append("")
        for t, i, props in self.subs:
            out.append(f'[sub_resource type="{t}" id="{i}"]')
            for k, v in props.items():
                out.append(f"{k} = {v}")
            out.append("")
        for name, type_, parent, props, groups, instance in self.nodes:
            head = f'[node name="{name}"'
            if type_:
                head += f' type="{type_}"'
            if parent is not None:
                head += f' parent="{parent}"'
            if instance:
                head += f" instance={instance}"
            if groups:
                head += " groups=[" + ", ".join(q(g) for g in groups) + "]"
            out.append(head + "]")
            for k, v in props.items():
                out.append(f"{k} = {v}")
            out.append("")
        path = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("\n".join(out))
        print("wrote", rel)


def inherited(name, base_scene, script, rel):
    """A scene that instances `base_scene` with a different root script."""
    s = Scene(name, None)
    s.nodes = []
    base = s.ext_res("PackedScene", base_scene)
    s.nodes.append((name, None, None, {"script": s.ext_res("Script", script)}, None, base))
    s.save(rel)
