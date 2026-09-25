import lib.testing
# wbuild: x64 arch=arm64

/*
goto and labels (grammar/goto_statement.w, issue #435): function-scoped
labels, forward and backward jumps, jumps out of and into blocks (the
stack is popped or reserved to the target's depth) and the C idioms the
feature exists for -- cleanup ladders and hand-rolled loops.
*/


int trace


void mark(int digit):
	trace = trace * 10 + digit


# --- forward jump skips code ---

void forward_helper():
	mark(1)
	goto done
	mark(2)
	done:
	mark(3)


void test_forward_goto_skips_code():
	trace = 0
	forward_helper()
	assert_equal(13, trace)


# --- backward jump builds a loop ---

int count_to(int n):
	int i = 0
	again:
	if (i < n):
		i = i + 1
		goto again
	return i


void test_backward_goto_loops():
	assert_equal(5, count_to(5))
	assert_equal(0, count_to(0))


# --- goto out of nested blocks and loops pops their locals ---

int find_pair(int target):
	int result = -1
	for i in range(10):
		int a = i * 3
		for j in range(10):
			int b = j * 7
			if (a + b == target):
				result = i * 100 + j
				goto found
	found:
	# result must still be addressable at its original slot
	return result


void test_goto_out_of_nested_loops():
	assert_equal(302, find_pair(23))
	assert_equal(-1, find_pair(1000))


# --- goto into a block reserves its locals ---

int into_block(int flag):
	int total = 100
	if (flag):
		goto inside
	total = total + 1
	if (total > 0):
		int local = 5
		inside:
		local = 7
		total = total + local
	return total


void test_goto_into_block():
	assert_equal(107, into_block(1))
	assert_equal(108, into_block(0))


# --- forward jump over a declaration at the same block level ---

int over_declaration(int skip):
	int base = 10
	if (skip):
		goto after
	int extra = 5
	base = base + extra
	after:
	extra = 1
	return base + extra


void test_goto_over_declaration():
	assert_equal(11, over_declaration(1))
	assert_equal(16, over_declaration(0))


# --- several gotos from different depths to one label ---

int cleanup_ladder(int fail_at):
	int state = 0
	int step = 1
	if (fail_at == 1):
		goto fail
	state = state + 1
	if (step):
		int x = 2
		if (fail_at == 2):
			goto fail
		state = state + x
		while (step < 3):
			int y = step
			if (fail_at == 3):
				goto fail
			state = state + y
			step = step + 1
	return state
	fail:
	return 0 - fail_at


void test_cleanup_ladder():
	assert_equal(0 - 1, cleanup_ladder(1))
	assert_equal(0 - 2, cleanup_ladder(2))
	assert_equal(0 - 3, cleanup_ladder(3))
	assert_equal(6, cleanup_ladder(0))


# --- labels are per function: the same name in two functions ---

int first_label_user():
	goto out
	return 1
	out:
	return 2


int second_label_user():
	goto out
	return 3
	out:
	return 4


void test_labels_are_function_scoped():
	assert_equal(2, first_label_user())
	assert_equal(4, second_label_user())


# --- backward goto from a deeper block pops back to the label ---

int backward_from_block():
	int rounds = 0
	top:
	rounds = rounds + 1
	if (rounds < 4):
		int scratch = rounds * 2
		if (scratch > 0):
			int more = scratch
			goto top
	return rounds


void test_backward_goto_from_block():
	assert_equal(4, backward_from_block())


# --- goto inside a switch case ---

int switch_goto(int v):
	int out = 0
	switch v:
		case 1:
			out = 10
			goto tail
		case 2: out = 20
		default: out = 30
	out = out + 1
	tail:
	return out


void test_goto_in_switch():
	assert_equal(10, switch_goto(1))
	assert_equal(21, switch_goto(2))
	assert_equal(31, switch_goto(9))


# --- deferred statements still run once at function exit ---

void defer_goto_helper():
	defer mark(9)
	int n = 0
	loop:
	n = n + 1
	mark(n)
	if (n < 3):
		goto loop


void test_goto_with_defer():
	trace = 0
	defer_goto_helper()
	assert_equal(1239, trace)


# --- label at the end of a function body ---

void end_label_helper(int skip):
	if (skip):
		goto end
	mark(5)
	end:


void test_label_at_end_of_body():
	trace = 0
	end_label_helper(1)
	end_label_helper(0)
	assert_equal(5, trace)


# --- a variable and a label may share a name ---

int shared_name():
	int out = 1
	goto out
	out = 2
	out:
	return out


void test_label_and_variable_share_name():
	assert_equal(1, shared_name())
