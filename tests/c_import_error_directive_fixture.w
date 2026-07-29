# Fixture for c_import_error_directive_test: the header hits an
# '#error' directive, and the diagnostic must echo the directive's own
# message text after the file name
# (libs/extras/c_preprocessor/pp_directives.w's
# cpp_directive_message_text). The header's '#if 0' branch holds a
# second '#error' that must NOT fire (inactive conditional).
# expect_fail
# expect_stderr: c preprocessor: #error in tests/c_import_error_directive_fixture.h: unsupported configuration for this header
# reject_stderr: inactive branch: must not fire
c_import "libc.so.6" c"tests/c_import_error_directive_fixture.h"


int main(int argc, int argv):
	return 0
