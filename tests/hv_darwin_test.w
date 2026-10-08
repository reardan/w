# wbuild: arch_only=arm64_darwin
# Build-only on Linux. tools/mac/run_vm_tests.sh signs and executes this
# mandatory native gate; the unentitled copy must return status 77.
import lib.vmm.darwin_hv

int hv_test_check(int result, char* operation):
	if (result == 0): return 1
	print_string(operation, itoa(result))
	return 0

# modes: 0 hello; 1 writable; 2 readonly; 3 NX; 4 unmapped;
# 5 CPU-only deadline; 6 explicit cancellation before run.
int hv_test_case(int mode):
	if (!hv_test_check(hv_vm_create(0), c"vm create")): return 1
	int size = dhv_getpagesize()
	int address = mmap(0, size * 2, 3, 34)
	if (address < 0):
		hv_vm_destroy()
		return 1
	char* ram = cast(char*, address)
	# mov x0,#87; hvc #0
	save_int32(ram, cast(int, 0xd2800ae0))
	save_int32(ram + 4, cast(int, 0xd4000002))
	if (mode == 1 || mode == 2 || mode == 4): save_int32(ram, cast(int, 0xf9000020))
	if (mode == 5 || mode == 6): save_int32(ram, 0x14000000)
	int ok = hv_test_check(hv_vm_map(ram, 1048576, size, 5), c"map code")
	ok = ok && hv_test_check(hv_vm_map(ram + size, 1048576 + size, size, 3), c"map data")
	if (mode == 2): ok = ok && hv_test_check(hv_vm_protect(1048576 + size, size, 1), c"readonly")
	if (mode == 3): ok = ok && hv_test_check(hv_vm_protect(1048576, size, 1), c"nx")
	if (mode == 4): ok = ok && hv_test_check(hv_vm_unmap(1048576 + size, size), c"unmapped")
	int cpu = 0
	dhv_exit* state = 0
	int invalid_map = hv_vm_map(ram, 1048577, size, 5)
	ok = ok && invalid_map != 0
	int created = hv_vcpu_create(&cpu, &state, 0) == 0
	ok = ok && created
	if (created):
		ok = ok && hv_test_check(hv_vcpu_set_reg(cpu, dhv_reg_pc, 1048576), c"set pc")
		ok = ok && hv_test_check(hv_vcpu_set_reg(cpu, dhv_reg_cpsr, 0x3c5), c"set cpsr")
		ok = ok && hv_test_check(hv_vcpu_set_reg(cpu, 0, 42), c"set x0")
		ok = ok && hv_test_check(hv_vcpu_set_reg(cpu, 1, 1048576 + size), c"set x1")
		ok = ok && hv_test_check(hv_vcpu_set_vtimer_mask(cpu, 1), c"mask timer")
		int system_control = 0
		ok = ok && hv_test_check(hv_vcpu_get_sys_reg(cpu, 0xc080, &system_control), c"read SCTLR_EL1")
		ok = ok && hv_test_check(hv_vcpu_set_sys_reg(cpu, 0xc080, system_control), c"write SCTLR_EL1")
		int timeout = 1000
		if (mode == 5 || mode == 6): timeout = 30
		dhv_watchdog* guard = dhv_watchdog_start(cpu, timeout)
		ok = ok && (guard != 0)
		if (mode == 6): dhv_watchdog_cancel(guard)
		int before = dhv_now_ms()
		if (ok): ok = hv_test_check(hv_vcpu_run(cpu), c"run")
		int expired = dhv_watchdog_stop(guard)
		int elapsed = dhv_now_ms() - before
		int x0 = 0
		ok = ok && hv_test_check(hv_vcpu_get_reg(cpu, 0, &x0), c"get x0")
		int ec = state.syndrome >> 26
		if (mode == 5 || mode == 6):
			ok = ok && expired && (state.reason == dhv_exit_canceled) && elapsed < 2000
		else:
			ok = ok && !expired && (state.reason == dhv_exit_exception)
			if (mode == 0): ok = ok && ec == 0x16 && x0 == 87
			if (mode == 1): ok = ok && ec == 0x16 && load_int(ram + size) == 42
			if (mode == 2 || mode == 4): ok = ok && (ec == 0x24 || ec == 0x25) && load_int(ram + size) == 0
			if (mode == 3): ok = ok && (ec == 0x20 || ec == 0x21)
		if (!ok):
			print_string(c"mode ", itoa(mode))
			print_string(c"reason ", itoa(cast(int, state.reason)))
			print_string(c"EC ", itoa(ec))
			print_string(c"expired ", itoa(expired))
		ok = hv_test_check(hv_vcpu_destroy(cpu), c"vcpu destroy") && ok
	hv_vm_unmap(1048576, size)
	if (mode != 4): hv_vm_unmap(1048576 + size, size)
	ok = hv_test_check(hv_vm_destroy(), c"vm destroy") && ok
	munmap(address, size * 2)
	if (!ok): return 1
	return 0

int main(int argc, int argv):
	int rc = dhv_probe()
	if (rc != 0):
		println2(dhv_error_message(rc))
		return 77
	if (sizeof(dhv_exit) != 32): return 1
	for iteration in range(3):
		for mode in range(7):
			if (hv_test_case(mode) != 0): return 1
	println(c"Hypervisor native: 21 hello/permissions/deadline/cancel/recreate cases passed")
	return 0
