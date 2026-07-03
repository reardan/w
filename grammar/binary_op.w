void binary1(int type):
	promote(type)
	push_eax()
	stack_pos = stack_pos + 1


# Finish a binary operator whose emitter pops the pushed left operand
# itself (division, shifts): promote the right operand, then account for
# the popped stack word.
int binary2_finish(int type):
	promote(type)
	stack_pos = stack_pos - 1
	return 3


# Finish a binary operator that expects the left operand in ebx: promote
# the right operand and pop the left one first.
int binary2_finish_pop(int type):
	promote(type)
	pop_ebx()
	stack_pos = stack_pos - 1
	return 3
