import lib.memory_debug
import tests.safe_reference_field_import_fixture


type ReferenceUpdate = fn[a,b,c,d](own[a,b,c,d] ReferenceOwner*, ref[a] int[], ref[c] int*, ref[d] int*) -> own[a,b,c,d] ReferenceOwner*


int reference_exercise():
	int[2] first
	int[3] second
	first[0] = 3
	second[1] = 8
	int value = 4
	int next = 5
	int left = 6
	int right = 7
	own[a,b,c,d] ReferenceOwner* owner = reference_owner(first, &value, &left, &right)
	ReferenceUpdate* update = reference_update
	owner = update(owner, second, &left, &right)
	for i in range(100):
		owner.value = &next
		refmut int* p = owner.value
		*p += 1
		owner.pair = ReferencePair(reference_pass[int](&left), &right)
		owner.items = second
	ref[a,b] ReferencePair pair = owner.pair
	ref int* p = pair.first
	ref int* q = pair.second
	int sum = *p + *q
	ref int[] items = reference_take(owner, second)
	return next + items[1] + items.length + sum


int reference_exits(int early):
	int[2] data
	int value = 1
	int left = 2
	int right = 3
	own[a,b,c,d] ReferenceOwner* owner = reference_owner(data, &value, &left, &right)
	for i in range(3):
		owner.items = data
		owner.pair = ReferencePair(&left, &right)
		if (early): return i
		if (i == 0): continue
		break
	return 1


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if reference_exercise() != 129: return 1
	if reference_exits(1) != 0: return 2
	if reference_exits(0) != 1: return 3
	return debug_alloc_report_leaks() - before
