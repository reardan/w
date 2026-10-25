# Opt-in NSTextInputClient bridge for graphics.window_cocoa: dead keys,
# the Character Viewer and input methods compose on macOS. Build the
# companion with tools/mac/build_text_input.sh (it must sit beside the
# executable) and call gfx_cocoa_text_input_enable after gfx_window_open.
# Committed text arrives as GFX_EVENT_CHAR, marked text as the
# PREEDIT_BEGIN/TEXT/END snapshot stream; keys the input system returns
# as commands (arrows, Return, Backspace, Ctrl chords) keep the window's
# own CHAR/NAV translation. See docs/projects/text_input.md.
import graphics.window_cocoa

c_lib "@executable_path/libwtextinput.dylib"
extern int w_textin_open(int view)
extern int w_textin_key(int bridge, int event)
extern int w_textin_next(int bridge, int* code)
extern void w_textin_focus(int bridge, int focus, float64 x, float64 y, float64 width, float64 height)
extern void w_textin_close(int bridge)

# Queue entry kinds from graphics/ui/native/text_input.m.
const int GFX_COCOA_TEXTIN_COMMIT = 1
const int GFX_COCOA_TEXTIN_PREEDIT_BEGIN = 2
const int GFX_COCOA_TEXTIN_PREEDIT_TEXT = 3
const int GFX_COCOA_TEXTIN_PREEDIT_END = 4


# Queue one bridge entry as window events for field focus. Commits keep
# the key's modifiers so Option-typed characters still insert.
void gfx_cocoa_text_input_event(gfx_window* win, int kind, int code, int mods):
	if (kind == GFX_COCOA_TEXTIN_COMMIT):
		gfx_cocoa_push(win, GFX_EVENT_CHAR, code, mods & (GFX_MOD_SHIFT | GFX_MOD_ALT))
	else if (kind == GFX_COCOA_TEXTIN_PREEDIT_BEGIN):
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_BEGIN, 0, win.text_focus, code, 0)
	else if (kind == GFX_COCOA_TEXTIN_PREEDIT_TEXT):
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_TEXT, code, win.text_focus, 0, 0)
	else if (kind == GFX_COCOA_TEXTIN_PREEDIT_END):
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_END, 0, win.text_focus, 0, 0)


void gfx_cocoa_text_input_drain(gfx_window* win, int mods):
	int code = 0
	while (1):
		int kind = w_textin_next(win.text_bridge, &code)
		if (kind == 0): break
		gfx_cocoa_text_input_event(win, kind, code, mods)


int gfx_cocoa_text_input_key(void* window, int event, int mods):
	gfx_window* win = cast(gfx_window*, window)
	if ((win.text_bridge == 0) || (win.text_focus == 0)): return 0
	int handled = w_textin_key(win.text_bridge, event)
	gfx_cocoa_text_input_drain(win, mods)
	return handled


void gfx_cocoa_text_input_focus(void* window, int focus, int multiline, int x, int y, int width, int height):
	gfx_window* win = cast(gfx_window*, window)
	if (win.text_bridge == 0): return
	w_textin_focus(win.text_bridge, focus, cast(float64, x), cast(float64, y), cast(float64, width), cast(float64, height))
	gfx_cocoa_text_input_drain(win, 0)


# Install the bridge on win. Returns 1 once installed (or already), 0
# when the companion could not attach to the window's content view.
int gfx_cocoa_text_input_enable(gfx_window* win):
	if (win == 0): return 0
	if (win.text_bridge != 0): return 1
	int view = objc_msg0(win.window, sel_registerName(c"contentView"))
	win.text_bridge = w_textin_open(view)
	if (win.text_bridge == 0): return 0
	win.key_hook = gfx_cocoa_text_input_key
	win.focus_hook = gfx_cocoa_text_input_focus
	w_textin_focus(win.text_bridge, win.text_focus, 0.0, 0.0, 0.0, 0.0)
	return 1


# Remove the bridge before gfx_window_destroy; the window keeps its own
# key translation afterwards.
void gfx_cocoa_text_input_disable(gfx_window* win):
	if ((win == 0) || (win.text_bridge == 0)): return
	win.key_hook = cast(gfx_cocoa_key_hook*, 0)
	win.focus_hook = cast(gfx_cocoa_focus_hook*, 0)
	w_textin_close(win.text_bridge)
	win.text_bridge = 0
