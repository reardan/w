/*
graphics.gl: OpenGL enums and shader helpers over the per-target GL
binding (graphics/__arch__/<target>/gl_native.w — libGL.so.1 on the
Linux targets, the OpenGL framework on arm64_darwin). Consumers import
this module only; the platform split stays behind the __arch__ path.

Shaders are plain GLSL source strings compiled at runtime with
gl_create_program — no shader file loader yet, string shaders by design
for now. Portable shader sources take their "#version" line from
gfx_shader_header() (graphics.window): 130 on GLX contexts, 150 on the
Mac's 3.2-core contexts.

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
		char* log = malloc(4096)
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
		char* log = malloc(4096)
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
	if (vertex_shader == 0):
		return 0
	int fragment_shader = gl_compile_shader(GL_FRAGMENT_SHADER, fragment_source)
	if (fragment_shader == 0):
		glDeleteShader(vertex_shader)
		return 0
	int program = gl_link_program(vertex_shader, fragment_shader)
	glDeleteShader(vertex_shader)
	glDeleteShader(fragment_shader)
	return program
