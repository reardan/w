# wbuild: arch_only=x64 timeout=10000
import lib.testing
import lib.kvm
import lib.ci_skip


void test_kvm_layout():
	assert_equal(144, KVM_REGS_SIZE)
	assert_equal(312, KVM_SREGS_SIZE)
	assert_equal(44672, kvm_request(0, 0, 128))
	assert_equal(1075883590, kvm_request(1, 32, 70))
	char[32] record
	kvm_memory_record(&record[0], 3, 4096, cast(char*, 8192), 12288)
	assert_equal(3, load_int32(&record[0]))
	assert_equal(0, load_int32(&record[4]))
	assert_equal(4096, load_int64(&record[8]))
	assert_equal(12288, load_int64(&record[16]))
	assert_equal(8192, load_int64(&record[24]))


void test_kvm_port_exit():
	# Only an unavailable device is a skip; failures after open are bugs.
	int probe = kvm_open_system()
	if (probe < 0):
		test_skip_kvm(c"SKIP: /dev/kvm unavailable")
		return
	close(probe)
	kvm_machine vm
	asserts(c"create KVM VM", kvm_create(&vm))
	int addr = mmap(0, 4096, 3, MAP_PRIVATE | MAP_ANONYMOUS)
	asserts(c"guest RAM", addr > 0)
	char* ram = cast(char*, addr)
	# Real mode: mov al,'W'; out 0xe9,al; hlt.
	mem_copy[char](ram, c"\xb0\x57\xe6\xe9\xf4", 5)
	assert_equal(0, kvm_set_memory(&vm, 0, 0, ram, 4096))
	char[312] sregs
	assert_equal(0, kvm_get_sregs(&vm, &sregs[0]))
	save_int64(&sregs[0], 0) # cs.base
	save_int16(&sregs[12], 0) # cs.selector
	assert_equal(0, kvm_set_sregs(&vm, &sregs[0]))
	char[144] regs
	mem_fill[char](&regs[0], 0, KVM_REGS_SIZE)
	save_int64(&regs[136], 2)
	assert_equal(0, kvm_set_regs(&vm, &regs[0]))
	assert_equal(0, kvm_run(&vm))
	assert_equal(KVM_EXIT_IO, load_int32(vm.run + 8))
	assert_equal(1, vm.run[32])
	assert_equal(1, vm.run[33])
	assert_equal(233, load_int16(vm.run + 34))
	assert_equal(1, load_int32(vm.run + 36))
	int offset = load_int64(vm.run + 40)
	asserts(c"IO data inside run mapping", offset >= 0 && offset < vm.run_size)
	assert_equal(87, vm.run[offset])
	assert_equal(0, kvm_run(&vm))
	assert_equal(KVM_EXIT_HLT, load_int32(vm.run + 8))
	kvm_destroy(&vm)
	assert_equal(0, munmap(addr, 4096))
