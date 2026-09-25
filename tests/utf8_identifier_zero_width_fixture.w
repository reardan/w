# A zero-width space (U+200B) inside an identifier is rejected: it is
# invisible, so two names could look identical (issue #287 stage 2).
# wbuild: fixture_group=utf8_identifier_error_test
# expect_fail
# expect_stderr: contains an invisible or bidirectional control character: U+200B
int main():
	int ab​c = 1
	return abc
