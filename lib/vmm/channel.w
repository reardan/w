# WVM1 command channel. Fixed little-endian fields, bounded byte lengths;
# never parse shell text or trust a guest-supplied allocation size.
import lib.process
import lib.net
import lib.mem

const int box_channel_magic = 0x57564d31
const int box_status_output_limit = -1002
const int box_status_transport = -1003
const int box_channel_max_request = 65536
const int box_channel_max_output = 1048576


# The descriptor must be nonblocking. All I/O shares one absolute deadline.
# sockets use MSG_NOSIGNAL; guest virtio ports use write(2).
int box_channel_io(int fd, char* data, int length, int writing, int is_socket, int deadline):
	int offset = 0
	char[8] events
	while (offset < length):
		int remaining = deadline - process_monotonic_ms()
		if (remaining <= 0): return 0
		int requested = 1
		if (writing): requested = 4
		process_pollfd_set(&events[0], 0, fd, requested)
		int ready = poll(cast(int*, &events[0]), 1, remaining)
		if (ready == -4): continue
		if (ready <= 0): return 0
		int count = 0
		if (writing):
			if (is_socket): count = socket_send(fd, data + offset, length - offset, 16384)
			else: count = write(fd, data + offset, length - offset)
		else: count = read(fd, data + offset, length - offset)
		if (count == -4 || count == -11): continue
		if (count <= 0): return 0
		offset = offset + count
	return 1


int box_channel_text_valid(char* data, int length):
	for i in range(length):
		if (data[i] == 0): return 0
	return 1


# Returns the complete encoded request, including its 24-byte header.
# Null means caller input was invalid, before any bytes were transmitted.
char* box_channel_request(char** args, char* cwd, int timeout_ms, int output_limit, int* length):
	if (args == 0 || timeout_ms < 1 || timeout_ms > 600000): return 0
	if (output_limit < 1 || output_limit > box_channel_max_output): return 0
	int cwd_length = 0
	if (cwd != 0): cwd_length = strlen(cwd)
	if (cwd_length > 4096): return 0
	int argc = 0
	int total = 24 + cwd_length
	while (strv_get(args, argc) != 0):
		if (argc >= 128): return 0
		int size = strlen(strv_get(args, argc))
		if (size > 4096): return 0
		total = total + 4 + size
		if (total > box_channel_max_request): return 0
		argc = argc + 1
	if (argc == 0 || args[0][0] != '/'): return 0
	char* data = malloc(total)
	save_int32(data, box_channel_magic)
	save_int32(data + 4, total - 24)
	save_int32(data + 8, argc)
	save_int32(data + 12, timeout_ms)
	save_int32(data + 16, output_limit)
	save_int32(data + 20, cwd_length)
	if (cwd_length > 0): mem_copy[char](data + 24, cwd, cwd_length)
	int offset = 24 + cwd_length
	for i in range(argc):
		char* arg = strv_get(args, i)
		int size = strlen(arg)
		save_int32(data + offset, size)
		mem_copy[char](data + offset + 4, arg, size)
		offset = offset + 4 + size
	*length = total
	return data


# Validate every length before copying. Returned strings are separately owned.
char** box_channel_decode(char* header, char* payload, char** cwd):
	int length = load_int32(header + 4)
	int argc = load_int32(header + 8)
	int timeout_ms = load_int32(header + 12)
	int output_limit = load_int32(header + 16)
	int cwd_length = load_int32(header + 20)
	if (load_int32(header) != box_channel_magic): return 0
	if (length < 0 || length > box_channel_max_request - 24): return 0
	if (argc < 1 || argc > 128): return 0
	if (timeout_ms < 1 || timeout_ms > 600000): return 0
	if (output_limit < 1 || output_limit > box_channel_max_output): return 0
	if (cwd_length < 0 || cwd_length > 4096 || cwd_length > length): return 0
	if (box_channel_text_valid(payload, cwd_length) == 0): return 0
	int offset = cwd_length
	# First pass means no partial allocations on malformed input.
	for i in range(argc):
		if (offset > length - 4): return 0
		int size = load_int32(payload + offset)
		offset = offset + 4
		if (size < 0 || size > 4096 || size > length - offset): return 0
		if (box_channel_text_valid(payload + offset, size) == 0): return 0
		if (i == 0):
			if (size == 0 || payload[offset] != '/'): return 0
		offset = offset + size
	if (offset != length): return 0
	*cwd = 0
	if (cwd_length > 0):
		*cwd = malloc(cwd_length + 1)
		mem_copy[char](*cwd, payload, cwd_length)
		char* directory = *cwd
		directory[cwd_length] = 0
	char** args = strv_new(argc)
	offset = cwd_length
	for i in range(argc):
		int size = load_int32(payload + offset)
		char* value = malloc(size + 1)
		mem_copy[char](value, payload + offset + 4, size)
		value[size] = 0
		strv_set(args, i, value)
		offset = offset + 4 + size
	return args


void box_channel_args_free(char** args):
	if (args == 0): return
	int i = 0
	while (strv_get(args, i) != 0):
		free(strv_get(args, i))
		i = i + 1
	free(cast(void*, args))


process_result* box_channel_result(int status):
	process_result* result = new process_result()
	result.status = status
	result.stdout_text = strclone(c"")
	result.stderr_text = strclone(c"")
	result.stdout_length = 0
	result.stderr_length = 0
	return result
