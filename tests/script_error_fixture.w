# Script mode v1: declarations cannot follow the first top-level
# statement; this fixture asserts the diagnostic.
x := 1
struct too_late:
	int a
