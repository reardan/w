# wbuild: binary=wvm_darwin_recovery arch=x64 tag=tests
# Native failure injection: real signed workers, bounded transports and FD isolation.
import tools.mac.vm_harness

char* vr_worker
char* vr_daemon
char* vr_guest
char* vr_sentinel

struct vr_harness:
	char* path
	char* template_id
	hm_sample* daemon

int vr_alive(int pid, int zombies = 1):
	process_result* result = ht_run(ht_argv(c"ps", c"-p", itoa(pid), c"-o", c"stat="), 0, 0, 5000)
	if (result.status != 0): return 0
	return zombies || strip(result.stdout_text)[0] != 'Z'

void vr_wait_gone(int pid, int zombies = 1, int timeout = 5000):
	int deadline = process_monotonic_ms() + timeout
	while (vr_alive(pid, zombies)):
		ht_require(process_monotonic_ms() < deadline, c"worker survived failure injection")
		process_sleep_ms(20)

vr_harness* vr_start(char* work, char* name, int inherited = -1):
	vr_harness* h = new vr_harness
	h.path = path_join(work, strjoin(name, c".sock"))
	h.daemon = vm_start(vr_daemon, vr_worker, h.path, 1, 2, inherited)
	h.template_id = ht_text(vm_ok(h.path, c"template_create", vm_image(vr_guest)), c"template")
	return h

char* vr_spawn(vr_harness* h, int* worker):
	char* session = ht_text(vm_ok(h.path, c"vm_spawn", vm_template(h.template_id)), c"session")
	vm_state(h.path, session)
	list[char*] children = split(ht_checked(ht_argv(c"pgrep", c"-P", itoa(h.daemon.child.pid))).stdout_text)
	ht_require(children.length == 1, c"expected exactly one worker")
	*worker = atoi(children[0])
	return session

void vr_hello(vr_harness* h, char* session):
	json_value* result = vm_execute(h.path, session, c"hello", 7, c"hello from an ARM64 cell\n")
	ht_require(strcmp(ht_text(result, c"stdout_hex"), hex_encode(c"hello from an ARM64 cell\n", strlen(c"hello from an ARM64 cell\n"))) == 0, c"hello stdout was not exact")

void vr_close(vr_harness* h):
	vm_ok(h.path, c"stop")
	hm_finish(h.daemon, 5000)
	ht_require(h.daemon.status == 0 && !h.daemon.timed_out, c"daemon failed normal shutdown")

void vr_malformed(vr_harness* h):
	list[char*] samples = ht_argv(c"Content-Length: 999999999999999999999999\r\n\r\n", c"Content-Length: -1\r\n\r\n", ht_repeat('X', 128), c"Content-Length: 2\r\n\r\n{]", c"Content-Length: 8\r\n\r\n\"\\u0000\"")
	for char* sample in samples:
		int fd = vm_connect(h.path, 2000)
		vm_send(fd, sample, strlen(sample))
		char[64] buffer
		ht_require(socket_recv(fd, &buffer[0], 64, 0) == 0, c"malformed channel not closed")
		close(fd)
		ht_require(ht_number(vm_ok(h.path, c"stats"), c"active") == 0, c"malformed input poisoned daemon")
	int fd = vm_connect(h.path)
	char* partial = c"Content-Length: 8192\r\n\r\n{"
	vm_send(fd, partial, strlen(partial))
	close(fd)
	ht_require(ht_number(vm_ok(h.path, c"stats"), c"active") == 0, c"partial disconnect poisoned daemon")
	println(c"PASS bounded malformed/truncated channel recovery")

void vr_predict_old_output():
	char* path = strjoin(c"bin/wvm-darwin-source-", itoa(getpid()))
	if (symlink(vr_sentinel, path) != 0): exit(126)

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"wvm_darwin_recovery")
	for char* name in ht_command(c"--worker --daemon --guest"): argparse_arg_required(argparse_add_option(parser, name, c"PATH", c"native artifact"))
	argparse_add_option(parser, c"--compiler", c"PATH", c"native compiler")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	vm_native()
	vr_worker = ht_resolve(argparse_get(args, c"worker"))
	vr_daemon = ht_resolve(argparse_get(args, c"daemon"))
	vr_guest = ht_resolve(argparse_get(args, c"guest"))
	char* work = ht_temp()
	char* fifo = path_join(work, c"image.fifo")
	ht_checked(ht_argv(c"mkfifo", fifo))
	process_result* rejected = ht_run(ht_argv(vr_worker, c"run", fifo), 0, c"", 2000)
	ht_require(rejected.status == 125 && contains(rejected.stderr_text, c"regular file"), c"FIFO image not rejected by CLI")
	int[2] pipe_fds
	ht_require(process_make_pipe(&pipe_fds[0], &pipe_fds[1]) == 0, c"cannot create diagnostic pipe")
	int flags = sys_fcntl(pipe_fds[1], 3, 0)
	ht_require(sys_fcntl(pipe_fds[1], 4, flags | o_nonblock) == 0, c"cannot make diagnostic pipe nonblocking")
	char* fill = ht_repeat('x', 4096)
	int written = 0
	while (1):
		written = write(pipe_fds[1], fill, 4096)
		if (written < 0): break
	ht_require(written == 0 - net_eagain(), c"unexpected pipe fill error")
	ht_require(sys_fcntl(pipe_fds[1], 4, flags) == 0, c"cannot restore blocking diagnostic pipe")
	hm_sample* failed = hm_start(ht_argv(vr_worker, c"run", fifo), 0, 0, pipe_fds[1])
	hm_finish(failed, 2000)
	close(pipe_fds[0])
	close(pipe_fds[1])
	ht_require(failed.status == 125 && !failed.timed_out, c"full stderr blocked CLI diagnostics")
	println(c"PASS full stderr cannot block CLI diagnostics")
	char* compiler = argparse_get(args, c"compiler")
	if (compiler == 0): compiler = path_join(path_dirname(vr_worker), c"wv4_darwin")
	compiler = ht_resolve(compiler)
	char* source = path_join(work, c"source.w")
	char* program = c"import lib.lib\nint main():\n\tprintln(c\"isolated source output\")\n\treturn 9\n"
	ht_write(source, program, strlen(program))
	vr_sentinel = path_join(work, c"source-output-sentinel")
	ht_write(vr_sentinel, c"must remain untouched", 21)
	char** environment = env_copy_with(env_current(), c"W_DARWIN_COMPILER", compiler)
	hm_sample* source_process = hm_start(ht_argv(vr_worker, c"run", source), 0, environment, -1, -1, vr_predict_old_output)
	hm_finish(source_process, 10000)
	unlink(strjoin(c"bin/wvm-darwin-source-", itoa(source_process.child.pid)))
	ht_require(source_process.status == 9 && !source_process.timed_out, c"source execution failed")
	ht_equal_file(source_process.stdout_path, c"isolated source output\n")
	ht_equal_file(vr_sentinel, c"must remain untouched")
	println(c"PASS source compilation isolates output from predictable-path symlinks")
	char* marker = path_join(work, c"must-not-reach-worker")
	ht_write(marker, c"host-secret-descriptor", 22)
	int retained = open(marker, 0, 0)
	ht_require(retained >= 0, c"cannot open host FD fixture")
	int inherited = sys_fcntl(retained, 0, 200)
	close(retained)
	ht_require(inherited >= 200, c"cannot duplicate high-number FD")
	vr_harness* h = vr_start(work, c"recovery", inherited)
	close(inherited)
	process_result* listing = ht_run(ht_argv(c"/usr/sbin/lsof", c"-a", c"-p", itoa(h.daemon.child.pid), c"-d", itoa(inherited), c"-Fn"), 0, 0, 5000)
	ht_require(contains(listing.stdout_text, marker), c"FD fixture not inherited by daemon")
	ht_require(json_object_has(vm_rpc(h.path, c"vm_spawn", vm_image(fifo)), c"error"), c"daemon accepted FIFO image")
	ht_require(ht_number(vm_ok(h.path, c"stats"), c"sessions") == 0, c"rejected image retained a session")
	println(c"PASS FIFO image rejected without blocking CLI/daemon")
	vr_malformed(h)
	int worker = 0
	char* session = vr_spawn(h, &worker)
	listing = ht_run(ht_argv(c"/usr/sbin/lsof", c"-a", c"-p", itoa(worker), c"-Fn"), 0, 0, 5000)
	ht_require(listing.status == 0 && !contains(listing.stdout_text, marker), c"inherited host descriptor leaked to worker")
	println(c"PASS high-number host FD excluded by worker allowlist")
	vm_exec(h.path, session, c"spin", 600000)
	# Darwin SIGSTOP=17 and SIGCONT=19 (Linux values differ).
	ht_require(kill(worker, 17) == 0, c"cannot stop worker")
	vm_ok(h.path, c"vm_cancel", vj_one(c"session", session))
	vr_wait_gone(worker)
	ht_require(ht_number(vm_ok(h.path, c"stats"), c"active") == 0, c"stopped worker retained admission")
	session = vr_spawn(h, &worker)
	vr_hello(h, session)
	vm_ok(h.path, c"vm_destroy", vj_one(c"session", session))
	println(c"PASS SIGSTOP worker cancellation and admission recovery")
	session = vr_spawn(h, &worker)
	vm_exec(h.path, session, c"burst", 1000, 1048576)
	ht_require(kill(h.daemon.child.pid, 17) == 0, c"cannot stop daemon")
	vr_wait_gone(worker, 0, 7000)
	ht_require(kill(h.daemon.child.pid, 19) == 0, c"cannot resume daemon")
	vm_state(h.path, session, c"failed")
	vr_wait_gone(worker)
	vm_ok(h.path, c"vm_destroy", vj_one(c"session", session))
	session = vr_spawn(h, &worker)
	vr_hello(h, session)
	vm_ok(h.path, c"vm_destroy", vj_one(c"session", session))
	println(c"PASS stopped daemon cannot block worker result indefinitely; replacement succeeds")
	vr_close(h)
	h = vr_start(work, c"replacement-daemon")
	session = vr_spawn(h, &worker)
	vr_hello(h, session)
	vr_close(h)
	ht_cleanup()
	println(c"PASS fresh daemon after injected failures; no retained worker processes")
	return 0
