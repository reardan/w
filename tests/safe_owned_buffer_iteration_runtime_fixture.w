import lib.safe_owned_vector
import lib.memory_debug
import lib.safe


struct Payload:
	own int* value
	int weight


struct Group:
	own WOwnedBuffer[Payload]* items
	int tag


own Payload* payload(int number):
	own int* value = new int
	*value = number
	return new Payload(value, number * 3)


own Group* make_group(int tag, int count):
	own WOwnedBuffer[Payload]* items = owned_buffer_new[Payload](-1)
	for i in range(count): owned_buffer_push[Payload](items, payload(tag + i))
	return new Group(items, tag)


int payload_value(ref Payload* item):
	ref int* value = item.value
	return *value


# Returns from inside nested loops; every body-local owner is dropped.
int find_value(ref WOwnedBuffer[Group]* groups, int wanted):
	for group in groups:
		for item in group.items:
			own int* scratch = new int
			*scratch = payload_value(item)
			if *scratch == wanted: return group.tag * 1000 + *scratch
	return -1


optref[a] Payload* heaviest(ref[a] WOwnedBuffer[Payload]* items):
	optref Payload* best = 0
	for item in items:
		if (!best): best = item
		else if (item.weight > best.weight): best = item
	return best


int exercise():
	int total = 0
	for repetition in range(20):
		own WOwnedBuffer[Group]* groups = owned_buffer_new[Group](-1)
		for g in range(4): owned_buffer_push[Group](groups, make_group(g * 10, g + 1))
		for group in groups:
			for item in group.items:
				if payload_value(item) % 2 == 1: continue
				if payload_value(item) > 31: break
				own int* copy = new int
				*copy = item.weight
				defer: total += *copy
		total += find_value(groups, 21)
		for group in groups:
			optref Payload* best = heaviest(group.items)
			if (best): total += best.weight
		# Mutation resumes once the loops end: replacing and clearing
		# destroys each owned element exactly once.
		owned_buffer_set[Group](groups, 0, make_group(90, 2))
		ref Group* first = owned_buffer_get[Group](groups, 0)
		for item in first.items: total += payload_value(item)
		owned_buffer_clear[Group](groups)
		for group in groups: total += 1000000
	return total


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = exercise()
	if result != 412920:
		safe_println_int(result)
		return 1
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
