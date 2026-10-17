import lib.memory_debug
import tests.safe_optional_field_import_fixture


type OptionalFieldMake = fn[a](optref[a] int*) -> ref[a] OptionalFieldRecord


int optional_field_records():
	int value = 7
	OptionalFieldMake* make = optional_field_record
	ref[a] OptionalFieldRecord empty = make(0)
	ref[a] OptionalFieldRecord filled = make(&value)
	optref int* absent = empty.value
	if (absent): return 1
	optref int* present = filled.value
	if (present): return *present + filled.tag
	return 0


int optional_field_replacement():
	int value = 3
	own[a] OptionalFieldOuter* outer = new OptionalFieldOuter(optional_field_owner(0))
	for i in range(100):
		outer.child.value = &value
		optrefmut int* pointer = outer.child.value
		if (pointer): *pointer += 1
		outer.child.value = 0
		optrefmut int* empty = outer.child.value
		if (empty): return 1
	optref int* final_value = optional_field_read(outer.child)
	if (final_value): return 2
	return value


int optional_field_transfer():
	int value = 7
	own[a] OptionalFieldOuter* outer = new OptionalFieldOuter(optional_field_owner(&value))
	own[a] OptionalFieldOwner* child = outer.child
	optrefmut int* pointer = child.value
	if (pointer): *pointer = 8
	return value


int optional_field_exits(int early):
	for i in range(3):
		own[a] OptionalFieldOwner* owner = optional_field_owner(0)
		optrefmut int* pointer = owner.value
		if (pointer): return 2
		if (early): return 0
		if (i == 0): continue
		break
	return 1


int main():
	int before = debug_alloc_report_leaks()
	if optional_field_records() != 10: return 1
	if optional_field_replacement() != 103: return 2
	if optional_field_transfer() != 8: return 3
	if optional_field_exits(1) != 0: return 4
	if optional_field_exits(0) != 1: return 5
	return debug_alloc_report_leaks() - before
