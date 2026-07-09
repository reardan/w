/*
wdbg: in-process debugger for W programs.

The target file is compiled into an executable mmap buffer (the same
model as repl.w) and its main() is called directly. Signal handlers are
installed first: every int3 the compiler emits for a 'debugger' statement
(and every breakpoint wdbg patches into the buffer) lands in wdbg_trap,
which drops into an interactive command loop on stdin. Fatal signals
(SIGSEGV, SIGILL, SIGBUS, SIGFPE) enter the same loop for post-mortem
inspection.

Execution control:
	c / continue      resume the debuggee
	s / step          run to the next source line, entering calls
	n / next          run to the next source line, stepping over calls
	si / stepi        execute one machine instruction
	fin / finish      run until the current function returns
	q / quit          exit wdbg
An empty line repeats the previous command.

Breakpoints (patched int3 bytes with the original byte remembered):
	b / break <t>     set a breakpoint; t = function | line | file:line
	tb / tbreak <t>   one-shot breakpoint, deleted when hit
	condition <n> [<expr>]  stop breakpoint n only when <expr> is true
	                  (no expr clears it); evaluated fresh on every hit
	                  with the same in-process compiler print uses
	ignore <n> <count>  skip the next <count> eligible (condition-true)
	                  hits of breakpoint n before it actually stops
	log <t> <expr>    logpoint: like break, but eligible hits print
	                  "logpoint n hit h: expr = value" and auto-continue
	                  instead of stopping (combine with condition/ignore
	                  on the same slot number)
	watch <x|addr>    software watchpoint on a variable's word: while any
	                  exist, resumes single-step statement-by-statement
	                  and stop with an old -> new report on change (slow)
	d / delete <n>    delete breakpoint n; d w <n> deletes watchpoint n
	                  (no argument: delete everything)
	i b               list breakpoints (with condition/ignore/hit counts
	                  and log expressions when set); i w lists watchpoints

Inspection:
	p / print <x>     local/arg/global by name, or compile and run any
	                  W expression in-process (globals and calls work)
	set <x> <v>       write a local, argument or global
	x <addr|name> [n] dump n memory words (addresses probed via /dev/null
	                  writes, so bad pointers cannot crash wdbg)
	bt / backtrace    heuristic stack unwind through return addresses
	f / frame [n]     select frame n (bt numbers); up / down move by one.
	                  print, set, x and info locals/args then address the
	                  selected frame's variables
	st / stack        raw words at the trapped esp
	r / registers     the trapped register file
	l / line          current location (function, file:line)
	list [line]       source listing around the stop
	i locals|args|breakpoints|registers|functions|files

Stepping is driven by the x86 trap flag in the signal frame's eflags:
returning from the handler with TF set raises the next SIGTRAP after one
instruction, and the handler keeps stepping until the source line changes
(step/next/finish consult the recorded line table and the trapped esp).

usage: wdbg <file.w> [--break_start] [--break_end]
   or: w --debug <file.w> [--break_start] [--break_end]

--break_start traps before the debuggee's main runs; --break_end traps
after it returns. End of input on stdin continues execution, so piped
command scripts cannot hang the debuggee.

This file is the whole debugger as a library around wdbg_main();
debugger/debugger.w wraps it as the standalone wdbg binary and w.w
dispatches to it for --debug.
*/
import compiler.compiler
import lib.args
import lib.line_edit
import debugger.sigcontext
import debugger.memory
import debugger.lines
import debugger.symbols
import debugger.locals
import debugger.breakpoints
import debugger.watchpoints
import debugger.eval


# Stepping state machine, consumed by the SIGTRAP handler.
int dbg_step_none():
	return 0
int dbg_step_insn():
	return 1
int dbg_step_line_mode():
	return 2
int dbg_step_over():
	return 3
int dbg_step_finish():
	return 4

int dbg_step_mode
int dbg_step_line   /* source line at the step's start */
int dbg_step_file   /* source file index at the step's start */
int dbg_step_esp    /* esp at the step's start (frame depth) */
int dbg_step_stack  /* compile-time stack words at the start statement */
int dbg_step_fstart /* enclosing function range at the step's start */
int dbg_step_fend
int dbg_step_count
int dbg_rearm_bp   /* breakpoint to re-arm after one single-step, or -1 */
int dbg_fatal_stop /* 1 while stopped on a fatal signal: no resuming */

char* dbg_last_command


# Read one command line from stdin with line editing and history on a
# tty; returns its length, -1 on EOF, -2 when discarded with Ctrl-C.
int wdbg_read_command(char* buf, int size):
	return line_edit_read(c"wdbg> ", buf, size, 0)


# Terminate the first word of s and return the rest (spaces skipped).
char* dbg_split_word(char* s):
	int i = 0
	while ((s[i] != 0) & (s[i] != ' ')):
		i = i + 1
	if (s[i] == 0):
		return s + i
	s[i] = 0
	i = i + 1
	while (s[i] == ' '):
		i = i + 1
	return s + i


# Parse "123", "-4" or "0x1f".
int dbg_number(char* s):
	if (starts_with(s, c"0x")):
		return from_hex(s)
	return atoi(s)


int dbg_is_identifier(char* s):
	if (s[0] == 0):
		return 0
	int i = 0
	while (s[i]):
		int c = s[i]
		int ok = 0
		if (('a' <= c) & (c <= 'z')):
			ok = 1
		if (('A' <= c) & (c <= 'Z')):
			ok = 1
		if (c == '_'):
			ok = 1
		if ((i > 0) & ('0' <= c) & (c <= '9')):
			ok = 1
		if (ok == 0):
			return 0
		i = i + 1
	return 1


void wdbg_print_register(char* name, int value):
	print(name)
	print(c": ")
	char* h = hex_word(value)
	println(h)
	free(h)


void wdbg_print_registers(int context):
	if (__word_size__ == 8):
		wdbg_print_register(c"rax", ctx_reg(context, sigcontext_eax()))
		wdbg_print_register(c"rcx", ctx_reg(context, sigcontext_ecx()))
		wdbg_print_register(c"rdx", ctx_reg(context, sigcontext_edx()))
		wdbg_print_register(c"rbx", ctx_reg(context, sigcontext_ebx()))
		wdbg_print_register(c"rsp", ctx_reg(context, sigcontext_esp()))
		wdbg_print_register(c"rbp", ctx_reg(context, sigcontext_ebp()))
		wdbg_print_register(c"rsi", ctx_reg(context, sigcontext_esi()))
		wdbg_print_register(c"rdi", ctx_reg(context, sigcontext_edi()))
		wdbg_print_register(c"r8", ctx_reg(context, sigcontext_r8()))
		wdbg_print_register(c"r9", ctx_reg(context, sigcontext_r9()))
		wdbg_print_register(c"r10", ctx_reg(context, sigcontext_r10()))
		wdbg_print_register(c"r11", ctx_reg(context, sigcontext_r11()))
		wdbg_print_register(c"r12", ctx_reg(context, sigcontext_r12()))
		wdbg_print_register(c"r13", ctx_reg(context, sigcontext_r13()))
		wdbg_print_register(c"r14", ctx_reg(context, sigcontext_r14()))
		wdbg_print_register(c"r15", ctx_reg(context, sigcontext_r15()))
		wdbg_print_register(c"rip", ctx_reg(context, sigcontext_eip()))
		wdbg_print_register(c"eflags", ctx_reg(context, sigcontext_eflags()))
		return;
	wdbg_print_register(c"eax", ctx_reg(context, sigcontext_eax()))
	wdbg_print_register(c"ecx", ctx_reg(context, sigcontext_ecx()))
	wdbg_print_register(c"edx", ctx_reg(context, sigcontext_edx()))
	wdbg_print_register(c"ebx", ctx_reg(context, sigcontext_ebx()))
	wdbg_print_register(c"esp", ctx_reg(context, sigcontext_esp()))
	wdbg_print_register(c"ebp", ctx_reg(context, sigcontext_ebp()))
	wdbg_print_register(c"esi", ctx_reg(context, sigcontext_esi()))
	wdbg_print_register(c"edi", ctx_reg(context, sigcontext_edi()))
	wdbg_print_register(c"eip", ctx_reg(context, sigcontext_eip()))
	wdbg_print_register(c"eflags", ctx_reg(context, sigcontext_eflags()))


void wdbg_print_stack(int context):
	int esp = ctx_esp(context)
	int i = 0
	while (i < 16):
		int slot = esp + i * __word_size__
		char* ha = hex_word(slot)
		print(ha)
		free(ha)
		print(c": ")
		if (dbg_mem_readable(slot, __word_size__)):
			char* hv = hex_word(load_word(cast(char*, slot)))
			println(hv)
			free(hv)
		else:
			println(c"<unreadable>")
		i = i + 1


# "function (file:line)" for an absolute statement address.
void dbg_announce_location(int addr):
	print(dbg_function_name(addr))
	print(c" (")
	dbg_print_file_line(addr)
	println(c")")


# 1 when v looks like a return address: the bytes before it decode as one
# of the compiler's call forms (call *eax, or call rel32 in asm stubs).
int dbg_looks_like_return(int v):
	if (dbg_in_debuggee(v - 2)):
		if ((bp_read_byte(v - 2) == 255) & (bp_read_byte(v - 1) == 208)):
			return 1
	if (dbg_in_debuggee(v - 5)):
		if (bp_read_byte(v - 5) == 232):
			return 1
	return 0


# ---------------------------------------------------------------------------
# Frame list and selection.
#
# At every stop the stack is scanned once (heuristically, through
# plausible return addresses) into a frame list holding each frame's pc
# and its frame base: the esp at the frame's function entry, which is
# the address of the stack slot holding its return address. The scan
# ends at the debuggee's entry function; its own return address points
# into wdbg itself and is recognized by the same call-site byte check.
#
# frame <n> / up / down select a frame; print, set, x and info
# locals/args then address that frame's variables through its statement
# stack depth (esp at a statement boundary = base - depth * word), the
# same arithmetic frame 0 uses with the trapped esp.

int dbg_fr_max():
	return 16

char* dbg_fr_pc /* absolute pc per frame (word slots) */
char* dbg_fr_base /* frame base per frame, 0 = unknown (word slots) */
int dbg_fr_count
int dbg_fr_sel


void dbg_fr_store(int pc, int base):
	if (dbg_fr_count >= dbg_fr_max()):
		return;
	save_word(dbg_fr_pc + dbg_fr_count * __word_size__, pc)
	save_word(dbg_fr_base + dbg_fr_count * __word_size__, base)
	dbg_fr_count = dbg_fr_count + 1


# 1 when v looks like a return address into wdbg's own image: readable
# memory just before it that decodes as the compiler's call *reg form.
int dbg_looks_like_wdbg_return(int v):
	if (dbg_in_debuggee(v)):
		return 0
	if (dbg_mem_readable(v - 2, 2) == 0):
		return 0
	return (bp_read_byte(v - 2) == 255) & (bp_read_byte(v - 1) == 208)


void dbg_frames_compute(int context, int stop_addr):
	if (dbg_fr_pc == 0):
		dbg_fr_pc = malloc(dbg_fr_max() * __word_size__)
		dbg_fr_base = malloc(dbg_fr_max() * __word_size__)
	dbg_fr_count = 0
	dbg_fr_sel = 0
	int esp = ctx_esp(context)
	int base0 = 0
	if (dbg_in_debuggee(stop_addr)):
		int entry = dbg_find_line(stop_addr - code_offset)
		if (entry >= 0):
			if (dbg_line_stack(entry) >= 0):
				base0 = esp + dbg_line_stack(entry) * __word_size__
	dbg_fr_store(stop_addr, base0)
	int main_at = dbg_function_at(sym_address(c"main"))
	int outermost = (dbg_function_at(stop_addr) == main_at)
	int i = 0
	while ((i < 2048) & (dbg_fr_count < dbg_fr_max())):
		int slot = esp + i * __word_size__
		if (dbg_mem_readable(slot, __word_size__) == 0):
			return;
		int v = load_word(cast(char*, slot))
		if (outermost):
			# Only the entry function's own base is missing: its return
			# address is the first plausible wdbg call site on the stack
			if (dbg_looks_like_wdbg_return(v)):
				save_word(dbg_fr_base + (dbg_fr_count - 1) * __word_size__, slot)
				return;
		else if (dbg_in_debuggee(v)):
			if (dbg_looks_like_return(v)):
				# v's slot is the previous frame's function entry esp
				save_word(dbg_fr_base + (dbg_fr_count - 1) * __word_size__, slot)
				dbg_fr_store(v - 1, 0)
				if (dbg_function_at(v - 1) == main_at):
					outermost = 1
		i = i + 1


int dbg_fr_pc_at(int n):
	return load_word(dbg_fr_pc + n * __word_size__)


int dbg_fr_base_at(int n):
	return load_word(dbg_fr_base + n * __word_size__)


# The selected frame's pc: the stop address for frame 0, the address
# inside the calling statement for older frames.
int dbg_sel_pc(int stop_addr):
	if ((dbg_fr_sel <= 0) | (dbg_fr_sel >= dbg_fr_count)):
		return stop_addr
	return dbg_fr_pc_at(dbg_fr_sel)


# esp at the selected frame's statement boundary, or 0 when the frame's
# base or line info is unknown (locals cannot be addressed then).
int dbg_sel_esp(int context):
	if ((dbg_fr_sel <= 0) | (dbg_fr_sel >= dbg_fr_count)):
		return ctx_esp(context)
	int base = dbg_fr_base_at(dbg_fr_sel)
	if (base == 0):
		return 0
	int pc = dbg_fr_pc_at(dbg_fr_sel)
	if (dbg_in_debuggee(pc) == 0):
		return 0
	int entry = dbg_find_line(pc - code_offset)
	if (entry < 0):
		return 0
	int depth = dbg_line_stack(entry)
	if (depth < 0):
		return 0
	return base - depth * __word_size__


void dbg_frame_announce(int n):
	print(c"#")
	char* digits = itoa(n)
	print(digits)
	free(digits)
	print(c"  ")
	dbg_announce_location(dbg_fr_pc_at(n))


void dbg_frame_select(int context, int n):
	dbg_fr_sel = n
	dbg_frame_announce(n)
	dbg_print_source_at(dbg_fr_pc_at(n))
	if (n > 0):
		if (dbg_sel_esp(context) == 0):
			println(c"(frame base unknown: locals are not addressable here)")


# frame [n]: select a frame (no argument: show the selected frame).
void dbg_frame_command(int context, char* arg):
	int n = dbg_fr_sel
	if (arg[0] != 0):
		n = atoi(arg)
		if ((n < 0) | (n >= dbg_fr_count)):
			print(c"no frame ")
			println(arg)
			return;
	dbg_frame_select(context, n)


# Heuristic backtrace over the stored frame list.
void dbg_backtrace():
	int k = 0
	while (k < dbg_fr_count):
		dbg_frame_announce(k)
		k = k + 1


void dbg_examine(int addr, int count):
	int i = 0
	while (i < count):
		int slot = addr + i * __word_size__
		char* ha = hex_word(slot)
		print(ha)
		free(ha)
		print(c": ")
		if (dbg_mem_readable(slot, __word_size__)):
			char* hv = hex_word(load_word(cast(char*, slot)))
			println(hv)
			free(hv)
		else:
			println(c"<unreadable>")
			return;
		i = i + 1


# print <arg>: locals and args by name first, then defined globals, then
# the expression compiler. pc/esp describe the selected frame.
void dbg_print_command(int pc, int esp, char* arg):
	if (arg[0] == 0):
		println(c"usage: print <name | expression>")
		return;
	if (dbg_is_identifier(arg)):
		int note = dbg_local_find(arg, pc)
		if (note >= 0):
			dbg_print_local(note, esp)
			return;
		int g = dbg_global_find(arg)
		if (g >= 0):
			if (dbg_sym_symtype(g) != 2):
				print(arg)
				print(c" = ")
				dbg_print_typed_value(dbg_sym_address(g), dbg_sym_type(g))
				put_char(10)
				return;
	dbg_eval(arg, pc, esp)


# set <name> <value>: writes a local, argument or global word.
void dbg_set_command(int pc, int esp, char* arg):
	char* value_text = dbg_split_word(arg)
	if ((arg[0] == 0) | (value_text[0] == 0)):
		println(c"usage: set <name> <value>")
		return;
	int v = dbg_number(value_text)
	int note = dbg_local_find(arg, pc)
	if (note >= 0):
		int addr = dbg_local_runtime_addr(note, esp)
		if (dbg_mem_readable(addr, __word_size__) == 0):
			println(c"variable is not addressable here")
			return;
		save_word(cast(char*, addr), v)
		dbg_print_local(note, esp)
		return;
	int g = dbg_global_find(arg)
	if (g >= 0):
		if (dbg_sym_symtype(g) != 2):
			save_word(cast(char*, dbg_sym_address(g)), v)
			print(arg)
			print(c" = ")
			dbg_print_typed_value(dbg_sym_address(g), dbg_sym_type(g))
			put_char(10)
			return;
	print(c"unknown variable: ")
	println(arg)


# watch <name | address>: record the variable's storage word (in the
# selected frame, for locals) for the software watch scan.
void dbg_watch_command(int pc, int esp, char* arg):
	if (arg[0] == 0):
		println(c"usage: watch <name | address>")
		return;
	int addr = 0
	int note = -1
	if (((arg[0] >= '0') & (arg[0] <= '9')) | (arg[0] == '-')):
		addr = dbg_number(arg)
	else:
		note = dbg_local_find(arg, pc)
		if (note >= 0):
			addr = dbg_local_runtime_addr(note, esp)
		else:
			int g = dbg_global_find(arg)
			if ((g < 0) | (dbg_sym_symtype(g) == 2)):
				print(c"unknown variable: ")
				println(arg)
				return;
			addr = dbg_sym_address(g)
	if (dbg_mem_readable(addr, __word_size__) == 0):
		println(c"address is not readable")
		return;
	int w = dbg_watch_add(arg, addr)
	if (w < 0):
		return;
	dbg_watch_describe(w)
	put_char(10)
	if (note >= 0):
		println(c"(watches this frame's stack slot: meaningless after the function returns)")
	println(c"(software watchpoints single-step the program: expect a slowdown)")


# Source file index at stop_addr, or -1 when unknown: what a bare line
# number resolves against for break/tbreak/log targets.
int dbg_current_file(int stop_addr):
	if (dbg_in_debuggee(stop_addr) == 0):
		return -1
	int entry = dbg_find_line(stop_addr - code_offset)
	if (entry < 0):
		return -1
	return dbg_line_file(entry)


# condition <n> [<expr>]: set or clear breakpoint n's stop condition.
void dbg_condition_command(char* arg):
	char* rest = dbg_split_word(arg)
	if (arg[0] == 0):
		println(c"usage: condition <n> [<expr>]")
		return;
	int n = atoi(arg) - 1
	if ((n < 0) | (n >= bp_used)):
		println(c"no such breakpoint")
		return;
	if (bp_addr(n) == 0):
		println(c"no such breakpoint")
		return;
	bp_set_condition(n, rest)
	print(c"breakpoint ")
	char* digits = itoa(n + 1)
	print(digits)
	free(digits)
	if (rest[0] == 0):
		println(c": condition cleared")
	else:
		println(c": condition set")


# ignore <n> <count>: skip the next <count> eligible (condition-true)
# hits of breakpoint n before it actually stops.
void dbg_ignore_command(char* arg):
	char* count_text = dbg_split_word(arg)
	if ((arg[0] == 0) | (count_text[0] == 0)):
		println(c"usage: ignore <n> <count>")
		return;
	int n = atoi(arg) - 1
	if ((n < 0) | (n >= bp_used)):
		println(c"no such breakpoint")
		return;
	if (bp_addr(n) == 0):
		println(c"no such breakpoint")
		return;
	int count = dbg_number(count_text)
	if (count < 0):
		count = 0
	bp_set_ignore(n, count)
	print(c"breakpoint ")
	char* digits = itoa(n + 1)
	print(digits)
	free(digits)
	print(c": will ignore the next ")
	char* cd = itoa(count)
	print(cd)
	free(cd)
	println(c" eligible hits")


# log <function | line | file:line> <expr>: like 'break', but the new
# slot is a logpoint - eligible hits print <expr> and auto-continue.
void dbg_log_command(int current_file, char* arg):
	char* expr = dbg_split_word(arg)
	if ((arg[0] == 0) | (expr[0] == 0)):
		println(c"usage: log <function | line | file:line> <expr>")
		return;
	int addr = bp_resolve_target(arg, current_file)
	if (addr == 0):
		return;
	int slot = bp_add(addr, 0)
	if (slot < 0):
		return;
	bp_set_log(slot, expr)
	bp_describe(slot)
	put_char(10)


# x <addr|name> [count]
void dbg_examine_command(int pc, int esp, char* arg):
	char* count_text = dbg_split_word(arg)
	if (arg[0] == 0):
		println(c"usage: x <address | name> [count]")
		return;
	int addr = 0
	if (((arg[0] >= '0') & (arg[0] <= '9')) | (arg[0] == '-')):
		addr = dbg_number(arg)
	else:
		int note = dbg_local_find(arg, pc)
		if (note >= 0):
			addr = load_word(cast(char*, dbg_local_runtime_addr(note, esp)))
		else:
			int g = dbg_global_find(arg)
			if (g < 0):
				print(c"unknown name: ")
				println(arg)
				return;
			if (dbg_sym_symtype(g) == 2):
				addr = dbg_sym_address(g)
			else:
				addr = load_word(cast(char*, dbg_sym_address(g)))
	int count = 8
	if (count_text[0] != 0):
		count = dbg_number(count_text)
	if (count < 1):
		count = 1
	if (count > 1024):
		count = 1024
	dbg_examine(addr, count)


void dbg_list_command(int stop_addr, char* arg):
	if (dbg_in_debuggee(stop_addr) == 0):
		println(c"no line info (address is outside the debuggee)")
		return;
	int entry = dbg_find_line(stop_addr - code_offset)
	if (entry < 0):
		println(c"no line info recorded")
		return;
	int current = dbg_line_line(entry)
	int center = current
	if (arg[0] != 0):
		center = dbg_number(arg)
	dbg_print_source_range(dbg_file_name(dbg_line_file(entry)), center - 5, center + 5, current)


# pc/esp describe the selected frame (used by info locals/args).
void dbg_info_command(int context, int pc, int esp, char* arg):
	char* rest = dbg_split_word(arg)
	if ((strcmp(arg, c"b") == 0) | (strcmp(arg, c"breakpoints") == 0)):
		bp_list()
	else if ((strcmp(arg, c"r") == 0) | (strcmp(arg, c"registers") == 0)):
		wdbg_print_registers(context)
	else if ((strcmp(arg, c"l") == 0) | (strcmp(arg, c"locals") == 0)):
		dbg_print_frame_vars(pc, esp, 'L')
	else if ((strcmp(arg, c"a") == 0) | (strcmp(arg, c"args") == 0)):
		dbg_print_frame_vars(pc, esp, 'A')
	else if ((strcmp(arg, c"w") == 0) | (strcmp(arg, c"watchpoints") == 0)):
		dbg_watch_list()
	else if ((strcmp(arg, c"f") == 0) | (strcmp(arg, c"functions") == 0)):
		dbg_print_functions()
	else if (strcmp(arg, c"files") == 0):
		int i = 0
		while (i < debug_file_count):
			println(str_from_cstr(cast(char*, load_ptr(debug_files + i * __word_size__))))
			i = i + 1
	else:
		println(c"info topics: breakpoints watchpoints registers locals args functions files")


void dbg_help():
	println(c"execution:")
	println(c"  c/continue  s/step  n/next  si/stepi  fin/finish  q/quit")
	println(c"breakpoints:")
	println(c"  b/break <function | line | file:line>   tb/tbreak <target>")
	println(c"  condition <n> [<expr>]   ignore <n> <count>")
	println(c"  log <target> <expr> (logpoint: prints and auto-continues)")
	println(c"  watch <name | address> (software watchpoint; slow while set)")
	println(c"  d/delete [n]   d w [n]   i b / i w (list)")
	println(c"inspection:")
	println(c"  p/print <name | expression>   set <name> <value>")
	println(c"  x <addr | name> [count]   bt/backtrace   st/stack")
	println(c"  f/frame [n]   up   down   (select the frame p/set/x/info use)")
	println(c"  r/registers   l/line   list [line]")
	println(c"  i locals | args | breakpoints | registers | functions | files")
	println(c"an empty line repeats the previous command")


# Configure the resume: step mode bookkeeping, the trap flag when
# stepping, and the one-step re-arm dance when a disarmed breakpoint sits
# at the resume address.
void dbg_prepare_resume(int context, int stop_addr, int mode):
	dbg_step_mode = mode
	dbg_step_count = 0
	dbg_step_esp = ctx_esp(context)
	dbg_step_line = -1
	dbg_step_file = -1
	dbg_step_stack = -1
	dbg_step_fstart = 0
	dbg_step_fend = 0
	if (dbg_in_debuggee(stop_addr)):
		int entry = dbg_find_line(stop_addr - code_offset)
		if (entry >= 0):
			dbg_step_line = dbg_line_line(entry)
			dbg_step_file = dbg_line_file(entry)
			dbg_step_stack = dbg_line_stack(entry)
		int f = dbg_function_at(stop_addr)
		if (f >= 0):
			dbg_step_fstart = dbg_sym_address(f)
			dbg_step_fend = dbg_step_fstart + dbg_sym_size(f)
	int bp = bp_find(ctx_eip(context))
	if (bp >= 0):
		bp_disarm(bp)
		dbg_rearm_bp = bp
		ctx_set_trap_flag(context)
	else if (mode != dbg_step_none()):
		ctx_set_trap_flag(context)
	# Live watchpoints turn every resume into a single-step scan
	if (dbg_watch_live() > 0):
		ctx_set_trap_flag(context)


# Interactive command loop. Returning resumes the debuggee.
void wdbg_command_loop(int context, int stop_addr):
	dbg_frames_compute(context, stop_addr)
	char* command = malloc(256)
	while (1):
		int n = wdbg_read_command(command, 256)
		if (n == -2):
			continue /* Ctrl-C: fresh prompt, do not repeat the last command */
		if (n < 0):
			println(c"(end of input: continuing)")
			free(command)
			if (dbg_fatal_stop):
				exit(1)
			return;
		if (n == 0):
			if (dbg_last_command == 0):
				continue
			strcpy(command, dbg_last_command)
		else:
			if (dbg_last_command == 0):
				dbg_last_command = malloc(256)
			strcpy(dbg_last_command, command)

		char* arg = dbg_split_word(command)
		int resume_mode = -1

		if ((strcmp(command, c"c") == 0) | (strcmp(command, c"continue") == 0)):
			resume_mode = dbg_step_none()
		else if ((strcmp(command, c"s") == 0) | (strcmp(command, c"step") == 0)):
			resume_mode = dbg_step_line_mode()
		else if ((strcmp(command, c"n") == 0) | (strcmp(command, c"next") == 0)):
			resume_mode = dbg_step_over()
		else if ((strcmp(command, c"si") == 0) | (strcmp(command, c"stepi") == 0)):
			resume_mode = dbg_step_insn()
		else if ((strcmp(command, c"fin") == 0) | (strcmp(command, c"finish") == 0)):
			resume_mode = dbg_step_finish()
		else if ((strcmp(command, c"q") == 0) | (strcmp(command, c"quit") == 0)):
			exit(0)
		else if ((strcmp(command, c"r") == 0) | (strcmp(command, c"registers") == 0)):
			wdbg_print_registers(context)
		else if ((strcmp(command, c"st") == 0) | (strcmp(command, c"stack") == 0)):
			wdbg_print_stack(context)
		else if ((strcmp(command, c"l") == 0) | (strcmp(command, c"line") == 0) | (strcmp(command, c"where") == 0)):
			dbg_announce_location(dbg_sel_pc(stop_addr))
		else if (strcmp(command, c"list") == 0):
			dbg_list_command(dbg_sel_pc(stop_addr), arg)
		else if ((strcmp(command, c"b") == 0) | (strcmp(command, c"break") == 0) | (strcmp(command, c"tb") == 0) | (strcmp(command, c"tbreak") == 0)):
			int temp = 0
			if ((command[0] == 't') & (command[1] == 'b')):
				temp = 1
			if (strcmp(command, c"tbreak") == 0):
				temp = 1
			int addr = bp_resolve_target(arg, dbg_current_file(stop_addr))
			if (addr != 0):
				int slot = bp_add(addr, temp)
				if (slot >= 0):
					bp_describe(slot)
					put_char(10)
		else if (strcmp(command, c"condition") == 0):
			dbg_condition_command(arg)
		else if (strcmp(command, c"ignore") == 0):
			dbg_ignore_command(arg)
		else if (strcmp(command, c"log") == 0):
			dbg_log_command(dbg_current_file(stop_addr), arg)
		else if ((strcmp(command, c"d") == 0) | (strcmp(command, c"delete") == 0)):
			if ((arg[0] == 0) | (strcmp(arg, c"all") == 0)):
				bp_delete_all()
				dbg_watch_delete_all()
				println(c"all breakpoints and watchpoints deleted")
			else:
				char* wnum = dbg_split_word(arg)
				if ((strcmp(arg, c"w") == 0) | (strcmp(arg, c"watch") == 0)):
					if (wnum[0] == 0):
						dbg_watch_delete_all()
						println(c"all watchpoints deleted")
					else:
						dbg_watch_delete(atoi(wnum) - 1)
				else:
					bp_delete(atoi(arg) - 1)
		else if ((strcmp(command, c"i") == 0) | (strcmp(command, c"info") == 0)):
			dbg_info_command(context, dbg_sel_pc(stop_addr), dbg_sel_esp(context), arg)
		else if ((strcmp(command, c"bt") == 0) | (strcmp(command, c"backtrace") == 0)):
			dbg_backtrace()
		else if ((strcmp(command, c"f") == 0) | (strcmp(command, c"frame") == 0)):
			dbg_frame_command(context, arg)
		else if (strcmp(command, c"up") == 0):
			if (dbg_fr_sel + 1 >= dbg_fr_count):
				println(c"no caller frame")
			else:
				dbg_frame_select(context, dbg_fr_sel + 1)
		else if (strcmp(command, c"down") == 0):
			if (dbg_fr_sel <= 0):
				println(c"already at the innermost frame")
			else:
				dbg_frame_select(context, dbg_fr_sel - 1)
		else if ((strcmp(command, c"p") == 0) | (strcmp(command, c"print") == 0)):
			dbg_print_command(dbg_sel_pc(stop_addr), dbg_sel_esp(context), arg)
		else if (strcmp(command, c"set") == 0):
			dbg_set_command(dbg_sel_pc(stop_addr), dbg_sel_esp(context), arg)
		else if (strcmp(command, c"x") == 0):
			dbg_examine_command(dbg_sel_pc(stop_addr), dbg_sel_esp(context), arg)
		else if (strcmp(command, c"watch") == 0):
			dbg_watch_command(dbg_sel_pc(stop_addr), dbg_sel_esp(context), arg)
		else if ((strcmp(command, c"h") == 0) | (strcmp(command, c"help") == 0) | (strcmp(command, c"?") == 0)):
			dbg_help()
		else:
			println(c"unknown command; type 'help' for the command list")

		if (resume_mode >= 0):
			if (dbg_fatal_stop):
				println(c"cannot resume after a fatal signal: exiting")
				exit(1)
			# A 'debugger' statement is a whole one-byte statement that has
			# already executed, leaving eip at the next statement's start.
			# Stepping from it only moves the reported position there.
			if ((resume_mode == dbg_step_line_mode()) | (resume_mode == dbg_step_over())):
				int reip = ctx_eip(context)
				if (dbg_in_debuggee(reip)):
					int rentry = dbg_find_line(reip - code_offset)
					if (rentry >= 0):
						if (reip == code_offset + dbg_line_addr(rentry)):
							int sentry = -1
							if (dbg_in_debuggee(stop_addr)):
								sentry = dbg_find_line(stop_addr - code_offset)
							int same = 0
							if (sentry >= 0):
								if ((dbg_line_line(rentry) == dbg_line_line(sentry)) & (dbg_line_file(rentry) == dbg_line_file(sentry))):
									same = 1
							if (same == 0):
								stop_addr = reip
								dbg_frames_compute(context, stop_addr)
								dbg_announce_location(stop_addr)
								dbg_print_source_at(stop_addr)
								continue
			dbg_prepare_resume(context, stop_addr, resume_mode)
			free(command)
			return;


# Announce a stop, reset the stepping state and enter the command loop.
void wdbg_stop_loop(int context, int stop_addr):
	dbg_step_mode = dbg_step_none()
	ctx_clear_trap_flag(context)
	wdbg_command_loop(context, stop_addr)


# Stop conditions for the stepping modes, evaluated once per instruction.
#
# The frame base (esp at the enclosing function's entry, where its return
# address sits) anchors everything: it is dbg_step_esp + 4 * the recorded
# stack depth of the starting statement, it never changes while the frame
# is live, and every statement boundary in the frame has the exact esp
# frame_base - 4 * that statement's recorded depth. Comparing esp against
# it separates this frame from callees (deeper), recursive instances
# (different base) and callers (shallower), without frame pointers.
int dbg_step_should_stop(int context, int eip):
	if (dbg_step_mode == dbg_step_insn()):
		return 1
	if (dbg_in_debuggee(eip) == 0):
		return 0 /* inside wdbg itself (e.g. between --break_start and main) */
	int entry = dbg_find_line(eip - code_offset)
	if (entry < 0):
		return 0 /* runtime asm stubs have no line info */
	int esp = ctx_esp(context)
	int frame_base = dbg_step_esp
	if (dbg_step_stack >= 0):
		frame_base = dbg_step_esp + dbg_step_stack * __word_size__

	if (dbg_step_mode == dbg_step_finish()):
		return esp > frame_base

	# step/next only stop at exact statement starts: local addressing is
	# only accurate there, and every jump target is one. Returning from a
	# call lands mid-statement and glides on to the next boundary.
	if (eip != code_offset + dbg_line_addr(entry)):
		return 0
	if ((dbg_line_line(entry) == dbg_step_line) & (dbg_line_file(entry) == dbg_step_file)):
		return 0
	if (dbg_step_mode == dbg_step_over()):
		if (dbg_step_fstart == 0):
			return 1 /* unknown starting frame: behave like step */
		if (esp > frame_base):
			return 1 /* returned past the starting frame */
		if ((eip >= dbg_step_fstart) & (eip < dbg_step_fend)):
			if (esp == frame_base - dbg_line_stack(entry) * __word_size__):
				return 1 /* a statement boundary of the starting frame */
		return 0
	return 1


# A logpoint's eligible hit: evaluate its expression and print one line,
# never entering the command loop. Sets dbg_eval_ok like dbg_eval_call
# (0 on a compile error) so the caller can decide whether to keep
# auto-continuing or fail closed and stop.
void dbg_log_report(int bp, int addr, int esp):
	print(c"logpoint ")
	char* digits = itoa(bp + 1)
	print(digits)
	free(digits)
	print(c" hit ")
	char* hd = itoa(bp_hits(bp))
	print(hd)
	free(hd)
	print(c": ")
	print(bp_log_expr(bp))
	print(c" = ")
	int v = dbg_eval_call(bp_log_expr(bp), addr, esp)
	if (dbg_eval_ok):
		dbg_print_int_value(v)
		put_char(10)
	else:
		println(c"<failed to compile>")


# SIGTRAP handler: breakpoints and 'debugger' statements arrive as int3
# (trapno 3, eip past the int3 byte); trap-flag single-steps arrive as
# debug exceptions (trapno 1, eip exact). Returning resumes the debuggee
# through the kernel's sigreturn path. context points at the sigcontext;
# the arch-specific entry shims below compute it.
void wdbg_trap(int sig, int context):
	int eip = ctx_eip(context)

	# One instruction has executed since a breakpoint was resumed: put its
	# int3 back before anything else happens
	if (dbg_rearm_bp >= 0):
		bp_arm(dbg_rearm_bp)
		dbg_rearm_bp = -1

	if (ctx_trapno(context) == 3):
		int addr = eip - 1
		int bp = bp_find(addr)
		if (bp >= 0):
			# Restore the original byte and rewind eip so it executes
			bp_disarm(bp)
			ctx_set_eip(context, addr)
			bp_hit_increment(bp)

			# Gate the stop: condition -> ignore count -> logpoint. A
			# condition that fails to compile fails closed (stops, with
			# a diagnostic) rather than silently never stopping.
			int stop = 1
			if (bp_condition(bp) != 0):
				int cv = dbg_eval_call(bp_condition(bp), addr, ctx_esp(context))
				if (dbg_eval_ok == 0):
					print(c"condition on breakpoint ")
					char* cdigits = itoa(bp + 1)
					print(cdigits)
					free(cdigits)
					println(c" failed to compile: stopping unconditionally")
					stop = 1
				else:
					stop = cv != 0
			if (stop):
				if (bp_ignore(bp) > 0):
					bp_set_ignore(bp, bp_ignore(bp) - 1)
					stop = 0
			if (stop):
				if (bp_is_log(bp)):
					dbg_log_report(bp, addr, ctx_esp(context))
					# a log expression compile error falls through to
					# stop, so a broken logpoint is visible once
					# instead of silently spinning forever
					if (dbg_eval_ok):
						stop = 0
			if (stop == 0):
				# Same re-arm dance 'c' uses to resume over an armed
				# breakpoint: rewinds eip already happened above, so
				# this just re-establishes the one-step re-arm and any
				# live-watchpoint single-stepping before returning.
				dbg_prepare_resume(context, addr, dbg_step_none())
				return;

			print(c"hit ")
			bp_describe(bp)
			put_char(10)
			if (bp_is_temp(bp)):
				bp_delete(bp)
			dbg_print_source_at(addr)
			wdbg_stop_loop(context, addr)
			return;
		# A compiled-in 'debugger' statement (or --break_start/--break_end)
		print(c"breakpoint hit at eip=")
		char* h = hex_word(eip)
		println(h)
		free(h)
		dbg_announce_location(addr)
		dbg_print_source_at(addr)
		wdbg_stop_loop(context, addr)
		return;

	# Single-step trap. The watchpoint scan comes first: at every
	# statement boundary compare each watched word with its remembered
	# value and stop on the first change, whatever mode is stepping.
	if (dbg_watch_live() > 0):
		if (dbg_in_debuggee(eip)):
			int wentry = dbg_find_line(eip - code_offset)
			if (wentry >= 0):
				if (eip == code_offset + dbg_line_addr(wentry)):
					int w = dbg_watch_check()
					if (w >= 0):
						dbg_watch_report(w)
						dbg_announce_location(eip)
						dbg_print_source_at(eip)
						wdbg_stop_loop(context, eip)
						return;
	if (dbg_step_mode == dbg_step_none()):
		if (dbg_watch_live() > 0):
			# 'continue' with watchpoints: keep scanning until execution
			# returns past the resume point into wdbg itself
			if (dbg_in_debuggee(eip)):
				ctx_set_trap_flag(context)
				return;
			if (ctx_esp(context) <= dbg_step_esp):
				ctx_set_trap_flag(context)
				return;
		# The step only existed to re-arm a breakpoint: full speed again
		ctx_clear_trap_flag(context)
		return;
	dbg_step_count = dbg_step_count + 1
	if (dbg_step_count > 500000):
		println(c"step: no source boundary found: continuing")
		dbg_step_mode = dbg_step_none()
		if (dbg_watch_live() == 0):
			ctx_clear_trap_flag(context)
		return;
	# Returning past the debuggee's main into wdbg itself ends the step
	if (dbg_in_debuggee(eip) == 0):
		if (ctx_esp(context) > dbg_step_esp):
			println(c"(step left the debuggee: continuing)")
			dbg_step_mode = dbg_step_none()
			ctx_clear_trap_flag(context)
			return;
	if (dbg_step_should_stop(context, eip)):
		if (dbg_step_mode == dbg_step_finish()):
			# The function returned; execution is mid-statement at the call
			# site, where local addressing would be off by the words the
			# call pushed. Report the value, then glide to the next
			# statement boundary like a step.
			print(c"value returned = ")
			dbg_print_int_value(ctx_eax(context))
			put_char(10)
			dbg_prepare_resume(context, eip, dbg_step_line_mode())
			dbg_step_esp = ctx_esp(context)
			ctx_set_trap_flag(context)
			return;
		dbg_announce_location(eip)
		dbg_print_source_at(eip)
		wdbg_stop_loop(context, eip)
		return;
	ctx_set_trap_flag(context)


# Fatal signal handler: announce, inspect, never resume.
void wdbg_fatal(int sig, int context):
	dbg_fatal_stop = 1
	print(c"fatal signal: ")
	if (sig == 11):
		print(c"SIGSEGV")
	else if (sig == 4):
		print(c"SIGILL")
	else if (sig == 7):
		print(c"SIGBUS")
	else if (sig == 8):
		print(c"SIGFPE")
	else:
		print(c"signal ")
		char* digits = itoa(sig)
		print(digits)
		free(digits)
	print(c" at eip=")
	char* h = hex_word(ctx_eip(context))
	print(h)
	free(h)
	if (sig == 11):
		print(c" fault address=")
		char* fa = hex_word(ctx_reg(context, sigcontext_cr2()))
		print(fa)
		free(fa)
	put_char(10)
	dbg_announce_location(ctx_eip(context))
	dbg_print_source_at(ctx_eip(context))
	wdbg_command_loop(context, ctx_eip(context))
	println(c"cannot resume after a fatal signal: exiting")
	exit(1)


# ---------------------------------------------------------------------------
# Signal delivery shims.
#
# i386: a non-SA_SIGINFO handler is called with the classic frame
# [restorer][sig][sigcontext...] on the stack, so &sig + 4 is the
# sigcontext, and the kernel's vdso trampoline performs sigreturn when
# the handler returns. The *_entry wrappers compute the context and
# forward to the real two-argument handlers.
#
# x86-64: the kernel always builds an rt frame and calls the handler
# with sig in rdi and the ucontext pointer in rdx, and rt_sigaction
# requires an SA_RESTORER trampoline. Neither matches a W function, so
# wdbg emits tiny runtime thunks into an executable page: one per
# handler converts the register convention into a W stack call of
# handler(sig, ucontext + 40) - the sigcontext is the uc_mcontext field
# at offset 40 - and a shared restorer performs rt_sigreturn.

void wdbg_trap_entry(int sig):
	wdbg_trap(sig, &sig + 4)


void wdbg_fatal_entry(int sig):
	wdbg_fatal(sig, &sig + 4)


int wdbg_thunk_page
int wdbg_thunk_pos
int wdbg_restorer


void wdbg_thunk_emit(int n, char* bytes):
	char* p = cast(char*, wdbg_thunk_page + wdbg_thunk_pos)
	int i = 0
	while (i < n):
		p[i] = bytes[i]
		i = i + 1
	wdbg_thunk_pos = wdbg_thunk_pos + n


void wdbg_thunk_init():
	if (wdbg_thunk_page != 0):
		return;
	wdbg_thunk_page = mmap(0, 4096, 7, 34) /* RWX, PRIVATE|ANONYMOUS */
	asserts(c"mmap of signal thunk page failed", (wdbg_thunk_page > 0) | (wdbg_thunk_page < -4095))
	wdbg_restorer = wdbg_thunk_page
	/* mov eax,15 ; syscall  (rt_sigreturn) */
	wdbg_thunk_emit(7, c"\xb8\x0f\x00\x00\x00\x0f\x05")


# Emit an x64 thunk calling handler(sig, &uc_mcontext) with the W stack
# convention (first argument at the highest address). The handler
# address fits an imm32: the wdbg image loads in the low 2GB.
int wdbg_emit_handler_thunk(int handler):
	int addr = wdbg_thunk_page + wdbg_thunk_pos
	/* push rdi ; lea rax,[rdx+40] ; push rax ; mov eax,imm32 */
	wdbg_thunk_emit(7, c"\x57\x48\x8d\x42\x28\x50\xb8")
	save_int32(cast(char*, wdbg_thunk_page + wdbg_thunk_pos), handler)
	wdbg_thunk_pos = wdbg_thunk_pos + 4
	/* call rax ; add rsp,16 ; ret  (returns into the restorer) */
	wdbg_thunk_emit(7, c"\xff\xd0\x48\x83\xc4\x10\xc3")
	return addr


# struct sigaction: on i386 {handler, flags, restorer, mask[2]} with
# 4-byte fields, no SA_SIGINFO/SA_RESTORER (the vdso trampoline does
# sigreturn); on x86-64 {handler, flags, restorer, mask} with 8-byte
# fields, SA_SIGINFO (4) | SA_RESTORER (0x04000000) and the thunks.
void wdbg_install_handler(int signum, int handler, int flags):
	int* act = malloc(5 * __word_size__)
	if (__word_size__ == 8):
		wdbg_thunk_init()
		act[0] = wdbg_emit_handler_thunk(handler)
		act[1] = flags | 4 | 0x04000000
		act[2] = wdbg_restorer
		act[3] = 0
	else:
		act[0] = handler
		act[1] = flags
		act[2] = 0
		act[3] = 0
		act[4] = 0
	int err = rt_sigaction(signum, act, 0)
	asserts(c"rt_sigaction failed", err == 0)
	free(act)


int wdbg_main(int argc, int argv):
	args_init(argc, argv)

	# The target is the first argument ending in .w, so the boolean
	# --break_* flags can appear on either side of it
	char* target = 0
	int i = 1
	while (i < args_count()):
		if (ends_with(args_get(i), c".w")):
			if (target == 0):
				target = args_get(i)
		i = i + 1
	if (target == 0):
		println2(c"usage: wdbg <file.w> [--break_start] [--break_end]")
		exit(1)

	verbosity = -1
	# The in-process model runs the debuggee directly, so the target
	# architecture is the one this binary was compiled for.
	word_size = __word_size__
	word_size_log2 = 2
	if (word_size == 8):
		word_size_log2 = 3
	push_basic_types()
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)

	# Executable buffer the debuggee runs from; code_offset makes every
	# embedded address point into this mapping (same model as repl.w).
	# The codegen embeds addresses as 32-bit immediates, so on x64 the
	# buffer must sit in the low 2GB: MAP_32BIT (0x40).
	int buffer_size = 8388608
	int mmap_flags = 34 /* PRIVATE|ANONYMOUS */
	if (word_size == 8):
		mmap_flags = 34 + 64
	int buffer = mmap(0, buffer_size, 7, mmap_flags) /* RWX */
	asserts(c"mmap of code buffer failed", (buffer > 0) | (buffer < -4095))
	code = cast(char*, buffer)
	code_size = buffer_size
	codepos = 0
	code_offset = buffer

	# Recoverable compile errors for the print/eval command: error()
	# jumps back to the checkpoint instead of exiting
	repl_jump_buffer = cast(int, malloc(3 * __word_size__))
	repl_error_jump = cast(int, repl_longjmp)

	# Runtime stubs first, then the target and everything it imports
	if (word_size == 8):
		define_asm_functions_x64()
	else:
		define_asm_functions()
	compile_file(target)
	# On-demand runtimes for to_json/from_json and f"..." template
	# strings used by the debuggee, plus its queued generic
	# instantiations
	generic_finish_instantiations()
	json_codec_finish_import()
	template_string_finish_import()
	prelude_finish_import()
	var_finish_import()
	generic_finish_instantiations()

	int* target_main = cast(int*, sym_address(c"main"))
	asserts(c"debuggee has no main()", target_main != 0)

	bp_init()
	dbg_memory_init()
	dbg_rearm_bp = -1

	# SA_NODEFER (0x40000000) keeps SIGTRAP deliverable inside the
	# handler, so 'debugger' statements reached through the print/eval
	# command nest instead of killing the process. On x86 the kernel
	# calls the 1-argument entry wrappers; on x64 the thunks call the
	# 2-argument handlers directly.
	int trap_handler = cast(int, wdbg_trap_entry)
	int fatal_handler = cast(int, wdbg_fatal_entry)
	if (__word_size__ == 8):
		trap_handler = cast(int, wdbg_trap)
		fatal_handler = cast(int, wdbg_fatal)
	wdbg_install_handler(5, trap_handler, 1073741824) /* SIGTRAP */
	wdbg_install_handler(4, fatal_handler, 0) /* SIGILL */
	wdbg_install_handler(7, fatal_handler, 0) /* SIGBUS */
	wdbg_install_handler(8, fatal_handler, 0) /* SIGFPE */
	wdbg_install_handler(11, fatal_handler, 0) /* SIGSEGV */

	if (term_isatty(0)):
		line_edit_history_load(c"~/.wdbg_history")

	println(c"wdbg: 'debugger' statements trap into the command loop (type 'help' for commands)")

	if (args_has_flag(c"break_start")):
		debugger
	else if (saw_debugger_statement == 0):
		# Nothing will pause the debuggee before it runs: no 'debugger'
		# statement anywhere in the compiled program, and --break_start
		# wasn't passed. Any breakpoint/condition/log commands already
		# queued on stdin have not been read yet (the command loop only
		# starts on a trap) and will not apply -- the debuggee just runs
		# to completion or a crash. Warn instead of silently dropping them.
		println2(c"wdbg: no --break_start and no 'debugger' statement in the program; it will run unmanaged until a trap or crash, so breakpoints queued on stdin before then will not apply")

	int result = target_main(argc, argv)

	if (args_has_flag(c"break_end")):
		debugger

	print(c"wdbg: debuggee main returned ")
	char* digits = itoa(result)
	println(digits)
	free(digits)
	return 0
