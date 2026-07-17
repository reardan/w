/*
graphics.gl_web: the WebGL binding for the wasm target — the same core-GL
extern surface as graphics/gl_linux.w (minus GLX), imported from the
"env" module and implemented by the JS host glue (tools/web/webgl_env.mjs)
over a WebGL2 canvas context.

Selected by graphics/__arch__/wasm/gl_native.w; graphics.gl re-exports it
together with the enums and shader helpers, so consumers keep importing
graphics.gl only.

Handles (GLuint) travel as word-sized W ints: WebGL object handles are
JS objects, so the glue keeps a handle table mapping these ints to the
underlying WebGLBuffer/WebGLShader/... instances. Pointers are linear
memory offsets the glue resolves against the module's exported memory;
glGetString copies its result into the reserved low-page scratch region
(see tools/web/webgl_env.mjs) and returns its address.

Design notes: docs/projects/wasm_webgl.md
*/
import lib.lib


c_lib "env"

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
