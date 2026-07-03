/*
wdbg: in-process debugger for W programs.

The target file is compiled into an executable mmap buffer (the same
model as repl.w) and its main() is called directly. A SIGTRAP handler is
installed first, so every int3 the compiler emits for a 'debugger'
statement lands in wdbg_trap, which drops into an interactive command
loop on stdin:

	c / continue    resume the debuggee
	r / registers   dump the trapped registers from the signal frame
	s / stack       dump 16 words at the trapped esp
	l / line        map the trapped eip to file:line via the DWARF notes
	q / quit        exit wdbg

usage: wdbg <file.w> [--break_start] [--break_end]

--break_start traps before the debuggee's main runs; --break_end traps
after it returns. End of input on stdin continues execution, so piped
command scripts cannot hang the debuggee.
*/
import compiler.compiler
import lib.args


# Offsets into the i386 struct sigcontext that the kernel builds on the
# stack for a non-SA_SIGINFO handler: [restorer][sig][sigcontext...].
int sigcontext_edi():
	return 16
int sigcontext_esi():
	return 20
int sigcontext_ebp():
	return 24
int sigcontext_esp():
	return 28
int sigcontext_ebx():
	return 32
int sigcontext_edx():
	return 36
int sigcontext_ecx():
	return 40
int sigcontext_eax():
	return 44
int sigcontext_eip():
	return 56
int sigcontext_eflags():
	return 64


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


void wdbg_print_register(char* name, int value):
	print(name)
	print(": ")
	println(hex(value))


void wdbg_print_registers(int context):
	wdbg_print_register("eax", load_int(context + sigcontext_eax()))
	wdbg_print_register("ecx", load_int(context + sigcontext_ecx()))
	wdbg_print_register("edx", load_int(context + sigcontext_edx()))
	wdbg_print_register("ebx", load_int(context + sigcontext_ebx()))
	wdbg_print_register("esp", load_int(context + sigcontext_esp()))
	wdbg_print_register("ebp", load_int(context + sigcontext_ebp()))
	wdbg_print_register("esi", load_int(context + sigcontext_esi()))
	wdbg_print_register("edi", load_int(context + sigcontext_edi()))
	wdbg_print_register("eip", load_int(context + sigcontext_eip()))
	wdbg_print_register("eflags", load_int(context + sigcontext_eflags()))


void wdbg_print_stack(int context):
	int esp = load_int(context + sigcontext_esp())
	int i = 0
	while (i < 16):
		print(hex(esp + i * 4))
		print(": ")
		println(hex(load_int(esp + i * 4)))
		i = i + 1


# Map the trapped eip back to file:line using the DWARF line notes the
# in-process compile recorded. eip points just past the int3 byte, so
# the int3's own address is eip - 1.
void wdbg_print_location(int eip):
	int rel = eip - code_offset - 1
	if ((rel < 0) | (rel >= codepos)):
		println("no line info (eip is outside the debuggee)")
		return;
	int best = -1
	int i = 0
	while (i < debug_line_count):
		if (load_int(debug_line_addresses + i * 4) <= rel):
			best = i
		i = i + 1
	if (best < 0):
		println("no line info recorded")
		return;
	char* file_name = load_int(debug_files + load_int(debug_line_file_indexes + best * 4) * 4)
	print(file_name)
	print(":")
	println(itoa(load_int(debug_line_lines + best * 4)))


void wdbg_command_loop(int context):
	char* command = malloc(64)
	while (1):
		print("wdbg> ")
		int n = wdbg_read_command(command, 64)
		if (n < 0):
			println("(end of input: continuing)")
			free(command)
			return;
		if (n == 0):
			continue
		if ((strcmp(command, "c") == 0) | (strcmp(command, "continue") == 0)):
			free(command)
			return;
		else if ((strcmp(command, "q") == 0) | (strcmp(command, "quit") == 0)):
			exit(0)
		else if ((strcmp(command, "r") == 0) | (strcmp(command, "registers") == 0)):
			wdbg_print_registers(context)
		else if ((strcmp(command, "s") == 0) | (strcmp(command, "stack") == 0)):
			wdbg_print_stack(context)
		else if ((strcmp(command, "l") == 0) | (strcmp(command, "line") == 0)):
			wdbg_print_location(load_int(context + sigcontext_eip()))
		else:
			println("commands: c(ontinue), r(egisters), s(tack), l(ine), q(uit)")


# SIGTRAP handler. Returning resumes the debuggee just past the int3:
# the kernel's frame return address is the vdso sigreturn trampoline.
void wdbg_trap(int sig):
	# The sigcontext sits directly after the sig argument on the stack
	int context = &sig + 4
	print("breakpoint hit at eip=")
	println(hex(load_int(context + sigcontext_eip())))
	wdbg_print_location(load_int(context + sigcontext_eip()))
	wdbg_command_loop(context)


int main(int argc, int argv):
	args_init(argc, argv)

	# The target is the first argument ending in .w, so the boolean
	# --break_* flags can appear on either side of it
	char* target = 0
	int i = 1
	while (i < args_count()):
		if (ends_with(args_get(i), ".w")):
			if (target == 0):
				target = args_get(i)
		i = i + 1
	if (target == 0):
		println2("usage: wdbg <file.w> [--break_start] [--break_end]")
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
	asserts("mmap of code buffer failed", (buffer > 0) | (buffer < -4095))
	code = buffer
	code_size = buffer_size
	codepos = 0
	code_offset = buffer

	# Runtime stubs first, then the target and everything it imports
	define_asm_functions()
	compile_file(target)

	int* target_main = sym_address("main")
	asserts("debuggee has no main()", target_main != 0)

	# struct sigaction { handler, flags, restorer, mask[2] }; no
	# SA_SIGINFO so the handler gets the classic sigcontext frame, no
	# SA_RESTORER so the kernel uses the vdso sigreturn trampoline
	int* act = malloc(20)
	act[0] = wdbg_trap
	act[1] = 0
	act[2] = 0
	act[3] = 0
	act[4] = 0
	int err = rt_sigaction(5, act, 0) /* SIGTRAP */
	asserts("rt_sigaction failed", err == 0)

	println("wdbg: 'debugger' statements trap into the command loop")

	if (args_has_flag("break_start")):
		debugger

	int result = target_main(argc, argv)

	if (args_has_flag("break_end")):
		debugger

	print("wdbg: debuggee main returned ")
	println(itoa(result))
	return 0
