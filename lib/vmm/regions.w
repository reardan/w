# Explicit shared pages live in the unused 240..248 MiB guest range.
# Binding is opt-in before execution and independent of private template RAM.
import lib.vmm.snapshot
import lib.vmm.backing

const int VM_REGION_MAP_FIXED = 16

struct vm_region:
	int id
	int available
	int references
	int fd
	int length
	int writable
	int lease_deadline

struct cell_region_binding:
	int length


vm_region* vm_region_new(int length, int writable, char* data):
	if (length < 4096 || length > CELL_STACK_LOW - CELL_HEAP_MAX || length % 4096 != 0 || writable < 0 || writable > 1): return 0
	int bytes = 0
	if (data != 0): bytes = strlen(data)
	if (bytes > length): return 0
	int fd = memfd_create(c"wvm-shared-region", MFD_CLOEXEC | MFD_ALLOW_SEALING)
	if (fd < 0): return 0
	int ok = sys_ftruncate(fd, length) == 0
	if (ok && bytes > 0): ok = write(fd, data, bytes) == bytes
	int seals = F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL
	if (writable == 0): seals = seals | F_SEAL_WRITE
	if (ok): ok = sys_fcntl(fd, F_ADD_SEALS, seals) == 0
	if (ok == 0):
		close(fd)
		return 0
	vm_region* region = new vm_region()
	mem_fill[char](cast(char*, region), 0, sizeof(vm_region))
	region.available = 1
	region.fd = fd
	region.length = length
	region.writable = writable
	return region


void vm_region_free(vm_region* region):
	if (region == 0): return
	close(region.fd)
	free(region)


void cell_region_unbind(vm_cell* cell):
	cell_region_binding* binding = cast(cell_region_binding*, cell.region_state)
	if (binding == 0): return
	# The reserved gap has no template pages. Replacing the shared VMA
	# before snapshot reset makes MADV_DONTNEED affect private memory only.
	int address = cast(int, cell.ram) + CELL_HEAP_MAX
	int restored = mmap(address, binding.length, PROT_READ | PROT_WRITE, VM_REGION_MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS)
	if (restored != address):
		# A missing VMA cannot safely be reused as cell RAM.
		exit(125)
	cell_map(cell, CELL_HEAP_MAX, binding.length, 0)
	free(binding)
	cell.region_state = 0
	cell.region_cleanup = 0


int cell_region_bind(vm_cell* cell, vm_region* region, int writable):
	if (cell == 0 || region == 0 || cell.loaded == 0 || cell.started || cell.machine != 0 || cell.retain_cpus || cell.deterministic || cell.region_state != 0): return 0
	if (writable < 0 || writable > region.writable): return 0
	int prot = PROT_READ
	if (writable): prot = prot | PROT_WRITE
	int address = cast(int, cell.ram) + CELL_HEAP_MAX
	int mapped = mmap_fd(address, region.length, prot, MAP_SHARED | VM_REGION_MAP_FIXED, region.fd, 0)
	if (mapped != address): return 0
	cell.region_state = cast(void*, new cell_region_binding(region.length))
	cell.region_cleanup = cast(void*, cell_region_unbind)
	cell_map(cell, CELL_HEAP_MAX, region.length, prot)
	return 1


struct vm_region_request:
	int length
	int writable
	char* data


int vm_region_builder(void* request, char* metadata):
	vm_region_request* params = cast(vm_region_request*, request)
	vm_region* region = vm_region_new(params.length, params.writable, params.data)
	if (region == 0): return -1
	return region.fd


vm_region* vm_region_new_charged(vm_cgroup* group, int length, int writable, char* data):
	vm_region_request request
	request.length = length
	request.writable = writable
	request.data = data
	int fd = vm_backing_create(group, vm_region_builder, cast(void*, &request), 0, 0)
	if (fd < 0): return 0
	vm_region* region = new vm_region()
	mem_fill[char](cast(char*, region), 0, sizeof(vm_region))
	region.available = 1
	region.length = length
	region.writable = writable
	region.fd = fd
	return region
