# Section placement and symbol attributes under --c-abi
# (tests/object_sections_test.w links it with c_abi_main.c and
# sections.ld): global symbols are the System V entries, so the initcall
# table holds functions C calls directly.
type unary = fn(int) -> int

int base = 7


@section(".init.text")
static int init_helper(int x):
	return x + base


@section(".init.text") @align(64)
int init_level1(int x):
	return init_helper(x) * 2


# Plain .text between the .init.text functions.
int middle(int x):
	return init_level1(x) + 1


@section(".init.text")
int init_level6(int x):
	return middle(x) + 100


@section(".w_initcall.6")
unary* initcall_level6 = init_level6
@section(".w_initcall.1")
unary* initcall_level1 = init_level1

@section(".w_table")
int table_a = 11
@section(".w_table")
int table_b = 31


@weak
int weak_hook(int x):
	return x + 5


# W's own calls bind to the W body; the pointer goes through the symbol.
int call_hook(int x):
	unary* f = weak_hook
	return f(x) * 1000 + weak_hook(x)


int real(int a):
	return a * 3


@alias("real")
int real_alias(int a);


int call_alias(int a):
	unary* f = real_alias
	return real_alias(a) + f(a)
