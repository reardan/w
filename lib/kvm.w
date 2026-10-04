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

struct kvm_machine:
	int system_fd
	int vm_fd
	int cpu_fd
	char* run
	int run_size
	int error


# Avoid sign-extending ioctl constants with bit 31 set on x64.
int kvm_request(int direction, int size, int number):
	return (direction << 30) | (size << 16) | (174 << 8) | number


void kvm_destroy(kvm_machine* vm):
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
	int capacity = 256
	char* cpuid = malloc(8 + capacity * 40)
	mem_fill[char](cpuid, 0, 8 + capacity * 40)
	save_int32(cpuid, capacity)
	int status = sys_ioctl(vm.system_fd, kvm_request(3, 8, 5), cast(int, cpuid))
	if (status == 0): status = sys_ioctl(vm.cpu_fd, kvm_request(1, 8, 144), cast(int, cpuid))
	free(cpuid)
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
