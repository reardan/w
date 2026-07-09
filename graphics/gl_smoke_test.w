/*
End-to-end GL smoke test: open a window through the target's backend
(X11/GLX on x64/arm64, Cocoa on arm64_darwin), compile a GLSL program
from source strings, draw one interpolated-color triangle through a
mat4 uniform from graphics.math, and read pixels back to verify the
rasterized output.

Prints "graphics gl smoke OK" on success. When no display is reachable
(headless host) it prints a SKIP line and exits 0, like
tests/cuda_smoke.w does for missing GPUs; the build greps for the
"graphics gl smoke" prefix so both outcomes keep the suite green while
a real failure (bad pixels, shader errors) still fails the target.
*/
import lib.lib
import graphics.math
import graphics.gl
import graphics.window


int smoke_failures


# One RGBA pixel from the back buffer; y counts from the bottom.
int read_pixel_channel(int x, int y, int channel):
	char* pixel = malloc(4)
	glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
	int value = pixel[channel] & 255
	free(pixel)
	return value


void check_channel(char* label, int x, int y, int channel, int want, int tolerance):
	int got = read_pixel_channel(x, y, channel)
	int diff = got - want
	if (diff < 0):
		diff = 0 - diff
	if (diff > tolerance):
		print_error(c"pixel check failed: ")
		print_error(label)
		print_error(c" wanted ")
		print_error(itoa(want))
		print_error(c" got ")
		print_error(itoa(got))
		print_error(c"\n")
		smoke_failures = smoke_failures + 1


int main(int argc, int argv):
	gfx_window* win = gfx_window_open(c"w graphics smoke", 320, 240)
	if (win == 0):
		println(c"graphics gl smoke SKIP (no display)")
		return 0

	char* version = glGetString(GL_VERSION)
	print(c"GL_VERSION: ")
	println(version)

	# String shaders: per-vertex color through an interpolator, position
	# through a mat4 uniform driven by graphics.math. The bodies compile
	# as both GLSL 130 (GLX) and 150 (Mac core profile); the backend's
	# gfx_shader_header() supplies the right "#version" line.
	char* vertex_source = strjoin(gfx_shader_header(), c"in vec2 a_pos;\nin vec3 a_color;\nout vec3 v_color;\nuniform mat4 u_mvp;\nvoid main() {\n\tv_color = a_color;\n\tgl_Position = u_mvp * vec4(a_pos, 0.0, 1.0);\n}\n")
	char* fragment_source = strjoin(gfx_shader_header(), c"in vec3 v_color;\nout vec4 frag_color;\nvoid main() {\n\tfrag_color = vec4(v_color, 1.0);\n}\n")
	int program = gl_create_program(vertex_source, fragment_source)
	if (program == 0):
		println(c"graphics gl smoke FAILED (shader build)")
		return 1
	glUseProgram(program)

	# A triangle spanning most of clip space: red, green and blue
	# corners; the center interpolates to a known mix.
	float32[15] vertices
	vertices[0] = -0.8
	vertices[1] = -0.8
	vertices[2] = 1.0
	vertices[3] = 0.0
	vertices[4] = 0.0
	vertices[5] = 0.8
	vertices[6] = -0.8
	vertices[7] = 0.0
	vertices[8] = 1.0
	vertices[9] = 0.0
	vertices[10] = 0.0
	vertices[11] = 0.9
	vertices[12] = 0.0
	vertices[13] = 0.0
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

	# Identity transform via the math library; exercised end to end
	# through glUniformMatrix4fv.
	mat4 mvp = mat4_identity()
	int mvp_uniform = glGetUniformLocation(program, c"u_mvp")
	glUniformMatrix4fv(mvp_uniform, 1, 0, &mvp.m[0])

	glClearColor(0.1, 0.2, 0.3, 1.0)
	glClear(GL_COLOR_BUFFER_BIT)
	glDrawArrays(GL_TRIANGLES, 0, 3)
	glFinish()

	# Barycentric mix at the window center (NDC 0,0): the blue corner
	# contributes 0.8/1.7, red and green split the rest evenly.
	# 0.2647 * 255 = 67, 0.4706 * 255 = 120.
	check_channel(c"center red", 160, 120, 0, 67, 14)
	check_channel(c"center green", 160, 120, 1, 67, 14)
	check_channel(c"center blue", 160, 120, 2, 120, 14)
	# A corner outside the triangle shows the clear color.
	check_channel(c"corner red", 4, 4, 0, 26, 4)
	check_channel(c"corner green", 4, 4, 1, 51, 4)
	check_channel(c"corner blue", 4, 4, 2, 77, 4)

	int gl_error = glGetError()
	if (gl_error != 0):
		print_error(c"glGetError: ")
		print_error(itoa(gl_error))
		print_error(c"\n")
		smoke_failures = smoke_failures + 1

	gfx_window_swap(win)
	# Drain events once so the poll/input path runs under test too.
	gfx_window_poll(win)

	if (smoke_failures > 0):
		println(c"graphics gl smoke FAILED")
		return 1
	println(c"graphics gl smoke OK")
	gfx_window_destroy(win)
	return 0
