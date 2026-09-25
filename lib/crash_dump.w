/*
W-generated crash dumps (issue #378).

When W_CRASH_DUMP=<path> is set in the environment, the fatal-signal
handler in lib/crash.w (crash_handler_install) also writes an ELF
ET_CORE core file of the crashing process to <path> ("%p" in the path
expands to the process id). Unlike a kernel core it does not depend on
RLIMIT_CORE or /proc/sys/kernel/core_pattern, so it also lands when
cores are disabled or piped to apport/systemd-coredump, and it carries
W-specific extras:

  * PT_NOTE "CORE" NT_PRSTATUS: the signal and the faulting thread's
    registers (user_regs_struct order, rebuilt from the signal's
    sigcontext), so gdb, readelf and tools/wcore.w read it like a
    kernel core;
  * PT_NOTE "CORE" NT_SIGINFO: signal, si_code (derived from the trap
    number and page-fault error code) and the faulting address;
  * PT_NOTE "W" type 0x57455845 (W_NT_EXE_PATH): the executable's path, so
    `wcore <dump>` finds the binary without being told;
  * PT_LOAD segments for every readable mapping in /proc/self/maps -
    the executable image (whose first page holds the GNU build-id, so
    wcore can verify the binary), globals, heap and stack. [vvar] and
    [vsyscall] are skipped. Without /proc the dump falls back to the
    image's own PT_LOAD segments plus the stack pages above sp.

Handler safety: crash_dump_prepare() (called from crash_handler_install
when W_CRASH_DUMP is set) mmaps every buffer the writer needs and
resolves the executable path up front; crash_dump_write() then only
issues syscalls (open, read, write, seek, getpid, close). Mapped memory
is copied with write(2) straight from the mapping, so an unreadable
page makes write fail with EFAULT instead of faulting: that segment is
recorded with the bytes that did land (p_filesz < p_memsz). The data is
written first and the headers last, so the header always describes
exactly what is in the file.

Linux x86/x64 only (the handler itself is installed only there). This
file is in the seed's import graph (lib/crash.w, imported by w.w):
seed-era syntax only.
*/
import lib.stack_trace
import debugger.sigcontext
import lib.hex


char* cd_template   /* W_CRASH_DUMP value, 0 = dumps disabled */
char* cd_path       /* resolved dump path (4 KiB) */
char* cd_exe        /* executable path, NUL-terminated (4 KiB) */
int cd_exe_len
char* cd_hdr        /* ELF header + program headers + notes */
char* cd_maps       /* /proc/self/maps text */
char* cd_seg        /* segment table: [start, length, p_flags, bytes landed] words */
int cd_nseg
int cd_written_path /* 1 after a successful dump: cd_path is valid */

# Build-id of the running image (crash_build_id), 0 = none.
int cd_id_addr
int cd_id_size


# Note type of the "W" executable-path note ("WEXE"); tools/wcore.w
# reads it to find the binary when none is given.
const int cd_nt_exe_path = 0x57455845
const int cd_max_segs = 1024
const int cd_hdr_size = 131072
const int cd_maps_size = 262144


int cd_mmap(int size):
	int p = mmap(0, size, 3, 34) /* RW, PRIVATE|ANONYMOUS */
	if ((p > 0) || (p < -4095)):
		return p
	return 0


# --- little-endian writers into the header buffer ---
void cd_put8(int off, int v):
	cd_hdr[off] = v & 255


void cd_put16(int off, int v):
	cd_put8(off, v)
	cd_put8(off + 1, v >> 8)


void cd_put32(int off, int v):
	cd_put16(off, v)
	cd_put16(off + 2, v >> 16)


# A word of the dump's ELF class (= the running target's word size).
void cd_putw(int off, int v):
	cd_put32(off, v)
	if (__word_size__ == 8): cd_put32(off + 4, v >> 32)


int cd_seg_get(int i, int k):
	return load_word(&cd_seg[(i * 4 + k) * __word_size__])


void cd_seg_set(int i, int k, int v):
	save_word(&cd_seg[(i * 4 + k) * __word_size__], v)


void cd_seg_add(int lo, int hi, int flags):
	if (cd_nseg >= cd_max_segs): return;
	if (hi - lo <= 0): return;
	cd_seg_set(cd_nseg, 0, lo)
	cd_seg_set(cd_nseg, 1, hi - lo)
	cd_seg_set(cd_nseg, 2, flags)
	cd_seg_set(cd_nseg, 3, 0)
	cd_nseg = cd_nseg + 1


# --- build-id of the running image ---
# The image's ELF header is at st_base (lib/stack_trace.w); its PT_NOTE
# p_vaddr is absolute. Sets cd_id_addr / cd_id_size.
void crash_build_id():
	cd_id_addr = 0
	cd_id_size = 0
	if (st_state != 1): return;
	if (st_macho):
		# Mach-O: the LC_UUID's 16 bytes (the writer hashes the image
		# into it, code_generator/macho_64.w).
		int lc = st_base + 32
		int ncmds = st_int32(st_base + 16)
		for k in range(ncmds):
			if (st_int32(lc) == 27):
				cd_id_addr = lc + 8
				cd_id_size = 16
				return;
			lc = lc + st_int32(lc + 4)
		return;
	int b = st_base
	int phoff = 0
	int phentsize = 0
	int phnum = 0
	if (st_class == 2):
		phoff = st_word(b + 32)
		phentsize = st_int16(b + 54)
		phnum = st_int16(b + 56)
	else:
		phoff = st_int32(b + 28)
		phentsize = st_int16(b + 42)
		phnum = st_int16(b + 44)
	if ((phnum <= 0) || (phnum > 64)): return;
	if (st_range_readable(b + phoff, phnum * phentsize) == 0): return;
	int i = 0
	while (i < phnum):
		int p = b + phoff + i * phentsize
		i = i + 1
		if (st_int32(p) != 4): continue
		int vaddr = 0
		int fsz = 0
		if (st_class == 2):
			vaddr = st_word(p + 16)
			fsz = st_word(p + 32)
		else:
			vaddr = st_int32(p + 8)
			fsz = st_int32(p + 16)
		if (st_range_readable(vaddr, fsz) == 0): continue
		int cur = vaddr
		int end = vaddr + fsz
		while (cur + 12 <= end):
			int namesz = st_int32(cur)
			int descsz = st_int32(cur + 4)
			int ntype = st_int32(cur + 8)
			int desc = cur + 12 + (namesz + 3) / 4 * 4
			if ((namesz < 0) || (descsz < 0) || (desc + descsz > end)): break
			if ((ntype == 3) && (namesz == 4) && (descsz > 0)):
				if (st_cstr_eq(cur + 12, c"GNU")):
					cd_id_addr = desc
					cd_id_size = descsz
					return;
			cur = desc + (descsz + 3) / 4 * 4


# Lowercase hex of the build-id to stderr (no allocation).
void crash_write_build_id():
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < cd_id_size):
		int b = st_byte(cd_id_addr + i)
		write(2, &digits[b >> 4], 1)
		write(2, &digits[b & 15], 1)
		i = i + 1


# --- setup (not in the handler: may allocate) ---
void crash_dump_prepare(char* template):
	if (template == 0): return;
	if (template[0] == 0): return;
	if (cd_hdr == 0):
		cd_hdr = cast(char*, cd_mmap(cd_hdr_size))
		cd_maps = cast(char*, cd_mmap(cd_maps_size))
		cd_seg = cast(char*, cd_mmap(cd_max_segs * 4 * __word_size__))
		cd_path = cast(char*, cd_mmap(4096))
		cd_exe = cast(char*, cd_mmap(4096))
	if ((cd_hdr == 0) || (cd_maps == 0) || (cd_seg == 0) || (cd_path == 0) || (cd_exe == 0)):
		return;
	cd_exe_len = readlink(c"/proc/self/exe", cd_exe, 4095)
	if (cd_exe_len < 0): cd_exe_len = 0
	cd_exe[cd_exe_len] = 0
	cd_template = template


int crash_dump_enabled():
	return cd_template != 0


# --- handler-time helpers (syscalls only) ---
# cd_template with "%p" replaced by the pid, into cd_path.
void cd_resolve_path():
	int pid = getpid()
	int o = 0
	int i = 0
	while ((cd_template[i] != 0) && (o < 4000)):
		if ((cd_template[i] == '%') && (cd_template[i + 1] == 'p')):
			char* tmp = &cd_path[4032]
			int n = 0
			int v = pid
			while (1):
				tmp[n] = '0' + v - v / 10 * 10
				n = n + 1
				v = v / 10
				if (v == 0): break
			while (n > 0):
				n = n - 1
				cd_path[o] = tmp[n]
				o = o + 1
			i = i + 2
		else:
			cd_path[o] = cd_template[i]
			o = o + 1
			i = i + 1
	cd_path[o] = 0


int cd_pos

int cd_parse_hex():
	int v = 0
	while (1):
		int d = hex_decode_char(cd_maps[cd_pos] & 255)
		if (d < 0):
			return v
		v = (v << 4) | d
		cd_pos = cd_pos + 1


# 1 when the text from cd_pos to the end of its line contains s.
int cd_line_has(char* s):
	int i = cd_pos
	while ((cd_maps[i] != 0) && (cd_maps[i] != 10)):
		int k = 0
		while ((s[k] != 0) && (cd_maps[i + k] == s[k])): k = k + 1
		if (s[k] == 0): return 1
		i = i + 1
	return 0


# Readable mappings from /proc/self/maps; returns the count found.
int cd_collect_maps():
	int f = open(c"/proc/self/maps", 0, 0)
	if (f < 0): return 0
	int got = 0
	int cap = cd_maps_size - 1
	while (got < cap):
		int r = read(f, &cd_maps[got], cap - got)
		if (r <= 0): break
		got = got + r
	close(f)
	# Drop a partial last line (buffer full).
	while ((got > 0) && (cd_maps[got - 1] != 10)): got = got - 1
	cd_maps[got] = 0
	cd_pos = 0
	while (cd_pos < got):
		int lo = cd_parse_hex()
		cd_pos = cd_pos + 1 /* '-' */
		int hi = cd_parse_hex()
		cd_pos = cd_pos + 1 /* ' ' */
		int flags = 0
		if (cd_maps[cd_pos] == 'r'): flags = flags | 4
		if (cd_maps[cd_pos + 1] == 'w'): flags = flags | 2
		if (cd_maps[cd_pos + 2] == 'x'): flags = flags | 1
		int skip = 0
		if (cd_line_has(c"[vvar")): skip = 1
		if (cd_line_has(c"[vsyscall]")): skip = 1
		if (((flags & 4) != 0) && (skip == 0)): cd_seg_add(lo, hi, flags)
		while ((cd_pos < got) && (cd_maps[cd_pos] != 10)): cd_pos = cd_pos + 1
		cd_pos = cd_pos + 1
	return cd_nseg


# No /proc: the image's own PT_LOAD segments plus the stack from sp's
# page up to the first unmapped page.
void cd_collect_fallback(int sp):
	if (st_state == 1):
		int b = st_base
		int phoff = st_int32(b + 28)
		int phentsize = st_int16(b + 42)
		int phnum = st_int16(b + 44)
		if (st_class == 2):
			phoff = st_word(b + 32)
			phentsize = st_int16(b + 54)
			phnum = st_int16(b + 56)
		int i = 0
		while ((i < phnum) && (i < 64)):
			int p = b + phoff + i * phentsize
			i = i + 1
			if (st_int32(p) != 1): continue
			int vaddr = st_int32(p + 8)
			int memsz = st_int32(p + 20)
			int pf = st_int32(p + 24)
			if (st_class == 2):
				vaddr = st_word(p + 16)
				memsz = st_word(p + 40)
				pf = st_int32(p + 4)
			int lo = vaddr - (vaddr & 4095)
			int hi = vaddr + memsz
			hi = hi + ((4096 - (hi & 4095)) & 4095)
			cd_seg_add(lo, hi, pf | 4)
	int s = sp - (sp & 4095)
	int e = s
	int pages = 0
	while ((pages < 4096) && st_page_readable(e)):
		e = e + 4096
		pages = pages + 1
	cd_seg_add(s, e, 6)


int cd_note_size(int namesz, int descsz):
	return 12 + (namesz + 3) / 4 * 4 + (descsz + 3) / 4 * 4


int cd_prstatus_size():
	if (__word_size__ == 8): return 336
	return 144


int cd_notes_size():
	return cd_note_size(5, cd_prstatus_size()) + cd_note_size(5, 128) + cd_note_size(2, cd_exe_len + 1)


# Writes a note header + name at off; returns the descriptor offset.
int cd_note(int off, char* name, int namesz, int descsz, int ntype):
	cd_put32(off, namesz)
	cd_put32(off + 4, descsz)
	cd_put32(off + 8, ntype)
	for i in range(namesz): cd_put8(off + 12 + i, name[i])
	return off + 12 + (namesz + 3) / 4 * 4


# One user_regs_struct slot from the sigcontext: off >= 0 is a word
# field, off <= -2 is a 16-bit segment register at -(off + 2), -1 is
# orig_eax/orig_rax (not in the sigcontext: -1 as the kernel reports
# for a fault).
int cd_reg(int context, int off):
	if (off == -1): return -1
	if (off < -1): return st_int16(context - off - 2)
	return ctx_reg(context, off)


# sigcontext offset of user_regs_struct register i (see cd_reg).
int cd_reg_off(int i):
	if (__word_size__ == 8):
		# r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi
		# orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs
		if (i < 4): return 56 - i * 8
		if (i == 4): return 80
		if (i == 5): return 88
		if (i < 10): return 24 - (i - 6) * 8
		if (i == 10): return 104
		if (i == 11): return 112
		if (i == 12): return 96
		if (i == 13): return 72
		if (i == 14): return 64
		if (i == 15): return -1
		if (i == 16): return 128
		if (i == 17):
			return -146 /* cs, 16-bit at 144 */
		if (i == 18): return 136
		if (i == 19): return 120
		if (i == 20):
			return -152 /* ss, 16-bit at 150 */
		if (i == 25):
			return -150 /* fs, 16-bit at 148 */
		if (i == 26):
			return -148 /* gs, 16-bit at 146 */
		return -3 /* fs_base, gs_base, ds, es: not recorded (0 below) */
	# ebx ecx edx esi edi ebp eax ds es fs gs orig_eax eip cs eflags esp ss
	if (i == 0): return 32
	if (i == 1): return 40
	if (i == 2): return 36
	if (i == 3): return 20
	if (i == 4): return 16
	if (i == 5): return 24
	if (i == 6): return 44
	if (i < 11):
		return (i - 7) * 4 - 14 /* ds 12, es 8, fs 4, gs 0: 16-bit */
	if (i == 11): return -1
	if (i == 12): return 56
	if (i == 13):
		return -62 /* cs */
	if (i == 14): return 64
	if (i == 15): return 28
	return -74 /* ss */


# si_code and faulting address the kernel would have reported.
int cd_si_code(int sig, int context):
	int trapno = ctx_reg(context, sigcontext_trapno())
	if (sig == 11):
		if (trapno == 13):
			return 128 /* SI_KERNEL: general protection */
		if (ctx_reg(context, sigcontext_err()) & 1):
			return 2 /* SEGV_ACCERR */
		return 1 /* SEGV_MAPERR */
	if (sig == 7):
		return 2 /* BUS_ADRERR */
	if (sig == 8):
		return 1 /* FPE_INTDIV */
	if (sig == 4):
		return 2 /* ILL_ILLOPN */
	return 128


int cd_fault_addr(int sig, int context):
	if ((sig == 11) || (sig == 7)):
		if (cd_si_code(sig, context) == 128): return 0
		return ctx_reg(context, sigcontext_cr2())
	return ctx_eip(context)


# Writes n bytes at address addr to fd; returns the count that landed.
int cd_copy(int fd, int addr, int n):
	int done = 0
	while (done < n):
		int chunk = n - done
		if (chunk > 1048576): chunk = 1048576
		int r = write(fd, cast(char*, addr + done), chunk)
		if (r <= 0):
			return done
		done = done + r
	return done


# The dump itself; returns 1 when the file was written. Runs in the
# fatal-signal handler: syscalls and preallocated buffers only.
int crash_dump_write(int sig, int context):
	cd_written_path = 0
	if (cd_template == 0): return 0
	cd_resolve_path()
	int fd = open(cd_path, 577, 384) /* O_WRONLY|O_CREAT|O_TRUNC, 0600 */
	if (fd < 0): return 0
	cd_nseg = 0
	if (cd_collect_maps() == 0): cd_collect_fallback(ctx_esp(context))

	int ehsize = 52
	int phentsize = 32
	int machine = 3
	if (__word_size__ == 8):
		ehsize = 64
		phentsize = 56
		machine = 62
	int phnum = 1 + cd_nseg
	int notes_off = ehsize + phnum * phentsize
	int notes_size = cd_notes_size()
	int data_off = notes_off + notes_size
	data_off = data_off + ((4096 - (data_off & 4095)) & 4095)
	if (data_off > cd_hdr_size):
		close(fd)
		return 0

	# Segment data first; the headers go in last, describing what landed.
	int off = data_off
	int i = 0
	while (i < cd_nseg):
		int got = 0
		if (seek(fd, off, 0) == off): got = cd_copy(fd, cd_seg_get(i, 0), cd_seg_get(i, 1))
		cd_seg_set(i, 3, got)
		off = off + got
		off = off + ((4096 - (off & 4095)) & 4095)
		i = i + 1

	int k = 0
	while (k < data_off):
		cd_hdr[k] = 0
		k = k + 1
	# ELF header
	cd_put8(0, 127)
	cd_put8(1, 'E')
	cd_put8(2, 'L')
	cd_put8(3, 'F')
	cd_put8(4, __word_size__ / 4)
	cd_put8(5, 1) /* little-endian */
	cd_put8(6, 1) /* EV_CURRENT */
	cd_put16(16, 4) /* ET_CORE */
	cd_put16(18, machine)
	cd_put32(20, 1)
	if (__word_size__ == 8):
		cd_putw(32, ehsize) /* e_phoff */
		cd_put16(52, ehsize)
		cd_put16(54, phentsize)
		cd_put16(56, phnum)
	else:
		cd_put32(28, ehsize)
		cd_put16(40, ehsize)
		cd_put16(42, phentsize)
		cd_put16(44, phnum)

	# PT_NOTE
	int ph = ehsize
	cd_put32(ph, 4)
	if (__word_size__ == 8):
		cd_putw(ph + 8, notes_off)
		cd_putw(ph + 32, notes_size)
		cd_putw(ph + 48, 4)
	else:
		cd_put32(ph + 4, notes_off)
		cd_put32(ph + 16, notes_size)
		cd_put32(ph + 28, 4)

	# PT_LOADs
	off = data_off
	i = 0
	while (i < cd_nseg):
		ph = ehsize + (i + 1) * phentsize
		int lo = cd_seg_get(i, 0)
		int len = cd_seg_get(i, 1)
		int flags = cd_seg_get(i, 2)
		int got = cd_seg_get(i, 3)
		cd_put32(ph, 1)
		if (__word_size__ == 8):
			cd_put32(ph + 4, flags)
			cd_putw(ph + 8, off)
			cd_putw(ph + 16, lo)
			cd_putw(ph + 32, got)
			cd_putw(ph + 40, len)
			cd_putw(ph + 48, 4096)
		else:
			cd_put32(ph + 4, off)
			cd_put32(ph + 8, lo)
			cd_put32(ph + 16, got)
			cd_put32(ph + 20, len)
			cd_put32(ph + 24, flags)
			cd_put32(ph + 28, 4096)
		off = off + got
		off = off + ((4096 - (off & 4095)) & 4095)
		i = i + 1

	# NT_PRSTATUS
	int d = cd_note(notes_off, c"CORE", 5, cd_prstatus_size(), 1)
	int code = cd_si_code(sig, context)
	cd_put32(d, sig)          /* pr_info.si_signo */
	cd_put32(d + 4, code)     /* pr_info.si_code */
	cd_put16(d + 12, sig)     /* pr_cursig */
	int pid_off = 24
	int reg_off = 72
	int nregs = 17
	if (__word_size__ == 8):
		pid_off = 32
		reg_off = 112
		nregs = 27
	cd_put32(d + pid_off, getpid())
	for r in range(nregs):
		int roff = cd_reg_off(r)
		if (roff != -3): cd_putw(d + reg_off + r * __word_size__, cd_reg(context, roff))
	# NT_SIGINFO
	d = cd_note(d + (cd_prstatus_size() + 3) / 4 * 4, c"CORE", 5, 128, 0x53494749)
	cd_put32(d, sig)
	cd_put32(d + 8, code)
	if (__word_size__ == 8): cd_putw(d + 16, cd_fault_addr(sig, context))
	else: cd_put32(d + 12, cd_fault_addr(sig, context))
	# W_NT_EXE_PATH
	d = cd_note(d + 128, c"W", 2, cd_exe_len + 1, cd_nt_exe_path)
	k = 0
	while (k < cd_exe_len):
		cd_put8(d + k, cd_exe[k])
		k = k + 1

	int ok = 0
	if (seek(fd, 0, 0) == 0):
		if (cd_copy(fd, cast(int, cd_hdr), data_off) == data_off): ok = 1
	close(fd)
	cd_written_path = ok
	return ok
