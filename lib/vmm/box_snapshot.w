# Live Linux RAM/device snapshots of an idle command session, on this host.
# Sealed migration streams own their backing. Restore uses independent file
# descriptions so several clones never share a migration stream offset.
# External devices (9p/network) are deliberately rejected: their state is
# outside guest RAM and QEMU 9p is not migratable.
import lib.vmm.box
import lib.memfd

struct box_snapshot:
	int fd
	char* kernel
	char* initrd
	int cpus
	int memory_mb


void box_snapshot_free(box_snapshot* snapshot):
	if (snapshot == 0): return
	close(snapshot.fd)
	free(snapshot.kernel)
	free(snapshot.initrd)
	free(snapshot)


box_snapshot* box_snapshot_create(vm_box_session* session, int timeout_ms):
	if (session == 0 || session.alive == 0 || session.snapshot_allowed == 0): return 0
	if (timeout_ms < 1 || timeout_ms > 600000): return 0
	int fd = memfd_create(c"wvm-linux-snapshot", MFD_CLOEXEC | MFD_ALLOW_SEALING)
	if (fd < 0): return 0
	int deadline = process_monotonic_ms() + timeout_ms
	int ok = box_qmp_simple(session.qmp_fd, c"stop", deadline)
	if (ok): ok = box_qmp_migrate(session.qmp_fd, fd, 0, deadline)
	if (ok): ok = sys_fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) == 0
	if (ok): ok = box_qmp_simple(session.qmp_fd, c"cont", deadline)
	if (ok == 0):
		# An uncertain migration must never be offered as a healthy session.
		box_session_cancel(session)
		close(fd)
		return 0
	box_snapshot* snapshot = new box_snapshot()
	snapshot.fd = fd
	snapshot.kernel = strclone(session.kernel)
	snapshot.initrd = strclone(session.initrd)
	snapshot.cpus = session.cpus
	snapshot.memory_mb = session.memory_mb
	return snapshot


vm_box_session* box_snapshot_restore_in(box_snapshot* snapshot, int timeout_ms, char* directory):
	if (snapshot == 0): return 0
	string_builder* path = string_new()
	string_append(path, c"/proc/self/fd/")
	string_append_int(path, snapshot.fd)
	int fd = open(path.data, 524288, 0)
	string_free(path)
	if (fd < 0): return 0
	vm_box_options* options = box_options_new()
	options.kernel = snapshot.kernel
	options.initrd = snapshot.initrd
	options.cpus = snapshot.cpus
	options.memory_mb = snapshot.memory_mb
	options.timeout_ms = timeout_ms
	options.snapshot_fd = fd
	options.channel_directory = directory
	vm_box_session* session = box_session_open(options)
	close(fd)
	free(options)
	return session


vm_box_session* box_snapshot_restore(box_snapshot* snapshot, int timeout_ms):
	return box_snapshot_restore_in(snapshot, timeout_ms, 0)
