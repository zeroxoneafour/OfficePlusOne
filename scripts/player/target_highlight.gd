class_name TargetHighlight extends Node
## Outlines whatever you're currently targeting (pointer ray or desktop
## crosshair) — objects, seats, widgets, AIs and people, never walls/floor/ceiling —
## whether or not the ray itself is visible. Local only. Toggle: watch → Me.

const OUTLINE := preload("res://shaders/outline.gdshader")
## Pointer target types that get outlined.
const TYPES := ["object", "seat", "agent", "player", "widget"]

var enabled := true:
	set(v):
		enabled = v
		_apply(_node, v)
var _node: Node3D
var _material: ShaderMaterial


func _init() -> void:
	_material = ShaderMaterial.new()
	_material.shader = OUTLINE


## Outline the node a Pointer target refers to (or nothing).
func show_target(target: Dictionary) -> void:
	set_node(node_for(target))


static func node_for(target: Dictionary) -> Node3D:
	match target.get("type"):
		"object", "seat", "agent", "widget":
			return Sync.entities.get(int(target.get("entity_id", 0)))
		"player":
			return Sync.avatars.get(int(target.get("peer", 0)))
	return null


func set_node(node: Node3D) -> void:
	if is_instance_valid(_node) and node == _node:
		return
	_apply(_node, false)
	_node = node
	_apply(node, enabled)


func current() -> Node3D:
	return _node if is_instance_valid(_node) else null


## (Untyped: the node may have been deleted since it was outlined.)
func _apply(node: Variant, on: bool) -> void:
	if not is_instance_valid(node):
		return
	for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		if mi.name.begins_with("Ray"):
			continue # an avatar's pointer beams
		mi.material_overlay = _material if on else null
