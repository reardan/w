# A --kernel-codegen object that does call a built-in assembly stub:
# the stubs are emitted after the last function (tests/kernel_codegen_test.w).
export int kv_getpid():
	return syscall(39, 0, 0, 0)
