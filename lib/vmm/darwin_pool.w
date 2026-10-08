# Bounded ready-RAM pool for a single Darwin VM owner thread. Entries are
# private, never-run cells; no vCPU/VM or watchdog survives between leases.
# acquire transfers ownership to the caller, who must free the returned
# cell. replenish builds replacements from the pool's independent backing
# fd, including after source/template destruction. Calls are serialized;
# this is separate from the daemon's prewarmed worker-process lifecycle.
import lib.vmm.darwin_cell_snapshot

const int DARWIN_POOL_MAX_CAPACITY = 32

struct darwin_pool:
	int fd
	int capacity
	int available
	darwin_cell** cells


void darwin_pool_free(darwin_pool* pool):
	if (pool == 0): return
	for index in range(pool.available): darwin_cell_free(pool.cells[index])
	free(cast(void*, pool.cells))
	close(pool.fd)
	free(pool)


# Failure keeps already-restored entries available and permits retry.
int darwin_pool_replenish(darwin_pool* pool):
	if (pool == 0): return 0
	while (pool.available < pool.capacity):
		darwin_cell* cell = darwin_cell_snapshot_from_fd(pool.fd)
		if (cell == 0): return 0
		pool.cells[pool.available] = cell
		pool.available = pool.available + 1
	return 1


darwin_pool* darwin_pool_new(darwin_backing* backing, int capacity):
	if (backing == 0 || capacity < 1 || capacity > DARWIN_POOL_MAX_CAPACITY): return 0
	int fd = sys_fcntl(backing.fd, 0, 0)
	if (fd < 0): return 0
	if (sys_fcntl(fd, 2, 1) < 0):
		close(fd)
		return 0
	darwin_pool* pool = new darwin_pool()
	pool.fd = fd
	pool.capacity = capacity
	pool.available = 0
	pool.cells = cast(darwin_cell**, malloc(capacity * __word_size__))
	if (darwin_pool_replenish(pool) == 0):
		darwin_pool_free(pool)
		return 0
	return pool


darwin_cell* darwin_pool_acquire(darwin_pool* pool):
	if (pool == 0 || pool.available == 0): return 0
	pool.available = pool.available - 1
	darwin_cell* cell = pool.cells[pool.available]
	pool.cells[pool.available] = 0
	return cell
