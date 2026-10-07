/*
--profile-generate: instrumented execution counters (unit P1 of
docs/projects/register_allocation_pgo.md, §3.2-§3.3, §3.5).

When profile_generate_mode is set (compiler/compiler.w's option block),
the emitter gives every function and every while/for loop head one 8-byte
counter in the RW data segment and emits an increment of it:

  x64    inc QWORD PTR [abs32]            48 ff 04 25 <disp32>
  x86    add DWORD PTR [abs32],1          83 05 <disp32> 01
         adc DWORD PTR [abs32+4],0        83 15 <disp32> 00

Both forms touch no register but the flags. The sites are the first
instruction after the function prologue (profile_function_enter, called
right after be_function_prologue by grammar/program.w's
function_definition and by code_generator/function_ast.w's
emit_function_begin_ast, so the streaming grammar and the
--ast-emit-retained path instrument identically) and the loop region
start (profile_loop_head, called right after be_ctrl_loop by the
while/for emitters in grammar/while_statement.w, grammar/for_statement.w
and code_generator/loop_ast.w). Neither site sits between a compare and
its branch: the loop head precedes the condition, and the function entry
precedes the body. A loop counter therefore counts head evaluations:
iterations + 1 for a loop that leaves through its condition.

The counter table is laid out at finish time (profile_finish), after the
last global was allocated, so it is one contiguous block whose address
and length are written into lib/profile.w's __w_profile_counters /
__w_profile_count globals; every increment's disp32 is patched then.
Emission order fixes the indices, so the output is a pure function of
the sources and flags (§3.5). profile_finish also redirects lib's exit()
to __w_profile_exit (a jmp written over exit's first five bytes), which
flushes the counters to $W_PROFILE_OUT and performs the exit_group
syscall itself: both _main's exit(main(...)) and direct exit() calls
reach the flush. A crash (_exit, signal) does not, by design.

The sidecar <output>.wprofmap names every counter, one tab-separated line
each: index, kind (f/l), defhash of the enclosing definition (the same
sha256 'w defhash' prints: profile_defhash_* in compiler/compiler.w
look the definition up by file and line among the definitions
defhash_note recorded, which the option block arms), function name,
file, line, loop ordinal within the function (0 for f lines). A
function the defhash scan did not record (a script's implicit main, a
generator body) gets 64 zeros as its hash; its counters are still real.

Decisions: generator bodies get no function counter (they have no
be_function_prologue; the body runs once and is resumed by gen_switch,
so an entry count would mean neither calls nor resumptions) but loops
inside them are counted and attributed to the generator
(profile_generator_enter). A script's implicit main is a function with
a prologue and is counted like one; the synthesized __w_test_main
(compiler/test_registry.w) is not (one entry per run says nothing, and
its loop-free body has no sites). Asm-bodied functions
(PR #579) go through the same function_definition path: the increment
after the prologue touches neither registers nor the stack, so they are
instrumented like any other function if and when that lands. Only the
x86 and x64 Linux ELF targets are supported; the option block rejects
the flag on every other target with an error rather than emitting
counters there (arm64 would need ldr/add/str through a scratch
register, wasm has no absolute addressing).
*/

int profile_generate_mode

# The record of the function body being compiled (the entry hooks set
# it; grammar/statement.w's current_function_symbol is declared after
# the while/for emitters, so the loop hook cannot read it), or -1.
int profile_current_record

int sym_decl_file_index(int t);   /* compiler/symbol_table.w */
int sym_decl_line(int t);
int sym_decl_visibility(int t);
int sym_lookup(char* s);
int sym_address(char* s);
int profile_defhash_find(int file_index, int line);   /* compiler/compiler.w */
char* profile_defhash_hex_at(int idx);
char* profile_defhash_name_at(int idx);


# Growable word array (seed-era: malloc/free, no list[int]).
struct profile_words:
	int* items
	int count
	int capacity


profile_words* profile_words_new():
	profile_words* w = cast(profile_words*, malloc(3 * __word_size__))
	w.items = 0
	w.count = 0
	w.capacity = 0
	return w


void profile_words_push(profile_words* w, int v):
	if (w.count >= w.capacity):
		int grown = w.capacity * 2
		if (grown < 64): grown = 64
		int* fresh = cast(int*, malloc(grown * __word_size__))
		int i = 0
		while (i < w.count):
			fresh[i] = w.items[i]
			i = i + 1
		if (w.items != 0): free(cast(void*, w.items))
		w.items = fresh
		w.capacity = grown
	w.items[w.count] = v
	w.count = w.count + 1


# Function records: one per function whose body emitted a counter site.
# fn_counter is the function's own counter index, or -1 when only loops
# inside it were counted (generator bodies, __w_test_main, script main).
profile_words* profile_fn_symbol
profile_words* profile_fn_name
profile_words* profile_fn_file
profile_words* profile_fn_line
profile_words* profile_fn_loops
profile_words* profile_fn_counter

# Counters, in emission order (= index): kind 1 function / 2 loop, the
# function record, the loop ordinal (1-based, 0 for a function) and the
# source line of the site.
profile_words* profile_ct_kind
profile_words* profile_ct_record
profile_words* profile_ct_ordinal
profile_words* profile_ct_line

# disp32 patch sites: code position, counter index, byte offset into
# the 8-byte counter (4 for the x86 adc half).
profile_words* profile_pt_pos
profile_words* profile_pt_counter
profile_words* profile_pt_offset


# lib/profile.w itself, compiled with the counters off: its flush loop
# and the helpers it calls would otherwise count themselves while
# dumping, and those entries are noise in every profile.
int import_module(char* dotted);   /* grammar/import_statement.w */


void profile_import_runtime():
	int saved = profile_generate_mode
	profile_generate_mode = 0
	import_module(c"lib.profile")
	profile_generate_mode = saved


void profile_counters_init():
	if (profile_fn_symbol != 0): return
	profile_current_record = -1
	profile_fn_symbol = profile_words_new()
	profile_fn_name = profile_words_new()
	profile_fn_file = profile_words_new()
	profile_fn_line = profile_words_new()
	profile_fn_loops = profile_words_new()
	profile_fn_counter = profile_words_new()
	profile_ct_kind = profile_words_new()
	profile_ct_record = profile_words_new()
	profile_ct_ordinal = profile_words_new()
	profile_ct_line = profile_words_new()
	profile_pt_pos = profile_words_new()
	profile_pt_counter = profile_words_new()
	profile_pt_offset = profile_words_new()


# The increment of counter `index` at the current code position; the
# disp32 fields are patched in profile_finish once the table exists.
void profile_emit_increment(int index):
	if (word_size == 8):
		emit(4, c"\x48\xff\x04\x25")   # inc QWORD PTR [disp32]
		profile_words_push(profile_pt_pos, codepos)
		profile_words_push(profile_pt_counter, index)
		profile_words_push(profile_pt_offset, 0)
		emit_int32(0)
	else:
		emit(2, c"\x83\x05")   # add DWORD PTR [disp32],1
		profile_words_push(profile_pt_pos, codepos)
		profile_words_push(profile_pt_counter, index)
		profile_words_push(profile_pt_offset, 0)
		emit_int32(0)
		emit_int8(1)
		emit(2, c"\x83\x15")   # adc DWORD PTR [disp32+4],0
		profile_words_push(profile_pt_pos, codepos)
		profile_words_push(profile_pt_counter, index)
		profile_words_push(profile_pt_offset, 4)
		emit_int32(0)
		emit_int8(0)


int profile_counter_new(int kind, int record, int ordinal):
	int index = profile_ct_kind.count
	profile_words_push(profile_ct_kind, kind)
	profile_words_push(profile_ct_record, record)
	profile_words_push(profile_ct_ordinal, ordinal)
	profile_words_push(profile_ct_line, diag_token_line)
	profile_emit_increment(index)
	return index


int profile_record_new(int symbol, char* name):
	int record = profile_fn_symbol.count
	profile_words_push(profile_fn_symbol, symbol)
	if (name != 0): name = strclone(name)
	profile_words_push(profile_fn_name, cast(int, name))
	profile_words_push(profile_fn_file, sym_decl_file_index(symbol))
	profile_words_push(profile_fn_line, sym_decl_line(symbol))
	profile_words_push(profile_fn_loops, 0)
	profile_words_push(profile_fn_counter, -1)
	return record


# Right after be_function_prologue: the function's entry counter.
void profile_function_enter(int symbol, char* name):
	if (profile_generate_mode == 0): return
	if (target_isa != 0): return
	profile_counters_init()
	int record = profile_record_new(symbol, name)
	profile_fn_counter.items[record] = profile_counter_new(1, record, 0)
	profile_current_record = record


# A generator body: no entry counter (see the header), but a record so
# its loops are attributed to it rather than to the previous function.
void profile_generator_enter(int symbol, char* name):
	if (profile_generate_mode == 0): return
	if (target_isa != 0): return
	profile_counters_init()
	profile_current_record = profile_record_new(symbol, name)


# Right after be_ctrl_loop at a while/for head: the loop's counter, the
# next ordinal within its function.
void profile_loop_head():
	if (profile_generate_mode == 0): return
	if (target_isa != 0): return
	profile_counters_init()
	int record = profile_current_record
	if (record < 0): return
	int ordinal = profile_fn_loops.items[record] + 1
	profile_fn_loops.items[record] = ordinal
	profile_counter_new(2, record, ordinal)


# Store a target word into the RW data image at data vaddr `vaddr`.
void profile_data_store_word(int vaddr, int value):
	save_i(data + (vaddr - data_offset), value, word_size)


# Set lib/profile.w's global `name` (zero-initialised data-segment
# storage) to value, when the program has it.
void profile_set_runtime_global(char* name, int value):
	int t = sym_lookup(name)
	if (t < 0): return
	if (sym_decl_visibility(t) != 'D'): return
	profile_data_store_word(sym_address(name), value)


# Redirect lib's exit(code) to __w_profile_exit(code): a jmp rel32 over
# its first five bytes (push ebp ; mov ebp,esp ; ...). The jmp keeps the
# caller's frame exactly as a call would have left it, so the hook sees
# the same argument slot and never returns here.
void profile_patch_exit():
	int t_exit = sym_lookup(c"exit")
	int t_hook = sym_lookup(c"__w_profile_exit")
	if ((t_exit < 0) || (t_hook < 0)): return
	if ((sym_decl_visibility(t_exit) != 'D') || (sym_decl_visibility(t_hook) != 'D')): return
	int exit_addr = sym_address(c"exit")
	int hook_addr = sym_address(c"__w_profile_exit")
	int pos = exit_addr - code_offset
	code[pos] = 0xe9
	save_int32(code + pos + 1, hook_addr - exit_addr - 5)


void profile_map_write_cstr(int fd, char* s):
	write(fd, s, strlen(s))


void profile_map_write_int(int fd, int v):
	char* digits = itoa(v)
	profile_map_write_cstr(fd, digits)
	free(digits)


# Copy of name with whitespace removed, so operator overloads
# ("operator+(vec3, vec3)") keep the map and profile whitespace-split.
char* profile_map_name(char* name):
	char* out = malloc(strlen(name) + 1)
	int i = 0
	int o = 0
	while (name[i] != 0):
		if ((name[i] != ' ') && (name[i] != 9)):
			out[o] = name[i]
			o = o + 1
		i = i + 1
	out[o] = 0
	return out


# The sidecar map: a header line, then one line per counter.
void profile_map_write(char* map_path):
	int fd = open(map_path, 577, 420)   # O_WRONLY|O_CREAT|O_TRUNC, 0644
	if (fd < 0):
		print_error(c"error: could not open profile map '")
		print_error(map_path)
		print_error(c"'\x0a")
		exit(1)
	int max_path_size = 4096
	char* cwd = malloc(max_path_size)
	getcwd(cwd, max_path_size)
	int cwd_len = strlen(cwd)
	profile_map_write_cstr(fd, c"# wprofmap v1\x09")
	if (word_size == 8): profile_map_write_cstr(fd, c"x64")
	else: profile_map_write_cstr(fd, c"x86")
	profile_map_write_cstr(fd, c"\x09")
	profile_map_write_int(fd, profile_ct_kind.count)
	profile_map_write_cstr(fd, c"\x0a")
	# Per record: the defhash entry (looked up once) and its hex.
	int records = profile_fn_symbol.count
	int* record_hex = cast(int*, malloc((records + 1) * __word_size__))
	int r = 0
	while (r < records):
		int idx = profile_defhash_find(profile_fn_file.items[r], profile_fn_line.items[r])
		if (idx >= 0):
			record_hex[r] = cast(int, profile_defhash_hex_at(idx))
			if (profile_fn_name.items[r] == 0): profile_fn_name.items[r] = cast(int, strclone(profile_defhash_name_at(idx)))
		else:
			record_hex[r] = cast(int, c"0000000000000000000000000000000000000000000000000000000000000000")
		r = r + 1
	int i = 0
	while (i < profile_ct_kind.count):
		int record = profile_ct_record.items[i]
		profile_map_write_int(fd, i)
		if (profile_ct_kind.items[i] == 1): profile_map_write_cstr(fd, c"\x09f\x09")
		else: profile_map_write_cstr(fd, c"\x09l\x09")
		profile_map_write_cstr(fd, cast(char*, record_hex[record]))
		profile_map_write_cstr(fd, c"\x09")
		char* name = cast(char*, profile_fn_name.items[record])
		if (name == 0): name = c"?"
		char* shown_name = profile_map_name(name)
		profile_map_write_cstr(fd, shown_name)
		free(shown_name)
		profile_map_write_cstr(fd, c"\x09")
		char* path = debug_file_name(profile_fn_file.items[record])
		char* shown = path
		if (starts_with(path, cwd)):
			if (path[cwd_len] == '/'): shown = path + cwd_len + 1
		profile_map_write_cstr(fd, shown)
		profile_map_write_cstr(fd, c"\x09")
		profile_map_write_int(fd, profile_ct_line.items[i])
		profile_map_write_cstr(fd, c"\x09")
		profile_map_write_int(fd, profile_ct_ordinal.items[i])
		profile_map_write_cstr(fd, c"\x0a")
		i = i + 1
	close(fd)
	free(cast(void*, record_hex))
	free(cwd)


# Called by link_impl once every function (user files, runtime imports,
# generic instantiations, __w_test_main) has been compiled and before the
# image is finished: lay out the counter table, patch the increments,
# point lib/profile.w at the table, hook exit, write the map.
void profile_finish(char* output_path, int check_mode):
	if (profile_generate_mode == 0): return
	if (target_isa != 0): return
	profile_counters_init()
	if ((check_mode == 0) && (output_path == 0)):
		print_error(c"error: --profile-generate requires -o <output> (the map is written next to it)\x0a")
		exit(1)
	int count = profile_ct_kind.count
	# 8-byte aligned table, one entry even for a program with no sites so
	# the runtime pointer is never null.
	int misalign = datapos & 7
	if (misalign != 0): emit_data_zeros(8 - misalign)
	int reserve = count
	if (reserve == 0): reserve = 1
	int base = emit_data_zeros(reserve * 8)
	int p = 0
	while (p < profile_pt_pos.count):
		int target = base + profile_pt_counter.items[p] * 8 + profile_pt_offset.items[p]
		save_int32(code + profile_pt_pos.items[p], target)
		p = p + 1
	profile_set_runtime_global(c"__w_profile_counters", base)
	profile_set_runtime_global(c"__w_profile_count", count)
	profile_patch_exit()
	if (check_mode): return
	char* map_path = strjoin(output_path, c".wprofmap")
	profile_map_write(map_path)
	free(map_path)
