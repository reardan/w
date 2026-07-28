# Warning input for the two 'new map[K, V](...)' default type-mismatch
# contexts (issue #327): a factory whose return type does not match the
# value type, and a stored default value of the wrong type. Asserted by
# map_set_builtin_test in build.base.json; the program still compiles.
int mdw_wrong_factory():
	return 1


int main():
	map[char*, char*] a = new map[char*, char*](mdw_wrong_factory)
	map[char*, int] b = new map[char*, int](c"zero")
	return (a.length + b.length) * 0
