/*
Software watchpoints for wdbg.

Hardware debug registers are unreachable in-process (writing DR0-DR7
needs ptrace from a second process), so watchpoints are scanned in
software at statement granularity: while any watchpoint is live, every
resume keeps the trap flag set and the SIGTRAP handler compares each
watched word against its remembered value at every statement boundary,
stopping with an old -> new report when one changed. That single-steps
the whole program, so expect a large slowdown while watchpoints exist.

A watchpoint records one word: the storage address of a local, argument
or global at 'watch' time, or a raw address. A local's address is a
stack slot of the selected frame, so its watchpoint is only meaningful
until that frame returns. Deleted entries keep their slot (addr 0) so
watchpoint numbers stay stable, like breakpoints.
*/
import debugger.locals
import debugger.memory


int dbg_watch_max():
	return 16

char* dbg_watch_addrs /* watched address per slot, 0 = deleted (word slots) */
char* dbg_watch_olds  /* last seen value (word slots) */
char* dbg_watch_texts /* what the user typed (word slots, owned copies) */
int dbg_watch_count


void dbg_watch_init():
	if (dbg_watch_addrs != 0):
		return;
	dbg_watch_addrs = malloc(dbg_watch_max() * __word_size__)
	dbg_watch_olds = malloc(dbg_watch_max() * __word_size__)
	dbg_watch_texts = malloc(dbg_watch_max() * __word_size__)


int dbg_watch_addr_at(int i):
	return load_word(dbg_watch_addrs + i * __word_size__)


int dbg_watch_old_at(int i):
	return load_word(dbg_watch_olds + i * __word_size__)


char* dbg_watch_text_at(int i):
	return cast(char*, load_word(dbg_watch_texts + i * __word_size__))


# Number of live (not deleted) watchpoints; nonzero switches every
# resume into the single-step scan.
int dbg_watch_live():
	int n = 0
	int i = 0
	while (i < dbg_watch_count):
		if (dbg_watch_addr_at(i) != 0):
			n = n + 1
		i = i + 1
	return n


# Record a watchpoint over the word at addr; returns its slot or -1.
int dbg_watch_add(char* text, int addr):
	dbg_watch_init()
	if (dbg_watch_count >= dbg_watch_max()):
		println(c"too many watchpoints")
		return -1
	int i = dbg_watch_count
	char* copy = malloc(strlen(text) + 1)
	strcpy(copy, text)
	save_word(dbg_watch_addrs + i * __word_size__, addr)
	save_word(dbg_watch_olds + i * __word_size__, load_word(cast(char*, addr)))
	save_word(dbg_watch_texts + i * __word_size__, cast(int, copy))
	dbg_watch_count = i + 1
	return i


void dbg_watch_describe(int i):
	print(c"watchpoint ")
	char* digits = itoa(i + 1)
	print(digits)
	free(digits)
	print(c": ")
	print(str_from_cstr(dbg_watch_text_at(i)))
	print(c" at ")
	char* ha = hex_word(dbg_watch_addr_at(i))
	print(ha)
	free(ha)
	print(c", value ")
	dbg_print_int_value(dbg_watch_old_at(i))


# Slot of the first live watchpoint whose memory no longer matches the
# remembered value, or -1. Unreadable memory (e.g. a stack slot of a
# frame that returned) never matches: the watchpoint stays silent.
int dbg_watch_check():
	int i = 0
	while (i < dbg_watch_count):
		int addr = dbg_watch_addr_at(i)
		if (addr != 0):
			if (dbg_mem_readable(addr, __word_size__)):
				if (load_word(cast(char*, addr)) != dbg_watch_old_at(i)):
					return i
		i = i + 1
	return -1


# Announce a hit as old -> new and remember the new value, so continuing
# only stops on the next change.
void dbg_watch_report(int i):
	int now = load_word(cast(char*, dbg_watch_addr_at(i)))
	print(c"watchpoint ")
	char* digits = itoa(i + 1)
	print(digits)
	free(digits)
	print(c": ")
	print(str_from_cstr(dbg_watch_text_at(i)))
	print(c" changed: ")
	dbg_print_int_value(dbg_watch_old_at(i))
	print(c" -> ")
	dbg_print_int_value(now)
	put_char(10)
	save_word(dbg_watch_olds + i * __word_size__, now)


void dbg_watch_delete(int i):
	if ((i < 0) || (i >= dbg_watch_count)):
		println(c"no such watchpoint")
		return;
	if (dbg_watch_addr_at(i) == 0):
		println(c"no such watchpoint")
		return;
	free(dbg_watch_text_at(i))
	save_word(dbg_watch_addrs + i * __word_size__, 0)


void dbg_watch_delete_all():
	int i = 0
	while (i < dbg_watch_count):
		if (dbg_watch_addr_at(i) != 0):
			free(dbg_watch_text_at(i))
			save_word(dbg_watch_addrs + i * __word_size__, 0)
		i = i + 1


void dbg_watch_list():
	int shown = 0
	int i = 0
	while (i < dbg_watch_count):
		if (dbg_watch_addr_at(i) != 0):
			dbg_watch_describe(i)
			put_char(10)
			shown = shown + 1
		i = i + 1
	if (shown == 0):
		println(c"no watchpoints set")
