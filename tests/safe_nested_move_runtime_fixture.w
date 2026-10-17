import lib.memory_debug
import tests.safe_nested_move_import_fixture


type NestedMoveTake = fn[](own NestedMoveOwner*) -> own int*


int nested_move_exercise():
	own NestedMoveOwner* owner = nested_move_owner()
	refmut int* right = owner.right.second
	*right = 7
	int sum = 0
	for i in range(100):
		own int* first = partial_identity[int](owner.left.first)
		*first = i
		sum += *first
		owner.left = partial_pair()
	int value = *right
	refmut int* first = owner.left.first
	*first = 11
	NestedMoveTake* take = nested_move_take
	own int* final_value = take(owner)
	return sum + value + *final_value


int nested_move_external():
	int[3] data
	data[1] = 8
	own[a] NestedMoveOuter* outer = new NestedMoveOuter(new NestedMoveMiddle(new PartialView(new int, data)))
	own[a] PartialView* child = nested_move_extract(outer)
	ref int[] view = child.data
	return view[1] + view.length


int nested_move_exits(int early):
	for i in range(3):
		own NestedMoveOwner* owner = nested_move_owner()
		own int* first = owner.left.first
		*first = i
		if (early): return *first
		if (i == 0): continue
		break
	return 1


int main():
	int before = debug_alloc_report_leaks()
	if nested_move_exercise() != 4968: return 1
	if nested_move_external() != 11: return 2
	if nested_move_exits(1) != 0: return 3
	if nested_move_exits(0) != 1: return 4
	return debug_alloc_report_leaks() - before
