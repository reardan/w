/*
structures.json_float64_stub: 4-byte-word twin of
structures/json_float64_impl.w, shared by the x86 and wasm
structures/__arch__/<arch>/json_float64.w selectors.

float64 is a compile error on these targets and structures/json.w
never sets has_float64 there (json_parse_number guards the wide path
with __word_size__ == 8, and the compiler rejects float64 codec fields
outside 8-byte words), so these bodies are unreachable in practice:
they exist so json.w's 'import structures.__arch__.json_float64'
resolves on every target, the same way
lib/__arch__/x86/repl_echo_float64.w stubs its x64 twin. A caller that
does hand a 4-byte-word json_value float64 bits gets a value that
degrades to 0.0.
*/
import lib.lib
import structures.string


int json_f64_from_decimal(int mant, int exp10, int negative):
	return 0


int json_f64_from_float32(float f):
	return 0


int json_f64_from_int(int v):
	return 0


float json_f64_to_float32(int bits):
	return 0.0


void json_f64_append(string_builder* out, int bits):
	string_append(out, c"0.0")
