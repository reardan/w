import lib.safe_vector
import lib.safe_owned_vector
import lib.memory_debug


struct MutablePayload:
	own int* value
	int weight


struct MutableGroup:
	own WOwnedBuffer[MutablePayload]* items


own MutablePayload* mutable_payload(int number):
	own int* value = new int
	*value = number
	return new MutablePayload(value, number * 3)


refmut[a] int[] mutable_counted(refmut[a] WBuffer[int]* values, refmut int* count):
	*count += 1
	return buffer_view_mut[int](values)


int mutable_early(refmut WOwnedBuffer[MutablePayload]* values):
	for refmut MutablePayload* item in values:
		own int* scratch = new int
		*scratch = item.weight
		defer: item.weight += 1
		return *scratch
	return 0


int mutable_exercise():
	for repetition in range(20):
		own WBuffer[int]* scalars = buffer_new[int]()
		for i in range(20): buffer_push[int](scalars, i)
		int calls = 0
		for refmut int* item in mutable_counted(scalars, &calls):
			defer: *item += 1
			if *item % 2 == 0: continue
			*item += 2
		if calls != 1: return 1
		for i in range(20):
			int expected = i + 1
			if i % 2: expected += 2
			if buffer_get[int](scalars, i) != expected: return 2
		own WOwnedBuffer[MutableGroup]* groups = owned_buffer_new[MutableGroup](-1)
		for g in range(4):
			own WOwnedBuffer[MutablePayload]* items = owned_buffer_new[MutablePayload](-1)
			for i in range(8): owned_buffer_push[MutablePayload](items, mutable_payload(g + i))
			owned_buffer_push[MutableGroup](groups, new MutableGroup(items))
		for refmut MutableGroup* group in groups:
			for refmut MutablePayload* item in group.items:
				own int* replacement = new int
				*replacement = item.weight + 5
				refmut int* contents = item.value
				*contents = *replacement
				defer: item.weight += 1
				if item.weight % 2: continue
				item.weight += 2
		for group in groups:
			for item in group.items:
				ref int* value = item.value
				int original = *value - 5
				int expected = original + 1
				if original % 2 == 0: expected += 2
				if item.weight != expected: return 3
		for refmut MutableGroup* group in groups:
			mutable_early(group.items)
			optrefmut MutablePayload* saved = 0
			for refmut MutablePayload* item in group.items:
				saved = item
				break
			if saved:
				refmut int* value = saved.value
				*value += 1
		owned_buffer_clear[MutableGroup](groups)
		buffer_clear[int](scalars)
	return 0


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = mutable_exercise()
	if result: return result
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
