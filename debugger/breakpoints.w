/*
Breakpoints for wdbg.

A breakpoint patches an int3 (0xcc) over the first byte of a statement in
the debuggee's RWX code buffer, remembering the original byte. When it
hits, the trap handler restores the byte and rewinds eip so the original
instruction executes on resume; the main loop then re-arms the breakpoint
by single-stepping one instruction past it (dbg_rearm_bp).

Slots are identified by a stable 1-based id. Deleted slots keep their id
out of circulation until wdbg exits.
*/
import debugger.locals


int bp_max():
	return 64


int bp_addrs   /* absolute address, 0 = free slot */
int bp_bytes   /* original code byte */
int bp_armeds  /* 1 while the int3 is written into the code */
int bp_temps   /* 1 = one-shot breakpoint (tbreak) */
int bp_used


void bp_init():
	bp_addrs = malloc(bp_max() * 4)
	bp_bytes = malloc(bp_max() * 4)
	bp_armeds = malloc(bp_max() * 4)
	bp_temps = malloc(bp_max() * 4)
	int i = 0
	while (i < bp_max()):
		save_int(bp_addrs + i * 4, 0)
		i = i + 1
	bp_used = 0


int bp_addr(int i):
	return load_int(bp_addrs + i * 4)


int bp_is_temp(int i):
	return load_int(bp_temps + i * 4)


# Slot index of the breakpoint at an absolute address, or -1.
int bp_find(int addr):
	int i = 0
	while (i < bp_used):
		if (bp_addr(i) == addr):
			return i
		i = i + 1
	return -1


void bp_write_byte(int addr, int value):
	char* p = addr
	p[0] = value


int bp_read_byte(int addr):
	char* p = addr
	return p[0] & 255


void bp_arm(int i):
	if (bp_addr(i) == 0):
		return;
	if (load_int(bp_armeds + i * 4)):
		return;
	save_int(bp_bytes + i * 4, bp_read_byte(bp_addr(i)))
	bp_write_byte(bp_addr(i), 204) /* int3 */
	save_int(bp_armeds + i * 4, 1)


void bp_disarm(int i):
	if (bp_addr(i) == 0):
		return;
	if (load_int(bp_armeds + i * 4) == 0):
		return;
	bp_write_byte(bp_addr(i), load_int(bp_bytes + i * 4))
	save_int(bp_armeds + i * 4, 0)


# Create and arm a breakpoint; returns the slot index or -1.
int bp_add(int addr, int temp):
	if (bp_find(addr) >= 0):
		println(c"a breakpoint is already set there")
		return -1
	if (bp_used >= bp_max()):
		println(c"too many breakpoints")
		return -1
	if (bp_read_byte(addr) == 204):
		println(c"that statement is already a 'debugger' trap")
		return -1
	int i = bp_used
	bp_used = bp_used + 1
	save_int(bp_addrs + i * 4, addr)
	save_int(bp_armeds + i * 4, 0)
	save_int(bp_temps + i * 4, temp)
	bp_arm(i)
	return i


void bp_delete(int i):
	if ((i < 0) | (i >= bp_used)):
		println(c"no such breakpoint")
		return;
	if (bp_addr(i) == 0):
		println(c"no such breakpoint")
		return;
	bp_disarm(i)
	save_int(bp_addrs + i * 4, 0)


void bp_delete_all():
	int i = 0
	while (i < bp_used):
		if (bp_addr(i) != 0):
			bp_disarm(i)
			save_int(bp_addrs + i * 4, 0)
		i = i + 1


void bp_describe(int i):
	print(c"breakpoint ")
	char* digits = itoa(i + 1)
	print(digits)
	free(digits)
	if (bp_is_temp(i)):
		print(c" (temporary)")
	print(c" at ")
	print(dbg_function_name(bp_addr(i)))
	print(c" (")
	dbg_print_file_line(bp_addr(i))
	print(c")")


void bp_list():
	int shown = 0
	int i = 0
	while (i < bp_used):
		if (bp_addr(i) != 0):
			bp_describe(i)
			put_char(10)
			shown = shown + 1
		i = i + 1
	if (shown == 0):
		println(c"no breakpoints set")


# Resolve a breakpoint target the user typed into an absolute address:
#   function        (defined function name)
#   line            (line in current_file, the file of the current stop)
#   file:line       (any path-aligned suffix works as the file)
# Returns 0 when the target does not resolve; the reason is printed.
int bp_resolve_target(char* arg, int current_file):
	if (arg[0] == 0):
		println(c"usage: break <function | line | file:line>")
		return 0

	# file:line splits at the last ':'
	int colon = -1
	int i = 0
	while (arg[i]):
		if (arg[i] == ':'):
			colon = i
		i = i + 1

	int file_index = current_file
	char* line_text = arg
	if (colon >= 0):
		arg[colon] = 0
		line_text = arg + colon + 1
		file_index = dbg_file_index_for(arg)
		if (file_index < 0):
			print(c"unknown file: ")
			println(arg)
			return 0

	# Function name: no colon and not a number
	if (colon < 0):
		if ((arg[0] < '0') | (arg[0] > '9')):
			int f = dbg_global_find(arg)
			if (f < 0):
				print(c"unknown function: ")
				println(arg)
				return 0
			if (dbg_sym_symtype(f) != 2):
				print(c"not a function: ")
				println(arg)
				return 0
			return dbg_sym_address(f)

	int line = atoi(line_text)
	if (line <= 0):
		print(c"bad line number: ")
		println(line_text)
		return 0
	if (file_index < 0):
		println(c"no current file; use file:line")
		return 0
	int entry = dbg_entry_for_line(file_index, line)
	if (entry < 0):
		print(c"no code at ")
		print(dbg_file_name(file_index))
		print(c":")
		println(line_text)
		return 0
	return dbg_line_addr(entry) + code_offset
