import lib.testing
import tests.level1.level2.level3.level_file


void test_deep_import():
	level_file_variable = 42
	assert_equal(42, level_file_variable)
