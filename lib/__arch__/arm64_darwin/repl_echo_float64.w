# float64 formatting for the REPL's echo on AArch64: the same
# reinterpret-and-format step as the x64 twin (lib/__arch__/x64/), which
# documents why it lives behind the __arch__ import segment.
import lib.lib
import lib.float64_format


# bits holds the raw IEEE-754 bit pattern of a float64_value_type REPL
# echo result: reinterpret and format it with f64toa.
char* repl_float64_to_string(int bits):
	float64* p = cast(float64*, &bits)
	return f64toa(*p)
