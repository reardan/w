# A typed local is in scope in its own initializer, but reading it there
# has no value to read: its slot does not exist yet. Taking its address
# is allowed (tests/kernel_codegen/corpus.w, kc_self_address).
# expect_fail
# expect_stderr: local 'x' is read in its own initializer
# expect_stderr: local_self_read_error_fixture.w:8:10
int main():
	int x = x + 1
	return x
# wbuild: fixture_group=type_system_error_test
