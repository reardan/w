/*
graphics.gl: OpenGL enums and shader helpers over the per-target GL
binding (graphics/__arch__/<target>/gl_native.w — libGL.so.1 on the
Linux targets, the OpenGL framework on arm64_darwin, WebGL2 host
imports on wasm). Consumers import this module only; the platform
split stays behind the __arch__ path.

Shaders are plain GLSL source strings compiled at runtime with
gl_create_program — no shader file loader yet, string shaders by design
for now. Portable shader sources take their "#version" line from
gfx_shader_header() (graphics.window): 130 on GLX contexts, 150 on the
Mac's 3.2-core contexts, "300 es" on WebGL2.

GL handles (GLuint) travel as word-sized W ints. GLint out-parameters
are int32*.

Design notes: docs/projects/graphics.md
*/
import lib.lib
import graphics.__arch__.gl_native


enum gl_constant:
	GL_DEPTH_BUFFER_BIT = 0x100
	GL_COLOR_BUFFER_BIT = 0x4000
	GL_POINTS = 0x0000
	GL_LINES = 0x0001
	GL_TRIANGLES = 0x0004
	GL_TRIANGLE_STRIP = 0x0005
	GL_TRIANGLE_FAN = 0x0006
	GL_DEPTH_TEST = 0x0B71
	GL_CULL_FACE = 0x0B44
	GL_BLEND = 0x0BE2
	GL_SCISSOR_TEST = 0x0C11
	GL_TEXTURE_2D = 0x0DE1
	GL_UNSIGNED_BYTE = 0x1401
	GL_UNSIGNED_INT = 0x1405
	GL_FLOAT = 0x1406
	GL_RGBA = 0x1908
	GL_VENDOR = 0x1F00
	GL_RENDERER = 0x1F01
	GL_VERSION = 0x1F02
	GL_SRC_ALPHA = 0x0302
	GL_ONE_MINUS_SRC_ALPHA = 0x0303
	GL_ARRAY_BUFFER = 0x8892
	GL_ELEMENT_ARRAY_BUFFER = 0x8893
	GL_STATIC_DRAW = 0x88E4
	GL_DYNAMIC_DRAW = 0x88E8
	GL_FRAGMENT_SHADER = 0x8B30
	GL_VERTEX_SHADER = 0x8B31
	GL_COMPILE_STATUS = 0x8B81
	GL_LINK_STATUS = 0x8B82
	GL_INFO_LOG_LENGTH = 0x8B84
	GL_TEXTURE0 = 0x84C0
	GL_TEXTURE_MAG_FILTER = 0x2800
	GL_TEXTURE_MIN_FILTER = 0x2801
	GL_TEXTURE_WRAP_S = 0x2802
	GL_TEXTURE_WRAP_T = 0x2803
	GL_NEAREST = 0x2600
	GL_LINEAR = 0x2601
	GL_CLAMP_TO_EDGE = 0x812F
	GL_RED = 0x1903
	GL_R8 = 0x8229
	GL_RGBA8 = 0x8058
	GL_UNPACK_ALIGNMENT = 0x0CF5
	GL_PACK_ALIGNMENT = 0x0D05
	GL_STREAM_DRAW = 0x88E0
	GL_REPEAT = 0x2901
	GL_TEXTURE1 = 0x84C1
	GL_TEXTURE2 = 0x84C2
	# glGetIntegerv queries
	GL_VIEWPORT = 0x0BA2
	GL_MAX_TEXTURE_SIZE = 0x0D33
	GL_TEXTURE_BINDING_2D = 0x8069
	GL_CURRENT_PROGRAM = 0x8B8D
	GL_FRAMEBUFFER_BINDING = 0x8CA6
	GL_RENDERBUFFER_BINDING = 0x8CA7
	GL_MAX_RENDERBUFFER_SIZE = 0x84E8
	# framebuffer objects (render-to-texture)
	GL_FRAMEBUFFER = 0x8D40
	GL_READ_FRAMEBUFFER = 0x8CA8
	GL_DRAW_FRAMEBUFFER = 0x8CA9
	GL_RENDERBUFFER = 0x8D41
	GL_COLOR_ATTACHMENT0 = 0x8CE0
	GL_DEPTH_ATTACHMENT = 0x8D00
	GL_STENCIL_ATTACHMENT = 0x8D20
	GL_DEPTH_STENCIL_ATTACHMENT = 0x821A
	GL_DEPTH_COMPONENT16 = 0x81A5
	GL_DEPTH24_STENCIL8 = 0x88F0
	GL_FRAMEBUFFER_COMPLETE = 0x8CD5
	GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT = 0x8CD6
	GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT = 0x8CD7
	GL_FRAMEBUFFER_UNSUPPORTED = 0x8CDD


########################## shader helpers #############################

# Compile one shader from a GLSL source string. Returns the shader id,
# or 0 after printing the compile log to stderr.
int gl_compile_shader(int shader_type, char* source):
	int shader = glCreateShader(shader_type)
	if (shader == 0):
		print_error(c"gl: glCreateShader failed\n")
		return 0
	char** source_ptr = &source
	glShaderSource(shader, 1, source_ptr, 0)
	glCompileShader(shader)
	int32 status = 0
	glGetShaderiv(shader, GL_COMPILE_STATUS, &status)
	if (status == 0):
		char* log = cast(char*, malloc(4096))
		int32 log_length = 0
		glGetShaderInfoLog(shader, 4095, &log_length, log)
		log[log_length] = 0
		print_error(c"gl: shader compile failed:\n")
		print_error(log)
		print_error(c"\n")
		free(log)
		glDeleteShader(shader)
		return 0
	return shader


# Link a vertex + fragment shader pair into a program. Returns the
# program id, or 0 after printing the link log to stderr.
int gl_link_program(int vertex_shader, int fragment_shader):
	int program = glCreateProgram()
	if (program == 0):
		print_error(c"gl: glCreateProgram failed\n")
		return 0
	glAttachShader(program, vertex_shader)
	glAttachShader(program, fragment_shader)
	glLinkProgram(program)
	int32 status = 0
	glGetProgramiv(program, GL_LINK_STATUS, &status)
	if (status == 0):
		char* log = cast(char*, malloc(4096))
		int32 log_length = 0
		glGetProgramInfoLog(program, 4095, &log_length, log)
		log[log_length] = 0
		print_error(c"gl: program link failed:\n")
		print_error(log)
		print_error(c"\n")
		free(log)
		glDeleteProgram(program)
		return 0
	return program


# Build a complete program from two GLSL source strings. The shader
# objects are deleted once linked (the program keeps the binaries).
# Returns the program id, or 0 on any failure.
int gl_create_program(char* vertex_source, char* fragment_source):
	int vertex_shader = gl_compile_shader(GL_VERTEX_SHADER, vertex_source)
	if (vertex_shader == 0): return 0
	int fragment_shader = gl_compile_shader(GL_FRAGMENT_SHADER, fragment_source)
	if (fragment_shader == 0):
		glDeleteShader(vertex_shader)
		return 0
	int program = gl_link_program(vertex_shader, fragment_shader)
	glDeleteShader(vertex_shader)
	glDeleteShader(fragment_shader)
	return program


######################## render-target helpers ########################

# A tightly packed RGBA8 texture (pixels may be 0 for uninitialized
# storage), clamped at the edges, with filter (GL_NEAREST or GL_LINEAR)
# for both minification and magnification. Leaves it bound to
# GL_TEXTURE_2D on the active unit. Returns the texture id.
int gl_texture_rgba(int width, int height, char* pixels, int filter):
	int32 texture = 0
	glGenTextures(1, &texture)
	glBindTexture(GL_TEXTURE_2D, texture)
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
	return texture


# A framebuffer object whose color attachment 0 is level 0 of texture.
# Returns the framebuffer id with it left bound to GL_FRAMEBUFFER, or 0
# (after printing the status to stderr and rebinding the default
# framebuffer) when the driver reports it incomplete.
int gl_framebuffer_for_texture(int texture):
	int32 framebuffer = 0
	glGenFramebuffers(1, &framebuffer)
	glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
	int status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
	if (status != GL_FRAMEBUFFER_COMPLETE):
		print_error(c"gl: framebuffer incomplete, status ")
		print_error(itoa(status))
		print_error(c"\n")
		glBindFramebuffer(GL_FRAMEBUFFER, 0)
		glDeleteFramebuffers(1, &framebuffer)
		return 0
	return framebuffer


# The framebuffer currently bound for drawing (0 = the window's).
int gl_current_framebuffer():
	int32 binding = 0
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &binding)
	return binding


# glIsEnabled as 0/1: GLboolean is one byte, and the C ABI leaves the
# rest of the return register undefined.
int gl_is_enabled(int capability):
	return (glIsEnabled(capability) & 255) != 0
