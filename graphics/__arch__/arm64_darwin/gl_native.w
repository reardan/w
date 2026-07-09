/*
graphics.__arch__.arm64_darwin.gl_native: macOS OpenGL binding.

The OpenGL framework serves the same core-GL entry points libGL.so.1
does on Linux (macOS caps the core profile at GL 4.1, plenty for this
module); only the five glX context calls have no counterpart here —
contexts come from NSOpenGLContext (graphics.window_cocoa). Identical W
names, so the shader helpers and every consumer compile unchanged.

The framework binary lives in the dyld shared cache, not on disk; dyld
resolves the install path all the same.
*/
import lib.lib


############################# core GL #################################

c_lib "/System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL"

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
