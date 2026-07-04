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
	d / delete <n>    delete breakpoint n (no argument: delete all)
	i b               list breakpoints

Inspection:
	p / print <x>     local/arg/global by name, or compile and run any
	                  W expression in-process (globals and calls work)
	set <x> <v>       write a local, argument or global
	x <addr|name> [n] dump n memory words (addresses probed via /dev/null
	                  writes, so bad pointers cannot crash wdbg)
	bt / backtrace    heuristic stack unwind through return addresses
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
import debugger.sigcontext
import debugger.memory
import debugger.lines
import debugger.symbols
import debugger.locals
import debugger.breakpoints
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


# Read one command line from stdin; returns its length or -1 on EOF.
int wdbg_read_command(char* buf, int size):
	int i = 0
	int c = getchar(0)
	if (c == -1):
		return -1
	while ((c != 10) & (c != -1)):
		if (i < size - 1):
			buf[i] = c
			i = i + 1
		c = getchar(0)
	buf[i] = 0
	return i


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
	char* h = hex(value)
	println(h)
	free(h)


void wdbg_print_registers(int context):
	wdbg_print_register(c"eax", load_int(context + sigcontext_eax()))
	wdbg_print_register(c"ecx", load_int(context + sigcontext_ecx()))
	wdbg_print_register(c"edx", load_int(context + sigcontext_edx()))
	wdbg_print_register(c"ebx", load_int(context + sigcontext_ebx()))
	wdbg_print_register(c"esp", load_int(context + sigcontext_esp()))
	wdbg_print_register(c"ebp", load_int(context + sigcontext_ebp()))
	wdbg_print_register(c"esi", load_int(context + sigcontext_esi()))
	wdbg_print_register(c"edi", load_int(context + sigcontext_edi()))
	wdbg_print_register(c"eip", load_int(context + sigcontext_eip()))
	wdbg_print_register(c"eflags", load_int(context + sigcontext_eflags()))


void wdbg_print_stack(int context):
	int esp = ctx_esp(context)
	int i = 0
	while (i < 16):
		char* ha = hex(esp + i * 4)
		print(ha)
		free(ha)
		print(c": ")
		if (dbg_mem_readable(esp + i * 4, 4)):
			char* hv = hex(load_int(esp + i * 4))
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


# Heuristic backtrace: frame 0 is the stop location; older frames come
# from scanning the stack upward for plausible return addresses. The scan
# ends at the debuggee's entry function, whose caller is wdbg itself.
void dbg_backtrace(int context, int stop_addr):
	print(c"#0  ")
	dbg_announce_location(stop_addr)
	int main_at = dbg_function_at(sym_address(c"main"))
	if (dbg_function_at(stop_addr) == main_at):
		return;
	int esp = ctx_esp(context)
	int frame = 1
	int i = 0
	while ((i < 2048) & (frame < 16)):
		int slot = esp + i * 4
		if (dbg_mem_readable(slot, 4) == 0):
			return;
		int v = load_int(cast(char*, slot))
		if (dbg_in_debuggee(v)):
			if (dbg_looks_like_return(v)):
				print(c"#")
				char* digits = itoa(frame)
				print(digits)
				free(digits)
				print(c"  ")
				dbg_announce_location(v - 1)
				frame = frame + 1
				if (dbg_function_at(v - 1) == main_at):
					return;
		i = i + 1


void dbg_examine(int addr, int count):
	int i = 0
	while (i < count):
		char* ha = hex(addr + i * 4)
		print(ha)
		free(ha)
		print(c": ")
		if (dbg_mem_readable(addr + i * 4, 4)):
			char* hv = hex(load_int(addr + i * 4))
			println(hv)
			free(hv)
		else:
			println(c"<unreadable>")
			return;
		i = i + 1


# print <arg>: locals and args by name first, then defined globals, then
# the expression compiler.
void dbg_print_command(int context, int stop_addr, char* arg):
	if (arg[0] == 0):
		println(c"usage: print <name | expression>")
		return;
	if (dbg_is_identifier(arg)):
		int note = dbg_local_find(arg, stop_addr)
		if (note >= 0):
			dbg_print_local(note, ctx_esp(context))
			return;
		int g = dbg_global_find(arg)
		if (g >= 0):
			if (dbg_sym_symtype(g) != 2):
				print(arg)
				print(c" = ")
				dbg_print_typed_value(dbg_sym_address(g), dbg_sym_type(g))
				put_char(10)
				return;
	dbg_eval(arg)


# set <name> <value>: writes a local, argument or global word.
void dbg_set_command(int context, int stop_addr, char* arg):
	char* value_text = dbg_split_word(arg)
	if ((arg[0] == 0) | (value_text[0] == 0)):
		println(c"usage: set <name> <value>")
		return;
	int v = dbg_number(value_text)
	int note = dbg_local_find(arg, stop_addr)
	if (note >= 0):
		int addr = dbg_local_runtime_addr(note, ctx_esp(context))
		if (dbg_mem_readable(addr, 4) == 0):
			println(c"variable is not addressable here")
			return;
		save_int(cast(char*, addr), v)
		dbg_print_local(note, ctx_esp(context))
		return;
	int g = dbg_global_find(arg)
	if (g >= 0):
		if (dbg_sym_symtype(g) != 2):
			save_int(cast(char*, dbg_sym_address(g)), v)
			print(arg)
			print(c" = ")
			dbg_print_typed_value(dbg_sym_address(g), dbg_sym_type(g))
			put_char(10)
			return;
	print(c"unknown variable: ")
	println(arg)


# x <addr|name> [count]
void dbg_examine_command(int context, int stop_addr, char* arg):
	char* count_text = dbg_split_word(arg)
	if (arg[0] == 0):
		println(c"usage: x <address | name> [count]")
		return;
	int addr = 0
	if (((arg[0] >= '0') & (arg[0] <= '9')) | (arg[0] == '-')):
		addr = dbg_number(arg)
	else:
		int note = dbg_local_find(arg, stop_addr)
		if (note >= 0):
			addr = load_int(cast(char*, dbg_local_runtime_addr(note, ctx_esp(context))))
		else:
			int g = dbg_global_find(arg)
			if (g < 0):
				print(c"unknown name: ")
				println(arg)
				return;
			if (dbg_sym_symtype(g) == 2):
				addr = dbg_sym_address(g)
			else:
				addr = load_int(cast(char*, dbg_sym_address(g)))
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


void dbg_info_command(int context, int stop_addr, char* arg):
	char* rest = dbg_split_word(arg)
	if ((strcmp(arg, c"b") == 0) | (strcmp(arg, c"breakpoints") == 0)):
		bp_list()
	else if ((strcmp(arg, c"r") == 0) | (strcmp(arg, c"registers") == 0)):
		wdbg_print_registers(context)
	else if ((strcmp(arg, c"l") == 0) | (strcmp(arg, c"locals") == 0)):
		dbg_print_frame_vars(stop_addr, ctx_esp(context), 'L')
	else if ((strcmp(arg, c"a") == 0) | (strcmp(arg, c"args") == 0)):
		dbg_print_frame_vars(stop_addr, ctx_esp(context), 'A')
	else if ((strcmp(arg, c"f") == 0) | (strcmp(arg, c"functions") == 0)):
		dbg_print_functions()
	else if (strcmp(arg, c"files") == 0):
		int i = 0
		while (i < debug_file_count):
			println(str_from_cstr(cast(char*, load_int(debug_files + i * 4))))
			i = i + 1
	else:
		println(c"info topics: breakpoints registers locals args functions files")


void dbg_help():
	println(c"execution:")
	println(c"  c/continue  s/step  n/next  si/stepi  fin/finish  q/quit")
	println(c"breakpoints:")
	println(c"  b/break <function | line | file:line>   tb/tbreak <target>")
	println(c"  d/delete [n]   i b (list)")
	println(c"inspection:")
	println(c"  p/print <name | expression>   set <name> <value>")
	println(c"  x <addr | name> [count]   bt/backtrace   st/stack")
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


# Interactive command loop. Returning resumes the debuggee.
void wdbg_command_loop(int context, int stop_addr):
	char* command = malloc(256)
	while (1):
		print(c"wdbg> ")
		int n = wdbg_read_command(command, 256)
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
			dbg_announce_location(stop_addr)
		else if (strcmp(command, c"list") == 0):
			dbg_list_command(stop_addr, arg)
		else if ((strcmp(command, c"b") == 0) | (strcmp(command, c"break") == 0) | (strcmp(command, c"tb") == 0) | (strcmp(command, c"tbreak") == 0)):
			int temp = 0
			if ((command[0] == 't') & (command[1] == 'b')):
				temp = 1
			if (strcmp(command, c"tbreak") == 0):
				temp = 1
			int current_file = -1
			if (dbg_in_debuggee(stop_addr)):
				int entry = dbg_find_line(stop_addr - code_offset)
				if (entry >= 0):
					current_file = dbg_line_file(entry)
			int addr = bp_resolve_target(arg, current_file)
			if (addr != 0):
				int slot = bp_add(addr, temp)
				if (slot >= 0):
					bp_describe(slot)
					put_char(10)
		else if ((strcmp(command, c"d") == 0) | (strcmp(command, c"delete") == 0)):
			if ((arg[0] == 0) | (strcmp(arg, c"all") == 0)):
				bp_delete_all()
				println(c"all breakpoints deleted")
			else:
				bp_delete(atoi(arg) - 1)
		else if ((strcmp(command, c"i") == 0) | (strcmp(command, c"info") == 0)):
			dbg_info_command(context, stop_addr, arg)
		else if ((strcmp(command, c"bt") == 0) | (strcmp(command, c"backtrace") == 0)):
			dbg_backtrace(context, stop_addr)
		else if ((strcmp(command, c"p") == 0) | (strcmp(command, c"print") == 0)):
			dbg_print_command(context, stop_addr, arg)
		else if (strcmp(command, c"set") == 0):
			dbg_set_command(context, stop_addr, arg)
		else if (strcmp(command, c"x") == 0):
			dbg_examine_command(context, stop_addr, arg)
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
		frame_base = dbg_step_esp + dbg_step_stack * 4

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
			if (esp == frame_base - dbg_line_stack(entry) * 4):
				return 1 /* a statement boundary of the starting frame */
		return 0
	return 1


# SIGTRAP handler: breakpoints and 'debugger' statements arrive as int3
# (trapno 3, eip past the int3 byte); trap-flag single-steps arrive as
# debug exceptions (trapno 1, eip exact). Returning resumes the debuggee
# through the kernel's vdso sigreturn trampoline.
void wdbg_trap(int sig):
	# The sigcontext sits directly after the sig argument on the stack
	int context = &sig + 4
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
		char* h = hex(eip)
		println(h)
		free(h)
		dbg_announce_location(addr)
		dbg_print_source_at(addr)
		wdbg_stop_loop(context, addr)
		return;

	# Single-step trap
	if (dbg_step_mode == dbg_step_none()):
		# The step only existed to re-arm a breakpoint: full speed again
		ctx_clear_trap_flag(context)
		return;
	dbg_step_count = dbg_step_count + 1
	if (dbg_step_count > 500000):
		println(c"step: no source boundary found: continuing")
		dbg_step_mode = dbg_step_none()
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
void wdbg_fatal(int sig):
	int context = &sig + 4
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
	char* h = hex(ctx_eip(context))
	print(h)
	free(h)
	if (sig == 11):
		print(c" fault address=")
		char* fa = hex(load_int(context + sigcontext_cr2()))
		print(fa)
		free(fa)
	put_char(10)
	dbg_announce_location(ctx_eip(context))
	dbg_print_source_at(ctx_eip(context))
	wdbg_command_loop(context, ctx_eip(context))
	println(c"cannot resume after a fatal signal: exiting")
	exit(1)


# Signal handlers are ordinary W functions taking the signal number.
type wdbg_signal_handler = fn(int) -> void


# struct sigaction { handler, flags, restorer, mask[2] }; no SA_SIGINFO so
# the handler gets the classic sigcontext frame, no SA_RESTORER so the
# kernel uses the vdso sigreturn trampoline.
void wdbg_install_handler(int signum, wdbg_signal_handler* handler, int flags):
	int* act = malloc(20)
	act[0] = cast(int, handler)
	act[1] = flags
	act[2] = 0
	act[3] = 0
	act[4] = 0
	int err = rt_sigaction(signum, act, 0)
	asserts(c"rt_sigaction failed", err == 0)
	free(act)


int wdbg_main(int argc, int argv):
	# The in-process model is x86-only: the sigcontext layout, the 4-byte
	# stack slot arithmetic and the runtime asm stubs all assume i386
	if (__word_size__ != 4):
		println2(c"wdbg only runs as a 32-bit x86 binary")
		exit(1)

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
	word_size = 4
	word_size_log2 = 2
	push_basic_types()
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)

	# Executable buffer the debuggee runs from; code_offset makes every
	# embedded address point into this mapping (same model as repl.w)
	int buffer_size = 8388608
	int buffer = mmap(0, buffer_size, 7, 34) /* RWX, PRIVATE|ANONYMOUS */
	asserts(c"mmap of code buffer failed", (buffer > 0) | (buffer < -4095))
	code = cast(char*, buffer)
	code_size = buffer_size
	codepos = 0
	code_offset = buffer

	# Recoverable compile errors for the print/eval command: error()
	# jumps back to the checkpoint instead of exiting
	repl_jump_buffer = cast(int, malloc(12))
	repl_error_jump = cast(int, repl_longjmp)

	# Runtime stubs first, then the target and everything it imports
	define_asm_functions()
	compile_file(target)

	int* target_main = cast(int*, sym_address(c"main"))
	asserts(c"debuggee has no main()", target_main != 0)

	bp_init()
	dbg_memory_init()
	dbg_rearm_bp = -1

	# SA_NODEFER (0x40000000) keeps SIGTRAP deliverable inside the
	# handler, so 'debugger' statements reached through the print/eval
	# command nest instead of killing the process
	wdbg_install_handler(5, wdbg_trap, 1073741824) /* SIGTRAP */
	wdbg_install_handler(4, wdbg_fatal, 0) /* SIGILL */
	wdbg_install_handler(7, wdbg_fatal, 0) /* SIGBUS */
	wdbg_install_handler(8, wdbg_fatal, 0) /* SIGFPE */
	wdbg_install_handler(11, wdbg_fatal, 0) /* SIGSEGV */

	println(c"wdbg: 'debugger' statements trap into the command loop (type 'help' for commands)")

	if (args_has_flag(c"break_start")):
		debugger

	int result = target_main(argc, argv)

	if (args_has_flag(c"break_end")):
		debugger

	print(c"wdbg: debuggee main returned ")
	char* digits = itoa(result)
	println(digits)
	free(digits)
	return 0
