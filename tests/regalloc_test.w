# wbuild: x64
# Register promotion of word-sized locals into callee-saved registers
# (docs/projects/register_allocation_pgo.md §2.2 and §2.4, units R2 and
# R2b; compiler/regalloc_scan.w). Every function below contains a loop,
# so the pre-scan ranks its locals and the top ones live in esi/edi
# (x86) or r12-r15 (x64) for the whole body. One case per hazard row of
# §2.4: the test asserts computed values only, so it passes whether or
# not a given local was promoted -- what it pins is that promotion
# never changes what a program computes, through calls, defer, goto,
# raw_asm, setjmp/longjmp, threads, generators, shadowing, multiple
# assignment, ternaries, pointers, f-strings, compound assignment,
# struct returns, generics, variadics, narrow and float locals, range
# and container loops, recursion and register pressure past the
# budget. regalloc_diff_test compares the same programs built with and
# without --no-regs; the compiler's own self-host fixpoint is the
# third gate.
import lib.lib
import lib.assert
import lib.setjmp
import lib.generator
import lib.thread
import lib.utf8


struct pair:
	int a
	int b


# --- plain promotion: a loop counter and an accumulator --------------------
int sum_to(int n):
	int i = 0
	int s = 0
	while (i < n):
		s = s + i
		i = i + 1
	return s


void test_sum_to():
	assert_equal(0, sum_to(0))
	assert_equal(45, sum_to(10))
	assert_equal(499500, sum_to(1000))


# --- address-taken locals never promote --------------------------------------
int address_taken(int n):
	int x = 1
	int i = 0
	while (i < n):
		int* p = &x
		*p = *p + i
		i = i + 1
	return x


int* leaked
int address_escapes(int n):
	int x = 5
	leaked = &x
	int i = 0
	while (i < n):
		*leaked = *leaked + 1
		i = i + 1
	return x


void test_address_taken():
	assert_equal(1 + 0 + 1 + 2 + 3, address_taken(4))
	assert_equal(8, address_escapes(3))


# --- aggregates and arrays: excluded by type ---------------------------------
int aggregates(int n):
	pair pr
	pr.a = 0
	pr.b = 1
	int[4] arr
	arr[0] = 0
	int i = 0
	while (i < n):
		pr.a = pr.a + pr.b
		arr[0] = arr[0] + pr.a
		i = i + 1
	return arr[0] + pr.a


int pointer_field(int n):
	pair pr
	pr.a = 0
	pr.b = 0
	pair* pp = &pr
	int i = 0
	while (i < n):
		pp.a = pp.a + i
		pp.b = pp.b + 1
		i = i + 1
	return pp.a * 10 + pp.b


void test_aggregates():
	assert_equal(10 + 4, aggregates(4))
	assert_equal(64, pointer_field(4))


# --- calls inside loops: the callee saves what it uses -----------------------
int callee_loop(int k):
	int t = 0
	int j = 0
	while (j < k):
		t = t + j
		j = j + 1
	return t


int calls_in_loop(int n):
	int i = 0
	int s = 0
	while (i < n):
		s = s + callee_loop(i)
		i = i + 1
	return s


int three(int a, int b, int c):
	return a * 100 + b * 10 + c


int args_from_registers(int n):
	int x = 1
	int y = 2
	int i = 0
	int s = 0
	while (i < n):
		s = s + three(x, y, x + y)
		x = x + 1
		y = y + 1
		i = i + 1
	return s


int call_result(int n):
	int x = 1
	int i = 0
	while (i < n):
		x = callee_loop(x + 2) + 1
		i = i + 1
	return x


void test_calls():
	assert_equal(0 + 0 + 1 + 3 + 6, calls_in_loop(5))
	assert_equal(123 + 235, args_from_registers(2))
	assert_equal(16, call_result(2))


# --- defer reads the register at every exit ----------------------------------
int defer_total

int with_defer(int n):
	int s = 0
	int i = 0
	defer defer_total = defer_total + s
	while (i < n):
		s = s + i
		i = i + 1
		if (s > 20): return -s
	return s


void test_defer():
	defer_total = 0
	assert_equal(10, with_defer(5))
	assert_equal(10, defer_total)
	assert_equal(-21, with_defer(100))
	assert_equal(31, defer_total)


# --- goto and labels: function-scoped promotion is unaffected ---------------
int with_goto(int n):
	int i = 0
	int s = 0
	while (i < 0): i = i + 1
	again:
	s = s + i
	i = i + 1
	if (i < n): goto again
	if (s > 1000): goto done
	s = s * 2
	done:
	return s


void test_goto():
	assert_equal(2 * (0 + 1 + 2 + 3), with_goto(4))
	assert_equal(0, with_goto(0))


# --- raw_asm: the function promotes nothing ----------------------------------
# The asm swaps the two registers R2 would hand out first (esi/edi on
# x86, r12/r13 on x64) and swaps them back before the next statement
# reads a local: were s or i register-resident, 'i = i + 1' in between
# would increment s instead.
int with_raw_asm(int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + i
		if (__word_size__ == 8): raw_asm(c"\x4f\x87\xec")
		else: raw_asm(c"\x87\xf7")
		i = i + 1
		if (__word_size__ == 8): raw_asm(c"\x4f\x87\xec")
		else: raw_asm(c"\x87\xf7")
	return s


void test_raw_asm():
	assert_equal(10, with_raw_asm(5))


# --- setjmp/longjmp ----------------------------------------------------------
jmp_buf env
int jump_total

void jump_now(int v):
	longjmp(&env, v)


# Below the setjmp caller: its promoted locals are live in registers
# when the jump unwinds it; repl_longjmp restores the callee-saved set
# from the buffer. (The longjmp call sits in jump_now: a body that
# names longjmp promotes nothing itself.)
int jumper(int n):
	int i = 0
	int s = 0
	while (i < n):
		s = s + i
		i = i + 1
	jump_total = s
	jump_now(7)
	return 0


# The setjmp caller promotes nothing: base keeps its latest value.
int with_setjmp(int n):
	int base = 0
	int i = 0
	while (i < n):
		base = base + 2
		i = i + 1
	int r = setjmp(&env)
	if (r == 0):
		jumper(n)
		return -1
	return base + r + jump_total


void test_setjmp():
	int acc = 0
	int k = 0
	while (k < 3):
		acc = acc + with_setjmp(4)
		k = k + 1
	assert_equal(3 * (8 + 7 + 6), acc)
	assert_equal(3, k)


# --- threads: each starts with its own registers -----------------------------
int[4] thread_results

void thread_worker(void* arg):
	int k = cast(int, arg)
	int i = 0
	int s = 0
	while (i < 10):
		s = s + i * k
		i = i + 1
	thread_results[k] = s


void test_threads():
	wthread** threads = cast(wthread**, malloc(4 * __word_size__))
	for i in range(4):
		threads[i] = thread_spawn(thread_worker, cast(void*, i))
		asserts(c"thread_spawn", cast(int, threads[i]) != 0)
	int total = 0
	for j in range(4):
		thread_join(threads[j])
		total = total + thread_results[j]
	assert_equal(45 * (0 + 1 + 2 + 3), total)
	free(cast(void*, threads))


# --- generators: bodies promote nothing, consumers promote -------------------
generator int gen_squares(int n):
	int i = 0
	while (i < n):
		yield i * i
		i = i + 1


int consume_generator(int n):
	int total = 0
	int count = 0
	for v in gen_squares(n):
		total = total + v
		count = count + 1
	return total * 100 + count


void test_generators():
	assert_equal((0 + 1 + 4 + 9) * 100 + 4, consume_generator(4))


# --- two declarations of one name: not a candidate ---------------------------
int sibling_blocks(int n):
	int s = 0
	int i = 0
	while (i < n):
		if (i & 1):
			int t = i * 2
			s = s + t
		else:
			int t = i * 3
			s = s + t
		i = i + 1
	return s


void test_shadowing():
	assert_equal(0 + 2 + 6 + 6 + 12, sibling_blocks(5))


# --- multiple assignment -----------------------------------------------------
int fib_multi(int n):
	int a = 0
	int b = 1
	int i = 0
	while (i < n):
		a, b = b, a + b
		i = i + 1
	return a


void test_multi_assign():
	assert_equal(55, fib_multi(10))
	assert_equal(0, fib_multi(0))


# --- ternaries and short-circuit operands ------------------------------------
int ternary_short(int n):
	int s = 0
	int i = 0
	int hits = 0
	while (i < n):
		s = (i & 1) ? s + i : s - 1
		if ((i > 2) && (s > 0)): hits = hits + 1
		if ((i == 0) || (hits > 100)): hits = hits + 10
		i = i + 1
	return s * 1000 + hits


void test_ternary():
	# s: -1, 0, -1, 2, 1, 6 ; hits: 10 (i == 0), +1 at i=3, +1 at i=4, +1 at i=5
	assert_equal(6 * 1000 + 13, ternary_short(6))


# --- pointer locals promote too ----------------------------------------------
int count_a(char* text):
	char* p = text
	int count = 0
	while (*p != 0):
		if (*p == 'a'): count = count + 1
		p = p + 1
	return count


void test_pointers():
	assert_equal(3, count_a(c"banana"))
	assert_equal(0, count_a(c""))


# --- f-strings: the function promotes nothing --------------------------------
int with_fstring(int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + i
		i = i + 1
	if (f"{s}" != s"10"): return -1
	return s


void test_fstring():
	assert_equal(10, with_fstring(5))


# --- compound assignment and increments: excluded ----------------------------
int compound(int n):
	int s = 0
	int i = 0
	int steps = 0
	while (i < n):
		s += i
		i++
		steps = steps + 1
	return s * 100 + steps


void test_compound():
	assert_equal(10 * 100 + 5, compound(5))


# --- struct returns inside the loop ------------------------------------------
pair make_pair(int a, int b):
	pair p
	p.a = a
	p.b = b
	return p


int struct_returns(int n):
	int s = 0
	int i = 0
	while (i < n):
		pair p = make_pair(i, i * 2)
		s = s + p.a + p.b
		i = i + 1
	return s


void test_struct_returns():
	assert_equal(3 * (0 + 1 + 2 + 3), struct_returns(4))


# --- generics --------------------------------------------------------------
T generic_sum[T](T* items, int n):
	T total = 0
	int i = 0
	while (i < n):
		total = total + items[i]
		i = i + 1
	return total


void test_generics():
	int[4] ints
	ints[0] = 1
	ints[1] = 2
	ints[2] = 3
	ints[3] = 4
	assert_equal(10, generic_sum[int](&ints[0], 4))


# --- variadic functions: excluded ---------------------------------------------
int variadic_sum(int... values):
	int s = 0
	int i = 0
	while (i < values.length):
		s = s + values[i]
		i = i + 1
	return s


void test_variadic():
	assert_equal(6, variadic_sum(1, 2, 3))
	assert_equal(0, variadic_sum())


# --- narrow integers and floats: excluded by type ----------------------------
int narrow_and_float(int n):
	int8 small = 0
	uint16 half = 0
	float f = 0.5
	int i = 0
	int big = 0
	while (i < n):
		small = small + 1
		half = half + 3
		f = f + 1.0
		if (f > 3.0): big = big + 1
		i = i + 1
	return small * 1000 + half + big * 100000


void test_narrow():
	assert_equal(5 * 1000 + 15 + 3 * 100000, narrow_and_float(5))


# --- range loops: the loop variable lives in a register (R2b) --------------
int for_ranges(int n):
	int s = 0
	for i in range(n): s = s + i
	for int j in range(2, n): s = s + j * 10
	for k in range(0, n, 3):
		if (k == 3): continue
		s = s + k * 100
	for a in range(n):
		for b in range(a):
			s = s + 1
			if (b == 2): break
	return s


int for_stepped(int hi):
	int s = 0
	for i in range(1, hi, 3): s = s + i
	return s


void test_for_ranges():
	assert_equal(10 + 90 + 0 + 9, for_ranges(5))
	assert_equal(1 + 4 + 7, for_stepped(10))
	assert_equal(0, for_ranges(0))


# --- container loops: loop variables are stored through the register path --
int for_containers():
	list[int] l = list[int]{3, 4, 5}
	int s = 0
	for i, x in l: s = s + i * 10 + x
	map[char*, int] m = new map[char*, int]
	m[c"a"] = 1
	m[c"b"] = 2
	int t = 0
	for char* k, int v in m: t = t + v * (k[0] - 'a' + 1)
	for c in "ab": s = s + c
	return s * 1000 + t


void test_for_containers():
	assert_equal((3 + 14 + 25 + 97 + 98) * 1000 + 5, for_containers())


# --- more locals than registers ------------------------------------------------
int many_locals(int n):
	int a = 1
	int b = 2
	int c = 3
	int d = 4
	int e = 5
	int f = 6
	int i = 0
	while (i < n):
		a = a + i
		b = b + a
		c = c + b
		d = d + c
		e = e + d
		f = f + e
		i = i + 1
	return a + b * 10 + c * 100 + d * 1000 + e * 10000 + f * 100000


void test_many_locals():
	assert_equal(14213094, many_locals(3))


# --- declared inside the loop, used before and after it, recursion ---------
int declared_in_loop(int n):
	int s = 0
	int i = 0
	while (i < n):
		int sq = i * i
		int cube = sq * i
		s = s + sq + cube
		i = i + 1
	return s


int before_after(int n):
	int x = n * 2
	int i = 0
	while (i < n):
		x = x + 1
		i = i + 1
	x = x * 3
	return x + i


int recursive(int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + i
		i = i + 1
	if (n > 0): s = s + recursive(n - 1)
	return s


int with_switch(int n):
	int s = 0
	int i = 0
	while (i < n):
		switch (i % 3):
			case 0: s = s + 1
			case 1: s = s + 10
			default: s = s + 100
		i = i + 1
	return s


void test_lifetimes():
	assert_equal(50, declared_in_loop(4))
	assert_equal(40, before_after(4))
	assert_equal(4, recursive(3))
	assert_equal(2 * 1 + 2 * 10 + 2 * 100, with_switch(6))


int main():
	test_sum_to()
	test_address_taken()
	test_aggregates()
	test_calls()
	test_defer()
	test_goto()
	test_raw_asm()
	test_setjmp()
	test_threads()
	test_generators()
	test_shadowing()
	test_multi_assign()
	test_ternary()
	test_pointers()
	test_fstring()
	test_compound()
	test_struct_returns()
	test_generics()
	test_variadic()
	test_narrow()
	test_for_ranges()
	test_for_containers()
	test_many_locals()
	test_lifetimes()
	println(c"regalloc_test passed")
	return 0
