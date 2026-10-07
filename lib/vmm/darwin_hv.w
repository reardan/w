# Apple Silicon Hypervisor.framework host adapter. Only import on Darwin.
# One VM per process; create/run/destroy the vCPU on the same host thread.
# SDK: hv_vcpu_exit_t has a 32-bit reason, four padding bytes, three u64s.
import lib.lib

struct dhv_exit:
	int32 reason
	int32 padding
	int syndrome
	int virtual_address
	int physical_address

const int dhv_reg_pc = 31
const int dhv_reg_cpsr = 34
const int dhv_memory_read = 1
const int dhv_memory_write = 2
const int dhv_memory_exec = 4
const int dhv_exit_canceled = 0
const int dhv_exit_exception = 1

c_lib "/System/Library/Frameworks/Hypervisor.framework/Hypervisor"
extern int hv_vm_create_raw(int config) = "hv_vm_create"
extern int hv_vm_destroy_raw() = "hv_vm_destroy"
extern int hv_vm_map_raw(char* address, int ipa, int size, int flags) = "hv_vm_map"
extern int hv_vm_protect_raw(int ipa, int size, int flags) = "hv_vm_protect"
extern int hv_vm_unmap_raw(int ipa, int size) = "hv_vm_unmap"
extern int hv_vcpu_create_raw(int* cpu, dhv_exit** state, int config) = "hv_vcpu_create"
extern int hv_vcpu_destroy_raw(int cpu) = "hv_vcpu_destroy"
extern int hv_vcpu_run_raw(int cpu) = "hv_vcpu_run"
extern int hv_vcpu_set_reg_raw(int cpu, int reg, int value) = "hv_vcpu_set_reg"
extern int hv_vcpu_get_reg_raw(int cpu, int reg, int* value) = "hv_vcpu_get_reg"
extern int hv_vcpu_set_sys_reg_raw(int cpu, int reg, int value) = "hv_vcpu_set_sys_reg"
extern int hv_vcpu_get_sys_reg_raw(int cpu, int reg, int* value) = "hv_vcpu_get_sys_reg"
extern int hv_vcpu_set_vtimer_mask_raw(int cpu, int masked) = "hv_vcpu_set_vtimer_mask"
extern int hv_vcpus_exit_raw(int* cpus, int count) = "hv_vcpus_exit"

c_lib "/usr/lib/libSystem.B.dylib"
extern int dhv_sysctlbyname_raw(char* name, void* old, int* size, int value, int len) = "sysctlbyname"
extern int dhv_getppid_raw() = "getppid"
extern int dhv_getpagesize_raw() = "getpagesize"
extern int dhv_clock_gettime_raw(int clock, int* ts) = "clock_gettime"
extern int dhv_nanosleep_raw(int* ts, int remaining) = "nanosleep"
extern int dhv_pthread_create_raw(int* thread, int attr, int callback, void* argument) = "pthread_create"
extern int dhv_pthread_join_raw(int thread, int result) = "pthread_join"
extern int dhv_mutex_init_raw(void* lock, int attr) = "pthread_mutex_init"
extern int dhv_mutex_lock_raw(void* lock) = "pthread_mutex_lock"
extern int dhv_mutex_unlock_raw(void* lock) = "pthread_mutex_unlock"
extern int dhv_mutex_destroy_raw(void* lock) = "pthread_mutex_destroy"
extern void dhv_icache_invalidate(void* address, int size) = "sys_icache_invalidate"

# C int/hv_return_t only define w0: normalize the upper half of x0.
# Some framework fast paths leave those bits nonzero on successful calls.
int hv_vm_create(int config):
	return hv_vm_create_raw(config) & ((1 << 32) - 1)

int hv_vm_destroy():
	return hv_vm_destroy_raw() & ((1 << 32) - 1)

int hv_vm_map(char* address, int ipa, int size, int flags):
	return hv_vm_map_raw(address, ipa, size, flags) & ((1 << 32) - 1)

int hv_vm_protect(int ipa, int size, int flags):
	return hv_vm_protect_raw(ipa, size, flags) & ((1 << 32) - 1)

int hv_vm_unmap(int ipa, int size):
	return hv_vm_unmap_raw(ipa, size) & ((1 << 32) - 1)

int hv_vcpu_create(int* cpu, dhv_exit** state, int config):
	return hv_vcpu_create_raw(cpu, state, config) & ((1 << 32) - 1)

int hv_vcpu_destroy(int cpu):
	return hv_vcpu_destroy_raw(cpu) & ((1 << 32) - 1)

int hv_vcpu_run(int cpu):
	return hv_vcpu_run_raw(cpu) & ((1 << 32) - 1)

int hv_vcpu_set_reg(int cpu, int reg, int value):
	return hv_vcpu_set_reg_raw(cpu, reg, value) & ((1 << 32) - 1)

int hv_vcpu_get_reg(int cpu, int reg, int* value):
	return hv_vcpu_get_reg_raw(cpu, reg, value) & ((1 << 32) - 1)

int hv_vcpu_set_sys_reg(int cpu, int reg, int value):
	return hv_vcpu_set_sys_reg_raw(cpu, reg, value) & ((1 << 32) - 1)

int hv_vcpu_get_sys_reg(int cpu, int reg, int* value):
	return hv_vcpu_get_sys_reg_raw(cpu, reg, value) & ((1 << 32) - 1)

int hv_vcpu_set_vtimer_mask(int cpu, int masked):
	return hv_vcpu_set_vtimer_mask_raw(cpu, masked) & ((1 << 32) - 1)

int hv_vcpus_exit(int* cpus, int count):
	return hv_vcpus_exit_raw(cpus, count) & ((1 << 32) - 1)

int dhv_sysctlbyname(char* name, void* old, int* size, int value, int len):
	return dhv_sysctlbyname_raw(name, old, size, value, len) & ((1 << 32) - 1)

int dhv_getppid():
	return dhv_getppid_raw() & ((1 << 32) - 1)

int dhv_getpagesize():
	return dhv_getpagesize_raw() & ((1 << 32) - 1)

int dhv_clock_gettime(int clock, int* ts):
	return dhv_clock_gettime_raw(clock, ts) & ((1 << 32) - 1)

int dhv_nanosleep(int* ts, int remaining):
	return dhv_nanosleep_raw(ts, remaining) & ((1 << 32) - 1)

int dhv_pthread_create(int* thread, int attr, int callback, void* argument):
	return dhv_pthread_create_raw(thread, attr, callback, argument) & ((1 << 32) - 1)

int dhv_pthread_join(int thread, int result):
	return dhv_pthread_join_raw(thread, result) & ((1 << 32) - 1)

int dhv_mutex_init(void* lock, int attr):
	return dhv_mutex_init_raw(lock, attr) & ((1 << 32) - 1)

int dhv_mutex_lock(void* lock):
	return dhv_mutex_lock_raw(lock) & ((1 << 32) - 1)

int dhv_mutex_unlock(void* lock):
	return dhv_mutex_unlock_raw(lock) & ((1 << 32) - 1)

int dhv_mutex_destroy(void* lock):
	return dhv_mutex_destroy_raw(lock) & ((1 << 32) - 1)

# Darwin CLOCK_MONOTONIC is 6. The portable raw syscall compatibility
# clock uses gettimeofday on Darwin and cannot enforce VM deadlines.
int dhv_now_ms():
	int[2] ts
	if (dhv_clock_gettime(6, ts) != 0): return -1
	return ts[0] * 1000 + ts[1] / 1000000

int dhv_probe():
	int supported = 0
	int length = 4
	if (dhv_sysctlbyname(c"kern.hv_support", cast(void*, &supported), &length, 0, 0) != 0): return -38
	if (supported == 0): return -38
	int rc = hv_vm_create(0)
	if (rc == 0): return hv_vm_destroy()
	return rc

char* dhv_error_message(int rc):
	# hv_return_t is unsigned 32-bit in the C ABI, whereas W int is 64-bit.
	# Compare its low bits without sign-extending a high-bit hex literal.
	if ((rc & 65535) == 16391): return c"missing-entitlement: sign worker with com.apple.security.hypervisor"
	if (rc == -38): return c"unsupported-host: Apple Silicon Hypervisor.framework required"
	if (rc == 0): return c"available"
	return c"backend-initialization: Hypervisor.framework rejected VM creation"

# A watchdog owns one pthread, one private W stack and one C->W thunk.
# The body never allocates or accesses W thread-local heap state. All shared
# stop/deadline state is protected by the pthread mutex (ARM weak ordering).
# Stop and join before destroying the vCPU. This makes old watchdogs unable
# to cancel a subsequent lease, even when a deadline races natural exit.
int dhv_watchdog_parent_pid

struct dhv_watchdog:
	int stack_top
	int body
	int cpu
	int deadline
	int thread
	void* lock
	int stopped
	int expired
	int canceled
	int thunk
	int stack_base
	int parent_pid

int dhv_watchdog_body(void* argument):
	dhv_watchdog* guard = cast(dhv_watchdog*, argument)
	int[2] delay
	delay[0] = 0
	delay[1] = 1000000
	while (1):
		dhv_mutex_lock(guard.lock)
		if (guard.stopped):
			dhv_mutex_unlock(guard.lock)
			return 0
		int now = dhv_now_ms()
		if (guard.parent_pid > 0 && dhv_getppid() != guard.parent_pid): guard.canceled = 1
		if (now < 0 || now >= guard.deadline || guard.canceled):
			guard.expired = 1
			hv_vcpus_exit(&guard.cpu, 1)
			dhv_mutex_unlock(guard.lock)
			return 0
		dhv_mutex_unlock(guard.lock)
		dhv_nanosleep(delay, 0)
	return 0

# Returns 0 on acquisition failure. timeout_ms is bounded to one day.
# The callback adapter saves all AAPCS64 callee-saved integer/FP registers,
# installs x28 as the private W evaluation stack, then calls body(argument).
# Its pointer/stack slots are the first two fields of dhv_watchdog above.
dhv_watchdog* dhv_watchdog_start(int cpu, int timeout_ms):
	if (timeout_ms < 1 || timeout_ms > 86400000): return cast(dhv_watchdog*, 0)
	int now = dhv_now_ms()
	if (now < 0): return cast(dhv_watchdog*, 0)
	dhv_watchdog* guard = new dhv_watchdog()
	guard.parent_pid = dhv_watchdog_parent_pid
	guard.stopped = 0
	guard.expired = 0
	guard.canceled = 0
	guard.cpu = cpu
	guard.deadline = now + timeout_ms
	guard.body = cast(int, dhv_watchdog_body)
	guard.lock = malloc(64)
	for i in range(64): (cast(char*, guard.lock))[i] = 0
	if (dhv_mutex_init(guard.lock, 0) != 0):
		free(guard.lock)
		free(cast(void*, guard))
		return cast(dhv_watchdog*, 0)
	guard.stack_base = mmap(0, 81920, 3, 34)
	guard.thunk = mmap(0, dhv_getpagesize(), 3, 34)
	if (guard.stack_base < 0 || guard.thunk < 0):
		if (guard.stack_base > 0): munmap(guard.stack_base, 81920)
		if (guard.thunk > 0): munmap(guard.thunk, dhv_getpagesize())
		dhv_mutex_destroy(guard.lock)
		free(guard.lock)
		free(cast(void*, guard))
		return cast(dhv_watchdog*, 0)
	guard.stack_top = guard.stack_base + 81920
	if (mprotect(guard.stack_base, 16384, 0) != 0):
		munmap(guard.stack_base, 81920)
		munmap(guard.thunk, dhv_getpagesize())
		dhv_mutex_destroy(guard.lock)
		free(guard.lock)
		free(cast(void*, guard))
		return cast(dhv_watchdog*, 0)
	# Fixed AAPCS64 bridge (104 bytes), assembled from:
	# stp x29,x30,[sp,#-160]!; stp x19,x20,[sp,#16];
	# stp x21,x22,[sp,#32]; stp x23,x24,[sp,#48];
	# stp x25,x26,[sp,#64]; stp x27,x28,[sp,#80];
	# stp d8,d9,[sp,#96]; stp d10,d11,[sp,#112];
	# stp d12,d13,[sp,#128]; stp d14,d15,[sp,#144];
	# ldr x28,[x0]; ldr x9,[x0,#8]; str x0,[x28,#-8]!;
	# mov x29,#0; blr x9; then restore the pairs in reverse order,
	# ldp x29,x30,[sp],#160; ret. d8..d15 low 64 bits are the
	# callee-saved portion under AAPCS64. x18 remains untouched.
	# W^X: code is writable only during construction, then RX.
	char* bridge = c"\xfd\x7b\xb6\xa9\xf3\x53\x01\xa9\xf5\x5b\x02\xa9\xf7\x63\x03\xa9\xf9\x6b\x04\xa9\xfb\x73\x05\xa9\xe8\x27\x06\x6d\xea\x2f\x07\x6d\xec\x37\x08\x6d\xee\x3f\x09\x6d\x1c\x00\x40\xf9\x09\x04\x40\xf9\x80\x8f\x1f\xf8\x1d\x00\x80\xd2\x20\x01\x3f\xd6\xee\x3f\x49\x6d\xec\x37\x48\x6d\xea\x2f\x47\x6d\xe8\x27\x46\x6d\xfb\x73\x45\xa9\xf9\x6b\x44\xa9\xf7\x63\x43\xa9\xf5\x5b\x42\xa9\xf3\x53\x41\xa9\xfd\x7b\xca\xa8\xc0\x03\x5f\xd6"
	for i in range(104): (cast(char*, guard.thunk))[i] = bridge[i]
	dhv_icache_invalidate(cast(void*, guard.thunk), 104)
	int rc = mprotect(guard.thunk, dhv_getpagesize(), 5)
	if (rc == 0): rc = dhv_pthread_create(&guard.thread, 0, guard.thunk, cast(void*, guard))
	if (rc != 0):
		munmap(guard.stack_base, 81920)
		munmap(guard.thunk, dhv_getpagesize())
		dhv_mutex_destroy(guard.lock)
		free(guard.lock)
		free(cast(void*, guard))
		return cast(dhv_watchdog*, 0)
	return guard

void dhv_watchdog_cancel(dhv_watchdog* guard):
	if (guard == 0): return
	dhv_mutex_lock(guard.lock)
	guard.canceled = 1
	hv_vcpus_exit(&guard.cpu, 1)
	dhv_mutex_unlock(guard.lock)

# Returns 1 if the deadline/cancellation won the race, 0 on natural exit.
# Must be called by the owning thread, and consumes guard exactly once.
int dhv_watchdog_stop(dhv_watchdog* guard):
	if (guard == 0): return 0
	dhv_mutex_lock(guard.lock)
	guard.stopped = 1
	int expired = guard.expired || guard.canceled
	dhv_mutex_unlock(guard.lock)
	dhv_pthread_join(guard.thread, 0)
	munmap(guard.stack_base, 81920)
	munmap(guard.thunk, dhv_getpagesize())
	dhv_mutex_destroy(guard.lock)
	free(guard.lock)
	free(cast(void*, guard))
	return expired
