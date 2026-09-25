# Unicode whitespace (here U+00A0, a no-break space) is not an
# identifier character; the tokenizer names it instead of reporting a
# confusing parse error (issue #287 stage 2).
# wbuild: fixture_group=utf8_identifier_error_test
# expect_fail
# expect_stderr: contains a whitespace character: U+00A0
int main():
	int a b = 1
	return 0
