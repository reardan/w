import lib.memory_debug
import tests.safe_mixed_owner_views_import_fixture


type MixedViewData = fn[a](ref[a] OwnedView*) -> ref[a] int[]
type MixedViewPass = fn[a](ref[a] OwnedView*) -> ref[a] OwnedView*


ref[a] OwnedView* mixed_view_count(ref[a] OwnedView* view, refmut int* calls):
	*calls += 1
	return view


int mixed_view_exercise():
	MixedViewData* data_view = mixed_view_data
	MixedViewPass* pass = mixed_view_pass
	int item = 3
	int[2] data
	data[0] = 5
	int calls = 0
	int total = 0
	for i in range(100):
		own[a,b] OwnedView* holder = owned_view_new(&item, data)
		refmut int* stored = holder.stored
		*stored = 7
		ref OwnedView* view = pass(mixed_view_count(holder, &calls))
		ref int[] slice = data_view(view)
		ref int* child = mixed_view_stored(view)
		total += slice[0] + slice.length + *child
		holder = owned_view_new(&item, data)
	return total + calls


struct MixedViewOuter:
	own[item,data] OwnedView* child
	int tag


ref[a] int[] mixed_view_nested(ref[a] MixedViewOuter* outer):
	return outer.child.data


int mixed_view_nested_exercise():
	int item = 3
	int[2] data
	data[0] = 9
	own[a,b] MixedViewOuter* owner = new MixedViewOuter(owned_view_new(&item, data), 1)
	ref MixedViewOuter* view = owner
	ref int[] result = mixed_view_nested(view)
	int answer = result[0] + result.length
	owner = new MixedViewOuter(owned_view_new(&item, data), 2)
	return answer


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if mixed_view_exercise() != 1500: return 1
	if mixed_view_nested_exercise() != 11: return 2
	return debug_alloc_report_leaks() - before
