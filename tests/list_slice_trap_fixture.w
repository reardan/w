# Runtime trap input: a list slice end past the length must print the
# offending bound and the length to stderr and exit 1 (issue #360).
# Asserted by container_trap_test.
void main():
	list[int] l = list[int]{1, 2, 3}
	list[int] s = l[1:9]
	print(s.length)
