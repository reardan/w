# x86 twin of lib/__arch__/x64/repl_echo_float64.w.
#
# repl_echo never calls this on the 32-bit target: float64_value_type
# (compiler/type_table.w) can only be produced when word_size == 8, since
# grammar/type_name.w rejects the "float64" type name otherwise. This
# stub exists only so repl.w's "import lib.__arch__.repl_echo_float64"
# resolves on both targets; see the x64 twin for the real implementation.
char* repl_float64_to_string(int bits):
	return c"0.000000"
