# expect_fail
# expect_stderr: c_import is not supported on the wasm target
# Compiled with 'wv2 wasm' by the wasm_extern_test target: c_import binds
# whole shared-library headers through the native ABI shims, which do not
# exist on wasm (extern against a host module is the import path).
import lib.lib

c_import "libc.so.6" "stdio.h"

int main(int argc, int argv):
	return 0
