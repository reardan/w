# Manual interpreter benchmark, from the W repository root:
# ./wbuild graphics_ui_mobile_web
# bin/wv2 x64 tests/wasm_mobile_bench.w -o bin/wasm_mobile_bench
# taskset -c 0 bin/wasm_mobile_bench
# Uses the unchanged mobile Wasm with deterministic host stubs. This measures
# interpreter CPU/fuel, not actual browser rendering or native GL throughput.
# The explicit 200M benchmark allowance does not change any runtime default.
import libs.extras.wasm.runtime
import lib.file
import lib.assert
import lib.time

# Linux thread CPU time excludes unrelated load on other cores.
int wasm_bench_cpu_us():
	int[2] stamp
	if (sys_clock_gettime(3, cast(int, &stamp[0])) != 0): return time_monotonic_ms() * 1000
	return stamp[0] * 1000000 + stamp[1] / 1000


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
	if (strcmp(name, c"glGenBuffers") == 0 || strcmp(name, c"glGenTextures") == 0): probe_store(m, args[1], 1)
	if (strcmp(name, c"gfx_host_set_frame_callback") == 0): frame_callback = args[0]
	if (strcmp(name, c"gfx_host_poll_state") == 0):
		probe_store(m, args[0], 640)
		probe_store(m, args[0] + 4, 480)
	if (strcmp(name, c"glDrawArrays") == 0):
		draw_count = draw_count + 1
	if (strcmp(name, c"glBufferData") == 0): buffer_bytes = args[1]
	if (strcmp(name, c"glShaderSource") == 0): shader_count = shader_count + 1
	return 0

int main():
	char* bytes = file_read_text(c"bin/graphics_ui_mobile.wasm")
	int fd = open(c"bin/graphics_ui_mobile.wasm", 0, 0)
	int length = file_size(fd)
	close(fd)
	wwasm* m = wwasm_load_bounded(bytes, length, 4194304, 1048576)
	if (m.error != 0):
		print(m.error)
		print(c"\n")
		return 1
	for i in range(m.imports):
		wwasm_function* f = m.functions[i]
		f.context = f
		f.callback = cast(int, probe_host)
	list[int] args = new list[int]
	int begin = wasm_bench_cpu_us()
	wwasm_call(m, wwasm_find_export(m, c"_start").index, args, 200000000)
	print_int(c"startup_us=", wasm_bench_cpu_us() - begin)
	print_int(c"startup_fuel=", 200000000 - m.fuel)
	if (m.error != 0):
		print(m.error)
		print(c"\n")
		return 1
	assert1(frame_callback > 0)
	for i in range(11):
		begin = wasm_bench_cpu_us()
		wwasm_call(m, m.table[frame_callback], args, 200000000)
		print_int(c"frame_us=", wasm_bench_cpu_us() - begin)
		print_int(c"frame_fuel=", 200000000 - m.fuel)
		if (m.error != 0):
			print(m.error)
			print(c"\n")
			return 1
	int digest = 0
	for i in range(m.pages * 65536): digest = ((digest * 33) ^ (m.memory[i] & 255)) & 0x7fffffff
	print_int(c"memory_digest=", digest)
	print_int(c"draw_count=", draw_count)
	print_int(c"shader_count=", shader_count)
	__w_list_free(cast(__w_list*, args))
	wwasm_free(m)
	free(bytes)
	return 0
