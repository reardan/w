/*
lib/core_file.w: reader for ELF core files of W-compiled x86 / x86-64
Linux binaries (issue #338: the core-file half of tools/wcore.w, which is
now a thin CLI over this library).

A caller loads a core (cf_load_core), then the binary that produced it
(cf_load_binary), cross-checks their build-ids (cf_check_build_id),
reads the faulting thread's state (cf_read_prstatus), points
lib/stack_trace.w's symbol lookups at the binary (cf_load_symbols) and
unwinds (cf_unwind). Each loading step returns 0 on success or an error
message; when the message is about a file, cf_error_path names it.

Both kernel cores and the dumps W programs write themselves when
W_CRASH_DUMP=<path> is set (lib/crash_dump.w) are understood; the latter
carry a "W" note naming the executable (cf_exe_note).

Word-size notes: the core's class decides every field width, so a
64-bit build of a caller reads both 32- and 64-bit cores; a 32-bit build
refuses 64-bit cores. The reader keeps one core/binary pair in globals
and repoints the st_* globals of lib/stack_trace.w, like the tool it came
from; it is a leaf library (not in the seed's import graph).
*/
import lib.lib
import lib.stack_trace


# --- state ---
int cf_core_buf       /* whole core file in memory (address) */
int cf_core_size
int cf_bin_buf        /* whole binary file in memory (address) */
int cf_bin_size
int cf_class          /* 1 = ELFCLASS32, 2 = ELFCLASS64 (core and binary) */
int cf_machine        /* 3 = x86, 62 = x86-64 */
int cf_wsize          /* target word size: 4 or 8 */

int cf_core_phoff
int cf_core_phentsize
int cf_core_phnum
int cf_bin_phoff
int cf_bin_phentsize
int cf_bin_phnum

int cf_text_lo        /* .text address range in the binary */
int cf_text_hi
int cf_have_syms      /* 1 when the binary's .symtab/.strtab parsed */

int cf_prstatus       /* address of the first NT_PRSTATUS desc, 0 = none */
int cf_prstatus_size
int cf_siginfo        /* address of the NT_SIGINFO desc, 0 = none */
int cf_siginfo_size
int cf_exe_note       /* address of the "W" exe-path note's string, 0 = none */

int cf_bin_id         /* address of the binary's build-id bytes, 0 = none */
int cf_bin_id_size
int cf_core_id        /* address of the core's copy of the build-id, 0 = none */
int cf_core_id_size

int cf_sig            /* fatal signal number, 0 = none recorded */
int cf_pc
int cf_sp
int cf_read_ok        /* last cf_core_word read hit dumped memory */

int cf_frames_max():
	return 256


# --- little-endian field readers ---
# st_byte/st_int16/st_int32/st_word (lib/stack_trace.w) read at absolute
# addresses; this reader points them into its file buffers. st_int32
# builds the value from masked bytes, so 32-bit fields stay non-negative
# in a 64-bit int. st_word reads 8 bytes only on a 64-bit build.

# A class-dependent word field (Elf32/Elf64 layouts).
int cf_field(int addr):
	if (cf_class == 2):
		return st_word(addr)
	return st_int32(addr)


# --- ELF header accessors (b = image base address) ---
int cf_eh_type(int b):
	return st_int16(b + 16)


int cf_eh_machine(int b):
	return st_int16(b + 18)


int cf_eh_phoff(int b):
	if (cf_class == 2):
		return st_word(b + 32)
	return st_int32(b + 28)


int cf_eh_phentsize(int b):
	if (cf_class == 2):
		return st_int16(b + 54)
	return st_int16(b + 42)


int cf_eh_phnum(int b):
	if (cf_class == 2):
		return st_int16(b + 56)
	return st_int16(b + 44)


int cf_eh_shoff(int b):
	if (cf_class == 2):
		return st_word(b + 40)
	return st_int32(b + 32)


int cf_eh_shentsize(int b):
	if (cf_class == 2):
		return st_int16(b + 58)
	return st_int16(b + 46)


int cf_eh_shnum(int b):
	if (cf_class == 2):
		return st_int16(b + 60)
	return st_int16(b + 48)


int cf_eh_shstrndx(int b):
	if (cf_class == 2):
		return st_int16(b + 62)
	return st_int16(b + 50)


# --- program header accessors (p = header address) ---
int cf_ph_type(int p):
	return st_int32(p)


int cf_ph_offset(int p):
	if (cf_class == 2):
		return st_word(p + 8)
	return st_int32(p + 4)


int cf_ph_vaddr(int p):
	if (cf_class == 2):
		return st_word(p + 16)
	return st_int32(p + 8)


int cf_ph_filesz(int p):
	if (cf_class == 2):
		return st_word(p + 32)
	return st_int32(p + 16)


# --- file loading ---
int cf_read_size

# Whole file into a malloc'd buffer; returns its address or 0.
int cf_load_file(char* path):
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
	cf_read_size = size
	return cast(int, buf)


int cf_is_elf(int b, int size):
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
int cf_core_mem(int vaddr, int n):
	int i = 0
	while (i < cf_core_phnum):
		int p = cf_core_buf + cf_core_phoff + i * cf_core_phentsize
		if (cf_ph_type(p) == 1):
			int lo = cf_ph_vaddr(p)
			int fsz = cf_ph_filesz(p)
			int off = cf_ph_offset(p)
			if ((off >= 0) && (off + fsz <= cf_core_size)):
				if ((vaddr >= lo) && (vaddr + n <= lo + fsz)):
					return cf_core_buf + off + (vaddr - lo)
		i = i + 1
	return 0


# Target-word-sized read from dumped memory; sets cf_read_ok.
int cf_core_word(int vaddr):
	int a = cf_core_mem(vaddr, cf_wsize)
	if (a == 0):
		cf_read_ok = 0
		return 0
	cf_read_ok = 1
	if (cf_class == 2):
		return st_word(a)
	return st_int32(a)


# --- code bytes (binary file first, dumped memory as fallback) ---
# W's ELF backends map file offset 0 at the load base in one text
# segment, so byte i of the file is process byte p_vaddr + i; going
# through the binary's program headers keeps this exact for any layout.
int cf_code_byte(int vaddr):
	int i = 0
	while (i < cf_bin_phnum):
		int p = cf_bin_buf + cf_bin_phoff + i * cf_bin_phentsize
		if (cf_ph_type(p) == 1):
			int lo = cf_ph_vaddr(p)
			int fsz = cf_ph_filesz(p)
			int off = cf_ph_offset(p)
			if ((off >= 0) && (off + fsz <= cf_bin_size)):
				if ((vaddr >= lo) && (vaddr < lo + fsz)):
					return st_byte(cf_bin_buf + off + (vaddr - lo))
		i = i + 1
	int a = cf_core_mem(vaddr, 1)
	if (a != 0):
		return st_byte(a)
	return -1


# --- core note parsing (NT_PRSTATUS, NT_SIGINFO) ---
# Notes are 4-byte aligned in both ELF classes on Linux. The first
# NT_PRSTATUS is the faulting thread (the kernel writes it first).
void cf_parse_notes():
	int i = 0
	while (i < cf_core_phnum):
		int p = cf_core_buf + cf_core_phoff + i * cf_core_phentsize
		if (cf_ph_type(p) == 4):
			int off = cf_ph_offset(p)
			int fsz = cf_ph_filesz(p)
			if ((off < 0) || (off + fsz > cf_core_size)):
				i = i + 1
				continue
			int cur = cf_core_buf + off
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
				if ((namesz == 2) && (ntype == 0x57455845) && (descsz > 1)):
					if (st_cstr_eq(name, c"W")):
						if (st_byte(desc + descsz - 1) == 0):
							cf_exe_note = desc
				if (is_core_note):
					if ((ntype == 1) && (cf_prstatus == 0)):
						cf_prstatus = desc
						cf_prstatus_size = descsz
					if ((ntype == 0x53494749) && (cf_siginfo == 0)):
						cf_siginfo = desc
						cf_siginfo_size = descsz
				cur = desc + (descsz + 3) / 4 * 4
		i = i + 1


# --- build-id (NT_GNU_BUILD_ID) ---
int cf_found_id_size

# Scan the notes in [cur, end) for the GNU build-id; returns the address
# of its descriptor bytes (size in cf_found_id_size) or 0.
int cf_find_build_id(int cur, int end):
	while (cur + 12 <= end):
		int namesz = st_int32(cur)
		int descsz = st_int32(cur + 4)
		int ntype = st_int32(cur + 8)
		int name = cur + 12
		int desc = name + (namesz + 3) / 4 * 4
		if ((desc + descsz > end) || (descsz < 0) || (namesz < 0)):
			return 0
		if ((ntype == 3) && (namesz == 4) && (descsz > 0)):
			if (st_cstr_eq(name, c"GNU")):
				cf_found_id_size = descsz
				return desc
		cur = desc + (descsz + 3) / 4 * 4
	return 0


# The binary's build-id, from its PT_NOTE segments.
void cf_bin_build_id():
	int i = 0
	while (i < cf_bin_phnum):
		int p = cf_bin_buf + cf_bin_phoff + i * cf_bin_phentsize
		if (cf_ph_type(p) == 4):
			int off = cf_ph_offset(p)
			int fsz = cf_ph_filesz(p)
			if ((off >= 0) && (off + fsz <= cf_bin_size)):
				int id = cf_find_build_id(cf_bin_buf + off, cf_bin_buf + off + fsz)
				if (id != 0):
					cf_bin_id = id
					cf_bin_id_size = cf_found_id_size
					return;
		i = i + 1


# The build-id as the crashed process had it mapped: find a dumped PT_LOAD
# page holding an ET_EXEC ELF header (W binaries are ET_EXEC; the loader,
# shared libraries and the vDSO are ET_DYN), then follow that copy's
# program headers to its PT_NOTE, whose p_vaddr is absolute.
void cf_core_build_id():
	int i = 0
	while (i < cf_core_phnum):
		int p = cf_core_buf + cf_core_phoff + i * cf_core_phentsize
		i = i + 1
		if (cf_ph_type(p) != 1):
			continue
		int base = cf_ph_vaddr(p)
		int eh = cf_core_mem(base, 64)
		if (eh == 0):
			continue
		if (cf_is_elf(eh, 64) == 0):
			continue
		if ((st_byte(eh + 4) != cf_class) || (cf_eh_type(eh) != 2)):
			continue
		int phentsize = cf_eh_phentsize(eh)
		int phnum = cf_eh_phnum(eh)
		int ph = cf_core_mem(base + cf_eh_phoff(eh), phnum * phentsize)
		if (ph == 0):
			continue
		int k = 0
		while (k < phnum):
			int q = ph + k * phentsize
			k = k + 1
			if (cf_ph_type(q) != 4):
				continue
			int fsz = cf_ph_filesz(q)
			int notes = cf_core_mem(cf_ph_vaddr(q), fsz)
			if (notes == 0):
				continue
			int id = cf_find_build_id(notes, notes + fsz)
			if (id != 0):
				cf_core_id = id
				cf_core_id_size = cf_found_id_size
				return;


int cf_build_ids_match():
	if (cf_bin_id_size != cf_core_id_size):
		return 0
	int i = 0
	while (i < cf_bin_id_size):
		if (st_byte(cf_bin_id + i) != st_byte(cf_core_id + i)):
			return 0
		i = i + 1
	return 1


# Lowercase hex of n bytes at addr (malloc'd).
char* cf_id_hex(int addr, int n):
	char* s = malloc(n * 2 + 1)
	int i = 0
	while (i < n):
		int b = st_byte(addr + i)
		s[i * 2] = c"0123456789abcdef"[b >> 4]
		s[i * 2 + 1] = c"0123456789abcdef"[b & 15]
		i = i + 1
	s[n * 2] = 0
	return s


# --- registers (elf_prstatus.pr_reg, user_regs_struct layout) ---
# Offsets per arch/x86 struct elf_prstatus: pr_reg at 72 (i386, 17
# 4-byte regs) / 112 (x86-64, 27 8-byte regs). The in-register order is
# the ptrace user_regs_struct one, the same layout debugger/attach.w
# reads via PTRACE_GETREGS (ip at word 12/16, sp at word 15/19).
int cf_prreg_off():
	if (cf_class == 2):
		return 112
	return 72


int cf_prreg_count():
	if (cf_class == 2):
		return 27
	return 17


int cf_reg(int index):
	return cf_field(cf_prstatus + cf_prreg_off() + index * cf_wsize)


int cf_pc_index():
	if (cf_class == 2):
		return 16 /* rip */
	return 12 /* eip */


int cf_fp_index():
	if (cf_class == 2):
		return 4 /* rbp */
	return 5 /* ebp */


int cf_sp_index():
	if (cf_class == 2):
		return 19 /* rsp */
	return 15 /* esp */


# The registers the report shows, in the same order attach mode's
# 'registers' command prints them (debugger/attach.w at_print_registers).
int cf_reg_print_count():
	if (cf_class == 2):
		return 18
	return 10


char* cf_reg_print_name(int k):
	if (cf_class == 2):
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


int cf_reg_print_index(int k):
	if (cf_class == 2):
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
char* cf_signal_name(int sig):
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
char* cf_signal_desc(int sig):
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


# siginfo_t: si_signo +0, si_errno +4, si_code +8; the fault address
# union member starts at +12 (32-bit) / +16 (64-bit, 8-byte aligned).
int cf_fault_addr():
	if (cf_class == 2):
		return st_word(cf_siginfo + 16)
	return st_int32(cf_siginfo + 12)


int cf_si_code():
	return st_int32(cf_siginfo + 8)


int cf_have_fault():
	if (cf_siginfo == 0):
		return 0
	# si_code <= 0 means user-sent (SI_USER/SI_TKILL): the siginfo union
	# holds the sender's pid/uid there, not a fault address.
	if (cf_si_code() <= 0):
		return 0
	if ((cf_sig == 4) || (cf_sig == 7) || (cf_sig == 8) || (cf_sig == 11)):
		return 1
	return 0


# --- backtrace: the live tracer's return-address scan over core memory ---
# Port of lib/stack_trace.w st_scan/st_call_site: scan stack words
# upward from sp, keep values that point into the binary's .text and
# whose preceding bytes decode as one of the compiler's call forms
# (call *eax / call *rax, or call rel32 in asm stubs), stop at main's
# frame or the end of the dumped stack segment.
int cf_call_site(int v):
	if (v - 5 < cf_text_lo):
		return 0
	if ((cf_code_byte(v - 2) == 255) && (cf_code_byte(v - 1) == 208)):
		return 1
	if (cf_code_byte(v - 5) == 232):
		return 1
	return 0


int cf_scan(int sp, char* out, int max):
	int found = 0
	int i = 0
	while (i < 65536):
		int slot = sp + i * cf_wsize
		int v = cf_core_word(slot)
		if (cf_read_ok == 0):
			return found
		if ((v > cf_text_lo) && (v < cf_text_hi)):
			if (cf_call_site(v)):
				int keep = 1
				int e = 0
				if (cf_have_syms):
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


# --- backtrace: the frame-pointer chain (exact) ---
# W functions open with push ebp ; mov ebp,esp on x86/x64, so the core's
# ebp/rbp heads a chain of [saved fp | return address] pairs through
# the dumped stack. Mirrors lib/stack_trace.w st_unwind / st_chain,
# reading words from the core and code bytes from the binary; where the
# chain breaks (or the binary predates frame pointers) the rest comes
# from cf_scan and cf_chain_exact is 0.
int cf_chain_exact


int cf_prologue_len(int addr):
	if (cf_code_byte(addr) != 85):
		return 0
	if (cf_class == 2):
		if ((cf_code_byte(addr + 1) == 72) && (cf_code_byte(addr + 2) == 137) && (cf_code_byte(addr + 3) == 229)):
			return 4
		return 0
	if ((cf_code_byte(addr + 1) == 137) && (cf_code_byte(addr + 2) == 229)):
		return 3
	return 0


int cf_is_main(int pc):
	int e = st_func_entry(pc)
	if (e == 0):
		return 0
	return st_cstr_eq(st_entry_name(e), c"main")


# 1 when the binary's main opens with the frame-pointer prologue (the
# whole image comes from one compiler).
int cf_uses_frame_pointers():
	if (cf_have_syms == 0):
		return 0
	int i = 1
	while (i < st_symtab_count):
		int e = st_symtab_lo + i * st_symtab_entsize
		if (st_cstr_eq(st_entry_name(e), c"main")):
			return cf_prologue_len(st_entry_value(e)) > 0
		i = i + 1
	return 0


int cf_is_return(int v):
	if ((v <= cf_text_lo) || (v >= cf_text_hi)):
		return 0
	if (cf_call_site(v) == 0):
		return 0
	return st_func_entry(v - 1) != 0


int cf_chain(int fp, char* out, int found, int max, int fallback_sp):
	int last = 0
	int broken = 0
	while ((found < max) && (broken == 0)):
		if (fp == 0):
			cf_chain_exact = 1
			return found
		int v = 0
		if ((fp & (cf_wsize - 1)) != 0):
			broken = 1
		else:
			v = cf_core_word(fp + cf_wsize)
			if (cf_read_ok == 0):
				broken = 1
			else if (cf_is_return(v) == 0):
				broken = 1
		if (broken == 0):
			save_word(&out[found * __word_size__], v - 1)
			found = found + 1
			last = fp
			if (cf_is_main(v - 1)):
				cf_chain_exact = 1
				return found
			int next = cf_core_word(fp)
			if (cf_read_ok == 0):
				broken = 1
			else if ((next != 0) && (next <= fp)):
				broken = 1
			fp = next
	if (broken == 0):
		cf_chain_exact = 1
		return found
	cf_chain_exact = 0
	int from = fallback_sp
	if (last != 0):
		from = last + 2 * cf_wsize
	return found + cf_scan(from, &out[found * __word_size__], max - found)


# Callers of pc (the faulting thread's pc/sp/fp), most recent first.
int cf_unwind(int pc, int sp, int fp, char* out, int max):
	cf_chain_exact = 0
	if (cf_uses_frame_pointers() == 0):
		return cf_scan(sp, out, max)
	int e = st_func_entry(pc)
	if (e == 0):
		return cf_scan(sp, out, max)
	if (cf_is_main(pc)):
		cf_chain_exact = 1
		return 0
	int entry = st_entry_value(e)
	int plen = cf_prologue_len(entry)
	int found = 0
	if (plen == 0):
		found = cf_scan(sp, out, 1)
		if (found == 0):
			return 0
		if (cf_is_main(load_word(out))):
			return found
		found = cf_chain(fp, out, found, max, sp)
		cf_chain_exact = 0
		return found
	int ret_slot = 0
	if (pc == entry):
		ret_slot = sp
	else if (pc < entry + plen):
		ret_slot = sp + cf_wsize
	if (ret_slot != 0):
		int v = cf_core_word(ret_slot)
		if ((cf_read_ok == 0) || (cf_is_return(v) == 0)):
			return cf_scan(sp, out, max)
		save_word(out, v - 1)
		found = 1
		if (cf_is_main(v - 1)):
			cf_chain_exact = 1
			return found
	return cf_chain(fp, out, found, max, sp)


# --- binary section parsing (points lib/stack_trace.w at the buffer) ---
# Mirrors st_init, minus its this-image class check: st_class is the
# CORE'S class here, not the running tool's, so the shared lookups
# decode the right symbol-entry layout for either word size.
void cf_parse_bin_sections():
	int b = cf_bin_buf
	st_class = cf_class
	st_machine = cf_machine
	int shoff = cf_eh_shoff(b)
	int shentsize = cf_eh_shentsize(b)
	int shnum = cf_eh_shnum(b)
	int shstrndx = cf_eh_shstrndx(b)
	if ((shoff <= 0) || (shnum < 2) || (shstrndx >= shnum)):
		return;
	if (shoff + shnum * shentsize > cf_bin_size):
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
			cf_text_lo = st_sh_word(header, 12, 16)
			cf_text_hi = cf_text_lo + st_sh_word(header, 20, 32)
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
	cf_have_syms = 1


# When the section headers gave no .text range, fall back to the text
# program header so the raw (unsymbolized) scan still bounds itself.
void cf_text_fallback():
	if (cf_text_hi != 0):
		return;
	int i = 0
	while (i < cf_bin_phnum):
		int p = cf_bin_buf + cf_bin_phoff + i * cf_bin_phentsize
		if (cf_ph_type(p) == 1):
			cf_text_lo = cf_ph_vaddr(p)
			cf_text_hi = cf_text_lo + cf_ph_filesz(p)
			return;
		i = i + 1


# Fixed-width hex at the CORE'S word size (hex_word would use the
# running program's).
char* cf_hex(int v):
	int digits = cf_wsize * 2
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


# --- loading (the checks tools/wcore.w runs, in the same order) ---
char* cf_error_path   /* the file an error message is about, 0 = none */


char* cf_fail_path(char* msg, char* path):
	cf_error_path = path
	return msg


# Load and validate the core file, then parse its notes. Returns 0 or an
# error message.
char* cf_load_core(char* path):
	cf_error_path = cast(char*, 0)
	cf_core_buf = cf_load_file(path)
	if (cf_core_buf == 0):
		return cf_fail_path(c"cannot read core file", path)
	cf_core_size = cf_read_size
	if (cf_is_elf(cf_core_buf, cf_core_size) == 0):
		return cf_fail_path(c"not an ELF file:", path)
	cf_class = st_byte(cf_core_buf + 4)
	if ((cf_class != 1) && (cf_class != 2)):
		return c"unsupported ELF class in core"
	if ((cf_class == 2) && (__word_size__ != 8)):
		return c"64-bit cores need the 64-bit wcore build"
	cf_wsize = cf_class * 4
	if (cf_eh_type(cf_core_buf) != 4):
		return cf_fail_path(c"not an ET_CORE core file:", path)
	cf_machine = cf_eh_machine(cf_core_buf)
	if ((cf_machine != 3) && (cf_machine != 62)):
		return c"unsupported machine in core (x86 and x86-64 only)"
	cf_core_phoff = cf_eh_phoff(cf_core_buf)
	cf_core_phentsize = cf_eh_phentsize(cf_core_buf)
	cf_core_phnum = cf_eh_phnum(cf_core_buf)
	if ((cf_core_phoff <= 0) || (cf_core_phnum <= 0)):
		return c"core has no program headers"
	if (cf_core_phoff + cf_core_phnum * cf_core_phentsize > cf_core_size):
		return c"core program header table is truncated"
	cf_parse_notes()
	return cast(char*, 0)


# Load the binary the core came from and check it matches the core's
# class and machine. Returns 0 or an error message.
char* cf_load_binary(char* path):
	cf_error_path = cast(char*, 0)
	cf_bin_buf = cf_load_file(path)
	if (cf_bin_buf == 0):
		return cf_fail_path(c"cannot read binary", path)
	cf_bin_size = cf_read_size
	if (cf_is_elf(cf_bin_buf, cf_bin_size) == 0):
		return cf_fail_path(c"not an ELF file:", path)
	if (st_byte(cf_bin_buf + 4) != cf_class):
		return c"ELF class mismatch: core and binary word sizes differ"
	if (cf_eh_machine(cf_bin_buf) != cf_machine):
		return c"machine mismatch: core and binary architectures differ"
	cf_bin_phoff = cf_eh_phoff(cf_bin_buf)
	cf_bin_phentsize = cf_eh_phentsize(cf_bin_buf)
	cf_bin_phnum = cf_eh_phnum(cf_bin_buf)
	if (cf_bin_phoff + cf_bin_phnum * cf_bin_phentsize > cf_bin_size):
		return c"binary program header table is truncated"
	return cast(char*, 0)


# Find both build-ids. Returns 0 when they match, 1 on a mismatch (or a
# core build-id with none in the binary), 2 when the core records none
# but the binary has one (unverifiable), 3 when neither has one.
int cf_check_build_id():
	cf_bin_build_id()
	cf_core_build_id()
	if (cf_core_id != 0):
		if ((cf_bin_id == 0) || (cf_build_ids_match() == 0)):
			return 1
		return 0
	if (cf_bin_id != 0):
		return 2
	return 3


# Read the faulting thread's signal, pc and sp from NT_PRSTATUS. Returns
# 0 or an error message.
char* cf_read_prstatus():
	cf_error_path = cast(char*, 0)
	if (cf_prstatus == 0):
		return c"core has no NT_PRSTATUS note"
	if (cf_prstatus_size < cf_prreg_off() + cf_prreg_count() * cf_wsize):
		return c"core NT_PRSTATUS note is too small"
	cf_sig = st_int16(cf_prstatus + 12) /* pr_cursig */
	if (cf_sig == 0):
		cf_sig = st_int32(cf_prstatus) /* pr_info.si_signo */
	cf_pc = cf_reg(cf_pc_index())
	cf_sp = cf_reg(cf_sp_index())
	return cast(char*, 0)


# Parse the binary's sections for symbolization; cf_have_syms says
# whether .symtab was found.
void cf_load_symbols():
	cf_parse_bin_sections()
	cf_text_fallback()


# The backtrace into frames (max words): frame 0 is the faulting pc
# (exact), then the frame-pointer chain with the heuristic scan as
# fallback (cf_chain_exact says which). Returns the frame count.
int cf_backtrace(char* frames, int max):
	save_word(frames, cf_pc)
	return 1 + cf_unwind(cf_pc, cf_sp, cf_reg(cf_fp_index()), &frames[__word_size__], max - 1)
