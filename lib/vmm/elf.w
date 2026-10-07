# Checked loader for static little-endian x86-64 ET_EXEC files.
# No dynamic loader, relocations, interpreter, or host environment.
import lib.vmm.memory


int cell_elf_load(vm_cell* cell, char* image, int length):
	if (cell.loaded): return cell_fail(cell, c"cell already loaded")
	if (length < 64): return cell_fail(cell, c"truncated ELF header")
	if (load_int32(image) != 0x464c457f): return cell_fail(cell, c"not an ELF file")
	if (image[4] != 2 || image[5] != 1 || image[6] != 1): return cell_fail(cell, c"requires little-endian ELF64")
	if (load_int16(image + 16) != 2 || load_int16(image + 18) != 62 || load_int32(image + 20) != 1):
		return cell_fail(cell, c"requires a static x64 ET_EXEC image")
	if (load_int16(image + 52) != 64 || load_int16(image + 54) != 56): return cell_fail(cell, c"invalid ELF header sizes")
	int phoff = load_int64(image + 32)
	int count = load_int16(image + 56)
	if (count == 0 || count > 128 || phoff < 64 || phoff > length): return cell_fail(cell, c"invalid program header table")
	if (count > (length - phoff) / 56): return cell_fail(cell, c"truncated program header table")
	int entry = load_int64(image + 24)
	int executable_entry = 0
	int high = CELL_IMAGE_MIN
	# Validate everything before copying any bytes or accepting the entry.
	for i in range(count):
		char* ph = image + phoff + i * 56
		int kind = load_int32(ph)
		if (kind == 2 || kind == 3): return cell_fail(cell, c"dynamic ELF images are unsupported")
		if (kind == 1):
			int flags = load_int32(ph + 4)
			int offset = load_int64(ph + 8)
			int address = load_int64(ph + 16)
			int filesz = load_int64(ph + 32)
			int memsz = load_int64(ph + 40)
			int align = load_int64(ph + 48)
			if (flags < 0 || flags > 7 || filesz < 0 || memsz < filesz): return cell_fail(cell, c"invalid load segment")
			if (offset < 0 || offset > length || filesz > length - offset): return cell_fail(cell, c"truncated load segment")
			if (address < CELL_IMAGE_MIN || address >= CELL_IMAGE_MAX || memsz > CELL_IMAGE_MAX - address):
				return cell_fail(cell, c"load segment outside cell image range")
			if (align < 0 || (align > 1 && ((align & (align - 1)) != 0 || address % align != offset % align))):
				return cell_fail(cell, c"invalid segment alignment")
			# Overlapping load pages would otherwise let one segment silently
			# replace another's bytes or permissions. W emits separate pages.
			if (memsz > 0):
				for j in range(i):
					char* previous = image + phoff + j * 56
					if (load_int32(previous) == 1):
						int start = load_int64(previous + 16)
						int size = load_int64(previous + 40)
						if (size > 0 && (address & -4096) < cell_page_end(start + size) && (start & -4096) < cell_page_end(address + memsz)):
							return cell_fail(cell, c"overlapping load segments")
			if (entry >= address && entry - address < memsz && (flags & 1)): executable_entry = 1
			if (address + memsz > high): high = address + memsz
	if (executable_entry == 0): return cell_fail(cell, c"entry is not in an executable segment")
	cell_page_tables(cell)
	for i in range(count):
		char* ph = image + phoff + i * 56
		if (load_int32(ph) == 1):
			int address = load_int64(ph + 16)
			int filesz = load_int64(ph + 32)
			int memsz = load_int64(ph + 40)
			int flags = load_int32(ph + 4)
			int prot = PROT_READ
			if (flags & 2): prot = prot | PROT_WRITE
			if (flags & 1): prot = prot | PROT_EXEC
			if (memsz > 0): cell_map(cell, address, memsz, prot)
			mem_copy[char](cell.ram + address, image + load_int64(ph + 8), filesz)
	cell.entry = entry
	cell.heap_start = cell_page_end(high)
	cell.heap_end = cell.heap_start
	cell.loaded = 1
	return 1


# argv is copied into guest RAM. Only one fixed, non-secret environment
# entry disables guest-native signal tracing; the VMM reports faults.
int cell_stack(vm_cell* cell, int argc, char** argv):
	if (cell.loaded == 0 || cell.started): return cell_fail(cell, c"stack setup requires a loaded, unstarted cell")
	if (argc < 1 || argc > 256): return cell_fail(cell, c"too many guest arguments")
	int sp = CELL_STACK_TOP
	int* pointers = cast(int*, malloc(argc * 8))
	for i in range(argc):
		int size = strlen(argv[i]) + 1
		if (size > 65536 || sp - CELL_STACK_LOW < size + 4096):
			free(pointers)
			return cell_fail(cell, c"guest arguments too large")
		sp = sp - size
		mem_copy[char](cell.ram + sp, argv[i], size)
		pointers[i] = sp
	char* env = c"W_CRASH_TRACE=0"
	sp = sp - strlen(env) - 1
	mem_copy[char](cell.ram + sp, env, strlen(env) + 1)
	int env_address = sp
	# argc, argv[], NULL, envp[], NULL, auxv AT_PAGESZ and AT_NULL.
	sp = (sp - (argc + 9) * 8) & -16
	save_int64(cell.ram + sp, argc)
	for i in range(argc): save_int64(cell.ram + sp + 8 + i * 8, pointers[i])
	free(pointers)
	int tail = sp + 8 + argc * 8
	save_int64(cell.ram + tail, 0)
	save_int64(cell.ram + tail + 8, env_address)
	save_int64(cell.ram + tail + 16, 0)
	save_int64(cell.ram + tail + 24, 6) # AT_PAGESZ
	save_int64(cell.ram + tail + 32, 4096)
	save_int64(cell.ram + tail + 40, 0)
	save_int64(cell.ram + tail + 48, 0)
	cell_map(cell, CELL_STACK_LOW, CELL_STACK_TOP - CELL_STACK_LOW, PROT_READ | PROT_WRITE)
	cell.stack = sp
	return 1
