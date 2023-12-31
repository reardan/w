void binary1(int type):
	promote(type)
	push_eax()
	stack_pos = stack_pos + 1


int binary2(int type, int n, char *s):
	promote(type)
	emit(n, s)
	stack_pos = stack_pos - 1
	return 3


int binary2_pop(int type, int n, char *s):
	promote(type)
	emit(1, "\x5b") /* pop ebx */
	emit(n, s)
	stack_pos = stack_pos - 1
	return 3
