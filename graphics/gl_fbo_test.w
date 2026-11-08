/*
End-to-end framebuffer-object (render-to-texture) test.

Pass 1 renders a gl_FragCoord gradient into a 256x128 RGBA8 texture
through an FBO -- larger than the 64x48 window, so a read at (200, 100)
can only succeed off-screen -- and checks it with glReadPixels while the
FBO is bound. A depth renderbuffer is attached too, to exercise the
renderbuffer entry points and the completeness check. Pass 2 binds the
default framebuffer, samples that texture on a fullscreen quad with
NEAREST filtering, and checks the window pixels map back to the right
texels. glGetIntegerv confirms the FRAMEBUFFER_BINDING and VIEWPORT
round trips along the way.

Prints "graphics gl fbo OK" on success, or a SKIP line (exit 0) with no
display; the build greps for the "graphics gl fbo" prefix (the
graphics_gl_texture_test convention).
*/
# wbuild: name=graphics_gl_fbo_test arch_only=x64 expect_stdout="graphics gl fbo"
import lib.lib
import graphics.gl
import graphics.window
import lib.ci_skip


int fbo_failures


void fbo_check(char* label, char* pixel, int channel, int want, int tolerance):
	int got = pixel[channel] & 255
	int diff = got - want
	if (diff < 0): diff = 0 - diff
	if (diff > tolerance):
		print_error(c"pixel check failed: ")
		print_error(label)
		print_error(c" channel ")
		print_error(itoa(channel))
		print_error(c" wanted ")
		print_error(itoa(want))
		print_error(c" got ")
		print_error(itoa(got))
		print_error(c"\n")
		fbo_failures = fbo_failures + 1


void fbo_expect(char* label, int want, int got):
	if (want != got):
		print_error(label)
		print_error(c": wanted ")
		print_error(itoa(want))
		print_error(c" got ")
		print_error(itoa(got))
		print_error(c"\n")
		fbo_failures = fbo_failures + 1


# The gradient pass 1 writes at texel (x, y): red ramps across, green
# up, blue constant.
int fbo_ramp(int coord, int extent):
	return (((coord * 2 + 1) * 255) + extent) / (extent * 2)


int main(int argc, int argv):
	gfx_window* win = gfx_window_open(c"w graphics fbo", 64, 48)
	if (win == 0):
		test_skip(c"graphics gl fbo SKIP (no display)")
		return 0

	char* vertex_source = strjoin(gfx_shader_header(), c"in vec2 a_pos;\nout vec2 v_uv;\nvoid main() {\n\tv_uv = a_pos * 0.5 + 0.5;\n\tgl_Position = vec4(a_pos, 0.0, 1.0);\n}\n")
	char* gradient_source = strjoin(gfx_shader_header(), c"in vec2 v_uv;\nout vec4 frag_color;\nuniform vec2 u_size;\nvoid main() {\n\tfrag_color = vec4(gl_FragCoord.x / u_size.x, gl_FragCoord.y / u_size.y, 0.25, 1.0);\n}\n")
	char* sample_source = strjoin(gfx_shader_header(), c"in vec2 v_uv;\nout vec4 frag_color;\nuniform sampler2D u_tex;\nvoid main() {\n\tfrag_color = texture(u_tex, v_uv);\n}\n")
	int gradient = gl_create_program(vertex_source, gradient_source)
	int sampler = gl_create_program(vertex_source, sample_source)
	if ((gradient == 0) || (sampler == 0)):
		println(c"graphics gl fbo FAILED (shader build)")
		return 1

	# A fullscreen triangle strip.
	float32 neg = 0.0 - 1.0
	float32[8] quad
	quad[0] = neg
	quad[1] = neg
	quad[2] = 1.0
	quad[3] = neg
	quad[4] = neg
	quad[5] = 1.0
	quad[6] = 1.0
	quad[7] = 1.0
	int32 vertex_buffer = 0
	glGenBuffers(1, &vertex_buffer)
	glBindBuffer(GL_ARRAY_BUFFER, vertex_buffer)
	glBufferData(GL_ARRAY_BUFFER, 32, &quad[0], GL_STATIC_DRAW)

	# The render target: a texture plus a depth renderbuffer.
	int tex_w = 256
	int tex_h = 128
	glActiveTexture(GL_TEXTURE0)
	int texture = gl_texture_rgba(tex_w, tex_h, 0, GL_NEAREST)
	int framebuffer = gl_framebuffer_for_texture(texture)
	if (framebuffer == 0):
		println(c"graphics gl fbo FAILED (incomplete color-only framebuffer)")
		return 1
	int32 depth = 0
	glGenRenderbuffers(1, &depth)
	glBindRenderbuffer(GL_RENDERBUFFER, depth)
	glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, tex_w, tex_h)
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth)
	fbo_expect(c"status with depth attached", GL_FRAMEBUFFER_COMPLETE, glCheckFramebufferStatus(GL_FRAMEBUFFER))
	fbo_expect(c"FRAMEBUFFER_BINDING", framebuffer, gl_current_framebuffer())

	# Pass 1: into the texture, at the texture's resolution.
	glViewport(0, 0, tex_w, tex_h)
	int32[4] viewport
	glGetIntegerv(GL_VIEWPORT, &viewport[0])
	fbo_expect(c"viewport width", tex_w, viewport[2])
	fbo_expect(c"viewport height", tex_h, viewport[3])
	glDisable(GL_BLEND)
	glClearColor(0.0, 0.0, 0.0, 0.0)
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
	glUseProgram(gradient)
	glUniform2f(glGetUniformLocation(gradient, c"u_size"), cast(float32, tex_w), cast(float32, tex_h))
	int gradient_pos = glGetAttribLocation(gradient, c"a_pos")
	glEnableVertexAttribArray(gradient_pos)
	glVertexAttribPointer(gradient_pos, 2, GL_FLOAT, 0, 8, 0)
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
	glFinish()

	# Read back with the FBO bound: (200, 100) lies outside the window.
	char* pixel = cast(char*, malloc(4))
	glReadPixels(200, 100, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
	fbo_check(c"fbo (200,100)", pixel, 0, fbo_ramp(200, tex_w), 2)
	fbo_check(c"fbo (200,100)", pixel, 1, fbo_ramp(100, tex_h), 2)
	fbo_check(c"fbo (200,100)", pixel, 2, 64, 2)
	fbo_check(c"fbo (200,100)", pixel, 3, 255, 0)
	glReadPixels(3, 120, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
	fbo_check(c"fbo (3,120)", pixel, 0, fbo_ramp(3, tex_w), 2)
	fbo_check(c"fbo (3,120)", pixel, 1, fbo_ramp(120, tex_h), 2)

	# Pass 2: the window samples the texture.
	glBindFramebuffer(GL_FRAMEBUFFER, 0)
	fbo_expect(c"FRAMEBUFFER_BINDING after unbind", 0, gl_current_framebuffer())
	glViewport(0, 0, win.width, win.height)
	glClearColor(1.0, 0.0, 1.0, 1.0)
	glClear(GL_COLOR_BUFFER_BIT)
	glUseProgram(sampler)
	glBindTexture(GL_TEXTURE_2D, texture)
	glUniform1i(glGetUniformLocation(sampler, c"u_tex"), 0)
	int sampler_pos = glGetAttribLocation(sampler, c"a_pos")
	glEnableVertexAttribArray(sampler_pos)
	glVertexAttribPointer(sampler_pos, 2, GL_FLOAT, 0, 8, 0)
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
	glFinish()
	# Window pixel (px, py) samples texel (px * 4 + 2, py * 8 / 3) at
	# 64x48 -> 256x128 with NEAREST filtering.
	int px = 10
	int py = 30
	int tx = ((px * 2 + 1) * tex_w) / (win.width * 2)
	int ty = ((py * 2 + 1) * tex_h) / (win.height * 2)
	glReadPixels(px, py, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
	fbo_check(c"window (10,30)", pixel, 0, fbo_ramp(tx, tex_w), 2)
	fbo_check(c"window (10,30)", pixel, 1, fbo_ramp(ty, tex_h), 2)
	fbo_check(c"window (10,30)", pixel, 2, 64, 2)

	int gl_error = glGetError()
	if (gl_error != 0):
		print_error(c"glGetError: ")
		print_error(itoa(gl_error))
		print_error(c"\n")
		fbo_failures = fbo_failures + 1

	gfx_window_swap(win)
	gfx_window_poll(win)

	int32 texture_id = texture
	glDeleteTextures(1, &texture_id)
	glDeleteRenderbuffers(1, &depth)
	int32 framebuffer_id = framebuffer
	glDeleteFramebuffers(1, &framebuffer_id)
	free(pixel)
	if (fbo_failures > 0):
		println(c"graphics gl fbo FAILED")
		return 1
	println(c"graphics gl fbo OK")
	gfx_window_destroy(win)
	return 0
