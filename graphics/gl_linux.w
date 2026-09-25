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

# The core-GL externs, bound to libGL.so.1 by the c_lib line above.
import graphics.gl_core
