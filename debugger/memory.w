/*
Safe memory access for the debugger.

Debugger commands dereference debuggee pointers (string previews, the x
command, stack scans). A bad pointer must not crash wdbg itself, so
dbg_mem_readable probes the pages with the mincore syscall first: an
unmapped range fails with -ENOMEM instead of a SIGSEGV. (Writing the
bytes to /dev/null does not work as a probe: its write handler never
reads the buffer.)
*/
import lib.lib


char* dbg_mincore_vec


void dbg_memory_init():
	# One residency byte per probed page; probes span at most 2 pages
	dbg_mincore_vec = malloc(16)


# 1 when n bytes starting at addr sit on mapped pages.
int dbg_mem_readable(int addr, int n):
	if (dbg_mincore_vec == 0):
		return 0
	int page = addr - (addr & 4095)
	int length = addr + n - page
	if (length > 16 * 4096):
		return 0
	# mincore (218): fails with -ENOMEM when the range is not fully mapped
	return syscall7(218, page, length, dbg_mincore_vec, 0, 0, 0) == 0


# Print a bounded, escaped preview of a C string the debuggee owns, or
# nothing when the pointer is unreadable. Used for char* values.
void dbg_print_string_preview(int addr):
	if (addr == 0):
		return;
	if (dbg_mem_readable(addr, 1) == 0):
		return;
	char* p = addr
	print(c" \x22")
	int i = 0
	while (i < 64):
		if (dbg_mem_readable(addr + i, 1) == 0):
			print(c"\x22...")
			return;
		int c = p[i] & 255
		if (c == 0):
			print(c"\x22")
			return;
		if ((c < 32) | (c > 126)):
			print(c"\x22...")
			return;
		put_char(c)
		i = i + 1
	print(c"\x22...")
