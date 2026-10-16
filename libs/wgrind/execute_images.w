# Linux mapped ELF discovery. Paths consume the complete maps-line tail
# (including spaces). Missing/replaced/deleted images fail closed.
import libs.wgrind.execute_symbols
import libs.wgrind.leaks

struct wg_image_map:
	int low
	int high
	int offset
	int permissions
	int executable
	int major
	int minor
	int inode
	char* path

struct wg_image_root:
	int address
	int size

struct wg_image_record:
	char* path
	int bias

struct wg_images:
	wg_context* context
	wg_symbols* symbols
	int limit
	list[wg_image_map] maps
	list[wg_image_root] roots
	list[wg_image_record] images


void wg_images_init(wg_images* images, wg_context* c, wg_symbols* symbols, int limit):
	images.context = c
	images.symbols = symbols
	images.limit = limit
	images.maps = new list[wg_image_map]
	images.roots = new list[wg_image_root]
	images.images = new list[wg_image_record]
	if ((limit < 1) || (limit > 4096)): wg_error(c, WG_INCOMPLETE, 0, limit, 0, 0)


void wg_images_clear(wg_images* images):
	for i in range(images.maps.length): free(images.maps[i].path)
	for i in range(images.images.length): free(images.images[i].path)
	images.maps.clear()
	images.roots.clear()
	images.images.clear()


void wg_images_destroy(wg_images* images):
	wg_images_clear(images)
	images.maps.free()
	images.roots.free()
	images.images.free()


int wg_map_number(char* text, int* position, int base, int* result):
	int start = *position
	int n = 0
	while (1):
		int ch = text[*position]
		int digit = ch - '0'
		if ((ch >= 'a') && (ch <= 'f')): digit = ch - 'a' + 10
		else if ((ch >= 'A') && (ch <= 'F')): digit = ch - 'A' + 10
		else if ((ch < '0') || (ch > '9')): break
		if (digit >= base): break
		# Signed-host arithmetic cannot represent oversized offsets/inodes.
		int maximum = (1 << (__word_size__ * 8 - 1)) - 1
		if (base == 16):
			if ((n < 0) || (n > ((1 << (__word_size__ * 8 - 4)) - 1))): return 0
		else if (n > (maximum - digit) / base): return 0
		n = n * base + digit
		*position = *position + 1
	if (*position == start): return 0
	*result = n
	return 1


int wg_map_space(char* text, int* position):
	if (text[*position] != ' '): return 0
	while (text[*position] == ' '): *position = *position + 1
	return 1


int wg_images_parse(wg_images* images, char* text):
	wg_context* c = images.context
	if (c.error): return 0
	int pos = 0
	while (text[pos]):
		if (images.maps.length >= images.limit): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		wg_image_map mapping
		if (wg_map_number(text, &pos, 16, &mapping.low) == 0): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		if (text[pos] != '-'): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		pos = pos + 1
		if ((wg_map_number(text, &pos, 16, &mapping.high) == 0) || (wg_less(mapping.low, mapping.high) == 0) || (wg_map_space(text, &pos) == 0)):
			return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		mapping.permissions = 0
		if (text[pos] == 'r'): mapping.permissions = WG_READ
		else if (text[pos] != '-'): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		pos = pos + 1
		if (text[pos] == 'w'): mapping.permissions = mapping.permissions | WG_WRITE
		else if (text[pos] != '-'): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		pos = pos + 1
		mapping.executable = text[pos] == 'x'
		if ((text[pos] != 'x') && (text[pos] != '-')): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		pos = pos + 1
		if ((text[pos] != 'p') && (text[pos] != 's')): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		pos = pos + 1
		if ((wg_map_space(text, &pos) == 0) || (wg_map_number(text, &pos, 16, &mapping.offset) == 0) || (wg_map_space(text, &pos) == 0) || (wg_map_number(text, &pos, 16, &mapping.major) == 0)):
			return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		if (text[pos] != ':'): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		pos = pos + 1
		if ((wg_map_number(text, &pos, 16, &mapping.minor) == 0) || (wg_map_space(text, &pos) == 0) || (wg_map_number(text, &pos, 10, &mapping.inode) == 0)):
			return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
		while (text[pos] == ' '): pos = pos + 1
		int start = pos
		while (text[pos] && (text[pos] != '\n')):
			if ((pos - start >= 4096) || (text[pos] == '\\')): return wg_error(c, WG_INCOMPLETE, 0, pos, 0, 0)
			pos = pos + 1
		int length = pos - start
		mapping.path = cast(char*, malloc(length + 1))
		if (mapping.path == 0): return wg_error(c, WG_INCOMPLETE, 0, length, 0, 0)
		for i in range(length): mapping.path[i] = text[start + i]
		mapping.path[length] = 0
		images.maps.push(mapping)
		if (text[pos]): pos = pos + 1
	return 1


# Validate program headers before using offsets to derive any load bias.
int wg_images_headers(char* data, int length):
	if ((__word_size__ != 8) || (wg_elf64(data, length) == 0)): return 0
	int offset = wg_elf_u64(data, 32)
	int count = wg_elf_u16(data, 56)
	if ((wg_elf_u16(data, 54) != 56) || (count < 1) || (count > 1024) || (wg_elf_range(length, offset, count * 56) == 0)): return 0
	int loads = 0
	for i in range(count):
		int header = offset + i * 56
		if (wg_elf_u32(data, header) != 1): continue
		int file = wg_elf_u64(data, header + 8)
		int address = wg_elf_u64(data, header + 16)
		int size = wg_elf_u64(data, header + 32)
		int memory = wg_elf_u64(data, header + 40)
		if ((wg_elf_range(length, file, size) == 0) || (memory < size) || (memory < 0) || (address < 0) || (address + memory < address) || ((file & 4095) != (address & 4095))): return 0
		loads = loads + 1
	return loads != 0


int wg_images_add(wg_images* images, char* path, char* data, int length, int bias):
	wg_context* c = images.context
	for i in range(images.images.length):
		wg_image_record image = images.images[i]
		if ((image.bias == bias) && (strcmp(image.path, path) == 0)): return 1
	if (images.images.length >= images.limit): return wg_error(c, WG_INCOMPLETE, bias, 0, 0, 0)
	if ((wg_elf_u16(data, 16) == 2) && (bias != 0)): return wg_error(c, WG_INCOMPLETE, bias, 0, 0, 0)
	if (wg_symbols_image(images.symbols, data, length, bias) == 0): return 0
	wg_image_record image
	image.path = strclone(path)
	image.bias = bias
	images.images.push(image)
	int offset = wg_elf_u64(data, 32)
	for i in range(wg_elf_u16(data, 56)):
		int header = offset + i * 56
		if ((wg_elf_u32(data, header) != 1) || ((wg_elf_u32(data, header + 4) & 2) == 0)): continue
		int base = wg_elf_u64(data, header + 16)
		int size = wg_elf_u64(data, header + 40)
		if ((bias < 0) || (base + bias < base) || (base + bias + size < base + bias)): return wg_error(c, WG_INCOMPLETE, base, size, 0, 0)
		if (images.roots.length >= images.limit * 16): return wg_error(c, WG_INCOMPLETE, base, size, 0, 0)
		wg_image_root root
		root.address = base + bias
		root.size = size
		images.roots.push(root)
	return 1


int wg_images_layout(wg_images* images, char* path, char* data, int length):
	wg_context* c = images.context
	if (wg_images_headers(data, length) == 0): return wg_error(c, WG_INCOMPLETE, 0, length, 0, 0)
	int offset = wg_elf_u64(data, 32)
	int first = -1
	for i in range(wg_elf_u16(data, 56)):
		int header = offset + i * 56
		if (wg_elf_u32(data, header) != 1): continue
		if ((first < 0) || (wg_elf_u64(data, header + 8) < wg_elf_u64(data, first + 8))): first = header
	int anchors = 0
	for i in range(images.maps.length):
		wg_image_map mapping = images.maps[i]
		if (strcmp(mapping.path, path)): continue
		if (mapping.offset != (wg_elf_u64(data, first + 8) & ~4095)): continue
		int virtual = wg_elf_u64(data, first + 16) & ~4095
		if (wg_less(mapping.low, virtual)): return wg_error(c, WG_INCOMPLETE, mapping.low, 0, 0, 0)
		if (wg_images_add(images, path, data, length, mapping.low - virtual) == 0): return 0
		anchors = anchors + 1
	if (anchors == 0): return wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	# Split RELRO mappings can reuse file offsets. Match virtual address
	# against each PT_LOAD using the anchored bias, never offset alone.
	for i in range(images.maps.length):
		wg_image_map mapping = images.maps[i]
		if (strcmp(mapping.path, path)): continue
		int matched = 0
		for j in range(images.images.length):
			wg_image_record image = images.images[j]
			if (strcmp(image.path, path)): continue
			for k in range(wg_elf_u16(data, 56)):
				int header = offset + k * 56
				if (wg_elf_u32(data, header) != 1): continue
				int file = wg_elf_u64(data, header + 8)
				int size = wg_elf_u64(data, header + 32)
				int end = (file + size + 4095) & ~4095
				int flags = wg_elf_u32(data, header + 4)
				if ((mapping.offset < (file & ~4095)) || (mapping.offset >= end)): continue
				int virtual = (wg_elf_u64(data, header + 16) & ~4095) + image.bias + mapping.offset - (file & ~4095)
				if ((mapping.low == virtual) && ((mapping.executable == 0) || (flags & 1)) && (((mapping.permissions & WG_WRITE) == 0) || (flags & 2))): matched = 1
		if (matched == 0): return wg_error(c, WG_INCOMPLETE, mapping.low, mapping.high - mapping.low, 0, 0)
	return 1


int wg_images_file(wg_images* images, int pid, char* path):
	wg_context* c = images.context
	int name_length = strlen(path)
	if ((name_length >= 10) && (strcmp(path + name_length - 10, c" (deleted)") == 0)):
		return wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	char* number = itoa(pid)
	char* prefix = strjoin(c"/proc/", number)
	char* root = strjoin(prefix, c"/root")
	char* host_path = strjoin(root, path)
	free(number)
	free(prefix)
	free(root)
	char[256] metadata
	if (statx(host_path, 0, 256, &metadata[0]) < 0):
		free(host_path)
		return wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	int length = 0
	char* data = wg_symbol_read_file(host_path, &length)
	free(host_path)
	if (data == 0): return wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	int success = 1
	int elf = wg_images_headers(data, length)
	if ((elf == 0) && (length >= 4) && (data[0] == 127) && (data[1] == 'E') && (data[2] == 'L') && (data[3] == 'F')):
		free(data)
		return wg_error(c, WG_INCOMPLETE, 0, length, 0, 0)
	for i in range(images.maps.length):
		wg_image_map mapping = images.maps[i]
		if (strcmp(mapping.path, path)): continue
		if ((wg_elf_u64(&metadata[0], 32) != mapping.inode) || (wg_elf_u32(&metadata[0], 136) != mapping.major) || (wg_elf_u32(&metadata[0], 140) != mapping.minor)):
			success = wg_error(c, WG_INCOMPLETE, mapping.low, 0, 0, 0)
			break
		if (elf == 0):
			if (mapping.executable): success = wg_error(c, WG_INCOMPLETE, mapping.low, 0, 0, 0)
			continue
	if (success && elf): success = wg_images_layout(images, path, data, length)
	free(data)
	return success


char* wg_images_read_maps(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	# A fixed upper bound also protects the supervisor from huge maps
	# files before the parsed-record limit can reject their contents.
	int limit = 16777216
	char* text = cast(char*, malloc(limit + 1))
	if (text == 0):
		close(fd)
		return 0
	int used = 0
	while (used < limit):
		int n = read(fd, text + used, limit - used)
		if (n == -4): continue
		if (n < 0):
			free(text)
			close(fd)
			return 0
		if (n == 0):
			text[used] = 0
			close(fd)
			return text
		used = used + n
	free(text)
	close(fd)
	return 0


int wg_images_refresh(wg_images* images, int pid):
	wg_context* c = images.context
	if (c.error): return 0
	if (__word_size__ != 8): return wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	wg_images_clear(images)
	images.symbols.allocators.clear()
	images.symbols.w_abi = 0
	char* number = itoa(pid)
	char* prefix = strjoin(c"/proc/", number)
	char* path = strjoin(prefix, c"/maps")
	char* maps = wg_images_read_maps(path)
	free(number)
	free(prefix)
	free(path)
	if (maps == 0): return wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	int parsed = wg_images_parse(images, maps)
	free(maps)
	if (parsed == 0): return 0
	for i in range(images.maps.length):
		wg_image_map mapping = images.maps[i]
		if (mapping.path[0] != '/'): continue
		int seen = 0
		for j in range(i):
			if (strcmp(images.maps[j].path, mapping.path) == 0): seen = 1
		if (seen): continue
		if (wg_images_file(images, pid, mapping.path) == 0): return 0
	return 1


int wg_images_roots(wg_images* images, wg_leaks* leaks):
	if (images.context.error): return 0
	for i in range(images.roots.length):
		wg_image_root root = images.roots[i]
		if (wg_leaks_root_range(leaks, root.address, root.size) == 0): return 0
	return 1
