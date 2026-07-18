/*
Spinning-triangle demo for the wasm/WebGL backend — graphics/demo.w
restructured for the browser's inverted control flow (see
graphics/window_web.w): main does the one-time setup and registers
demo_frame, which the host then calls once per animation frame.

Browser: compile and serve the tools/web/ page —

	./bin/wv2 wasm graphics/demo_web.w -o bin/graphics_demo.wasm
	python3 -m http.server -d . 8000   # open /tools/web/?module=/bin/graphics_demo.wasm

Headless: the same module runs under the recording fake-GL host,
which is how wasm_webgl_test exercises it:

	node tools/web/run_webgl_stub.mjs bin/graphics_demo.wasm --frames 3

--frames N makes demo_frame return 0 (stop) after N frames, for
unattended runs; without it the demo spins until the page goes away.
*/
import lib.lib
import lib.args
import graphics.math
import graphics.gl
import graphics.window


gfx_window* demo_win
int demo_mvp_uniform
float32 demo_angle
int demo_frame_count
int demo_max_frames


int demo_frame():
	if (gfx_window_poll(demo_win) == 0):
		return 0

	demo_angle = demo_angle + 0.02
	if (demo_angle > gfx_two_pi()):
		demo_angle = demo_angle - gfx_two_pi()
	# Keep the triangle round on non-square canvases.
	float32 aspect = 1.0
	if (demo_win.height > 0):
		aspect = cast(float32, demo_win.width) / cast(float32, demo_win.height)
	mat4 aspect_scale = mat4_scale(mat4_identity(), vec3_new(1.0 / aspect, 1.0, 1.0))
	mat4 mvp = mat4_mul(aspect_scale, mat4_rotation(demo_angle, vec3_new(0.0, 0.0, 1.0)))
	glUniformMatrix4fv(demo_mvp_uniform, 1, 0, &mvp.m[0])

	glClearColor(0.08, 0.09, 0.12, 1.0)
	glClear(GL_COLOR_BUFFER_BIT)
	glDrawArrays(GL_TRIANGLES, 0, 3)
	gfx_window_swap(demo_win)

	demo_frame_count = demo_frame_count + 1
	if ((demo_max_frames > 0) && (demo_frame_count >= demo_max_frames)):
		return 0
	return 1


int main(int argc, int argv):
	args_init(argc, argv)
	char* frames_value = args_value(c"frames")
	if (frames_value != 0):
		demo_max_frames = atoi(frames_value)

	demo_win = gfx_window_open(c"W graphics demo", 640, 480)
	if (demo_win == 0):
		return 1

	char* vertex_source = strjoin(gfx_shader_header(), c"in vec2 a_pos;\nin vec3 a_color;\nout vec3 v_color;\nuniform mat4 u_mvp;\nvoid main() {\n\tv_color = a_color;\n\tgl_Position = u_mvp * vec4(a_pos, 0.0, 1.0);\n}\n")
	char* fragment_source = strjoin(gfx_shader_header(), c"in vec3 v_color;\nout vec4 frag_color;\nvoid main() {\n\tfrag_color = vec4(v_color, 1.0);\n}\n")
	int program = gl_create_program(vertex_source, fragment_source)
	if (program == 0):
		gfx_window_destroy(demo_win)
		return 1
	glUseProgram(program)

	# One triangle: position (x, y) then color (r, g, b) per vertex.
	float32[15] vertices
	vertices[0] = 0.0
	vertices[1] = 0.6
	vertices[2] = 1.0
	vertices[3] = 0.2
	vertices[4] = 0.2
	vertices[5] = -0.55
	vertices[6] = -0.4
	vertices[7] = 0.2
	vertices[8] = 1.0
	vertices[9] = 0.2
	vertices[10] = 0.55
	vertices[11] = -0.4
	vertices[12] = 0.2
	vertices[13] = 0.2
	vertices[14] = 1.0

	int32 vertex_buffer = 0
	glGenBuffers(1, &vertex_buffer)
	glBindBuffer(GL_ARRAY_BUFFER, vertex_buffer)
	glBufferData(GL_ARRAY_BUFFER, 60, &vertices[0], GL_STATIC_DRAW)

	int position_attrib = glGetAttribLocation(program, c"a_pos")
	int color_attrib = glGetAttribLocation(program, c"a_color")
	glEnableVertexAttribArray(position_attrib)
	glVertexAttribPointer(position_attrib, 2, GL_FLOAT, 0, 20, 0)
	glEnableVertexAttribArray(color_attrib)
	glVertexAttribPointer(color_attrib, 3, GL_FLOAT, 0, 20, 8)

	demo_mvp_uniform = glGetUniformLocation(program, c"u_mvp")
	demo_angle = 0.0
	demo_frame_count = 0

	gfx_window_run(demo_win, demo_frame)
	return 0
