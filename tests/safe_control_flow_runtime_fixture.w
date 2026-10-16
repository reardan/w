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


int main():
	int before = debug_alloc_report_leaks()
	if control_flow_cleanup(1) != 3: return 1
	if control_flow_cleanup(0) != 14: return 2
	return debug_alloc_report_leaks() - before
