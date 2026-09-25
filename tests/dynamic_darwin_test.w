# Darwin dynamic-linking smoke test: bind libSystem functions through
# extern declarations and check one against the equivalent raw BSD
# syscall. Cross-compiled as arm64_darwin on Linux, signed and executed
# natively on the Mac by tools/mac/run_darwin_tests.sh.

c_lib "/usr/lib/libSystem.B.dylib"

# getppid rather than getpid: the runtime's syscall wrappers (auto-imported
# into every program) already define getpid, which would clash with the
# libSystem extern of the same name.
extern int getppid()
extern int puts(char* s)
# The entry stub exits with a raw syscall, bypassing libSystem's atexit
# flush, so buffered stdout must be flushed explicitly.
extern int fflush(int stream)


# BSD getppid is syscall 39 (xnu bsd/kern/syscalls.master).
int raw_getppid():
	return syscall(39, 0, 0, 0)


int _main():
	int libc_pid = getppid()
	int raw_pid = raw_getppid()

	int rc = 0
	if (libc_pid != raw_pid):
		puts(c"FAIL: libSystem getppid disagrees with the raw syscall")
		rc = 1
	else:
		puts(c"darwin dynamic linking OK")

	fflush(0)
	return rc
# wbuild: target=graphics_darwin tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64_darwin tests/dynamic_darwin_test.w -o bin/dynamic_darwin_test"
# wbuild: step="bin/wv2 arm64_darwin graphics/gl_smoke_test.w -o bin/graphics_gl_smoke_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/gl_texture_test.w -o bin/graphics_gl_texture_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/render_test.w -o bin/graphics_ui_render_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets_test.w -o bin/graphics_ui_widgets_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/clip_test.w -o bin/graphics_ui_clip_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/layout_test.w -o bin/graphics_ui_layout_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/overlay_test.w -o bin/graphics_ui_overlay_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/scroll_test.w -o bin/graphics_ui_scroll_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/buffer_test.w -o bin/graphics_ui_buffer_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/modal_test.w -o bin/graphics_ui_modal_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/table_test.w -o bin/graphics_ui_table_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/textarea_test.w -o bin/graphics_ui_textarea_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/splitter_test.w -o bin/graphics_ui_splitter_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/tree_test.w -o bin/graphics_ui_tree_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/tabs_test.w -o bin/graphics_ui_tabs_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/popover_test.w -o bin/graphics_ui_popover_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/menu_test.w -o bin/graphics_ui_menu_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/toast_test.w -o bin/graphics_ui_toast_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/form_test.w -o bin/graphics_ui_form_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/chips_test.w -o bin/graphics_ui_chips_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/email_test.w -o bin/graphics_ui_email_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/dropdown_multi_test.w -o bin/graphics_ui_dropdown_multi_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/dropdown_search_test.w -o bin/graphics_ui_dropdown_search_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/calendar_test.w -o bin/graphics_ui_calendar_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/date_picker_test.w -o bin/graphics_ui_date_picker_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/widgets/time_picker_test.w -o bin/graphics_ui_time_picker_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/smoke_test.w -o bin/graphics_ui_smoke_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/ui/demo.w -o bin/graphics_ui_demo_darwin"
# wbuild: step="bin/wv2 arm64_darwin graphics/demo.w -o bin/graphics_demo_darwin"
