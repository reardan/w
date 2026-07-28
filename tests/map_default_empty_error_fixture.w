# The argument-less form only synthesizes a default for container value
# types; scalar maps must spell the default out (issue #327). Asserted
# by map_set_builtin_test in build.base.json.
int main():
	map[char*, int] m = new map[char*, int]()
	return 0
