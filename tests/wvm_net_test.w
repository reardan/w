# wbuild: target=wvm_net_test tag=tests dep=wv2 dep=wvm dep=wvm_net_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_net_test.w -o bin/wvm_net_test"
# wbuild: step="bin/wvm_net_test" timeout=20000
import lib.testing
import lib.vmm.cell
import lib.vmm.network
import lib.file
import lib.str
import lib.process
import lib.ci_skip

int wvm_net_call(vm_cell* cell, int nr, int a, int b, int c):
	save_int64(cell.regs, nr)
	save_int64(cell.regs + 40, a)
	save_int64(cell.regs + 32, b)
	save_int64(cell.regs + 24, c)
	return cell_net_syscall(cell)


void test_wvm_net_boundary():
	vm_cell* cell = cell_new()
	assert_equal(-13, cell_net_socket(cell, 2, 1, 0))
	assert_equal(0, cell_net_allow(cell, c"127.0.0.1x", 80))
	assert_equal(0, cell_net_allow(cell, c"256.0.0.1", 80))
	assert_equal(0, cell_net_allow(cell, c"127.0.0.1", 65536))
	assert_equal(1, cell_net_allow(cell, c"127.0.0.1", 80))
	assert_equal(1, cell_net_allow(cell, c"192.168.255.254", 443))
	int high = 254
	assert_equal((high << 24) | 16754880, cell_net_ipv4(c"192.168.255.254"))
	assert_equal(-13, cell_net_socket(cell, 1, 1, 0))
	assert_equal(-13, cell_net_socket(cell, 2, 2, 0))
	assert_equal(-13, cell_net_socket(cell, 2, 3, 0))
	int fd = cell_net_socket(cell, 2, 2049, 0)
	assert_equal(64, fd)
	assert_equal(-4096, wvm_net_call(cell, 9, 100000, 4096, 3))
	assert_equal(-14, cell_net_connect(cell, fd, 4096, 16))
	assert_equal(-14, cell_net_io(cell, fd, 4096, 1, 0, 0))
	assert_equal(-22, cell_net_io(cell, fd, 4096, -1, 0, 0))
	assert_equal(-22, cell_net_poll(cell, 4096, 129, 0))
	assert_equal(-14, cell_net_poll(cell, 4096, 1, 0))
	assert_equal(-13, wvm_net_call(cell, 49, fd, 4096, 16))
	assert_equal(2050, wvm_net_call(cell, 72, fd, 3, 0))
	assert_equal(0, wvm_net_call(cell, 72, fd, 4, 0))
	assert_equal(2, wvm_net_call(cell, 72, fd, 3, 0))
	cell_map(cell, CELL_USER_MIN, 4096, 3)
	char* pollbuf = cell.ram + CELL_USER_MIN
	save_int32(pollbuf, 1)
	save_int16(pollbuf + 4, 4)
	assert_equal(1, cell_net_poll(cell, CELL_USER_MIN, 1, 0))
	assert_equal(4, load_int16(pollbuf + 6))
	save_int32(pollbuf, 63)
	assert_equal(1, cell_net_poll(cell, CELL_USER_MIN, 1, 0))
	assert_equal(32, load_int16(pollbuf + 6))
	for i in range(63): assert_equal(65 + i, cell_net_socket(cell, 2, 1, 0))
	assert_equal(-24, cell_net_socket(cell, 2, 1, 0))
	int host_fd = cell_net_host_fd(cell, fd)
	asserts(c"host socket remains nonblocking", sys_fcntl(host_fd, 3, 0) & 2048)
	cell_net_free(cell)
	assert_equal(-9, sys_fcntl(host_fd, 3, 0))
	cell_net_free(cell)
	cell_free(cell)


vm_cell* wvm_net_load(int port, char* mode):
	int fd = open(c"bin/wvm_net_fixture", 0, 0)
	asserts(c"open net guest", fd >= 0)
	int length = file_size(fd)
	close(fd)
	char* image = file_read_text(c"bin/wvm_net_fixture")
	vm_cell* cell = cell_new()
	asserts(c"net guest loaded", cell_elf_load(cell, image, length))
	free(image)
	char** args = strv_new(3)
	args[0] = c"network"
	args[1] = itoa(port)
	args[2] = mode
	asserts(c"net guest stack", cell_stack(cell, 3, args))
	free(args[1])
	free(cast(void*, args))
	return cell


process_result* wvm_net_cli(char* endpoint, char* port, char* mode):
	char** args = strv_new(9)
	args[0] = c"bin/wvm"
	args[1] = c"run"
	args[2] = c"--net-allow"
	args[3] = endpoint
	args[4] = c"--net-allow"
	args[5] = c"127.0.0.1:1"
	args[6] = c"bin/wvm_net_fixture"
	args[7] = port
	args[8] = mode
	process_result* result = process_run(args[0], args, 0, 0, 10000)
	free(cast(void*, args))
	asserts(c"CLI process result", result != 0)
	return result


void test_wvm_net_cli_invalid():
	list[char*] endpoints = new list[char*]
	endpoints.push(c"127.0.0.256:80")
	endpoints.push(c"127.0.0.1x:80")
	endpoints.push(c"127.0.0.1")
	endpoints.push(c":80")
	endpoints.push(c"127.0.0.1:")
	endpoints.push(c"127.0.0.1:0")
	endpoints.push(c"127.0.0.1:65536")
	endpoints.push(c"127.0.0.1:80x")
	for char* endpoint in endpoints:
		process_result* result = wvm_net_cli(endpoint, c"1", c"denied")
		assert_equal(125, result.status)
		asserts(c"CLI diagnoses invalid endpoint", contains(result.stderr_text, c"invalid --net-allow endpoint"))
		process_result_free(result)
	__w_list_free(cast(__w_list*, endpoints))


void test_wvm_net_execution():
	int kvm = kvm_open_system()
	if (kvm < 0):
		test_skip(c"SKIP: /dev/kvm unavailable (network boundary tests still ran)")
		return
	close(kvm)
	vm_cell* denied = wvm_net_load(1, c"denied")
	asserts(c"disabled network guest ran", cell_run(denied, 2000))
	assert_equal(0, denied.status)
	cell_free(denied)
	int listener = socket_tcp_ipv4()
	asserts(c"fixture listener", listener >= 0)
	assert_equal(0, socket_bind_ipv4(listener, 2130706433, 0))
	assert_equal(0, socket_listen(listener, 1))
	sockaddr_in bound
	assert_equal(0, socket_getsockname_ipv4(listener, &bound))
	int port = net_htons(bound.port)
	int pid = fork()
	asserts(c"fixture process", pid >= 0)
	if (pid == 0):
		if (poll_single(listener, poll_in, 5000) <= 0): exit(2)
		int client = socket_accept_connection(listener)
		if (client < 0): exit(3)
		if (poll_single(client, poll_in, 5000) <= 0): exit(4)
		char[4] message
		if (read(client, &message[0], 4) != 4): exit(5)
		if (message[0] != 112 || message[3] != 103): exit(6)
		char[16] delay
		save_int64(&delay[0], 0)
		save_int64(&delay[8], 50000000)
		syscall(35, cast(int, &delay[0]), 0, 0)
		if (write(client, c"pong", 4) != 4): exit(7)
		close(client)
		close(listener)
		exit(0)
	close(listener)
	char* port_text = itoa(port)
	char* endpoint = strjoin(c"127.0.0.1:", port_text)
	process_result* result = wvm_net_cli(endpoint, port_text, c"echo")
	assert_equal(0, result.status)
	assert_strings_equal(c"cell TCP OK\n", result.stdout_text)
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	free(endpoint)
	free(port_text)
	int status = 0
	assert_equal(pid, syscall7(61, pid, cast(int, &status), 0, 0, 0, 0))
	assert_equal(0, status)


void test_wvm_net_wait_watchdog():
	int kvm = kvm_open_system()
	if (kvm < 0): return
	close(kvm)
	int listener = socket_tcp_ipv4()
	asserts(c"timeout fixture listener", listener >= 0)
	assert_equal(0, socket_bind_ipv4(listener, 2130706433, 0))
	assert_equal(0, socket_listen(listener, 1))
	sockaddr_in bound
	assert_equal(0, socket_getsockname_ipv4(listener, &bound))
	int port = net_htons(bound.port)
	int pid = fork()
	asserts(c"timeout fixture process", pid >= 0)
	if (pid == 0):
		if (poll_single(listener, poll_in, 5000) <= 0): exit(2)
		int client = socket_accept_connection(listener)
		if (client < 0): exit(3)
		if (poll_single(client, poll_in, 5000) <= 0): exit(4)
		char[1] message
		if (read(client, &message[0], 1) != 1): exit(5)
		char[16] delay
		save_int64(&delay[0], 0)
		save_int64(&delay[8], 500000000)
		syscall(35, cast(int, &delay[0]), 0, 0)
		close(client)
		close(listener)
		exit(0)
	close(listener)
	vm_cell* cell = wvm_net_load(port, c"timeout")
	assert_equal(1, cell_net_allow(cell, c"127.0.0.1", port))
	asserts(c"watchdog interrupts waiting guest", cell_run(cell, 100))
	assert_equal(124, cell.status)
	assert_strings_equal(c"guest timed out", cell.error)
	cell_free(cell)
	int status = 0
	assert_equal(pid, syscall7(61, pid, cast(int, &status), 0, 0, 0, 0))
	assert_equal(0, status)


void test_wvm_net_close_cancels_waiter():
	int kvm = kvm_open_system()
	if (kvm < 0): return
	close(kvm)
	int listener = socket_tcp_ipv4()
	asserts(c"reuse fixture listener", listener >= 0)
	assert_equal(0, socket_bind_ipv4(listener, 2130706433, 0))
	assert_equal(0, socket_listen(listener, 2))
	sockaddr_in bound
	assert_equal(0, socket_getsockname_ipv4(listener, &bound))
	int port = net_htons(bound.port)
	int pid = fork()
	asserts(c"reuse fixture process", pid >= 0)
	if (pid == 0):
		if (poll_single(listener, poll_in, 5000) <= 0): exit(2)
		int first = socket_accept_connection(listener)
		if (first < 0): exit(3)
		# The original stream never supplies data: its guest reader parks.
		if (poll_single(first, poll_in, 5000) <= 0): exit(4)
		char[1] buffer
		if (read(first, &buffer[0], 1) != 0): exit(5)
		close(first)
		if (poll_single(listener, poll_in, 5000) <= 0): exit(6)
		int replacement = socket_accept_connection(listener)
		if (replacement < 0): exit(7)
		if (write(replacement, c"z", 1) != 1): exit(8)
		if (poll_single(replacement, poll_in, 5000) <= 0): exit(9)
		if (read(replacement, &buffer[0], 1) != 1 || buffer[0] != 121): exit(10)
		close(replacement)
		close(listener)
		exit(0)
	close(listener)
	vm_cell* cell = wvm_net_load(port, c"reuse")
	assert_equal(1, cell_net_allow(cell, c"127.0.0.1", port))
	asserts(c"socket close guest executed", cell_run(cell, 5000))
	assert_equal(0, cell.status)
	assert_strings_equal(c"socket close cancellation OK\n", cell.output.data)
	cell_free(cell)
	int status = 0
	assert_equal(pid, syscall7(61, pid, cast(int, &status), 0, 0, 0, 0))
	assert_equal(0, status)
