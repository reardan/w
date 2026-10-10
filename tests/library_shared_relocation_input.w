# A non-W host loads this image; no executable startup function runs.
import lib.lib
import lib.utf8

int[3] shared_items
struct shared_record:
	int[2] items
shared_record shared_rec
int shared_started = 10

int shared_forward(int n);
type shared_callback = fn(int) -> int


int main():
	shared_started = 999
	return 0


export int shared_relocation_value():
	shared_items[2] = 73
	shared_rec.items[1] = 19
	shared_callback* callback = shared_forward
	return callback(shared_items[2] + shared_rec.items[1])


export char* shared_utf8():
	string text = "shared UTF-8: λ"
	return cstr(text)


export int shared_startup_state():
	return shared_started


export void shared_set_state(int n):
	shared_started = n


# These names are reserved only by wasm modules, not ELF shared objects.
export int ax():
	return 17


int shared_forward(int n):
	return n + 1

# wbuild: library=shared_relocation kind=shared arch=x64
# wbuild: target=library_shared_host_test tag=tests dep=shared_relocation input=tests/library_shared_host_test.py
# wbuild: step="python3 tests/library_shared_host_test.py bin/libshared_relocation.so" expect_stdout="shared host relocations OK"
# wbuild: step="bin/wv2 x64 --shared tests/extern_data_test.w -o bin/library_shared_bad_data.so" expect_fail expect_stderr="--shared does not support extern data"
# wbuild: step="bin/wv2 x64 --shared tests/wasm_export_undefined_fixture.w -o bin/library_shared_bad_export.so" expect_fail expect_stderr="exported function 'missing' is never defined"
# wbuild: step="bin/wv2 x64 --shared tests/wasm_export_variadic_fixture.w -o bin/library_shared_bad_variadic.so" expect_fail expect_stderr="cannot export a variadic function"
# wbuild: step="bin/wv2 x64 --shared tests/wasm_export_struct_fixture.w -o bin/library_shared_bad_struct.so" expect_fail expect_stderr="exported function parameters must be single words"
