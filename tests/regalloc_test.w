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


# --- R3: compound operators and the register-operand folds -----------------
# (docs/projects/register_allocation_pgo.md §2.3). Compound assignment
# and '++'/'--' on a promoted local emit 'op R,X' in place; 'x = x op y'
# and 'x = y op x' fold the same way; a binary operator or compare whose
# operands are register reads, constants or local loads uses them as
# direct operands. The expected values come from gcc-compiled C twins of
# the same functions (the oracle is independent of this compiler).

# every compound operator between registers, with a constant, and the
# division/modulo/shift forms that keep the accumulator path
int compound_registers(int n):
	int a = 1
	int b = 2
	int i = 0
	while (i < n):
		a += i
		b += 3
		a -= 1
		b *= 2
		a |= 8
		b &= 0xffff
		a ^= i
		b <<= 1
		a >>= 1
		b /= 3
		a %= 1000
		i++
	return a * 100000 + b


# compound operands that are stack locals (m is loop-invariant, a/b/c
# compete for the register budget on x86) and prefix/postfix forms
int compound_stack(int n):
	int a = 7
	int b = 11
	int c = 13
	int i = 0
	int m = n * 3
	while (i < n):
		a += m
		b -= m
		c += a
		a += b
		b -= c
		a++
		--b
		i++
	return a + b * 7 + c * 1000


# 'x = x op y', 'x = y op x' (commutative only), non-commutative with the
# register on the right (no fold), small and negative constants
int assign_shapes(int n):
	int s = 0
	int t = 1000
	int u = 5
	int i = 0
	while (i < n):
		s = s + i
		t = t - i
		u = i + u
		s = s * 3
		t = t & 0xfff
		u = u | i
		s = s ^ t
		t = i - t
		u = u + 100000
		s = s + (-7)
		u = u - 200000
		i = i + 1
	return s + t * 3 + u * 5


# compares between registers, against constants and locals, in branch
# and in value context
int compare_shapes(int n):
	int i = 0
	int j = n
	int hits = 0
	while (i < n):
		if (i < j): hits += 1
		if (i == j): hits += 10
		if (j > 3): hits += 100
		if (i >= 2): hits += 1000
		hits += (i < j)
		hits += (j <= i) * 7
		hits += (i != 4) * 3
		i++
		j--
	return hits


# the value of a register assignment used inside a larger expression
int value_kept(int n):
	int x = 0
	int y = 0
	int z = 0
	int i = 0
	while (i < n):
		y = (x += 2) * 3
		z = (x = x + 1) + y
		i = i + 1
	return x * 1000000 + y * 1000 + z


# a promoted pointer indexed by a promoted counter: the shuttle's
# 'mov ebx,R' form feeds an address computation and a store
int pointer_shapes(int n):
	int* p = cast(int*, malloc(16 * __word_size__))
	int i = 0
	int s = 0
	while (i < 16):
		p[i] = i * 3
		i++
	i = 0
	while (i < n):
		s = s + p[i]
		p[i] = p[i] + s
		s += p[i]
		i += 1
	int r = s + p[0] + p[n - 1]
	free(p)
	return r


# constants past the signed-byte immediate form, negative ones, masks
int large_constants(int n):
	int s = 1
	int t = 2
	int i = 0
	while (i < n):
		s = s + 1000000
		t = t - 70000
		s = s * 3
		t = t ^ 0x7fff
		s = s & 0x3fffffff
		t = t | 0x10000
		s = s + (-1000000)
		i = i + 1
	return s + t


# narrow and unsigned operands never fold into a word-sized ALU operand
int narrow_and_unsigned(int n):
	int8 c = 3
	uint32 u = 3000000
	int s = 0
	int i = 0
	while (i < n):
		s = s + c
		s = s + u
		s = s - c
		c = c + 1
		s += c
		i++
	return s


# division, modulo and variable shifts between registers keep the
# accumulator path (edx/ecx operands)
int div_and_shift(int n):
	int a = 1000000
	int b = 7
	int c = 3
	int i = 0
	while (i < n):
		a = a / b
		a = a + (a % c)
		a = a << c
		a = a >> b
		a = a * b + c
		a /= 2
		a %= 100000
		a <<= 1
		a >>= 1
		i++
	return a


# 'i * k' at the end of a line is a product, not a 'T* name' declaration:
# k stays a candidate (function-level and loop-scoped alike)
int star_operand(int n, int m):
	int s = 0
	int k = m
	int i = 0
	while (i < n):
		s = s + i * k
		k = k - 1
		i = i + 1
	return s * 100 + k


void test_r3_shapes():
	assert_equal(4606, star_operand(4, 10))
	assert_equal(3, star_operand(0, 3))
	assert_equal(100002, compound_registers(0))
	assert_equal(600020, compound_registers(3))
	assert_equal(100218, compound_registers(10))
	assert_equal(56757, compound_stack(3))
	assert_equal(-1342882, compound_stack(7))
	assert_equal(-1996233, assign_shapes(4))
	assert_equal(-1188348, assign_shapes(9))
	assert_equal(4352, compare_shapes(6))
	assert_equal(7662, compare_shapes(9))
	assert_equal(9024033, value_kept(3))
	assert_equal(15042057, value_kept(5))
	assert_equal(153, pointer_shapes(4))
	assert_equal(884529, pointer_shapes(16))
	assert_equal(1971696, large_constants(1))
	assert_equal(25840648, large_constants(3))
	assert_equal(6000009, narrow_and_unsigned(2))
	assert_equal(15000030, narrow_and_unsigned(5))
	assert_equal(31249, div_and_shift(1))
	assert_equal(1, div_and_shift(4))


# --- R3: loop-scoped caller-saved registers ---------------------------------
# Call-free loops may hold their hot locals (and a for-range's hidden end/
# step words) in caller-saved registers on x64; every other width and target
# keeps the stack shape. Values are the gcc oracle's (scratch oracle2.c).
int loop_helper(int x): return x * 2 + 1


int loop_args(int n, int m):
	int s = 0
	int i = 0
	while (i < n):
		s = s + i * m
		m = m - 1
		i = i + 1
	return s * 1000 + m + n


int loop_break_continue(int n):
	int a = 0
	int b = 0
	int c = 0
	int i = 0
	while (i < n):
		i = i + 1
		if (i == 3): continue
		a = a + i
		b = b + a
		if (b > 50): break
		c = c + 1
	return a * 10000 + b * 100 + c + i


int loop_return_inside(int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + i * 3
		if (s > 40): return s * 10 + i
		i = i + 1
	return s


int loop_nested(int n):
	int a = 1
	int b = 2
	int c = 3
	int d = 4
	int e = 5
	int f = 6
	int g = 7
	int h = 8
	int s = 0
	int i = 0
	while (i < n):
		int j = 0
		while (j < n):
			s = s + i * j + a - b + c - d + e - f + g - h
			a = a + 1
			b = b + 2
			c = c + 3
			d = d + 4
			e = e + 5
			f = f + 6
			g = g + 7
			h = h + 8
			j = j + 1
		s = s + loop_helper(i)
		i = i + 1
	return s + a + b + c + d + e + f + g + h


# list indexing is a hidden runtime call: the loop keeps its registers but
# spills them around each call
int loop_hidden_call(int n):
	list[int] lst = new list[int]
	int i = 0
	int s = 0
	int t = 7
	for k in range(8): lst.push(k * 5)
	while (i < n):
		s = s + lst[i] + t
		t = t + 1
		i = i + 1
	return s * 100 + t


int loop_declared_inside(int n):
	int s = 0
	int i = 0
	while (i < n):
		int t = i * 2
		if (i & 1):
			int u = t + 1
			s = s + u
		else:
			int u = t - 1
			s = s + u * 2
		int v = s + t
		s = s + v
		i = i + 1
	return s


int loop_step(int n):
	int s = 0
	for i in range(2, n, 3): s = s + i
	int k = n
	while (k > 0):
		s = s * 2 + k
		k -= 2
	for a in range(1, n):
		for b in range(a, n): s = s + a * b
	return s


int loop_switch(int n):
	int s = 0
	int k = 0
	int i = 0
	while (i < n):
		switch (i % 4):
			case 0: s = s + 1
			case 1: s = s + 10
			case 2: k = k + 1
			default: s = s + 100
		i = i + 1
		if (k > 2): break
	return s * 10 + k + i


int loop_pointer_param(int* p, int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + p[i]
		p[i] = s
		i = i + 1
	return s + p[0]


int loop_global_t = 1000
int loop_shadow_global(int n):
	int s = 0
	int i = 0
	while (i < n):
		int local_t = i + 1
		s = s + local_t + loop_global_t
		i = i + 1
	return s


int loop_one_liner(int n):
	int s = 0
	for i in range(n): s = s + loop_helper(i)
	return s + n


void test_r3_loops():
	assert_equal(46010, loop_args(4, 10))
	assert_equal(3, loop_args(0, 3))
	assert_equal(122309, loop_break_continue(5))
	assert_equal(256612, loop_break_continue(20))
	assert_equal(9, loop_return_inside(3))
	assert_equal(455, loop_return_inside(10))
	assert_equal(198, loop_nested(3))
	assert_equal(-239, loop_nested(5))
	assert_equal(3910, loop_hidden_call(3))
	assert_equal(22415, loop_hidden_call(8))
	assert_equal(52, loop_declared_inside(4))
	assert_equal(680, loop_declared_inside(7))
	assert_equal(108, loop_step(5))
	assert_equal(4737, loop_step(12))
	assert_equal(1227, loop_switch(6))
	assert_equal(2344, loop_switch(20))
	int* buf = cast(int*, malloc(6 * __word_size__))
	for i in range(6): buf[i] = i + 1
	assert_equal(22, loop_pointer_param(buf, 6))
	assert_equal(4010, loop_shadow_global(4))
	assert_equal(30, loop_one_liner(5))


# --- A1: pointer and struct-pointer bases in registers ----------------------
# (docs/projects/codegen_gap_plan.md §2.1, unit A1). A subscripted or
# field-accessed pointer local or argument competes for a register like
# a scalar; grammar/postfix_expr.w adds the register to the scaled index
# in place of the parked base. Array locals, struct values and
# address-taken names stay on the stack, and a base written inside its
# own subscript keeps the stack path's "old value" reading. Values are
# the gcc oracle's (scratch oracle_a1.c, the same functions in C).
struct a1_node:
	int value
	int* items
	a1_node* next


struct a1_box:
	pair inner
	int tag


int a1_sum_pointer_arg(int* p, int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + p[i]
		i = i + 1
	return s


int a1_store_elements(int* p, int n):
	int i = 0
	while (i < n):
		p[i] = i * 3
		i = i + 1
	int s = 0
	i = 0
	while (i < n):
		s = s + p[i]
		p[i] = p[i] + 1
		p[i] += 2
		p[i]++
		s = s + p[i]
		i = i + 1
	return s + p[n - 1]


int a1_local_pointer_bases(int* a, int* b, int n):
	int* p = a
	int* q = b
	int s = 0
	int i = 0
	while (i < n):
		s = s + p[i] * q[i]
		q[i] = p[i] - q[i]
		i = i + 1
	return s + q[0]


int a1_struct_pointer_fields(a1_node* head, int n):
	a1_node* cur = head
	int s = 0
	int i = 0
	while (i < n):
		cur.value = cur.value + i
		s = s + cur.value
		cur.value += 2
		cur.value++
		int* it = cur.items
		s = s + it[i] + cur.items[i]
		cur.items[i] = s
		cur = cur.next
		i = i + 1
	return s + head.value


int a1_nested_pointers(int** rows, int n):
	int s = 0
	int i = 0
	while (i < n):
		int j = 0
		while (j < n):
			s = s + rows[i][j]
			rows[i][j] = s
			j = j + 1
		i = i + 1
	return s + rows[n - 1][n - 1]


int a1_array_of_structs(pair* ps, int n):
	int s = 0
	int i = 0
	while (i < n):
		ps[i].a = i + 1
		ps[i].b = ps[i].a * 2
		s = s + ps[i].a + ps[i].b
		i = i + 1
	return s + ps[0].b


int a1_nested_field(a1_box* b, int n):
	int s = 0
	int i = 0
	while (i < n):
		b.inner.a = b.inner.a + i
		b[i].tag = i * 7
		b[i].inner.b = b.inner.a
		s = s + b.inner.a + b[i].tag + b[i].inner.b
		i = i + 1
	return s


int a1_address_and_subscript(int n):
	int[8] storage
	int* p = storage
	int** pp = &p
	int s = 0
	int i = 0
	while (i < n):
		p[i] = i + 5
		s = s + (*pp)[i] + p[i]
		i = i + 1
	return s


int a1_element_and_field_address(int* p, a1_node* nd, int n):
	int s = 0
	int i = 0
	while (i < n):
		int* e = &p[i]
		*e = *e + i
		int* v = &nd.value
		*v = *v + p[i]
		s = s + p[i] + nd.value
		i = i + 1
	return s


int a1_array_local(int n):
	int[16] arr
	int i = 0
	while (i < n):
		arr[i] = i * i
		i = i + 1
	int s = 0
	i = 0
	while (i < n):
		s = s + arr[i]
		i = i + 1
	return s


int a1_struct_local(int n):
	pair pr
	pr.a = 1
	pr.b = 0
	int i = 0
	while (i < n):
		pr.b = pr.b + pr.a
		pr.a = pr.a + 1
		i = i + 1
	return pr.a * 1000 + pr.b


int a1_zero_of(int* r): return 0


int a1_base_written_in_index(int* p, int* q, int n):
	int s = 0
	int i = 0
	while (i < n):
		int* old = p
		s = s + p[a1_zero_of(p = q)]
		p = old
		i = i + 1
	return s


int a1_node_bump(a1_node* nd, int k):
	nd.value = nd.value + k
	return nd.value


int a1_pointer_across_calls(a1_node* head, int n):
	a1_node* cur = head
	int s = 0
	int i = 0
	while (i < n):
		s = s + a1_node_bump(cur, i) + cur.value + cur.items[i]
		i = i + 1
	return s


int a1_count_char(char* s, int n, int ch):
	int c = 0
	int i = 0
	while (i < n):
		if (s[i] == ch): c = c + 1
		s[i] = s[i] + 1
		i = i + 1
	return c * 100 + s[0]


int a1_int_base(int base, int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + base[i]
		i = i + 1
	return s


void test_a1_bases():
	int* buf = cast(int*, malloc(16 * __word_size__))
	int* buf2 = cast(int*, malloc(16 * __word_size__))
	for i in range(16):
		buf[i] = i + 1
		buf2[i] = 2
	assert_equal(0, a1_sum_pointer_arg(buf, 0))
	assert_equal(120, a1_sum_pointer_arg(buf, 15))
	assert_equal(8, a1_store_elements(buf, 1))
	assert_equal(225, a1_store_elements(buf, 8))
	for i in range(16):
		buf[i] = i + 1
		buf2[i] = 2
	assert_equal(1, a1_local_pointer_bases(buf, buf2, 1))
	assert_equal(239, a1_local_pointer_bases(buf, buf2, 15))
	a1_node nd
	nd.value = 0
	nd.items = buf2
	nd.next = &nd
	for i in range(16): buf2[i] = i
	assert_equal(0, a1_struct_pointer_fields(&nd, 0))
	assert_equal(3, a1_struct_pointer_fields(&nd, 1))
	assert_equal(3, a1_struct_pointer_fields(&nd, 0))
	nd.value = 0
	for i in range(16): buf2[i] = i
	assert_equal(143, a1_struct_pointer_fields(&nd, 6))
	int** rows = cast(int**, malloc(4 * __word_size__))
	for i in range(4):
		rows[i] = cast(int*, malloc(4 * __word_size__))
		for j in range(4): rows[i][j] = i * 4 + j
	assert_equal(0, a1_nested_pointers(rows, 1))
	assert_equal(240, a1_nested_pointers(rows, 4))
	pair* ps = cast(pair*, malloc(8 * sizeof(pair)))
	assert_equal(5, a1_array_of_structs(ps, 1))
	assert_equal(110, a1_array_of_structs(ps, 8))
	a1_box* boxes = cast(a1_box*, malloc(8 * sizeof(a1_box)))
	for i in range(8):
		boxes[i].inner.a = 0
		boxes[i].inner.b = 0
		boxes[i].tag = 0
	assert_equal(0, a1_nested_field(boxes, 1))
	assert_equal(175, a1_nested_field(boxes, 6))
	assert_equal(0, a1_address_and_subscript(0))
	assert_equal(136, a1_address_and_subscript(8))
	for i in range(16): buf[i] = i + 1
	nd.value = 0
	assert_equal(0, a1_element_and_field_address(buf, &nd, 0))
	assert_equal(268, a1_element_and_field_address(buf, &nd, 8))
	assert_equal(0, a1_array_local(0))
	assert_equal(1240, a1_array_local(16))
	assert_equal(1000, a1_struct_local(0))
	assert_equal(8028, a1_struct_local(7))
	for i in range(16):
		buf[i] = i + 1
		buf2[i] = 50
	assert_equal(0, a1_base_written_in_index(buf, buf2, 0))
	assert_equal(5, a1_base_written_in_index(buf, buf2, 5))
	nd.value = 0
	nd.items = buf
	assert_equal(0, a1_pointer_across_calls(&nd, 0))
	assert_equal(91, a1_pointer_across_calls(&nd, 6))
	char* text = strclone(c"abcabcabca")
	assert_equal(498, a1_count_char(text, 10, 'a'))
	assert_equal(99, a1_count_char(text, 10, 'a'))
	free(text)
	text = strclone(c"\x01\x02\x03\x04")
	assert_equal(10, a1_int_base(cast(int, text), 4))
	free(text)


# --- A1: arguments at function level ----------------------------------------
# A pointer or int argument the body subscripts or field-accesses in a
# loop (with calls inside, so R3's loop registers do not apply) takes a
# callee-saved register in the prologue; an address-taken argument and a
# struct-valued one keep the stack.
int a1_arg_across_calls(a1_node* nd, int* p, int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + a1_node_bump(nd, p[i]) + nd.value + p[i] + nd.items[i]
		p[i] = s
		nd.value = nd.value - 1
		i = i + 1
	return s + nd.value + p[0]


int a1_arg_recursive(int* p, int n, int depth):
	int s = 0
	int i = 0
	while (i < n):
		s = s + p[i]
		if (depth > 0): s = s + a1_arg_recursive(p, n - 1, depth - 1)
		i = i + 1
	return s


int a1_set_through(int** pp, int v):
	**pp = v
	return v


int a1_arg_address_taken(int* p, int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + p[i] + a1_set_through(&p, i)
		i = i + 1
	return s


int a1_pair_sum(pair q): return q.a + q.b


int a1_arg_struct_value(pair pr, int n):
	int s = 0
	int i = 0
	while (i < n):
		pr.a = pr.a + i
		s = s + pr.b + a1_pair_sum(pr)
		i = i + 1
	return s + pr.a


void test_a1_arguments():
	int* buf = cast(int*, malloc(16 * __word_size__))
	int* buf2 = cast(int*, malloc(16 * __word_size__))
	for i in range(16):
		buf[i] = i + 1
		buf2[i] = i * 2
	a1_node nd
	nd.value = 0
	nd.items = buf2
	nd.next = &nd
	assert_equal(1, a1_arg_across_calls(&nd, buf, 0))
	assert_equal(151, a1_arg_across_calls(&nd, buf, 6))
	for i in range(16): buf[i] = i + 1
	assert_equal(6, a1_arg_recursive(buf, 3, 0))
	assert_equal(365, a1_arg_recursive(buf, 5, 3))
	assert_equal(0, a1_arg_address_taken(buf, 0))
	assert_equal(25, a1_arg_address_taken(buf, 5))
	pair pr
	pr.a = 3
	pr.b = 4
	assert_equal(3, a1_arg_struct_value(pr, 0))
	assert_equal(88, a1_arg_struct_value(pr, 5))
	assert_equal(3, pr.a)


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
	test_r3_shapes()
	test_r3_loops()
	test_a1_bases()
	test_a1_arguments()
	println(c"regalloc_test passed")
	return 0
