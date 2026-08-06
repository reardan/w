/*
wcore: Linux core-dump processor for W binaries (issue #378's tooling half).

Usage: wcore [--json] <core> <binary>

Reads an ET_CORE ELF core file of a W-compiled x86 or x86-64 Linux
binary next to the binary that produced it and prints:

  * the fatal signal and the thread's registers, from the core's
    PT_NOTE segment (NT_PRSTATUS; NT_SIGINFO adds the si_code and the
    faulting address when the kernel recorded them),
  * the faulting pc symbolized to "function (file:line)", and
  * a heuristic backtrace: the same return-address scan the live
    tracer uses (lib/stack_trace.w st_scan), reading stack words from
    the core's PT_LOAD segments instead of live memory.

The word size is detected from the core's ELF class, so one (64-bit)
wcore build processes both 32- and 64-bit cores.

Symbolization reuses lib/stack_trace.w's .symtab/.debug_line lookups
(st_func_entry / st_line_lookup / st_file_name). Those functions read
section bytes at file offsets from the image base and compare pc values
against the absolute target addresses stored in the sections, so they
work unchanged when the "image" is the on-disk binary loaded into a
malloc'd buffer: this file parses the binary's section headers itself
(st_init assumes the running image's class) and points the st_* globals
at the buffer. A binary without .symtab degrades to raw addresses; a
missing .debug_line drops only the file:line part.

Code bytes for the call-site decode come from the binary file (a
kernel core normally omits the read-only text mapping), located through
the binary's program headers; stack words come from the core's PT_LOAD
segments. Like the live tracer, the innermost frame (the faulting pc)
is exact and every older frame is heuristic: a stale stack slot that
still looks like a return address can add a frame, and a frame can be
missing.

There is no build-id in W binaries, so wcore cannot detect a wrong
same-architecture binary; passing one yields wrong names, exactly like
attach mode before its calibration. Cross-checks that are possible
(ELF class and machine of core vs. binary) are enforced.

--json prints one JSON object on one line instead of the human report.

Exit status: 0 on success, 1 on a processing error, 2 on usage errors.
This is a leaf tool (not in the seed's import graph); built as a 64-bit
binary by the wcore target so 64-bit core addresses fit in int.
*/
import lib.lib
import lib.stack_trace


# --- state ---
int wc_json           /* 1 when --json */
char* wc_core_path
char* wc_bin_path
int wc_core_buf       /* whole core file in memory (address) */
int wc_core_size
int wc_bin_buf        /* whole binary file in memory (address) */
int wc_bin_size
int wc_class          /* 1 = ELFCLASS32, 2 = ELFCLASS64 (core and binary) */
int wc_machine        /* 3 = x86, 62 = x86-64 */
int wc_wsize          /* target word size: 4 or 8 */

int wc_core_phoff
int wc_core_phentsize
int wc_core_phnum
int wc_bin_phoff
int wc_bin_phentsize
int wc_bin_phnum

int wc_text_lo        /* .text address range in the binary */
int wc_text_hi
int wc_have_syms      /* 1 when the binary's .symtab/.strtab parsed */

int wc_prstatus       /* address of the first NT_PRSTATUS desc, 0 = none */
int wc_prstatus_size
int wc_siginfo        /* address of the NT_SIGINFO desc, 0 = none */
int wc_siginfo_size

int wc_sig            /* fatal signal number, 0 = none recorded */
int wc_pc
int wc_sp
int wc_read_ok        /* last wc_core_word read hit dumped memory */

int wc_frames_max():
	return 64


# --- little-endian field readers ---
# st_byte/st_int16/st_int32/st_word (lib/stack_trace.w) read at absolute
# addresses; wcore points them into its file buffers. st_int32 builds the
# value from masked bytes, so 32-bit fields stay non-negative in wcore's
# 64-bit int. st_word reads 8 bytes only on the 64-bit build this tool
# ships as (the wcore target compiles with the x64 selector).

# A class-dependent word field (Elf32/Elf64 layouts).
int wc_field(int addr):
	if (wc_class == 2):
		return st_word(addr)
	return st_int32(addr)


# --- ELF header accessors (b = image base address) ---
int wc_eh_type(int b):
	return st_int16(b + 16)


int wc_eh_machine(int b):
	return st_int16(b + 18)


int wc_eh_phoff(int b):
	if (wc_class == 2):
		return st_word(b + 32)
	return st_int32(b + 28)


int wc_eh_phentsize(int b):
	if (wc_class == 2):
		return st_int16(b + 54)
	return st_int16(b + 42)


int wc_eh_phnum(int b):
	if (wc_class == 2):
		return st_int16(b + 56)
	return st_int16(b + 44)


int wc_eh_shoff(int b):
	if (wc_class == 2):
		return st_word(b + 40)
	return st_int32(b + 32)


int wc_eh_shentsize(int b):
	if (wc_class == 2):
		return st_int16(b + 58)
	return st_int16(b + 46)


int wc_eh_shnum(int b):
	if (wc_class == 2):
		return st_int16(b + 60)
	return st_int16(b + 48)


int wc_eh_shstrndx(int b):
	if (wc_class == 2):
		return st_int16(b + 62)
	return st_int16(b + 50)


# --- program header accessors (p = header address) ---
int wc_ph_type(int p):
	return st_int32(p)


int wc_ph_offset(int p):
	if (wc_class == 2):
		return st_word(p + 8)
	return st_int32(p + 4)


int wc_ph_vaddr(int p):
	if (wc_class == 2):
		return st_word(p + 16)
	return st_int32(p + 8)


int wc_ph_filesz(int p):
	if (wc_class == 2):
		return st_word(p + 32)
	return st_int32(p + 16)


# --- file loading ---
int wc_read_size

# Whole file into a malloc'd buffer; returns its address or 0.
int wc_load_file(char* path):
	int f = open(path, 0, 0)
	if (f < 0):
		return 0
	int size = file_size(f)
	if (size <= 0):
		close(f)
		return 0
	char* buf = malloc(size)
	int got = 0
	while (got < size):
		int r = read(f, &buf[got], size - got)
		if (r <= 0):
			close(f)
			free(buf)
			return 0
		got = got + r
	close(f)
	wc_read_size = size
	return cast(int, buf)


int wc_is_elf(int b, int size):
	if (size < 52):
		return 0
	if (st_byte(b) != 127):
		return 0
	if (st_byte(b + 1) != 'E'):
		return 0
	if (st_byte(b + 2) != 'L'):
		return 0
	if (st_byte(b + 3) != 'F'):
		return 0
	return 1


# --- core memory (PT_LOAD segments of the core file) ---
# Buffer address of the n bytes at target address vaddr, or 0 when that
# range was not dumped (a kernel core records p_filesz = 0 for mappings
# excluded by coredump_filter, e.g. the file-backed text).
int wc_core_mem(int vaddr, int n):
	int i = 0
	while (i < wc_core_phnum):
		int p = wc_core_buf + wc_core_phoff + i * wc_core_phentsize
		if (wc_ph_type(p) == 1):
			int lo = wc_ph_vaddr(p)
			int fsz = wc_ph_filesz(p)
			int off = wc_ph_offset(p)
			if ((off >= 0) && (off + fsz <= wc_core_size)):
				if ((vaddr >= lo) && (vaddr + n <= lo + fsz)):
					return wc_core_buf + off + (vaddr - lo)
		i = i + 1
	return 0


# Target-word-sized read from dumped memory; sets wc_read_ok.
int wc_core_word(int vaddr):
	int a = wc_core_mem(vaddr, wc_wsize)
	if (a == 0):
		wc_read_ok = 0
		return 0
	wc_read_ok = 1
	if (wc_class == 2):
		return st_word(a)
	return st_int32(a)


# --- code bytes (binary file first, dumped memory as fallback) ---
# W's ELF backends map file offset 0 at the load base in one text
# segment, so byte i of the file is process byte p_vaddr + i; going
# through the binary's program headers keeps this exact for any layout.
int wc_code_byte(int vaddr):
	int i = 0
	while (i < wc_bin_phnum):
		int p = wc_bin_buf + wc_bin_phoff + i * wc_bin_phentsize
		if (wc_ph_type(p) == 1):
			int lo = wc_ph_vaddr(p)
			int fsz = wc_ph_filesz(p)
			int off = wc_ph_offset(p)
			if ((off >= 0) && (off + fsz <= wc_bin_size)):
				if ((vaddr >= lo) && (vaddr < lo + fsz)):
					return st_byte(wc_bin_buf + off + (vaddr - lo))
		i = i + 1
	int a = wc_core_mem(vaddr, 1)
	if (a != 0):
		return st_byte(a)
	return -1


# --- core note parsing (NT_PRSTATUS, NT_SIGINFO) ---
# Notes are 4-byte aligned in both ELF classes on Linux. The first
# NT_PRSTATUS is the faulting thread (the kernel writes it first).
void wc_parse_notes():
	int i = 0
	while (i < wc_core_phnum):
		int p = wc_core_buf + wc_core_phoff + i * wc_core_phentsize
		if (wc_ph_type(p) == 4):
			int off = wc_ph_offset(p)
			int fsz = wc_ph_filesz(p)
			if ((off < 0) || (off + fsz > wc_core_size)):
				i = i + 1
				continue
			int cur = wc_core_buf + off
			int end = cur + fsz
			while (cur + 12 <= end):
				int namesz = st_int32(cur)
				int descsz = st_int32(cur + 4)
				int ntype = st_int32(cur + 8)
				int name = cur + 12
				int desc = name + (namesz + 3) / 4 * 4
				if ((desc + descsz > end) || (descsz < 0) || (namesz < 0)):
					break
				int is_core_note = 0
				if (namesz >= 5):
					if (st_cstr_eq(name, c"CORE")):
						is_core_note = 1
				if (is_core_note):
					if ((ntype == 1) && (wc_prstatus == 0)):
						wc_prstatus = desc
						wc_prstatus_size = descsz
					if ((ntype == 0x53494749) && (wc_siginfo == 0)):
						wc_siginfo = desc
						wc_siginfo_size = descsz
				cur = desc + (descsz + 3) / 4 * 4
		i = i + 1


# --- registers (elf_prstatus.pr_reg, user_regs_struct layout) ---
# Offsets per arch/x86 struct elf_prstatus: pr_reg at 72 (i386, 17
# 4-byte regs) / 112 (x86-64, 27 8-byte regs). The in-register order is
# the ptrace user_regs_struct one, the same layout debugger/attach.w
# reads via PTRACE_GETREGS (ip at word 12/16, sp at word 15/19).
int wc_prreg_off():
	if (wc_class == 2):
		return 112
	return 72


int wc_prreg_count():
	if (wc_class == 2):
		return 27
	return 17


int wc_reg(int index):
	return wc_field(wc_prstatus + wc_prreg_off() + index * wc_wsize)


int wc_pc_index():
	if (wc_class == 2):
		return 16 /* rip */
	return 12 /* eip */


int wc_sp_index():
	if (wc_class == 2):
		return 19 /* rsp */
	return 15 /* esp */


# The registers the report shows, in the same order attach mode's
# 'registers' command prints them (debugger/attach.w at_print_registers).
int wc_reg_print_count():
	if (wc_class == 2):
		return 18
	return 10


char* wc_reg_print_name(int k):
	if (wc_class == 2):
		if (k == 0):
			return c"rax"
		if (k == 1):
			return c"rbx"
		if (k == 2):
			return c"rcx"
		if (k == 3):
			return c"rdx"
		if (k == 4):
			return c"rsi"
		if (k == 5):
			return c"rdi"
		if (k == 6):
			return c"rbp"
		if (k == 7):
			return c"rsp"
		if (k == 8):
			return c"r8"
		if (k == 9):
			return c"r9"
		if (k == 10):
			return c"r10"
		if (k == 11):
			return c"r11"
		if (k == 12):
			return c"r12"
		if (k == 13):
			return c"r13"
		if (k == 14):
			return c"r14"
		if (k == 15):
			return c"r15"
		if (k == 16):
			return c"rip"
		return c"eflags"
	if (k == 0):
		return c"eax"
	if (k == 1):
		return c"ebx"
	if (k == 2):
		return c"ecx"
	if (k == 3):
		return c"edx"
	if (k == 4):
		return c"esi"
	if (k == 5):
		return c"edi"
	if (k == 6):
		return c"ebp"
	if (k == 7):
		return c"esp"
	if (k == 8):
		return c"eip"
	return c"eflags"


int wc_reg_print_index(int k):
	if (wc_class == 2):
		if (k == 0):
			return 10 /* rax */
		if (k == 1):
			return 5 /* rbx */
		if (k == 2):
			return 11 /* rcx */
		if (k == 3):
			return 12 /* rdx */
		if (k == 4):
			return 13 /* rsi */
		if (k == 5):
			return 14 /* rdi */
		if (k == 6):
			return 4 /* rbp */
		if (k == 7):
			return 19 /* rsp */
		if (k == 8):
			return 9 /* r8 */
		if (k == 9):
			return 8 /* r9 */
		if (k == 10):
			return 7 /* r10 */
		if (k == 11):
			return 6 /* r11 */
		if (k == 12):
			return 3 /* r12 */
		if (k == 13):
			return 2 /* r13 */
		if (k == 14):
			return 1 /* r14 */
		if (k == 15):
			return 0 /* r15 */
		if (k == 16):
			return 16 /* rip */
		return 18 /* eflags */
	if (k == 0):
		return 6 /* eax */
	if (k == 1):
		return 0 /* ebx */
	if (k == 2):
		return 1 /* ecx */
	if (k == 3):
		return 2 /* edx */
	if (k == 4):
		return 3 /* esi */
	if (k == 5):
		return 4 /* edi */
	if (k == 6):
		return 5 /* ebp */
	if (k == 7):
		return 15 /* esp */
	if (k == 8):
		return 12 /* eip */
	return 14 /* eflags */


# --- signal info ---
char* wc_signal_name(int sig):
	if (sig == 3):
		return c"SIGQUIT"
	if (sig == 4):
		return c"SIGILL"
	if (sig == 5):
		return c"SIGTRAP"
	if (sig == 6):
		return c"SIGABRT"
	if (sig == 7):
		return c"SIGBUS"
	if (sig == 8):
		return c"SIGFPE"
	if (sig == 11):
		return c"SIGSEGV"
	return c"unknown"


# The parenthetical the human report appends, mirroring lib/crash.w's
# crash_signal_name text for the signals both tools describe.
char* wc_signal_desc(int sig):
	if (sig == 4):
		return c"illegal instruction"
	if (sig == 6):
		return c"abort"
	if (sig == 7):
		return c"bus error"
	if (sig == 8):
		return c"arithmetic exception"
	if (sig == 11):
		return c"invalid memory reference"
	return cast(char*, 0)


int wc_have_fault():
	if (wc_siginfo == 0):
		return 0
	if ((wc_sig == 4) || (wc_sig == 7) || (wc_sig == 8) || (wc_sig == 11)):
		return 1
	return 0


# siginfo_t: si_signo +0, si_errno +4, si_code +8; the fault address
# union member starts at +12 (32-bit) / +16 (64-bit, 8-byte aligned).
int wc_fault_addr():
	if (wc_class == 2):
		return st_word(wc_siginfo + 16)
	return st_int32(wc_siginfo + 12)


int wc_si_code():
	return st_int32(wc_siginfo + 8)


# --- backtrace: the live tracer's return-address scan over core memory ---
# Port of lib/stack_trace.w st_scan/st_call_site: scan stack words
# upward from sp, keep values that point into the binary's .text and
# whose preceding bytes decode as one of the compiler's call forms
# (call *eax / call *rax, or call rel32 in asm stubs), stop at main's
# frame or the end of the dumped stack segment.
int wc_call_site(int v):
	if (v - 5 < wc_text_lo):
		return 0
	if ((wc_code_byte(v - 2) == 255) && (wc_code_byte(v - 1) == 208)):
		return 1
	if (wc_code_byte(v - 5) == 232):
		return 1
	return 0


int wc_scan(int sp, char* out, int max):
	int found = 0
	int i = 0
	while (i < 65536):
		int slot = sp + i * wc_wsize
		int v = wc_core_word(slot)
		if (wc_read_ok == 0):
			return found
		if ((v > wc_text_lo) && (v < wc_text_hi)):
			if (wc_call_site(v)):
				int keep = 1
				int e = 0
				if (wc_have_syms):
					e = st_func_entry(v - 1)
					if (e == 0):
						keep = 0
				if (keep):
					save_word(&out[found * __word_size__], v - 1)
					found = found + 1
					if (found >= max):
						return found
					if (e != 0):
						if (st_cstr_eq(st_entry_name(e), c"main")):
							return found
		i = i + 1
	return found


# --- binary section parsing (points lib/stack_trace.w at the buffer) ---
# Mirrors st_init, minus its this-image class check: st_class is the
# CORE'S class here, not the running tool's, so the shared lookups
# decode the right symbol-entry layout for either word size.
void wc_parse_bin_sections():
	int b = wc_bin_buf
	st_class = wc_class
	st_machine = wc_machine
	int shoff = wc_eh_shoff(b)
	int shentsize = wc_eh_shentsize(b)
	int shnum = wc_eh_shnum(b)
	int shstrndx = wc_eh_shstrndx(b)
	if ((shoff <= 0) || (shnum < 2) || (shstrndx >= shnum)):
		return;
	if (shoff + shnum * shentsize > wc_bin_size):
		return;
	int table = b + shoff
	int shstr = b + st_sh_word(table + shstrndx * shentsize, 16, 24)
	int text_seen = 0
	int i = 1
	while (i < shnum):
		int header = table + i * shentsize
		int sh_type = st_int32(header + 4)
		int name_addr = shstr + st_int32(header)
		if (sh_type == 2):
			st_symtab_lo = b + st_sh_word(header, 16, 24)
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
				st_strtab_lo = b + st_sh_word(table + link * shentsize, 16, 24)
		else if (st_cstr_eq(name_addr, c".text")):
			wc_text_lo = st_sh_word(header, 12, 16)
			wc_text_hi = wc_text_lo + st_sh_word(header, 20, 32)
			text_seen = 1
		else if (st_cstr_eq(name_addr, c".debug_line")):
			st_dline_lo = b + st_sh_word(header, 16, 24)
			st_dline_size = st_sh_word(header, 20, 32)
		i = i + 1
	if (text_seen == 0):
		return;
	if ((st_symtab_lo == 0) || (st_strtab_lo == 0)):
		return;
	# st_state = 1 arms st_func_entry/st_line_lookup/st_file_name.
	st_state = 1
	wc_have_syms = 1


# When the section headers gave no .text range, fall back to the text
# program header so the raw (unsymbolized) scan still bounds itself.
void wc_text_fallback():
	if (wc_text_hi != 0):
		return;
	int i = 0
	while (i < wc_bin_phnum):
		int p = wc_bin_buf + wc_bin_phoff + i * wc_bin_phentsize
		if (wc_ph_type(p) == 1):
			wc_text_lo = wc_ph_vaddr(p)
			wc_text_hi = wc_text_lo + wc_ph_filesz(p)
			return;
		i = i + 1


# --- output helpers ---
# Fixed-width hex at the CORE'S word size (hex_word would use wcore's).
char* wc_hex(int v):
	int digits = wc_wsize * 2
	char* s = malloc(digits + 3)
	s[0] = '0'
	s[1] = 'x'
	int i = 0
	while (i < digits):
		int nibble = (v >> ((digits - 1 - i) * 4)) & 15
		if (nibble < 10):
			s[2 + i] = '0' + nibble
		else:
			s[2 + i] = 'a' + nibble - 10
		i = i + 1
	s[digits + 2] = 0
	return s


void wc_print_hex(int v):
	char* h = wc_hex(v)
	print(h)
	free(h)


void wc_print_dec(int v):
	char* d = itoa(v)
	print(d)
	free(d)


# "  at function (file:line)" or "  at 0xADDR", lib/crash.w's frame shape.
void wc_print_frame(int addr):
	print(c"  at ")
	int e = 0
	if (wc_have_syms):
		e = st_func_entry(addr)
	if (e != 0):
		print(cast(char*, st_entry_name(e)))
	else:
		wc_print_hex(addr)
	if (wc_have_syms):
		if (st_line_lookup(addr)):
			print(c" (")
			int fname = st_file_name(st_file_found)
			if (fname != 0):
				print(cast(char*, fname))
				print(c":")
			wc_print_dec(st_line_found)
			print(c")")
	put_char(10)


# --- JSON output ---
void wc_json_str(char* s):
	put_char('"')
	int i = 0
	while (s[i] != 0):
		int ch = s[i] & 255
		if ((ch == '"') || (ch == 92)):
			put_char(92)
			put_char(ch)
		else if (ch >= 32):
			put_char(ch)
		i = i + 1
	put_char('"')


void wc_json_key(char* k):
	wc_json_str(k)
	put_char(':')


void wc_json_hex(int v):
	char* h = wc_hex(v)
	wc_json_str(h)
	free(h)


void wc_json_report(char* frames, int nframes):
	put_char('{')
	wc_json_key(c"core")
	wc_json_str(wc_core_path)
	put_char(',')
	wc_json_key(c"binary")
	wc_json_str(wc_bin_path)
	put_char(',')
	wc_json_key(c"word_size")
	wc_print_dec(wc_wsize)
	put_char(',')
	wc_json_key(c"signal")
	wc_print_dec(wc_sig)
	put_char(',')
	wc_json_key(c"signal_name")
	wc_json_str(wc_signal_name(wc_sig))
	put_char(',')
	wc_json_key(c"pc")
	wc_json_hex(wc_pc)
	put_char(',')
	wc_json_key(c"sp")
	wc_json_hex(wc_sp)
	if (wc_have_fault()):
		put_char(',')
		wc_json_key(c"fault_address")
		wc_json_hex(wc_fault_addr())
		put_char(',')
		wc_json_key(c"si_code")
		wc_print_dec(wc_si_code())
	put_char(',')
	wc_json_key(c"registers")
	put_char('{')
	int k = 0
	while (k < wc_reg_print_count()):
		if (k > 0):
			put_char(',')
		wc_json_key(wc_reg_print_name(k))
		wc_json_hex(wc_reg(wc_reg_print_index(k)))
		k = k + 1
	put_char('}')
	put_char(',')
	wc_json_key(c"frames")
	put_char('[')
	int f = 0
	while (f < nframes):
		if (f > 0):
			put_char(',')
		int addr = load_word(&frames[f * __word_size__])
		put_char('{')
		wc_json_key(c"pc")
		wc_json_hex(addr)
		if (wc_have_syms):
			int e = st_func_entry(addr)
			if (e != 0):
				put_char(',')
				wc_json_key(c"function")
				wc_json_str(cast(char*, st_entry_name(e)))
			if (st_line_lookup(addr)):
				int fname = st_file_name(st_file_found)
				if (fname != 0):
					put_char(',')
					wc_json_key(c"file")
					wc_json_str(cast(char*, fname))
				put_char(',')
				wc_json_key(c"line")
				wc_print_dec(st_line_found)
		put_char('}')
		f = f + 1
	put_char(']')
	put_char('}')
	put_char(10)


# --- human output ---
void wc_report(char* frames, int nframes):
	print(c"core: ")
	print(wc_core_path)
	if (wc_class == 2):
		println(c" (x86-64, 64-bit ELF core)")
	else:
		println(c" (x86, 32-bit ELF core)")
	print(c"binary: ")
	println(wc_bin_path)
	print(c"signal: ")
	if (wc_sig == 0):
		println(c"none recorded")
	else:
		print(wc_signal_name(wc_sig))
		char* desc = wc_signal_desc(wc_sig)
		if (desc != 0):
			print(c" (")
			print(desc)
			print(c")")
		print(c", signal ")
		wc_print_dec(wc_sig)
		put_char(10)
	if (wc_have_fault()):
		print(c"faulting address: ")
		wc_print_hex(wc_fault_addr())
		print(c" (si_code ")
		wc_print_dec(wc_si_code())
		println(c")")
	print(c"pc: ")
	wc_print_hex(wc_pc)
	int e = 0
	if (wc_have_syms):
		e = st_func_entry(wc_pc)
	if (e != 0):
		print(c"  ")
		print(cast(char*, st_entry_name(e)))
		if (st_line_lookup(wc_pc)):
			print(c" (")
			int fname = st_file_name(st_file_found)
			if (fname != 0):
				print(cast(char*, fname))
				print(c":")
			wc_print_dec(st_line_found)
			print(c")")
	put_char(10)
	println(c"registers:")
	int k = 0
	while (k < wc_reg_print_count()):
		print(c"  ")
		print(wc_reg_print_name(k))
		print(c" ")
		wc_print_hex(wc_reg(wc_reg_print_index(k)))
		put_char(10)
		k = k + 1
	println(c"stack trace (most recent call first):")
	int f = 0
	while (f < nframes):
		wc_print_frame(load_word(&frames[f * __word_size__]))
		f = f + 1
	println(c"note: the trace is heuristic (return-address scan, no frame pointers): frames can be missing or stale")


# --- errors ---
int wc_fail(char* msg):
	print2(c"wcore: ")
	println2(msg)
	return 1


int wc_fail_path(char* msg, char* path):
	print2(c"wcore: ")
	print2(msg)
	print2(c" '")
	print2(path)
	println2(c"'")
	return 1


int main(int argc, int argv):
	int i = 1
	while (i < argc):
		char** slot = argv + i * __word_size__
		char* a = *slot
		if (strcmp(a, c"--json") == 0):
			wc_json = 1
		else if (wc_core_path == 0):
			wc_core_path = a
		else if (wc_bin_path == 0):
			wc_bin_path = a
		else:
			println2(c"usage: wcore [--json] <core> <binary>")
			return 2
		i = i + 1
	if (wc_bin_path == 0):
		println2(c"usage: wcore [--json] <core> <binary>")
		return 2

	wc_core_buf = wc_load_file(wc_core_path)
	if (wc_core_buf == 0):
		return wc_fail_path(c"cannot read core file", wc_core_path)
	wc_core_size = wc_read_size
	wc_bin_buf = wc_load_file(wc_bin_path)
	if (wc_bin_buf == 0):
		return wc_fail_path(c"cannot read binary", wc_bin_path)
	wc_bin_size = wc_read_size

	if (wc_is_elf(wc_core_buf, wc_core_size) == 0):
		return wc_fail_path(c"not an ELF file:", wc_core_path)
	if (wc_is_elf(wc_bin_buf, wc_bin_size) == 0):
		return wc_fail_path(c"not an ELF file:", wc_bin_path)
	wc_class = st_byte(wc_core_buf + 4)
	if ((wc_class != 1) && (wc_class != 2)):
		return wc_fail(c"unsupported ELF class in core")
	if ((wc_class == 2) && (__word_size__ != 8)):
		return wc_fail(c"64-bit cores need the 64-bit wcore build")
	wc_wsize = wc_class * 4
	if (wc_eh_type(wc_core_buf) != 4):
		return wc_fail_path(c"not an ET_CORE core file:", wc_core_path)
	wc_machine = wc_eh_machine(wc_core_buf)
	if ((wc_machine != 3) && (wc_machine != 62)):
		return wc_fail(c"unsupported machine in core (x86 and x86-64 only)")
	if (st_byte(wc_bin_buf + 4) != wc_class):
		return wc_fail(c"ELF class mismatch: core and binary word sizes differ")
	if (wc_eh_machine(wc_bin_buf) != wc_machine):
		return wc_fail(c"machine mismatch: core and binary architectures differ")

	wc_core_phoff = wc_eh_phoff(wc_core_buf)
	wc_core_phentsize = wc_eh_phentsize(wc_core_buf)
	wc_core_phnum = wc_eh_phnum(wc_core_buf)
	if ((wc_core_phoff <= 0) || (wc_core_phnum <= 0)):
		return wc_fail(c"core has no program headers")
	if (wc_core_phoff + wc_core_phnum * wc_core_phentsize > wc_core_size):
		return wc_fail(c"core program header table is truncated")
	wc_bin_phoff = wc_eh_phoff(wc_bin_buf)
	wc_bin_phentsize = wc_eh_phentsize(wc_bin_buf)
	wc_bin_phnum = wc_eh_phnum(wc_bin_buf)
	if (wc_bin_phoff + wc_bin_phnum * wc_bin_phentsize > wc_bin_size):
		return wc_fail(c"binary program header table is truncated")

	wc_parse_notes()
	if (wc_prstatus == 0):
		return wc_fail(c"core has no NT_PRSTATUS note")
	if (wc_prstatus_size < wc_prreg_off() + wc_prreg_count() * wc_wsize):
		return wc_fail(c"core NT_PRSTATUS note is too small")
	wc_sig = st_int16(wc_prstatus + 12) /* pr_cursig */
	if (wc_sig == 0):
		wc_sig = st_int32(wc_prstatus) /* pr_info.si_signo */
	wc_pc = wc_reg(wc_pc_index())
	wc_sp = wc_reg(wc_sp_index())

	wc_parse_bin_sections()
	wc_text_fallback()
	if (wc_have_syms == 0):
		println2(c"wcore: no .symtab in the binary; raw addresses only")

	# Frame 0 is the faulting pc (exact); the rest is the heuristic scan.
	char* frames = malloc(wc_frames_max() * __word_size__)
	save_word(frames, wc_pc)
	int nframes = 1 + wc_scan(wc_sp, &frames[__word_size__], wc_frames_max() - 1)

	if (wc_json):
		wc_json_report(frames, nframes)
	else:
		wc_report(frames, nframes)
	return 0
