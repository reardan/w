import lib.memory_debug
import tests.safe_mixed_owner_import_fixture


type OwnerFactory = fn[a, b](ref[a] int*, ref[b] int[]) -> own[a, b] OwnedView*
type OwnerPass = fn[a, b](own[a, b] OwnedView*) -> own[a, b] OwnedView*
type TakeData = fn[a, b](own[a, b] OwnedView*) -> ref[b] int[]


int mixed_clobber(int value):
	int[64] scratch
	scratch[0] = value
	return scratch[0]


int mixed_exercise():
	OwnerFactory* factory = owned_view_new
	OwnerPass* pass_owner = owned_view_pass
	TakeData* take = owned_view_take_data
	own int* value = new int
	int[2] data
	data[0] = 5
	int total = 0
	for i in range(100):
		*value = 3
		own[a, b] OwnedView* view = pass_owner(factory(value, data))
		ref int[] slice = take(view)
		value = new int
		int pressure = mixed_clobber(1)
		total += slice[0] + slice.length + pressure
	return total


struct MixedOuter:
	own[item, data] OwnedView* child
	own int* other


ref[a] int* mixed_nested(own[a, b] MixedOuter* outer):
	return outer.child.item


int mixed_nested_exercise():
	int value = 11
	int[2] data
	own[a, b] MixedOuter* outer = new MixedOuter(owned_view_new(&value, data), new int)
	ref int* p = mixed_nested(outer)
	return *p


int mixed_replacement():
	int value = 3
	int[2] data
	own[a, b] OwnedView* view = owned_view_new(&value, data)
	for i in range(10): view = owned_view_new(&value, data)
	ref int* p = owned_view_take_item(view)
	return *p


int mixed_exits(int early):
	int value = 3
	int[2] data
	own[a, b] OwnedView* outer = owned_view_new(&value, data)
	for i in range(3):
		own[a, b] OwnedView* inner = owned_view_new(&value, data)
		if (early): return 3
		if (i == 0): continue
		break
	ref int* p = outer.item
	return *p


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if mixed_exercise() != 800: return 1
	if mixed_nested_exercise() != 11: return 2
	if mixed_replacement() != 3: return 3
	if mixed_exits(1) != 3: return 4
	if mixed_exits(0) != 3: return 5
	return debug_alloc_report_leaks() - before
