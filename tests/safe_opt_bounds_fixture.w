# Bounds checks that optimization must keep. SAFE_OPT_CASE selects one
# scenario (tests/safe_opt_log.w's safe_opt_case); case 0 runs every
# scenario in range and exits 0. Cases 1-6 index one element past the
# end (or before the start) and must trap with the same "index out of
# range" message under every optimization configuration
# (tests/safe_opt_diff_test.w), after printing the same log: marks and
# drops that happened before the trap, and nothing after it. Owners live
# at the trap are not destroyed (no cleanup is promised after a trap).
import tests.safe_opt_log


own int* bounds_box(int n):
	own int* box = new int
	*box = safe_opt_tag(n)
	return box


# A checked-slice accessor: never inlined (checked parameter).
int bounds_at(ref int[] view, int i):
	return view[i]


# A scalar leaf over its own fixed array: the inliner may copy it into
# its callers (no checked parameter, result or declaration), and the
# copy must keep the index check.
int bounds_pick(int i):
	int[4] small
	small[0] = 5
	small[3] = 6
	return small[i]


# Hot loops over a checked slice: register promotion, loop rotation and
# (x64) induction-variable pointers all apply.
int bounds_sum(ref int[] view, int n):
	int total = 0
	for i in range(n):
		total = total + view[i]
	return total


int bounds_sum_down(ref int[] view, int start):
	int total = 0
	int i = start
	while i >= -1:
		if i < 0: total = total + view[i]
		else: total = total + view[i]
		i = i - 1
	return total


int bounds_fill(int n):
	int[8] data
	for i in range(n):
		data[i] = i
	return data[7]


int bounds_case(int which):
	own int* outer = bounds_box(1)
	int[8] data
	for i in range(8):
		data[i] = i + 1
	ref int[] view = data
	int total = 0
	if 1:
		own int* scoped = bounds_box(2)
		safe_opt_mark(10)
	safe_opt_mark(11)
	if which == 1: total = total + bounds_sum(view, 9)
	else: total = total + bounds_sum(view, 8)
	safe_opt_mark(12)
	if which == 2: total = total + bounds_at(view, 8)
	else: total = total + bounds_at(view, 7)
	safe_opt_mark(13)
	ref int[] tail = view[3:]
	if which == 3: total = total + bounds_sum(tail, 6)
	else: total = total + bounds_sum(tail, 5)
	safe_opt_mark(14)
	if which == 4: total = total + bounds_fill(9)
	else: total = total + bounds_fill(8)
	safe_opt_mark(15)
	if which == 5: total = total + bounds_sum_down(view, 7)
	safe_opt_mark(16)
	if which == 6: total = total + bounds_pick(4)
	else: total = total + bounds_pick(3)
	safe_opt_mark(17)
	return total


int main():
	int which = safe_opt_case()
	unsafe:
		safe_opt_log_install()
	safe_println_int(bounds_case(which))
	safe_opt_mark(99)
	return 0
