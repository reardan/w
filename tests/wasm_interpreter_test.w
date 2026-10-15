# wbuild: target=wasm_interpreter_test tag=tests dep=wv2
# wbuild: step="bin/wv2 wasm graphics/demo_web.w -o bin/wasm_interpreter_demo.wasm"
# wbuild: step="bin/wv2 x64 tests/wasm_interpreter_test.w -o bin/wasm_interpreter_test"
# wbuild: step="bin/wasm_interpreter_test" expect_stdout="graphics demo: 3 frames OK"
import libs.extras.wasm.runtime
import lib.file
import lib.assert

int frame_callback
int draw_count
int shader_count
int buffer_bytes

void probe_store(wwasm* m, int address, int value):
	assert1(address >= 0 && address <= m.pages * 65536 - 4)
	for j in range(4): m.memory[address + j] = (value >> (8 * j)) & 255

int probe_host(void* context, wwasm* m, list[int] args):
	wwasm_function* f = cast(wwasm_function*, context)
	char* name = f.name
	if (strcmp(name, c"args_sizes_get") == 0 || strcmp(name, c"environ_sizes_get") == 0):
		probe_store(m, args[0], 0)
		probe_store(m, args[1], 0)
	if (strcmp(name, c"gfx_host_canvas_init") == 0): return 1
	if (strcmp(name, c"glCreateShader") == 0 || strcmp(name, c"glCreateProgram") == 0): return 1
	if (strcmp(name, c"glGetShaderiv") == 0 || strcmp(name, c"glGetProgramiv") == 0): probe_store(m, args[2], 1)
	if (strcmp(name, c"glGenBuffers") == 0): probe_store(m, args[1], 1)
	if (strcmp(name, c"gfx_host_set_frame_callback") == 0): frame_callback = args[0]
	if (strcmp(name, c"gfx_host_poll_state") == 0):
		probe_store(m, args[0], 640)
		probe_store(m, args[0] + 4, 480)
	if (strcmp(name, c"glDrawArrays") == 0):
		assert_equal(4, args[0])
		assert_equal(0, args[1])
		assert_equal(3, args[2])
		draw_count = draw_count + 1
	if (strcmp(name, c"glBufferData") == 0): buffer_bytes = args[1]
	if (strcmp(name, c"glShaderSource") == 0): shader_count = shader_count + 1
	return 0

int main():
	char* bytes = file_read_text(c"bin/wasm_interpreter_demo.wasm")
	int fd = open(c"bin/wasm_interpreter_demo.wasm", 0, 0)
	int length = file_size(fd)
	close(fd)
	wwasm* m = wwasm_load(bytes, length)
	if (m.error != 0):
		print(m.error)
		print(c"\n")
		return 1
	for i in range(m.imports):
		wwasm_function* f = m.functions[i]
		f.context = f
		f.callback = cast(int, probe_host)
	list[int] args = new list[int]
	wwasm_call(m, wwasm_find_export(m, c"_start").index, args, 1000000)
	if (m.error != 0):
		print(m.error)
		print(c"\n")
		return 1
	assert1(frame_callback > 0)
	for i in range(3):
		wwasm_call(m, m.table[frame_callback], args, 1000000)
		if (m.error != 0):
			print(m.error)
			print(c"\n")
			return 1
	assert_equal(3, draw_count)
	assert_equal(2, shader_count)
	assert_equal(60, buffer_bytes)
	print(c"graphics demo: 3 frames OK\n")
	__w_list_free(cast(__w_list*, args))
	wwasm_free(m)
	free(bytes)
	return 0
