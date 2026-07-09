/*
Spinning-triangle demo for the graphics module (x64 only):

	./bin/wv2 x64 graphics/demo.w -o bin/graphics_demo && ./bin/graphics_demo

Opens a 640x480 GLX window and draws an interpolated-color triangle
rotating through a mat4 uniform from graphics.math, using string
shaders. Runs until the window is closed (or --frames N for a fixed
number of frames, handy for unattended runs).
*/
import lib.lib
import lib.args
import lib.time
import graphics.math
import graphics.gl
import graphics.window


int main(int argc, int argv):
	args_init(argc, argv)
	int max_frames = 0
	char* frames_value = args_value(c"frames")
	if (frames_value != 0):
		max_frames = atoi(frames_value)

	gfx_window* win = gfx_window_open(c"W graphics demo", 640, 480)
	if (win == 0):
		return 1

	char* vertex_source = c"#version 130\nin vec2 a_pos;\nin vec3 a_color;\nout vec3 v_color;\nuniform mat4 u_mvp;\nvoid main() {\n\tv_color = a_color;\n\tgl_Position = u_mvp * vec4(a_pos, 0.0, 1.0);\n}\n"
	char* fragment_source = c"#version 130\nin vec3 v_color;\nout vec4 frag_color;\nvoid main() {\n\tfrag_color = vec4(v_color, 1.0);\n}\n"
	int program = gl_create_program(vertex_source, fragment_source)
	if (program == 0):
		gfx_window_destroy(win)
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

	int mvp_uniform = glGetUniformLocation(program, c"u_mvp")
	vec3 z_axis = vec3_new(0.0, 0.0, 1.0)
	float32 angle = 0.0
	int frame = 0

	while (gfx_window_poll(win)):
		angle = angle + 0.02
		if (angle > gfx_two_pi()):
			angle = angle - gfx_two_pi()
		# Keep the triangle round on non-square windows.
		float32 aspect = 1.0
		if (win.height > 0):
			aspect = cast(float32, win.width) / cast(float32, win.height)
		# Aspect correction applies after the rotation so the triangle
		# keeps its shape while spinning: mvp = S(1/aspect) * R(angle).
		mat4 aspect_scale = mat4_scale(mat4_identity(), vec3_new(1.0 / aspect, 1.0, 1.0))
		mat4 mvp = mat4_mul(aspect_scale, mat4_rotation(angle, z_axis))
		glUniformMatrix4fv(mvp_uniform, 1, 0, &mvp.m[0])

		glClearColor(0.08, 0.09, 0.12, 1.0)
		glClear(GL_COLOR_BUFFER_BIT)
		glDrawArrays(GL_TRIANGLES, 0, 3)
		gfx_window_swap(win)
		sleep_ms(16)

		frame = frame + 1
		if ((max_frames > 0) & (frame >= max_frames)):
			break

	gfx_window_destroy(win)
	return 0
