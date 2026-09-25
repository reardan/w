# wbuild: binary=wcore arch=x64 staged
/*
wcore: Linux core-dump processor for W binaries (issue #378's tooling half).

Usage: wcore [--json] <core> [<binary>]

Reads an ET_CORE ELF core file of a W-compiled x86 or x86-64 Linux
binary next to the binary that produced it and prints:

  * the fatal signal and the thread's registers, from the core's
    PT_NOTE segment (NT_PRSTATUS; NT_SIGINFO adds the si_code and the
    faulting address when the kernel recorded them),
  * the faulting pc symbolized to "function (file:line)", and
  * a backtrace: the frame-pointer chain from the core's ebp/rbp (the
    live tracer's lib/stack_trace.w st_unwind, reading stack words from
    the core's PT_LOAD segments instead of live memory), exact for
    binaries built with frame pointers, falling back to the heuristic
    return-address scan (st_scan) where the chain breaks.

The word size is detected from the core's ELF class, so one (64-bit)
wcore build processes both 32- and 64-bit cores.

Symbolization reuses lib/stack_trace.w's .symtab/.debug_line lookups
(st_func_entry / st_line_lookup / st_file_name). Those functions read
section bytes at file offsets from the image base and compare pc values
against the absolute target addresses stored in the sections, so they
work unchanged when the "image" is the on-disk binary loaded into a
malloc'd buffer: lib/core_file.w parses the binary's section headers itself
(st_init assumes the running image's class) and points the st_* globals
at the buffer. A binary without .symtab degrades to raw addresses; a
missing .debug_line drops only the file:line part.

Code bytes for the call-site decode come from the binary file (a
kernel core normally omits the read-only text mapping), located through
the binary's program headers; stack words come from the core's PT_LOAD
segments. Like the live tracer, the innermost frame (the faulting pc)
is exact, and so is every older frame the chain yields; frames from
the fallback scan are heuristic (a stale stack slot that still looks
like a return address can add a frame, and a frame can be missing), and
the report says so ("note: part of the trace is heuristic", JSON
"trace_exact": false).

W binaries carry a GNU build-id note (NT_GNU_BUILD_ID, a content hash
of the image) right after their program headers, inside the first file
page, which the kernel copies into the core by default (coredump_filter
bit 4, "ELF headers"). wcore finds the executable's ELF header among the
core's dumped pages, reads the build-id through that copy's PT_NOTE,
and refuses a binary whose build-id differs, since symbolizing against
the wrong binary yields wrong names. When the core has no build-id (the
page was filtered out, or the binary predates build-ids) the check is
skipped with a warning. ELF class and machine are cross-checked too.

Besides kernel cores, wcore reads the dumps W programs write themselves
when W_CRASH_DUMP=<path> is set (lib/crash_dump.w): the same ET_CORE
layout, plus a "W" note (type 0x57455845, "WEXE") naming the crashed
executable, so <binary> may be omitted for them. The report says
"source: W crash handler dump" and --json carries "source":"w_crash_dump"
(or "kernel").

--json prints one JSON object on one line instead of the human report.

Exit status: 0 on success, 1 on a processing error, 2 on usage errors.
This is a leaf tool (not in the seed's import graph); built as a 64-bit
binary by the wcore target so 64-bit core addresses fit in int.

The core-file reading itself (loading, notes, build-ids, registers,
unwinding) lives in lib/core_file.w; this file is argument handling and
the two report formats.
*/
import lib.lib
import lib.stack_trace
import lib.core_file


# --- state ---
int wc_json           /* 1 when --json */
char* wc_core_path
char* wc_bin_path


# --- output helpers ---
void wc_print_hex(int v):
	char* h = cf_hex(v)
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
	if (cf_have_syms):
		e = st_func_entry(addr)
	if (e != 0):
		print(cast(char*, st_entry_name(e)))
	else:
		wc_print_hex(addr)
	if (cf_have_syms):
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
	char* h = cf_hex(v)
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
	wc_json_key(c"source")
	if (cf_exe_note != 0):
		wc_json_str(c"w_crash_dump")
	else:
		wc_json_str(c"kernel")
	put_char(',')
	if (cf_bin_id != 0):
		wc_json_key(c"build_id")
		char* id = cf_id_hex(cf_bin_id, cf_bin_id_size)
		wc_json_str(id)
		free(id)
		put_char(',')
		wc_json_key(c"build_id_verified")
		if (cf_core_id != 0):
			print(c"true")
		else:
			print(c"false")
		put_char(',')
	wc_json_key(c"word_size")
	wc_print_dec(cf_wsize)
	put_char(',')
	wc_json_key(c"signal")
	wc_print_dec(cf_sig)
	put_char(',')
	wc_json_key(c"signal_name")
	wc_json_str(cf_signal_name(cf_sig))
	put_char(',')
	wc_json_key(c"pc")
	wc_json_hex(cf_pc)
	put_char(',')
	wc_json_key(c"sp")
	wc_json_hex(cf_sp)
	if (cf_have_fault()):
		put_char(',')
		wc_json_key(c"fault_address")
		wc_json_hex(cf_fault_addr())
		put_char(',')
		wc_json_key(c"si_code")
		wc_print_dec(cf_si_code())
	put_char(',')
	wc_json_key(c"registers")
	put_char('{')
	int k = 0
	while (k < cf_reg_print_count()):
		if (k > 0):
			put_char(',')
		wc_json_key(cf_reg_print_name(k))
		wc_json_hex(cf_reg(cf_reg_print_index(k)))
		k = k + 1
	put_char('}')
	put_char(',')
	wc_json_key(c"trace_exact")
	if (cf_chain_exact):
		print(c"true")
	else:
		print(c"false")
	put_char(',')
	wc_json_key(c"frames")
	put_char('[')
	for f in range(nframes):
		if (f > 0):
			put_char(',')
		int addr = load_word(&frames[f * __word_size__])
		put_char('{')
		wc_json_key(c"pc")
		wc_json_hex(addr)
		if (cf_have_syms):
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
	put_char(']')
	put_char('}')
	put_char(10)


# --- human output ---
void wc_report(char* frames, int nframes):
	print(c"core: ")
	print(wc_core_path)
	if (cf_class == 2):
		println(c" (x86-64, 64-bit ELF core)")
	else:
		println(c" (x86, 32-bit ELF core)")
	print(c"binary: ")
	println(wc_bin_path)
	if (cf_exe_note != 0):
		println(c"source: W crash handler dump (W_CRASH_DUMP)")
	if (cf_bin_id != 0):
		print(c"build-id: ")
		char* id = cf_id_hex(cf_bin_id, cf_bin_id_size)
		print(id)
		free(id)
		if (cf_core_id != 0):
			println(c" (core and binary match)")
		else:
			println(c" (unverified: the core has no build-id)")
	print(c"signal: ")
	if (cf_sig == 0):
		println(c"none recorded")
	else:
		print(cf_signal_name(cf_sig))
		char* desc = cf_signal_desc(cf_sig)
		if (desc != 0):
			print(c" (")
			print(desc)
			print(c")")
		print(c", signal ")
		wc_print_dec(cf_sig)
		put_char(10)
	if (cf_have_fault()):
		print(c"faulting address: ")
		wc_print_hex(cf_fault_addr())
		print(c" (si_code ")
		wc_print_dec(cf_si_code())
		println(c")")
	print(c"pc: ")
	wc_print_hex(cf_pc)
	int e = 0
	if (cf_have_syms):
		e = st_func_entry(cf_pc)
	if (e != 0):
		print(c"  ")
		print(cast(char*, st_entry_name(e)))
		if (st_line_lookup(cf_pc)):
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
	while (k < cf_reg_print_count()):
		print(c"  ")
		print(cf_reg_print_name(k))
		print(c" ")
		wc_print_hex(cf_reg(cf_reg_print_index(k)))
		put_char(10)
		k = k + 1
	println(c"stack trace (most recent call first):")
	for f in range(nframes):
		wc_print_frame(load_word(&frames[f * __word_size__]))
	if (cf_chain_exact == 0):
		println(c"note: part of the trace is heuristic (return-address scan): frames can be missing or stale")


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


# A loading error from lib/core_file.w, with its file when it names one.
int wc_fail_err(char* msg):
	if (cf_error_path != 0):
		return wc_fail_path(msg, cf_error_path)
	return wc_fail(msg)


int main(int argc, int argv):
	for i in range(1, argc):
		char** slot = argv + i * __word_size__
		char* a = *slot
		if (strcmp(a, c"--json") == 0):
			wc_json = 1
		else if (wc_core_path == 0):
			wc_core_path = a
		else if (wc_bin_path == 0):
			wc_bin_path = a
		else:
			println2(c"usage: wcore [--json] <core> [<binary>]")
			return 2
	if (wc_core_path == 0):
		println2(c"usage: wcore [--json] <core> [<binary>]")
		return 2

	char* err = cf_load_core(wc_core_path)
	if (err != 0):
		return wc_fail_err(err)

	# A dump written by W's own crash handler (lib/crash_dump.w) names
	# its executable, so the binary argument is optional for those.
	if (wc_bin_path == 0):
		if (cf_exe_note == 0):
			println2(c"usage: wcore [--json] <core> <binary>  (the binary may be omitted for W_CRASH_DUMP dumps)")
			return 2
		wc_bin_path = cast(char*, cf_exe_note)
	err = cf_load_binary(wc_bin_path)
	if (err != 0):
		return wc_fail_err(err)

	# A core that names a build-id must come from this exact binary.
	int id_status = cf_check_build_id()
	if (id_status == 1):
		print2(c"wcore: build-id mismatch: the core was produced by build-id ")
		print2(cf_id_hex(cf_core_id, cf_core_id_size))
		if (cf_bin_id == 0):
			println2(c", but the binary has no build-id")
		else:
			print2(c", but the binary is ")
			println2(cf_id_hex(cf_bin_id, cf_bin_id_size))
		return 1
	if (id_status == 2):
		println2(c"wcore: warning: the core records no build-id (its ELF header page was not dumped); cannot confirm it came from this binary")

	err = cf_read_prstatus()
	if (err != 0):
		return wc_fail_err(err)

	cf_load_symbols()
	if (cf_have_syms == 0):
		println2(c"wcore: no .symtab in the binary; raw addresses only")

	# Frame 0 is the faulting pc (exact); the rest follows the
	# frame-pointer chain, falling back to the heuristic scan.
	char* frames = malloc(cf_frames_max() * __word_size__)
	int nframes = cf_backtrace(frames, cf_frames_max())

	if (wc_json):
		wc_json_report(frames, nframes)
	else:
		wc_report(frames, nframes)
	return 0
