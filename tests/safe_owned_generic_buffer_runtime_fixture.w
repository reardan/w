import lib.safe_owned_vector
import lib.memory_debug


struct OwnedBufferItem:
	own int* value


own OwnedBufferItem* owned_buffer_item(int number):
	own int* value = new int
	*value = number
	return new OwnedBufferItem(value)


# The raw allocator hook returns a null machine word on every target.
int owned_buffer_fail_allocation(int size):
	return 0


int exercise_owned_buffers():
	int total = 0
	for i in range(30):
		own WOwnedBuffer[OwnedBufferItem]* values = owned_buffer_new[OwnedBufferItem](-1)
		for j in range(20): owned_buffer_push[OwnedBufferItem](values, owned_buffer_item(j))
		ref OwnedBufferItem* first = owned_buffer_get[OwnedBufferItem](values, 0)
		ref int* first_value = first.value
		total += *first_value
		owned_buffer_set[OwnedBufferItem](values, 0, owned_buffer_item(100))
		own OwnedBufferItem* last = owned_buffer_pop[OwnedBufferItem](values)
		ref int* last_value = last.value
		total += *last_value
		owned_buffer_clear[OwnedBufferItem](values)
		own WOwnedBuffer[OwnedBufferItem]* bounded = owned_buffer_new[OwnedBufferItem](1)
		owned_buffer_push[OwnedBufferItem](bounded, owned_buffer_item(11))
		optown OwnedBufferItem* rejected = owned_buffer_try_push[OwnedBufferItem](bounded, owned_buffer_item(13))
		if rejected:
			ref int* rejected_value = rejected.value
			total += *rejected_value
		else: return -1
		own WOwnedBuffer[WOwnedBuffer[OwnedBufferItem]]* outer = owned_buffer_new[WOwnedBuffer[OwnedBufferItem]](-1)
		owned_buffer_push[WOwnedBuffer[OwnedBufferItem]](outer, bounded)
		if i % 2 == 0: continue
		total += owned_buffer_length[WOwnedBuffer[OwnedBufferItem]](outer)
	return total


int exercise_allocation_failure():
	own WOwnedBuffer[OwnedBufferItem]* values = owned_buffer_new[OwnedBufferItem](-1)
	own OwnedBufferItem* candidate = owned_buffer_item(17)
	unsafe: malloc_hook_malloc = cast(int, owned_buffer_fail_allocation)
	optown OwnedBufferItem* returned = owned_buffer_try_push[OwnedBufferItem](values, candidate)
	unsafe: malloc_hook_malloc = 0
	if returned:
		ref int* view = returned.value
		if *view != 17: return 1
		if owned_buffer_length[OwnedBufferItem](values) != 0: return 2
		owned_buffer_push[OwnedBufferItem](values, returned)
	else: return 3
	# Fill the first allocation, then fail a growth. Existing slots must
	# remain readable and owned; the rejected element can be retried.
	for i in range(7): owned_buffer_push[OwnedBufferItem](values, owned_buffer_item(i))
	own OwnedBufferItem* next_value = owned_buffer_item(23)
	unsafe: malloc_hook_malloc = cast(int, owned_buffer_fail_allocation)
	optown OwnedBufferItem* retry = owned_buffer_try_push[OwnedBufferItem](values, next_value)
	unsafe: malloc_hook_malloc = 0
	if retry:
		if owned_buffer_length[OwnedBufferItem](values) != 8: return 4
		ref OwnedBufferItem* first = owned_buffer_get[OwnedBufferItem](values, 0)
		ref int* first_value = first.value
		if *first_value != 17: return 5
		owned_buffer_push[OwnedBufferItem](values, retry)
	else: return 6
	return owned_buffer_length[OwnedBufferItem](values) - 9


int exercise_break_cleanup():
	for i in range(3):
		own WOwnedBuffer[OwnedBufferItem]* values = owned_buffer_new[OwnedBufferItem](-1)
		owned_buffer_push[OwnedBufferItem](values, owned_buffer_item(i))
		if i == 1: break
	return 0


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	if exercise_owned_buffers() != 975: return 1
	if exercise_allocation_failure(): return 2
	if exercise_break_cleanup(): return 3
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
