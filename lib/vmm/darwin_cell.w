# Apple Silicon cells: Linux AArch64 ELF guests at EL0, behind a protected
# EL1 exception monitor. All addresses are identity mapped in 256 MiB.
# Stage-1 uses 4 KiB pages; the host mapping uses its own 16 KiB granule.
import lib.vmm.darwin_hv
import structures.string
import lib.mem

extern void arc4random_buf(char* buffer, int length)
extern int darwin_cell_fstat(int fd, char* record) = "fstat"

const int DARWIN_CELL_RAM_SIZE = 268435456
const int DARWIN_CELL_USER_MIN = 2097152
const int DARWIN_CELL_IMAGE_MIN = 134217728
const int DARWIN_CELL_IMAGE_MAX = 234881024
const int DARWIN_CELL_HEAP_MAX = 251658240
const int DARWIN_CELL_STACK_LOW = 260046848
const int DARWIN_CELL_STACK_TOP = 268431360
const int DARWIN_CELL_PT = 131072
const int DARWIN_CELL_GATE = 9216

struct darwin_cell:
	char* ram
	int ram_size
	int owns_ram
	char* permissions
	int entry
	int stack
	int heap_start
	int heap_end
	int mmap_next
	int loaded
	int started
	int status
	int exited
	int fault_pc
	int gate_pc
	int gate_cpsr
	int gate_syndrome
	int guest_spsr
	int fault_syndrome
	int fault_address
	int unsupported_syscall
	int output_bytes
	int output_limit
	int syscall_count
	int syscall_limit
	int closed_fds
	char* input
	int input_length
	int input_pos
	string_builder* output
	string_builder* errors
	char* error
	int cpu
	int vm_created
	int cpu_created
	int mapped
	void* snapshot_state
	void* snapshot_cleanup
	dhv_exit* exit_state


int darwin_cell_fail(darwin_cell* cell, char* error):
	cell.error = error
	return 0


int darwin_cell_page_end(int address):
	return (address + 4095) & -4096


darwin_cell* darwin_cell_new():
	int address = mmap(0, DARWIN_CELL_RAM_SIZE, 3, 34)
	if (address < 0 && address > -4096): return 0
	darwin_cell* cell = new darwin_cell()
	mem_fill[char](cast(char*, cell), 0, sizeof(darwin_cell))
	cell.ram = cast(char*, address)
	cell.ram_size = DARWIN_CELL_RAM_SIZE
	cell.owns_ram = 1
	cell.permissions = cast(char*, malloc(DARWIN_CELL_RAM_SIZE / 4096))
	mem_fill[char](cell.permissions, 0, DARWIN_CELL_RAM_SIZE / 4096)
	cell.output = string_new()
	cell.errors = string_new()
	cell.mmap_next = DARWIN_CELL_USER_MIN
	cell.status = 125
	cell.output_limit = 4194304
	cell.syscall_limit = 1000000
	cell.unsupported_syscall = -1
	return cell


void darwin_cell_runtime_free(darwin_cell* cell):
	if (cell.cpu_created): hv_vcpu_destroy(cell.cpu)
	cell.cpu_created = 0
	if (cell.mapped): hv_vm_unmap(0, cell.ram_size)
	cell.mapped = 0
	if (cell.vm_created): hv_vm_destroy()
	cell.vm_created = 0


type darwin_cell_cleanup_fn = fn(darwin_cell*) -> void


void darwin_cell_free(darwin_cell* cell):
	if (cell == 0): return
	darwin_cell_runtime_free(cell)
	if (cell.snapshot_cleanup != 0):
		darwin_cell_cleanup_fn* cleanup = cast(darwin_cell_cleanup_fn*, cell.snapshot_cleanup)
		cleanup(cell)
	if (cell.owns_ram): munmap(cast(int, cell.ram), cell.ram_size)
	free(cell.permissions)
	string_free(cell.output)
	string_free(cell.errors)
	free(cell)


char* darwin_cell_pte(darwin_cell* cell, int address):
	return cell.ram + DARWIN_CELL_PT + (address / 4096) * 8


void darwin_cell_map(darwin_cell* cell, int address, int length, int prot):
	for page in range(address & -4096, darwin_cell_page_end(address + length), 4096):
		cell.permissions[page / 4096] = prot | 8
		int pte = page | 3 | 1024 | 768 | 64 # page, AF, inner shareable, EL0
		if ((prot & 2) == 0): pte = pte | 128 # read-only
		pte = pte | (1 << 53) # never executable at EL1
		if ((prot & 4) == 0): pte = pte | (1 << 54)
		if (prot == 0): pte = 0
		save_int64(darwin_cell_pte(cell, page), pte)


int darwin_cell_range(darwin_cell* cell, int address, int length, int prot):
	if (length < 0): return 0
	if (length == 0): return 1
	if (address < DARWIN_CELL_USER_MIN || address >= cell.ram_size || length > cell.ram_size - address): return 0
	for page in range(address / 4096, (address + length - 1) / 4096 + 1):
		if ((cell.permissions[page] & (prot | 8)) != (prot | 8)): return 0
	return 1


void darwin_cell_tables(darwin_cell* cell):
	# 39-bit VA: L1[0] -> L2; its 128 entries -> 128 L3 pages.
	mem_fill[char](cell.ram, 0, DARWIN_CELL_USER_MIN)
	save_int64(cell.ram + 65536, 69632 | 3)
	for i in range(128): save_int64(cell.ram + 69632 + i * 8, (DARWIN_CELL_PT + i * 4096) | 3)
	# Protected privileged RAM. User copies cannot address it either.
	for page in range(0, DARWIN_CELL_USER_MIN, 4096):
		int pte = page | 3 | 1024 | 768 | (1 << 54) | (1 << 53)
		if (page == 4096 || page == 8192): pte = page | 3 | 1024 | 768 | 128 | (1 << 54)
		save_int64(darwin_cell_pte(cell, page), pte)
	# Clear every SIMD register on entry. General/system registers are set
	# through HV before entry; monitor instructions preserve them.
	for i in range(32): save_int32(cell.ram + 4096 + i * 4, 0x4f00e400 | i) # movi vN.16b,#0
	save_int32(cell.ram + 4224, cast(int, 0xd69f03e0)) # eret to initial EL0 state
	for vector in range(16):
		save_int32(cell.ram + 8192 + vector * 128, cast(int, 0xd4000022)) # hvc #1: fault
		save_int32(cell.ram + 8196 + vector * 128, 0x14000000)
	save_int32(cell.ram + DARWIN_CELL_GATE, cast(int, 0xd4000002)) # hvc #0: lower EL A64 sync
	save_int32(cell.ram + DARWIN_CELL_GATE + 4, cast(int, 0xd5033a9f)) # dsb ishst
	save_int32(cell.ram + DARWIN_CELL_GATE + 8, cast(int, 0xd508871f)) # tlbi vmalle1
	save_int32(cell.ram + DARWIN_CELL_GATE + 12, cast(int, 0xd5033b9f)) # dsb ish
	save_int32(cell.ram + DARWIN_CELL_GATE + 16, cast(int, 0xd5033fdf)) # isb
	save_int32(cell.ram + DARWIN_CELL_GATE + 20, cast(int, 0xd69f03e0)) # eret


int darwin_cell_elf_load(darwin_cell* cell, char* image, int length):
	if (cell.loaded || cell.started): return darwin_cell_fail(cell, c"cell already loaded")
	if (length < 64): return darwin_cell_fail(cell, c"truncated ELF header")
	if (load_int32(image) != 0x464c457f): return darwin_cell_fail(cell, c"not an ELF image")
	if (image[4] != 2 || image[5] != 1 || image[6] != 1 || (image[7] != 0 && image[7] != 3) || image[8] != 0): return darwin_cell_fail(cell, c"requires little-endian ELF64")
	if (load_int16(image + 16) != 2 || load_int16(image + 18) != 183 || load_int32(image + 20) != 1):
		return darwin_cell_fail(cell, c"requires a static ARM64 Linux ET_EXEC image")
	if (load_int16(image + 52) != 64 || load_int16(image + 54) != 56 || load_int32(image + 48) != 0):
		return darwin_cell_fail(cell, c"invalid ELF header sizes or flags")
	int phoff = load_int64(image + 32)
	int count = load_int16(image + 56)
	if (count == 0 || count > 128 || phoff < 64 || phoff > length): return darwin_cell_fail(cell, c"invalid program header table")
	if (count > (length - phoff) / 56): return darwin_cell_fail(cell, c"truncated program header table")
	int entry = load_int64(image + 24)
	int executable = 0
	int high = DARWIN_CELL_IMAGE_MIN
	for i in range(count):
		char* ph = image + phoff + i * 56
		int kind = load_int32(ph)
		if (kind == 2 || kind == 3): return darwin_cell_fail(cell, c"dynamic ELF images are unsupported")
		if (kind == 7): return darwin_cell_fail(cell, c"ELF TLS segments are unsupported")
		if (kind == 1):
			int flags = load_int32(ph + 4)
			int offset = load_int64(ph + 8)
			int address = load_int64(ph + 16)
			int filesz = load_int64(ph + 32)
			int memsz = load_int64(ph + 40)
			int align = load_int64(ph + 48)
			if (flags < 0 || flags > 7 || filesz < 0 || memsz < filesz): return darwin_cell_fail(cell, c"invalid load segment")
			if (offset < 0 || offset > length || filesz > length - offset): return darwin_cell_fail(cell, c"truncated load segment")
			if (address < DARWIN_CELL_IMAGE_MIN || address >= DARWIN_CELL_IMAGE_MAX || memsz > DARWIN_CELL_IMAGE_MAX - address):
				return darwin_cell_fail(cell, c"load segment outside cell image range")
			if (align < 0 || (align > 1 && ((align & (align - 1)) != 0 || address % align != offset % align))):
				return darwin_cell_fail(cell, c"invalid segment alignment")
			if (memsz > 0):
				for j in range(i):
					char* other = image + phoff + j * 56
					if (load_int32(other) == 1):
						int start = load_int64(other + 16)
						int size = load_int64(other + 40)
						if (size > 0 && (address & -4096) < darwin_cell_page_end(start + size) && (start & -4096) < darwin_cell_page_end(address + memsz)):
							return darwin_cell_fail(cell, c"overlapping load segments")
			if (entry >= address && entry - address < memsz && (flags & 1)): executable = 1
			if (address + memsz > high): high = address + memsz
	if (executable == 0 || entry % 4 != 0): return darwin_cell_fail(cell, c"entry is not an aligned executable address")
	darwin_cell_tables(cell)
	for i in range(count):
		char* ph = image + phoff + i * 56
		if (load_int32(ph) == 1):
			int address = load_int64(ph + 16)
			int filesz = load_int64(ph + 32)
			int memsz = load_int64(ph + 40)
			int flags = load_int32(ph + 4)
			int prot = 0
			if (flags & 4): prot = prot | 1
			if (flags & 2): prot = prot | 2 | 1
			if (flags & 1): prot = prot | 4 | 1
			if (memsz > 0): darwin_cell_map(cell, address, memsz, prot)
			mem_copy[char](cell.ram + address, image + load_int64(ph + 8), filesz)
	cell.entry = entry
	cell.heap_start = darwin_cell_page_end(high)
	cell.heap_end = cell.heap_start
	cell.loaded = 1
	return 1


int darwin_cell_load(darwin_cell* cell, char* path):
	# O_NONBLOCK prevents a FIFO image from blocking the daemon scheduler.
	int fd = open(path, 2048, 0)
	if (fd < 0): return darwin_cell_fail(cell, c"cannot open guest image")
	# Darwin arm64 struct stat: 144 bytes, st_mode u16 at offset 4.
	# Validate the opened descriptor, avoiding path/fstat races.
	char[144] record
	if ((darwin_cell_fstat(fd, &record[0]) & ((1 << 32) - 1)) != 0 || (load_int16(&record[4]) & 61440) != 32768):
		close(fd)
		return darwin_cell_fail(cell, c"guest image must be a regular file")
	int length = seek(fd, 0, 2)
	if (length < 64 || length > 67108864 || seek(fd, 0, 0) != 0):
		close(fd)
		return darwin_cell_fail(cell, c"invalid guest image length")
	char* image = cast(char*, malloc(length))
	int done = 0
	while (done < length):
		int count = read(fd, image + done, length - done)
		if (count <= 0): break
		done = done + count
	close(fd)
	int result = 0
	if (done == length): result = darwin_cell_elf_load(cell, image, length)
	else: darwin_cell_fail(cell, c"cannot read guest image")
	free(image)
	return result


int darwin_cell_stack(darwin_cell* cell, int argc, char** argv):
	if (cell.loaded == 0 || cell.started): return darwin_cell_fail(cell, c"stack requires a loaded, unstarted cell")
	if (argc < 1 || argc > 256): return darwin_cell_fail(cell, c"invalid guest argument count")
	int sp = DARWIN_CELL_STACK_TOP
	int[256] pointers
	for i in range(argc):
		int size = strlen(argv[i]) + 1
		if (size > 65536 || sp - DARWIN_CELL_STACK_LOW < size + 4096): return darwin_cell_fail(cell, c"guest arguments too large")
		sp = sp - size
		mem_copy[char](cell.ram + sp, argv[i], size)
		pointers[i] = sp
	char* env = c"W_CRASH_TRACE=0"
	sp = sp - strlen(env) - 1
	mem_copy[char](cell.ram + sp, env, strlen(env) + 1)
	int env_address = sp
	sp = (sp - (argc + 9) * 8) & -16
	save_int64(cell.ram + sp, argc)
	for i in range(argc): save_int64(cell.ram + sp + 8 + i * 8, pointers[i])
	int tail = sp + 8 + argc * 8
	save_int64(cell.ram + tail, 0)
	save_int64(cell.ram + tail + 8, env_address)
	save_int64(cell.ram + tail + 16, 0)
	save_int64(cell.ram + tail + 24, 6)
	save_int64(cell.ram + tail + 32, 4096)
	save_int64(cell.ram + tail + 40, 0)
	save_int64(cell.ram + tail + 48, 0)
	darwin_cell_map(cell, DARWIN_CELL_STACK_LOW, DARWIN_CELL_STACK_TOP - DARWIN_CELL_STACK_LOW, 3)
	cell.stack = sp
	return 1


int darwin_cell_mmap(darwin_cell* cell, int address, int length, int prot, int flags, int fd, int offset):
	if (address != 0 || fd != -1 || offset != 0 || prot < 0 || prot > 7): return -22
	if ((flags & 34) != 34 || (flags & -131363) != 0): return -22
	if (length <= 0 || length > DARWIN_CELL_IMAGE_MIN - cell.mmap_next): return -12
	int size = darwin_cell_page_end(length)
	if (size > DARWIN_CELL_IMAGE_MIN - cell.mmap_next): return -12
	int result = cell.mmap_next
	cell.mmap_next = result + size
	darwin_cell_map(cell, result, size, prot)
	return result


int darwin_cell_brk(darwin_cell* cell, int address):
	if (address == 0): return cell.heap_end
	if (address < cell.heap_start || address > DARWIN_CELL_HEAP_MAX): return cell.heap_end
	int old_page = darwin_cell_page_end(cell.heap_end)
	int new_page = darwin_cell_page_end(address)
	if (new_page > old_page): darwin_cell_map(cell, old_page, new_page - old_page, 3)
	if (new_page < old_page):
		for page in range(new_page, old_page, 4096):
			save_int64(darwin_cell_pte(cell, page), 0)
			cell.permissions[page / 4096] = 0
		mem_fill[char](cell.ram + new_page, 0, old_page - new_page)
	cell.heap_end = address
	return address


int darwin_cell_mprotect(darwin_cell* cell, int address, int length, int prot):
	if (address % 4096 != 0 || length < 0 || prot < 0 || prot > 7): return -22
	if (address < DARWIN_CELL_USER_MIN || address >= cell.ram_size || length > cell.ram_size - address): return -12
	int end = darwin_cell_page_end(address + length)
	for page in range(address, end, 4096):
		if ((cell.permissions[page / 4096] & 8) == 0): return -12
	if (length > 0): darwin_cell_map(cell, address, length, prot)
	return 0


int darwin_cell_munmap(darwin_cell* cell, int address, int length):
	if (length <= 0 || address % 4096 != 0): return -22
	if (address < DARWIN_CELL_USER_MIN || address >= cell.mmap_next || length > cell.mmap_next - address): return -22
	int size = darwin_cell_page_end(length)
	for page in range(address, address + size, 4096):
		save_int64(darwin_cell_pte(cell, page), 0)
		cell.permissions[page / 4096] = 0
	mem_fill[char](cell.ram + address, 0, size)
	return 0


int darwin_cell_syscall(darwin_cell* cell, int nr, int a, int b, int c, int d, int e, int f):
	if (nr == 93 || nr == 94):
		cell.status = a & 255
		cell.exited = 1
		return 0
	if (nr == 63 || nr == 64):
		if (a < 0 || a > 2 || (cell.closed_fds & (1 << a))): return -9
		if ((nr == 63 && a != 0) || (nr == 64 && a == 0)): return -9
		if (c == 0): return 0
		int prot = 1
		if (nr == 63): prot = 2
		if (darwin_cell_range(cell, b, c, prot) == 0): return -14
		if (nr == 63):
			int count = cell.input_length - cell.input_pos
			if (c < count): count = c
			if (count > 0): mem_copy[char](cell.ram + b, cell.input + cell.input_pos, count)
			cell.input_pos = cell.input_pos + count
			return count
		if (c > cell.output_limit - cell.output_bytes):
			darwin_cell_fail(cell, c"guest output limit exceeded")
			cell.exited = 1
			return -27
		if (a == 1): string_append_bytes(cell.output, cell.ram + b, c)
		else: string_append_bytes(cell.errors, cell.ram + b, c)
		cell.output_bytes = cell.output_bytes + c
		return c
	if (nr == 57):
		if (a < 0 || a > 2 || (cell.closed_fds & (1 << a))): return -9
		cell.closed_fds = cell.closed_fds | (1 << a)
		return 0
	if (nr == 222): return darwin_cell_mmap(cell, a, b, c, d, e, f)
	if (nr == 214): return darwin_cell_brk(cell, a)
	if (nr == 215): return darwin_cell_munmap(cell, a, b)
	if (nr == 226): return darwin_cell_mprotect(cell, a, b, c)
	if (nr == 113):
		if (a != 0 && a != 1): return -22
		if (darwin_cell_range(cell, b, 16, 2) == 0): return -14
		int clock = 0
		if (a == 1): clock = 6
		if (dhv_clock_gettime(clock, cast(int*, cell.ram + b)) != 0): return -22
		return 0
	if (nr == 278):
		if (c < 0 || c > 3): return -22
		if (b > 1048576): return -22
		if (darwin_cell_range(cell, a, b, 2) == 0): return -14
		arc4random_buf(cell.ram + a, b)
		return b
	# No host descriptors, paths, network, or threads cross this boundary.
	if (nr == 56 || nr == 198 || nr == 203): return -13
	if (nr == 172 || nr == 178): return 1
	if (nr == 174 || nr == 175 || nr == 176 || nr == 177): return 65534
	if (nr == 96): return 1 # set_tid_address: no guest threads
	cell.unsupported_syscall = nr
	return -38


int darwin_cell_cpu_setup(darwin_cell* cell):
	int result = hv_vm_create(0)
	if (result != 0): return darwin_cell_fail(cell, c"Hypervisor VM creation failed (check entitlement)")
	cell.vm_created = 1
	if (hv_vm_map(cell.ram, 0, cell.ram_size, 7) != 0): return darwin_cell_fail(cell, c"Hypervisor RAM mapping failed")
	cell.mapped = 1
	if (hv_vcpu_create(&cell.cpu, &cell.exit_state, 0) != 0): return darwin_cell_fail(cell, c"Hypervisor vCPU creation failed")
	cell.cpu_created = 1
	int rc = hv_vcpu_set_vtimer_mask(cell.cpu, 1)
	for i in range(31): rc = rc | hv_vcpu_set_reg(cell.cpu, i, 0)
	rc = rc | hv_vcpu_set_reg(cell.cpu, 32, 0) # FPCR
	rc = rc | hv_vcpu_set_reg(cell.cpu, 33, 0) # FPSR
	rc = rc | hv_vcpu_set_reg(cell.cpu, 31, 4096)
	rc = rc | hv_vcpu_set_reg(cell.cpu, 34, 0x3c5) # masked EL1h
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc082, 3 << 20) # CPACR FPEN
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc100, 65536) # TTBR0
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc102, 25 | (1 << 8) | (1 << 10) | (3 << 12) | (1 << 23) | (2 << 32))
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc510, 255) # MAIR normal WB
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc600, 8192) # VBAR
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc201, cell.entry) # ELR
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc200, 0x3c0) # SPSR EL0t
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc208, cell.stack)
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xe208, 1044480)
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xde82, 0)
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xde83, 0)
	rc = rc | hv_vcpu_set_sys_reg(cell.cpu, 0xc080, 0x30d01805) # SCTLR: M,C,I, RES1
	if (rc != 0): return darwin_cell_fail(cell, c"Hypervisor register initialization failed")
	return 1


int darwin_cell_run(darwin_cell* cell, int timeout_ms):
	if (cell.loaded == 0 || cell.stack == 0 || cell.started): return darwin_cell_fail(cell, c"cell is not ready")
	if (timeout_ms < 1 || timeout_ms > 600000): return darwin_cell_fail(cell, c"timeout must be 1..600000 ms")
	if (cell.input_length < 0 || cell.input_length > 4194304 || (cell.input_length > 0 && cell.input == 0)):
		return darwin_cell_fail(cell, c"invalid bounded guest input")
	if (cell.output_limit < 1 || cell.output_limit > 4194304 || cell.syscall_limit < 1 || cell.syscall_limit > 1000000):
		return darwin_cell_fail(cell, c"invalid guest output or syscall quota")
	cell.started = 1
	if (darwin_cell_cpu_setup(cell) == 0):
		darwin_cell_runtime_free(cell)
		return 0
	# Watchdog interrupts CPU-only guests; it is joined before CPU teardown.
	dhv_watchdog* watchdog = dhv_watchdog_start(cell.cpu, timeout_ms)
	if (watchdog == 0):
		darwin_cell_runtime_free(cell)
		return darwin_cell_fail(cell, c"cannot start Hypervisor watchdog")
	while (cell.exited == 0):
		if (dhv_now_ms() >= watchdog.deadline):
			cell.status = 124
			darwin_cell_fail(cell, c"guest deadline exceeded")
			break
		if (hv_vcpu_run(cell.cpu) != 0):
			darwin_cell_fail(cell, c"Hypervisor run failed")
			break
		if (cell.exit_state.reason == 0):
			cell.status = 124
			darwin_cell_fail(cell, c"guest deadline or cancellation")
			break
		int pc = 0
		int cpsr = 0
		int esr = 0
		int elr = 0
		int spsr = 0
		int far = 0
		int rc = hv_vcpu_get_reg(cell.cpu, 31, &pc)
		rc = rc | hv_vcpu_get_reg(cell.cpu, 34, &cpsr)
		rc = rc | hv_vcpu_get_sys_reg(cell.cpu, 0xc290, &esr)
		rc = rc | hv_vcpu_get_sys_reg(cell.cpu, 0xc201, &elr)
		rc = rc | hv_vcpu_get_sys_reg(cell.cpu, 0xc200, &spsr)
		rc = rc | hv_vcpu_get_sys_reg(cell.cpu, 0xc300, &far)
		cell.gate_pc = pc
		cell.gate_cpsr = cpsr
		cell.gate_syndrome = cell.exit_state.syndrome
		cell.guest_spsr = spsr
		cell.fault_pc = elr
		cell.fault_syndrome = esr
		cell.fault_address = far
		if (rc != 0):
			darwin_cell_fail(cell, c"cannot read guest exception state")
			break
		if (cell.exit_state.reason != 1 || (cell.exit_state.syndrome >> 26) != 22 || pc != DARWIN_CELL_GATE + 4 || (cpsr & 31) != 5 || (esr >> 26) != 21 || (esr & 65535) != 0 || (spsr & 31) != 0 || elr % 4 != 0 || darwin_cell_range(cell, elr - 4, 4, 4) == 0):
			cell.status = 139
			darwin_cell_fail(cell, c"guest exception or invalid syscall gate")
			break
		cell.syscall_count = cell.syscall_count + 1
		if (cell.syscall_count > cell.syscall_limit):
			darwin_cell_fail(cell, c"guest syscall limit exceeded")
			break
		int[9] regs
		for i in range(9): rc = rc | hv_vcpu_get_reg(cell.cpu, i, &regs[i])
		if (rc != 0):
			darwin_cell_fail(cell, c"cannot read guest syscall registers")
			break
		int value = darwin_cell_syscall(cell, regs[8], regs[0], regs[1], regs[2], regs[3], regs[4], regs[5])
		if (hv_vcpu_set_reg(cell.cpu, 0, value) != 0 || hv_vcpu_set_reg(cell.cpu, 31, DARWIN_CELL_GATE + 4) != 0):
			darwin_cell_fail(cell, c"cannot resume guest syscall")
			break
	dhv_watchdog_stop(watchdog)
	darwin_cell_runtime_free(cell)
	return cell.error == 0
