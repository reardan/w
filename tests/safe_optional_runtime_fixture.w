import lib.memory_debug


optref[a] int* optional_find(ref[a] int* first, ref[a] int* second, int choose):
	if choose == 0: return 0
	if choose == 1: return first
	return second


optrefmut int* optional_mutable(refmut int* value, int present):
	if present: return value
	return 0


void optional_deferred(optref int* value, refmut int* output):
	if value: *output = *value


int optional_exercise(int choose):
	own int* first = new int
	own int* second = new int
	*first = 7
	*second = 9
	optref int* selected = optional_find(first, second, choose)
	optref int* saved = selected
	selected = 0
	int answer = 0
	while saved:
		answer = *saved
		saved = 0
	optrefmut int* changed = optional_mutable(first, 1)
	if changed: *changed = 11
	changed = 0
	for i in range(3):
		optref int* current = optional_find(first, second, i)
		if current:
			if *current == 11: continue
			answer += *current
	return answer


void optional_exit_inner(refmut int* answer):
	own int* value = new int
	*value = 13
	optref int* present = value
	defer optional_deferred(present, answer)


int optional_exit():
	int answer = 0
	optional_exit_inner(&answer)
	return answer


int main():
	malloc_force_debug_mode()
	int baseline = debug_alloc_report_leaks()
	if optional_exercise(0) != 9: return 1
	if optional_exercise(1) != 16: return 2
	if optional_exercise(2) != 18: return 3
	if optional_exit() != 13: return 4
	return debug_alloc_report_leaks() - baseline
