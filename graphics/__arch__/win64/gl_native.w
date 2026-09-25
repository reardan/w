# Per-target GL binding selector: this target binds opengl32.dll and
# resolves the GL 2+ entry points through wglGetProcAddress (see
# graphics/gl_win32.w; the Linux targets use graphics/gl_linux.w).
import graphics.gl_win32
