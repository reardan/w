/*
graphics.gl_linux: the Linux OpenGL binding — libGL.so.1 via extern/c_lib,
which also exports the GLX entry points the X11 window layer uses.

Selected by graphics/__arch__/<target>/gl_native.w for the Linux targets;
graphics.gl re-exports it together with the enums and shader helpers, so
consumers keep importing graphics.gl only.

GL handles (GLuint) and GLX handles (GLXContext, XVisualInfo*) travel
as word-sized W ints. GLint out-parameters are int32*.

Design notes: docs/projects/graphics.md
*/
import lib.lib
import graphics.x11


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
