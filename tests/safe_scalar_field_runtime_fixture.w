import lib.memory_debug
import tests.safe_scalar_field_import_fixture


type ScalarChange = fn[a](refmut[a] ScalarPair*, int) -> int


int scalar_exercise():
	int count = 0
	ScalarPair local = ScalarPair(second: scalar_tick(&count), first: scalar_tick(&count))
	int ordered = local.first * 10 + local.second
	refmut int* local_first = &local.first
	refmut int* local_second = &local.second
	*local_first = 7
	*local_second = 8
	int sum = *local_first + *local_second
	own ScalarOwner* owner = new ScalarOwner(scalar_pair(3), new int)
	refmut ScalarPair* pair = &owner.pair
	refmut int* stored = owner.stored
	ScalarChange* change = scalar_change
	for i in range(100):
		*stored = i
		if change(pair, i) != i * 2 + 1: return 0
	int last = *stored
	own int* moved = owner.stored
	owner.pair.first = 11
	refmut int* first = &owner.pair.first
	refmut int* second = &owner.pair.second
	*first += 1
	*second += 1
	return ordered + sum + last + *first + *second


int scalar_arrays():
	own ScalarArrays* arrays = new ScalarArrays
	refmut int* first = &arrays.first[0]
	refmut int* second = &arrays.second[1]
	*first = 7
	*second = 8
	return *first + *second


int scalar_exits(int early):
	for i in range(3):
		own ScalarPair* pair = new ScalarPair(3, 4)
		refmut int* first = &pair.first
		refmut int* second = &pair.second
		*first = i
		*second = i + 1
		if (early): return *first
		if (*first == 0): continue
		break
	return 1


int main():
	int before = debug_alloc_report_leaks()
	if scalar_exercise() != 248: return 1
	if scalar_arrays() != 15: return 2
	if scalar_exits(1) != 0: return 3
	if scalar_exits(0) != 1: return 4
	return debug_alloc_report_leaks() - before
