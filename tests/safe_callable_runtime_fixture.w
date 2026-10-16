import lib.memory_debug


type MakeOwner = fn[](int) -> own int*
type ConsumeOwner = fn[](own int*) -> int
type BorrowOwner = fn[a](ref[a] int*) -> ref[a] int*


own int* callable_make(int value):
	own int* result = new int
	*result = value
	return result


int callable_consume(own int* value):
	return *value


ref[x] int* callable_borrow(ref[x] int* value):
	return value


int callable_exercise():
	MakeOwner* make = callable_make
	ConsumeOwner* consume = callable_consume
	BorrowOwner* borrow = callable_borrow
	int total = 0
	for i in range(100):
		own int* owner = make(3)
		if i % 2: owner = make(5)
		ref int* view = borrow(owner)
		total = total + *view
		total = total + consume(owner)
	return total


int callable_early(int branch):
	MakeOwner* make = callable_make
	own int* first = make(7)
	if branch: return *first
	own int* second = make(11)
	return *first + *second


struct CallableHolder:
	ref[field] int* item
	int tag


type SliceCall = fn[a](int, ref[a] int[], int) -> ref[a] int[]
type RecordCall = fn[a](int, ref[a] CallableHolder, int) -> ref[a] CallableHolder


ref[x] int[] callable_middle(int before, ref[x] int[] values, int after):
	return values[before:after]


ref[x] CallableHolder callable_record(int before, ref[x] CallableHolder value, int after):
	return value


int callable_multiword():
	SliceCall* slice = callable_middle
	RecordCall* record = callable_record
	int[3] values
	values[1] = 7
	ref int[] middle = slice(1, values, 3)
	int total = middle[0] + middle.length
	int value = 7
	ref[a] CallableHolder holder = CallableHolder(&value, 3)
	ref[a] CallableHolder result = record(2, holder, 5)
	ref int* p = result.item
	return total + *p + result.tag


int main():
	int before = debug_alloc_report_leaks()
	if callable_exercise() != 800: return 1
	if callable_early(1) != 7: return 2
	if callable_early(0) != 18: return 3
	if callable_multiword() != 19: return 4
	return debug_alloc_report_leaks() - before
