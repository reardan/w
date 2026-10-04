# Bounded, serialized pool of RAM-ready cell clones. Leases count toward
# capacity; exhaustion returns null instead of silently creating more.
# KVM CPUs are created by cell_run and destroyed when leases are returned.
import lib.vmm.snapshot

struct cell_pool:
	vm_cell** cells
	char* leased
	int capacity
	int active
	int high_water
	int acquisitions
	int resets
	int exhausted


void cell_pool_free(cell_pool* pool):
	if (pool == 0): return
	for i in range(pool.capacity): cell_free(pool.cells[i])
	free(cast(void*, pool.cells))
	free(pool.leased)
	free(pool)


cell_pool* cell_pool_new(cell_snapshot* snapshot, int capacity):
	if (snapshot == 0 || capacity < 1 || capacity > 256): return 0
	cell_pool* pool = new cell_pool()
	mem_fill[char](cast(char*, pool), 0, sizeof(cell_pool))
	pool.capacity = capacity
	pool.cells = cast(vm_cell**, malloc(capacity * sizeof(vm_cell*)))
	pool.leased = malloc(capacity)
	mem_fill[char](cast(char*, pool.cells), 0, capacity * sizeof(vm_cell*))
	mem_fill[char](pool.leased, 0, capacity)
	for i in range(capacity):
		pool.cells[i] = cell_snapshot_clone(snapshot)
		if (pool.cells[i] == 0):
			cell_pool_free(pool)
			return 0
	return pool


# The pool owns cells, including outstanding leases. Return with release,
# never cell_free; destroying a pool invalidates all its leased pointers.
vm_cell* cell_pool_acquire(cell_pool* pool):
	if (pool == 0): return 0
	for i in range(pool.capacity):
		if (pool.leased[i] == 0):
			pool.leased[i] = 1
			pool.active = pool.active + 1
			pool.acquisitions = pool.acquisitions + 1
			if (pool.active > pool.high_water): pool.high_water = pool.active
			return pool.cells[i]
	pool.exhausted = pool.exhausted + 1
	return 0


int cell_pool_release(cell_pool* pool, vm_cell* cell):
	if (pool == 0 || cell == 0): return 0
	for i in range(pool.capacity):
		if (pool.cells[i] == cell):
			if (pool.leased[i] == 0): return 0
			if (cell_snapshot_reset(cell) == 0): return 0
			pool.leased[i] = 0
			pool.active = pool.active - 1
			pool.resets = pool.resets + 1
			return 1
	return 0
