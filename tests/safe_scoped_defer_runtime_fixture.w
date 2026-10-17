import lib.memory_debug
import tests.safe_scoped_defer_import_fixture


type Add = fn[](refmut int*, int) -> void


struct ScopedPair:
	own int* left
	own int* right


int scoped_loop(refmut int* total):
	for i in range(100):
		own int* child = new int
		*child = i
		defer: scoped_dispose[int](child)
		defer: scoped_add(total, *child)
		if (i == 1): continue
		if (i == 10): break
	return *total


int scoped_return(refmut int* order, int early):
	own ScopedPair* pair = new ScopedPair(new int, new int)
	*pair.left = 7
	*pair.right = 11
	defer scoped_digit(order, 1)
	defer: scoped_digit(order, 2)
	if (early):
		own int* child = pair.left
		defer: scoped_digit(order, 3)
		defer: scoped_dispose[int](child)
		return *child
	if (1):
		defer: scoped_digit(order, 4)
	return *pair.right


int scoped_callback(refmut int* total):
	Add* callback = scoped_add
	if (1):
		int amount = 1
		defer: callback(total, amount)
		amount = 9
	return *total


int scoped_switch(refmut int* total):
	for i in range(3):
		defer: scoped_add(total, 1)
		switch (i):
			case 1:
				defer: scoped_add(total, 2)
				continue
			default:
				defer: scoped_add(total, 3)
				break
	return *total


int main():
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	int total = 0
	if scoped_loop(&total) != 55: return 1
	int order = 0
	if scoped_return(&order, 1) != 7: return 2
	if order != 321: return 3
	order = 0
	if scoped_return(&order, 0) != 11: return 4
	if order != 421: return 5
	total = 0
	if scoped_callback(&total) != 9: return 6
	total = 0
	if scoped_switch(&total) != 11: return 7
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
