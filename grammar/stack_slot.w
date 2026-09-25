# Stack-slot bookkeeping shared by the grammar rules.
#
# Every word the generated code pushes onto the machine stack must be
# mirrored in stack_pos (compiler/symbol_table.w), which local and slot
# addressing is relative to. These helpers keep the emitted push/pop and
# the bookkeeping together. A "slot" is the stack_pos value right after
# its word was pushed; load_slot/push_slot_copy address it relative to
# the current top of stack.
#
# The runtime-call protocol: rt_call_begin(fn) pushes fn's address and
# returns the stack position below it; the caller pushes the arguments
# (push_slot, push_slot_copy, push_slot_int); rt_call_end(s) reloads the
# function address, calls it and pops the arguments and the address.


# push eax as a new slot; returns the slot.
int push_slot():
	push_eax()
	stack_pos = stack_pos + 1
	return stack_pos


void push_slot_int(int v):
	mov_eax_int(v)
	push_slot()


void pop_ebx_slot():
	pop_ebx()
	stack_pos = stack_pos - 1


void pop_eax_slot():
	pop_eax()
	stack_pos = stack_pos - 1


# Discards the top n slots.
void drop_slots(int n):
	be_pop(n)
	stack_pos = stack_pos - n


# Discards every slot above stack position base.
void pop_to(int base):
	be_pop(stack_pos - base)
	stack_pos = base


# mov eax, <slot>
void load_slot(int slot):
	mov_eax_esp_plus((stack_pos - slot) << word_size_log2)


# Pushes a copy of an earlier slot as a new slot.
void push_slot_copy(int slot):
	load_slot(slot)
	push_slot()


int rt_call_begin(char* fn):
	sym_get_value(fn)
	int s = stack_pos
	push_slot()
	return s


void rt_call_end(int s):
	load_slot(s + 1)
	call_eax()
	pop_to(s)

