# Live Linux RAM/device snapshots of an idle command session, on this host.
# Sealed migration streams own their backing. Restore uses independent file
# descriptions so several clones never share a migration stream offset.
# External devices (9p/network) are deliberately rejected: their state is
# outside guest RAM and QEMU 9p is not migratable. Imported private workspaces
# reside entirely in guest tmpfs and are captured. Ordinary migration restores
# copy RAM. Explicit create_cow materializes sealed RAM and separate device
# state for actual private file mappings shared between restored guests.
import lib.vmm.box
import lib.memfd

struct box_snapshot:
	int fd
	int ram_fd # -1: full migration; otherwise sealed CoW RAM plus device stream
	char* kernel
	char* initrd
	int cpus
	int memory_mb


void box_snapshot_free(box_snapshot* snapshot):
	if (snapshot == 0): return
	close(snapshot.fd)
	if (snapshot.ram_fd >= 0): close(snapshot.ram_fd)
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
	# A private clone's next ordinary capture must include its dirty RAM.
	if (ok && session.snapshot_ignore_shared):
		ok = box_qmp_ignore_shared(session.qmp_fd, 0, deadline)
		if (ok): session.snapshot_ignore_shared = 0
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
	snapshot.ram_fd = -1
	snapshot.kernel = strclone(session.kernel)
	snapshot.initrd = strclone(session.initrd)
	snapshot.cpus = session.cpus
	snapshot.memory_mb = session.memory_mb
	return snapshot


vm_box_session* box_snapshot_open(box_snapshot* snapshot, int timeout_ms, char* directory, int memory_fd, int shared, int paused):
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
	options.memory_fd = memory_fd
	options.memory_shared = shared
	options.snapshot_paused = paused
	options.snapshot_ignore_shared = snapshot.ram_fd >= 0
	options.channel_directory = directory
	vm_box_session* session = box_session_open(options)
	close(fd)
	free(options)
	return session


vm_box_session* box_snapshot_restore_in(box_snapshot* snapshot, int timeout_ms, char* directory):
	if (snapshot == 0): return 0
	return box_snapshot_open(snapshot, timeout_ms, directory, snapshot.ram_fd, 0, 0)


vm_box_session* box_snapshot_restore(box_snapshot* snapshot, int timeout_ms):
	return box_snapshot_restore_in(snapshot, timeout_ms, 0)


# Explicit optional CoW capture: first take a normal snapshot, materialize
# it into a shared-RAM helper that NEVER resumes, save device-only state,
# then destroy the helper before sealing RAM. Capture costs O(RAM) and one
# transient QEMU; restores map the sealed RAM privately without replaying
# every RAM page. No fallback to ordinary copies when this mode fails.
# This also captures dirty clones without reading another process's memory.
box_snapshot* box_snapshot_create_cow(vm_box_session* session, int timeout_ms):
	if (timeout_ms < 1 || timeout_ms > 600000): return 0
	int deadline = process_monotonic_ms() + timeout_ms
	box_snapshot* snapshot = box_snapshot_create(session, timeout_ms)
	if (snapshot == 0): return 0
	int ram = memfd_create(c"wvm-linux-ram", MFD_CLOEXEC | MFD_ALLOW_SEALING)
	int state = memfd_create(c"wvm-linux-devices", MFD_CLOEXEC | MFD_ALLOW_SEALING)
	int ok = ram >= 0 && state >= 0
	if (ok): ok = sys_ftruncate(ram, snapshot.memory_mb * 1048576) == 0
	vm_box_session* helper = 0
	int remaining = deadline - process_monotonic_ms()
	if (ok && remaining > 0): helper = box_snapshot_open(snapshot, remaining, session.directory, ram, 1, 1)
	if (helper == 0): ok = 0
	if (ok): ok = box_qmp_ignore_shared(helper.qmp_fd, 1, deadline)
	if (ok): ok = box_qmp_migrate(helper.qmp_fd, state, 0, deadline)
	box_session_close(helper)
	if (ok):
		# KVM can briefly retain writable pins after QEMU exits. Sealing
		# must succeed; wait only for EBUSY and within the caller deadline.
		while (1):
			int sealed = sys_fcntl(ram, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL)
			if (sealed == 0): break
			if (sealed != -16 || deadline <= process_monotonic_ms()):
				ok = 0
				break
			process_sleep_ms(5)
	if (ok): ok = sys_fcntl(state, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) == 0
	if (ok == 0):
		if (ram >= 0): close(ram)
		if (state >= 0): close(state)
		box_snapshot_free(snapshot)
		return 0
	close(snapshot.fd)
	snapshot.fd = state
	snapshot.ram_fd = ram
	return snapshot
