# Runtime trap input: reading a missing char* key must print the key to
# stderr and exit 1 (issue #188). Asserted by container_trap_test.
void main():
	map[char*, int] m = new map[char*, int]
	m[c"apple"] = 1
	int x = m[c"banana"]
	print(x)
