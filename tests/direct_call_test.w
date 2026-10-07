# wbuild: x64
# wbuild: step="bin/wv2 --no-direct-calls tests/direct_call_test.w -o bin/direct_call_indirect_test"
# wbuild: step="bin/direct_call_indirect_test"
# Direct calls (docs/projects/codegen_gap_plan.md §2.4, unit A4): a call
# whose callee is a known W function is one `call rel32` with no
# callee word parked on the stack (grammar/stack_slot.w's call records,
# compiler/symbol_table.w's rel32 chains). Every call shape the emitter
# distinguishes is exercised here, each asserting a computed value, so
# the test passes whether or not a given call went direct -- what it
# pins is that the lowering never changes what a program computes:
# backward and forward references, a function called before and after
# its definition, direct and mutual recursion (across an import),
# generic instantiations (explicit before and after the drain, inferred,
# recursive, forward), nested calls whose first argument is itself a
# call based at the same stack position, struct returns through the
# hidden buffer, method and operator-overload calls, W variadics, calls
# inside loops that own registers, an asm-body callee, f-strings and
# print (the lazily imported runtime helpers), defer, generators, and
# the shapes that stay indirect: function-pointer values and calls, a
# parenthesized callee, a function passed as a value. The third step
# runs the same program built with --no-direct-calls.
import lib.lib
import lib.assert
import lib.generator
import tests.direct_call_helper


# --- backward reference, recursion ------------------------------------------
int dc_fact(int n):
	if (n <= 1): return 1
	return n * dc_fact(n - 1)


# --- called before and after its definition ----------------------------------
int dc_later(int x);


int dc_before(int x):
	return dc_later(x) + 1


int dc_later(int x):
	return x * 3


int dc_after(int x):
	return dc_later(x) + 2


# --- mutual recursion across the import --------------------------------------
int dc_even(int n):
	if (n == 0): return 1
	return dc_helper_odd(n - 1)


# --- struct returns ------------------------------------------------------------
struct dc_pair:
	int a
	int b


dc_pair dc_make(int x):
	dc_pair p
	p.a = x
	p.b = x * 10
	return p


int dc_take(dc_pair p):
	return p.a + p.b


dc_pair dc_swap(dc_pair p):
	dc_pair q
	q.a = p.b
	q.b = p.a
	return q


# --- methods and operator overloads --------------------------------------------
int dc_pair_sum(dc_pair* self):
	return self.a + self.b


dc_pair dc_pair_scaled(dc_pair* self, int k):
	dc_pair q
	q.a = self.a * k
	q.b = self.b * k
	return q


dc_pair operator+(dc_pair x, dc_pair y):
	dc_pair q
	q.a = x.a + y.a
	q.b = x.b + y.b
	return q


# --- W variadics ------------------------------------------------------------
int dc_sum(int... values):
	int s = 0
	int i = 0
	while (i < values.length):
		s = s + values[i]
		i = i + 1
	return s


int dc_sum_from(int base, int... values):
	return base * 1000 + dc_sum(values[0], values[1])


# --- generics ---------------------------------------------------------------
int dc_forward_generic(int x):
	return dc_twice[int](x)


T dc_twice[T](T x):
	return x + x


# instantiated after dc_twice$int exists, so its body's explicit call
# meets an already-defined instantiation (a plain known function)
T dc_relay[T](T x):
	return dc_twice[T](x) + dc_twice[T](1)


T dc_gpow[T](T x, int n):
	if (n == 0): return 1
	return x * dc_gpow[T](x, n - 1)


# --- an asm-body callee ------------------------------------------------------
int dc_asm_add(int a, int b):
	asm x86:
		"mov eax,[esp+8]"
		"add eax,[esp+4]"
		"ret"
	asm x64:
		"mov rax,[rsp+0x10]"
		"add rax,[rsp+8]"
		"ret"
	return a + b


# --- function pointers: the callee is a value, the call stays indirect ------
type dc_binop = fn(int, int) -> int


int dc_mul(int a, int b):
	return a * b


int dc_apply(dc_binop* f, int a, int b):
	return f(a, b)


# --- calls inside loops (loop-owned registers are parked around them) -------
int dc_loop_calls(int n):
	list[int] lst = new list[int]
	for k in range(8): lst.push(k * 5)
	int s = 0
	int i = 0
	int j = 7
	while (i < n):
		# list indexing is a hidden runtime call (__w_list_addr, now a
		# direct one) the loop's register pass does not see: the loop
		# owns caller-saved registers that the call parks and reloads
		s = s + lst[i] + j
		i = i + 1
		j = j + 1
	return s * 100 + j


int dc_loop_overload(int n):
	int s = 0
	int i = 0
	dc_pair acc = dc_make(0)
	dc_pair step = dc_make(1)
	while (i < n):
		# an operator overload is a call the scan does not see either
		acc = acc + step
		s = s + acc.a
		i = i + 1
	return s * 100 + acc.b


# --- defer and generators ---------------------------------------------------
int dc_defer_log
int dc_with_defer(int x):
	defer dc_defer_log = dc_defer_log + dc_later(x)
	return dc_before(x)


generator int dc_gen(int n):
	int i = 0
	while (i < n):
		yield dc_fact(i)
		i = i + 1


# --- nested calls based at the same stack position --------------------------
int dc_id(int x):
	return x


int dc_add3(int a, int b, int c):
	return a + 10 * b + 100 * c


void test_references():
	assert_equal(120, dc_fact(5))
	assert_equal(7, dc_before(2))
	assert_equal(8, dc_after(2))
	assert_equal(1, dc_even(4))
	assert_equal(0, dc_even(5))
	assert_equal(0, dc_helper_odd(4))
	assert_equal(1, dc_helper_odd(3))


void test_nesting():
	assert_equal(321, dc_add3(dc_id(1), dc_id(dc_id(2)), dc_fact(dc_id(3)) / 2))
	assert_equal(44, dc_take(dc_make(4)))
	assert_equal(44, dc_take(dc_swap(dc_make(4))))
	dc_pair p = dc_swap(dc_make(5))
	assert_equal(50, p.a)
	assert_equal(5, p.b)
	dc_box b
	b.lo = 3
	b.hi = 4
	assert_equal(7, dc_box_sum(b))
	# an argument that is itself a struct-returning call
	assert_equal(55, dc_take(dc_swap(dc_make(5))) + dc_take(dc_make(0)) * 0)


void test_methods_and_operators():
	dc_pair p = dc_make(6)
	assert_equal(66, p.sum())
	assert_equal(132, p.scaled(2).sum())
	dc_pair q = p + dc_make(1)
	assert_equal(7, q.a)
	assert_equal(70, q.b)
	assert_equal(77, (p + dc_make(1)).sum())


void test_variadics():
	assert_equal(6, dc_sum(1, 2, 3))
	assert_equal(0, dc_sum())
	assert_equal(2005, dc_sum_from(2, 2, 3))
	assert_equal(10, dc_sum(dc_id(1), dc_id(2), dc_id(3), dc_id(4)))


void test_generics():
	assert_equal(14, dc_forward_generic(7))
	assert_equal(8, dc_twice[int](4))
	assert_equal(8, dc_twice(4))
	assert_equal(81, dc_gpow[int](3, 4))
	assert_equal(2, dc_twice[int](dc_id(1)))
	assert_equal(12, dc_relay[int](5))


void test_asm_body():
	assert_equal(7, dc_asm_add(3, 4))
	assert_equal(12, dc_asm_add(dc_asm_add(1, 2), dc_asm_add(4, 5)))


void test_function_values():
	assert_equal(12, dc_apply(dc_mul, 3, 4))
	assert_equal(7, dc_apply(dc_asm_add, 3, 4))
	dc_binop* f = dc_mul
	assert_equal(20, f(4, 5))
	# a parenthesized known callee is still a direct call (the AST
	# emitter drops the grouping, so the streaming side must agree)
	assert_equal(20, (dc_mul)(4, 5))
	assert_equal(30, ((dc_mul))(5, 6))
	assert_equal(9, (dc_mul)(1, 2) + (dc_asm_add)(3, 4))
	assert_equal(1, (dc_even)((dc_id)(4)))
	assert_equal(7, (dc_apply)((dc_asm_add), 3, 4))
	asserts(c"a function compared with itself", dc_mul == dc_mul)
	asserts(c"distinct functions differ", cast(int, dc_mul) != cast(int, dc_asm_add))
	int addr = cast(int, dc_fact)
	asserts(c"a function value is an address", addr != 0)


void test_loops():
	# lst[0..4] = 0 5 10 15 20, j = 7..11, then j = 12
	assert_equal((0 + 5 + 10 + 15 + 20 + 7 + 8 + 9 + 10 + 11) * 100 + 12, dc_loop_calls(5))
	assert_equal((1 + 2 + 3 + 4 + 5) * 100 + 50, dc_loop_overload(5))


void test_defer_and_generators():
	dc_defer_log = 0
	assert_equal(7, dc_with_defer(2))
	assert_equal(6, dc_defer_log)
	int total = 0
	for v in dc_gen(4): total = total + v
	assert_equal(1 + 1 + 2 + 6, total)


void test_runtime_helpers():
	# f-strings and print lower to lazily imported runtime helpers,
	# called directly once the module is compiled
	char* s = f"{dc_fact(4)}-{dc_id(5)}"
	assert_strings_equal(c"24-5", s)
	list[int] l = list[int]{dc_id(3), dc_fact(3), 1}
	assert_equal(3, l.length)
	assert_equal(6, l[1])
	l.push(dc_id(9))
	assert_equal(9, l[3])
	print(dc_fact(3))
	println(c"")


int main():
	test_references()
	test_nesting()
	test_methods_and_operators()
	test_variadics()
	test_generics()
	test_asm_body()
	test_function_values()
	test_loops()
	test_defer_and_generators()
	test_runtime_helpers()
	println(c"direct_call_test passed")
	return 0
