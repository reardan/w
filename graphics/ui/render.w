/*
graphics.ui.render: the one batching renderer every widget draws
through (docs/projects/ui_framework.md §3 — one GL renderer, all
backends). Immediate-mode: each frame accumulates textured-quad
vertices into a caller-owned ui_renderer and uploads them once in
ui_render_end via glBufferData + GL_DYNAMIC_DRAW (the per-frame
orphaning idiom; no glBufferSubData needed).

Vertex layout: x, y, u, v, r, g, b, a — 8 float32s, 32 bytes. One
shader draws text, solid fills and every shape: glyphs and the baked
AA masks sample the R8 atlas's coverage in .r, solid rects sample the
solid-white mask's center, so the fragment path never branches.
Rounded rects, discs, rings, the checkmark/chevron and the shadow
9-patch are all mask quads (graphics.ui.font documents the mask ids)
— no extra draw calls, no shader changes. The atlas samples LINEAR:
masks scale smoothly and glyphs draw 1:1 at integer pens, where
LINEAR lands exactly on texel centers and stays crisp.

Pixel-space y-down coordinates via mat4_ortho(0, w, h, 0, ...),
matching mouse coordinates.

ui_render_init_headless builds only the CPU batch state — unit tests
assert on the accumulated vertices with no GL context or display.
*/
import lib.lib
import graphics.math
import graphics.gl
import graphics.window
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font


# Initial vertices per frame: 1365 quads. A batch that fills up doubles
# through realloc rather than dropping geometry — a scrolled list or an
# edit surface can exceed any fixed cap, and silently losing its tail is
# the wrong failure mode for content the user is looking at.
int ui_render_max_verts():
	return 8192


# Initial vertices for the two overlay layers: popup geometry is a
# small fraction of a frame's, and these batches double on demand like
# the base one.
int ui_render_overlay_verts():
	return 1024


# Clip-stack depth, per layer. Deep enough for a scroll region inside a
# table inside a modal, with room to spare; pushes past it are dropped
# rather than growing the renderer struct without bound.
int ui_render_clip_depth():
	return 8


# Draw layers, painted in this order by ui_render_end. One flag and one
# overlay batch could not express a popover inside a modal, or a toast
# above both — every widget that stacks needs to name where it draws
# rather than just "over" (docs/projects/ui_widgets.md §4).
enum ui_layer:
	UI_LAYER_BASE = 0
	UI_LAYER_POPUP = 1
	UI_LAYER_TOP = 2


int ui_render_layer_count():
	return 3


# How far ui_draw_shadow reaches outside the rect it sits behind: the
# 9-patch grows 10px and is offset 2px down. A popup's clip has to
# include this margin, or elevation would be clipped off the very
# surface it belongs to.
float32 ui_shadow_margin():
	return 12.0


struct ui_renderer:
	int gl_ready
	int program
	int32 vbuf
	int32 atlas_tex
	int u_proj
	int u_tex
	int a_pos
	int a_uv
	int a_color
	# One vertex batch per layer, each with its own count and capacity.
	# Vertices go to layer_verts[layer]; ui_render_end uploads and draws
	# them base-first.
	float32*[3] layer_verts
	int32[3] layer_vert_count
	int32[3] layer_vert_cap
	int32 layer
	# Clip rects, per layer: ui_render_clip_depth() slots each, the
	# innermost at clip_depth[layer] - 1, depth 0 meaning unclipped. Per
	# layer so entering a popup layer starts from a clean clip — a
	# dropdown opened inside a scrolled region must not be trimmed by
	# that region's viewport.
	#
	# ui_render_quad trims geometry against the top of this stack, which
	# is what lets anything scroll or mask. Kept on the CPU rather than
	# in glScissor: scissoring would split the one-glBufferData-per-batch
	# upload into a draw-call list, and does nothing under
	# ui_render_init_headless, the GL-free seam the widget tests are
	# built on (docs/projects/ui_widgets.md §4).
	ui_rect[24] clip_stack
	int32[3] clip_depth
	int32 vp_w
	int32 vp_h


# CPU-only init: the vertex batch works, every GL call is skipped
# (gl_ready stays 0). The seam headless unit tests build on.
void ui_render_init_headless(ui_renderer* r):
	r.gl_ready = 0
	r.program = 0
	r.vbuf = 0
	r.atlas_tex = 0
	r.u_proj = 0
	r.u_tex = 0
	r.a_pos = 0
	r.a_uv = 0
	r.a_color = 0
	r.layer_verts[UI_LAYER_BASE] = cast(float32*, malloc(ui_render_max_verts() * 32))
	r.layer_vert_cap[UI_LAYER_BASE] = ui_render_max_verts()
	int i = UI_LAYER_POPUP
	while (i < ui_render_layer_count()):
		r.layer_verts[i] = cast(float32*, malloc(ui_render_overlay_verts() * 32))
		r.layer_vert_cap[i] = ui_render_overlay_verts()
		i = i + 1
	i = 0
	while (i < ui_render_layer_count()):
		r.layer_vert_count[i] = 0
		r.clip_depth[i] = 0
		i = i + 1
	r.layer = UI_LAYER_BASE
	r.vp_w = 0
	r.vp_h = 0


# Full init: shader program, vertex buffer, glyph-atlas upload.
# Requires a current GL context (an opened gfx_window). Returns 1, or
# 0 after printing the failure to stderr.
int ui_render_init(ui_renderer* r):
	ui_render_init_headless(r)

	# Bodies compile as GLSL 130 (GLX), 150 (Mac core) and 300 es
	# (WebGL2); the backend's gfx_shader_header supplies "#version".
	char* vertex_source = strjoin(gfx_shader_header(), c"in vec2 a_pos;\nin vec2 a_uv;\nin vec4 a_color;\nout vec2 v_uv;\nout vec4 v_color;\nuniform mat4 u_proj;\nvoid main() {\n\tv_uv = a_uv;\n\tv_color = a_color;\n\tgl_Position = u_proj * vec4(a_pos, 0.0, 1.0);\n}\n")
	char* fragment_source = strjoin(gfx_shader_header(), c"in vec2 v_uv;\nin vec4 v_color;\nout vec4 frag_color;\nuniform sampler2D u_tex;\nvoid main() {\n\tfrag_color = vec4(v_color.rgb, v_color.a * texture(u_tex, v_uv).r);\n}\n")
	r.program = gl_create_program(vertex_source, fragment_source)
	if (r.program == 0):
		print_error(c"graphics.ui: renderer shader build failed\n")
		return 0
	glUseProgram(r.program)
	r.u_proj = glGetUniformLocation(r.program, c"u_proj")
	r.u_tex = glGetUniformLocation(r.program, c"u_tex")
	r.a_pos = glGetAttribLocation(r.program, c"a_pos")
	r.a_uv = glGetAttribLocation(r.program, c"a_uv")
	r.a_color = glGetAttribLocation(r.program, c"a_color")

	glGenBuffers(1, &r.vbuf)

	char* pixels = ui_font_build_atlas()
	# 2- and odd-width R8 rows are not 4-aligned.
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
	glGenTextures(1, &r.atlas_tex)
	glActiveTexture(GL_TEXTURE0)
	glBindTexture(GL_TEXTURE_2D, r.atlas_tex)
	glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, ui_font_atlas_w(), ui_font_atlas_h(), 0, GL_RED, GL_UNSIGNED_BYTE, pixels)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
	free(pixels)
	glUniform1i(r.u_tex, 0)

	r.gl_ready = 1
	return 1


# Start a frame: reset the batch, set the pixel-space projection for
# the current window size.
void ui_render_begin(ui_renderer* r, int width, int height):
	int i = 0
	while (i < ui_render_layer_count()):
		r.layer_vert_count[i] = 0
		r.clip_depth[i] = 0
		i = i + 1
	r.layer = UI_LAYER_BASE
	r.vp_w = width
	r.vp_h = height
	if (r.gl_ready == 0):
		return
	glUseProgram(r.program)
	glDisable(GL_DEPTH_TEST)
	glEnable(GL_BLEND)
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
	# y-down pixel space: top = 0, bottom = height, matching mouse
	# coordinates on every backend.
	mat4 proj = mat4_ortho(0.0, cast(float32, width), cast(float32, height), 0.0, 0.0 - 1.0, 1.0)
	glUniformMatrix4fv(r.u_proj, 1, 0, &proj.m[0])


# Route subsequent geometry to a layer. Out-of-range layers are
# ignored rather than corrupting the batch pointers.
void ui_render_layer(ui_renderer* r, int layer):
	if ((layer < 0) || (layer >= ui_render_layer_count())):
		return
	r.layer = layer


# The clip rect in force on the current layer, or the whole viewport
# when that layer's stack is empty. Nothing outside it reaches the batch.
ui_rect ui_clip_current(ui_renderer* r):
	int depth = r.clip_depth[r.layer]
	if (depth == 0):
		return ui_rect_new(0.0, 0.0, cast(float32, r.vp_w), cast(float32, r.vp_h))
	return r.clip_stack[r.layer * 8 + depth - 1]


# Narrow the current layer's clip to rect. Always intersects with the
# clip already in force, so a region can never draw outside its parent.
# A push past ui_render_clip_depth is dropped; a pop at depth 0 is a
# no-op, so a dropped push and its matching pop still balance.
void ui_clip_push(ui_renderer* r, ui_rect rect):
	int depth = r.clip_depth[r.layer]
	if (depth >= ui_render_clip_depth()):
		return
	r.clip_stack[r.layer * 8 + depth] = ui_rect_intersect(ui_clip_current(r), rect)
	r.clip_depth[r.layer] = depth + 1


void ui_clip_pop(ui_renderer* r):
	int depth = r.clip_depth[r.layer]
	if (depth == 0):
		return
	r.clip_depth[r.layer] = depth - 1


# Double a batch that has filled up. Returns the (possibly moved) base
# pointer; a failed grow returns the old one and the caller drops the
# vertex, so overflow degrades to the old drop-on-full behavior instead
# of writing past the end.
float32* ui_render_grow(float32* batch, int cap, int32* new_cap):
	int next = cap * 2
	float32* moved = cast(float32*, realloc(cast(char*, batch), cap * 32, next * 32))
	if (moved == 0):
		new_cap[0] = cap
		return batch
	new_cap[0] = next
	return moved


void ui_render_vertex(ui_renderer* r, float32 x, float32 y, float32 u, float32 v, ui_color color):
	int layer = r.layer
	float32* batch = r.layer_verts[layer]
	int count = r.layer_vert_count[layer]
	int cap = r.layer_vert_cap[layer]
	if (count >= cap):
		int32 grown = 0
		batch = ui_render_grow(batch, cap, &grown)
		if (grown == cap):
			return
		r.layer_verts[layer] = batch
		r.layer_vert_cap[layer] = grown
	float32* p = &batch[count * 8]
	p[0] = x
	p[1] = y
	p[2] = u
	p[3] = v
	p[4] = color.r
	p[5] = color.g
	p[6] = color.b
	p[7] = color.a
	r.layer_vert_count[layer] = count + 1


# Two triangles covering rect, sampling the atlas region u0,v0..u1,v1
# (u0 > u1 or v0 > v1 mirrors — the mask primitives lean on that).
#
# With a clip in force the rect is trimmed and the UVs are lerped by the
# same fractions, so the visible part samples exactly the texels it
# would have: mirrored ranges follow, since the lerp is on the range as
# given. A fully clipped quad emits nothing. With an empty clip stack
# the geometry passes through untouched — the viewport is not a clip
# (the GPU already bounds it), and treating it as one would drop the
# zero-extent fills that pill-shaped rrects legitimately emit.
void ui_render_quad(ui_renderer* r, ui_rect rect, float32 u0, float32 v0, float32 u1, float32 v1, ui_color color):
	if (r.clip_depth[r.layer] > 0):
		ui_rect clip = ui_clip_current(r)
		ui_rect vis = ui_rect_intersect(rect, clip)
		if (ui_rect_is_empty(vis)):
			return
		if ((rect.w > 0.0) && (rect.h > 0.0)):
			float32 fu0 = (vis.x - rect.x) / rect.w
			float32 fu1 = (vis.x + vis.w - rect.x) / rect.w
			float32 fv0 = (vis.y - rect.y) / rect.h
			float32 fv1 = (vis.y + vis.h - rect.y) / rect.h
			float32 du = u1 - u0
			float32 dv = v1 - v0
			u1 = u0 + du * fu1
			u0 = u0 + du * fu0
			v1 = v0 + dv * fv1
			v0 = v0 + dv * fv0
		rect = vis
	float32 x1 = rect.x + rect.w
	float32 y1 = rect.y + rect.h
	ui_render_vertex(r, rect.x, rect.y, u0, v0, color)
	ui_render_vertex(r, x1, rect.y, u1, v0, color)
	ui_render_vertex(r, x1, y1, u1, v1, color)
	ui_render_vertex(r, rect.x, rect.y, u0, v0, color)
	ui_render_vertex(r, x1, y1, u1, v1, color)
	ui_render_vertex(r, rect.x, y1, u0, v1, color)


# The atlas-space UV of a glyph/mask rect edge.
float32 ui_render_u(int x):
	return cast(float32, x) / cast(float32, ui_font_atlas_w())


float32 ui_render_v(int y):
	return cast(float32, y) / cast(float32, ui_font_atlas_h())


# Solid fill: sample the center of the solid-white mask.
void ui_render_rect(ui_renderer* r, ui_rect rect, ui_color color):
	ui_glyph m = ui_font_mask(ui_mask_white())
	float32 u = ui_render_u(m.x * 2 + m.w) * 0.5
	float32 v = ui_render_v(m.y * 2 + m.h) * 0.5
	ui_render_quad(r, rect, u, v, u, v, color)


# One mask stretched over rect; flip_x/flip_y mirror the sample.
void ui_render_mask(ui_renderer* r, ui_rect rect, int mask, int flip_x, int flip_y, ui_color color):
	ui_glyph m = ui_font_mask(mask)
	float32 u0 = ui_render_u(m.x)
	float32 u1 = ui_render_u(m.x + m.w)
	float32 v0 = ui_render_v(m.y)
	float32 v1 = ui_render_v(m.y + m.h)
	if (flip_x):
		float32 tu = u0
		u0 = u1
		u1 = tu
	if (flip_y):
		float32 tv = v0
		v0 = v1
		v1 = tv
	ui_render_quad(r, rect, u0, v0, u1, v1, color)


# One glyph at pen x with the line box's top at y_top; returns the pen
# advance. Inkless glyphs (space) advance without pushing a quad.
int ui_render_glyph(ui_renderer* r, float32 x, float32 y_top, int ch, int scale, ui_color color):
	int strike = ui_font_strike_from_scale(scale)
	ui_glyph g = ui_font_glyph(strike, ch)
	if (g.w > 0):
		float32 gx = x + cast(float32, g.bearing_x)
		float32 gy = y_top + cast(float32, ui_font_ascent(strike) - g.bearing_top)
		float32 u0 = ui_render_u(g.x)
		float32 v0 = ui_render_v(g.y)
		float32 u1 = ui_render_u(g.x + g.w)
		float32 v1 = ui_render_v(g.y + g.h)
		ui_render_quad(r, ui_rect_new(gx, gy, cast(float32, g.w), cast(float32, g.h)), u0, v0, u1, v1, color)
	return g.advance


# Rounded rect: four mirrored corner-mask quads plus three fills.
# radius clamps to half the shorter side; radius 0 is a plain rect.
void ui_draw_rrect(ui_renderer* r, ui_rect rect, float32 radius, ui_color color):
	float32 half = rect.w * 0.5
	if (rect.h * 0.5 < half):
		half = rect.h * 0.5
	if (radius > half):
		radius = half
	if (radius < 1.0):
		ui_render_rect(r, rect, color)
		return
	float32 x1 = rect.x + rect.w
	float32 y1 = rect.y + rect.h
	ui_render_mask(r, ui_rect_new(rect.x, rect.y, radius, radius), ui_mask_corner(), 0, 0, color)
	ui_render_mask(r, ui_rect_new(x1 - radius, rect.y, radius, radius), ui_mask_corner(), 1, 0, color)
	ui_render_mask(r, ui_rect_new(rect.x, y1 - radius, radius, radius), ui_mask_corner(), 0, 1, color)
	ui_render_mask(r, ui_rect_new(x1 - radius, y1 - radius, radius, radius), ui_mask_corner(), 1, 1, color)
	ui_render_rect(r, ui_rect_new(rect.x + radius, rect.y, rect.w - radius * 2.0, rect.h), color)
	ui_render_rect(r, ui_rect_new(rect.x, rect.y + radius, radius, rect.h - radius * 2.0), color)
	ui_render_rect(r, ui_rect_new(x1 - radius, rect.y + radius, radius, rect.h - radius * 2.0), color)


void ui_draw_disc(ui_renderer* r, ui_rect rect, ui_color color):
	ui_render_mask(r, rect, ui_mask_disc(), 0, 0, color)


void ui_draw_ring(ui_renderer* r, ui_rect rect, ui_color color):
	ui_render_mask(r, rect, ui_mask_ring(), 0, 0, color)


void ui_draw_check(ui_renderer* r, ui_rect rect, ui_color color):
	ui_render_mask(r, rect, ui_mask_check(), 0, 0, color)


void ui_draw_chevron(ui_renderer* r, ui_rect rect, ui_color color):
	ui_render_mask(r, rect, ui_mask_chevron(), 0, 0, color)


# The tree view's disclosure marker: right when collapsed, and the
# plain down chevron above when expanded.
void ui_draw_chevron_right(ui_renderer* r, ui_rect rect, ui_color color):
	ui_render_mask(r, rect, ui_mask_chevron_right(), 0, 0, color)


# The tab strip's close affordance.
void ui_draw_cross(ui_renderer* r, ui_rect rect, ui_color color):
	ui_render_mask(r, rect, ui_mask_cross(), 0, 0, color)


# Soft drop shadow behind rect: a 9-patch of the baked shadow corner
# tile, offset 2px down. Corners sample the whole tile; edge strips
# sample the tile's last row/column (the straight falloff profile);
# the center samples the fully-dark inner texel. 9 quads total.
void ui_draw_shadow(ui_renderer* r, ui_rect rect, ui_color color):
	ui_glyph m = ui_font_mask(ui_mask_shadow())
	float32 grow = 10.0
	ui_rect s = ui_rect_new(rect.x - grow, rect.y - grow + 2.0, rect.w + grow * 2.0, rect.h + grow * 2.0)
	float32 cs = 24.0
	if (s.w * 0.5 < cs):
		cs = s.w * 0.5
	if (s.h * 0.5 < cs):
		cs = s.h * 0.5
	float32 u0 = ui_render_u(m.x)
	float32 u1 = ui_render_u(m.x + m.w)
	float32 v0 = ui_render_v(m.y)
	float32 v1 = ui_render_v(m.y + m.h)
	# Inner sample points: the last column/row center, and the dark
	# bottom-right texel for edges and center.
	float32 uc = ui_render_u(m.x * 2 + m.w * 2 - 1) * 0.5
	float32 vc = ui_render_v(m.y * 2 + m.h * 2 - 1) * 0.5
	float32 sx1 = s.x + s.w
	float32 sy1 = s.y + s.h
	# corners
	ui_render_quad(r, ui_rect_new(s.x, s.y, cs, cs), u0, v0, u1, v1, color)
	ui_render_quad(r, ui_rect_new(sx1 - cs, s.y, cs, cs), u1, v0, u0, v1, color)
	ui_render_quad(r, ui_rect_new(s.x, sy1 - cs, cs, cs), u0, v1, u1, v0, color)
	ui_render_quad(r, ui_rect_new(sx1 - cs, sy1 - cs, cs, cs), u1, v1, u0, v0, color)
	# edges: top/bottom use the last-column profile, left/right the
	# last-row profile
	ui_render_quad(r, ui_rect_new(s.x + cs, s.y, s.w - cs * 2.0, cs), uc, v0, uc, v1, color)
	ui_render_quad(r, ui_rect_new(s.x + cs, sy1 - cs, s.w - cs * 2.0, cs), uc, v1, uc, v0, color)
	ui_render_quad(r, ui_rect_new(s.x, s.y + cs, cs, s.h - cs * 2.0), u0, vc, u1, vc, color)
	ui_render_quad(r, ui_rect_new(sx1 - cs, s.y + cs, cs, s.h - cs * 2.0), u1, vc, u0, vc, color)
	# center
	ui_render_quad(r, ui_rect_new(s.x + cs, s.y + cs, s.w - cs * 2.0, s.h - cs * 2.0), uc, vc, uc, vc, color)


void ui_render_draw_batch(ui_renderer* r, float32* batch, int count):
	if (count == 0):
		return
	glBindBuffer(GL_ARRAY_BUFFER, r.vbuf)
	glBufferData(GL_ARRAY_BUFFER, count * 32, batch, GL_DYNAMIC_DRAW)
	glEnableVertexAttribArray(r.a_pos)
	glVertexAttribPointer(r.a_pos, 2, GL_FLOAT, 0, 32, 0)
	glEnableVertexAttribArray(r.a_uv)
	glVertexAttribPointer(r.a_uv, 2, GL_FLOAT, 0, 32, 8)
	glEnableVertexAttribArray(r.a_color)
	glVertexAttribPointer(r.a_color, 4, GL_FLOAT, 0, 32, 16)
	glDrawArrays(GL_TRIANGLES, 0, count)


# End a frame: upload and draw each layer's batch in order, so popup
# geometry paints over widgets issued later in the frame and the top
# layer over both.
void ui_render_end(ui_renderer* r):
	if (r.gl_ready == 0):
		return
	int i = 0
	while (i < ui_render_layer_count()):
		ui_render_draw_batch(r, r.layer_verts[i], r.layer_vert_count[i])
		i = i + 1


void ui_render_destroy(ui_renderer* r):
	int i = 0
	while (i < ui_render_layer_count()):
		free(cast(char*, r.layer_verts[i]))
		r.layer_verts[i] = 0
		r.layer_vert_count[i] = 0
		r.layer_vert_cap[i] = 0
		i = i + 1
