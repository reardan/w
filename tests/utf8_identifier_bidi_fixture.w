# A Unicode bidirectional override (U+202E) inside an identifier is
# rejected: Trojan Source (CVE-2021-42574) hides code by reordering
# how a line displays (issue #287 stage 2).
# wbuild: fixture_group=utf8_identifier_error_test
# expect_fail
# expect_stderr: contains an invisible or bidirectional control character: U+202E
int main():
	int total‮ = 1
	return 0
