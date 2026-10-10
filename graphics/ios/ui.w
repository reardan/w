# Experimental native iOS controls. This is a small UIKit bridge, not the
# OpenGL graphics.ui renderer. Handles are stable, one-based integers.
# Call controls only from setup/lifecycle/action callbacks (main thread).
# Callbacks are no-argument W functions, passed through the host's ABI shim.
# wios_text_value borrows UIKit's UTF-8 storage until the field changes.
# Compile with arm64_ios or arm64_ios_sim; package with tools/ios/build.sh.
c_lib "@executable_path/Frameworks/WIOS.framework/WIOS"
extern int wios_run(int argc, int argv, char* title, void* setup, void* lifecycle)
extern int wios_label(char* text)
extern void wios_label_set(int handle, char* text)
extern int wios_button(char* title, void* callback)
extern int wios_text_field(char* label, void* callback)
extern char* wios_text_value(int handle)
# Lifecycle: 0 launching, 1 active, 2 background.
extern int wios_phase()
