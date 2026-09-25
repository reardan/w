/*
Runtime stack traces.

print_stack_trace() writes a symbolized trace of the calling thread to
stderr:

	stack trace (most recent call first):
	  at middle (tests/stack_trace_test.w:12)
	  at main (tests/stack_trace_test.w:20)

Unwinding follows the frame-pointer chain: every compiled function
opens with push ebp ; mov ebp,esp on x86/x64, and with stp x29,x30,
[x28,#-16]! ; mov x29,x28 on arm64 - the frame lives on the W stack
(be_function_prologue in code_generator/arm64.w) - so [ebp] is the
caller's ebp and [ebp + word] the return address, and the walk
(st_chain) is exact - every frame, in order, nothing stale. On arm64 a
call leaves the return address in x30, so a frameless stub or a
function stopped inside its prologue is missing from the chain; the
crash report adds that frame from the saved x30. The chain ends at main, at a zero ebp (process or
thread start), or where it stops looking like a chain (ebp not
increasing, unmapped, or a return address that is not a call site);
from there, and on images without frame pointers (a binary built by a
pre-frame-pointer compiler such as the seed), unwinding
falls back to the in-process debugger's return-address heuristic
(debugger/wdbg.w dbg_frames_compute, st_scan here): scan stack words
upward from the stack pointer and keep values that point into a
defined function's code and whose preceding bytes decode as one of the
compiler's call forms. st_unwind_exact reports which one produced the
last trace. Functions compiled without the prologue (asm stubs,
generator bodies, REPL entries) keep the caller's ebp: a fault inside
one is resolved by scanning for its return address first, but such a
function in the middle of the chain hides the frame that called it.
The repl_setjmp stub hands the collectors pc, sp and ebp on every
target.

Symbols come from the running binary itself. The ELF targets map the
whole output file - including the .symtab, string table and DWARF
.debug_line sections written by emit_debugging_symbols() - as one
PT_LOAD segment, so everything is parsed in place: the ELF header is
found by walking down one page at a time from a code address (the
image is contiguous, so the walk cannot skip past the header). Mach-O
images (arm64_darwin) are found the same way; their load commands give
the ASLR slide (the mapped header minus __TEXT's vmaddr), the __text
range, and the nlist symbol table the Mach-O writer puts in __LINKEDIT,
which dyld maps too. Mach-O has no line table yet, so darwin frames
carry function names only. arm64 keeps no frame chain, so its traces
always come from the scan; return addresses signed by pointer
authentication are stripped to their address bits first. On targets
without symbols (PE), collection returns no frames and
print_stack_trace() is a silent no-op, so the trap paths that call it
stay safe everywhere.

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
int st_base           /* image base = address of the ELF or Mach-O header */
int st_macho          /* 1 when the image is Mach-O */
int st_slide          /* Mach-O: runtime minus linked addresses */
int st_text_lo        /* Mach-O: __text start (ELF .text starts at st_base) */
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
char* st_scratch      /* number-print scratch: no malloc on the print path */

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


# The number writers share one scratch page so the fatal-signal path
# (lib/crash.w) never allocates; crash_handler_install warms it up
# front with st_scratch_ensure(). The page comes from mmap, NOT malloc:
# lib/memory_debug.w's leak accounting prints through these writers,
# and a malloc'd scratch appearing between two debug_alloc_report_leaks()
# calls would shift exact-leak-delta assertions (raft_ownership_test)
# by one block.
void st_scratch_ensure():
	if (st_scratch == 0):
		int page = mmap(0, 4096, 3, 34) /* RW, PRIVATE|ANONYMOUS */
		if ((page > 0) || (page < -4095)):
			st_scratch = cast(char*, page)


void st_write_dec(int v):
	if (v < 0):
		v = 0
	st_scratch_ensure()
	if (st_scratch == 0):
		return;
	char* buf = st_scratch
	int i = 16
	while (1):
		i = i - 1
		buf[i] = '0' + v - v / 10 * 10
		v = v / 10
		if (v == 0):
			break
	write(2, buf + i, 16 - i)


void st_write_hex(int v):
	int digits = __word_size__ * 2
	st_scratch_ensure()
	if (st_scratch == 0):
		return;
	char* buf = st_scratch
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


# Find the ELF or 64-bit Mach-O header by walking down one page at a
# time from a code address (st_macho says which). A 32-bit Mach-O or PE
# magic or an unmapped page ends the search with 0.
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
		# Mach-O: cf fa ed fe (64-bit) little-endian; PE: "MZ"
		if (b1 == 250):
			if (st_byte(page + 2) == 237):
				if (st_byte(page + 3) == 254):
					if (b0 == 207):
						st_macho = 1
						return page
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


# Parse our own mapped Mach-O image (arm64 only): the slide, __text
# and the LC_SYMTAB nlist table. Leaves st_state at -1 when anything is
# off.
void st_init_macho(int base):
	if (st_int32(base + 4) != 16777228):  /* CPU_TYPE_ARM64 0x0100000c */
		return;
	st_class = 2
	st_machine = 183
	int ncmds = st_int32(base + 16)
	if (st_range_readable(base + 32, st_int32(base + 20)) == 0):
		return;
	int text_vm = 0
	int sect_addr = 0
	int sect_size = 0
	int linkedit_vm = 0
	int linkedit_off = 0
	int symoff = 0
	int nsyms = 0
	int stroff = 0
	int lc = base + 32
	int i = 0
	while (i < ncmds):
		int cmd = st_int32(lc)
		int size = st_int32(lc + 4)
		if (size < 8):
			return;
		if (cmd == 25):  /* LC_SEGMENT_64 */
			if (st_cstr_eq(lc + 8, c"__TEXT")):
				text_vm = st_word(lc + 24)
				if (st_int32(lc + 64) > 0):
					if (st_cstr_eq(lc + 72, c"__text")):
						sect_addr = st_word(lc + 72 + 32)
						sect_size = st_word(lc + 72 + 40)
			else if (st_cstr_eq(lc + 8, c"__LINKEDIT")):
				linkedit_vm = st_word(lc + 24)
				linkedit_off = st_word(lc + 40)
		else if (cmd == 2):  /* LC_SYMTAB */
			symoff = st_int32(lc + 8)
			nsyms = st_int32(lc + 12)
			stroff = st_int32(lc + 16)
		lc = lc + size
		i = i + 1
	if ((text_vm == 0) || (sect_size == 0) || (linkedit_vm == 0) || (nsyms == 0)):
		return;
	st_slide = base - text_vm
	st_text_lo = sect_addr + st_slide
	st_text_hi = st_text_lo + sect_size
	# __LINKEDIT is mapped at its vmaddr; file offsets inside it map
	# relative to its fileoff.
	int linkedit = linkedit_vm + st_slide - linkedit_off
	st_symtab_lo = linkedit + symoff
	st_symtab_count = nsyms
	st_symtab_entsize = 16
	st_strtab_lo = linkedit + stroff
	if (st_range_readable(st_symtab_lo, nsyms * 16) == 0):
		return;
	st_dline_lo = 0
	st_base = base
	st_state = 1


# Parse our own mapped ELF image: .text bounds, .symtab + strings and
# .debug_line. Leaves st_state at -1 when anything is off.
void st_init(int pc):
	st_state = -1
	int base = st_find_base(pc)
	if (base == 0):
		return;
	if (st_macho):
		st_init_macho(base)
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


# Mach-O nlist entries carry no size: the function containing pc is the
# section symbol with the greatest address at or below it, inside
# __text.
int st_macho_func_entry(int pc):
	if ((pc < st_text_lo) || (pc >= st_text_hi)):
		return 0
	int best = 0
	int best_value = 0
	int i = 0
	while (i < st_symtab_count):
		int e = st_symtab_lo + i * 16
		if ((st_byte(e + 4) & 14) == 14):  /* N_SECT */
			int value = st_word(e + 8) + st_slide
			if ((value <= pc) && (value >= best_value)):
				best = e
				best_value = value
		i = i + 1
	return best


# Symbol table entry (its address) of the defined function whose code
# contains pc, or 0. Mirrors dbg_function_at (debugger/symbols.w).
int st_func_entry(int pc):
	if (st_state != 1):
		return 0
	if (st_macho):
		return st_macho_func_entry(pc)
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
	int name = st_strtab_lo + st_int32(e)
	if (st_macho):
		if (st_byte(name) == '_'):
			return name + 1
	return name


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


# An arm64 code address may carry a pointer-authentication signature
# in its high bits (stacked return addresses, and repl_setjmp's resume
# pc under --pac=full); keep the 47 address bits.
int st_code_address(int v):
	if ((__target_isa__ == 1) && (__word_size__ == 8)):
		return v & ((1 << 47) - 1)
	return v


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
		int v = st_code_address(st_word(slot))
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


# 1 when the last st_unwind / st_chain walk followed an intact
# frame-pointer chain to its end (main or a zero ebp); 0 when any part
# of the trace came from the heuristic scan.
int st_unwind_exact
int st_chain_fp       /* last frame pointer st_chain accepted, 0 = none */


# Symbol value (entry address) of a symbol table entry.
int st_entry_value(int e):
	if (st_macho):
		return st_word(e + 8) + st_slide
	if (st_class == 1):
		return st_int32(e + 4)
	return st_word(e + 8)


# Length of the frame-pointer prologue at a function entry (x86:
# 55 89 e5, x64: 55 48 89 e5, arm64: [pacia x30,x28 ;] stp x29,x30,
# [x28,#-16]! ; mov x29,x28), 0 when the function has none.
int st_prologue_len(int addr):
	if (st_machine == 183):
		int k = 0
		if (st_int32(addr) == ((218 << 24) | 12649374)):  /* pacia x30, x28: 0xdac1039e */
			k = 4
		if (st_int32(addr + k) != ((169 << 24) | 12549021)):  /* stp x29, x30, [x28, #-16]!: 0xa9bf7b9d */
			return 0
		if (st_int32(addr + k + 4) != ((170 << 24) | 1836029)):  /* mov x29, x28: 0xaa1c03fd */
			return 0
		return k + 8
	if (st_byte(addr) != 85):
		return 0
	if (st_class == 2):
		if ((st_byte(addr + 1) == 72) && (st_byte(addr + 2) == 137) && (st_byte(addr + 3) == 229)):
			return 4
		return 0
	if ((st_byte(addr + 1) == 137) && (st_byte(addr + 2) == 229)):
		return 3
	return 0


# 1 when the running image keeps frame-pointer chains. The whole image
# comes from one compiler, so probing one of this file's own functions
# answers for all of them.
int st_uses_frame_pointers():
	if (st_state != 1):
		return 0
	if ((st_machine != 3) && (st_machine != 62) && (st_machine != 183)):
		return 0
	return st_prologue_len(st_code_address(cast(int, st_prologue_len))) > 0


# 1 when v is a plausible return address: inside a defined function
# and right after one of the compiler's call forms.
int st_is_return(int v):
	if ((v <= st_base) || (v >= st_text_hi)):
		return 0
	if (st_call_site(v) == 0):
		return 0
	return st_func_entry(v - 1) != 0


void st_out_set(char* out, int k, int v):
	int* slot_out = cast(int*, out + k * __word_size__)
	slot_out[0] = v


int st_is_main_frame(int v):
	int e = st_func_entry(v)
	if (e == 0):
		return 0
	return st_cstr_eq(st_entry_name(e), c"main")


# Follow the frame-pointer chain from fp, appending return addresses
# (minus one, like st_scan) to out after the found entries already
# there. Stops at main, a zero fp, or max. When the chain breaks, the
# rest of the trace comes from st_scan above the last accepted frame
# (or from fallback_sp, dropping hits in skip_entry's function, when
# none was accepted) and st_unwind_exact
# drops to 0. Returns the new count.
int st_chain(int fp, char* out, int found, int max, int fallback_sp, int skip_entry):
	st_chain_fp = 0
	int broken = 0
	while ((found < max) && (broken == 0)):
		if (fp == 0):
			st_unwind_exact = 1
			return found
		if ((fp & (__word_size__ - 1)) != 0):
			broken = 1
		else if (st_range_readable(fp, 2 * __word_size__) == 0):
			broken = 1
		else:
			int v = st_code_address(st_word(fp + __word_size__))
			if (st_is_return(v) == 0):
				broken = 1
			else:
				st_out_set(out, found, v - 1)
				found = found + 1
				st_chain_fp = fp
				if (st_is_main_frame(v - 1)):
					st_unwind_exact = 1
					return found
				int next = st_word(fp)
				if ((next != 0) && (next <= fp)):
					broken = 1
				fp = next
	if (broken == 0):
		st_unwind_exact = 1
		return found
	st_unwind_exact = 0
	if (st_chain_fp == 0):
		return found + st_scan(fallback_sp, out + found * __word_size__, max - found, skip_entry)
	int from = st_chain_fp + 2 * __word_size__
	return found + st_scan(from, out + found * __word_size__, max - found, 0)


# Callers of the code stopped at pc with stack pointer sp and frame
# pointer fp (a signal context), most recent first, each minus one
# like st_scan. Exact on frame-pointer images (st_unwind_exact = 1),
# the heuristic scan otherwise. The trace ends at main.
int st_unwind(int pc, int sp, int fp, char* out, int max):
	st_unwind_exact = 0
	if (st_state != 1):
		return 0
	if (st_uses_frame_pointers() == 0):
		return st_scan(sp, out, max, 0)
	int e = st_func_entry(pc)
	if (e == 0):
		return st_scan(sp, out, max, 0)
	if (st_cstr_eq(st_entry_name(e), c"main")):
		st_unwind_exact = 1
		return 0
	if (max <= 0):
		return 0
	int entry = st_entry_value(e)
	int plen = st_prologue_len(entry)
	int found = 0
	int ret_slot = 0
	if (st_machine == 183):
		# arm64 calls leave the return address in x30, not on the
		# stack, so a frameless stub (or a function stopped before its
		# stp) is not on the chain at all: x29 is still the caller's,
		# and the chain from it starts at the caller's caller. The
		# crash report adds the x30 frame itself. Once the stp has run
		# (pc at the mov), [x28 + 8] holds the return address.
		if ((plen != 0) && (pc == entry + plen - 4)):
			int v2 = st_code_address(st_word(sp + 8))
			if (st_is_return(v2)):
				st_out_set(out, 0, v2 - 1)
				found = 1
				if (st_is_main_frame(v2 - 1)):
					st_unwind_exact = 1
					return found
		return st_chain(fp, out, found, max, sp, 0)
	if (plen == 0):
		# Frameless function: ebp still belongs to its caller, whose
		# frame the chain covers; find this one's return address by
		# scanning (exact enough: it is the first call site above sp).
		found = st_scan(sp, out, 1, 0)
		if (found == 0):
			return 0
		if (st_is_main_frame(st_word(cast(int, out)))):
			return found
		found = st_chain(fp, out, found, max, sp, 0)
		st_unwind_exact = 0
		return found
	if (pc == entry):
		ret_slot = sp  /* before push ebp */
	else if (pc < entry + plen):
		ret_slot = sp + __word_size__  /* after push ebp, before mov */
	if (ret_slot != 0):
		if (st_range_readable(ret_slot, __word_size__) == 0):
			return 0
		int v = st_word(ret_slot)
		if (st_is_return(v) == 0):
			return st_scan(sp, out, max, 0)
		st_out_set(out, 0, v - 1)
		found = 1
		if (st_is_main_frame(v - 1)):
			st_unwind_exact = 1
			return found
	return st_chain(fp, out, found, max, sp, 0)


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


# The collectors' unwind: pc, sp and fp are what repl_setjmp recorded
# inside a collector (its return address into the collector, and the
# collector's own sp and ebp). The collector's ebp starts the chain at
# its caller; without frame pointers the scan skips the collector's
# own stale slots instead.
int st_collect_from(int pc, int sp, int fp, char* out, int max):
	st_unwind_exact = 0
	if (st_uses_frame_pointers()):
		return st_chain(fp, out, 0, max, sp, st_func_entry(pc))
	return st_scan(sp, out, max, st_func_entry(pc))


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
	int pc = st_code_address(st_word(cast(int, st_jmp_buf)))
	int sp = st_word(cast(int, st_jmp_buf) + __word_size__)
	int fp = st_word(cast(int, st_jmp_buf) + 2 * __word_size__)
	if (st_state == 0):
		st_init(pc)
	return st_collect_from(pc, sp, fp, out, max)


# Runtime address of the defined function called name, or 0. A linear
# walk of the symbol table: for setup paths, not per-frame work.
int st_symbol_address(char* name):
	if (st_state != 1):
		return 0
	int i = 0
	if (st_macho == 0):
		i = 1
	while (i < st_symtab_count):
		int e = st_symtab_lo + i * st_symtab_entsize
		if (st_cstr_eq(st_entry_name(e), name)):
			return st_entry_value(e)
		i = i + 1
	return 0


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
	int pc = st_code_address(st_word(cast(int, st_jmp_buf)))
	int sp = st_word(cast(int, st_jmp_buf) + __word_size__)
	int fp = st_word(cast(int, st_jmp_buf) + 2 * __word_size__)
	if (st_state == 0):
		st_init(pc)
	char* pcs = malloc(64 * __word_size__)
	int n = st_collect_from(pc, sp, fp, pcs, 64)
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
