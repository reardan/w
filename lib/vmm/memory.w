# Fixed 256 MiB guest-physical address space. Only mapped/touched pages
# consume host RAM. Low 2 MiB is supervisor-only (tables and traps).
# User image/brk: 128..240 MiB; anonymous mmap: 2..128 MiB; stack: 248..256 MiB.
# Page permissions are enforced by guest page tables AND syscall copies.
import lib.kvm
import structures.string

const int CELL_RAM_SIZE = 268435456
const int CELL_IMAGE_MIN = 134217728
const int CELL_IMAGE_MAX = 234881024
const int CELL_HEAP_MAX = 251658240
const int CELL_STACK_LOW = 260046848
const int CELL_STACK_TOP = 268431360
const int CELL_USER_MIN = 2097152
const int CELL_PT_BASE = 65536
const int CELL_TRAMPOLINE = 28672
const int CELL_OUTPUT_LIMIT = 4194304

struct vm_cell:
	kvm_machine* machine
	char* ram
	char* regs
	char* sregs
	int entry
	int stack
	int heap_start
	int heap_end
	int mmap_next
	int loaded
	int started
	int status
	int exited
	int fault_vector
	int fault_rip
	int last_exit
	int unsupported_syscall
	int output_bytes
	int closed_fds
	char* input
	int input_length
	int input_pos
	string_builder* output
	string_builder* errors
	char* error


int cell_fail(vm_cell* cell, char* error):
	cell.error = error
	return 0


vm_cell* cell_new():
	if (__word_size__ != 8): return 0
	int addr = mmap(0, CELL_RAM_SIZE, 3, MAP_PRIVATE | MAP_ANONYMOUS)
	if (addr < 0 && addr > -4096): return 0
	vm_cell* cell = malloc(sizeof(vm_cell))
	mem_fill[char](cast(char*, cell), 0, sizeof(vm_cell))
	cell.ram = cast(char*, addr)
	cell.regs = malloc(KVM_REGS_SIZE)
	cell.sregs = malloc(KVM_SREGS_SIZE)
	mem_fill[char](cell.regs, 0, KVM_REGS_SIZE)
	mem_fill[char](cell.sregs, 0, KVM_SREGS_SIZE)
	cell.output = string_new()
	cell.errors = string_new()
	cell.mmap_next = CELL_USER_MIN
	cell.fault_vector = -1
	cell.unsupported_syscall = -1
	cell.status = 125
	return cell


void cell_free(vm_cell* cell):
	if (cell == 0): return
	if (cell.machine != 0):
		kvm_destroy(cell.machine)
		free(cell.machine)
	munmap(cast(int, cell.ram), CELL_RAM_SIZE)
	free(cell.regs)
	free(cell.sregs)
	string_free(cell.output)
	string_free(cell.errors)
	free(cell)


int cell_page_end(int address):
	return (address + 4095) & -4096


char* cell_pte(vm_cell* cell, int address):
	return cell.ram + CELL_PT_BASE + (address / 4096) * 8


# Guest protection bits follow Linux PROT_*. NX is constructed at run
# time, since W's hex literals with bit 31 set sign-extend.
void cell_map(vm_cell* cell, int address, int length, int prot):
	int page = address & -4096
	int end = cell_page_end(address + length)
	while (page < end):
		int flags = 5 # present, user
		if (prot == 0): flags = 4 # reserved but inaccessible
		if (prot & PROT_WRITE): flags = flags | 2
		int nx = 1
		if ((prot & PROT_EXEC) == 0): flags = flags | (nx << 63)
		save_int64(cell_pte(cell, page), page | flags)
		page = page + 4096


# Range checks avoid overflow, including hostile 64-bit syscall args.
int cell_range(vm_cell* cell, int address, int length, int writing):
	if (address < CELL_USER_MIN || address >= CELL_RAM_SIZE): return 0
	if (length < 0 || length > CELL_RAM_SIZE - address): return 0
	if (length == 0): return 1
	int end = address + length
	int page = address & -4096
	while (page < end):
		int flags = load_int64(cell_pte(cell, page))
		if ((flags & 5) != 5): return 0
		if (writing && (flags & 2) == 0): return 0
		page = page + 4096
	return 1


void cell_page_tables(vm_cell* cell):
	# Identity-map the 256 MiB address space through 4 KiB leaf pages.
	save_int64(cell.ram + 4096, 8192 | 7)
	save_int64(cell.ram + 8192, 12288 | 7)
	for i in range(128):
		save_int64(cell.ram + 12288 + i * 8, (CELL_PT_BASE + i * 4096) | 7)
	# Supervisor pages: guest CPL3 cannot read or rewrite page tables,
	# descriptors, trap code, or the exception stack.
	for i in range(CELL_USER_MIN / 4096):
		save_int64(cell_pte(cell, i * 4096), (i * 4096) | 3)
