extends RefCounted
## Entity kind -> scene. Every scene's root is a NetBody subclass.

const SCENES := {
	"agent": preload("res://scenes/entities/agent.tscn"),
	"document": preload("res://scenes/entities/document.tscn"),
	"clipboard": preload("res://scenes/entities/clipboard.tscn"),
	"chair": preload("res://scenes/entities/props/chair.tscn"),
	"table": preload("res://scenes/entities/props/table.tscn"),
	"plant": preload("res://scenes/entities/props/plant.tscn"),
	"lamp": preload("res://scenes/entities/props/lamp.tscn"),
	"monitor": preload("res://scenes/entities/props/monitor.tscn"),
	"drawer": preload("res://scenes/entities/props/drawer.tscn"),
	"floating_screen": preload("res://scenes/entities/floating_screen.tscn"),
	# Wall widgets (see the Widgets autoload).
	"calendar": preload("res://scenes/widgets/calendar.tscn"),
	"alarm": preload("res://scenes/widgets/alarm.tscn"),
	"timer": preload("res://scenes/widgets/timer.tscn"),
	"whiteboard": preload("res://scenes/widgets/whiteboard.tscn"),
	"tv": preload("res://scenes/widgets/tv.tscn"),
	"practice": preload("res://scenes/widgets/practice.tscn"),
}


static func create(kind: String) -> NetBody:
	var scene: PackedScene = SCENES.get(kind, SCENES["table"])
	return scene.instantiate()
