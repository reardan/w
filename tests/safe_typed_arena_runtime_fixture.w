import lib.safe_typed_arena
import lib.memory_debug

struct ArenaNode:
	own int* left
	own int* right
	int number

own ArenaNode* arena_node(int number):
	own int* left = new int
	own int* right = new int
	*left = number
	*right = number + 1
	own ArenaNode* node = new ArenaNode(left, right, number)
	return node

int typed_arena_early():
	own WTypedArena[ArenaNode]* arena = typed_arena_new[ArenaNode](-1)
	typed_arena_insert[ArenaNode](arena, arena_node(2))
	defer: typed_arena_reset[ArenaNode](arena)
	return 0

int typed_arena_exercise():
	for repetition in range(30):
		own WTypedArena[ArenaNode]* arena = typed_arena_new[ArenaNode](32)
		for i in range(32):
			own ArenaNode* node = arena_node(i)
			if typed_arena_insert[ArenaNode](arena, node) != i: return 1
		for i in range(32):
			optref ArenaNode* node = typed_arena_get[ArenaNode](arena, i)
			if node:
				if *node.left + *node.right != i * 2 + 1: return 2
			else: return 3
		for i in range(0, 32, 2):
			if typed_arena_destroy[ArenaNode](arena, i) != 1: return 4
			if typed_arena_destroy[ArenaNode](arena, i) != 0: return 5
		if typed_arena_length[ArenaNode](arena) != 16: return 6
		own ArenaNode* overflow = arena_node(99)
		optown ArenaNode* rejected = typed_arena_try_insert[ArenaNode](arena, overflow)
		if rejected:
			if rejected.number != 99: return 7
		else: return 8
		typed_arena_reset[ArenaNode](arena)
		for i in range(8):
			own ArenaNode* node = arena_node(i)
			optown ArenaNode* failed = typed_arena_try_insert[ArenaNode](arena, node)
			if failed: return 9
		typed_arena_release[ArenaNode](arena)
		if typed_arena_slots[ArenaNode](arena): return 10
		own WTypedArena[int]* integers = typed_arena_new[int](-1)
		for i in range(24):
			refmut int* item = typed_arena_alloc[int](integers, i)
			*item += 1
		for i in range(24):
			optrefmut int* item = typed_arena_get_mut[int](integers, i)
			if item:
				if *item != i + 1: return 11
				*item += 1
			else: return 12
		if typed_arena_early(): return 13
	return 0

int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = typed_arena_exercise()
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	if result: return result
	return after - before
