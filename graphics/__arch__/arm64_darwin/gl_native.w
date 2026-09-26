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


c_lib "/System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL"

# The core-GL externs, bound to the framework above.
import graphics.gl_core
