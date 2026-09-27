class_name ScrollText extends Node3D
## Text on a flat panel that never spills out (scenes/ui/scroll_text.tscn):
## rendered into a viewport and shown on a quad (facing +Z), with scrollbars
## when it doesn't fit, vertical and (unless it wraps) horizontal, and
## small arrow buttons beside it to scroll (poke, or point and pinch). The
## buttons only appear when there's more to see that way. Used for documents'
## contents and clipboard pages.
##
## It only re-renders when the text or the scroll position changes.

## Panel size (metres) and resolution (pixels per metre).
@export var size := Vector2(0.2, 0.2)
@export var px_per_m := 1600.0
@export var font_size := 17
@export var font_color := Color("#222222")
@export var background := Color(1, 1, 1, 0)
## Wrap lines to the panel's width (no horizontal scrolling).
@export var wrap := false

const ARROW := Vector2(0.026, 0.026)
## A scroll step, as a fraction of the visible page.
const STEP := 0.6

var _render_frames := 0


func _ready() -> void:
	var px := Vector2i(roundi(size.x * px_per_m), roundi(size.y * px_per_m))
	%Viewport.size = px
	%Scroll.size = Vector2(px)
	%Scroll.get_v_scroll_bar().custom_minimum_size.x = maxf(8.0, px.x * 0.035)
	%Scroll.get_h_scroll_bar().custom_minimum_size.y = maxf(8.0, px.x * 0.035)
	%Scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if wrap else ScrollContainer.SCROLL_MODE_AUTO
	%Background.color = background
	%Background.size = Vector2(px)
	%Text.add_theme_font_size_override("font_size", font_size)
	%Text.add_theme_color_override("font_color", font_color)
	%Text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	if wrap:
		%Text.custom_minimum_size.x = px.x - %Scroll.get_v_scroll_bar().custom_minimum_size.x - 4
	var quad := QuadMesh.new() # (its own: panels differ in size)
	quad.size = size
	%Quad.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = %Viewport.get_texture()
	%Quad.material_override = mat
	# Arrows: up/down on the right edge, left/right along the bottom.
	%Up.position = Vector3(size.x * 0.5 + ARROW.x * 0.6, size.y * 0.5 - ARROW.y * 0.5, 0)
	%Down.position = Vector3(size.x * 0.5 + ARROW.x * 0.6, -size.y * 0.5 + ARROW.y * 0.5, 0)
	%Left.position = Vector3(-size.x * 0.5 + ARROW.x * 0.5, -size.y * 0.5 - ARROW.y * 0.6, 0)
	%Right.position = Vector3(size.x * 0.5 - ARROW.x * 0.5, -size.y * 0.5 - ARROW.y * 0.6, 0)
	%Up.pressed.connect(scroll_by.bind(0.0, -STEP))
	%Down.pressed.connect(scroll_by.bind(0.0, STEP))
	%Left.pressed.connect(scroll_by.bind(-STEP, 0.0))
	%Right.pressed.connect(scroll_by.bind(STEP, 0.0))
	_refresh()


func set_text(t: String) -> void:
	if %Text.text == t:
		return
	%Text.text = t
	%Scroll.scroll_vertical = 0
	%Scroll.scroll_horizontal = 0
	_refresh()


func get_text() -> String:
	return %Text.text


## Scroll by fractions of a page (negative: up / left).
func scroll_by(pages_x: float, pages_y: float) -> void:
	%Scroll.scroll_horizontal += int(pages_x * %Viewport.size.x)
	%Scroll.scroll_vertical += int(pages_y * %Viewport.size.y)
	_refresh()


## How far there is to scroll, in pixels: (horizontal, vertical); 0 = it all fits.
func overflow() -> Vector2:
	var v := %Scroll.get_v_scroll_bar() as VScrollBar
	var h := %Scroll.get_h_scroll_bar() as HScrollBar
	return Vector2(maxf(h.max_value - h.page, 0.0), maxf(v.max_value - v.page, 0.0))


func scroll_position() -> Vector2:
	return Vector2(%Scroll.scroll_horizontal, %Scroll.scroll_vertical)


## Re-render for a couple of frames (the layout settles a frame after a change).
func _refresh() -> void:
	_render_frames = 3


func _process(_delta: float) -> void:
	if _render_frames <= 0:
		return
	_render_frames -= 1
	%Viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var over := overflow()
	var pos := scroll_position()
	_show_arrow(%Up, over.y > 0.5 and pos.y > 0.5)
	_show_arrow(%Down, over.y > 0.5 and pos.y < over.y - 0.5)
	_show_arrow(%Left, over.x > 0.5 and pos.x > 0.5)
	_show_arrow(%Right, over.x > 0.5 and pos.x < over.x - 0.5)


static func _show_arrow(b: PokeButton, on: bool) -> void:
	if b.visible != on:
		b.visible = on
		b.set_deferred("monitoring", on)
		b.set_deferred("collision_layer", PokeButton.LAYER_BUTTONS if on else 0)
