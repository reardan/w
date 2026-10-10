# Mobile browser form: serve the repo and open
# /tools/web/?module=/bin/graphics_ui_mobile.wasm on a phone.
import lib.lib
import graphics.window
import graphics.ui.mobile_demo_shared


gfx_window* mobile_win
ui_renderer* mobile_renderer
ui_context* mobile_ctx
ui_mobile_demo_state* mobile_state


int mobile_frame():
	if (gfx_window_poll(mobile_win) == 0): return 0
	ui_begin_window(mobile_ctx, mobile_win)
	ui_mobile_demo_body(mobile_ctx, mobile_state)
	ui_end(mobile_ctx)
	gfx_window_swap(mobile_win)
	return 1


int main():
	# The browser clamps this ceiling to the live phone viewport; the
	# shared form also caps its own readable width on tablets/desktop.
	mobile_win = gfx_window_open(c"W mobile form", 720, 720)
	if (mobile_win == 0): return 1
	mobile_renderer = new ui_renderer()
	if (ui_render_init(mobile_renderer) == 0): return 1
	mobile_state = new ui_mobile_demo_state()
	ui_mobile_demo_init(mobile_state)
	mobile_ctx = new ui_context()
	ui_context_init(mobile_ctx, mobile_renderer, &mobile_state.theme)
	gfx_window_run(mobile_win, mobile_frame)
	return 0


# wbuild: target=graphics_ui_mobile_web dep=wv2 dep=ui_font_data
# wbuild: step="bin/wv2 wasm graphics/ui/mobile_demo_web.w -o bin/graphics_ui_mobile.wasm"

# wbuild: target=wasm_mobile_ui_test tag=tests_wasm dep=graphics_ui_mobile_web dep=wrun
# wbuild: step="bin/wrun node tools/web/run_mobile_ui.mjs bin/graphics_ui_mobile.wasm" expect_stdout="run_mobile_ui OK"
