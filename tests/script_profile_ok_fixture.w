# Ordinary addon code compiles under the script profile: structs and
# 'new', lists, maps, f-strings and print (on-demand runtimes compiled
# as trusted imports), generics, function pointers, integer and float
# casts, cast(int, pointer), a local that shadows a raw built-in's name,
# and the pure swap_endian16 built-in.
# wfixture: --profile=script
# reject_stderr: script profile:
type addon_unary = fn(int) -> int


struct addon_point:
	int x
	int y


T addon_pick[T](T a, T b):
	if (a > b): return a
	return b


int addon_twice(int v):
	return v * 2


int main():
	addon_point* p = new addon_point
	p.x = cast(int, 2.5)
	p.y = addon_pick(3, 4)
	list[int] values = new list[int]
	int bind = 7
	values.push(bind)
	map[int, int] counts = new map[int, int]
	counts[1] = values[0]
	addon_unary* twice = addon_twice
	int address = cast(int, p)
	float ratio = cast(float, p.y)
	print(f"{p.x} {p.y} {counts[1]} {twice(5)} {swap_endian16(1)} {ratio}")
	if (address == 0): return 1
	return 0
# wbuild: fixture_group=script_profile_error_test
