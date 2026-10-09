# wbuild: step="cat" stdin="import" stdout_file="bin/import_eof_fixture.w"
# wbuild: step="bin/wv2 bin/import_eof_fixture.w -o bin/import_eof_fixture" expect_fail expect_stderr="module name expected after 'import'" timeout=20000
# wbuild: step="cat" stdin="import lib.lib" stdout_file="bin/import_eof_named_fixture.w"
# wbuild: step="bin/wv2 bin/import_eof_named_fixture.w -o bin/import_eof_named_fixture" timeout=20000
# wbuild: x64 flags="--import-root tests/import_roots/a --import-root tests/import_roots/b" expect_stdout="import_root_test OK"
/*
Explicit ordered import roots (--import-root, compiler/compiler.w;
docs/projects/compilation_model.md "Import roots"), compiled through the
ordinary generated compile+run target, so wexec's deps-driven cache key
and wtest's closure selection both see the roots on the step command
line. 'ir_mod' exists in both roots and root a/ is named first;
'ir_only_b' exists only in root b/; 'ir_pkg.__arch__.ir_arch' resolves
per target inside root a/ (the x64 twin gets the x64 copy).
tests/import_root_order_test.w is the same program with the roots
swapped; tools/import_root_e2e.w covers check/deps/symbols, other
working directories and the error paths.
*/
import lib.assert
import ir_mod
import ir_only_b
import ir_pkg.__arch__.ir_arch


int main():
	assert_strings_equal(c"a", ir_which())
	assert_equal(42, ir_only_b())
	assert_equal(__word_size__, ir_arch_word())
	println(c"import_root_test OK")
	return 0
