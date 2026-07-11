# Per-target window backend selector: this target draws to a browser
# canvas through host imports (see graphics/window_web.w for the
# frame-callback contract that replaces the blocking render loop).
import graphics.window_web
