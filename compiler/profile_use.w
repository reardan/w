/*
--profile-use=<path>: profile-driven decisions (unit P2 of
docs/projects/register_allocation_pgo.md, §3.3-§3.5).

The flag (compiler/compiler.w's option block, whole-program: applied in
link_impl's flag pre-scan so the auto-imported runtime closure sees it
too) loads one .wprof text profile as bin/wprof writes it:

  f <defhash> <name> <file> <line> entries=<n>
  l <defhash> <name> <file> <line> head=<ordinal> iters=<n>

and answers, for the function whose body is being compiled, three
questions the optimizer asks (profile_function_class, profile_loop_iters,
profile_loop_hot): is it hot, is it cold, how often does its n-th loop
head run. The compiler never reads a profile implicitly (§3.5): no flag,
no profile, every answer "unknown", and the emitted bytes are exactly
the plain build's.

Keying. Entries are keyed by the definition's defhash (the sha256 of its
token stream, 'w defhash'), so a stale entry -- one token of the body
changed since the profile was taken -- silently stops matching and the
function is "unknown" (the static heuristic applies), never
mis-optimised. The hash has to be known at the START of the body, before
a byte of it is emitted and before the definition's end offset exists
(defhash_note runs after the body). It comes from the register pre-scan
(compiler/regalloc_scan.w, compiler/regalloc_profile.w): right before
the prologue, regalloc_function_scan calls profile_use_function_prepare
and, when the profile knows the function's name at all
(profile_use_names is the prefilter, so the ~75% of a self-compile's
functions that never ran cost one map probe), rs_hash_span re-lexes the
definition from its first token (the offset grammar/program.w's
recognizer and generic_instantiate_function store in
profile_use_definition_start, the same start defhash_note records
later) through the scanner's byte source -- getchar's window or the fd,
never the tokenizer -- reproducing get_token's token boundaries and
feeding profile_hash_token the "<kind><len>:<text>" stream of
compiler.w's defhash_process_span, until the first token that opens a
new line at tab level 0, which is where the body ends for every
definition that parses (a continuation line at tab level 0 inside a body
ends the scan early, mismatches, and is "unknown"). Deterministic -- it
reads the source bytes, not the parse state -- and a byte pass, not a
token pass: phase A's get_token look-ahead cost +8-14% compile time,
this one is inside the scan's own budget (§11). Any divergence from the
real tokenizer shows up as a stale count under --stats against a
freshly refreshed profile, which is the test.

Classes. hot: entries >= profile_use_hot_entries (10,000) or a loop
whose head evaluations are >= 16 per entry (and >= 256 in all, so a
one-shot loop does not qualify). cold: the profile matched this
function (by hash) and says it is not hot, OR the profile has entries
for this file (by its repo-relative path) and none under this
function's name -- the counter was zero or the function postdates the
profile; either way the registers are not worth the scan until
profile_refresh. unknown: no profile, the file is not in the profile at
all, or the hash no longer matches. Counts are parsed with saturation at
2^30 on every host so an x86-hosted and an x64-hosted compiler make the
same decisions from the same profile (verify_pgo's x64 leg relies on
it); ratios divide, never multiply.

Hot loop alignment. profile_use_loop_align is called once per while/for
head, right before be_ctrl_loop (grammar/while_statement.w,
grammar/for_statement.w and code_generator/loop_ast.w, so the streaming
grammar and --ast-emit-retained emit the same bytes), counting the loop's
ordinal within the function exactly as code_generator/profile_counters.w
numbers the 'l' entries. When the profile marks that loop hot on x86/x64
it pads with single-byte nops to the next 16-byte boundary before the
head label is placed, so the back edge lands on an aligned fetch block.
Every branch is rel32 and every peephole note compares its end against
codepos, so the pad invalidates nothing; DWARF rows cover it as part of
the loop statement's line. Executed once per loop entry (at most 15
nops), which is why the ratio rule above gates it.

--stats appends a "Profile use:" summary (profile_use_stats_dump).
*/
import lib.lib
import lib.sha256


int profile_use_mode
char* profile_use_path

# Where the current definition's token stream starts (set by the grammar,
# consumed and reset by profile_use_function_begin). -1: unknown, so the
# hash is not computed and the function is "unknown".
int profile_use_definition_start

# Class thresholds (see the header).
int profile_use_hot_entries
int profile_use_hot_loop_ratio
int profile_use_hot_loop_floor
int profile_use_count_cap

# Per-function state: class 0 unknown / 1 cold / 2 hot, the matched
# record (-1 when none) and the loop ordinal counter.
int profile_use_current_class
int profile_use_current_record
int profile_use_loop_ordinal
char* profile_use_current_name    # clone, for the --stats loop lines

# Records: one per 'f' hash, in file order.
int profile_use_record_count
int profile_use_record_capacity
int* profile_use_record_entries
int* profile_use_record_max_iters
char** profile_use_record_hash
map[char*, int] profile_use_hash_index    # hash -> record
map[char*, int] profile_use_loop_index    # "hash:ordinal" -> iters
map[char*, int] profile_use_names         # name, and its part before '$' -> 1
map[char*, int] profile_use_files         # repo-relative file -> 1

# --stats counters.
int profile_use_functions_seen
int profile_use_functions_hot
int profile_use_functions_cold
int profile_use_functions_stale
int profile_use_hashes_computed
int profile_use_loops_aligned
int profile_use_pad_bytes
int* profile_use_aligned_pos      # file offset of each aligned head
int* profile_use_aligned_pad      # the pad emitted before it
char** profile_use_aligned_name   # the function
int* profile_use_aligned_ordinal  # and the loop's ordinal in it
int profile_use_aligned_capacity

# Cached file-coverage answer for the current filename pointer.
char* profile_use_file_cache_name
int profile_use_file_cache_known

# Span-hash byte stream buffer.
char* profile_use_buf
int profile_use_buf_size
int profile_use_buf_pos


# --- queries -------------------------------------------------------------

int profile_use_active():
	return profile_use_mode


# 0 unknown (no profile, file not covered, or the hash no longer
# matches: apply the static heuristic), 1 cold, 2 hot.
int profile_function_class():
	if (profile_use_mode == 0): return 0
	return profile_use_current_class


# Entry count of the current function, or -1 when it is not matched.
int profile_function_entries():
	if (profile_use_current_record < 0): return -1
	return profile_use_record_entries[profile_use_current_record]


char* profile_use_loop_key(char* hash, int ordinal):
	char* digits = itoa(ordinal)
	char* with_colon = strjoin(hash, c":")
	char* key = strjoin(with_colon, digits)
	free(digits)
	free(with_colon)
	return key


# Head evaluations of the current function's ordinal-th while/for loop
# (1-based, emission order), or -1 when the function is not matched or
# the loop never ran.
int profile_loop_iters(int ordinal):
	if (profile_use_current_record < 0): return -1
	char* key = profile_use_loop_key(profile_use_record_hash[profile_use_current_record], ordinal)
	int iters = -1
	if (key in profile_use_loop_index): iters = profile_use_loop_index[key]
	free(key)
	return iters


# The ratio rule: >= 16 head evaluations per entry and >= 256 in all.
int profile_use_loop_is_hot(int iters, int entries):
	if (iters < profile_use_hot_loop_floor): return 0
	if (entries < 1): entries = 1
	return iters / entries >= profile_use_hot_loop_ratio


int profile_loop_hot(int ordinal):
	int iters = profile_loop_iters(ordinal)
	if (iters < 0): return 0
	return profile_use_loop_is_hot(iters, profile_function_entries())


# --- loading -------------------------------------------------------------

void profile_use_fail(char* what, char* detail):
	print_error(c"error: --profile-use: ")
	print_error(what)
	if (detail != 0):
		print_error(c" '")
		print_error(detail)
		print_error(c"'")
	print_error(c"\x0a")
	exit(1)


# Digits of s up to the first non-digit, saturating at 2^30 (identical
# on 32- and 64-bit hosts). -1 when s does not start with a digit.
int profile_use_parse_count(char* s):
	if ((s[0] < '0') || (s[0] > '9')): return -1
	int v = 0
	int i = 0
	while ((s[i] >= '0') && (s[i] <= '9')):
		# cap / 10 = 107374182: one more digit past that cannot overflow
		# a 32-bit int (<= 1073741829) and is clamped below
		if (v > 107374182): v = profile_use_count_cap
		else:
			v = v * 10 + (s[i] - '0')
			if (v > profile_use_count_cap): v = profile_use_count_cap
		i = i + 1
	return v


int profile_use_record_new(char* hash):
	if (profile_use_record_count >= profile_use_record_capacity):
		int grown = profile_use_record_capacity * 2
		if (grown < 256): grown = 256
		int* entries = cast(int*, malloc(grown * __word_size__))
		int* max_iters = cast(int*, malloc(grown * __word_size__))
		char** hashes = cast(char**, malloc(grown * __word_size__))
		int i = 0
		while (i < profile_use_record_count):
			entries[i] = profile_use_record_entries[i]
			max_iters[i] = profile_use_record_max_iters[i]
			hashes[i] = profile_use_record_hash[i]
			i = i + 1
		if (profile_use_record_entries != 0):
			free(cast(void*, profile_use_record_entries))
			free(cast(void*, profile_use_record_max_iters))
			free(cast(void*, profile_use_record_hash))
		profile_use_record_entries = entries
		profile_use_record_max_iters = max_iters
		profile_use_record_hash = hashes
		profile_use_record_capacity = grown
	int r = profile_use_record_count
	profile_use_record_entries[r] = 0
	profile_use_record_max_iters[r] = 0
	profile_use_record_hash[r] = hash
	profile_use_record_count = r + 1
	profile_use_hash_index[hash] = r
	return r


int profile_use_record_for(char* hash):
	if (hash in profile_use_hash_index): return profile_use_hash_index[hash]
	return profile_use_record_new(strclone(hash))


# Index name itself and, for a generic instantiation's mangled name
# ('max$int'), the definition's name before the '$'.
void profile_use_name_note(char* name):
	if ((name in profile_use_names) == 0): profile_use_names[strclone(name)] = 1
	int i = 0
	while ((name[i] != 0) && (name[i] != '$')): i = i + 1
	if (name[i] == '$'):
		char* base = cast(char*, malloc(i + 1))
		int j = 0
		while (j < i):
			base[j] = name[j]
			j = j + 1
		base[i] = 0
		if ((base in profile_use_names) == 0): profile_use_names[base] = 1
		else: free(base)


# One "f"/"l" line, already split at single spaces into fields[0..n).
void profile_use_apply_line(char** fields, int n, char* line):
	if (strlen(fields[1]) != 64): profile_use_fail(c"malformed hash in line", line)
	if (strcmp(fields[0], c"f") == 0):
		if ((n != 6) || (starts_with(fields[5], c"entries=") == 0)): profile_use_fail(c"malformed f line", line)
		int entries = profile_use_parse_count(fields[5] + 8)
		if (entries < 0): profile_use_fail(c"malformed f line", line)
		int r = profile_use_record_for(fields[1])
		int sum = profile_use_record_entries[r] + entries
		if (sum > profile_use_count_cap): sum = profile_use_count_cap
		profile_use_record_entries[r] = sum
	else if (strcmp(fields[0], c"l") == 0):
		if (n != 7): profile_use_fail(c"malformed l line", line)
		if ((starts_with(fields[5], c"head=") == 0) || (starts_with(fields[6], c"iters=") == 0)):
			profile_use_fail(c"malformed l line", line)
		int ordinal = profile_use_parse_count(fields[5] + 5)
		int iters = profile_use_parse_count(fields[6] + 6)
		if ((ordinal < 0) || (iters < 0)): profile_use_fail(c"malformed l line", line)
		int r = profile_use_record_for(fields[1])
		char* key = profile_use_loop_key(profile_use_record_hash[r], ordinal)
		int total = iters
		if (key in profile_use_loop_index):
			total = profile_use_loop_index[key] + iters
			if (total > profile_use_count_cap): total = profile_use_count_cap
			free(key)
			key = profile_use_loop_key(profile_use_record_hash[r], ordinal)
		profile_use_loop_index[key] = total
		if (total > profile_use_record_max_iters[r]): profile_use_record_max_iters[r] = total
	else: profile_use_fail(c"unknown profile line", line)
	profile_use_name_note(fields[2])
	if ((fields[3] in profile_use_files) == 0): profile_use_files[strclone(fields[3])] = 1


# The whole file, NUL-terminated (malloc'd), or 0.
char* profile_use_read_file(char* path):
	int fd = open(path, 0, 511)
	if (fd < 0): return 0
	int capacity = 65536
	int length = 0
	char* text = cast(char*, malloc(capacity + 1))
	int n = read(fd, text, capacity)
	while (n > 0):
		length = length + n
		if (length + 4096 > capacity):
			int grown = capacity * 2
			text = realloc(text, capacity + 1, grown + 1)
			capacity = grown
		n = read(fd, text + length, capacity - length)
	close(fd)
	text[length] = 0
	return text


void profile_use_load(char* path):
	if (path[0] == 0): profile_use_fail(c"a profile path is required (--profile-use=<path>)", 0)
	# Options are applied once in the whole-program pre-scan and again
	# per input file: the same profile loads once.
	if ((profile_use_mode != 0) && (strcmp(profile_use_path, path) == 0)): return
	if (profile_use_mode != 0): profile_use_fail(c"only one profile may be given; already using", profile_use_path)
	profile_use_hot_entries = 10000
	profile_use_hot_loop_ratio = 16
	profile_use_hot_loop_floor = 256
	profile_use_count_cap = 1073741824
	profile_use_definition_start = -1
	profile_use_current_record = -1
	profile_use_hash_index = new map[char*, int]
	profile_use_loop_index = new map[char*, int]
	profile_use_names = new map[char*, int]
	profile_use_files = new map[char*, int]
	char* text = profile_use_read_file(path)
	if (text == 0): profile_use_fail(c"cannot read profile", path)
	# Split in place: lines at '\n', fields at single ' '.
	int fields_max = 8
	char** fields = cast(char**, malloc((fields_max + 1) * __word_size__))
	int i = 0
	while (text[i] != 0):
		int line_start = i
		while ((text[i] != 0) && (text[i] != 10)): i = i + 1
		if (text[i] == 10):
			text[i] = 0
			i = i + 1
		char* line = text + line_start
		if ((line[0] == 0) || (line[0] == '#')): continue
		char* shown = strclone(line)
		int n = 0
		int at = 0
		while (1):
			if (n < fields_max):
				fields[n] = line + at
				n = n + 1
			while ((line[at] != 0) && (line[at] != ' ')): at = at + 1
			if (line[at] == 0): break
			line[at] = 0
			at = at + 1
		if (n < 6): profile_use_fail(c"malformed profile line", shown)
		profile_use_apply_line(fields, n, shown)
		free(shown)
	free(cast(void*, fields))
	free(text)
	profile_use_path = strclone(path)
	profile_use_mode = 1


# --- the span hash, fed by the scan ---------------------------------------

void profile_use_buf_reserve(int len):
	if (profile_use_buf_size == 0):
		profile_use_buf_size = 4096
		profile_use_buf = cast(char*, malloc(profile_use_buf_size))
	while (profile_use_buf_size <= profile_use_buf_pos + len):
		int old_size = profile_use_buf_size
		profile_use_buf_size = profile_use_buf_size << 1
		profile_use_buf = realloc(profile_use_buf, old_size, profile_use_buf_size)


void profile_hash_begin():
	profile_use_buf_pos = 0


# One token of the span, NUL-terminated text of len bytes: the same
# "<kind><len>:<text>" framing as defhash_process_span (its
# defhash_token_kind and itoa spelled inline: this runs once per token
# of every hashed body, so no allocation and no strlen).
void profile_hash_token(char* text, int len):
	int c0 = text[0] & 255
	int kind = 'o'
	if (c0 == 0): kind = 'e'
	else if (('0' <= c0) && (c0 <= '9')): kind = 'n'
	else if (c0 == '"'): kind = 's'
	else if (c0 == 39): kind = 'h'
	else if (((c0 == 's') || (c0 == 'c') || (c0 == 'f')) && (text[1] == '"')): kind = 's'
	else if (is_ident_start_byte(c0)): kind = 'i'
	profile_use_buf_reserve(len + 16)
	char* b = profile_use_buf
	int p = profile_use_buf_pos
	b[p] = kind
	p = p + 1
	int digits = 1
	int scale = 1
	while (len / scale >= 10):
		scale = scale * 10
		digits = digits + 1
	while (scale > 0):
		b[p] = '0' + (len / scale) % 10
		p = p + 1
		scale = scale / 10
	b[p] = ':'
	p = p + 1
	int i = 0
	while (i < len):
		b[p] = text[i]
		p = p + 1
		i = i + 1
	profile_use_buf_pos = p


# The 64-hex sha256 of the tokens fed since profile_hash_begin (malloc'd).
char* profile_hash_end():
	profile_use_hashes_computed = profile_use_hashes_computed + 1
	char* digest = cast(char*, malloc(32))
	sha256(profile_use_buf, profile_use_buf_pos, digest)
	char* hex = cast(char*, malloc(65))
	int i = 0
	while (i < 32):
		hex[i * 2] = diag_hex_digit((digest[i] >> 4) & 15)
		hex[i * 2 + 1] = diag_hex_digit(digest[i] & 15)
		i = i + 1
	hex[64] = 0
	free(digest)
	return hex


# --- the current function -----------------------------------------------

# name with whitespace removed (as the map writer spells it) and cut at
# the first '$' (a generic instantiation's base name), malloc'd.
char* profile_use_name_key(char* name):
	char* out = cast(char*, malloc(strlen(name) + 1))
	int i = 0
	int o = 0
	while ((name[i] != 0) && (name[i] != '$')):
		if ((name[i] != ' ') && (name[i] != 9)):
			out[o] = name[i]
			o = o + 1
		i = i + 1
	out[o] = 0
	return out


# Does the profile hold any entry from the file being compiled? The
# profile names files relative to the directory the profiled compile ran
# in; this compile's filename is made relative to its own cwd the same
# way (code_generator/profile_counters.w's map writer).
int profile_use_file_known():
	if (filename == 0): return 0
	if (filename == profile_use_file_cache_name): return profile_use_file_cache_known
	profile_use_file_cache_name = filename
	char* shown = filename
	int max_path_size = 4096
	char* cwd = cast(char*, malloc(max_path_size))
	getcwd(cwd, max_path_size)
	int cwd_len = strlen(cwd)
	if (starts_with(filename, cwd)):
		if (filename[cwd_len] == '/'): shown = filename + cwd_len + 1
	profile_use_file_cache_known = (shown in profile_use_files)
	free(cwd)
	return profile_use_file_cache_known


# The symbol the scan classified last, so the post-prologue hook does
# not classify it again (and does not consume a fresh definition start).
int profile_use_begun_symbol
int profile_use_begun_pending

# Start of a function body (the scan, before the prologue): reset the
# per-function state and settle what the name alone settles. Returns the
# definition's start offset when the profile knows the name, so the
# caller hashes the span and calls profile_use_function_classify; -1
# when the class is already final (unknown, or cold because the file is
# covered and the name is not).
int profile_use_function_prepare(int symbol, char* name):
	int start = profile_use_definition_start
	profile_use_definition_start = -1
	profile_use_current_class = 0
	profile_use_current_record = -1
	profile_use_loop_ordinal = 0
	profile_use_begun_symbol = symbol
	profile_use_begun_pending = 1
	if (profile_use_mode == 0): return -1
	profile_use_functions_seen = profile_use_functions_seen + 1
	if (profile_use_current_name != 0): free(profile_use_current_name)
	profile_use_current_name = 0
	if (name == 0): return -1
	profile_use_current_name = strclone(name)
	char* key = profile_use_name_key(name)
	int known_name = (key in profile_use_names)
	free(key)
	if (known_name == 0):
		if (profile_use_file_known()):
			profile_use_current_class = 1
			profile_use_functions_cold = profile_use_functions_cold + 1
		return -1
	return start


# The span's hash (0 when the scan could not read it): the final class.
void profile_use_function_classify(char* hex):
	if (hex == 0): return
	if ((hex in profile_use_hash_index) == 0):
		# The body changed since the profile was taken.
		profile_use_functions_stale = profile_use_functions_stale + 1
		return
	int r = profile_use_hash_index[hex]
	profile_use_current_record = r
	int entries = profile_use_record_entries[r]
	int hot = entries >= profile_use_hot_entries
	if (hot == 0): hot = profile_use_loop_is_hot(profile_use_record_max_iters[r], entries)
	if (hot):
		profile_use_current_class = 2
		profile_use_functions_hot = profile_use_functions_hot + 1
	else:
		profile_use_current_class = 1
		profile_use_functions_cold = profile_use_functions_cold + 1


# Right after be_function_prologue, through profile_function_enter /
# profile_generator_enter in code_generator/profile_counters.w (every
# function body, streaming and retained): a no-op when the scan already
# classified this symbol; otherwise (script main, generator bodies,
# kernels: bodies the scan never sees) the name alone decides and no
# hash is available, so a known name stays "unknown".
void profile_use_function_begin(int symbol, char* name):
	if (profile_use_begun_pending && (symbol == profile_use_begun_symbol)):
		profile_use_begun_pending = 0
		return
	profile_use_function_prepare(symbol, name)
	profile_use_begun_pending = 0


void profile_use_aligned_note(int pos, int pad):
	if (profile_use_loops_aligned >= profile_use_aligned_capacity):
		int grown = profile_use_aligned_capacity * 2
		if (grown < 64): grown = 64
		int* positions = cast(int*, malloc(grown * __word_size__))
		int* pads = cast(int*, malloc(grown * __word_size__))
		char** names = cast(char**, malloc(grown * __word_size__))
		int* ordinals = cast(int*, malloc(grown * __word_size__))
		int i = 0
		while (i < profile_use_loops_aligned):
			positions[i] = profile_use_aligned_pos[i]
			pads[i] = profile_use_aligned_pad[i]
			names[i] = profile_use_aligned_name[i]
			ordinals[i] = profile_use_aligned_ordinal[i]
			i = i + 1
		if (profile_use_aligned_pos != 0):
			free(cast(void*, profile_use_aligned_pos))
			free(cast(void*, profile_use_aligned_pad))
			free(cast(void*, profile_use_aligned_name))
			free(cast(void*, profile_use_aligned_ordinal))
		profile_use_aligned_pos = positions
		profile_use_aligned_pad = pads
		profile_use_aligned_name = names
		profile_use_aligned_ordinal = ordinals
		profile_use_aligned_capacity = grown
	int at = profile_use_loops_aligned
	profile_use_aligned_pos[at] = pos
	profile_use_aligned_pad[at] = pad
	char* name = c"?"
	if (profile_use_current_name != 0): name = strclone(profile_use_current_name)
	profile_use_aligned_name[at] = name
	profile_use_aligned_ordinal[at] = profile_use_loop_ordinal
	profile_use_loops_aligned = at + 1
	profile_use_pad_bytes = profile_use_pad_bytes + pad


# Right before be_ctrl_loop at a while/for head: count the loop and, when
# the profile marks it hot, pad to a 16-byte boundary (x86/x64 only).
void profile_use_loop_align():
	if (profile_use_mode == 0): return
	profile_use_loop_ordinal = profile_use_loop_ordinal + 1
	if (target_isa != 0): return
	if (profile_loop_hot(profile_use_loop_ordinal) == 0): return
	int pad = (16 - ((code_offset + codepos) & 15)) & 15
	int i = 0
	while (i < pad):
		emit(1, c"\x90")
		i = i + 1
	profile_use_aligned_note(codepos, pad)


# --stats: the summary line and one line per aligned loop head.
void profile_use_stats_dump():
	if (profile_use_mode == 0): return
	print_error(c"Profile use: ")
	print_error(profile_use_path)
	print_error(c": functions seen ")
	print_error(itoa(profile_use_functions_seen))
	print_error(c", hot ")
	print_error(itoa(profile_use_functions_hot))
	print_error(c", cold ")
	print_error(itoa(profile_use_functions_cold))
	print_error(c", stale ")
	print_error(itoa(profile_use_functions_stale))
	print_error(c", hashes computed ")
	print_error(itoa(profile_use_hashes_computed))
	print_error(c"; loops aligned ")
	print_error(itoa(profile_use_loops_aligned))
	print_error(c" (")
	print_error(itoa(profile_use_pad_bytes))
	print_error(c" pad bytes)\x0a")
	int i = 0
	while (i < profile_use_loops_aligned):
		print_error(c"Profile use: aligned loop head at file offset ")
		print_error(itoa(profile_use_aligned_pos[i]))
		print_error(c" pad ")
		print_error(itoa(profile_use_aligned_pad[i]))
		print_error(c": ")
		print_error(profile_use_aligned_name[i])
		print_error(c" loop ")
		print_error(itoa(profile_use_aligned_ordinal[i]))
		print_error(c"\x0a")
		i = i + 1
