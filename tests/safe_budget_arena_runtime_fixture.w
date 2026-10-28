import lib.safe_typed_arena
import lib.memory_debug
import lib.safe


# Budget arenas charge sizeof(T) per live object and refund it on every
# destruction path; shared allocation keeps earlier views valid.
struct BudgetNode:
	own int* value
	int number


own BudgetNode* budget_node(int number):
	own int* value = new int
	*value = number * 3
	own BudgetNode* node = new BudgetNode(value, number)
	return node


# An early return drops the arena, refunding everything it holds.
int budget_early(refmut WArenaBudget* budget, int stop):
	own[b] WBudgetArena[BudgetNode]* nodes = budget_arena_new[BudgetNode](budget, -1)
	defer: budget_arena_reset[BudgetNode](nodes)
	for i in range(8):
		if (i == stop): return i
		budget_arena_insert[BudgetNode](nodes, budget_node(i))
	return -1


int budget_fill(refmut WArenaBudget* budget):
	int total = 0
	own[b] WBudgetArena[BudgetNode]* nodes = budget_arena_new[BudgetNode](budget, 64)
	for i in range(64):
		optown BudgetNode* rejected = budget_arena_try_insert[BudgetNode](nodes, budget_node(i))
		if (rejected): total += 1000
	for i in range(budget_arena_slots[BudgetNode](nodes)):
		optref BudgetNode* node = budget_arena_get[BudgetNode](nodes, i)
		if (node): total += *node.value
	for i in range(0, budget_arena_slots[BudgetNode](nodes), 2):
		total += budget_arena_destroy[BudgetNode](nodes, i)
		total += budget_arena_destroy[BudgetNode](nodes, i)
	total += budget_arena_remaining[BudgetNode](nodes) / sizeof(BudgetNode) * 100000
	budget_arena_release[BudgetNode](nodes)
	total += budget_arena_remaining[BudgetNode](nodes) / sizeof(BudgetNode) * 1000000
	# A released arena is reusable under the same budget.
	budget_arena_insert[BudgetNode](nodes, budget_node(5))
	return total + budget_arena_length[BudgetNode](nodes)


int budget_values(refmut WArenaBudget* budget):
	int total = 0
	own[b] WBudgetArena[int]* values = budget_arena_new[int](budget, -1)
	for i in range(40):
		optrefmut int* value = budget_arena_try_alloc[int](values, i)
		if (value):
			*value = *value + 1
			total += *value
		else: total += 10000
	# Destroying an object refunds exactly the room for one more.
	total += budget_arena_destroy[int](values, 3) * 100000
	refmut int* first = budget_arena_alloc[int](values, 7)
	return total + *first


int shared_values():
	own WTypedArena[int]* arena = typed_arena_new[int](-1)
	ref int* first = typed_arena_alloc_shared[int](arena, 11)
	int total = 0
	for i in range(100):
		ref int* value = typed_arena_alloc_shared[int](arena, i)
		total += *value
	return total + *first + typed_arena_length[int](arena)


# Independent objects share one quota. Charging/refunding one arena never
# invalidates another arena's objects; refusal returns the original owner.
int shared_budget_round(ref WArenaBudget* budget, int early):
	own[a] WBudgetArena[BudgetNode]* first = budget_arena_new[BudgetNode](budget, -1)
	own[b] WBudgetArena[BudgetNode]* second = budget_arena_new[BudgetNode](budget, -1)
	budget_arena_insert[BudgetNode](first, budget_node(2))
	budget_arena_insert[BudgetNode](second, budget_node(3))
	optrefmut BudgetNode* x = budget_arena_get_mut[BudgetNode](first, 0)
	optrefmut BudgetNode* y = budget_arena_get_mut[BudgetNode](second, 0)
	if (x && y):
		x.number += 1
		y.number += 1
		if (x.number + y.number != 7): return 1
	if (arena_budget_used(budget) != sizeof(BudgetNode) * 2): return 2
	for i in range(14): budget_arena_insert[BudgetNode](first, budget_node(i))
	optown BudgetNode* refused = budget_arena_try_insert[BudgetNode](second, budget_node(10))
	if (refused == 0): return 3
	if (refused.number != 10): return 4
	budget_arena_destroy[BudgetNode](first, 1)
	optown BudgetNode* retried = budget_arena_try_insert[BudgetNode](second, refused)
	if (retried): return 5
	if (early): return 0
	budget_arena_reset[BudgetNode](first)
	if (arena_budget_used(budget) != sizeof(BudgetNode) * 2): return 6
	budget_arena_release[BudgetNode](second)
	if (arena_budget_used(budget) != 0): return 7
	return 0


int budget_exercise():
	int total = 0
	for repetition in range(20):
		own WArenaBudget* budget = arena_budget_new(sizeof(BudgetNode) * 16)
		if (shared_budget_round(budget, repetition % 2)): return -4
		if (arena_budget_used(budget) != 0): return -5
		total += budget_early(budget, repetition % 8)
		if (arena_budget_used(budget) != 0): return -1
		total += budget_fill(budget)
		if (arena_budget_used(budget) != 0): return -2
		own WArenaBudget* small = arena_budget_new(sizeof(int) * 10)
		total += budget_values(small)
		if (arena_budget_used(small) != 0): return -3
		total += shared_values()
	return total


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = budget_exercise()
	if result != 345069922:
		safe_println_int(result)
		return 1
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
