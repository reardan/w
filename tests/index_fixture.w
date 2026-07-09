import lib.lib

struct index_fixture_point:
	int x
	int y

int index_fixture_helper(int a):
	return a + 1

int index_fixture_caller(int a):
	return index_fixture_helper(a) + index_fixture_helper(a + 1)

int index_fixture_use_struct(index_fixture_point p):
	return p.x + p.y
