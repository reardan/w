/*
End-to-end texture smoke test for the new texture entry points: upload
a 2x2 single-channel checker with glTexImage2D (9 arguments — the call
shape the arm64_darwin FFI single-spill relaxation exists for), draw it
on a fullscreen quad with NEAREST sampling, and read the quadrants
back; then patch one texel with glTexSubImage2D and re-check, and clear
through a glScissor rect to prove GL_SCISSOR_TEST finally has a
function to set its box.

Prints "graphics gl texture OK" on success. When no display is
reachable it prints a SKIP line and exits 0; the build greps for the
"graphics gl texture" prefix so both outcomes keep the suite green
while a real failure still fails the target (the graphics_gl_smoke_test
convention).
*/
# wbuild: name=graphics_gl_texture_test arch_only=x64 expect_stdout="graphics gl texture"
import lib.lib
import graphics.gl
import graphics.window


int texture_failures


# One RGBA pixel from the back buffer; y counts from the bottom.
int texture_read_channel(int x, int y, int channel):
	char* pixel = malloc(4)
	glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
	int value = pixel[channel] & 255
	free(pixel)
	return value


void texture_check(char* label, int x, int y, int want, int tolerance):
	int got = texture_read_channel(x, y, 0)
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
		texture_failures = texture_failures + 1


int main(int argc, int argv):
	gfx_window* win = gfx_window_open(c"w graphics texture", 320, 240)
	if (win == 0):
		println(c"graphics gl texture SKIP (no display)")
		return 0

	# Textured-quad shaders; bodies compile as GLSL 130 (GLX), 150 (Mac
	# core profile) and 300 es (WebGL2): in/out interpolators, texture()
	# not texture2D, an explicit fragment output. The single-channel
	# atlas convention samples .r (WebGL2 has no GL_ALPHA textures).
	char* vertex_source = strjoin(gfx_shader_header(), c"in vec2 a_pos;\nin vec2 a_uv;\nout vec2 v_uv;\nvoid main() {\n\tv_uv = a_uv;\n\tgl_Position = vec4(a_pos, 0.0, 1.0);\n}\n")
	char* fragment_source = strjoin(gfx_shader_header(), c"in vec2 v_uv;\nout vec4 frag_color;\nuniform sampler2D u_tex;\nvoid main() {\n\tfloat r = texture(u_tex, v_uv).r;\n\tfrag_color = vec4(r, r, r, 1.0);\n}\n")
	int program = gl_create_program(vertex_source, fragment_source)
	if (program == 0):
		println(c"graphics gl texture FAILED (shader build)")
		return 1
	glUseProgram(program)

	# 2x2 GL_R8 checker: row 0 (v near 0) is white/black, row 1 is
	# black/white. Two-byte rows need GL_UNPACK_ALIGNMENT 1.
	char* texels = malloc(4)
	texels[0] = 255
	texels[1] = 0
	texels[2] = 0
	texels[3] = 255
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
	int32 texture = 0
	glGenTextures(1, &texture)
	glActiveTexture(GL_TEXTURE0)
	glBindTexture(GL_TEXTURE_2D, texture)
	glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, 2, 2, 0, GL_RED, GL_UNSIGNED_BYTE, texels)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
	int tex_uniform = glGetUniformLocation(program, c"u_tex")
	glUniform1i(tex_uniform, 0)

	# Fullscreen quad as two triangles; uv (0,0) lands at the bottom
	# left, matching glReadPixels' bottom-origin y.
	float32 neg = 0.0 - 1.0
	float32[24] vertices
	vertices[0] = neg
	vertices[1] = neg
	vertices[2] = 0.0
	vertices[3] = 0.0
	vertices[4] = 1.0
	vertices[5] = neg
	vertices[6] = 1.0
	vertices[7] = 0.0
	vertices[8] = 1.0
	vertices[9] = 1.0
	vertices[10] = 1.0
	vertices[11] = 1.0
	vertices[12] = neg
	vertices[13] = neg
	vertices[14] = 0.0
	vertices[15] = 0.0
	vertices[16] = 1.0
	vertices[17] = 1.0
	vertices[18] = 1.0
	vertices[19] = 1.0
	vertices[20] = neg
	vertices[21] = 1.0
	vertices[22] = 0.0
	vertices[23] = 1.0

	int32 vertex_buffer = 0
	glGenBuffers(1, &vertex_buffer)
	glBindBuffer(GL_ARRAY_BUFFER, vertex_buffer)
	glBufferData(GL_ARRAY_BUFFER, 96, &vertices[0], GL_STATIC_DRAW)

	int position_attrib = glGetAttribLocation(program, c"a_pos")
	int uv_attrib = glGetAttribLocation(program, c"a_uv")
	glEnableVertexAttribArray(position_attrib)
	glVertexAttribPointer(position_attrib, 2, GL_FLOAT, 0, 16, 0)
	glEnableVertexAttribArray(uv_attrib)
	glVertexAttribPointer(uv_attrib, 2, GL_FLOAT, 0, 16, 8)

	# Alpha blending on: the UI text path renders through
	# GL_SRC_ALPHA/GL_ONE_MINUS_SRC_ALPHA, so keep it enabled here
	# (opaque fragments, so the checker reads back unchanged).
	glEnable(GL_BLEND)
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

	glClearColor(0.1, 0.2, 0.3, 1.0)
	glClear(GL_COLOR_BUFFER_BIT)
	glDrawArrays(GL_TRIANGLES, 0, 6)
	glFinish()

	# Quadrant centers; NEAREST sampling makes each quadrant one texel.
	texture_check(c"bottom left", 80, 60, 255, 6)
	texture_check(c"bottom right", 240, 60, 0, 6)
	texture_check(c"top left", 80, 180, 0, 6)
	texture_check(c"top right", 240, 180, 255, 6)

	# Patch the bottom-right texel to white through glTexSubImage2D (the
	# other 9-argument entry point) and re-check.
	char* patch = malloc(1)
	patch[0] = 255
	glTexSubImage2D(GL_TEXTURE_2D, 0, 1, 0, 1, 1, GL_RED, GL_UNSIGNED_BYTE, patch)
	glClear(GL_COLOR_BUFFER_BIT)
	glDrawArrays(GL_TRIANGLES, 0, 6)
	glFinish()
	texture_check(c"patched bottom right", 240, 60, 255, 6)

	# Scissored clear: only the left half takes the gray clear; the
	# right half keeps the quad.
	glEnable(GL_SCISSOR_TEST)
	glScissor(0, 0, 160, 240)
	glClearColor(0.25, 0.25, 0.25, 1.0)
	glClear(GL_COLOR_BUFFER_BIT)
	glFinish()
	texture_check(c"scissored left", 80, 60, 64, 6)
	texture_check(c"unscissored right", 240, 60, 255, 6)
	glDisable(GL_SCISSOR_TEST)

	int gl_error = glGetError()
	if (gl_error != 0):
		print_error(c"glGetError: ")
		print_error(itoa(gl_error))
		print_error(c"\n")
		texture_failures = texture_failures + 1

	gfx_window_swap(win)
	gfx_window_poll(win)

	free(texels)
	free(patch)
	if (texture_failures > 0):
		println(c"graphics gl texture FAILED")
		return 1
	println(c"graphics gl texture OK")
	gfx_window_destroy(win)
	return 0
