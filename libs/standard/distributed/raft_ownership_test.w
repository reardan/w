# wbuild: x64

/*
Command-ownership regression (issue #315): raft_propose COPIES the
caller's command bytes into a fresh, entry-owned buffer
(raft_entry_new -> raft_copy_blob), and raft_entry_free releases that
copy. So (1) mutating or freeing the caller's buffer immediately after
append must never corrupt the log, and (2) tearing an entry (or the
whole raft) down must free the copy with no leak.

This is a standalone main() (not the test_* + lib.testing pattern the
rest of libs/standard/distributed uses) because it forces the
guard-page debug allocator (lib/memory_debug.w) via
malloc_force_debug_mode(), which per its own contract "must be called
before the first malloc/free/realloc of the process -- the backend
choice is fixed on first use and never revisited." raft_test.w's
shared test_* binary runs dozens of tests through lib.testing's
harness, which allocates before any individual test body gets to run;
switching backends mid-process there would try to free
already-freelist-allocated raft internals through the debug allocator
and fault spuriously on unrelated tests. A dedicated process (mirroring
tests/memory_debug_test.w's own pattern) is the only safe way to use
the harness here.

Ownership claim (1) -- the copy, and that freeing the caller's buffer
can never corrupt or reach back into the log -- is proven directly:
read the entry's bytes back AFTER mutating, and again AFTER freeing,
the caller's buffer. Under the guard-page allocator a freed page
faults on any touch, so if raft had shared the pointer instead of
copying it, the second read would crash rather than just read wrong
bytes -- a much stronger check than a plain assertion failure.

Ownership claim (2) -- teardown frees the copy with no leak -- is
proven with a before/after-raft_free leak-count DELTA, not a bare
"zero leaks" assertion: raft_free intentionally leaves list/map/set
backing storage for the runtime rather than freeing it (documented in
raft.w, "matching swim_free in swim.w"), so debug_alloc_report_leaks()
is never zero right after raft_free, propose or not -- that scaffolding
is normal and unrelated to command ownership. Comparing what ONE
raft_free call itself reclaims (leak count immediately before minus
immediately after) between a raft with zero proposed entries and one
with a single proposed entry cancels out that constant scaffolding
entirely (it is equally unreclaimed on both sides of the subtraction),
leaving exactly the marginal blocks the entry itself owns: the term
clone, the command copy, and the entry struct -- three, no more, no
less.
*/
import lib.lib
import lib.assert
import lib.memory
import libs.standard.distributed.raft


# Single-node cluster: ticking past the election deadline wins on the
# spot, no peers means no outbound messages.
raft* rot_leader():
	list[int] peers = new list[int]
	raft* r = raft_new(1, peers, 150, 300, 50, 7)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 300, out)
	asserts(c"single-node cluster ticks straight to leader", raft_state(r) == raft_leader())
	asserts(c"single-node win emits no messages", out.length == 0)
	return r


# raft_free(r) reclaims (leak count right before) minus (leak count
# right after): everything raft_free itself actually freed, excluding
# whatever it deliberately leaves behind (unaffected by teardown, so it
# cancels out of this difference regardless of how many entries exist).
int rot_reclaimed_by_free(raft* r):
	int before = debug_alloc_report_leaks()
	raft_free(r)
	int after = debug_alloc_report_leaks()
	return before - after


int main():
	malloc_force_debug_mode()

	# ---- claim 1: copy-not-share, proven behaviorally -------------------
	raft* r = rot_leader()
	list[raft_msg*] out = new list[raft_msg*]

	# propose from a caller-owned buffer with a non-text byte (tab) in
	# it, so this also doubles as a binary-safety smoke check
	char* buf = malloc(4)
	buf[0] = 'z'
	buf[1] = 'a'
	buf[2] = 'p'
	buf[3] = 9
	asserts(c"propose accepted", raft_propose(r, buf, 4, 10, out) == 1)
	while (out.length > 0):
		raft_msg_free(out.pop())

	# mutate the caller's buffer immediately: the log entry must be
	# unaffected, because raft_entry_new copied command_len bytes out
	# of it rather than sharing the pointer
	buf[0] = 'X'
	buf[1] = 'X'
	buf[2] = 'X'
	buf[3] = 'X'

	raft_entry* e = raft_log_at(r, 1)
	asserts(c"entry length unaffected by caller mutation", e.command_len == 4)
	asserts(c"entry byte 0 unaffected by caller mutation", (e.command[0] & 255) == 'z')
	asserts(c"entry byte 1 unaffected by caller mutation", (e.command[1] & 255) == 'a')
	asserts(c"entry byte 2 unaffected by caller mutation", (e.command[2] & 255) == 'p')
	asserts(c"entry byte 3 unaffected by caller mutation", (e.command[3] & 255) == 9)

	# free the caller's buffer entirely: under the guard-page allocator
	# any future access to IT (by anyone still holding the old pointer)
	# would fault immediately instead of silently reading freed memory
	# -- so simply reaching the asserts below without a crash is itself
	# part of the proof that raft never retained buf
	free(buf)

	asserts(c"entry still intact after caller frees its buffer", e.command_len == 4)
	asserts(c"entry byte 0 still intact after free", (e.command[0] & 255) == 'z')
	asserts(c"entry byte 3 still intact after free", (e.command[3] & 255) == 9)

	# ---- claim 2: teardown frees the copy, no leak, no double-free ------
	# baseline: an otherwise-identical raft that never proposed anything
	raft* c0 = rot_leader()
	int reclaimed_empty = rot_reclaimed_by_free(c0)

	# r already carries the one proposed entry from claim 1 above
	int reclaimed_with_entry = rot_reclaimed_by_free(r)

	asserts(c"one entry's teardown frees exactly 3 more blocks (term clone, command copy, entry struct)", reclaimed_with_entry - reclaimed_empty == 3)

	println2(c"raft_ownership_test: OK")
	return 0
