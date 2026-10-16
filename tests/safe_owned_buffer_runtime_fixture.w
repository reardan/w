import lib.safe_buffer
import lib.memory_debug

struct OwnedBufferPair:
	own WOwnedIntBuffer* values
	own int* tag

own int* owned_buffer_value(int n):
	own int* result = new int
	*result = n
	return result

own WOwnedIntBuffer* owned_buffer_filled():
	own WOwnedIntBuffer* buffer = owned_int_buffer_new()
	int i = 0
	while i < 96:
		owned_int_buffer_push(buffer, owned_buffer_value(i + 1))
		i = i + 1
	return buffer

ref[a] int* owned_buffer_first(ref[a] WOwnedIntBuffer* buffer):
	return owned_int_buffer_get(buffer, 0)

int owned_buffer_exercise(int early):
	own WOwnedIntBuffer* buffer = owned_buffer_filled()
	if owned_int_buffer_length(buffer) != 96: return 1
	ref int* first = owned_buffer_first(buffer)
	if *first != 1: return 2
	owned_int_buffer_set(buffer, 0, owned_buffer_value(101))
	ref int* replaced = owned_int_buffer_get(buffer, 0)
	if *replaced != 101: return 3
	own int* last = owned_int_buffer_pop(buffer)
	if *last != 96: return 4
	if early: return 0
	owned_int_buffer_clear(buffer)
	if owned_int_buffer_length(buffer) != 0: return 5
	owned_int_buffer_push(buffer, last)
	own int* extracted = owned_int_buffer_pop(buffer)
	buffer = owned_buffer_filled()
	if *extracted != 96: return 6
	own OwnedBufferPair* pair = new OwnedBufferPair(buffer, extracted)
	ref int* tag = pair.tag
	if *tag != 96: return 7
	ref int* child = owned_int_buffer_get(pair.values, 95)
	return *child - 96

int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = owned_buffer_exercise(0) + owned_buffer_exercise(1)
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return result + after - before
