# Runtime trap input: an out-of-range list index must print the index and
# length to stderr and exit 1 (issue #188). Asserted by container_trap_test.
void main():
	list[int] l = list[int]{1, 2}
	int x = l[5]
	print(x)
