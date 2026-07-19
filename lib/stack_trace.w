/*
Runtime stack traces.

print_stack_trace() writes a symbolized trace of the calling thread to
stderr:

	stack trace (most recent call first):
	  at middle (tests/stack_trace_test.w:12)
	  at main (tests/stack_trace_test.w:20)

Unwinding uses the in-process debugger's return-address heuristic
(debugger/wdbg.w dbg_frames_compute): scan stack words upward from the
current stack pointer and keep values that point into a defined
function's code and whose preceding bytes decode as one of the
compiler's call forms. There are no frame pointers to follow; the
calling convention keeps return addresses on the W stack (x86/x64: the
machine stack, arm64: the x28 data stack) and the repl_setjmp stub
hands us that pointer on every target.

Symbols come from the running binary itself. The ELF targets map the
whole output file - including the .symtab, string table and DWARF
.debug_line sections written by emit_debugging_symbols() - as one
PT_LOAD segment, so everything is parsed in place: the ELF header is
found by walking down one page at a time from a code address (the
image is contiguous, so the walk cannot skip past the header). On
targets without those sections (Mach-O, PE) or under arm64 pointer
authentication (stacked return addresses are signed), collection
returns no frames and print_stack_trace() is a silent no-op, so the
trap paths that call it stay safe everywhere.

Every probe of not-known-mapped memory goes through mincore() first
(the trick from debugger/memory.w), so scanning past the top of the
stack or below the image start cannot fault.

This file is reachable from the container runtime's trap paths
(structures/w_list.w) and lib/assert.w, which puts it in the seed's
import graph: seed-era syntax only.
*/
import lib.memory


# Parsed image state: 0 = not yet parsed, 1 = ready, -1 = unavailable.
int st_state
int st_base           /* image base = address of the ELF header */
int st_machine        /* e_machine: 3 x86, 62 x86-64, 183 arm64 */
int st_class          /* 1 = ELFCLASS32, 2 = ELFCLASS64 */
int st_text_hi        /* .text end; .text starts at st_base */
int st_symtab_lo      /* first .symtab entry */
int st_symtab_count
int st_symtab_entsize
int st_strtab_lo      /* symbol name strings */
int st_dline_lo       /* .debug_line payload, 0 when absent */
int st_dline_size
char* st_mincore_vec
char* st_jmp_buf

# DWARF line-program results (globals: no out parameters in W).
int st_cursor
int st_line_found
int st_file_found


int st_word(int addr):
	int* w = cast(int*, addr)
	return w[0]


int st_byte(int addr):
	char* p = cast(char*, addr)
	return p[0] & 255


int st_int16(int addr):
	return st_byte(addr) | (st_byte(addr + 1) << 8)


int st_int32(int addr):
	return st_byte(addr) | (st_byte(addr + 1) << 8) | (st_byte(addr + 2) << 16) | (st_byte(addr + 3) << 24)


# 1 when the page holding addr is mapped: mincore fails with -ENOMEM on
# an unmapped range instead of faulting like a read would.
int st_page_readable(int addr):
	if (st_mincore_vec == 0):
		st_mincore_vec = malloc(16)
	int page = addr - (addr & 4095)
	return sys_mincore(page, 1, cast(int, st_mincore_vec)) == 0


int st_range_readable(int addr, int length):
	if (length <= 0):
		return 0
	int p = addr - (addr & 4095)
	while (p < addr + length):
		if (st_page_readable(p) == 0):
			return 0
		p = p + 4096
	return 1


void st_write_cstr(char* s):
	int n = 0
	while (s[n]):
		n = n + 1
	write(2, s, n)


void st_write_dec(int v):
	if (v < 0):
		v = 0
	char* buf = malloc(16)
	int i = 16
	while (1):
		i = i - 1
		buf[i] = '0' + v - v / 10 * 10
		v = v / 10
		if (v == 0):
			break
	write(2, buf + i, 16 - i)
	free(buf)


void st_write_hex(int v):
	int digits = __word_size__ * 2
	char* buf = malloc(2 + digits)
	buf[0] = '0'
	buf[1] = 'x'
	int i = 0
	while (i < digits):
		int nibble = (v >> ((digits - 1 - i) * 4)) & 15
		if (nibble < 10):
			buf[2 + i] = '0' + nibble
		else:
			buf[2 + i] = 'a' + nibble - 10
		i = i + 1
	write(2, buf, 2 + digits)
	free(buf)


int st_cstr_eq(int a, char* b):
	char* pa = cast(char*, a)
	int i = 0
	while (1):
		int ca = pa[i] & 255
		int cb = b[i] & 255
		if (ca != cb):
			return 0
		if (ca == 0):
			return 1
		i = i + 1


# Find the ELF header by walking down one page at a time from a code
# address. A Mach-O or PE magic (no debug sections there) or an
# unmapped page ends the search with 0.
int st_find_base(int pc):
	int page = pc - (pc & 4095)
	int guard = 65536
	while (guard > 0):
		if (st_page_readable(page) == 0):
			return 0
		int b0 = st_byte(page)
		int b1 = st_byte(page + 1)
		if (b0 == 127):
			if (b1 == 'E'):
				if (st_byte(page + 2) == 'L'):
					if (st_byte(page + 3) == 'F'):
						return page
		# Mach-O: xx fa ed fe little-endian; PE: "MZ"
		if (b1 == 250):
			if (st_byte(page + 2) == 237):
				if (st_byte(page + 3) == 254):
					return 0
		if (b0 == 'M'):
			if (b1 == 'Z'):
				return 0
		page = page - 4096
		guard = guard - 1
	return 0


# Section header field at the class-dependent offset (32-/64-bit ELF).
int st_sh_word(int header, int off32, int off64):
	if (st_class == 1):
		return st_int32(header + off32)
	return st_word(header + off64)


# Parse our own mapped ELF image: .text bounds, .symtab + strings and
# .debug_line. Leaves st_state at -1 when anything is off.
void st_init(int pc):
	st_state = -1
	int base = st_find_base(pc)
	if (base == 0):
		return;
	if (st_byte(base + 4) != __word_size__ / 4):
		return;
	st_class = st_byte(base + 4)
	st_machine = st_int16(base + 18)
	int shoff = 0
	int shentsize = 0
	int shnum = 0
	int shstrndx = 0
	if (st_class == 1):
		shoff = st_int32(base + 32)
		shentsize = st_int16(base + 46)
		shnum = st_int16(base + 48)
		shstrndx = st_int16(base + 50)
	else:
		shoff = st_word(base + 40)
		shentsize = st_int16(base + 58)
		shnum = st_int16(base + 60)
		shstrndx = st_int16(base + 62)
	if (shoff <= 0):
		return;
	if ((shnum < 2) || (shnum > 100)):
		return;
	if ((shentsize < 40) || (shentsize > 128)):
		return;
	if (shstrndx >= shnum):
		return;
	int table = base + shoff
	if (st_range_readable(table, shnum * shentsize) == 0):
		return;
	int shstr = base + st_sh_word(table + shstrndx * shentsize, 16, 24)
	if (st_page_readable(shstr) == 0):
		return;
	int text_seen = 0
	int i = 1
	while (i < shnum):
		int header = table + i * shentsize
		int sh_type = st_int32(header + 4)
		int name_addr = shstr + st_int32(header)
		if (sh_type == 2):
			st_symtab_lo = base + st_sh_word(header, 16, 24)
			int entsize = 16
			if (st_class == 2):
				entsize = 24
			st_symtab_entsize = entsize
			st_symtab_count = st_sh_word(header, 20, 32) / entsize
			int link_off = 24
			if (st_class == 2):
				link_off = 40
			int link = st_int32(header + link_off)
			if (link < shnum):
				st_strtab_lo = base + st_sh_word(table + link * shentsize, 16, 24)
		else if (st_cstr_eq(name_addr, c".text")):
			st_text_hi = st_sh_word(header, 12, 16) + st_sh_word(header, 20, 32)
			text_seen = 1
		else if (st_cstr_eq(name_addr, c".debug_line")):
			st_dline_lo = base + st_sh_word(header, 16, 24)
			st_dline_size = st_sh_word(header, 20, 32)
		i = i + 1
	if (text_seen == 0):
		return;
	if (st_symtab_lo == 0):
		return;
	if (st_strtab_lo == 0):
		return;
	if (st_range_readable(st_symtab_lo, st_symtab_count * st_symtab_entsize) == 0):
		return;
	if (st_dline_lo != 0):
		if (st_range_readable(st_dline_lo, st_dline_size) == 0):
			st_dline_lo = 0
	st_base = base
	st_state = 1


# Symbol table entry (its address) of the defined function whose code
# contains pc, or 0. Mirrors dbg_function_at (debugger/symbols.w).
int st_func_entry(int pc):
	if (st_state != 1):
		return 0
	int i = 1
	while (i < st_symtab_count):
		int e = st_symtab_lo + i * st_symtab_entsize
		int info = 0
		int value = 0
		int size = 0
		if (st_class == 1):
			info = st_byte(e + 12)
			value = st_int32(e + 4)
			size = st_int32(e + 8)
		else:
			info = st_byte(e + 4)
			value = st_word(e + 8)
			size = st_word(e + 16)
		if ((info & 15) == 2):
			if (size > 0):
				if (pc >= value):
					if (pc < value + size):
						return e
		i = i + 1
	return 0


int st_entry_name(int e):
	return st_strtab_lo + st_int32(e)


# 1 when the bytes before the return address v decode as one of the
# compiler's call forms; mirrors dbg_looks_like_return (wdbg.w).
int st_call_site(int v):
	if ((st_machine == 3) || (st_machine == 62)):
		if (v - 5 < st_base):
			return 0
		if ((st_byte(v - 2) == 255) & (st_byte(v - 1) == 208)):
			return 1 /* call *eax / call *rax */
		if (st_byte(v - 5) == 232):
			return 1 /* call rel32 (asm stubs) */
		return 0
	if (st_machine == 183):
		if (v - 4 < st_base):
			return 0
		if ((st_byte(v - 2) == 63) & (st_byte(v - 1) == 214)):
			return 1 /* blr xN */
		if ((st_byte(v - 1) & 252) == 148):
			return 1 /* bl imm26 */
	return 0


# Scan stack words upward from sp for return addresses, storing each
# hit minus one (an address inside the calling statement) into out.
# Hits into the function owning skip_entry are dropped: the scan starts
# inside the collector's own frame, where stale return addresses from
# its completed calls still sit. Stops at max hits, at main's frame, or
# at the first unmapped page.
int st_scan(int sp, char* out, int max, int skip_entry):
	if (st_state != 1):
		return 0
	int found = 0
	int probed_page = 1
	int i = 0
	while (i < 65536):
		int slot = sp + i * __word_size__
		int page = slot - (slot & 4095)
		if (page != probed_page):
			if (st_page_readable(slot) == 0):
				return found
			probed_page = page
		int v = st_word(slot)
		if (v > st_base):
			if (v < st_text_hi):
				if (st_call_site(v)):
					int e = st_func_entry(v - 1)
					if (e != 0):
						if (e != skip_entry):
							int* slot_out = cast(int*, out + found * __word_size__)
							slot_out[0] = v - 1
							found = found + 1
							if (found >= max):
								return found
							if (st_cstr_eq(st_entry_name(e), c"main")):
								return found
		i = i + 1
	return found


int st_uleb():
	int result = 0
	int shift = 0
	while (1):
		int b = st_byte(st_cursor)
		st_cursor = st_cursor + 1
		result = result | ((b & 127) << shift)
		if ((b & 128) == 0):
			return result
		shift = shift + 7


int st_sleb():
	int result = 0
	int shift = 0
	while (1):
		int b = st_byte(st_cursor)
		st_cursor = st_cursor + 1
		result = result | ((b & 127) << shift)
		shift = shift + 7
		if ((b & 128) == 0):
			if (b & 64):
				if (shift < __word_size__ * 8):
					result = result | (0 - (1 << shift))
			return result


void st_skip_cstr():
	while (st_byte(st_cursor) != 0):
		st_cursor = st_cursor + 1
	st_cursor = st_cursor + 1


/* .debug_line header layout (DWARF 2, as written by debug_line_emit):
   +0 unit_length(4) +4 version(2) +6 header_length(4) +10 min_inst(1)
   +11 default_is_stmt(1) +12 line_base(1) +13 line_range(1)
   +14 opcode_base(1) +15 standard opcode lengths... */


# Run the line program and record the row with the largest address not
# above pc into st_line_found/st_file_found. Returns 1 on a match.
int st_line_lookup(int pc):
	st_line_found = 0
	st_file_found = 0
	if (st_state != 1):
		return 0
	if (st_dline_lo == 0):
		return 0
	int unit_length = st_int32(st_dline_lo)
	if ((unit_length < 16) || (unit_length + 4 > st_dline_size)):
		return 0
	if (st_int16(st_dline_lo + 4) != 2):
		return 0
	int unit_end = st_dline_lo + 4 + unit_length
	int min_inst = st_byte(st_dline_lo + 10)
	int line_base = st_byte(st_dline_lo + 12)
	if (line_base > 127):
		line_base = line_base - 256
	int line_range = st_byte(st_dline_lo + 13)
	int opcode_base = st_byte(st_dline_lo + 14)
	if (line_range == 0):
		return 0
	st_cursor = st_dline_lo + 10 + st_int32(st_dline_lo + 6)
	int address = 0
	int file = 1
	int line = 1
	int best_addr = -1
	while (st_cursor < unit_end):
		int op = st_byte(st_cursor)
		st_cursor = st_cursor + 1
		if (op == 0):
			int len = st_uleb()
			int next = st_cursor + len
			int sub = st_byte(st_cursor)
			if (sub == 1):
				/* end_sequence: reset the registers */
				address = 0
				file = 1
				line = 1
			else if (sub == 2):
				/* set_address: len-1 little-endian bytes */
				address = 0
				int k = 0
				while (k < len - 1):
					address = address | (st_byte(st_cursor + 1 + k) << (k * 8))
					k = k + 1
			st_cursor = next
		else if (op < opcode_base):
			if (op == 1):
				/* copy: emit a row */
				if (address <= pc):
					if (address > best_addr):
						best_addr = address
						st_line_found = line
						st_file_found = file
			else if (op == 2):
				address = address + st_uleb() * min_inst
			else if (op == 3):
				line = line + st_sleb()
			else if (op == 4):
				file = st_uleb()
			else if (op == 5):
				st_uleb() /* set_column */
			else if (op == 8):
				address = address + (255 - opcode_base) / line_range * min_inst
			else if (op == 9):
				address = address + st_int16(st_cursor)
				st_cursor = st_cursor + 2
			/* 6 negate_stmt and 7 basic_block take no operands */
		else:
			/* special opcode: advance address and line, emit a row */
			int adjusted = op - opcode_base
			address = address + adjusted / line_range * min_inst
			line = line + line_base + adjusted - adjusted / line_range * line_range
			if (address <= pc):
				if (address > best_addr):
					best_addr = address
					st_line_found = line
					st_file_found = file
	if (best_addr < 0):
		return 0
	return 1


# Name (address of a C string) of 1-based file number index in the
# .debug_line file table, or 0.
int st_file_name(int index):
	if (index < 1):
		return 0
	if (st_dline_lo == 0):
		return 0
	int opcode_base = st_byte(st_dline_lo + 14)
	st_cursor = st_dline_lo + 15 + opcode_base - 1
	while (st_byte(st_cursor) != 0):
		st_skip_cstr() /* include directories */
	st_cursor = st_cursor + 1
	int n = 1
	while (st_byte(st_cursor) != 0):
		int name = st_cursor
		st_skip_cstr()
		st_uleb()
		st_uleb()
		st_uleb()
		if (n == index):
			return name
		n = n + 1
	return 0


############################ public API ############################

# Fill out (word-sized slots) with up to max stack addresses, most
# recent call first, starting with the caller of this function. Each
# value points inside the calling statement, ready for
# stack_trace_symbol/line/file. Returns the number collected: 0 when
# the binary carries no readable symbols (Mach-O, PE) or the stack
# cannot be unwound.
int stack_trace_collect(char* out, int max):
	if (st_jmp_buf == 0):
		st_jmp_buf = malloc(3 * __word_size__)
	repl_setjmp(st_jmp_buf)
	int pc = st_word(cast(int, st_jmp_buf))
	int sp = st_word(cast(int, st_jmp_buf) + __word_size__)
	if (st_state == 0):
		st_init(pc)
	return st_scan(sp, out, max, st_func_entry(pc))


# Name of the defined function whose code contains pc, or 0.
char* stack_trace_symbol(int pc):
	int e = st_func_entry(pc)
	if (e == 0):
		return cast(char*, 0)
	return cast(char*, st_entry_name(e))


# 1-based source line for pc, or 0 when unknown.
int stack_trace_line(int pc):
	if (st_line_lookup(pc)):
		return st_line_found
	return 0


# Source file name for pc, or 0 when unknown.
char* stack_trace_file(int pc):
	if (st_line_lookup(pc)):
		return cast(char*, st_file_name(st_file_found))
	return cast(char*, 0)


# Write a symbolized stack trace of the calling thread to stderr, or
# nothing when no frames can be recovered.
void print_stack_trace():
	if (st_jmp_buf == 0):
		st_jmp_buf = malloc(3 * __word_size__)
	repl_setjmp(st_jmp_buf)
	int pc = st_word(cast(int, st_jmp_buf))
	int sp = st_word(cast(int, st_jmp_buf) + __word_size__)
	if (st_state == 0):
		st_init(pc)
	char* pcs = malloc(64 * __word_size__)
	int n = st_scan(sp, pcs, 64, st_func_entry(pc))
	if (n == 0):
		free(pcs)
		return;
	st_write_cstr(c"stack trace (most recent call first):\n")
	int k = 0
	while (k < n):
		int addr = st_word(cast(int, pcs) + k * __word_size__)
		st_write_cstr(c"  at ")
		int e = st_func_entry(addr)
		if (e != 0):
			st_write_cstr(cast(char*, st_entry_name(e)))
		else:
			st_write_hex(addr)
		if (st_line_lookup(addr)):
			st_write_cstr(c" (")
			int fname = st_file_name(st_file_found)
			if (fname != 0):
				st_write_cstr(cast(char*, fname))
				st_write_cstr(c":")
			st_write_dec(st_line_found)
			st_write_cstr(c")")
		st_write_cstr(c"\n")
		k = k + 1
	free(pcs)
