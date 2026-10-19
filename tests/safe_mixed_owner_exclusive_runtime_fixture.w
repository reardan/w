import lib.memory_debug
import tests.safe_mixed_owner_exclusive_import_fixture


type ExclusiveFactory = fn[a,b](refmut[a] int*, ref[b] int*) -> own[a,b] ExclusiveOwner*
type ExclusiveTake = fn[a,b](own[a,b] ExclusiveOwner*) -> refmut[a] int*


int exclusive_exercise():
	ExclusiveFactory* factory = exclusive_new
	ExclusiveTake* take = exclusive_take
	int value = 0
	int shared = 7
	int total = 0
	for i in range(100):
		own[a,b] ExclusiveOwner* holder = factory(&value, &shared)
		ref int* before = exclusive_inspect(holder)
		total += *before
		refmut int* result = take(holder)
		*result += 1
	return total + value


int exclusive_replace():
	int value = 0
	int shared = 7
	own[a,b] ExclusiveOwner* holder = exclusive_new(&value, &shared)
	for i in range(10):
		refmut int* item = holder.item
		*item += 1
		holder = exclusive_new(&value, &shared)
	ref int* last = exclusive_shared(holder)
	value = 12
	return *last + value


struct ExclusiveOuter:
	own[item,shared] ExclusiveOwner* child
	own int* stored


refmut[a] int* exclusive_nested(own[a,b] ExclusiveOuter* outer):
	return outer.child.item


int exclusive_nested_exercise():
	int value = 3
	int shared = 7
	own[a,b] ExclusiveOuter* outer = new ExclusiveOuter(exclusive_new(&value, &shared), new int)
	refmut int* item = exclusive_nested(outer)
	*item = 11
	return value


int exclusive_exits(int early):
	int value = 0
	int shared = 7
	for i in range(3):
		own[a,b] ExclusiveOwner* holder = exclusive_new(&value, &shared)
		refmut int* item = holder.item
		*item += 1
		if (early): return value
		if (i == 0): continue
		break
	return value


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if exclusive_exercise() != 5050: return 1
	if exclusive_replace() != 19: return 2
	if exclusive_nested_exercise() != 11: return 3
	if exclusive_exits(1) != 1: return 4
	if exclusive_exits(0) != 2: return 5
	return debug_alloc_report_leaks() - before
