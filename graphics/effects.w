/*
graphics.effects: GPU image effects -- a fullscreen-quad pass helper and
a ping-pong framebuffer chain runner over graphics.effects_core effects.

	fx_gl g
	if (fx_gl_init(&g) == 0): ...            # needs a current GL context
	list[fx_effect*] chain = new list[fx_effect*]
	chain.push(fx_bcs(0.1, 1.2, 1.1))
	chain.push(fx_blur_pass(3, 0))
	chain.push(fx_blur_pass(3, 1))
	rgba_image* out = fx_gl_run_image(&g, chain, image)

Each effect is one fragment shader (its GLSL body joined after
gfx_shader_header() and a shared prelude) drawn over a fullscreen
triangle strip into an RGBA8 texture-backed framebuffer object sized to
the IMAGE, not the window; the next pass samples that texture and draws
into the other one. The prelude gives every body:

	in vec2 v_uv;                # texel center of this fragment, 0..1
	out vec4 frag_color;
	uniform sampler2D u_source;  # the previous pass (NEAREST, clamped)
	uniform vec2 u_texel;        # 1 / image size
	uniform float u_p[12];       # the effect's fx_effect.p parameters

Row 0 of the source texture is row 0 of the image (top-down rgba_image
rows upload as-is), each pass maps fragment row j to texel row j, and
glReadPixels returns rows in the same order, so no pass ever flips.

The runner saves and restores the framebuffer binding, viewport,
program, active texture unit and the blend/scissor enables it turns
off, so it can run between a UI frame's draws. graphics/effects_cpu.w
is the reference implementation every shader here is tested against
(graphics/effects_gl_test.w).

Design notes: docs/projects/effects.md
*/
import lib.lib
import graphics.gl
import graphics.window
import graphics.effects_core
import graphics.image.image


struct fx_gl:
	int ready
	int32 quad_buffer
	int32[8] programs          # by effect kind, compiled on first use
	# The ping-pong pair, both target_width x target_height.
	int32[2] textures
	int32[2] framebuffers
	int target_width
	int target_height
	# The uploaded input of fx_gl_run_image / fx_gl_upload.
	int32 source_texture
	int source_width
	int source_height


######################### fullscreen-quad pass ########################

char* fx_vertex_body():
	return c"in vec2 a_pos;\nout vec2 v_uv;\nvoid main() {\n\tv_uv = a_pos * 0.5 + 0.5;\n\tgl_Position = vec4(a_pos, 0.0, 1.0);\n}\n"


char* fx_fragment_prelude():
	return c"in vec2 v_uv;\nout vec4 frag_color;\nuniform sampler2D u_source;\nuniform vec2 u_texel;\nuniform float u_p[12];\n"


# Build a pass program from a fragment body written against the
# prelude above. Returns the program id, or 0 after the compile log.
int fx_pass_program(char* fragment_body):
	char* vertex_source = strjoin(gfx_shader_header(), fx_vertex_body())
	char* head = strjoin(gfx_shader_header(), fx_fragment_prelude())
	char* fragment_source = strjoin(head, fragment_body)
	int program = gl_create_program(vertex_source, fragment_source)
	free(vertex_source)
	free(head)
	free(fragment_source)
	return program


# Draw the fullscreen strip with program into whatever framebuffer and
# viewport are bound, sampling source on unit 0. The program must be in
# use and its own uniforms set; this sets u_source and u_texel.
void fx_draw_pass(fx_gl* g, int program, int source, int width, int height):
	glActiveTexture(GL_TEXTURE0)
	glBindTexture(GL_TEXTURE_2D, source)
	glUniform1i(glGetUniformLocation(program, c"u_source"), 0)
	glUniform2f(glGetUniformLocation(program, c"u_texel"), 1.0 / cast(float32, width), 1.0 / cast(float32, height))
	int position = glGetAttribLocation(program, c"a_pos")
	glBindBuffer(GL_ARRAY_BUFFER, g.quad_buffer)
	glEnableVertexAttribArray(position)
	glVertexAttribPointer(position, 2, GL_FLOAT, 0, 8, 0)
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
	glDisableVertexAttribArray(position)


########################### effect shaders ############################

char* fx_fragment_body(int kind):
	if (kind == FX_BCS):
		return c"void main() {\n\tvec4 s = texture(u_source, v_uv);\n\tvec3 c = (s.rgb + u_p[0] - 0.5) * u_p[1] + 0.5;\n\tfloat l = dot(c, vec3(0.2126, 0.7152, 0.0722));\n\tc = l + (c - l) * u_p[2];\n\tfrag_color = vec4(clamp(c, 0.0, 1.0), s.a);\n}\n"
	if (kind == FX_LEVELS):
		return c"void main() {\n\tvec4 s = texture(u_source, v_uv);\n\tvec3 v = clamp((s.rgb - u_p[0]) / (u_p[1] - u_p[0]), 0.0, 1.0);\n\tv = pow(max(v, vec3(1e-6)), vec3(1.0 / u_p[2]));\n\tvec3 c = u_p[3] + v * (u_p[4] - u_p[3]);\n\tfrag_color = vec4(clamp(c, 0.0, 1.0), s.a);\n}\n"
	if (kind == FX_CONVOLVE):
		return c"void main() {\n\tvec3 sum = vec3(u_p[9]);\n\tfor (int k = 0; k < 9; k++) {\n\t\tint row = k / 3;\n\t\tvec2 offset = vec2(float(k - row * 3 - 1), float(row - 1)) * u_texel;\n\t\tsum += u_p[k] * texture(u_source, v_uv + offset).rgb;\n\t}\n\tfrag_color = vec4(clamp(sum, 0.0, 1.0), texture(u_source, v_uv).a);\n}\n"
	if (kind == FX_BLUR):
		return c"uniform float u_weights[33];\nuniform int u_radius;\nuniform vec2 u_step;\nvoid main() {\n\tvec4 sum = texture(u_source, v_uv) * u_weights[0];\n\tfor (int i = 1; i <= u_radius; i++) {\n\t\tvec2 offset = u_step * float(i);\n\t\tsum += u_weights[i] * (texture(u_source, v_uv + offset) + texture(u_source, v_uv - offset));\n\t}\n\tfrag_color = clamp(sum, 0.0, 1.0);\n}\n"
	if (kind == FX_VIGNETTE):
		return c"void main() {\n\tvec4 s = texture(u_source, v_uv);\n\tfloat d = length((v_uv - 0.5) * 2.0) * 0.70710678;\n\tfloat f = 1.0 - u_p[0] * smoothstep(u_p[1], u_p[1] + u_p[2], d);\n\tfrag_color = vec4(clamp(s.rgb * f, 0.0, 1.0), s.a);\n}\n"
	if (kind == FX_LUT):
		return c"uniform sampler2D u_lut;\nuniform float u_lut_size;\nvoid main() {\n\tvec4 s = texture(u_source, v_uv);\n\tvec3 c = clamp(s.rgb, 0.0, 1.0);\n\tfloat n = u_lut_size;\n\tfloat b = c.b * (n - 1.0);\n\tfloat b0 = floor(b);\n\tfloat b1 = min(b0 + 1.0, n - 1.0);\n\tvec2 rg = c.rg * (n - 1.0) + 0.5;\n\tvec2 scale = vec2(1.0 / (n * n), 1.0 / n);\n\tvec3 lo = texture(u_lut, vec2(b0 * n + rg.x, rg.y) * scale).rgb;\n\tvec3 hi = texture(u_lut, vec2(b1 * n + rg.x, rg.y) * scale).rgb;\n\tvec3 graded = mix(lo, hi, b - b0);\n\tfrag_color = vec4(clamp(mix(s.rgb, graded, u_p[0]), 0.0, 1.0), s.a);\n}\n"
	return 0


# The cached program for kind, compiled on first use; 0 on failure.
int fx_gl_program(fx_gl* g, int kind):
	if ((kind <= 0) || (kind >= FX_KIND_COUNT)): return 0
	if (g.programs[kind] == 0):
		char* body = fx_fragment_body(kind)
		if (body == 0): return 0
		g.programs[kind] = fx_pass_program(body)
	return g.programs[kind]


############################# the runner ##############################

# Set up the quad buffer. Needs a current GL context; returns 1.
int fx_gl_init(fx_gl* g):
	g.ready = 0
	g.quad_buffer = 0
	for i in range(8): g.programs[i] = 0
	for i in range(2):
		g.textures[i] = 0
		g.framebuffers[i] = 0
	g.target_width = 0
	g.target_height = 0
	g.source_texture = 0
	g.source_width = 0
	g.source_height = 0
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
	glGenBuffers(1, &g.quad_buffer)
	glBindBuffer(GL_ARRAY_BUFFER, g.quad_buffer)
	glBufferData(GL_ARRAY_BUFFER, 32, &quad[0], GL_STATIC_DRAW)
	g.ready = 1
	return 1


# The largest image side the context renders to (GL_MAX_TEXTURE_SIZE).
int fx_gl_max_size():
	int32 size = 0
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &size)
	return size


void fx_gl_free_targets(fx_gl* g):
	for i in range(2):
		if (g.framebuffers[i] != 0): glDeleteFramebuffers(1, &g.framebuffers[i])
		if (g.textures[i] != 0): glDeleteTextures(1, &g.textures[i])
		g.framebuffers[i] = 0
		g.textures[i] = 0
	g.target_width = 0
	g.target_height = 0


# (Re)allocate the ping-pong pair at width x height. Returns 0 when the
# driver refuses the framebuffer.
int fx_gl_targets(fx_gl* g, int width, int height):
	if ((g.target_width == width) && (g.target_height == height) && (g.framebuffers[1] != 0)): return 1
	fx_gl_free_targets(g)
	glActiveTexture(GL_TEXTURE0)
	for i in range(2):
		g.textures[i] = gl_texture_rgba(width, height, 0, GL_NEAREST)
		g.framebuffers[i] = gl_framebuffer_for_texture(g.textures[i])
		if (g.framebuffers[i] == 0):
			fx_gl_free_targets(g)
			return 0
	g.target_width = width
	g.target_height = height
	return 1


# Upload width x height RGBA rows as the runner's source texture,
# reusing the texture while the size is unchanged. Returns its id.
int fx_gl_upload(fx_gl* g, char* pixels, int width, int height):
	glActiveTexture(GL_TEXTURE0)
	if ((g.source_texture != 0) && (g.source_width == width) && (g.source_height == height)):
		glBindTexture(GL_TEXTURE_2D, g.source_texture)
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
		return g.source_texture
	if (g.source_texture != 0): glDeleteTextures(1, &g.source_texture)
	g.source_texture = gl_texture_rgba(width, height, pixels, GL_NEAREST)
	g.source_width = width
	g.source_height = height
	return g.source_texture


# Set kind-specific uniforms beyond u_p and bind any extra textures.
void fx_gl_effect_uniforms(fx_gl* g, int program, fx_effect* e, int width, int height):
	if (e.kind == FX_BLUR):
		float32[33] weights
		fx_blur_weights(e, &weights[0])
		glUniform1fv(glGetUniformLocation(program, c"u_weights"), 33, &weights[0])
		glUniform1i(glGetUniformLocation(program, c"u_radius"), cast(int, e.p[0]))
		if (e.p[2] > 0.5): glUniform2f(glGetUniformLocation(program, c"u_step"), 0.0, 1.0 / cast(float32, height))
		else: glUniform2f(glGetUniformLocation(program, c"u_step"), 1.0 / cast(float32, width), 0.0)
	else if (e.kind == FX_LUT):
		glActiveTexture(GL_TEXTURE1)
		if (e.lut_texture == 0):
			e.lut_texture = gl_texture_rgba(e.lut_size * e.lut_size, e.lut_size, e.lut, GL_LINEAR)
		else: glBindTexture(GL_TEXTURE_2D, e.lut_texture)
		glUniform1i(glGetUniformLocation(program, c"u_lut"), 1)
		glUniform1f(glGetUniformLocation(program, c"u_lut_size"), cast(float32, e.lut_size))
		glActiveTexture(GL_TEXTURE0)


# Release the GL texture an effect cached (its LUT strip); call before
# fx_effect_free while the context is current.
void fx_gl_release_effect(fx_effect* e):
	if ((e != 0) && (e.lut_texture != 0)):
		glDeleteTextures(1, &e.lut_texture)
		e.lut_texture = 0


# Run effects over the width x height texture source. Returns the
# texture holding the result: source itself for an empty chain,
# otherwise one of the runner's ping-pong textures (valid until the next
# run). Returns 0 when a shader or framebuffer fails. GL state the
# passes touch is restored before returning.
int fx_gl_run(fx_gl* g, int source, int width, int height, list[fx_effect*] effects):
	if (effects.length == 0): return source
	# Saved before fx_gl_targets: creating a framebuffer binds it.
	int32 saved_framebuffer = 0
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved_framebuffer)
	if (fx_gl_targets(g, width, height) == 0):
		glBindFramebuffer(GL_FRAMEBUFFER, saved_framebuffer)
		return 0
	int32[4] saved_viewport
	glGetIntegerv(GL_VIEWPORT, &saved_viewport[0])
	int32 saved_program = 0
	glGetIntegerv(GL_CURRENT_PROGRAM, &saved_program)
	int blend = gl_is_enabled(GL_BLEND)
	int scissor = gl_is_enabled(GL_SCISSOR_TEST)
	glDisable(GL_BLEND)
	glDisable(GL_SCISSOR_TEST)
	glViewport(0, 0, width, height)
	int current = source
	int target = 0
	int result = 0
	for i in range(effects.length):
		fx_effect* e = effects[i]
		int program = fx_gl_program(g, e.kind)
		if (program == 0):
			result = 0
			break
		glBindFramebuffer(GL_FRAMEBUFFER, g.framebuffers[target])
		glUseProgram(program)
		glUniform1fv(glGetUniformLocation(program, c"u_p"), fx_param_slots, &e.p[0])
		fx_gl_effect_uniforms(g, program, e, width, height)
		fx_draw_pass(g, program, current, width, height)
		current = g.textures[target]
		result = current
		target = 1 - target
	glBindFramebuffer(GL_FRAMEBUFFER, saved_framebuffer)
	glViewport(saved_viewport[0], saved_viewport[1], saved_viewport[2], saved_viewport[3])
	glUseProgram(saved_program)
	glActiveTexture(GL_TEXTURE0)
	if (blend): glEnable(GL_BLEND)
	if (scissor): glEnable(GL_SCISSOR_TEST)
	return result


# Read a width x height texture back as tightly packed RGBA rows (image
# row order). Returns malloc'd pixels, or 0 if it cannot be bound.
char* fx_gl_read(fx_gl* g, int texture, int width, int height):
	int32 saved_framebuffer = 0
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved_framebuffer)
	int framebuffer = 0
	int temporary = 1
	for i in range(2):
		if ((g.textures[i] == texture) && (g.textures[i] != 0)):
			framebuffer = g.framebuffers[i]
			temporary = 0
	if (framebuffer == 0):
		framebuffer = gl_framebuffer_for_texture(texture)
		if (framebuffer == 0): return 0
	glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
	glPixelStorei(GL_PACK_ALIGNMENT, 4)
	char* pixels = cast(char*, malloc(width * height * 4))
	glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
	glBindFramebuffer(GL_FRAMEBUFFER, saved_framebuffer)
	if (temporary):
		int32 id = framebuffer
		glDeleteFramebuffers(1, &id)
	return pixels


# Upload, run and read back raw RGBA; returns malloc'd pixels or 0.
char* fx_gl_run_pixels(fx_gl* g, list[fx_effect*] effects, char* pixels, int width, int height):
	int max_size = fx_gl_max_size()
	if ((width > max_size) || (height > max_size)): return 0
	int source = fx_gl_upload(g, pixels, width, height)
	int result = fx_gl_run(g, source, width, height, effects)
	if (result == 0): return 0
	return fx_gl_read(g, result, width, height)


# The same over an rgba_image at its own resolution; returns a new
# caller-owned image, or 0 when the GPU path failed (fall back to
# graphics.effects_cpu).
rgba_image* fx_gl_run_image(fx_gl* g, list[fx_effect*] effects, rgba_image* image):
	char* pixels = fx_gl_run_pixels(g, effects, image.pixels, image.width, image.height)
	if (pixels == 0): return 0
	return new rgba_image(image.width, image.height, image.width * image.height * 4, pixels)


void fx_gl_destroy(fx_gl* g):
	if (g.ready == 0): return
	fx_gl_free_targets(g)
	for i in range(8):
		if (g.programs[i] != 0): glDeleteProgram(g.programs[i])
		g.programs[i] = 0
	if (g.source_texture != 0): glDeleteTextures(1, &g.source_texture)
	g.source_texture = 0
	glDeleteBuffers(1, &g.quad_buffer)
	g.ready = 0
