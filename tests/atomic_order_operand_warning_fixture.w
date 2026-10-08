# wfixture: x64
# expect_stderr: function 'atomic_load' argument 1 type mismatch: expected 'int*', got 'float32*'
# expect_stderr: function 'atomic_store' argument 1 type mismatch: expected 'int*', got 'float32*'
# expect_stderr: function 'atomic_store' argument 2 type mismatch: expected 'int', got 'char*'
int main():
	float32 value
	float32* pointer = &value
	atomic_load(pointer)
	atomic_store(pointer, c"bad")
	return 0
