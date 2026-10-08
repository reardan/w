# wbuild: target=print_wasm_error_test tag=tests_wasm dep=wv2 dep=wrun
# wbuild: step="bin/wv2 wasm tests/print_wasm_error_fixture.w -o bin/print_wasm_error_fixture"
# wbuild: step="bin/wrun wasm bin/print_wasm_error_fixture"
import lib.lib


int wasm_print_calls
int wasm_print_interrupt


int wasm_print_writer(int fd, char* data, int length):
	wasm_print_calls = wasm_print_calls + 1
	if (wasm_print_calls == 1):
		if (wasm_print_interrupt): return -27 # WASI EINTR
		return -4 # WASI EADDRNOTAVAIL; not POSIX EINTR
	return length


int main():
	print_result r
	wasm_print_calls = 0
	wasm_print_interrupt = 0
	if (print_write_using(wasm_print_writer, 1, c"x", 1, &r) != -4): return 1
	if (r.error != 4 || r.transferred != 0 || wasm_print_calls != 1): return 2
	wasm_print_calls = 0
	wasm_print_interrupt = 1
	if (print_write_using(wasm_print_writer, 1, c"x", 1, &r) != 0): return 3
	if (r.error != 0 || r.transferred != 1 || wasm_print_calls != 2): return 4
	return 0
