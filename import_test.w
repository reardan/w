/*

Long Term how to do these tests:

1) Create Multi-Line String Formatting
	`
	'''
	or just block comments

2) Mock out the filesystem
3) Profit

*/
import testing
import tests.subfolder

# Test multiple of the same import
# Test importing invalid filename
# Test folder does not exist
# Test permission denied
# Test import filename.*
# Test import filename.[file1, file2, file3]
# Test import filename.symbol_name

void test_basic():
	println("hello!")

void test_subfolder_function():
	assert_equal(1337, subfolder_value())

