// Target highlight: an "inverted hull" outline. Used as a material_overlay, it
// redraws the mesh slightly enlarged with front faces culled, so only a rim
// shows around the object. Vertices grow outward from the mesh's own centre
// (every part here is a primitive centred on its origin), which keeps the rim
// continuous on flat-shaded boxes, where pushing along face normals would
// leave gaps at the corners.
shader_type spatial;
render_mode unshaded, cull_front, shadows_disabled;

uniform vec4 outline_color : source_color = vec4(1.0, 0.82, 0.2, 1.0);
uniform float width = 0.018; // metres

void vertex() {
	float len = length(VERTEX);
	VERTEX += (len > 0.0001 ? VERTEX / len : NORMAL) * width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
