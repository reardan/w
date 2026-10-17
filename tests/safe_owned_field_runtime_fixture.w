import lib.memory_debug
import tests.safe_owned_field_import_fixture
import tests.safe_mixed_owner_import_fixture
import tests.safe_mixed_owner_exclusive_import_fixture


type FieldFactory = fn[a](int, refmut[a] int*) -> own FieldNode*


int field_exercise():
	FieldFactory* factory = field_node
	int calls = 0
	own FieldOwner* holder = new FieldOwner(factory(0, &calls), int_buffer_new(), 3)
	for i in range(100):
		holder.node = factory(i, &calls)
		holder.buffer = int_buffer_new()
		int_buffer_push(holder.buffer, i)
	ref FieldNode* node = holder.node
	ref int* value = node.value
	int last = *value + int_buffer_get(holder.buffer, 0)
	own FieldNode* replacement = factory(7, &calls)
	holder = field_replace(holder, replacement)
	ref FieldNode* final_node = holder.node
	ref int* final_value = final_node.value
	return last + *final_value + calls


struct FieldMixedOwner:
	own[item,data] OwnedView* child
	int tag


int field_mixed():
	int item = 3
	int[2] first
	int[2] second
	first[0] = 4
	second[0] = 9
	own[a,b] FieldMixedOwner* holder = new FieldMixedOwner(owned_view_new(&item, first), 1)
	holder.child = owned_view_new(&item, second)
	ref int[] data = holder.child.data
	return data[0] + data.length


struct FieldExclusiveOwner:
	own[item,shared] ExclusiveOwner* child
	int tag


int field_exclusive():
	int first = 3
	int second = 4
	int shared = 7
	own[a,b] FieldExclusiveOwner* holder = new FieldExclusiveOwner(exclusive_new(&first, &shared), 1)
	holder.child = exclusive_new(&second, &shared)
	refmut int* value = holder.child.item
	*value = 11
	return second


int field_exits(int early):
	int calls = 0
	own FieldOwner* holder = new FieldOwner(field_node(0, &calls), int_buffer_new(), 3)
	for i in range(3):
		holder.node = field_node(i, &calls)
		if (early): return calls
		if (i == 0): continue
		break
	return calls


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if field_exercise() != 307: return 1
	if field_mixed() != 11: return 2
	if field_exclusive() != 11: return 3
	if field_exits(1) != 2: return 4
	if field_exits(0) != 3: return 5
	return debug_alloc_report_leaks() - before
