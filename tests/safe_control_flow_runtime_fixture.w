import lib.memory_debug


int control_flow_cleanup(int early):
	own int* outer = new int
	int total = 0
	for i in range(8):
		own int* item = new int
		switch i:
			case 0, 1:
				own int* arm = new int
				continue
			case 2:
				own int* arm = new int
				break
			case 4:
				own int* arm = new int
				if early: return total
			default:
				own int* arm = new int
				*arm = i
				total += *arm
		if i == 6: break
	return total


void control_flow_consume(own int* p):
	pass


void control_flow_digit(refmut int* output, int digit):
	*output = *output * 10 + digit


int control_flow_defer(refmut int* output):
	own int* item = new int
	*item = 7
	defer control_flow_consume(item)
	defer control_flow_digit(output, 1)
	defer control_flow_digit(output, 2)
	for i in range(3):
		own int* inner = new int
		switch i:
			case 0: continue
			default: return *item
	return 0


int control_flow_defer_run():
	int output = 0
	if control_flow_defer(&output) != 7: return 3
	if output != 21: return 4
	return 0


int main():
	int before = debug_alloc_report_leaks()
	if control_flow_cleanup(1) != 3: return 1
	if control_flow_cleanup(0) != 14: return 2
	if control_flow_defer_run(): return 3
	return debug_alloc_report_leaks() - before
