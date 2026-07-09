/*
graphics.gl: OpenGL + GLX bindings and shader helpers.

Links libGL.so.1 (which also exports the glX entry points) via the
extern/c_lib FFI. Shaders are plain GLSL source strings compiled at
runtime with gl_create_program — no shader file loader yet, string
shaders by design for now.

64-bit only in practice: the host ships a 64-bit libGL, and the
windowing layer (graphics.window) relies on x86_64 Xlib struct layouts.
Compile consumers with 'wv2 x64'.

GL handles (GLuint) and GLX handles (GLXContext, XVisualInfo*) travel
as word-sized W ints. GLint out-parameters are int32*.

Design notes: docs/projects/graphics.md
*/
import lib.lib
import graphics.x11


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


# GLX visual attributes (glx.h)
enum glx_attribute:
	GLX_RGBA = 4
	GLX_DOUBLEBUFFER = 5
	GLX_RED_SIZE = 8
	GLX_GREEN_SIZE = 9
	GLX_BLUE_SIZE = 10
	GLX_DEPTH_SIZE = 12


########################### GLX context ###############################

c_lib "libGL.so.1"

extern x_visual_info* glXChooseVisual(int display, int screen, int32* attrib_list)
extern int glXCreateContext(int display, x_visual_info* visual, int share_list, int direct)
extern int glXDestroyContext(int display, int context)
extern int glXMakeCurrent(int display, int drawable, int context)
extern int glXSwapBuffers(int display, int drawable)

############################# core GL #################################

extern void glViewport(int x, int y, int width, int height)
extern void glClearColor(float32 red, float32 green, float32 blue, float32 alpha)
extern void glClear(int mask)
extern void glEnable(int capability)
extern void glDisable(int capability)
extern void glBlendFunc(int source_factor, int dest_factor)
extern char* glGetString(int name)
extern int glGetError()
extern void glFinish()
extern void glReadPixels(int x, int y, int width, int height, int format, int pixel_type, char* pixels)
extern void glPixelStorei(int pname, int param)

######################## buffers and arrays ###########################

extern void glGenBuffers(int count, int32* buffers)
extern void glDeleteBuffers(int count, int32* buffers)
extern void glBindBuffer(int target, int buffer)
extern void glBufferData(int target, int size, void* data, int usage)
extern void glGenVertexArrays(int count, int32* arrays)
extern void glBindVertexArray(int array)
extern void glEnableVertexAttribArray(int index)
extern void glDisableVertexAttribArray(int index)
extern void glVertexAttribPointer(int index, int size, int attrib_type, int normalized, int stride, int offset)
extern void glDrawArrays(int mode, int first, int count)
extern void glDrawElements(int mode, int count, int index_type, int offset)

######################## shaders and programs #########################

extern int glCreateShader(int shader_type)
extern void glShaderSource(int shader, int count, char** sources, int32* lengths)
extern void glCompileShader(int shader)
extern void glGetShaderiv(int shader, int pname, int32* params)
extern void glGetShaderInfoLog(int shader, int max_length, int32* length, char* info_log)
extern void glDeleteShader(int shader)
extern int glCreateProgram()
extern void glAttachShader(int program, int shader)
extern void glLinkProgram(int program)
extern void glGetProgramiv(int program, int pname, int32* params)
extern void glGetProgramInfoLog(int program, int max_length, int32* length, char* info_log)
extern void glUseProgram(int program)
extern void glDeleteProgram(int program)
extern int glGetAttribLocation(int program, char* name)
extern int glGetUniformLocation(int program, char* name)
extern void glUniform1i(int location, int value)
extern void glUniform1f(int location, float32 value)
extern void glUniform2f(int location, float32 x, float32 y)
extern void glUniform3f(int location, float32 x, float32 y, float32 z)
extern void glUniform4f(int location, float32 x, float32 y, float32 z, float32 w)
extern void glUniformMatrix4fv(int location, int count, int transpose, float32* value)

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
