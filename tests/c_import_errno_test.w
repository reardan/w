import lib.testing

c_import "libc.so.6" c"/usr/include/errno.h"


void test_c_import_errno_constants():
	assert_equal(2, ENOENT)
	assert_equal(13, EACCES)
