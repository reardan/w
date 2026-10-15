# Owner destruction is observed by the guard allocator, including owned
# parameters, replacement, return transfer and all structured exits.
import lib.memory_debug

own int* safe_make(int value):
	own int* p = new int
	*p = value
	return p

int safe_consume(own int* p):
	return *p

refmut int* safe_runtime_view(refmut int* p):
	return p

int safe_returned_borrow_cleanup():
	own int* p = safe_make(6)
	refmut int* r = safe_runtime_view(p)
	*r = *r + 1
	return safe_consume(p)

int safe_paths(int n):
	own int* p = safe_make(10)
	if n == 0: return *p
	int sum = 0
	while n > 0:
		own int* q = safe_make(n)
		n = n - 1
		if n == 3: continue
		if n == 1: break
		sum = sum + safe_consume(q)
	p = safe_make(sum)
	return safe_consume(p)

int safe_pair(int first, own int* p, own int* q, int last):
	return first + *p + *q + last

int safe_multiple_arguments():
	own int* p = safe_make(4)
	own int* temporary = safe_make(5)
	q := temporary
	return safe_pair(1, p, q, 2)

int main():
	int before = debug_alloc_report_leaks()
	if safe_returned_borrow_cleanup() != 7: return 5
	if safe_multiple_arguments() != 12: return 4
	if safe_paths(0) != 10: return 1
	if safe_paths(1) != 1: return 2
	if safe_paths(5) != 8: return 3
	return debug_alloc_report_leaks() - before
