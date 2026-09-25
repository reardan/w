/*
graphics.gl_win32: the Windows OpenGL binding -- opengl32.dll plus the
WGL context calls the Win32 window layer (graphics.window_win32) uses.

opengl32.dll exports only the OpenGL 1.1 entry points, so those bind
eagerly through extern like libGL.so.1 on Linux. Everything newer
(buffers, vertex arrays, shaders, glActiveTexture) is reachable only
through wglGetProcAddress once a context is current: each such function
here is a W wrapper with the same name and signature as the Linux
extern, resolving its driver pointer on first call and calling it
through a win_c_function trampoline (lib/__arch__/win64/syscalls.w),
which loads every argument into both its integer and its xmm register
-- that is what lets the float32 glUniform* arguments pass. Identical W
names keep graphics.gl's shader helpers and every consumer unchanged.

Calling one of the wrapped functions with no current context (or on a
driver without it) prints the missing name and exits 1: there is no
sensible GL fallback for a missing shader entry point.

Selected by graphics/__arch__/win64/gl_native.w. Design notes:
docs/projects/graphics.md
*/
import lib.lib


############################# core GL 1.1 #############################

c_lib "opengl32.dll"

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
extern void glDrawArrays(int mode, int first, int count)
extern void glDrawElements(int mode, int count, int index_type, int offset)
extern void glScissor(int x, int y, int width, int height)
extern void glGenTextures(int count, int32* textures)
extern void glDeleteTextures(int count, int32* textures)
extern void glBindTexture(int target, int texture)
extern void glTexImage2D(int target, int level, int internal_format, int width, int height, int border, int format, int pixel_type, char* pixels)
extern void glTexSubImage2D(int target, int level, int x, int y, int width, int height, int format, int pixel_type, char* pixels)
extern void glTexParameteri(int target, int pname, int param)

################################# WGL #################################

extern int wglCreateContext(int dc)
extern int wglDeleteContext(int context)
extern int wglMakeCurrent(int dc, int context)
extern int wglGetProcAddress(char* name)


###################### wglGetProcAddress plumbing #####################

type gl_fn0 = fn() -> int
type gl_fn1 = fn(int) -> int
type gl_fn2 = fn(int, int) -> int
type gl_fn3 = fn(int, int, int) -> int
type gl_fn4 = fn(int, int, int, int) -> int
type gl_fn6 = fn(int, int, int, int, int, int) -> int
type gl_fn_if = fn(int, float32) -> int
type gl_fn_iff = fn(int, float32, float32) -> int
type gl_fn_ifff = fn(int, float32, float32, float32) -> int
type gl_fn_iffff = fn(int, float32, float32, float32, float32) -> int


# The W-callable trampoline for a GL 2+ entry point, created on first use
# and cached in *slot. wglGetProcAddress reports failure as 0 and, on
# some drivers, as 1, 2, 3 or -1.
int gl_win_proc(int* slot, char* name, int nargs):
	if (*slot != 0):
		return *slot
	int sym = wglGetProcAddress(name)
	if ((sym >= -1) && (sym <= 3)):
		print_error(c"graphics.gl: OpenGL entry point unavailable (no current context, or too old a driver): ")
		print_error(name)
		print_error(c"\n")
		exit(1)
	*slot = win_c_function(sym, nargs, 1)
	return *slot


######################## buffers and arrays ###########################

int gl_p_gen_buffers
int gl_p_delete_buffers
int gl_p_bind_buffer
int gl_p_buffer_data
int gl_p_buffer_sub_data
int gl_p_gen_vertex_arrays
int gl_p_bind_vertex_array
int gl_p_enable_vertex_attrib_array
int gl_p_disable_vertex_attrib_array
int gl_p_vertex_attrib_pointer
int gl_p_active_texture


void glGenBuffers(int count, int32* buffers):
	gl_fn2* f = cast(gl_fn2*, gl_win_proc(&gl_p_gen_buffers, c"glGenBuffers", 2))
	f(count, cast(int, buffers))


void glDeleteBuffers(int count, int32* buffers):
	gl_fn2* f = cast(gl_fn2*, gl_win_proc(&gl_p_delete_buffers, c"glDeleteBuffers", 2))
	f(count, cast(int, buffers))


void glBindBuffer(int target, int buffer):
	gl_fn2* f = cast(gl_fn2*, gl_win_proc(&gl_p_bind_buffer, c"glBindBuffer", 2))
	f(target, buffer)


void glBufferData(int target, int size, void* data, int usage):
	gl_fn4* f = cast(gl_fn4*, gl_win_proc(&gl_p_buffer_data, c"glBufferData", 4))
	f(target, size, cast(int, data), usage)


void glBufferSubData(int target, int offset, int size, void* data):
	gl_fn4* f = cast(gl_fn4*, gl_win_proc(&gl_p_buffer_sub_data, c"glBufferSubData", 4))
	f(target, offset, size, cast(int, data))


void glGenVertexArrays(int count, int32* arrays):
	gl_fn2* f = cast(gl_fn2*, gl_win_proc(&gl_p_gen_vertex_arrays, c"glGenVertexArrays", 2))
	f(count, cast(int, arrays))


void glBindVertexArray(int array):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_bind_vertex_array, c"glBindVertexArray", 1))
	f(array)


void glEnableVertexAttribArray(int index):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_enable_vertex_attrib_array, c"glEnableVertexAttribArray", 1))
	f(index)


void glDisableVertexAttribArray(int index):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_disable_vertex_attrib_array, c"glDisableVertexAttribArray", 1))
	f(index)


void glVertexAttribPointer(int index, int size, int attrib_type, int normalized, int stride, int offset):
	gl_fn6* f = cast(gl_fn6*, gl_win_proc(&gl_p_vertex_attrib_pointer, c"glVertexAttribPointer", 6))
	f(index, size, attrib_type, normalized, stride, offset)


############################# textures ################################

void glActiveTexture(int texture_unit):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_active_texture, c"glActiveTexture", 1))
	f(texture_unit)


######################## shaders and programs #########################

int gl_p_create_shader
int gl_p_shader_source
int gl_p_compile_shader
int gl_p_get_shaderiv
int gl_p_get_shader_info_log
int gl_p_delete_shader
int gl_p_create_program
int gl_p_attach_shader
int gl_p_link_program
int gl_p_get_programiv
int gl_p_get_program_info_log
int gl_p_use_program
int gl_p_delete_program
int gl_p_get_attrib_location
int gl_p_get_uniform_location
int gl_p_uniform1i
int gl_p_uniform1f
int gl_p_uniform2f
int gl_p_uniform3f
int gl_p_uniform4f
int gl_p_uniform_matrix4fv


int glCreateShader(int shader_type):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_create_shader, c"glCreateShader", 1))
	return f(shader_type)


void glShaderSource(int shader, int count, char** sources, int32* lengths):
	gl_fn4* f = cast(gl_fn4*, gl_win_proc(&gl_p_shader_source, c"glShaderSource", 4))
	f(shader, count, cast(int, sources), cast(int, lengths))


void glCompileShader(int shader):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_compile_shader, c"glCompileShader", 1))
	f(shader)


void glGetShaderiv(int shader, int pname, int32* params):
	gl_fn3* f = cast(gl_fn3*, gl_win_proc(&gl_p_get_shaderiv, c"glGetShaderiv", 3))
	f(shader, pname, cast(int, params))


void glGetShaderInfoLog(int shader, int max_length, int32* length, char* info_log):
	gl_fn4* f = cast(gl_fn4*, gl_win_proc(&gl_p_get_shader_info_log, c"glGetShaderInfoLog", 4))
	f(shader, max_length, cast(int, length), cast(int, info_log))


void glDeleteShader(int shader):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_delete_shader, c"glDeleteShader", 1))
	f(shader)


int glCreateProgram():
	gl_fn0* f = cast(gl_fn0*, gl_win_proc(&gl_p_create_program, c"glCreateProgram", 0))
	return f()


void glAttachShader(int program, int shader):
	gl_fn2* f = cast(gl_fn2*, gl_win_proc(&gl_p_attach_shader, c"glAttachShader", 2))
	f(program, shader)


void glLinkProgram(int program):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_link_program, c"glLinkProgram", 1))
	f(program)


void glGetProgramiv(int program, int pname, int32* params):
	gl_fn3* f = cast(gl_fn3*, gl_win_proc(&gl_p_get_programiv, c"glGetProgramiv", 3))
	f(program, pname, cast(int, params))


void glGetProgramInfoLog(int program, int max_length, int32* length, char* info_log):
	gl_fn4* f = cast(gl_fn4*, gl_win_proc(&gl_p_get_program_info_log, c"glGetProgramInfoLog", 4))
	f(program, max_length, cast(int, length), cast(int, info_log))


void glUseProgram(int program):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_use_program, c"glUseProgram", 1))
	f(program)


void glDeleteProgram(int program):
	gl_fn1* f = cast(gl_fn1*, gl_win_proc(&gl_p_delete_program, c"glDeleteProgram", 1))
	f(program)


int glGetAttribLocation(int program, char* name):
	gl_fn2* f = cast(gl_fn2*, gl_win_proc(&gl_p_get_attrib_location, c"glGetAttribLocation", 2))
	return f(program, cast(int, name))


int glGetUniformLocation(int program, char* name):
	gl_fn2* f = cast(gl_fn2*, gl_win_proc(&gl_p_get_uniform_location, c"glGetUniformLocation", 2))
	return f(program, cast(int, name))


void glUniform1i(int location, int value):
	gl_fn2* f = cast(gl_fn2*, gl_win_proc(&gl_p_uniform1i, c"glUniform1i", 2))
	f(location, value)


void glUniform1f(int location, float32 value):
	gl_fn_if* f = cast(gl_fn_if*, gl_win_proc(&gl_p_uniform1f, c"glUniform1f", 2))
	f(location, value)


void glUniform2f(int location, float32 x, float32 y):
	gl_fn_iff* f = cast(gl_fn_iff*, gl_win_proc(&gl_p_uniform2f, c"glUniform2f", 3))
	f(location, x, y)


void glUniform3f(int location, float32 x, float32 y, float32 z):
	gl_fn_ifff* f = cast(gl_fn_ifff*, gl_win_proc(&gl_p_uniform3f, c"glUniform3f", 4))
	f(location, x, y, z)


void glUniform4f(int location, float32 x, float32 y, float32 z, float32 w):
	gl_fn_iffff* f = cast(gl_fn_iffff*, gl_win_proc(&gl_p_uniform4f, c"glUniform4f", 5))
	f(location, x, y, z, w)


void glUniformMatrix4fv(int location, int count, int transpose, float32* value):
	gl_fn4* f = cast(gl_fn4*, gl_win_proc(&gl_p_uniform_matrix4fv, c"glUniformMatrix4fv", 4))
	f(location, count, transpose, cast(int, value))
