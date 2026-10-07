/*
Inlining of small leaf callees (docs/projects/codegen_gap_plan.md §2.4
and §5.1, unit A5; P3 of docs/projects/register_allocation_pgo.md): the
per-function record of what a call site needs in order to emit the
callee's body in place of a `call rel32`, and the decision itself.

The compiler is single pass with no tree, so a call site that wants to
inline its callee re-parses the callee's body from a copy of its source
bytes (grammar/inline_call.w), with the arguments bound as fresh locals
in the slots the call pushed and `return` lowered to a jump to the end
of the body. Everything that decision needs is collected while the
callee's own definition compiles (function_definition,
grammar/program.w, through inline_body_begin / inline_body_end below)
and stored in the record this module owns, keyed by the function's
symbol-table offset:

- the body's source span (file, retained source version, byte offset,
  line and column of its opening ':' or '{') and a private copy of its
  bytes, so no call site reopens or seeks the file;
- the parameter names and types (the 'A' records are truncated with
  the function's scope, so the names live here);
- the facts that make a body re-parseable in place: its token count,
  the bytes its code took, whether it emitted a call instruction that
  returns (inline_real_calls, counted by the x86 call emitters, less
  inline_noreturn_calls, the calls of noreturn functions both
  emitters note through inline_note_call: a checked add's overflow
  trap leaves its fast path call-free, and that is the path a copy of
  the body runs), opened a loop
  (inline_loop_count, counted by regalloc_loop_enter: a loop's R3
  facts are keyed by its keyword's file offset in the CALLER's scan,
  which an inlined loop would collide with), or used anything else that
  depends on the function's own frame or on a construct the re-parse
  cannot reproduce (inline_hazard_count: defer, goto and labels,
  raw_asm, f-strings, '?' propagation, yield, gpu constructs);
- the names the body resolved through sym_lookup that were NOT its own
  parameters or locals, with the record each resolved to
  (inline_note_lookup, called by sym_lookup while a body is being
  captured). A call site may only inline the body when every one of
  those names resolves to the same record there: the callee's
  parameters are bound as fresh locals in a scope that must not
  capture the caller's names, and its globals must resolve to the same
  records they resolved to in the callee. A file-scoped import alias
  ('import a.b as f', grammar/import_statement.w) is resolved outside
  the symbol table, per file, so a body that uses one is a hazard.

The decision (inline_site_ok) is made at the call's begin side, once
per call, by the streaming grammar (grammar/postfix_expr.w) and the
retained emitter (code_generator/expression_ast.w) alike, from the same
state, so the two emitters agree byte for byte. It is deterministic in
(sources, flags, profile): a size budget in bytes of code, raised for
callees and callers a --profile-use profile classifies as hot, lowered
for the ones it classifies cold and for a site outside every loop of
its function, and open to a body that calls (a wrapper) only when the
profile makes it hot. It is OPT-IN: --inline turns it on, --profile-use
turns it on (for the sites the profile marks hot, and the loop sites
below), and --no-inline turns it off whatever else was given (the
reference for tests/regalloc_diff_test.w). Off by default because the
capture and the re-parse cost the self-compile 8-15% of its
instructions for a few percent on the corpus (§8 of the plan).

What never inlines: a callee whose body was not seen yet (a forward
call stays a direct call), recursion (the callee is the function being
compiled, or is already being inlined further out), struct-by-value
parameters or returns (their stack layout is the call's), W variadics,
generators, asm bodies, bodies compiled under a generic substitution,
bodies that warned, call sites in generator or 'gpu for' bodies, the
REPL (a redefined function would not update inlined copies; its
late-binding registry patches call sites only), --profile-generate
builds (the instrumented binary measures the call graph) and 'w check'
(no code is written, and the body's diagnostics were already reported
once). x86 and x64 Linux only, like the register units: win64, arm64
and wasm images are byte-identical with and without this module.

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
import lib.lib
import compiler.tokenizer
import compiler.type_table
import compiler.symbol_table
import compiler.profile_use


# Size budgets, in bytes of code the body took where it was defined
# (prologue and epilogue included, and whatever was inlined into it, so
# nested inlining is bounded by the same number). The default covers
# leaf accessors up to inf_get_bit's size (libs/extras/compress/
# inflate.w: 314 bytes on x64); the cold budget keeps a trivially small
# callee inline even when the profile never saw it run; the hot budget
# is for callees or callers a --profile-use profile marks hot, and is
# the only one open to a body that calls: a wrapper's copy saves one
# call and costs its whole body at every site (free() alone has some
# 700 sites in the compiler), so without a profile saying the site is
# hot it stays a call. A body is also capped in tokens
# (inline_max_tokens), which bounds what the capture of its lookups
# costs.
const int inline_budget_default = 320
const int inline_budget_cold = 64
const int inline_budget_hot = 640
const int inline_max_tokens = 160
# Nesting: a body inlined inside an inlined body, and so on.
const int inline_max_depth = 3
# A record keeps at most this many parameters (every parameter is one
# word; sym_max_param_slots bounds the signature anyway).
const int inline_max_params = 10


struct inline_record:
	int sym            # table offset of the function's record
	char* name         # cloned
	char* file         # cloned path
	int offset         # file offset of the body's first token (':' or '{')
	int line           # tokenizer line_number at that token
	int column         # column_number at that token
	char* text         # the body's bytes, offset..end, plus a newline
	int length         # bytes in text
	int tokens         # body token count
	int code_bytes     # bytes the body's code took in the definition
	int ok             # 1 when the body may be inlined
	int has_calls      # the body emitted a call instruction that returns
	int param_count
	int* param_types   # inline_max_params entries
	char** param_names # inline_max_params cloned names
	char** free_names  # names resolved outside the body (in free_text)
	int* free_syms     # the record each resolved to (-1 unresolved)
	int* free_lens     # each name's length and hash, so the dedup rarely compares bytes
	int free_count
	char* free_text    # the names' bytes, one allocation per record
	int free_text_used
	int free_text_size
	int profile_class  # the profile's class of the callee (0 unknown, 1 cold, 2 hot)
	int sites          # --stats: call sites that inlined this body
	int refused        # --stats: eligible sites refused by a site rule


list[int] inline_records          # inline_record* per record
map[int, int] inline_by_sym       # symbol offset -> record index

# The record being captured (index), -1 when none; its counters at the
# body's start.
int inline_capture_record
int inline_capture_tokens
int inline_capture_calls
int inline_capture_noreturn
int inline_capture_loops
int inline_capture_hazards
int inline_capture_warnings
int inline_capture_codepos

# --stats
int inline_bodies_recorded
int inline_sites_inlined
int inline_sites_refused_capture
int inline_sites_refused_budget


void inline_table_ensure():
	if (inline_records == 0):
		inline_records = new list[int]
		inline_by_sym = new map[int, int]
		inline_capture_record = -1


inline_record* inline_record_at(int r):
	return cast(inline_record*, inline_records[r])


# The record of the function at table offset sym, or -1.
int inline_lookup(int sym):
	if (inline_records == 0): return -1
	if (inline_by_sym == 0): return -1
	return inline_by_sym.get(sym, -1)


# The record of the function named name, or -1: for the register
# pre-scan (compiler/regalloc_scan.w), which sees calls by name.
int inline_lookup_name(char* name):
	if (inline_records == 0): return -1
	int t = sym_probe(name)
	if (t < 0): return -1
	return inline_lookup(t)


# 1 when inlining is on for this compile.
int inline_enabled():
	if (inline_disabled): return 0
	return inline_requested || profile_use_mode


# 1 when a call to the function named name, emitted now, would leave
# no call instruction in the caller: the body is inlinable and emitted
# no call itself. The scan uses it to let a loop own registers across
# such a call; the emitter spills around any call that is emitted
# anyway, so a wrong answer costs instructions, never correctness.
int inline_name_is_leaf(char* name):
	if (inline_enabled() == 0): return 0
	int i = inline_lookup_name(name)
	if (i < 0): return 0
	inline_record* rec = inline_record_at(i)
	if (rec.ok == 0): return 0
	if (rec.has_calls): return 0
	return rec.code_bytes <= inline_budget_default


# A parameter of the function being defined (function_definition, in
# declaration order): recorded on the capture, if one is open.
void inline_note_parameter(char* name, int type):
	int r = inline_capture_record
	if (r < 0): return;
	inline_record* rec = inline_record_at(r)
	int n = rec.param_count
	# An unnamed parameter ('int f(int)') cannot be bound
	if ((n >= inline_max_params) || (name == 0)):
		rec.ok = 0
		return;
	int* types = rec.param_types
	char** names = rec.param_names
	types[n] = type
	names[n] = strclone(name)
	rec.param_count = n + 1
	# By-value aggregates span several stack words with a layout the
	# call's push protocol owns; the body stays a call.
	if (type_stack_words(type) != 1): rec.ok = 0
	if (type_num_args(type_unqualified(type)) > 0): rec.ok = 0


# A new function definition opens: start a record for symbol sym
# (named name, returning return_type), before its parameters are
# declared. The record is abandoned (ok = 0) by anything the body does
# that the re-parse cannot reproduce; inline_body_end decides.
void inline_definition_begin(int sym, char* name, int return_type):
	inline_table_ensure()
	inline_capture_record = -1
	if (inline_enabled() == 0): return;
	if ((target_isa != 0) || (target_os != 0)): return;
	if (repl_call_site_hook != 0): return;
	if (profile_generate_mode): return;
	if (analysis_mode): return;
	inline_record* rec = new inline_record()
	rec.sym = sym
	rec.name = strclone(name)
	rec.file = 0
	rec.offset = -1
	rec.line = 0
	rec.column = 0
	rec.text = 0
	rec.length = 0
	rec.tokens = 0
	rec.code_bytes = 0
	rec.ok = 1
	rec.has_calls = 0
	rec.param_count = 0
	rec.param_types = cast(int*, malloc(inline_max_params * __word_size__))
	rec.param_names = cast(char**, malloc(inline_max_params * __word_size__))
	rec.free_names = cast(char**, malloc((inline_max_tokens + 1) * __word_size__))
	rec.free_syms = cast(int*, malloc((inline_max_tokens + 1) * __word_size__))
	rec.free_lens = cast(int*, malloc((inline_max_tokens + 1) * __word_size__))
	rec.free_count = 0
	rec.free_text = 0
	rec.free_text_used = 0
	rec.free_text_size = 0
	rec.profile_class = 0
	rec.sites = 0
	rec.refused = 0
	# A struct returned by value travels through the hidden buffer the
	# call parks; the body stays a call.
	if (type_num_args(type_unqualified(return_type)) > 0): rec.ok = 0
	int r = inline_records.length
	inline_records.push(cast(int, rec))
	inline_capture_record = r


# A prototype: no body, no record.
void inline_definition_abandon():
	int r = inline_capture_record
	inline_capture_record = -1
	inline_capture_active = 0
	if (r >= 0): inline_record_at(r).ok = 0


# The definition's body is about to be parsed (the current token is its
# ':' or '{'): note the span and the counters the facts are deltas of.
# variadic: a W variadic function; generic: compiled under a generic
# substitution; asm_body: grammar/asm_function.w emitted an asm block;
# generator: a generator body.
void inline_body_begin(int variadic, int generic, int asm_body, int generator):
	int r = inline_capture_record
	if (r < 0): return;
	inline_record* rec = inline_record_at(r)
	if (variadic || generic || asm_body || generator): rec.ok = 0
	# A body that is not a block (a prototype, or the seed's single
	# statement form without ':') is never captured.
	if ((token[0] != ':') && (token[0] != '{')): rec.ok = 0
	rec.file = strclone(filename)
	rec.offset = token_start_offset
	rec.line = line_number
	rec.column = column_number - token_i
	rec.profile_class = profile_function_class()
	inline_capture_tokens = token_serial
	inline_capture_calls = inline_real_calls
	inline_capture_noreturn = inline_noreturn_calls
	inline_capture_loops = inline_loop_count
	inline_capture_hazards = inline_hazard_count
	inline_capture_warnings = warning_count
	inline_capture_codepos = codepos
	if (rec.ok): inline_capture_active = 1


int function_is_noreturn(char* name);   /* grammar/type_check.w */


# A call of the function named name is being emitted (both emitters,
# at the call's begin side): a call of a noreturn function does not
# make the body a non-leaf.
void inline_note_call(char* name):
	if (inline_capture_active == 0): return;
	if (function_is_noreturn(name)): inline_noreturn_calls = inline_noreturn_calls + 1


# A copy of the source bytes offset..end of the file being compiled,
# with a newline appended; compiler/regalloc_scan.w owns the file image
# it reads from. Returns the length, 0 when the bytes are not at hand.
int inline_source_copy(int offset, int end, char** out);


# The body has been parsed; the current token is the first one after it
# (its offset ends the span). Decides whether the record is usable.
void inline_body_end():
	int r = inline_capture_record
	inline_capture_record = -1
	inline_capture_active = 0
	if (r < 0): return;
	inline_record* rec = inline_record_at(r)
	rec.tokens = token_serial - inline_capture_tokens
	rec.has_calls = (inline_real_calls - inline_capture_calls) > (inline_noreturn_calls - inline_capture_noreturn)
	rec.code_bytes = codepos - inline_capture_codepos
	if (inline_loop_count != inline_capture_loops): rec.ok = 0
	if (inline_hazard_count != inline_capture_hazards): rec.ok = 0
	if (warning_count != inline_capture_warnings): rec.ok = 0
	if (rec.tokens > inline_max_tokens): rec.ok = 0
	if (rec.code_bytes > inline_budget_hot): rec.ok = 0
	if (rec.offset < 0): rec.ok = 0
	# A body that never completes (error(), a trap: grammar/type_check.w
	# records it as the definition finishes) is cold by definition, and
	# would be copied to every site that calls it
	if (function_is_noreturn(rec.name)): rec.ok = 0
	# The function's record must still be the symbol's (a REPL
	# rollback or a scope exit could truncate it; a definition's is a
	# global, so this is a consistency check)
	if (rec.sym >= table_pos): rec.ok = 0
	if (rec.ok):
		int end = token_start_offset
		if (end <= rec.offset): rec.ok = 0
		else:
			char* text = 0
			int length = inline_source_copy(rec.offset, end, &text)
			if (length <= 0): rec.ok = 0
			else:
				rec.text = text
				rec.length = length
	if (rec.ok):
		inline_by_sym[rec.sym] = r
		inline_bodies_recorded = inline_bodies_recorded + 1
	else:
		free(rec.text)
		rec.text = 0
	if (verbosity >= 1):
		print_error(c"inline_body_end('")
		print_error(rec.name)
		print_int0(c"', ok=", rec.ok)
		print_int0(c", tokens=", rec.tokens)
		print_int0(c", calls=", rec.has_calls)
		print_int0(c", loops=", inline_loop_count - inline_capture_loops)
		print_int0(c", hazards=", inline_hazard_count - inline_capture_hazards)
		print_int0(c", warnings=", warning_count - inline_capture_warnings)
		print_int0(c", bytes=", rec.code_bytes)
		print_error(c")\x0a")


# sym_lookup's hook while a body is being captured: a name that
# resolved outside the body (a global, or nothing at all -- a builtin,
# a helper declared on demand) is one the call site must check.
void inline_note_lookup(char* s, int found):
	int r = inline_capture_record
	if (r < 0): return;
	if (found >= 0):
		char scope = table[found + 1]
		if ((scope == 'L') || (scope == 'A')): return;
	inline_record* rec = inline_record_at(r)
	# The capture stops paying as soon as the body cannot inline any
	# more: past the token cap or the largest budget, or holding a
	# loop or a hazard (inline_body_end repeats these checks)
	if ((token_serial - inline_capture_tokens > inline_max_tokens) || (codepos - inline_capture_codepos > inline_budget_hot) || (inline_loop_count != inline_capture_loops) || (inline_hazard_count != inline_capture_hazards)):
		inline_capture_active = 0
		rec.ok = 0
		return;
	# One entry per name: a resolved name is recognised by its record
	# (no string compare), an unresolved one by its length and spelling.
	# Plain arrays and one text buffer per record: this runs at every
	# lookup of every body, and the self-compile paid 5% of its time for
	# the list accessors and the per-name clones a first version used.
	int n = rec.free_count
	int* syms = rec.free_syms
	if (found >= 0):
		for i in range(n):
			if (syms[i] == found): return;
	# The name's length and a hash of its bytes in one pass (most
	# lookups during a capture are probes of names that are not symbols
	# -- type names, keywords -- and they repeat)
	int len = 0
	int key = 5381
	while (s[len] != 0):
		key = key * 33 + s[len]
		len = len + 1
	key = (key << 8) | (len & 255)
	if (found < 0):
		int* lens = rec.free_lens
		char** names = rec.free_names
		for i in range(n):
			if ((syms[i] < 0) && (lens[i] == key)):
				if (strcmp(names[i], s) == 0): return;
	if (n > inline_max_tokens): return;
	if (rec.free_text_used + len + 1 > rec.free_text_size):
		int size = rec.free_text_size * 2
		if (size < 256): size = 256
		while (size < rec.free_text_used + len + 1): size = size * 2
		char* text = malloc(size)
		if (rec.free_text != 0):
			for i in range(rec.free_text_used): text[i] = rec.free_text[i]
			# Earlier names point into the old buffer: rebase them
			for i in range(n): rec.free_names[i] = text + (rec.free_names[i] - rec.free_text)
			free(rec.free_text)
		rec.free_text = text
		rec.free_text_size = size
	char* copy = rec.free_text + rec.free_text_used
	strcpy(copy, s)
	rec.free_text_used = rec.free_text_used + len + 1
	rec.free_names[n] = copy
	syms[n] = found
	rec.free_lens[n] = key
	rec.free_count = n + 1


# --- the call site -----------------------------------------------------------

# Functions being inlined right now, outermost first (recursion guard).
list[int] inline_open_syms


int inline_depth_of(int sym):
	if (inline_open_syms == 0): return -1
	for i in range(inline_open_syms.length):
		if (inline_open_syms[i] == sym): return i
	return -1


# The byte budget for a site: a site inside a loop of its function
# gets the default, lowered to the cold budget when a --profile-use
# profile classifies the callee or the caller cold; a site a profile
# classifies hot (callee or caller) gets the hot budget wherever it is;
# a straight-line site without a profile's word gets the cold budget
# under --inline (an accessor of a few instructions is shorter than
# the call it replaces, and this is where the corpus gains of §8 come
# from) and nothing under --profile-use alone (what a copy of the
# body saves is paid once per execution of the site, and a
# straight-line site runs once per call of its function, while the
# re-parse costs compile time at every site).
int inline_site_budget(inline_record* rec, int in_loop):
	int callee = rec.profile_class
	int caller = profile_function_class()
	if ((callee == 2) || (caller == 2)): return inline_budget_hot
	if (in_loop == 0):
		if (inline_requested): return inline_budget_cold
		return 0
	if ((callee == 1) || (caller == 1)): return inline_budget_cold
	return inline_budget_default


# 1 when a call to the function at table offset sym, about to be
# emitted inside the function current (current_function_symbol), may be
# inlined; in_loop is the caller's loop nesting at the site
# (grammar/while_statement.w's loop_depth). The record index is left in
# inline_site_record. Both emitters call this at the call's begin side.
int inline_site_record

int inline_site_ok(int sym, int current, int in_generator, int in_gpu_for, int in_loop):
	inline_site_record = -1
	if (inline_enabled() == 0): return 0
	if (inline_records == 0): return 0
	if ((target_isa != 0) || (target_os != 0)): return 0
	if (sym < 0): return 0
	if (current < 0): return 0
	if (sym == current): return 0
	if (in_generator || in_gpu_for): return 0
	if (repl_call_site_hook != 0): return 0
	if (profile_generate_mode): return 0
	if (analysis_mode): return 0
	int r = inline_lookup(sym)
	if (r < 0): return 0
	inline_record* rec = inline_record_at(r)
	if (rec.ok == 0): return 0
	if (rec.sym != sym): return 0
	if (inline_depth >= inline_max_depth): return 0
	if (inline_depth_of(sym) >= 0): return 0
	int budget = inline_site_budget(rec, in_loop)
	if (rec.has_calls && (budget != inline_budget_hot)):
		inline_sites_refused_budget = inline_sites_refused_budget + 1
		return 0
	if (rec.code_bytes > budget):
		inline_sites_refused_budget = inline_sites_refused_budget + 1
		return 0
	# The capture rule: every name the body resolves outside itself
	# must resolve here to the record it resolved to there (a global
	# the caller shadows with a local or argument, or a record declared
	# since, is a different one), and a name the body left unresolved
	# must not have become a local or argument
	char** names = rec.free_names
	int* syms = rec.free_syms
	for i in range(rec.free_count):
		int t = sym_probe(names[i])
		int captured = 0
		if (syms[i] >= 0): captured = t != syms[i]
		elif (t >= 0):
			char scope = table[t + 1]
			captured = (scope == 'L') || (scope == 'A')
		if (captured):
			inline_sites_refused_capture = inline_sites_refused_capture + 1
			rec.refused = rec.refused + 1
			return 0
	inline_site_record = r
	return 1


void inline_stats_dump():
	print_int0(c"inline: bodies recorded: ", inline_bodies_recorded)
	print_int0(c" sites inlined: ", inline_sites_inlined)
	print_int0(c" refused (capture): ", inline_sites_refused_capture)
	print_int0(c" refused (budget): ", inline_sites_refused_budget)
	print_error(c"\x0a")
	if (inline_records == 0): return;
	# The bodies that account for the most inlined bytes (sites x size)
	int shown = 0
	int floor = -1
	while (shown < 12):
		int best = -1
		int best_weight = -1
		for i in range(inline_records.length):
			inline_record* rec = inline_record_at(i)
			if (rec.sites == 0): continue
			int weight = rec.sites * rec.code_bytes
			if (weight > best_weight):
				if ((floor < 0) || (weight < floor)):
					best = i
					best_weight = weight
		if (best < 0): return;
		inline_record* top = inline_record_at(best)
		print_error(c"inline:   ")
		print_error(top.name)
		print_int0(c": sites ", top.sites)
		print_int0(c" x ", top.code_bytes)
		print_int0(c" bytes = ", best_weight)
		print_int0(c" (tokens ", top.tokens)
		print_int0(c", calls ", top.has_calls)
		print_error(c")\x0a")
		floor = best_weight
		shown = shown + 1
