import lib.memory_debug
import tests.safe_nested_replacement_import_fixture


type NestedReplacementMake = fn[](int) -> own int*


int nested_replacement_exercise():
	own NestedMoveOwner* owner = nested_move_owner()
	refmut int* sibling = owner.right.second
	*sibling = 7
	NestedReplacementMake* make = nested_replacement_value
	for i in range(100):
		own int* previous = owner.left.first
		owner.left.first = make(i)
		owner.left.second = partial_identity[int](previous)
		owner.left.second = owner.left.second
	ref int* final_value = owner.left.first
	return *final_value + *sibling


int nested_replacement_views():
	int[2] a
	int[3] b
	int[4] c
	c[1] = 8
	own[x,y] NestedReplacementOuter* owner = new NestedReplacementOuter(new NestedReplacementMiddle(new NestedReplacementView(a, b)))
	ref int[] previous = owner.middle.child.first
	owner.middle.child.first = c
	ref int[] current = owner.middle.child.first
	ref int[] sibling = owner.middle.child.second
	return previous.length + current[1] + sibling.length


int nested_replacement_records():
	int x = 3
	int y = 8
	own[a] NestedReplacementRoot* root = new NestedReplacementRoot(new NestedReplacementHolder(NestedReplacementRecord(&x)))
	ref NestedReplacementRecord old = root.holder.view
	root.holder.view = NestedReplacementRecord(&y)
	ref int* first = old.value
	ref int* second = root.holder.view.value
	return *first + *second


int nested_replacement_buffers():
	own NestedReplacementBuffers* owner = new NestedReplacementBuffers(new PartialBuffer(int_buffer_new(), new int), new int)
	for i in range(50):
		int_buffer_push(owner.child.buffer, i)
		owner.child.buffer = int_buffer_new()
		int_buffer_push(owner.child.buffer, i + 1)
	return int_buffer_length(owner.child.buffer)


int nested_replacement_exits(int early):
	for i in range(3):
		own NestedMoveOwner* owner = nested_move_owner()
		own int* first = owner.left.first
		owner.left.first = nested_replacement_value(i)
		if (early): return i
		if (i == 0): continue
		break
	return 1


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if nested_replacement_exercise() != 106: return 1
	if nested_replacement_views() != 13: return 2
	if nested_replacement_records() != 11: return 3
	if nested_replacement_buffers() != 1: return 4
	if nested_replacement_exits(1) != 0: return 5
	if nested_replacement_exits(0) != 1: return 6
	return debug_alloc_report_leaks() - before
