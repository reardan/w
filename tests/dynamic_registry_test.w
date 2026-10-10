# Host pointers must survive when a 64-bit compiler targets wasm32/x86.
# wbuild: x64
import lib.lib
import lib.assert


void error(char* message):
	println2(message)
	exit(1)


import code_generator.dynamic_registry


int main():
	word_size = 4
	dyn_add_lib(c"env")
	dyn_add_lib(c"second")
	assert1(strcmp(dyn_lib_name(0), c"env") == 0)
	assert1(strcmp(dyn_lib_name(1), c"second") == 0)
	int first = dyn_add_import(c"gfx_host_canvas_init", 1234)
	int second = dyn_add_import_weak(c"gfx_host_next_event", 5678)
	assert1(first == 0)
	assert1(second == 1)
	assert1(strcmp(dyn_import_name(first), c"gfx_host_canvas_init") == 0)
	assert1(strcmp(dyn_import_name(second), c"gfx_host_next_event") == 0)
	assert1(dyn_import_got_vaddr(first) == 1234)
	assert1(dyn_import_got_vaddr(second) == 5678)
	assert1(dyn_import_get_lib(first) == 1)
	assert1(dyn_import_get_binding(second) == 2)
	return 0
