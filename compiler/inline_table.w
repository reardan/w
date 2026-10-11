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
profile makes it hot. It is ON by default for tiny leaves only
(inline_budget_tiny: a body whose whole definition is about as long as
the call sequence it replaces); --inline raises the budgets to the
ones above, --profile-use gives the sites the profile marks hot the
hot budget, and --no-inline turns it off whatever else was given (the
reference for tests/regalloc_diff_test.w). The default stays tiny
because the capture and the re-parse of the larger budgets cost the
self-compile 8-15% of its instructions for a few percent on the
corpus (§8 of the plan); under the default a capture is abandoned as
soon as the body passes the tiny caps, and the record of a body that
cannot be inlined is dropped again, so the default costs the
self-compile about what it saves.

Constant arguments: an argument word that the call pushed straight
from an immediate (push_call_argument_compact notes every argument
word, inline_note_argument) binds a plain 'int' parameter that the
body never writes or takes the address of (inline_param_read_only, a
conservative byte scan of the body's copy) to the value:
grammar/inline_call.w lists the bound records, sym_emit_value notes
the 'lea' of one, and promote() loads the immediate in its place, so
the body's operators fold it as they fold a literal. The pushed word
stays, so every read that does not go through promote() still sees it.

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
# The default (neither --inline nor --profile-use): tiny leaves only,
# gcc-sized (early-inlining-insns 6, max-inline-insns-auto 15): a body
# whose whole definition, prologue and epilogue included, fits in
# inline_budget_tiny bytes is about as long as the push/call/pop
# sequence it replaces. A capture under the default stops paying as
# soon as the body passes either tiny cap, so the self-compile pays for
# the records of tiny bodies only.
# A straight-line site runs once per call of its caller: copying even a
# tiny body there cost the self-compile more (re-parsing the body at
# 1700 sites, +2% Ir) than its code saved, so only loop sites inline.
const int inline_budget_tiny = 40
const int inline_tiny_tokens = 32
const int inline_budget_tiny_straight = 0
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
	int has_clobber    # the body writes ecx/edx on x86 (inline_clobber_count)
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
	int param_ro       # bit i: parameter i is never written or address-taken in the body
	int profile_class  # the profile's class of the callee (0 unknown, 1 cold, 2 hot)
	int sites          # --stats: call sites that inlined this body
	int refused        # --stats: eligible sites refused by a site rule


list[int] inline_records          # inline_record* per usable record
# Symbol offset -> record index: open addressing over two plain arrays
# (keys -1 when empty), consulted at every direct call and every call
# the register pre-scan sees, where a map lookup cost the default
# compile a measurable share of its instructions.
int* inline_hash_keys
int* inline_hash_vals
int inline_hash_size      # a power of two, 0 until the first record
int inline_hash_count

# The capture: one scratch record reused by every definition (most are
# never inlinable, and allocating a record per definition cost the
# default compile more than its inlining saved), copied into a record
# of its own by inline_body_end when the body is usable.
# inline_capture_record is 1 while it is open, 0 otherwise; then the
# counters at the body's start.
inline_record* inline_scratch
char* inline_scratch_names    # the name and the parameter names, NUL-separated
int inline_scratch_names_used
int inline_capture_record
int inline_capture_tokens
int inline_capture_calls
int inline_capture_clobbers
int inline_capture_noreturn
int inline_capture_loops
int inline_capture_hazards
int inline_capture_warnings
int inline_capture_codepos
# The capture's caps (inline_capture_max_bytes/_tokens at its start)
int inline_capture_bytes_cap
int inline_capture_tokens_cap

# --stats
int inline_bodies_recorded
int inline_sites_inlined
int inline_sites_refused_capture
int inline_sites_refused_budget
int inline_consts_bound


const int inline_scratch_names_size = 2048


void inline_table_ensure():
	if (inline_records == 0):
		inline_records = new list[int]
		inline_capture_record = 0
		inline_scratch = new inline_record()
		inline_scratch.param_types = cast(int*, malloc(inline_max_params * __word_size__))
		inline_scratch.param_names = cast(char**, malloc(inline_max_params * __word_size__))
		inline_scratch.free_names = cast(char**, malloc((inline_max_tokens + 1) * __word_size__))
		inline_scratch.free_syms = cast(int*, malloc((inline_max_tokens + 1) * __word_size__))
		inline_scratch.free_lens = cast(int*, malloc((inline_max_tokens + 1) * __word_size__))
		inline_scratch.free_text = 0
		inline_scratch.free_text_size = 0
		inline_scratch_names = cast(char*, malloc(inline_scratch_names_size))


inline_record* inline_record_at(int r):
	return cast(inline_record*, inline_records[r])


# A copy of name in the scratch name buffer, 0 when it does not fit.
char* inline_scratch_name_copy(char* name):
	int len = strlen(name)
	if (inline_scratch_names_used + len + 1 > inline_scratch_names_size): return 0
	char* copy = inline_scratch_names + inline_scratch_names_used
	strcpy(copy, name)
	inline_scratch_names_used = inline_scratch_names_used + len + 1
	return copy


# The slot of sym in the record hash: where it is, or the empty slot
# where it goes.
int inline_hash_slot(int sym):
	int mask = inline_hash_size - 1
	int i = (sym * 40503 + (sym >> 11)) & mask
	while (1):
		int k = inline_hash_keys[i]
		if ((k == sym) || (k == -1)): return i
		i = (i + 1) & mask
	return -1


void inline_hash_put(int sym, int r):
	if ((inline_hash_count + 1) * 2 > inline_hash_size):
		int* old_keys = inline_hash_keys
		int* old_vals = inline_hash_vals
		int old_size = inline_hash_size
		int size = old_size * 2
		if (size < 256): size = 256
		inline_hash_keys = cast(int*, malloc(size * __word_size__))
		inline_hash_vals = cast(int*, malloc(size * __word_size__))
		inline_hash_size = size
		for i in range(size): inline_hash_keys[i] = -1
		for i in range(old_size):
			if (old_keys[i] != -1):
				int j = inline_hash_slot(old_keys[i])
				inline_hash_keys[j] = old_keys[i]
				inline_hash_vals[j] = old_vals[i]
		free(cast(char*, old_keys))
		free(cast(char*, old_vals))
	int slot = inline_hash_slot(sym)
	if (inline_hash_keys[slot] == -1): inline_hash_count = inline_hash_count + 1
	inline_hash_keys[slot] = sym
	inline_hash_vals[slot] = r


# The record of the function at table offset sym, or -1.
int inline_lookup(int sym):
	if (inline_hash_size == 0): return -1
	int slot = inline_hash_slot(sym)
	if (inline_hash_keys[slot] != sym): return -1
	return inline_hash_vals[slot]


# The record of the function named name, or -1: for the register
# pre-scan (compiler/regalloc_scan.w), which sees calls by name.
int inline_lookup_name(char* name):
	if (inline_hash_count == 0): return -1
	int t = sym_probe(name)
	if (t < 0): return -1
	return inline_lookup(t)


# 1 when inlining is on for this compile: always, unless --no-inline.
int inline_enabled():
	if (inline_disabled): return 0
	return 1


# The largest body a capture keeps, in code bytes and in tokens: the hot
# budget under --inline or --profile-use, the tiny one by default.
int inline_capture_max_bytes():
	if (inline_requested || profile_use_mode): return inline_budget_hot
	return inline_budget_tiny


int inline_capture_max_tokens():
	if (inline_requested || profile_use_mode): return inline_max_tokens
	return inline_tiny_tokens


# 1 when a call to the function named name, emitted now, would leave
# no call instruction in the caller: the body is inlinable and emitted
# no call itself. The scan uses it to let a loop own registers across
# such a call; the emitter spills around any call that is emitted
# anyway, so a wrong answer costs instructions, never correctness. The
# budget is the loop site's under the current mode and profile, the
# same rule the site applies (inline_site_budget), so a build whose
# profile inlines nothing (stale, header-only) scans exactly as the
# plain build does and emits its bytes (tests/profile_use_test.w).
int inline_site_budget(inline_record* rec, int in_loop);


# 1 when the record's body fits budget: its bytes, and under the tiny
# budget its tokens too (the tiny capture's cap, so a build whose
# captures used the larger caps inlines the same tiny bodies).
int inline_budget_fits(inline_record* rec, int budget):
	if (rec.code_bytes > budget): return 0
	if ((budget <= inline_budget_tiny) && (rec.tokens > inline_tiny_tokens)): return 0
	return 1


int inline_name_is_leaf(char* name):
	if (inline_enabled() == 0): return 0
	int i = inline_lookup_name(name)
	if (i < 0): return 0
	inline_record* rec = inline_record_at(i)
	if (rec.ok == 0): return 0
	if (rec.has_calls): return 0
	# x86: a loop's ecx/edx (A9) must not meet an inlined shift count
	# or division; the scan declines such loops as it declines the
	# body's own (the emitters would spill around them anyway)
	if ((word_size == 4) && rec.has_clobber): return 0
	return inline_budget_fits(rec, inline_site_budget(rec, 1))


# A parameter of the function being defined (function_definition, in
# declaration order): recorded on the capture, if one is open.
void inline_note_parameter(char* name, int type):
	if (inline_capture_record <= 0): return;
	inline_record* rec = inline_scratch
	int n = rec.param_count
	# An unnamed parameter ('int f(int)') cannot be bound
	if ((n >= inline_max_params) || (name == 0)):
		rec.ok = 0
		return;
	char* copy = inline_scratch_name_copy(name)
	if (copy == 0):
		rec.ok = 0
		return;
	int* types = rec.param_types
	char** names = rec.param_names
	types[n] = type
	names[n] = copy
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
	inline_capture_record = 0
	if (inline_enabled() == 0): return;
	if ((target_isa != 0) || (target_os != 0)): return;
	if (repl_call_site_hook != 0): return;
	if (profile_generate_mode): return;
	if (analysis_mode): return;
	inline_record* rec = inline_scratch
	inline_scratch_names_used = 0
	rec.sym = sym
	rec.ok = 1
	rec.name = inline_scratch_name_copy(name)
	if (rec.name == 0):
		rec.name = c"?"
		rec.ok = 0
	rec.file = 0
	rec.offset = -1
	rec.line = 0
	rec.column = 0
	rec.text = 0
	rec.length = 0
	rec.tokens = 0
	rec.code_bytes = 0
	rec.has_calls = 0
	rec.has_clobber = 0
	rec.param_count = 0
	inline_capture_bytes_cap = inline_capture_max_bytes()
	inline_capture_tokens_cap = inline_capture_max_tokens()
	rec.free_count = 0
	rec.free_text_used = 0
	rec.param_ro = 0
	rec.profile_class = 0
	rec.sites = 0
	rec.refused = 0
	# A struct returned by value travels through the hidden buffer the
	# call parks; the body stays a call.
	if (type_num_args(type_unqualified(return_type)) > 0): rec.ok = 0
	inline_capture_record = 1


# A prototype: no body, no record.
void inline_definition_abandon():
	inline_capture_record = 0
	inline_capture_active = 0


# A record of its own for the usable capture s (inline_body_end).
inline_record* inline_record_keep(inline_record* s):
	inline_record* rec = new inline_record()
	rec.sym = s.sym
	rec.name = strclone(s.name)
	rec.file = strclone(filename)
	rec.offset = s.offset
	rec.line = s.line
	rec.column = s.column
	rec.text = s.text
	rec.length = s.length
	rec.tokens = s.tokens
	rec.code_bytes = s.code_bytes
	rec.ok = s.ok
	rec.has_calls = s.has_calls
	rec.has_clobber = s.has_clobber
	int n = s.param_count
	rec.param_count = n
	rec.param_types = cast(int*, malloc((n + 1) * __word_size__))
	rec.param_names = cast(char**, malloc((n + 1) * __word_size__))
	for i in range(n):
		rec.param_types[i] = s.param_types[i]
		rec.param_names[i] = strclone(s.param_names[i])
	int f = s.free_count
	rec.free_count = f
	rec.free_names = cast(char**, malloc((f + 1) * __word_size__))
	rec.free_syms = cast(int*, malloc((f + 1) * __word_size__))
	rec.free_lens = cast(int*, malloc((f + 1) * __word_size__))
	rec.free_text = cast(char*, malloc(s.free_text_used + 1))
	for i in range(s.free_text_used): rec.free_text[i] = s.free_text[i]
	rec.free_text_used = s.free_text_used
	rec.free_text_size = s.free_text_used + 1
	for i in range(f):
		rec.free_names[i] = rec.free_text + (s.free_names[i] - s.free_text)
		rec.free_syms[i] = s.free_syms[i]
		rec.free_lens[i] = s.free_lens[i]
	rec.param_ro = s.param_ro
	rec.profile_class = s.profile_class
	rec.sites = 0
	rec.refused = 0
	return rec


# The definition's body is about to be parsed (the current token is its
# ':' or '{'): note the span and the counters the facts are deltas of.
# variadic: a W variadic function; generic: compiled under a generic
# substitution; asm_body: grammar/asm_function.w emitted an asm block;
# generator: a generator body.
void inline_body_begin(int variadic, int generic, int asm_body, int generator):
	if (inline_capture_record <= 0): return;
	inline_record* rec = inline_scratch
	if (variadic || generic || asm_body || generator): rec.ok = 0
	# A body that is not a block (a prototype, or the seed's single
	# statement form without ':') is never captured.
	if ((token[0] != ':') && (token[0] != '{')): rec.ok = 0
	rec.offset = token_start_offset
	rec.line = line_number
	rec.column = column_number - token_i
	rec.profile_class = profile_function_class()
	inline_capture_tokens = token_serial
	inline_capture_calls = inline_real_calls
	inline_capture_clobbers = inline_clobber_count
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


int inline_is_ident_byte(int c):
	if ((c >= 'a') && (c <= 'z')): return 1
	if ((c >= 'A') && (c <= 'Z')): return 1
	if ((c >= '0') && (c <= '9')): return 1
	return (c == '_') || (c >= 128)


# 1 when the line of text holding position at has an assignment '='
# (one that is not part of '==', '!=', '<=', '>=' or a compound
# operator's tail is enough: this only has to over-report).
int inline_line_assigns(char* text, int length, int at):
	int start = at
	while ((start > 0) && (text[start - 1] != 10)): start = start - 1
	int i = start
	while ((i < length) && (text[i] != 10)):
		if (text[i] == '='):
			int prev = 0
			if (i > 0): prev = text[i - 1]
			int next = 0
			if (i + 1 < length): next = text[i + 1]
			if ((prev != '=') && (prev != '!') && (prev != '<') && (prev != '>') && (next != '=')): return 1
		i = i + 1
	return 0


# 1 when the body text (a copy of the callee's source bytes) never
# writes the parameter called name and never takes its address, so a
# call site may bind it to a constant argument. A byte scan over the
# whole text, strings and comments included (an occurrence there can
# only make the answer 0, never hide a write): every occurrence of the
# name as a whole identifier must be read-only -- not preceded by '&',
# '++' or '--', not followed by an assignment operator ('=' but not
# '==', any 'op=', ':='), '++' or '--', and not next to a ',' on a line
# that assigns (a parallel assignment's left side). A redeclaration of
# the name in the body ('int name = ...') is a write too. Over-reports
# writes, never under-reports them.
int inline_param_read_only(char* text, int length, char* name):
	int n = strlen(name)
	if (n == 0): return 0
	int i = 0
	while (i + n <= length):
		int match = 1
		if ((i > 0) && inline_is_ident_byte(text[i - 1])): match = 0
		if (match):
			int j = 0
			while ((j < n) && (text[i + j] == name[j])): j = j + 1
			if (j < n): match = 0
		if (match && (i + n < length) && inline_is_ident_byte(text[i + n])): match = 0
		if (match):
			# before the name
			int b = i - 1
			while ((b >= 0) && ((text[b] == ' ') || (text[b] == 9))): b = b - 1
			if (b >= 0):
				# '&name' takes the address; '&& name' is a logical and
				# ('&&&name' is both)
				if (text[b] == '&'):
					if (b < 1): return 0
					if (text[b - 1] != '&'): return 0
					if ((b >= 2) && (text[b - 2] == '&')): return 0
				if (b >= 1):
					if ((text[b] == '+') && (text[b - 1] == '+')): return 0
					if ((text[b] == '-') && (text[b - 1] == '-')): return 0
				if ((text[b] == ',') && inline_line_assigns(text, length, i)): return 0
			# after the name
			int a = i + n
			while ((a < length) && ((text[a] == ' ') || (text[a] == 9))): a = a + 1
			if (a < length):
				int c = text[a]
				int c1 = 0
				if (a + 1 < length): c1 = text[a + 1]
				int c2 = 0
				if (a + 2 < length): c2 = text[a + 2]
				if ((c == '=') && (c1 != '=')): return 0
				if ((c1 == '=') && ((c == '+') || (c == '-') || (c == '*') || (c == '/') || (c == '%') || (c == '&') || (c == '|') || (c == '^') || (c == ':'))): return 0
				if ((c == '+') && (c1 == '+')): return 0
				if ((c == '-') && (c1 == '-')): return 0
				if ((c2 == '=') && (((c == '<') && (c1 == '<')) || ((c == '>') && (c1 == '>')))): return 0
				if ((c == ',') && inline_line_assigns(text, length, i)): return 0
			i = i + n
		else: i = i + 1
	return 1


# --- constant arguments ---------------------------------------------------
# Per pushed stack slot (grammar/stack_slot.w's numbering: stack_pos
# right after the push), whether the word every call argument push left
# there is an immediate, and its value. push_call_argument_compact
# (grammar/postfix_expr.w) notes every argument word it pushes, constant
# or not, so the entry for a slot is always the last argument pushed
# into it; inline_emit_call reads the entries of its own arguments.
const int inline_arg_slots = 1024
int* inline_arg_const
int* inline_arg_value


void inline_note_argument(int slot, int is_const, int value):
	if ((slot < 0) || (slot >= inline_arg_slots)): return;
	if (inline_arg_const == 0):
		inline_arg_const = cast(int*, malloc(inline_arg_slots * __word_size__))
		inline_arg_value = cast(int*, malloc(inline_arg_slots * __word_size__))
	inline_arg_const[slot] = is_const
	inline_arg_value[slot] = value


# 1 when slot holds a constant argument; its value is then in
# inline_arg_value[slot].
int inline_argument_is_const(int slot):
	if ((slot < 0) || (slot >= inline_arg_slots)): return 0
	if (inline_arg_const == 0): return 0
	return inline_arg_const[slot]


# The length of a body copy (text, length bytes, ending in a newline)
# without the blank lines and column-0 '#' comment lines that close it:
# the span runs to the next definition's first token, and lexing the
# comments between two definitions at every call site cost the default
# compile more than the body itself. The first line (the ':') always
# stays, and nothing is trimmed when the kept text would hold an odd
# number of '"' (a string literal running across the trimmed lines).
int inline_trim_tail(char* text, int length):
	int end = length
	while (end > 0):
		int s = end - 1
		while ((s > 0) && (text[s - 1] != 10)): s = s - 1
		if (s == 0): break
		int i = s
		while ((i < end - 1) && ((text[i] == ' ') || (text[i] == 9))): i = i + 1
		if ((i == end - 1) || (text[s] == '#')): end = s
		else: break
	if (end == length): return length
	int quotes = 0
	for i in range(end):
		if (text[i] == '"'):
			if ((i == 0) || (text[i - 1] != 92)): quotes = quotes + 1
	if ((quotes & 1) != 0): return length
	return end


# The body has been parsed; the current token is the first one after it
# (its offset ends the span). Decides whether the record is usable.
void inline_body_end():
	int r = inline_capture_record
	inline_capture_record = 0
	inline_capture_active = 0
	if (r <= 0): return;
	inline_record* rec = inline_scratch
	rec.tokens = token_serial - inline_capture_tokens
	rec.has_calls = (inline_real_calls - inline_capture_calls) > (inline_noreturn_calls - inline_capture_noreturn)
	rec.has_clobber = inline_clobber_count != inline_capture_clobbers
	rec.code_bytes = codepos - inline_capture_codepos
	if (inline_loop_count != inline_capture_loops): rec.ok = 0
	if (inline_hazard_count != inline_capture_hazards): rec.ok = 0
	if (warning_count != inline_capture_warnings): rec.ok = 0
	if (rec.tokens > inline_capture_tokens_cap): rec.ok = 0
	if (rec.code_bytes > inline_capture_bytes_cap): rec.ok = 0
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
				rec.length = inline_trim_tail(text, length)
	if (rec.ok):
		char** names = rec.param_names
		for i in range(rec.param_count):
			if (inline_param_read_only(rec.text, rec.length, names[i])): rec.param_ro = rec.param_ro | (1 << i)
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
	# The body text moves to the record kept (it is only copied once
	# every other check passed)
	if (rec.ok):
		inline_hash_put(rec.sym, inline_records.length)
		inline_records.push(cast(int, inline_record_keep(rec)))
		inline_bodies_recorded = inline_bodies_recorded + 1
	rec.text = 0


# sym_lookup's hook while a body is being captured: a name that
# resolved outside the body (a global, or nothing at all -- a builtin,
# a helper declared on demand) is one the call site must check.
void inline_note_lookup(char* s, int found):
	if (inline_capture_record <= 0): return;
	if (found >= 0):
		char scope = table[found + 1]
		if ((scope == 'L') || (scope == 'A')): return;
	inline_record* rec = inline_scratch
	# The capture stops paying as soon as the body cannot inline any
	# more: past the token cap or the largest budget, or holding a
	# loop or a hazard (inline_body_end repeats these checks)
	if ((token_serial - inline_capture_tokens > inline_capture_tokens_cap) || (codepos - inline_capture_codepos > inline_capture_bytes_cap) || (inline_loop_count != inline_capture_loops) || (inline_hazard_count != inline_capture_hazards)):
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
	if (n > inline_capture_tokens_cap): return;
	if (rec.free_text_used + len + 1 > rec.free_text_size):
		int size = rec.free_text_size * 2
		if (size < 256): size = 256
		while (size < rec.free_text_used + len + 1): size = size * 2
		char* text = cast(char*, malloc(size))
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


# The byte budget for a site. A site a --profile-use profile
# classifies hot (callee or caller) gets the hot budget wherever it
# is. Without --inline every other site inside a loop gets the tiny
# budget (and the tiny token cap, inline_budget_fits) and a
# straight-line one inline_budget_tiny_straight, exactly as in a build
# without a profile: a stale or header-only profile then inlines what
# the plain build inlines and the image is the plain build's
# (tests/profile_use_test.w compares them). Under
# --inline a site inside a loop of its function gets the default,
# lowered to the cold budget when the profile classifies the callee or
# the caller cold, and a straight-line site gets the cold budget (an
# accessor of a few instructions is shorter than the call it replaces,
# and this is where the corpus gains of §8 come from).
int inline_site_budget(inline_record* rec, int in_loop):
	int callee = rec.profile_class
	int caller = profile_function_class()
	if ((callee == 2) || (caller == 2)): return inline_budget_hot
	if (inline_requested == 0):
		if (in_loop == 0): return inline_budget_tiny_straight
		return inline_budget_tiny
	if (in_loop == 0): return inline_budget_cold
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
	if (inline_budget_fits(rec, budget) == 0):
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
	print_int0(c" constant arguments: ", inline_consts_bound)
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
