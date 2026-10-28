import tests.safe_foreign_boundary_module unsafe "6ef6a19a7598bda552d3a607d1483eb7585d583f3fe34f99b2dc4eb3f7bca57d"
import lib.safe_foreign_owner
import lib.memory_debug
import lib.safe


# Foreign owners release their object exactly once on every exit: early
# returns, loop iterations, replacement, owned records, failed transfers and
# failed adoption.
struct Holder:
	own WForeign[Resource]* resource
	int weight


int early(int stop):
	int total = 0
	for i in range(6):
		optown WForeign[Resource]* resource = resource_open(i)
		if (!resource): return -100
		if (i == stop): return total + resource_value(resource)
		resource_add(resource, 1)
		total += resource_value(resource)
	return total


int holders():
	int total = 0
	for i in range(4):
		optown WForeign[Resource]* resource = resource_open(i * 10)
		if (!resource): return -100
		own WForeign[Resource]* held = resource
		own Holder* holder = new Holder(held, i)
		total += holder.weight + resource_value(holder.resource)
	return total


int replacement():
	optown WForeign[Resource]* slot = resource_open(1)
	for i in range(5): slot = resource_open(i + 2)
	if (!slot): return -100
	int value = resource_value(slot)
	slot = 0
	return value + resource_live() * 1000


int transfers():
	int total = 0
	for i in range(6):
		optown WForeign[Resource]* resource = resource_open(i)
		if (!resource): return -100
		own WForeign[Resource]* held = resource
		optown WForeign[Resource]* back = resource_give(held, i % 2)
		if (back): total += resource_value(back)
	return total


int failures():
	int total = 0
	optown WForeign[Resource]* none = resource_open_null()
	if (!none): total += 1
	optown WForeign[Resource]* skewed = resource_open_misaligned()
	if (!skewed): total += 2
	return total


int closing():
	optown WForeign[Resource]* resource = resource_open(9)
	if (!resource): return -100
	own WForeign[Resource]* held = resource
	int value = resource_value(held)
	foreign_close[Resource](held)
	return value + resource_live() * 1000


int exercise():
	int total = 0
	for round in range(20):
		total += early(round % 7)
		if (resource_live() != 0): return -1
		total += holders()
		if (resource_live() != 0): return -2
		total += replacement()
		if (resource_live() != 0): return -3
		total += transfers()
		if (resource_live() != 0): return -4
		total += failures()
		if (resource_live() != 0): return -5
		total += closing()
		if (resource_live() != 0): return -6
	return total


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = exercise()
	if result != 1992:
		safe_println_int(result)
		return 1
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
