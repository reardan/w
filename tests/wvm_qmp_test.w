# wbuild: target=wvm_qmp_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 tests/wvm_qmp_test.w -o bin/wvm_qmp_test"
# wbuild: step="bin/wvm_qmp_test" timeout=10000
import lib.testing
import lib.vmm.qmp
import lib.memfd


void test_qmp_events_errors_and_descriptor_transfer():
	char[8] sockets
	assert_equal(0, syscall7(53, 1, 1, 0, cast(int, &sockets[0]), 0, 0))
	int client = load_int32(&sockets[0])
	int server = load_int32(&sockets[4])
	int image = memfd_create(c"qmp-test", MFD_CLOEXEC)
	asserts(c"create migration descriptor", image >= 0)
	assert_equal(7, write(image, c"payload", 7))
	assert_equal(0, seek(image, 0, 0))
	int pid = fork()
	if (pid == 0):
		close(client)
		close(image) # only SCM_RIGHTS can give this child access again
		socket_set_nonblocking(server)
		int deadline = process_monotonic_ms() + 3000
		char[56] message
		char[16] iov
		char[24] control
		char first
		mem_fill[char](&message[0], 0, 56)
		mem_fill[char](&control[0], 0, 24)
		save_int64(&iov[0], cast(int, &first))
		save_int64(&iov[8], 1)
		save_int64(&message[16], cast(int, &iov[0]))
		save_int64(&message[24], 1)
		save_int64(&message[32], cast(int, &control[0]))
		save_int64(&message[40], 24)
		poll_single(server, poll_in, 3000)
		if (syscall(47, server, cast(int, &message[0]), 0) != 1 || first != '{'): exit(1)
		if (load_int32(&control[8]) != 1 || load_int32(&control[12]) != 1): exit(2)
		int received = load_int32(&control[16])
		char[8] data
		if (read(received, &data[0], 7) != 7): exit(3)
		data[7] = 0
		if (strcmp(&data[0], c"payload") != 0): exit(4)
		close(received)
		# Drain the remainder of the command after the SCM_RIGHTS byte.
		char ch = 0
		while (ch != 10):
			if (box_channel_io(server, &ch, 1, 0, 1, deadline) == 0): exit(5)
		char* reply = c"{\"event\":\"STOP\"}\r\n{\"return\":{},\"id\":1}\r\n"
		if (box_channel_io(server, reply, strlen(reply), 1, 1, deadline) == 0): exit(6)
		json_value* request = box_qmp_read(server, deadline)
		if (request == 0): exit(7)
		json_free(request)
		reply = c"{\"error\":{\"class\":\"GenericError\"},\"id\":1}\n"
		if (box_channel_io(server, reply, strlen(reply), 1, 1, deadline) == 0): exit(8)
		close(server)
		exit(0)
	asserts(c"fork QMP fixture", pid > 0)
	close(server)
	socket_set_nonblocking(client)
	json_value* args = json_object()
	json_object_set(args, c"fdname", json_string(c"wvm-state"))
	json_value* result = box_qmp_call(client, c"getfd", args, image, process_monotonic_ms() + 3000)
	asserts(c"skip event and accept descriptor reply", result != 0)
	json_free(result)
	json_free(args)
	assert_equal(0, box_qmp_simple(client, c"stop", process_monotonic_ms() + 3000))
	close(client)
	close(image)
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)


void test_qmp_deadline():
	char[8] sockets
	assert_equal(0, syscall7(53, 1, 1, 0, cast(int, &sockets[0]), 0, 0))
	int client = load_int32(&sockets[0])
	int server = load_int32(&sockets[4])
	socket_set_nonblocking(client)
	asserts(c"silent peer times out", box_qmp_read(client, process_monotonic_ms() + 10) == 0)
	close(server)
	assert_equal(0, box_qmp_simple(client, c"stop", process_monotonic_ms() + 10))
	close(client)
