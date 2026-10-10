# This deliberately invalid conditional tests its type-mismatch warning.
# Keep diagnostic fallback available; it is not a positive AST-coverage case.
# wfixture: --ast-full-expressions
# expect_stderr: conditional arms type mismatch: expected 'int', got 'char*'
int main():
	int x = 1
	char* s = c"a"
	int y = x ? x : s
	return 0
# wbuild: fixture_group=diagnostic_sites_test
