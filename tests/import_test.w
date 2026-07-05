/*

Long Term how to do these tests:

1) Create Multi-Line String Formatting
	`
	'''
	or just block comments

2) Mock out the filesystem
3) Profit

*/
import lib.testing
import tests.subfolder
import tests.subfolder as sub
import tests.level1.level2.level3.level_file as deep
import tests.import_alias_helper

# Test importing invalid filename
# Test folder does not exist
# Test permission denied
# Test import filename.*
# Test import filename.[file1, file2, file3]
# Test import filename.symbol_name

void test_basic():
	println(c"hello!")

void test_subfolder_function():
	assert_equal(1337, subfolder_value())

# Qualified access through an import alias resolves the module's symbols.
void test_alias_qualified_call():
	assert_equal(1337, sub.subfolder_value())

# Globals are readable and writable through an alias.
void test_alias_global_access():
	deep.level_file_variable = 42
	assert_equal(42, deep.level_file_variable)

# Aliases are file-scoped: the helper module binds its own alias without
# leaking it here, and qualified access inside it works.
void test_alias_in_imported_module():
	assert_equal(1337, helper_qualified_value())

