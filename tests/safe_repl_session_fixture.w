# Helpers loaded into the REPL by tests/safe_repl_session_test.w (with
# --no_main). Under W_DEBUG_ALLOC the session allocator keeps a table of
# every block (lib/memory_debug.w); a cell has a size no compiler-internal
# allocation shares, so counting live blocks of that size counts the
# cells the session has not destroyed yet.
import lib.lib
import lib.memory_debug


struct cell:
	int value
	char[1013] tag


struct pair:
	own cell* left
	own cell* right


# Lifetime-labeled session bindings: a shared borrowed record, an exclusive
# one, and an owner carrying a borrowed group.
struct holder:
	ref[item] cell* value
	int tag


struct exclusive:
	refmut[item] cell* value
	int amount


struct stored:
	own cell* scratch
	ref[item] cell* item


# Shaped and named like lib/safe_thread.w's lock guard, which in-process
# sessions cannot import (thread_local): session bindings refuse the name.
struct WSafeGuard[T]:
	own cell* inner
	ref[m] cell* lock


type safe_repl_guard = WSafeGuard[int]


int safe_repl_live_cells():
	int live = 0
	for i in range(debug_tbl_count):
		if ((debug_tbl_freed[i] == 0) && (debug_tbl_size[i] == sizeof(cell))): live = live + 1
	return live


void safe_repl_report(char* label):
	print(label)
	print(c" live=")
	print(itoa(safe_repl_live_cells()))
	print(c"\x0a")


int safe_repl_take(own cell* c):
	return c.value


int safe_repl_peek(ref cell* c):
	return c.value


int safe_repl_hold(ref holder h):
	ref cell* c = h.value
	return c.value + h.tag


int safe_repl_bump(refmut exclusive e):
	int amount = e.amount
	refmut cell* c = e.value
	c.value = c.value + amount
	return c.value


own[a] stored* safe_repl_store(ref[a] cell* item):
	return new stored(new cell, item)


int safe_repl_stored(ref stored* s):
	ref cell* c = s.item
	return c.value


int safe_repl_take_stored(own[a] stored* s):
	ref cell* c = s.item
	return c.value


own[a] safe_repl_guard* safe_repl_lock(ref[a] cell* m):
	return new safe_repl_guard(new cell, m)


int main():
	return 0
