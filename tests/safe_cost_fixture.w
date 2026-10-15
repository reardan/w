# Fixed corpus for docs/projects/safe_mode.md cost measurements.
int main():
	int i = 0
	int sum = 0
	while i < 1000000:
		own int* p = new int
		*p = i % 31
		sum = sum + *p
		i = i + 1
	if sum != 14999971: return 1
	return 0
