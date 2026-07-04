# Compile-only fixture: map values share the list element storage rules,
# so fixed arrays (and structs containing them) are rejected.
int main():
	map[int, int[3]] m = new map[int, int[3]]
	return 0
