# wbuild: target=wvm_live_vmcall_fixture dep=wv2
# wbuild: step="bin/wv2 x64 --syscall-abi=vmcall tests/wvm_live_fixture.w -o bin/wvm_live_vmcall_fixture"
# wbuild: target=wvm_live_test tag=tests dep=wv2 dep=wvm_live_fixture dep=wvm_live_thread_fixture dep=wvm_live_vmcall_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_live_test.w -o bin/wvm_live_test"
# wbuild: step="bin/wvm_live_test" timeout=30000
import lib.testing
import lib.vmm.debug
import lib.file
import lib.ci_skip


vm_cell* live_test_cell_image(char* path):
	int fd = open(path, 0, 0)
	asserts(c"live fixture exists", fd >= 0)
	int length = file_size(fd)
	close(fd)
	char* image = file_read_text(path)
	asserts(c"live fixture read", image != 0)
	vm_cell* cell = cell_new()
	asserts(c"live load", cell_elf_load(cell, image, length))
	free(image)
	char*[1] args
	args[0] = c"fixture"
	asserts(c"live stack", cell_stack(cell, 1, &args[0]))
	asserts(c"live seed", cell_deterministic_configure(cell, 321))
	cell.input = c"abc"
	cell.input_length = 3
	return cell


vm_cell* live_test_cell():
	return live_test_cell_image(c"bin/wvm_live_fixture")


int live_test_available():
	int fd = kvm_open_system()
	if (fd < 0):
		test_skip_kvm(c"SKIP: /dev/kvm unavailable (live checkpoint layout gates still ran)")
		return 0
	close(fd)
	return 1


void live_test_pause_at_output(vm_cell* cell):
	int count = 0
	while (cell.output.length == 0):
		count = count + 1
		asserts(c"reach checkpoint within syscall bound", count < 100)
		cell.pause_after = cell.syscall_count + 1
		if (cell.started): asserts(c"resume to syscall boundary", cell_resume(cell, 5000))
		else: asserts(c"start to syscall boundary", cell_run(cell, 5000))
		assert_equal(1, cell.paused)
		assert_equal(0, cell.exited)
	assert_equal(6, cell.output.length)
	assert_strings_equal(c"before", cell.output.data)


void test_live_checkpoint_rejects_nonpaused():
	vm_cell* cell = cell_new()
	asserts(c"reject fresh", cell_live_capture(cell) == 0)
	assert_equal(0, cell_resume(cell, 5000))
	assert_equal(0, cell_debug_start(cell))
	cell_free(cell)
	asserts(c"null restore", cell_live_restore(0) == 0)
	cell_live_free(0)


void test_live_checkpoint_cow_cpu_services_and_lifetime():
	if (live_test_available() == 0): return
	vm_cell* cell = live_test_cell()
	live_test_pause_at_output(cell)
	asserts(c"drain pending IO", cell_pause_sync(cell))
	char[416] fpu
	assert_equal(0, sys_ioctl(cell.machine.cpu_fd, kvm_request(2, 416, 140), cast(int, &fpu[0])))
	assert_equal(77, cast(int, fpu[152])) # guest-established XMM0 state
	cell_live_snapshot* snapshot = cell_live_capture(cell)
	asserts(c"capture live", snapshot != 0)
	assert_equal(6, snapshot.output.length)
	vm_cell* first = cell_live_restore(snapshot)
	vm_cell* second = cell_live_restore(snapshot)
	asserts(c"independent restores", first != 0 && second != 0)
	assert_equal(0, cell_snapshot_reset(first))
	assert_equal(1, first.paused)
	assert_equal(0, sys_ioctl(first.machine.cpu_fd, kvm_request(2, 416, 140), cast(int, &fpu[0])))
	assert_equal(77, cast(int, fpu[152]))
	# A checkpoint of a restore exercises a second layer of materialization.
	cell_live_snapshot* nested = cell_live_capture_layer(first, snapshot)
	asserts(c"checkpoint restored process", nested != 0)
	vm_cell* third = cell_live_restore(nested)
	asserts(c"restore nested", third != 0)
	cell_live_free(nested)
	cell_live_free(snapshot)
	asserts(c"source resumes independently", cell_resume(cell, 5000))
	assert_equal(7, cell.status)
	assert_equal(17, cell.output.length)
	char[17] expected
	mem_copy[char](&expected[0], cell.output.data, 17)
	cell_free(cell)
	asserts(c"first survives owners", cell_resume(first, 5000))
	asserts(c"second survives owners", cell_resume(second, 5000))
	asserts(c"nested survives owners", cell_resume(third, 5000))
	assert_equal(7, first.status)
	assert_equal(7, second.status)
	assert_equal(7, third.status)
	for i in range(17):
		assert_equal(cast(int, expected[i]), cast(int, first.output.data[i]))
		assert_equal(cast(int, expected[i]), cast(int, second.output.data[i]))
		assert_equal(cast(int, expected[i]), cast(int, third.output.data[i]))
	cell_free(first)
	cell_free(second)
	cell_free(third)


void test_cell_debug_instruction_step_and_memory():
	if (live_test_available() == 0): return
	vm_cell* cell = live_test_cell()
	asserts(c"debugger stops before entry", cell_debug_start(cell))
	char[144] registers
	asserts(c"read initial registers", cell_debug_registers(cell, &registers[0]))
	int initial = load_int64(&registers[128])
	assert_equal(cell.entry, initial)
	asserts(c"single step", cell_debug_step(cell, 5000))
	assert_equal(1, cell.paused)
	assert_equal(1, cell.debug_exit)
	assert_equal(0, cell.debug_control)
	asserts(c"read stepped registers", cell_debug_registers(cell, &registers[0]))
	asserts(c"instruction advanced", load_int64(&registers[128]) != initial)
	char[8] bytes
	asserts(c"read guest stack", cell_debug_read(cell, cell.stack, &bytes[0], 8))
	assert_equal(1, load_int64(&bytes[0]))
	assert_equal(0, cell_debug_read(cell, 4096, &bytes[0], 8))
	assert_equal(0, cell_debug_write(cell, cell.entry, c"x", 1))
	asserts(c"write guest stack", cell_debug_write(cell, cell.stack, &bytes[0], 8))
	cell_live_snapshot* snapshot = cell_live_capture(cell)
	asserts(c"capture at instruction stop", snapshot != 0)
	vm_cell* clone = cell_live_restore(snapshot)
	asserts(c"restore instruction stop", clone != 0)
	cell_live_free(snapshot)
	cell_free(cell)
	asserts(c"continue restored instruction state", cell_resume(clone, 5000))
	assert_equal(7, clone.status)
	cell_free(clone)


void test_cell_hardware_breakpoint_continue_and_step():
	if (live_test_available() == 0): return
	vm_cell* cell = live_test_cell()
	asserts(c"hardware debugger start", cell_debug_start(cell))
	asserts(c"install execute breakpoint", cell_debug_breakpoint(cell, 0, cell.entry))
	assert_equal(cell.entry, cell_debug_breakpoint_address(cell, 0))
	assert_equal(0, cell_debug_breakpoint(cell, 4, cell.entry))
	assert_equal(0, cell_debug_breakpoint(cell, 1, cell.stack))
	asserts(c"continue to entry breakpoint", cell_debug_continue(cell, 5000))
	assert_equal(1, cell.paused)
	assert_equal(1, cell.debug_hit)
	assert_equal(cell.entry, load_int64(cell.regs + 128))
	assert_equal(0, cell.instruction_count)
	asserts(c"step resumes breakpoint instruction", cell_debug_step(cell, 5000))
	assert_equal(1, cell.paused)
	assert_equal(1, cell.instruction_count)
	asserts(c"breakpoint instruction advanced", load_int64(cell.regs + 128) != cell.entry)
	asserts(c"delete breakpoint", cell_debug_delete(cell, 0))
	assert_equal(0, cell_debug_breakpoint_address(cell, 0))
	assert_equal(1, cell_debug_thread_tid(cell, 0))
	assert_equal(1, cell_debug_thread_state(cell, 1))
	asserts(c"select main thread", cell_debug_thread_select(cell, 1))
	assert_equal(0, cell_debug_thread_select(cell, 999))
	asserts(c"continue after breakpoint", cell_debug_continue(cell, 5000))
	assert_equal(7, cell.status)
	cell_free(cell)


void test_cell_instruction_budget_and_reset():
	if (live_test_available() == 0): return
	vm_cell* source = live_test_cell()
	source.max_instructions = 64
	cell_snapshot* snapshot = cell_snapshot_create(source)
	asserts(c"instruction-limited template", snapshot != 0)
	vm_cell* cell = cell_snapshot_clone(snapshot)
	cell_snapshot_free(snapshot)
	cell_free(source)
	for iteration in range(2):
		asserts(c"instruction budget terminates", cell_run(cell, 5000))
		assert_equal(125, cell.status)
		assert_equal(64, cell.instruction_count)
		assert_strings_equal(c"guest instruction limit exceeded", cell.error)
		asserts(c"reset instruction accounting", cell_snapshot_reset(cell))
		assert_equal(0, cell.instruction_count)
		assert_equal(64, cell.max_instructions)
	cell_free(cell)


vm_cell* live_thread_test_cell(int timeout):
	int fd = open(c"bin/wvm_live_thread_fixture", 0, 0)
	asserts(c"thread checkpoint fixture", fd >= 0)
	int length = file_size(fd)
	close(fd)
	char* image = file_read_text(c"bin/wvm_live_thread_fixture")
	vm_cell* cell = cell_new()
	asserts(c"thread checkpoint load", cell_elf_load(cell, image, length))
	free(image)
	char*[2] args
	args[0] = c"fixture"
	args[1] = c"timeout"
	int argc = 1
	if (timeout): argc = 2
	asserts(c"thread checkpoint stack", cell_stack(cell, argc, &args[0]))
	cell.max_threads = 4
	return cell


void test_live_multithread_futex_tls_and_slot_reuse():
	if (live_test_available() == 0): return
	vm_cell* cell = live_thread_test_cell(0)
	int attempts = 0
	while (cell.output.length == 0):
		attempts = attempts + 1
		asserts(c"threads reach bounded checkpoint", attempts < 200)
		cell.pause_after = cell.syscall_count + 1
		if (cell.started): asserts(c"pause running thread", cell_resume(cell, 5000))
		else: asserts(c"pause first thread", cell_run(cell, 5000))
		assert_equal(1, cell.paused)
	assert_strings_equal(c"threads", cell.output.data)
	cell_live_snapshot* snapshot = cell_live_capture(cell)
	asserts(c"capture all guest CPUs", snapshot != 0)
	assert_equal(4, snapshot.capacity)
	asserts(c"second CPU captured", snapshot.cpus[1] != 0)
	asserts(c"third CPU captured", snapshot.cpus[2] != 0)
	assert_equal(2, snapshot.threads[1].state)
	assert_equal(2, snapshot.threads[2].state)
	asserts(c"relative futex timeout", snapshot.threads[1].wake_ms > 0 && snapshot.threads[1].wake_ms <= 1000)
	vm_cell* clone = cell_live_restore(snapshot)
	asserts(c"restore all guest CPUs", clone != 0)
	cell_live_snapshot* layer = cell_live_capture_layer(clone, snapshot)
	asserts(c"layered multithread checkpoint", layer != 0)
	vm_cell* second = cell_live_restore(layer)
	asserts(c"layered multithread restore", second != 0)
	cell_live_free(layer)
	cell_live_free(snapshot)
	asserts(c"original threads resume", cell_resume(cell, 5000))
	assert_equal(9, cell.status)
	assert_strings_equal(c"threadsdone\n", cell.output.data)
	cell_free(cell)
	asserts(c"restored threads resume", cell_resume(clone, 5000))
	assert_equal(9, clone.status)
	assert_strings_equal(c"threadsdone\n", clone.output.data)
	cell_free(clone)
	asserts(c"layered threads resume", cell_resume(second, 5000))
	assert_equal(9, second.status)
	assert_strings_equal(c"threadsdone\n", second.output.data)
	cell_free(second)


void test_live_restore_parked_futex_timeout():
	if (live_test_available() == 0): return
	vm_cell* cell = live_thread_test_cell(1)
	int attempts = 0
	while (1):
		attempts = attempts + 1
		asserts(c"timed wait reaches checkpoint", attempts < 100)
		cell.pause_after = cell.syscall_count + 1
		if (cell.started): asserts(c"pause timeout thread", cell_resume(cell, 5000))
		else: asserts(c"start timeout thread", cell_run(cell, 5000))
		assert_equal(1, cell.paused)
		cell_threads* threads = cast(cell_threads*, cell.thread_state)
		if (threads.slots[threads.current].state == 2): break
	cell_live_snapshot* snapshot = cell_live_capture(cell)
	asserts(c"checkpoint parked thread", snapshot != 0)
	vm_cell* clone = cell_live_restore(snapshot)
	asserts(c"restore parked thread", clone != 0)
	cell_live_free(snapshot)
	cell_free(cell)
	asserts(c"restored deadline expires", cell_resume(clone, 5000))
	assert_equal(11, clone.status)
	assert_strings_equal(c"timeout\n", clone.output.data)
	cell_free(clone)


void test_live_vmcall_checkpoint_preserves_modified_unused_site():
	if (live_test_available() == 0): return
	vm_cell* cell = live_test_cell_image(c"bin/wvm_live_vmcall_fixture")
	live_test_pause_at_output(cell)
	asserts(c"compiler emitted clone site", cell.hypercall_count > 3)
	int site = cell_hypercall_site_get(&cell.hypercall_sites, 3)
	assert_equal(56, load_int32(cell.ram + site - 4)) # thread_create's clone number
	# Model a guest changing an unused runtime stub after startup. Live
	# restore must preserve it, rather than rerun fresh-image validation.
	cell.ram[site] = 90
	cell_live_snapshot* snapshot = cell_live_capture(cell)
	asserts(c"capture modified vmcall code", snapshot != 0)
	vm_cell* restored = cell_live_restore(snapshot)
	asserts(c"restore modified vmcall code", restored != 0)
	assert_equal(90, cast(int, restored.ram[site]))
	cell_live_free(snapshot)
	asserts(c"modified source resumes", cell_resume(cell, 5000))
	asserts(c"modified restore resumes", cell_resume(restored, 5000))
	assert_equal(7, cell.status)
	assert_equal(7, restored.status)
	assert_equal(cell.output.length, restored.output.length)
	for i in range(cell.output.length): assert_equal(cast(int, cell.output.data[i]), cast(int, restored.output.data[i]))
	cell_free(restored)
	cell_free(cell)
