# Serialized daemon-owned ready-cell templates. A removed handle stops new
# admissions; queued/running sessions retain the backing until destruction.
# A full 256 MiB reservation per template bounds sparse backing growth too.
import lib.vmm.snapshot
import lib.vmm.backing
import lib.vmm.box_snapshot

struct vm_template:
	int id
	int available
	int references
	cell_snapshot* snapshot
	box_snapshot* box
	int memory_mb
	int lease_deadline
	int lease_ms
	int source_session


cell_snapshot* vm_template_load(char* path):
	if (path == 0 || strlen(path) > 1024): return 0
	int fd = open(path, 2048, 0)
	if (fd < 0): return 0
	int size = seek(fd, 0, 2)
	if (size < 64 || size > 67108864 || seek(fd, 0, 0) != 0):
		close(fd)
		return 0
	char* image = cast(char*, malloc(size))
	int have = 0
	while (have < size):
		int count = read(fd, image + have, size - have)
		if (count == -4): continue
		if (count <= 0): break
		have = have + count
	close(fd)
	vm_cell* cell = cell_new()
	cell_snapshot* snapshot = 0
	if (cell != 0 && have == size):
		char** args = strv_new(1)
		strv_set(args, 0, path)
		if (cell_elf_load(cell, image, size) && cell_stack(cell, 1, args)):
			snapshot = cell_snapshot_create(cell)
		free(cast(void*, args))
	cell_free(cell)
	free(image)
	return snapshot


void vm_template_free(vm_template* template):
	if (template == 0): return
	cell_snapshot_free(template.snapshot)
	box_snapshot_free(template.box)
	free(template)


int vm_template_builder(void* request, char* metadata):
	cell_snapshot* snapshot = vm_template_load(cast(char*, request))
	if (snapshot == 0): return -1
	# Ready templates have no pointer-owned input; only the fd crosses.
	if (snapshot.input != 0 || snapshot.input_length != 0 || snapshot.parent != 0 || snapshot.changed_pages != 0): return -1
	mem_copy[char](metadata, cast(char*, snapshot), sizeof(cell_snapshot))
	return snapshot.fd


cell_snapshot* vm_template_load_charged(vm_cgroup* group, char* path):
	if (path == 0): return 0
	cell_snapshot* snapshot = new cell_snapshot()
	int fd = vm_backing_create(group, vm_template_builder, cast(void*, path), cast(char*, snapshot), sizeof(cell_snapshot))
	if (fd < 0):
		free(snapshot)
		return 0
	snapshot.fd = fd
	return snapshot
