# expect_fail
# expect_stderr: thread_local fixed arrays are not supported; use a pointer
# A fixed array's header points into its own storage, which differs per
# thread, so it cannot live in a zero-filled TLS block.
thread_local int[4] cells

int main():
	return 0
