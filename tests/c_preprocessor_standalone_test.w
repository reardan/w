# The C preprocessor is also linked into standalone tools (w-private's
# c_to_w) without the compiler: its import closure must not pull in the
# code emitter, whose optimizer hooks are only defined by the grammar.
import lib.testing


# Standalone users supply the compiler's diagnostic interface (as c_to_w does).
void diag_part(char* s):
	print_error(s)


void error(char* s):
	print_error(s)
	print_error(c"\n")
	exit(1)


import libs.extras.c_preprocessor.pp_init


void test_predefined_macros_without_the_compiler():
	map[char*, cpp_macro*] macros = new map[char*, cpp_macro*]
	cpp_init_predefined_macros(macros)
	asserts(c"__STDC__ predefined", c"__STDC__" in macros)
	asserts(c"__SIZEOF_POINTER__ predefined", c"__SIZEOF_POINTER__" in macros)
	assert_equal(__word_size__, cpp_target_word_size())
