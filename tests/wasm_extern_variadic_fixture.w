# expect_fail
# expect_stderr: variadic extern functions are not supported on the wasm target
# Compiled with 'wv2 wasm' by the wasm_extern_test target: a variadic C
# import has no wasm lowering (imports carry fixed typed signatures).
import lib.lib

c_lib "env"

extern int host_printf(char* fmt, ...)

int main(int argc, int argv):
	return host_printf(c"x")
