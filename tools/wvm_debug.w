# wbuild: binary=wvm_debug arch=x64
# Scriptable KVM cell debugger. Only static ELF input; compilation is explicit.
import lib.vmm.debug
import lib.vmm.faults
import lib.file
import lib.hex


void vmdbg_print_string(char* label, char* value):
	print(label)
	println(value)


void vmdbg_print_int(char* label, int value):
	char* text = itoa(value)
	print(label)
	println(text)
	free(text)


int vmdbg_number(char* text):
	if (text == 0 || text[0] == 0): return -1
	int base = 10
	int at = 0
	if (text[0] == '0' && text[1] == 'x'):
		base = 16
		at = 2
	if (text[at] == 0): return -1
	int value = 0
	while (text[at] != 0):
		int digit = hex_decode_char(text[at])
		if (digit < 0 || digit >= base || value > (CELL_RAM_SIZE - digit) / base): return -1
		value = value * base + digit
		at = at + 1
	return value


char* vmdbg_image(char* path, int* length):
	int fd = open(path, 2048, 0)
	if (fd < 0): return 0
	int size = seek(fd, 0, 2)
	if (size < 64 || size > 67108864 || seek(fd, 0, 0) != 0):
		close(fd)
		return 0
	char* image = cast(char*, malloc(size))
	int at = 0
	while (at < size):
		int count = read(fd, image + at, size - at)
		if (count == -4): continue
		if (count <= 0): break
		at = at + count
	close(fd)
	if (at != size):
		free(image)
		return 0
	*length = size
	return image


int vmdbg_address(vm_cell* cell, char* text):
	if (text == 0): return -1
	if (strcmp(text, c"$entry") == 0): return cell.entry
	if (strcmp(text, c"$stack") == 0): return CELL_STACK_LOW
	if (strcmp(text, c"$heap") == 0): return cell.heap_start
	if (strcmp(text, c"$rip") == 0 || strcmp(text, c"$rsp") == 0):
		char[144] registers
		if (cell_debug_registers(cell, &registers[0]) == 0): return -1
		if (strcmp(text, c"$rip") == 0): return load_int64(&registers[128])
		return load_int64(&registers[48])
	return vmdbg_number(text)


# Resolve only bounded original ELF function symbols; never guest metadata.
int vmdbg_symbol(char* image, int length, char* wanted):
	int budget = 65536
	int size = strlen(wanted)
	if (size < 1 || size > 1024): return -1
	int count = load_int16(image + 60)
	for i in range(count):
		char* section = vm_debug_section(image, length, i)
		if (section == 0 || load_int32(section + 4) != 2 || load_int64(section + 56) != 24): continue
		char* names = vm_debug_section(image, length, load_int32(section + 40))
		if (names == 0): continue
		int entries = load_int64(section + 32) / 24
		for j in range(entries):
			budget = budget - 1
			if (budget < 0): return -1
			char* symbol = image + load_int64(section + 24) + j * 24
			if ((symbol[4] & 15) != 2): continue
			int offset = load_int32(symbol)
			int bytes = load_int64(names + 32)
			if (offset < 0 || offset >= bytes): continue
			char* name = image + load_int64(names + 24) + offset
			if (size >= bytes - offset): continue
			int same = name[size] == 0
			for k in range(size):
				if (name[k] != wanted[k]): same = 0
			if (same): return load_int64(symbol + 8)
	return -1


void vmdbg_status(vm_cell* cell, char* image, int length):
	if (cell.exited):
		vmdbg_print_int(c"exited status=", cell.status)
		if (cell.fault_vector >= 0):
			char* symbol = cell_fault_symbol(image, length, cell.fault_rip)
			char* pc = hex_fixed(cell.fault_rip, 16)
			vmdbg_print_string(c"fault rip=", pc)
			vmdbg_print_string(c" ", symbol)
			vmdbg_print_int(c"vector=", cell.fault_vector)
			free(pc)
			free(symbol)
	else if (cell.paused):
		char[144] registers
		if (cell_debug_registers(cell, &registers[0])):
			char* pc = hex_fixed(load_int64(&registers[128]), 16)
			vmdbg_print_string(c"paused rip=", pc)
			free(pc)
	else: println(c"debugger unavailable")


int vmdbg_registers(vm_cell* cell):
	char[144] registers
	if (cell_debug_registers(cell, &registers[0]) == 0):
		println(c"error: registers require a paused guest")
		return 0
	char* names = c"rax rbx rcx rdx rsi rdi rsp rbp r8 r9 r10 r11 r12 r13 r14 r15 rip rflags"
	int at = 0
	for i in range(18):
		int start = at
		while (names[at] != 0 && names[at] != ' '): at = at + 1
		write(1, names + start, at - start)
		char* value = hex_fixed(load_int64(&registers[i * 8]), 16)
		vmdbg_print_string(c"=", value)
		free(value)
		if (names[at] == ' '): at = at + 1
	return 1


# -1 oversized/malformed, 0 EOF, 1 complete line. Input never grows a heap
# buffer; at most four command tokens and 4096 bytes are accepted.
int vmdbg_line(char* buffer):
	int length = 0
	while (1):
		char ch
		int got = read(0, &ch, 1)
		if (got == -4): continue
		if (got <= 0):
			buffer[length] = 0
			return length != 0
		if (ch == 10):
			buffer[length] = 0
			return 1
		if (ch == 0 || length == 4096): return -1
		buffer[length] = ch
		length = length + 1


int vmdbg_tokens(char* line, char** words):
	int count = 0
	int at = 0
	while (line[at] != 0):
		while (line[at] == ' ' || line[at] == 9 || line[at] == 13): at = at + 1
		if (line[at] == 0): break
		if (count == 4): return -1
		words[count] = line + at
		count = count + 1
		while (line[at] != 0 && line[at] != ' ' && line[at] != 9 && line[at] != 13): at = at + 1
		if (line[at] != 0):
			line[at] = 0
			at = at + 1
	return count


int main(int argc, int argv):
	char** args = cast(char**, argv)
	int at = 1
	int timeout = 5000
	if (argc >= 4 && strcmp(args[at], c"--timeout-ms") == 0):
		timeout = vmdbg_number(args[at + 1])
		at = at + 2
	if (at >= argc || timeout < 1 || timeout > 600000):
		println(c"usage: wvm_debug [--timeout-ms 1..600000] STATIC_X64_ELF [args...]")
		return 2
	int length = 0
	char* image = vmdbg_image(args[at], &length)
	if (image == 0): return 125
	vm_cell* cell = cell_new()
	int ok = cell != 0
	if (ok): ok = cell_elf_load(cell, image, length) && cell_stack(cell, argc - at, args + at * __word_size__)
	if (ok): ok = cell_debug_start(cell)
	if (ok == 0):
		println(c"error: cannot start KVM guest debugger")
		cell_free(cell)
		free(image)
		return 125
	vmdbg_status(cell, image, length)
	int failed = 0
	int commands = 0
	int stdout_at = 0
	int stderr_at = 0
	while (commands < 10000):
		char[4097] line
		print(c"wvmdbg> ")
		int got = vmdbg_line(&line[0])
		if (got == 0): break
		if (got < 0):
			failed = 1
			break
		commands = commands + 1
		char*[4] words
		int count = vmdbg_tokens(&line[0], &words[0])
		if (count == 0): continue
		if (count < 0):
			println(c"error: too many command arguments")
			failed = 1
			continue
		char* command = words[0]
		if ((strcmp(command, c"quit") == 0 || strcmp(command, c"q") == 0) && count == 1): break
		int accepted = 0
		if (strcmp(command, c"help") == 0 && count == 1):
			println(c"status | regs | step | continue | break SYMBOL_OR_ADDRESS | delete SLOT | threads | thread TID | read ADDRESS LENGTH | write ADDRESS HEX | quit")
			accepted = 1
		else if (strcmp(command, c"status") == 0 && count == 1):
			vmdbg_status(cell, image, length)
			accepted = 1
		else if ((strcmp(command, c"regs") == 0 || strcmp(command, c"r") == 0) && count == 1):
			accepted = vmdbg_registers(cell)
		else if ((strcmp(command, c"step") == 0 || strcmp(command, c"si") == 0) && count == 1):
			accepted = cell_debug_step(cell, timeout)
			vmdbg_status(cell, image, length)
		else if ((strcmp(command, c"continue") == 0 || strcmp(command, c"c") == 0) && count == 1):
			accepted = cell_debug_continue(cell, timeout)
			vmdbg_status(cell, image, length)
		else if ((strcmp(command, c"break") == 0 || strcmp(command, c"b") == 0) && count == 2):
			int address = vmdbg_address(cell, words[1])
			if (address < 0): address = vmdbg_symbol(image, length, words[1])
			int slot = -1
			for i in range(4):
				if (slot < 0 && cell_debug_breakpoint_address(cell, i) == 0): slot = i
			if (address >= 0 && slot >= 0): accepted = cell_debug_breakpoint(cell, slot, address)
			if (accepted):
				vmdbg_print_int(c"breakpoint ", slot)
				char* pc = hex_fixed(address, 16)
				vmdbg_print_string(c"address=", pc)
				free(pc)
		else if (strcmp(command, c"delete") == 0 && count == 2):
			accepted = cell_debug_delete(cell, vmdbg_number(words[1]))
			if (accepted): println(c"breakpoint deleted")
		else if (strcmp(command, c"threads") == 0 && count == 1):
			int capacity = cell_debug_threads(cell)
			for i in range(capacity):
				int tid = cell_debug_thread_tid(cell, i)
				if (tid > 0):
					vmdbg_print_int(c"thread ", tid)
					vmdbg_print_int(c"state=", cell_debug_thread_state(cell, tid))
			accepted = capacity > 0
		else if (strcmp(command, c"thread") == 0 && count == 2):
			accepted = cell_debug_thread_select(cell, vmdbg_number(words[1]))
			if (accepted):
				vmdbg_print_int(c"selected thread ", vmdbg_number(words[1]))
				vmdbg_status(cell, image, length)
		else if (strcmp(command, c"read") == 0 && count == 3):
			int address = vmdbg_address(cell, words[1])
			int bytes = vmdbg_number(words[2])
			char[1024] data
			if (address >= 0 && bytes >= 0 && bytes <= 1024): accepted = cell_debug_read(cell, address, &data[0], bytes)
			if (accepted):
				char* hex = hex_encode(&data[0], bytes)
				vmdbg_print_string(c"memory=", hex)
				free(hex)
		else if (strcmp(command, c"write") == 0 && count == 3):
			int address = vmdbg_address(cell, words[1])
			int bytes = 0
			char* data = 0
			if (strlen(words[2]) <= 2048): data = hex_decode(words[2], strlen(words[2]), &bytes)
			if (address >= 0 && data != 0): accepted = cell_debug_write(cell, address, data, bytes)
			free(data)
			if (accepted): println(c"memory written")
		if (accepted == 0):
			println(c"error: invalid command or unavailable guest operation")
			failed = 1
		if (cell.output.length > stdout_at):
			char* hex = hex_encode(cell.output.data + stdout_at, cell.output.length - stdout_at)
			vmdbg_print_string(c"stdout_hex=", hex)
			free(hex)
			stdout_at = cell.output.length
		if (cell.errors.length > stderr_at):
			char* hex = hex_encode(cell.errors.data + stderr_at, cell.errors.length - stderr_at)
			vmdbg_print_string(c"stderr_hex=", hex)
			free(hex)
			stderr_at = cell.errors.length
	int status = 0
	if (cell.exited): status = cell.status
	if (failed || commands == 10000): status = 2
	cell_free(cell)
	free(image)
	return status
