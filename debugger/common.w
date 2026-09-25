# Helpers shared by the debuggers (wdbg in process, attach mode) and the
# REPL's runtime-fault handler.
import debugger.sigcontext


# stdout helpers for the debuggers' and the REPL's reports: v in decimal,
# v as a full-width hex word.
void dbg_print_dec(int v):
	char* digits = itoa(v)
	print(digits)
	free(digits)


void dbg_print_hex(int v):
	char* h = hex_word(v)
	print(h)
	free(h)


# "<lead><signal> at eip=<pc>[ fault address=<addr>]" and a newline: the
# fault report shared by the REPL (a rolled-back entry) and wdbg (a fatal
# stop).
void dbg_fault_banner(char* lead, int sig, int context):
	print(lead)
	if (sig == 11): print(c"SIGSEGV")
	elif (sig == 4): print(c"SIGILL")
	elif (sig == 7): print(c"SIGBUS")
	elif (sig == 8): print(c"SIGFPE")
	else:
		print(c"signal ")
		dbg_print_dec(sig)
	print(c" at eip=")
	dbg_print_hex(ctx_eip(context))
	if (sig == 11):
		print(c" fault address=")
		dbg_print_hex(ctx_reg(context, sigcontext_cr2()))
	put_char(10)


# Splits s at its first space: terminates the first word in place and
# returns the rest with leading spaces skipped ("" when there is none).
char* dbg_split_word(char* s):
	int i = 0
	while ((s[i] != 0) && (s[i] != ' ')):
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
