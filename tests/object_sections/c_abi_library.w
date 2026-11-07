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


# The pointer and W's own direct call both go through the symbol, so a
# strong C definition replaces the weak body for them too (C semantics).
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


# Brace-initialized data under --c-abi: a function item holds the System
# V entry (defined before or after the table), an extern C function the
# C symbol, so C calls straight through the table.
extern int c_scale(int x)

struct ops:
	unary* run
	unary* later
	unary* from_c
	int* data

@section(".w_ops") @align(32)
ops[2] w_ops_table = {real, late_op, c_scale, &table_a,
	init_level1, real, late_op, &table_b}


int late_op(int x):
	return x - 1


# @section/@align place and align an array's elements (its symbol); the
# W header that W code indexes through stays behind in .data.
@section(".w_vector") @align(64)
int32[4] w_vector = {int32 1, int32 2, int32 3, int32 4}

# All-zero arrays still land in .bss.
int32[16] w_zero_array = {}
int32[16] w_plain_array


int w_vector_sum():
	int sum = 0
	for i in range(4): sum = sum + w_vector[i]
	return sum


int w_zero_sum():
	int sum = 0
	for i in range(16): sum = sum + w_zero_array[i] + w_plain_array[i]
	return sum


int w_ops_call(int i, int x):
	ops* o = &w_ops_table[i]
	return o.run(x) + o.later(x) + o.from_c(x) + o.data[0]
