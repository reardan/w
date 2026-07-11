# expect_fail
# expect_stderr: extern data objects are not supported on the wasm target
# Compiled with 'wv2 wasm' by the wasm_extern_test target: there is no
# loader and no COPY relocation to fill an imported data object.
import lib.lib

c_lib "env"

extern void* host_stdout

int main(int argc, int argv):
	return cast(int, host_stdout)
