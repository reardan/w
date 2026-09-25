# A generic combining diacritic (here U+0301 after a plain e, the NFD
# spelling of e-acute) is rejected instead of silently naming a symbol
# distinct from the precomposed U+00E9 spelling (issue #287 stage 2).
# wbuild: fixture_group=utf8_identifier_error_test
# expect_fail
# expect_stderr: contains a combining mark (use the precomposed spelling): U+0301
int main():
	int café = 1
	return 0
