# Minimal Linux x64 KVM ABI. All kernel records use explicit byte
# offsets (linux/kvm.h and asm/kvm.h), never W's word-sized structs.
# Each instance owns its fds and run mapping; caller owns guest RAM.
import lib.mem
import lib.memfd
import lib.__arch__.kvm

const int KVM_REGS_SIZE = 144
const int KVM_SREGS_SIZE = 312
const int KVM_EXIT_IO = 2
const int KVM_EXIT_HLT = 5
const int KVM_EXIT_INTR = 10
const int KVM_EXIT_XEN = 34

struct kvm_machine:
	int system_fd
	int vm_fd
	int cpu_fd
	char* run
	int run_size
	int error
	int cpuid_set
	char* reset_state # pristine vCPU state, only allocated for retained cells


# Avoid sign-extending ioctl constants with bit 31 set on x64.
int kvm_request(int direction, int size, int number):
	return (direction << 30) | (size << 16) | (174 << 8) | number


void kvm_destroy(kvm_machine* vm):
	free(vm.reset_state)
	vm.reset_state = 0
	if (vm.run != 0): munmap(cast(int, vm.run), vm.run_size)
	if (vm.cpu_fd >= 0): close(vm.cpu_fd)
	if (vm.vm_fd >= 0): close(vm.vm_fd)
	if (vm.system_fd >= 0): close(vm.system_fd)
	vm.run = 0
	vm.cpu_fd = -1
	vm.vm_fd = -1
	vm.system_fd = -1


int kvm_get_regs(kvm_machine* vm, char* regs):
	return sys_ioctl(vm.cpu_fd, kvm_request(2, KVM_REGS_SIZE, 129), cast(int, regs))

int kvm_set_regs(kvm_machine* vm, char* regs):
	return sys_ioctl(vm.cpu_fd, kvm_request(1, KVM_REGS_SIZE, 130), cast(int, regs))

int kvm_get_sregs(kvm_machine* vm, char* regs):
	return sys_ioctl(vm.cpu_fd, kvm_request(2, KVM_SREGS_SIZE, 131), cast(int, regs))

int kvm_set_sregs(kvm_machine* vm, char* regs):
	return sys_ioctl(vm.cpu_fd, kvm_request(1, KVM_SREGS_SIZE, 132), cast(int, regs))

int kvm_run(kvm_machine* vm):
	return sys_ioctl(vm.cpu_fd, kvm_request(0, 0, 128), 0)


# Xen's userspace hypercall interception accepts CPL3 and the Linux x64
# argument registers. Ordinary KVM hypercalls reject CPL3 before userspace.
# No Xen guest services/shared-info pages are exposed or configured here.
int kvm_enable_vmcall(kvm_machine* vm):
	int caps = sys_ioctl(vm.system_fd, kvm_request(0, 0, 3), 38)
	if (caps < 0 || (caps & 2) == 0): return 0
	char[56] config
	mem_fill[char](&config[0], 0, 56)
	save_int32(&config[0], 2)
	save_int32(&config[4], 1073741824) # Xen hypercall MSR enables interception
	return sys_ioctl(vm.vm_fd, kvm_request(1, 56, 122), cast(int, &config[0])) == 0


void kvm_memory_record(char* record, int slot, int guest, char* host, int size):
	mem_fill[char](record, 0, 32)
	save_int32(record, slot)
	save_int64(record + 8, guest)
	save_int64(record + 16, size)
	save_int64(record + 24, cast(int, host))


int kvm_set_memory(kvm_machine* vm, int slot, int guest, char* host, int size):
	char[32] record
	kvm_memory_record(&record[0], slot, guest, host, size)
	return sys_ioctl(vm.vm_fd, kvm_request(1, 32, 70), cast(int, &record[0]))


# Initialize even on failure, so kvm_destroy is always safe. error
# preserves the raw errno. An unsupported API is reported as -ENOSYS.
int kvm_create(kvm_machine* vm):
	vm.system_fd = -1
	vm.vm_fd = -1
	vm.cpu_fd = -1
	vm.run = 0
	vm.run_size = 0
	vm.error = 0
	vm.cpuid_set = 0
	vm.reset_state = 0
	vm.system_fd = kvm_open_system()
	if (vm.system_fd < 0):
		vm.error = vm.system_fd
		return 0
	int version = sys_ioctl(vm.system_fd, kvm_request(0, 0, 0), 0)
	if (version != 12):
		vm.error = -38
		return 0
	vm.vm_fd = sys_ioctl(vm.system_fd, kvm_request(0, 0, 1), 0)
	if (vm.vm_fd < 0):
		vm.error = vm.vm_fd
		return 0
	# Three pages outside guest RAM, required on Intel hosts.
	int status = sys_ioctl(vm.vm_fd, kvm_request(0, 0, 71), (65531 << 16) | 53248)
	if (status < 0):
		vm.error = status
		return 0
	vm.cpu_fd = sys_ioctl(vm.vm_fd, kvm_request(0, 0, 65), 0)
	if (vm.cpu_fd < 0):
		vm.error = vm.cpu_fd
		return 0
	vm.run_size = sys_ioctl(vm.system_fd, kvm_request(0, 0, 4), 0)
	if (vm.run_size < 4096):
		vm.error = -22
		return 0
	int addr = mmap_fd(0, vm.run_size, 3, MAP_SHARED, vm.cpu_fd, 0)
	if (addr < 0 && addr > -4096):
		vm.error = addr
		return 0
	vm.run = cast(char*, addr)
	return 1


# Ask KVM for the supported CPUID instead of inventing a CPU model.
int kvm_set_supported_cpuid(kvm_machine* vm):
	# CPUID is immutable once this vCPU has run. Host-dependent leaves may
	# differ when fetched on another physical CPU; never reinstall on reset.
	if (vm.cpuid_set): return 0
	int capacity = 256
	char* cpuid = cast(char*, malloc(8 + capacity * 40))
	mem_fill[char](cpuid, 0, 8 + capacity * 40)
	save_int32(cpuid, capacity)
	int status = sys_ioctl(vm.system_fd, kvm_request(3, 8, 5), cast(int, cpuid))
	if (status == 0): status = sys_ioctl(vm.cpu_fd, kvm_request(1, 8, 144), cast(int, cpuid))
	free(cpuid)
	if (status == 0): vm.cpuid_set = 1
	return status


int kvm_set_msr(kvm_machine* vm, int index, int value):
	char[24] msr
	mem_fill[char](&msr[0], 0, 24)
	save_int32(&msr[0], 1)
	save_int32(&msr[8], index)
	save_int64(&msr[16], value)
	int count = sys_ioctl(vm.cpu_fd, kvm_request(1, 8, 137), cast(int, &msr[0]))
	if (count == 1): return 0
	if (count < 0): return count
	return -22


# Additional vCPU in an existing VM. Dup the shared descriptors so
# ordinary kvm_destroy owns and releases every descriptor it sees.
int kvm_create_cpu(kvm_machine* child, kvm_machine* parent, int id):
	mem_fill[char](cast(char*, child), 0, sizeof(kvm_machine))
	child.system_fd = -1
	child.vm_fd = -1
	child.cpu_fd = -1
	child.system_fd = syscall(32, parent.system_fd, 0, 0)
	if (child.system_fd < 0): return 0
	child.vm_fd = syscall(32, parent.vm_fd, 0, 0)
	if (child.vm_fd < 0): return 0
	child.cpu_fd = sys_ioctl(parent.vm_fd, kvm_request(0, 0, 65), id)
	if (child.cpu_fd < 0): return 0
	child.run_size = parent.run_size
	int address = mmap_fd(0, child.run_size, 3, MAP_SHARED, child.cpu_fd, 0)
	if (address < 0 && address > -4096): return 0
	child.run = cast(char*, address)
	return 1


# XSAVE preserves SSE/AVX and all enabled extended state when cloning.
# XSAVE2 reports the host-dependent size (AMX can exceed 4096 bytes).
int kvm_copy_xsave(kvm_machine* destination, kvm_machine* source):
	int size = sys_ioctl(source.system_fd, kvm_request(0, 0, 3), 208)
	int request = 207
	if (size <= 0):
		size = 4096
		request = 164
	if (size > 1048576): return -22
	char* state = cast(char*, malloc(size))
	mem_fill[char](state, 0, size)
	int result = sys_ioctl(source.cpu_fd, kvm_request(2, 4096, request), cast(int, state))
	if (result == 0): result = sys_ioctl(destination.cpu_fd, kvm_request(1, 4096, 165), cast(int, state))
	free(state)
	return result


# Cell-only reset image: ring 3 cannot alter privileged MSRs/debug state.
# Restore all userspace-modifiable extended state, segments, pending events,
# and MP state. STAR/LSTAR/FMASK are reinstalled by the cell gate setup.
int kvm_cell_checkpoint(kvm_machine* vm):
	if (vm.reset_state != 0): return 1
	int size = sys_ioctl(vm.vm_fd, kvm_request(0, 0, 3), 208)
	int request = 207
	if (size <= 0):
		size = 4096
		request = 164
	if (size > 1048576): return 0
	char* state = cast(char*, malloc(4096 + size))
	mem_fill[char](state, 0, 4096 + size)
	int ok = kvm_get_regs(vm, state) == 0
	if (ok): ok = kvm_get_sregs(vm, state + 144) == 0
	if (ok): ok = sys_ioctl(vm.cpu_fd, kvm_request(2, 64, 159), cast(int, state + 456)) == 0
	if (ok): ok = sys_ioctl(vm.cpu_fd, kvm_request(2, 128, 161), cast(int, state + 520)) == 0
	if (ok): ok = sys_ioctl(vm.cpu_fd, kvm_request(2, 392, 166), cast(int, state + 648)) == 0
	if (ok): ok = sys_ioctl(vm.cpu_fd, kvm_request(2, 4, 152), cast(int, state + 1040)) == 0
	if (ok): ok = sys_ioctl(vm.cpu_fd, kvm_request(2, 4096, request), cast(int, state + 4096)) == 0
	if (ok == 0):
		free(state)
		return 0
	vm.reset_state = state
	return 1


int kvm_cell_restore(kvm_machine* vm):
	char* state = vm.reset_state
	if (state == 0): return 0
	# Complete any pending OUT without executing another instruction. KVM
	# requires this before overwriting state after an I/O exit.
	vm.run[1] = 1
	int completed = kvm_run(vm)
	vm.run[1] = 0
	if (completed != -4): return 0
	if (kvm_set_sregs(vm, state + 144) < 0): return 0
	if (sys_ioctl(vm.cpu_fd, kvm_request(1, 392, 167), cast(int, state + 648)) < 0): return 0
	if (sys_ioctl(vm.cpu_fd, kvm_request(1, 4096, 165), cast(int, state + 4096)) < 0): return 0
	if (sys_ioctl(vm.cpu_fd, kvm_request(1, 128, 162), cast(int, state + 520)) < 0): return 0
	if (sys_ioctl(vm.cpu_fd, kvm_request(1, 64, 160), cast(int, state + 456)) < 0): return 0
	if (sys_ioctl(vm.cpu_fd, kvm_request(1, 4, 153), cast(int, state + 1040)) < 0): return 0
	return kvm_set_regs(vm, state) == 0
