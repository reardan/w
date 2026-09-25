# The frame list both debuggers walk (wdbg.w in process, attach.w over
# ptrace): per frame an absolute pc and a frame base -- the esp at the
# frame's function entry, which is the address of the stack slot holding
# its return address; 0 = unknown. Each mode rebuilds it at every stop
# from its own stack scan; frame <n> / up / down select a frame, whose
# variables are then addressed through its statement stack depth (esp at
# a statement boundary = base - depth * word), the same arithmetic frame
# 0 uses with the trapped esp.
import debugger.lines


char* dbg_fr_pc /* absolute pc per frame (word slots) */
char* dbg_fr_base /* frame base per frame (word slots) */
int dbg_fr_count
int dbg_fr_sel


const int dbg_fr_max = 16


void dbg_fr_reset():
	if (dbg_fr_pc == 0):
		dbg_fr_pc = malloc(dbg_fr_max * __word_size__)
		dbg_fr_base = malloc(dbg_fr_max * __word_size__)
	dbg_fr_count = 0
	dbg_fr_sel = 0


void dbg_fr_store(int pc, int base):
	if (dbg_fr_count >= dbg_fr_max):
		return;
	save_word(dbg_fr_pc + dbg_fr_count * __word_size__, pc)
	save_word(dbg_fr_base + dbg_fr_count * __word_size__, base)
	dbg_fr_count = dbg_fr_count + 1


# The newest frame's base, once the scan finds its return-address slot.
void dbg_fr_set_last_base(int base):
	save_word(dbg_fr_base + (dbg_fr_count - 1) * __word_size__, base)


int dbg_fr_pc_at(int n):
	return load_word(dbg_fr_pc + n * __word_size__)


int dbg_fr_base_at(int n):
	return load_word(dbg_fr_base + n * __word_size__)


# esp at a statement boundary of a frame whose base is known, given the
# statement's code address relative to the image (vpc - code_offset
# indexes the line table) and whether the pc lies in the debuggee's code
# at all; 0 when any of it is unknown (locals are not addressable then).
int dbg_fr_statement_esp(int base, int in_code, int vpc):
	if ((base == 0) || (in_code == 0)):
		return 0
	int entry = dbg_find_line(vpc - code_offset)
	if (entry < 0):
		return 0
	int depth = dbg_line_stack(entry)
	if (depth < 0):
		return 0
	return base - depth * __word_size__


# Frame 0's base from the trapped esp: esp plus the stop statement's
# stack depth, or 0 when the stop is outside the debuggee's line table.
int dbg_fr_stop_base(int esp, int in_code, int vpc):
	if (in_code):
		int entry = dbg_find_line(vpc - code_offset)
		if (entry >= 0):
			if (dbg_line_stack(entry) >= 0):
				return esp + dbg_line_stack(entry) * __word_size__
	return 0


# The frame 'up' (delta 1) or 'down' (delta -1) moves to, or -1 after
# saying there is none.
int dbg_fr_step(int delta):
	int n = dbg_fr_sel + delta
	if (n >= dbg_fr_count):
		println(c"no caller frame")
		return -1
	if (n < 0):
		println(c"already at the innermost frame")
		return -1
	return n


void dbg_fr_announce_number(int n):
	print(c"#")
	dbg_print_dec(n)
	print(c"  ")
