# expect_fail
# expect_stderr: exported function 'missing' is never defined
# Compiled with 'wv2 wasm' by the wasm_export_test target: 'export' on a
# bare prototype registers the name, but the export wrapper needs a
# defined body by the end of the compile.
import lib.lib

export int missing(int a);

int main(int argc, int argv):
	return 0
