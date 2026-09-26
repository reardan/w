/*
graphics.gl_core: the core-GL extern surface shared by every binding that
links GL entry points by name -- graphics/gl_linux.w (libGL.so.1),
graphics/gl_web.w (the wasm "env" host glue) and
graphics/__arch__/arm64_darwin/gl_native.w (OpenGL.framework).

Deliberately declares no c_lib and imports nothing: each binding writes
its own c_lib line and imports this module directly after it, so every
extern here binds to that library (the wasm import module, the Mach-O
dylib ordinal). Never import it from anywhere else. graphics/gl_win32.w
resolves most entry points through wglGetProcAddress instead and keeps
its own declarations.
*/


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
extern void glBufferSubData(int target, int offset, int size, void* data)
extern void glGenVertexArrays(int count, int32* arrays)
extern void glBindVertexArray(int array)
extern void glEnableVertexAttribArray(int index)
extern void glDisableVertexAttribArray(int index)
extern void glVertexAttribPointer(int index, int size, int attrib_type, int normalized, int stride, int offset)
extern void glDrawArrays(int mode, int first, int count)
extern void glDrawElements(int mode, int count, int index_type, int offset)
extern void glScissor(int x, int y, int width, int height)

############################# textures ################################

extern void glGenTextures(int count, int32* textures)
extern void glDeleteTextures(int count, int32* textures)
extern void glBindTexture(int target, int texture)
# 9 arguments: one past the 8 AAPCS64 integer registers — the case the
# arm64_darwin single-spill FFI relaxation exists for (code_generator/
# ffi.w, emit_c_abi_call_arm64).
extern void glTexImage2D(int target, int level, int internal_format, int width, int height, int border, int format, int pixel_type, char* pixels)
extern void glTexSubImage2D(int target, int level, int x, int y, int width, int height, int format, int pixel_type, char* pixels)
extern void glTexParameteri(int target, int pname, int param)
extern void glActiveTexture(int texture_unit)

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
