# wbuild: binary=wvm_net_fixture arch=x64
import lib.net
import lib.assert
import lib.str
import lib.thread

int net_wait_fd
int net_wait_started
int net_wait_finished
int net_wait_result


void net_wait_worker(void* argument):
	char[1] buffer
	net_wait_started = 1
	net_wait_result = read(net_wait_fd, &buffer[0], 1)
	net_wait_finished = 1


int main(int argc, int argv):
	if (argc != 3): return 2
	char** args = cast(char**, argv)
	int port = atoi(args[1])
	if (strcmp(args[2], c"denied") == 0):
		assert_equal(-13, socket_tcp_ipv4())
		return 0
	int fd = socket_tcp_ipv4()
	asserts(c"virtual socket descriptor", fd >= 64 && fd < 128)
	assert_equal(-13, socket_unix_stream())
	assert_equal(-13, socket_udp_ipv4())
	assert_equal(-13, socket_bind_ipv4(fd, 0, port))
	assert_equal(-13, socket_connect_ipv4(fd, 2130706434, port))
	assert_equal(-14, syscall(42, fd, 4096, 16))
	assert_equal(0, socket_connect_ipv4(fd, 2130706433, port))
	char[16] buffer
	if (strcmp(args[2], c"reuse") == 0):
		net_wait_fd = fd
		wthread* worker = thread_spawn(net_wait_worker, 0)
		asserts(c"spawn socket waiter", worker != 0)
		while (net_wait_started == 0): syscall(24, 0, 0, 0)
		# Park the parent too, ensuring the worker reaches its empty read.
		assert_equal(0, sys_poll(0, 0, 20))
		assert_equal(0, net_wait_finished)
		assert_equal(0, close(fd))
		int replacement = socket_tcp_ipv4()
		assert_equal(fd, replacement)
		assert_equal(0, socket_connect_ipv4(replacement, 2130706433, port))
		assert_equal(0, thread_join(worker))
		assert_equal(-9, net_wait_result)
		assert_equal(1, read(replacement, &buffer[0], 1))
		assert_equal(122, buffer[0])
		assert_equal(1, write(replacement, c"y", 1))
		assert_equal(0, close(replacement))
		println(c"socket close cancellation OK")
		return 0
	if (strcmp(args[2], c"timeout") == 0):
		assert_equal(1, write(fd, c"x", 1))
		return read(fd, &buffer[0], 1)
	assert_equal(-14, read(fd, cast(char*, 4096), 1))
	assert_equal(-14, write(fd, cast(char*, 4096), 1))
	assert_equal(-22, sys_sendto(fd, c"x", 1, 0, cast(int, &buffer[0]), 16))
	assert_equal(0, socket_set_nonblocking(fd))
	assert_equal(-11, read(fd, &buffer[0], 1))
	assert_equal(0, socket_set_blocking(fd))
	assert_equal(0, poll_single(fd, poll_in, 5))
	assert_equal(4, write(fd, c"ping", 4))
	asserts(c"socket ready", poll_single(fd, poll_in, 2000) > 0)
	assert_equal(4, read(fd, &buffer[0], 4))
	assert_equal(103, buffer[3])
	assert_equal(0, close(fd))
	assert_equal(-9, close(fd))
	assert_equal(-9, write(fd, c"x", 1))
	println(c"cell TCP OK")
	return 0
