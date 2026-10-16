import lib.memory_debug


struct MethodOwner:
	own int* item


int MethodOwner_take(own MethodOwner* self):
	ref int* item = self.item
	return *item


int MethodOwner_sum(ref MethodOwner* self, own int* other):
	ref int* item = self.item
	return *item + *other


int methods_runtime_run():
	for i in range(100):
		own int* child = new int
		*child = 7
		own MethodOwner* p = new MethodOwner(child)
		own int* other = new int
		*other = 3
		if p.sum(other) != 10: return 1
		if p.take() != 7: return 2
	return 0


int main():
	int before = debug_alloc_report_leaks()
	if methods_runtime_run(): return 1
	return debug_alloc_report_leaks() - before
