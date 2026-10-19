# Checked ownership program whose stdout is a log of every observable
# ownership event: "drop <n>" when the owner tagged n is destroyed (the
# free hook of tests/safe_opt_log.w), "mark <n>" at transfer points and
# when deferred work runs. tests/safe_opt_diff_test.w compiles it under
# every optimization configuration and requires the same log, exit status
# and leak count; tests/safe_opt_order_manual_fixture.w performs the same
# work with raw pointers, explicit free() and hand-ordered "deferred"
# calls, and must print the identical log.
import lib.memory_debug
import tests.safe_opt_log


struct OptNode:
	int tag
	own int* left
	own int* right


own int* opt_box(int n):
	own int* box = new int
	*box = safe_opt_tag(n)
	return box


# Tiny leaves: inlined at their call sites by default, by --inline and by
# a hot profile. They only see scalars read through owners.
int opt_untag(int value):
	return value - 7340000


int opt_twice(int value):
	return value + value


# Tiny bodies whose only checked part is a declaration: the inliner
# must still refuse them (code_generator/statement_ast.w counts a
# checked declaration as an inlining hazard).
int opt_local_view(int value):
	int[2] data
	data[0] = value
	ref int[] view = data
	return view[0] + 1


int opt_local_ref(int value):
	int copy = value
	ref int* borrowed = &copy
	return *borrowed + 2


# Ownership enters and is destroyed at this function's exit.
int opt_consume(own int* box, int mark):
	safe_opt_mark(mark)
	return opt_untag(*box)


int opt_peek(ref int* box):
	return opt_untag(*box)


void opt_bump(refmut int* box):
	*box = *box + 1


# Scalar wrapper around a transfer between two non-inlinable checked
# calls; a hot profile makes it inlinable (it has calls but no checked
# parameter, result or declaration).
int opt_feed(int n):
	return opt_consume(opt_box(n), n)


# 1: reverse declaration order at a plain scope exit.
int opt_scope_exit():
	own int* a = opt_box(10)
	own int* b = opt_box(11)
	if 1:
		own int* c = opt_box(12)
		own int* d = opt_box(13)
		safe_opt_mark(1)
	own int* e = opt_box(14)
	safe_opt_mark(2)
	return opt_peek(a) + opt_peek(b) + opt_peek(e)


# 2: the result is evaluated and transferred before owners are destroyed;
# deferred work runs (LIFO) before automatic destruction.
int opt_early_return(int early):
	own int* keep = opt_box(20)
	defer safe_opt_mark(21)
	defer: safe_opt_mark(22)
	if early:
		own int* inner = opt_box(23)
		defer: safe_opt_mark(24)
		return opt_consume(inner, 25) + opt_peek(keep)
	own int* late = opt_box(26)
	return opt_peek(late)


# 3: owners and scoped defers per loop iteration, with continue/break.
int opt_loop(int limit):
	int total = 0
	for i in range(limit):
		own int* item = opt_box(30 + i)
		defer: safe_opt_mark(300 + i)
		if i == 1: continue
		if i == 3:
			own int* extra = opt_box(39)
			break
		total = total + opt_twice(opt_peek(item))
	safe_opt_mark(399)
	return total


# 4: transfers into calls and out of returns; a moved slot is skipped.
own int* opt_pass_through(own int* box):
	safe_opt_mark(41)
	return box


int opt_transfer():
	own int* a = opt_box(40)
	own int* b = opt_pass_through(a)
	safe_opt_mark(42)
	int seen = opt_consume(b, 43)
	safe_opt_mark(44)
	own int* c = opt_box(45)
	return seen + opt_peek(c)


# 5: replacement evaluates the new owner, destroys the old, installs.
int opt_replace():
	own int* slot = opt_box(50)
	safe_opt_mark(51)
	slot = opt_box(52)
	safe_opt_mark(54)
	opt_bump(slot)
	return opt_peek(slot)


# 6: nested owner: fields in reverse declaration order, then the node.
int opt_nested():
	own OptNode* node = new OptNode(safe_opt_tag(60), opt_box(61), opt_box(62))
	own OptNode* other = new OptNode(safe_opt_tag(63), opt_box(64), opt_box(65))
	safe_opt_mark(66)
	return opt_untag(node.tag) + opt_untag(other.tag)


# 7: branch-dependent transfer; cleanup tests the moved slot.
int opt_branch_move(int move):
	own int* box = opt_box(70)
	int seen = 0
	if move: seen = opt_consume(box, 71)
	safe_opt_mark(72)
	return seen


# 8: a hot loop (regalloc, loop rotation, ivopts on x64) creating and
# destroying an owner per iteration; only a summary is printed.
int opt_hot(int rounds):
	int total = 0
	int i = 0
	while i < rounds:
		own int* box = new int
		*box = i
		total = total + opt_twice(*box)
		i = i + 1
	return total


# 9: bounds-checked reads of checked slices inside an optimized loop.
int opt_bounded(int n):
	int[6] data
	for i in range(6):
		data[i] = i + 1
	ref int[] view = data
	ref int[] tail = view[1:]
	int total = 0
	for i in range(n):
		total = total + tail[i]
	return total


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	safe_opt_log_install()
	safe_println_int(opt_scope_exit())
	safe_println_int(opt_early_return(1))
	safe_println_int(opt_early_return(0))
	safe_println_int(opt_loop(5))
	safe_println_int(opt_transfer())
	safe_println_int(opt_replace())
	safe_println_int(opt_nested())
	safe_println_int(opt_branch_move(1))
	safe_println_int(opt_branch_move(0))
	safe_println_int(opt_feed(80))
	safe_println_int(opt_hot(2000))
	safe_println_int(opt_bounded(5))
	safe_println_int(opt_local_view(90) + opt_local_ref(91))
	int leaks = 0
	unsafe:
		leaks = debug_alloc_report_leaks() - before
	safe_println_int(leaks)
	return leaks
