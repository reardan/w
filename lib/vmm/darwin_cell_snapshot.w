# Ready ARM64 cell records layered over Darwin's read-only unlinked backing.
# Initial architectural state is reconstructed by darwin_cell_cpu_setup;
# no live vCPU, watchdog or host resource is serialized. The metadata
# fingerprint identifies executable guest bytes; it is not authentication.
import lib.vmm.darwin_cell
import lib.vmm.darwin_snapshot

const int DARWIN_CELL_SNAPSHOT_MAGIC = 0x4443454c
const int DARWIN_CELL_SNAPSHOT_META = 128


int darwin_cell_snapshot_identity(darwin_cell* cell):
	int identity = 1
	for page in range(cell.ram_size / 4096):
		if (cell.permissions[page] & 4):
			identity = identity * 31 + page
			for offset in range(0, 4096, 8): identity = identity * 31 + load_int64(cell.ram + page * 4096 + offset)
	return identity


darwin_backing* darwin_cell_snapshot_create(darwin_cell* cell):
	if (cell == 0): return 0
	if (cell.loaded == 0 || cell.stack == 0 || cell.started || cell.vm_created || cell.cpu_created || cell.mapped):
		darwin_cell_fail(cell, c"snapshot requires a ready, never-run cell")
		return 0
	if (cell.ram_size != DARWIN_CELL_RAM_SIZE || cell.heap_end != cell.heap_start || cell.mmap_next != DARWIN_CELL_USER_MIN):
		darwin_cell_fail(cell, c"snapshot requires pristine ARM64 memory state")
		return 0
	if (cell.output_limit < 0 || cell.output_limit > 4194304 || cell.syscall_limit < 1 || cell.syscall_limit > 1000000):
		darwin_cell_fail(cell, c"invalid snapshot service limits")
		return 0
	if (cell.input_length < 0 || cell.input_length > 4194304 || (cell.input_length > 0 && cell.input == 0)):
		darwin_cell_fail(cell, c"invalid snapshot input")
		return 0
	if (cell.input_pos != 0 || cell.output.length != 0 || cell.errors.length != 0 || cell.closed_fds != 0):
		darwin_cell_fail(cell, c"snapshot requires pristine I/O")
		return 0
	int permission_bytes = cell.ram_size / 4096
	int length = DARWIN_CELL_SNAPSHOT_META + permission_bytes + cell.input_length
	char* metadata = cast(char*, malloc(length))
	mem_fill[char](metadata, 0, length)
	int* values = cast(int*, metadata)
	values[0] = DARWIN_CELL_SNAPSHOT_MAGIC
	values[1] = 1
	values[2] = cell.entry
	values[3] = cell.stack
	values[4] = cell.heap_start
	values[5] = cell.heap_end
	values[6] = cell.mmap_next
	values[7] = cell.output_limit
	values[8] = cell.syscall_limit
	values[9] = cell.input_length
	values[10] = permission_bytes
	values[11] = darwin_cell_snapshot_identity(cell)
	mem_copy[char](metadata + DARWIN_CELL_SNAPSHOT_META, cell.permissions, permission_bytes)
	if (cell.input_length > 0): mem_copy[char](metadata + DARWIN_CELL_SNAPSHOT_META + permission_bytes, cell.input, cell.input_length)
	darwin_backing* backing = darwin_backing_create(cell.ram, cell.ram_size, metadata, length)
	free(metadata)
	if (backing == 0): darwin_cell_fail(cell, c"Darwin immutable snapshot capture failed")
	return backing


void darwin_cell_snapshot_detach(darwin_cell* cell):
	darwin_clone_free(cast(darwin_clone*, cell.snapshot_state))
	cell.snapshot_state = 0
	cell.snapshot_cleanup = 0
	cell.ram = 0


int darwin_cell_snapshot_metadata(darwin_clone* clone):
	if (clone.length != DARWIN_CELL_RAM_SIZE || clone.metadata_length < DARWIN_CELL_SNAPSHOT_META): return 0
	int* values = cast(int*, clone.metadata)
	if (values[0] != DARWIN_CELL_SNAPSHOT_MAGIC || values[1] != 1): return 0
	if (values[2] < DARWIN_CELL_IMAGE_MIN || values[2] >= DARWIN_CELL_IMAGE_MAX || values[2] % 4 != 0): return 0
	if (values[3] < DARWIN_CELL_STACK_LOW || values[3] >= DARWIN_CELL_STACK_TOP || values[3] % 16 != 0): return 0
	if (values[4] < DARWIN_CELL_IMAGE_MIN || values[4] > DARWIN_CELL_IMAGE_MAX || values[4] % 4096 != 0): return 0
	if (values[5] != values[4] || values[6] != DARWIN_CELL_USER_MIN): return 0
	if (values[7] < 0 || values[7] > 4194304 || values[8] < 1 || values[8] > 1000000): return 0
	if (values[9] < 0 || values[9] > 4194304 || values[10] != DARWIN_CELL_RAM_SIZE / 4096): return 0
	if (clone.metadata_length != DARWIN_CELL_SNAPSHOT_META + values[10] + values[9]): return 0
	for index in range(12, 16):
		if (values[index] != 0): return 0
	char* permissions = clone.metadata + DARWIN_CELL_SNAPSHOT_META
	for page in range(values[10]):
		int flags = cast(int, permissions[page])
		if (flags < 0 || flags > 15): return 0
		if (page < DARWIN_CELL_USER_MIN / 4096 && flags != 0): return 0
	if ((permissions[values[2] / 4096] & 13) != 13): return 0
	if ((permissions[values[3] / 4096] & 11) != 11): return 0
	return 1


# Reset is owner-thread-only, serialized with run. Each run joins its
# watchdog and destroys its VM before returning, so no retained CPU state
# can leak into a later lease. New RAM pointers replace all borrowed views.
int darwin_cell_snapshot_reset(darwin_cell* cell):
	if (cell == 0 || cell.snapshot_state == 0): return 0
	if (cell.vm_created || cell.cpu_created || cell.mapped): return darwin_cell_fail(cell, c"cannot reset an active Darwin VM")
	darwin_clone* clone = cast(darwin_clone*, cell.snapshot_state)
	if (darwin_clone_reset(clone) == 0): return darwin_cell_fail(cell, c"Darwin private clone remap failed")
	cell.ram = clone.ram
	if (darwin_cell_snapshot_metadata(clone) == 0):
		cell.loaded = 0
		return darwin_cell_fail(cell, c"invalid Darwin snapshot metadata")
	int* values = cast(int*, clone.metadata)
	cell.ram = clone.ram
	mem_copy[char](cell.permissions, clone.metadata + DARWIN_CELL_SNAPSHOT_META, values[10])
	cell.entry = values[2]
	cell.stack = values[3]
	cell.heap_start = values[4]
	cell.heap_end = values[5]
	cell.mmap_next = values[6]
	cell.output_limit = values[7]
	cell.syscall_limit = values[8]
	cell.input_length = values[9]
	cell.input = clone.metadata + DARWIN_CELL_SNAPSHOT_META + values[10]
	cell.input_pos = 0
	cell.loaded = 1
	cell.started = 0
	cell.status = 125
	cell.exited = 0
	cell.fault_pc = 0
	cell.gate_pc = 0
	cell.gate_cpsr = 0
	cell.gate_syndrome = 0
	cell.guest_spsr = 0
	cell.fault_syndrome = 0
	cell.fault_address = 0
	cell.unsupported_syscall = -1
	cell.output_bytes = 0
	cell.syscall_count = 0
	cell.closed_fds = 0
	cell.error = 0
	cell.cpu = 0
	cell.exit_state = 0
	string_free(cell.output)
	string_free(cell.errors)
	cell.output = string_new()
	cell.errors = string_new()
	return 1


darwin_cell* darwin_cell_snapshot_from_fd(int fd):
	darwin_clone* clone = darwin_clone_from_fd(fd)
	if (clone == 0): return 0
	if (darwin_cell_snapshot_metadata(clone) == 0):
		darwin_clone_free(clone)
		return 0
	darwin_cell* cell = darwin_cell_new()
	if (cell == 0):
		darwin_clone_free(clone)
		return 0
	munmap(cast(int, cell.ram), cell.ram_size)
	cell.owns_ram = 0
	cell.ram = clone.ram
	cell.snapshot_state = cast(void*, clone)
	cell.snapshot_cleanup = cast(void*, darwin_cell_snapshot_detach)
	if (darwin_cell_snapshot_reset(cell) == 0):
		darwin_cell_free(cell)
		return 0
	if (darwin_cell_snapshot_identity(cell) != (cast(int*, clone.metadata))[11]):
		darwin_cell_free(cell)
		return 0
	return cell


darwin_cell* darwin_cell_snapshot_clone(darwin_backing* backing):
	if (backing == 0): return 0
	return darwin_cell_snapshot_from_fd(backing.fd)
