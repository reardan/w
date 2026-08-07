/*
graphics.ui.render: the one batching renderer every widget draws
through (docs/projects/ui_framework.md §3 — one GL renderer, all
backends). Immediate-mode: each frame accumulates textured-quad
vertices into a caller-owned ui_renderer and uploads them once in
ui_render_end via glBufferData + GL_DYNAMIC_DRAW (the per-frame
orphaning idiom; no glBufferSubData needed).

Vertex layout: x, y, u, v, r, g, b, a — 8 float32s, 32 bytes. One
shader draws both text and solid fills: glyphs sample the R8 atlas's
coverage in .r, solid rects sample the atlas's solid-white cell, so
the fragment path never branches. Pixel-space y-down coordinates via
mat4_ortho(0, w, h, 0, ...), matching mouse coordinates.

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


# Max vertices per frame: 682 quads, far beyond a stage-1 form. Pushes
# past the cap are dropped.
int ui_render_max_verts():
	return 4096


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
	float32* verts
	int vert_count
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
	r.verts = cast(float32*, malloc(ui_render_max_verts() * 32))
	r.vert_count = 0
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
	# 2- and 8-byte-wide R8 rows are not 4-aligned.
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
	glGenTextures(1, &r.atlas_tex)
	glActiveTexture(GL_TEXTURE0)
	glBindTexture(GL_TEXTURE_2D, r.atlas_tex)
	glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, ui_font_atlas_w(), ui_font_atlas_h(), 0, GL_RED, GL_UNSIGNED_BYTE, pixels)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
	free(pixels)
	glUniform1i(r.u_tex, 0)

	r.gl_ready = 1
	return 1


# Start a frame: reset the batch, set the pixel-space projection for
# the current window size.
void ui_render_begin(ui_renderer* r, int width, int height):
	r.vert_count = 0
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


void ui_render_vertex(ui_renderer* r, float32 x, float32 y, float32 u, float32 v, ui_color color):
	if (r.vert_count >= ui_render_max_verts()):
		return
	float32* p = &r.verts[r.vert_count * 8]
	p[0] = x
	p[1] = y
	p[2] = u
	p[3] = v
	p[4] = color.r
	p[5] = color.g
	p[6] = color.b
	p[7] = color.a
	r.vert_count = r.vert_count + 1


# Two triangles covering rect, sampling the atlas region u0,v0..u1,v1.
void ui_render_quad(ui_renderer* r, ui_rect rect, float32 u0, float32 v0, float32 u1, float32 v1, ui_color color):
	float32 x1 = rect.x + rect.w
	float32 y1 = rect.y + rect.h
	ui_render_vertex(r, rect.x, rect.y, u0, v0, color)
	ui_render_vertex(r, x1, rect.y, u1, v0, color)
	ui_render_vertex(r, x1, y1, u1, v1, color)
	ui_render_vertex(r, rect.x, rect.y, u0, v0, color)
	ui_render_vertex(r, x1, y1, u1, v1, color)
	ui_render_vertex(r, rect.x, y1, u0, v1, color)


# Solid fill: sample the center of the atlas's solid-white cell.
void ui_render_rect(ui_renderer* r, ui_rect rect, ui_color color):
	float32 u = (cast(float32, (ui_font_white_cell() % ui_font_atlas_cols()) * 8) + 4.0) / cast(float32, ui_font_atlas_w())
	float32 v = (cast(float32, (ui_font_white_cell() / ui_font_atlas_cols()) * 8) + 4.0) / cast(float32, ui_font_atlas_h())
	ui_render_quad(r, rect, u, v, u, v, color)


# One glyph quad at pixel position x,y, cell-aligned in the atlas.
# Atlas rows and screen y both run top-down, so v maps directly.
void ui_render_glyph(ui_renderer* r, float32 x, float32 y, int ch, int scale, ui_color color):
	int cell = ch - ui_font_first_char()
	if ((cell < 0) || (cell >= ui_font_char_count())):
		cell = 0
	int cell_x = (cell % ui_font_atlas_cols()) * 8
	int cell_y = (cell / ui_font_atlas_cols()) * 8
	float32 u0 = cast(float32, cell_x) / cast(float32, ui_font_atlas_w())
	float32 v0 = cast(float32, cell_y) / cast(float32, ui_font_atlas_h())
	float32 u1 = cast(float32, cell_x + 8) / cast(float32, ui_font_atlas_w())
	float32 v1 = cast(float32, cell_y + 8) / cast(float32, ui_font_atlas_h())
	float32 size = cast(float32, 8 * scale)
	ui_render_quad(r, ui_rect_new(x, y, size, size), u0, v0, u1, v1, color)


# End a frame: upload the batch once and draw it.
void ui_render_end(ui_renderer* r):
	if ((r.gl_ready == 0) || (r.vert_count == 0)):
		return
	glBindBuffer(GL_ARRAY_BUFFER, r.vbuf)
	glBufferData(GL_ARRAY_BUFFER, r.vert_count * 32, r.verts, GL_DYNAMIC_DRAW)
	glEnableVertexAttribArray(r.a_pos)
	glVertexAttribPointer(r.a_pos, 2, GL_FLOAT, 0, 32, 0)
	glEnableVertexAttribArray(r.a_uv)
	glVertexAttribPointer(r.a_uv, 2, GL_FLOAT, 0, 32, 8)
	glEnableVertexAttribArray(r.a_color)
	glVertexAttribPointer(r.a_color, 4, GL_FLOAT, 0, 32, 16)
	glDrawArrays(GL_TRIANGLES, 0, r.vert_count)


void ui_render_destroy(ui_renderer* r):
	free(cast(char*, r.verts))
	r.verts = 0
	r.vert_count = 0
