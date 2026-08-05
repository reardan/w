# expect_fail
# expect_stderr: exported function parameters must be single words
# Compiled with 'wv2 wasm' by the wasm_export_test target: a by-value
# struct parameter spans several stack words, which a typed wasm export
# cannot express (pass a pointer instead).
import lib.lib

struct pair:
	int a
	int b

export int pair_sum(pair p):
	return p.a + p.b

int main(int argc, int argv):
	pair p
	p.a = 1
	p.b = 2
	return pair_sum(p)
