# wbuild: x64 flags="--import-root tests/import_roots/b --import-root=tests/import_roots/a" expect_stdout="import_root_order_test OK"
/*
tests/import_root_test.w with the import roots swapped (and the second
one in the '--import-root=<dir>' spelling): root b/ is now named first,
so it supplies 'ir_mod'. 'ir_only_b' still comes from b/ and the
per-arch 'ir_pkg.__arch__.ir_arch' from a/, the only root holding it.
*/
import lib.assert
import ir_mod
import ir_only_b
import ir_pkg.__arch__.ir_arch


int main():
	assert_strings_equal(c"b", ir_which())
	assert_equal(42, ir_only_b())
	assert_equal(__word_size__, ir_arch_word())
	println(c"import_root_order_test OK")
	return 0
