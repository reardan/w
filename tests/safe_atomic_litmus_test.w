# wbuild: x64
# wbuild: step="bin/wv2 --safe --inline tests/safe_atomic_litmus_test.w -o bin/safe_atomic_litmus_inline"
# wbuild: step="bin/safe_atomic_litmus_inline"
# wbuild: step="bin/wv2 x64 --safe --no-regs --no-inline tests/safe_atomic_litmus_test.w -o bin/safe_atomic_litmus_plain64"
# wbuild: step="bin/safe_atomic_litmus_plain64"
/*
Store-buffering (Dekker) litmus for the checked atomics
(docs/projects/safe_mode_contracts.md "Synchronization and memory
ordering"). Two threads run lock-step rounds; in round i one stores
x = i and then loads y, the other stores y = i and then loads x, all
seq_cst. Sequential consistency forbids both loads missing the other
thread's store in the same round. On x86-TSO only the fence after a
seq_cst store (safe_atomic_store) rules that outcome out: with
release stores and acquire loads instead, the review that added this
test (#699 deliverable 4) saw the forbidden outcome in every run. So
this is the one test that fails if the seq_cst store fence is lost.

The go_a/go_b words start both sides of a round together; res_a
carries thread A's "missed y" flag (2 * i + flag) to thread B, which
counts rounds where both missed. Runtime is about 0.1 s per binary.
*/
import lib.safe_thread


struct Litmus:
	own WSafeAtomic* role
	own WSafeAtomic* x
	own WSafeAtomic* y
	own WSafeAtomic* go_a
	own WSafeAtomic* go_b
	own WSafeAtomic* res_a
	own WSafeAtomic* violations


type Side = fn[](ref Litmus*) -> int


int litmus_side(ref Litmus* s):
	ref WSafeAtomic* role = s.role
	ref WSafeAtomic* x = s.x
	ref WSafeAtomic* y = s.y
	ref WSafeAtomic* go_a = s.go_a
	ref WSafeAtomic* go_b = s.go_b
	ref WSafeAtomic* res_a = s.res_a
	ref WSafeAtomic* violations = s.violations
	int me = safe_atomic_fetch_add(role, 1, memory_order_seq_cst)
	int i = 1
	while (i <= 200000):
		if (me == 0):
			safe_atomic_store(go_a, i, memory_order_seq_cst)
			while (safe_atomic_load(go_b, memory_order_acquire) < i): pass
			safe_atomic_store(x, i, memory_order_seq_cst)
			int seen = safe_atomic_load(y, memory_order_seq_cst)
			int missed = 0
			if (seen < i): missed = 1
			safe_atomic_store(res_a, i * 2 + missed, memory_order_seq_cst)
		else:
			safe_atomic_store(go_b, i, memory_order_seq_cst)
			while (safe_atomic_load(go_a, memory_order_acquire) < i): pass
			safe_atomic_store(y, i, memory_order_seq_cst)
			int seen = safe_atomic_load(x, memory_order_seq_cst)
			int r = safe_atomic_load(res_a, memory_order_acquire)
			while (r < i * 2): r = safe_atomic_load(res_a, memory_order_acquire)
			if ((seen < i) && ((r - i * 2) == 1)): safe_atomic_fetch_add(violations, 1, memory_order_seq_cst)
		i = i + 1
	return 0


int main():
	own Litmus* litmus = new Litmus(safe_atomic_new(0), safe_atomic_new(0), safe_atomic_new(0), safe_atomic_new(0), safe_atomic_new(0), safe_atomic_new(0), safe_atomic_new(0))
	ref Litmus* shared = litmus
	Side* side = litmus_side
	safe_thread_fork_join(side, shared, shared)
	int violations = safe_atomic_load(shared.violations, memory_order_seq_cst)
	# Nonzero exit: a forbidden store-buffering outcome under seq_cst.
	if (violations != 0): return 1
	return 0
