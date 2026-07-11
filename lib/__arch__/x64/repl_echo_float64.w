# float64 formatting for the REPL's echo (D2, docs/projects/repl_improvements.md).
#
# float64 requires the x64 target (grammar/type_name.w rejects the type
# name otherwise), so repl.w itself can never spell "float64" and still
# compile for x86 -- the reinterpret-and-format step lives here instead,
# resolved in only for x64 builds through the reserved __arch__ import
# segment. See the x86 twin in lib/__arch__/x86/ for why it is a stub
# there.
import lib.lib
import lib.float64_format


# bits holds the raw IEEE-754 bit pattern of a float64_value_type REPL
# echo result (see promote()'s "value" pseudo-types in
# compiler/type_table.w): reinterpret and format it with f64toa.
char* repl_float64_to_string(int bits):
	float64* p = cast(float64*, &bits)
	return f64toa(*p)
