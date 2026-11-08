# The runtime's ordinary W syscall wrappers (open, write, unlink, kill,
# ... from the auto-imported runtime and lib/lib.w) are not visible to a
# profiled source, though the runtime itself calls them (P2b).
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: runtime function 'open' is not visible to addon code
int main():
	return open(c"/etc/passwd", 0, 0)
# wbuild: fixture_group=script_profile_error_test
