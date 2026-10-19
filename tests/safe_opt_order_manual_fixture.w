# Manual-cleanup twin of tests/safe_opt_order_fixture.w: the same work
# with raw pointers, explicit free() calls and hand-ordered "deferred"
# calls, written to follow the checked cleanup rules of
# docs/projects/safe_mode.md ("Cleanup and unsafe boundaries"): deferred
# work in reverse registration order before automatic destruction, owners
# in reverse declaration order, a returned value evaluated first.
# tests/safe_opt_diff_test.w requires its stdout, exit status and leak
# count to equal the checked program's under every configuration.
import lib.memory_debug
import tests.safe_opt_log


struct OptNode:
	int tag
	int* left
	int* right


int* opt_box(int n):
	int* box = new int
	*box = safe_opt_tag(n)
	return box


int opt_untag(int value):
	return value - 7340000


int opt_twice(int value):
	return value + value


int opt_local_view(int value):
	int[2] data
	data[0] = value
	return data[0] + 1


int opt_local_ref(int value):
	int copy = value
	int* borrowed = &copy
	return *borrowed + 2


int opt_consume(int* box, int mark):
	safe_opt_mark(mark)
	int result = opt_untag(*box)
	free(box)
	return result


int opt_peek(int* box):
	return opt_untag(*box)


void opt_bump(int* box):
	*box = *box + 1


int opt_feed(int n):
	return opt_consume(opt_box(n), n)


int opt_scope_exit():
	int* a = opt_box(10)
	int* b = opt_box(11)
	if 1:
		int* c = opt_box(12)
		int* d = opt_box(13)
		safe_opt_mark(1)
		free(d)
		free(c)
	int* e = opt_box(14)
	safe_opt_mark(2)
	int result = opt_peek(a) + opt_peek(b) + opt_peek(e)
	free(e)
	free(b)
	free(a)
	return result


int opt_early_return(int early):
	int* keep = opt_box(20)
	if early:
		int* inner = opt_box(23)
		int result = opt_consume(inner, 25) + opt_peek(keep)
		safe_opt_mark(24)
		safe_opt_mark(22)
		safe_opt_mark(21)
		free(keep)
		return result
	int* late = opt_box(26)
	int result = opt_peek(late)
	safe_opt_mark(22)
	safe_opt_mark(21)
	free(late)
	free(keep)
	return result


int opt_loop(int limit):
	int total = 0
	for i in range(limit):
		int* item = opt_box(30 + i)
		if i == 1:
			safe_opt_mark(300 + i)
			free(item)
			continue
		if i == 3:
			int* extra = opt_box(39)
			safe_opt_mark(300 + i)
			free(extra)
			free(item)
			break
		total = total + opt_twice(opt_peek(item))
		safe_opt_mark(300 + i)
		free(item)
	safe_opt_mark(399)
	return total


int* opt_pass_through(int* box):
	safe_opt_mark(41)
	return box


int opt_transfer():
	int* a = opt_box(40)
	int* b = opt_pass_through(a)
	safe_opt_mark(42)
	int seen = opt_consume(b, 43)
	safe_opt_mark(44)
	int* c = opt_box(45)
	int result = seen + opt_peek(c)
	free(c)
	return result


int opt_replace():
	int* slot = opt_box(50)
	safe_opt_mark(51)
	int* next = opt_box(52)
	free(slot)
	slot = next
	safe_opt_mark(54)
	opt_bump(slot)
	int result = opt_peek(slot)
	free(slot)
	return result


OptNode* opt_node(int n, int* left, int* right):
	OptNode* node = new OptNode
	node.tag = safe_opt_tag(n)
	node.left = left
	node.right = right
	return node


void opt_node_free(OptNode* node):
	free(node.right)
	free(node.left)
	free(node)


int opt_nested():
	OptNode* node = opt_node(60, opt_box(61), opt_box(62))
	OptNode* other = opt_node(63, opt_box(64), opt_box(65))
	safe_opt_mark(66)
	int result = opt_untag(node.tag) + opt_untag(other.tag)
	opt_node_free(other)
	opt_node_free(node)
	return result


int opt_branch_move(int move):
	int* box = opt_box(70)
	int seen = 0
	if move:
		seen = opt_consume(box, 71)
		box = 0
	safe_opt_mark(72)
	if box != 0: free(box)
	return seen


int opt_hot(int rounds):
	int total = 0
	int i = 0
	while i < rounds:
		int* box = new int
		*box = i
		total = total + opt_twice(*box)
		free(box)
		i = i + 1
	return total


int opt_bounded(int n):
	int[6] data
	for i in range(6):
		data[i] = i + 1
	int total = 0
	for i in range(n):
		total = total + data[i + 1]
	return total


int main():
	malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
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
	int leaks = debug_alloc_report_leaks() - before
	safe_println_int(leaks)
	return leaks
