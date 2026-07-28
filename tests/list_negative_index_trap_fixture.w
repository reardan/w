# Runtime trap input: a negative list index below -length must print the
# index as written and the length to stderr and exit 1 (issue #360).
# Asserted by container_trap_test.
void main():
	list[int] l = list[int]{1, 2, 3}
	int x = l[-4]
	print(x)
