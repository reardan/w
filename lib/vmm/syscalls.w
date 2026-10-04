# Cell syscall boundary: no guest descriptor or pathname is ever passed
# through to the host. Only explicitly listed services are available.
import lib.vmm.x64


int cell_mmap(vm_cell* cell, int address, int length, int prot, int flags, int fd, int offset):
	# Anonymous, private, non-fixed mappings only. GROWSDOWN and STACK
	# are accepted hints; memory still has a fixed, bounded extent.
	if (address != 0 || fd != -1 || offset != 0): return -22
	if (length <= 0 || length > CELL_IMAGE_MIN - cell.mmap_next): return -12
	if (prot < 0 || prot > 7 || (flags & 34) != 34 || (flags & -131363) != 0): return -22
	int size = cell_page_end(length)
	if (size > CELL_IMAGE_MIN - cell.mmap_next): return -12
	int result = cell.mmap_next
	cell.mmap_next = result + size
	cell_map(cell, result, size, prot)
	return result


int cell_brk(vm_cell* cell, int address):
	if (address == 0): return cell.heap_end
	if (address < cell.heap_start || address > CELL_HEAP_MAX): return cell.heap_end
	int old_page = cell_page_end(cell.heap_end)
	int new_page = cell_page_end(address)
	if (new_page > old_page): cell_map(cell, old_page, new_page - old_page, 3)
	if (new_page < old_page):
		for page in range(new_page, old_page, 4096): save_int64(cell_pte(cell, page), 0)
		madvise(cast(int, cell.ram) + new_page, old_page - new_page, MADV_DONTNEED)
	cell.heap_end = address
	return address


int cell_mprotect(vm_cell* cell, int address, int length, int prot):
	if (address % 4096 != 0 || length < 0 || prot < 0 || prot > 7): return -22
	if (address < CELL_USER_MIN || address >= CELL_RAM_SIZE || length > CELL_RAM_SIZE - address): return -12
	int end = cell_page_end(address + length)
	for page in range(address, end, 4096):
		if ((load_int64(cell_pte(cell, page)) & 4) == 0): return -12
	if (length > 0): cell_map(cell, address, length, prot)
	return 0


int cell_munmap(vm_cell* cell, int address, int length):
	# Only mmap allocations can be released, never image or stack pages.
	if (length <= 0 || address % 4096 != 0): return -22
	if (address < CELL_USER_MIN || address >= cell.mmap_next || length > cell.mmap_next - address): return -22
	int size = cell_page_end(length)
	for page in range(address, address + size, 4096): save_int64(cell_pte(cell, page), 0)
	return madvise(cast(int, cell.ram) + address, size, MADV_DONTNEED)


int cell_write(vm_cell* cell, int fd, int address, int length):
	if (fd != 1 && fd != 2): return -9
	if (cell.closed_fds & (1 << fd)): return -9
	if (length == 0): return 0
	if (cell_range(cell, address, length, 0) == 0): return -14
	if (length > CELL_OUTPUT_LIMIT - cell.output_bytes):
		cell_fail(cell, c"guest output limit exceeded")
		cell.exited = 1
		cell.status = 125
		return -27
	if (fd == 1): string_append_bytes(cell.output, cell.ram + address, length)
	else: string_append_bytes(cell.errors, cell.ram + address, length)
	cell.output_bytes = cell.output_bytes + length
	return length


int cell_read(vm_cell* cell, int fd, int address, int length):
	if (fd != 0 || (cell.closed_fds & 1)): return -9
	if (length == 0): return 0
	if (cell_range(cell, address, length, 1) == 0): return -14
	int available = cell.input_length - cell.input_pos
	if (length > available): length = available
	if (length > 0): mem_copy[char](cell.ram + address, cell.input + cell.input_pos, length)
	cell.input_pos = cell.input_pos + length
	return length


int cell_syscall(vm_cell* cell):
	char* regs = cell.regs
	int nr = load_int64(regs)
	int a = load_int64(regs + 40) # rdi
	int b = load_int64(regs + 32) # rsi
	int c = load_int64(regs + 24) # rdx
	if (nr == 0): return cell_read(cell, a, b, c)
	if (nr == 1): return cell_write(cell, a, b, c)
	if (nr == 3):
		if (a < 0 || a > 2): return -9
		if (cell.closed_fds & (1 << a)): return -9
		cell.closed_fds = cell.closed_fds | (1 << a)
		return 0
	if (nr == 60 || nr == 231):
		cell.exited = 1
		cell.status = a & 255
		return 0
	if (nr == 9): return cell_mmap(cell, a, b, c, load_int64(regs + 80), load_int64(regs + 64), load_int64(regs + 72))
	if (nr == 10): return cell_mprotect(cell, a, b, c)
	if (nr == 11): return cell_munmap(cell, a, b)
	if (nr == 12): return cell_brk(cell, a)
	if (nr == 158): # arch_prctl: TLS bases are guest linear addresses
		if (a != 4097 && a != 4098): return -22
		if (b != 0 && cell_range(cell, b, 8, 0) == 0): return -14
		if (kvm_get_sregs(cell.machine, cell.sregs) < 0): return -5
		int field = 96 # GS
		if (a == 4098): field = 72 # FS
		save_int64(cell.sregs + field, b)
		return kvm_set_sregs(cell.machine, cell.sregs)
	if (nr == 228): # clock_gettime
		if (a != 0 && a != 1): return -22
		if (cell_range(cell, b, 16, 1) == 0): return -14
		return sys_clock_gettime(a, cast(int, cell.ram + b))
	if (nr == 318): # bounded, nonblocking getrandom
		if (c != 0 && c != 1): return -22
		if (b == 0): return 0
		if (cell_range(cell, a, b, 1) == 0): return -14
		if (b > 1048576): b = 1048576
		return sys_getrandom(cell.ram + a, b, 1)
	if (nr == 39 || nr == 186): return 1 # virtual pid/tid
	if (nr == 24): return 0 # sched_yield: one vCPU
	# Path-based access is denied. None of these dereference a guest
	# string or touch a host path, including /proc/self/environ.
	if (nr == 2 || nr == 85 || nr == 257): return -13
	if (nr == 8): return -9 # no seekable descriptors
	cell.unsupported_syscall = nr
	return -38
