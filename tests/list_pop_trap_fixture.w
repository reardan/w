# Runtime trap input: pop on an empty list must say so on stderr and
# exit 1 (issue #188). Asserted by container_trap_test.
void main():
	list[int] l = new list[int]
	int x = l.pop()
	print(x)
