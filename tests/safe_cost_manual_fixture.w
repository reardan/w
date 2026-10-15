# Equivalent legacy program with explicit destruction.
int main():
	int i = 0
	int sum = 0
	while i < 1000000:
		int* p = new int
		*p = i % 31
		sum = sum + *p
		free(p)
		i = i + 1
	if sum != 14999971: return 1
	return 0
