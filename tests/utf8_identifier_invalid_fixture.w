# A UTF-8 lead byte without its continuation byte inside an identifier
# is a clear compile error, not a cascade of bogus one-byte tokens
# (issue #287 stage 2).
# wbuild: fixture_group=utf8_identifier_error_test
# expect_fail
# expect_stderr: invalid UTF-8 sequence in identifier
int main():
	int caf√ = 1
	return 0
