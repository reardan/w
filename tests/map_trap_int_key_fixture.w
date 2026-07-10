# Runtime trap input: reading a missing int key must print the key to
# stderr and exit 1 (issue #188). Asserted by container_trap_test.
void main():
	map[int, int] m = new map[int, int]
	m[7] = 1
	int x = m[-42]
	print(x)
