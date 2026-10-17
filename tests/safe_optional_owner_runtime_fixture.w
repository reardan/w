import lib.memory_debug
import tests.safe_optional_owner_import_fixture


type OptionalOwnerMake = fn[](int, int) -> optown int*


int optional_owner_replacements():
	OptionalOwnerMake* make = optional_owner_make
	optown int* value = 0
	int total = 0
	for i in range(100):
		value = make(i, 1)
		if (value): total += *value
		value = 0
		value = optional_owner_identity[int](make(0, 0))
		if (value): return -1
	return total


int optional_owner_fields():
	own OptionalOwnerBox* box = new OptionalOwnerBox(0, 7)
	box.child = optional_owner_make(11, 1)
	optown int* child = box.child
	box.child = 0
	if (child):
		own int* required = child
		*required += box.tag
		box.child = required
	optown int* returned = box.child
	box.child = optional_owner_make(19, 1)
	box.child = 0
	if (returned): return *returned
	return -1


int optional_owner_external():
	int number = 23
	optown[a] OptionalOwnerMixed* mixed = optional_owner_mixed(&number, 1)
	int answer = 0
	if (mixed):
		ref int* view = mixed.external
		answer = *view
		optown int* child = mixed.child
		if (child): answer += *child
		mixed.child = 0
	mixed = 0
	number = 0
	return answer


void optional_owner_deferred(optref int* value, refmut int* output):
	if (value): *output += *value


int optional_owner_exit(refmut int* output, int early):
	optown int* value = optional_owner_make(13, 1)
	defer optional_owner_deferred(value, output)
	for i in range(3):
		optown OptionalOwnerBox* box = new OptionalOwnerBox(optional_owner_make(i, 1), i)
		if (early): return 2
		if (i == 0): continue
		break
	return 3


int main():
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	if optional_owner_replacements() != 4950: return 1
	if optional_owner_fields() != 18: return 2
	if optional_owner_external() != 27: return 3
	int output = 0
	if optional_owner_exit(&output, 1) != 2: return 4
	if output != 13: return 5
	if optional_owner_exit(&output, 0) != 3: return 6
	if output != 26: return 7
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
