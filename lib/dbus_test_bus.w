# A private message bus for tests: spawns `dbus-daemon --session` on a
# fresh socket and reports its address, so D-Bus tests never touch the
# user's session. Tests call dbus_test_bus_start and skip (test_skip)
# when it returns 0 because dbus-daemon is not installed.
import lib.lib
import lib.process
import lib.poll
import lib.dbus


struct dbus_test_bus:
	process* daemon
	char* address


# Start the daemon and read the address line it prints. Returns 1 with
# bus.address set, 0 when dbus-daemon is missing or does not come up.
# listen (may be 0) overrides the configured listen address.
int dbus_test_bus_start_at(dbus_test_bus* bus, char* listen):
	bus.daemon = 0
	bus.address = 0
	char* path = process_which(c"dbus-daemon")
	if (path == 0): return 0
	char** argv = strv_new(5)
	strv_set(argv, 0, c"dbus-daemon")
	strv_set(argv, 1, c"--session")
	strv_set(argv, 2, c"--nofork")
	strv_set(argv, 3, c"--print-address=1")
	if (listen != 0):
		char* flag = c"--address="
		int a = strlen(flag)
		int b = strlen(listen)
		char* arg = cast(char*, malloc(a + b + 1))
		for i in range(a): arg[i] = flag[i]
		for i in range(b + 1): arg[a + i] = listen[i]
		strv_set(argv, 4, arg)
	spawn_options* opts = spawn_options_new()
	opts.stdout_mode = process_pipe
	opts.stderr_mode = process_null
	opts.new_group = 1
	bus.daemon = process_spawn(path, argv, opts)
	free(opts)
	if (bus.daemon == 0): return 0
	char* line = cast(char*, malloc(512))
	int n = 0
	while (n < 511):
		if (poll_single(bus.daemon.stdout_fd, poll_in, 5000) <= 0): break
		char[1] ch
		if (read(bus.daemon.stdout_fd, &ch[0], 1) != 1): break
		if (ch[0] == 10): break
		line[n] = ch[0]
		n = n + 1
	line[n] = 0
	if (n == 0):
		free(line)
		process_kill_group(bus.daemon, sigkill)
		process_wait(bus.daemon)
		bus.daemon = 0
		return 0
	bus.address = line
	return 1


int dbus_test_bus_start(dbus_test_bus* bus):
	return dbus_test_bus_start_at(bus, 0)


void dbus_test_bus_stop(dbus_test_bus* bus):
	if (bus.daemon != 0):
		process_kill_group(bus.daemon, sigterm)
		process_wait(bus.daemon)
		process_free(bus.daemon)
		bus.daemon = 0
	free(bus.address)
	bus.address = 0
