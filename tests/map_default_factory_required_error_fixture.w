# A stored default value for a pointer or container value type would
# alias the same object across every missing key, so those value types
# require a factory function (issue #327). Asserted by
# map_set_builtin_test in build.base.json.
int main():
	map[char*, map[char*, int]] m = new map[char*, map[char*, int]](new map[char*, int])
	return 0
