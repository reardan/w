# Host atomics always emit the int form, so the target pointer is
# checked like an ordinary int* call argument (the limb-intrinsic
# rule): a wrongly-typed pointer variable warns. The float32* atomic_add
# form exists only on the GPU — lock-prefixed x86 has no float add.
# ('&x' itself is the untyped address-of constant and passes; it is the
# natural host idiom.)
# wfixture: x64
# expect_stderr: warning: function 'atomic_add' argument 1 type mismatch: expected 'int*', got 'float32*'
float32 shared_float

int main(int argc, int argv):
	float32* p = &shared_float
	atomic_add(p, 1)
	return 0
