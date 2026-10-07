# Bounded serialized pool of ready Linux clones. The pool owns all sessions,
# including outstanding leases. Release consumes the pointer and replaces the
# dirty guest from the retained CoW template; refill failure leaves a vacancy.
# Acquire never boots or silently grows the pool. This is eager availability,
# not an in-place device reset: replacement has an explicit QEMU restore cost.
import lib.vmm.box_snapshot

struct box_pool:
	box_snapshot* snapshot
	vm_box_session** sessions
	char* leased
	int capacity
	int active
	int acquisitions
	int replacements
	int exhausted
	int timeout_ms


void box_pool_free(box_pool* pool):
	if (pool == 0): return
	for i in range(pool.capacity): box_session_close(pool.sessions[i])
	free(cast(void*, pool.sessions))
	free(pool.leased)
	box_snapshot_free(pool.snapshot)
	free(pool)


# Duplicate immutable backing ownership; the caller may immediately free its
# snapshot. Reopened restore streams have independent file descriptions.
box_snapshot* box_pool_retain(box_snapshot* source):
	if (source == 0 || source.ram_fd < 0): return 0
	box_snapshot* snapshot = new box_snapshot()
	snapshot.fd = sys_fcntl(source.fd, 1030, 0)
	snapshot.ram_fd = sys_fcntl(source.ram_fd, 1030, 0)
	snapshot.kernel = strclone(source.kernel)
	snapshot.initrd = strclone(source.initrd)
	snapshot.cpus = source.cpus
	snapshot.memory_mb = source.memory_mb
	if (snapshot.fd < 0 || snapshot.ram_fd < 0):
		box_snapshot_free(snapshot)
		return 0
	return snapshot


box_pool* box_pool_new(box_snapshot* source, int capacity, int timeout_ms):
	if (capacity < 1 || capacity > 64 || timeout_ms < 1 || timeout_ms > 600000): return 0
	box_snapshot* snapshot = box_pool_retain(source)
	if (snapshot == 0): return 0
	box_pool* pool = new box_pool()
	mem_fill[char](cast(char*, pool), 0, sizeof(box_pool))
	pool.snapshot = snapshot
	pool.capacity = capacity
	pool.timeout_ms = timeout_ms
	pool.sessions = cast(vm_box_session**, malloc(capacity * sizeof(vm_box_session*)))
	pool.leased = cast(char*, malloc(capacity))
	mem_fill[char](cast(char*, pool.sessions), 0, capacity * sizeof(vm_box_session*))
	mem_fill[char](pool.leased, 0, capacity)
	int deadline = process_monotonic_ms() + timeout_ms
	for i in range(capacity):
		int remaining = deadline - process_monotonic_ms()
		if (remaining > 0): pool.sessions[i] = box_snapshot_restore(snapshot, remaining)
		if (pool.sessions[i] == 0):
			box_pool_free(pool)
			return 0
	return pool


vm_box_session* box_pool_acquire(box_pool* pool):
	if (pool == 0): return 0
	for i in range(pool.capacity):
		if (pool.leased[i] == 0 && pool.sessions[i] != 0):
			pool.leased[i] = 1
			pool.active = pool.active + 1
			pool.acquisitions = pool.acquisitions + 1
			return pool.sessions[i]
	pool.exhausted = pool.exhausted + 1
	return 0


int box_pool_refill(box_pool* pool):
	if (pool == 0): return 0
	int deadline = process_monotonic_ms() + pool.timeout_ms
	for i in range(pool.capacity):
		if (pool.sessions[i] == 0):
			int remaining = deadline - process_monotonic_ms()
			if (remaining <= 0): return 0
			pool.sessions[i] = box_snapshot_restore(pool.snapshot, remaining)
			if (pool.sessions[i] == 0): return 0
			pool.replacements = pool.replacements + 1
	return 1


# Pointer is consumed even if replacement fails; never use or release it again.
int box_pool_release(box_pool* pool, vm_box_session* session):
	if (pool == 0 || session == 0): return 0
	for i in range(pool.capacity):
		if (pool.sessions[i] == session && pool.leased[i]):
			pool.sessions[i] = 0
			pool.leased[i] = 0
			pool.active = pool.active - 1
			box_session_close(session)
			return box_pool_refill(pool)
	return 0
