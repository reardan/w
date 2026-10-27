# wbuild: x64 arch=arm64
# wbuild: target=regalloc_arm64_variants_test tag=tests_arm64 dep=wv2 dep=wrun
# wbuild: step="bin/wv2 arm64 --no-regs tests/regalloc_arm64_test.w -o bin/regalloc_arm64_noregs"
# wbuild: step="bin/wrun arm64 bin/regalloc_arm64_noregs"
# wbuild: step="bin/wv2 arm64 --streaming tests/regalloc_arm64_test.w -o bin/regalloc_arm64_streaming"
# wbuild: step="bin/wrun arm64 bin/regalloc_arm64_streaming"
# wbuild: step="bin/wv2 arm64 --pac=full tests/regalloc_arm64_test.w -o bin/regalloc_arm64_pac_full"
# wbuild: step="bin/wrun arm64 bin/regalloc_arm64_pac_full"
/*
Register promotion on arm64 Linux (issue #801,
docs/projects/register_allocation_pgo.md §6 R4; compiler/regalloc_scan.w,
code_generator/arm64.w): the hottest word-sized locals and arguments of
a body with a loop live in the callee-saved registers x19-x23 for the
whole body. Every case asserts computed values only, so the program
passes whether or not a given local was promoted; it runs on x86, x64
and arm64 (the regalloc_arm64_test_arm64 twin, under qemu), and
regalloc_arm64_variants_test runs the arm64 build again with --no-regs,
with the streaming front end and with --pac=full. Which locals the
promoted arm64 build keeps in registers, and the shape of its loops,
prologues and returns, is what regalloc_arm64_structure_test inspects
in a cross-compiled copy of this program (on any host): the names below
are the ones it looks up.

The boundary cases are the ones a callee-saved register crosses: a call
(the callee saves what it uses), recursion, every return path (the
epilogue restores from the frame), longjmp out of promoted frames
(setjmp saves x19-x23, longjmp restores them), generators and tasks
(gen_switch saves them: a task suspends from inside any function it
calls, so another task's promoted locals occupy the same registers
until it resumes), defer, goto, and the shapes the scan declines
(address-taken locals, a name declared twice, raw_asm, setjmp callers,
f-strings, variadics, narrow and float types).
*/
import lib.lib
import lib.assert
import lib.setjmp
import lib.generator
import lib.task


# --- a loop counter, an accumulator and an argument ---------------------------
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


# --- register pressure: more hot locals than the budget ----------------------
int pressure(int n):
	int a = 1
	int b = 2
	int c = 3
	int d = 4
	int e = 5
	int f = 6
	int g = 7
	int i = 0
	while (i < n):
		a = a + b
		b = b + c
		c = c + d
		d = d + e
		e = e + f
		f = f + g
		g = g + a
		i = i + 1
	return a + b * 3 + c * 5 + d * 7 + e * 11 + f * 13 + g * 17


void test_pressure():
	assert_equal(1 + 2 * 3 + 3 * 5 + 4 * 7 + 5 * 11 + 6 * 13 + 7 * 17, pressure(0))
	# one round: a=3 b=5 c=7 d=9 e=11 f=13 g=10
	assert_equal(3 + 15 + 35 + 63 + 121 + 169 + 170, pressure(1))
	assert_equal(465361, pressure(10))


# --- address-taken locals stay on the stack ----------------------------------
int address_taken(int n):
	int x = 1
	int i = 0
	while (i < n):
		int* p = &x
		*p = *p + i
		i = i + 1
	return x


void test_address_taken():
	assert_equal(1 + 0 + 1 + 2 + 3, address_taken(4))


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
		s = s + callee_loop(i) * 2 + callee_loop(i + 1)
		i = i + 1
	return s


void test_calls():
	# sum over i < 5 of 2*T(i-1) + T(i), T(k) = k(k-1)/2 summed 0..k-1
	int expect = 0
	for k in range(5): expect = expect + ((k * (k - 1)) / 2) * 2 + ((k + 1) * k) / 2
	assert_equal(expect, calls_in_loop(5))


# --- recursion: every frame saves and restores the caller's registers --------
int tree(int depth):
	if (depth <= 0): return 1
	int t = 0
	int i = 0
	while (i < 3):
		t = t + tree(depth - 1) + i
		i = i + 1
	return t


void test_recursion():
	assert_equal(1, tree(0))
	assert_equal(3 + 3, tree(1))
	assert_equal(3 * 6 + 3, tree(2))
	assert_equal(3 * 21 + 3, tree(3))


# --- early returns: every exit restores the saved registers -------------------
int early_exit(int n, int stop):
	int i = 0
	int s = 0
	while (i < n):
		if (i == stop): return s * 1000 + i
		s = s + i
		if (s > 100): return -s
		i = i + 1
	return s


int early_caller(int n):
	int acc = 0
	int k = 0
	while (k < n):
		acc = acc + early_exit(20, k) + early_exit(k, 99) + early_exit(50, 99)
		k = k + 1
	return acc


void test_early_returns():
	assert_equal(3 * 1000 + 3, early_exit(10, 3))
	assert_equal(-105, early_exit(30, 99))
	assert_equal(45, early_exit(10, 99))
	int expect = 0
	for k in range(4):
		int s = 0
		for j in range(k): s = s + j
		expect = expect + s * 1000 + k + s - 105
	assert_equal(expect, early_caller(4))


# --- a name declared twice is not a candidate --------------------------------
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


# --- setjmp/longjmp ----------------------------------------------------------
jmp_buf env
int jump_total

void jump_now(int v):
	longjmp(&env, v)


# Below the setjmp caller: its promoted locals are live in x19.. when
# the jump unwinds it, and nothing of its epilogue runs.
int jumper(int n):
	int i = 0
	int s = 0
	int q = 7
	while (i < n):
		s = s + i * q
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


# The caller of the setjmp caller holds acc and k in x19/x20 across the
# whole jump: longjmp must bring back the values setjmp saw.
void test_setjmp():
	int acc = 0
	int k = 0
	int extra = 5
	while (k < 3):
		acc = acc + with_setjmp(4) + extra
		k = k + 1
	assert_equal(3 * (8 + 7 + 42 + 5), acc)
	assert_equal(3, k)
	assert_equal(5, extra)


# --- generators: the consumer's registers survive every resume ---------------
int square_slowly(int v):
	int r = 0
	int j = 0
	while (j < v):
		r = r + v
		j = j + 1
	return r


generator int gen_squares(int n):
	int i = 0
	while (i < n):
		yield square_slowly(i)
		i = i + 1


int consume_generator(int n):
	int total = 0
	int count = 0
	int bias = 1000
	for v in gen_squares(n):
		total = total + v + bias
		count = count + 1
	return total * 100 + count


void test_generators():
	assert_equal((0 + 1 + 4 + 9 + 4000) * 100 + 4, consume_generator(4))


# --- tasks: a task suspends from inside a promoted function's loop -----------
int task_results_a
int task_results_b

int busy(int k, int rounds):
	int s = 0
	int i = 0
	int w = k * 10
	while (i < rounds):
		s = s + w + i
		task_yield_now()
		i = i + 1
	return s


generator int busy_task(int k):
	int r = busy(k, 6)
	if (k == 1): task_results_a = r
	else: task_results_b = r
	task_finish(r)
	yield 0


void test_tasks():
	task_scheduler* s = task_scheduler_new()
	task* a = task_spawn(s, busy_task(1))
	task* b = task_spawn(s, busy_task(2))
	int marker = 77
	int spins = 0
	while (spins < 3):
		marker = marker + spins
		spins = spins + 1
	assert_equal(0, task_run(s))
	assert_equal(6 * 10 + 15, task_result(a))
	assert_equal(6 * 20 + 15, task_result(b))
	assert_equal(6 * 10 + 15, task_results_a)
	assert_equal(6 * 20 + 15, task_results_b)
	assert_equal(80, marker)
	task_scheduler_free(s)


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


# --- goto and labels ---------------------------------------------------------
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
# The asm swaps the two registers promotion hands out first (x19/x20 on
# arm64, esi/edi on x86, r12/r13 on x64) and swaps them back before the
# next statement reads a local: were s or i register-resident, 'i = i +
# 1' in between would increment s instead. Every branch's raw bytes are
# emitted on every target (the arch test runs at run time), so the x86
# sequences are padded with nops to whole 4-byte words to keep the arm64
# instruction stream aligned.
int with_raw_asm(int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + i
		if (__target_isa__ == 1): raw_asm(c"\xe9\x03\x13\xaa\xf3\x03\x14\xaa\xf4\x03\x09\xaa")
		elif (__word_size__ == 8): raw_asm(c"\x4f\x87\xec\x90")
		else: raw_asm(c"\x87\xf7\x90\x90")
		i = i + 1
		if (__target_isa__ == 1): raw_asm(c"\xe9\x03\x13\xaa\xf3\x03\x14\xaa\xf4\x03\x09\xaa")
		elif (__word_size__ == 8): raw_asm(c"\x4f\x87\xec\x90")
		else: raw_asm(c"\x87\xf7\x90\x90")
	return s


void test_raw_asm():
	assert_equal(10, with_raw_asm(5))


# --- multiple assignment, ternaries, short-circuit operands ------------------
int fib_multi(int n):
	int a = 0
	int b = 1
	int i = 0
	while (i < n):
		a, b = b, a + b
		i = i + 1
	return a


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


void test_expressions():
	assert_equal(55, fib_multi(10))
	assert_equal(0, fib_multi(0))
	assert_equal(6 * 1000 + 13, ternary_short(6))


# --- operators on registers: every ALU form, constants and compares ----------
int operators(int n):
	int x = 3
	int y = 5
	int z = 0
	int i = 0
	while (i < n):
		z = z + (x * y) - (x & y) + (x | y) - (x ^ y)
		x = x + 7
		y = y - 1
		z = z - 4097
		z = z + 70000
		if (x > y): z = z + 1
		if (y < -3): z = z - 2
		if (x == 24): z = z + 100
		if (y != 0): z = z + 1000
		if (i >= 2): z = z * 2
		i = i + 1
	return z


int operators_reference(int n):
	int x = 3
	int y = 5
	int z = 0
	for i in range(n):
		int[1] keep
		keep[0] = x
		int xv = keep[0]
		z = z + (xv * y) - (xv & y) + (xv | y) - (xv ^ y)
		x = x + 7
		y = y - 1
		z = z - 4097
		z = z + 70000
		if (x > y): z = z + 1
		if (y < -3): z = z - 2
		if (x == 24): z = z + 100
		if (y != 0): z = z + 1000
		if (i >= 2): z = z * 2
	return z


void test_operators():
	for n in range(8): assert_equal(operators_reference(n), operators(n))


# --- pointers: subscripts and walks through register bases -------------------
int count_a(char* text):
	char* p = text
	int count = 0
	while (*p != 0):
		if (*p == 'a'): count = count + 1
		p = p + 1
	return count


int dot(int* a, int* b, int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + a[i] * b[i] + a[n - 1 - i]
		i = i + 1
	return s


void test_pointers():
	assert_equal(3, count_a(c"banana"))
	assert_equal(0, count_a(c""))
	int[4] u
	int[4] v
	for k in range(4):
		u[k] = k + 1
		v[k] = 10 * (k + 1)
	assert_equal(10 + 40 + 90 + 160 + 10, dot(&u[0], &v[0], 4))


# --- compound assignment, increments, range loops ----------------------------
int compound(int n):
	int s = 0
	int i = 0
	int steps = 0
	while (i < n):
		s += i
		s -= 1
		s *= 2
		i++
		steps = steps + 1
	return s * 100 + steps


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


void test_compound_and_ranges():
	# s: (0-1)*2=-2, (-2+1-1)*2=-4, (-4+2-1)*2=-6
	assert_equal(-6 * 100 + 3, compound(3))
	assert_equal(10 + 90 + 0 + 9, for_ranges(5))
	assert_equal(0, for_ranges(0))


# --- shapes the scan declines: f-strings, variadics, narrow and float -------
int with_fstring(int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + i
		i = i + 1
	if (f"{s}" != s"10"): return -1
	return s


int variadic_sum(int... values):
	int s = 0
	int i = 0
	while (i < values.length):
		s = s + values[i]
		i = i + 1
	return s


int narrow_and_float(int n):
	int8 small = 0
	int32 mid = 0
	float f = 0.5
	int i = 0
	int big = 0
	while (i < n):
		small = small + 1
		mid = mid + 3
		f = f + 1.0
		if (f > 3.0): big = big + 1
		i = i + 1
	return small * 1000 + mid + big * 100000


void test_declined():
	assert_equal(10, with_fstring(5))
	assert_equal(6, variadic_sum(1, 2, 3))
	assert_equal(0, variadic_sum())
	assert_equal(5 * 1000 + 15 + 3 * 100000, narrow_and_float(5))


int main():
	test_sum_to()
	test_pressure()
	test_address_taken()
	test_calls()
	test_recursion()
	test_early_returns()
	test_shadowing()
	test_setjmp()
	test_generators()
	test_tasks()
	test_defer()
	test_goto()
	test_raw_asm()
	test_expressions()
	test_operators()
	test_pointers()
	test_compound_and_ranges()
	test_declined()
	println(c"regalloc_arm64_test passed")
	return 0
