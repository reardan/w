# Struct value types take no default in any form (issue #327). Asserted
# by map_set_builtin_test in build.base.json.
struct md_err_point:
	int x
	int y


int main():
	map[int, md_err_point] m = new map[int, md_err_point](0)
	return 0
