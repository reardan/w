# Source identities must survive multiple registry growths on both word sizes.
# wbuild: x64
import lib.testing
import compiler.compiler


void test_growing_source_file_registry():
	int first = debug_file_count
	for i in range(600):
		char* name = f"registry_fixture/source_{i}.w"
		assert_equal(first + i, debug_line_file_index_of(name))
		# Repeated lookups take the last-file fast path without adding entries.
		assert_equal(first + i, debug_line_file_index_of(name))
		free(name)
	assert_equal(first + 600, debug_file_count)
	# Look up old entries after both growths; names are owned by the registry.
	for i in range(600):
		char* name = f"registry_fixture/source_{i}.w"
		assert_strings_equal(name, debug_file_name(first + i))
		assert_equal(first + i, debug_line_file_index_of(name))
		free(name)
	assert_equal(first + 600, debug_file_count)
	assert_strings_equal(c"", debug_file_name(-1))
	assert_strings_equal(c"", debug_file_name(debug_file_count))
