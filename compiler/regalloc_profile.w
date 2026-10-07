/*
P2: the profile's say in the register pre-scan (unit P2 phase B,
docs/projects/register_allocation_pgo.md §3.4). Imported by
compiler/regalloc_scan.w after its byte source (rs_next/rs_c), which this
file reads; regalloc_function_scan calls rs_profile_begin before its
heuristic and rs_profile_pass_begin before each pass, rs_identifier
calls rs_profile_loop_note at each while/for head and rs_weight asks
rs_profile_weight when a profile matched the function.

Three things live here:

- rs_hash_span: the definition's defhash computed from the scanner's
  byte source. It reproduces compiler/tokenizer.w's get_token token
  boundaries (identifier runs with UTF-8 sequences, prefixed and plain
  string/char literals with escapes, f-string opening chunks, numbers
  with fraction and exponent, the <=>|&! runs, + - * % ^ with = or
  doubling, := , comments, single characters) and the span end rule
  (the first token that opens a line at tab level 0, after the first
  token), feeding compiler/profile_use.w's profile_hash_token so the
  bytes hashed are exactly defhash_process_span's. Anything the real
  tokenizer would reject (EOF in a literal, a bad UTF-8 sequence, a lone
  '}' in a template chunk) aborts and the function is "unknown". Every
  byte is already in the scanner's budget: this replaces phase A's
  get_token look-ahead, which cost +8-14% of a compile.
- the decision: cold functions skip the scan entirely (no probe, no
  full pass), hot ones go straight to the full pass (no probe), unknown
  ones keep R2's heuristic (probe for a loop, then the full pass).
- the weights: in a matched function the use weight inside a loop is
  that loop's head evaluations per entry from the profile (capped,
  1 when the loop never ran) instead of 8^depth, by the loop's ordinal
  within the function -- the n-th while/for keyword at a line start,
  which is how code_generator/profile_counters.w numbered the 'l'
  entries (a loop keyword not at a line start would shift the ordinals
  of the loops after it: performance only).
*/
import lib.lib
import compiler.profile_use


int rs_profile_class          # 0 unknown, 1 cold, 2 hot (this function)
int rs_profile_weighted       # 1: rs_weight takes the profile's counts
int rs_profile_ordinal        # while/for heads seen in the current pass
int[64] rs_profile_loop_weight
int rs_profile_cold_skipped   # --stats
int rs_profile_hot_scanned
int rs_profile_fruitless      # full passes that promoted nothing

# Token text for the hash pass.
char* rs_hash_tok
int rs_hash_tok_size
int rs_hash_tok_len
int rs_hash_tabs              # tabs consumed since the last newline (tab_level)


void rs_hash_put(int c):
	if (rs_hash_tok_len + 2 > rs_hash_tok_size):
		int x = rs_hash_tok_size << 1
		if (x < 64): x = 64
		if (rs_hash_tok == 0): rs_hash_tok = malloc(x)
		else: rs_hash_tok = realloc(rs_hash_tok, rs_hash_tok_size, x)
		rs_hash_tok_size = x
	rs_hash_tok[rs_hash_tok_len] = c
	rs_hash_tok_len = rs_hash_tok_len + 1


# Consume rs_c the way get_character accounts for it (tab_level), then
# load the next byte.
void rs_hnext():
	if (rs_c == 10): rs_hash_tabs = 0
	else if (rs_c == 9): rs_hash_tabs = rs_hash_tabs + 1
	rs_next()


# takechar's twin.
void rs_htake():
	rs_hash_put(rs_c)
	rs_hnext()


# A quoted literal body after its opening quote was taken: through the
# closing quote, backslash escaping the next byte. 0 at EOF.
int rs_hash_quoted(int quote):
	while (rs_c != quote):
		if (rs_c == -1): return 0
		if (rs_c == 92):
			rs_htake()
			if (rs_c == -1): return 0
		rs_htake()
	rs_htake()
	return 1


# take_template_chunk: the raw text up to and including the closing '"'
# or a single '{'. 0 when the real tokenizer would error.
int rs_hash_template_chunk():
	while (1):
		if (rs_c == -1): return 0
		if (rs_c == '"'):
			rs_htake()
			return 1
		if (rs_c == '{'):
			rs_htake()
			if (rs_c == '{'): rs_htake()
			else: return 1
		else if (rs_c == '}'):
			rs_htake()
			if (rs_c == '}'): rs_htake()
			else: return 0
		else:
			if (rs_c == 92):
				rs_htake()
				if (rs_c == -1): return 0
			rs_htake()
	return 0


int rs_hash_is_ascii_ident(int c):
	return (('a' <= c) && (c <= 'z')) || (('A' <= c) && (c <= 'Z')) || (('0' <= c) && (c <= '9')) || (c == '_')


# take_ident_run: identifier bytes, a UTF-8 lead byte with its
# continuation bytes. 0 on a malformed sequence.
int rs_hash_ident_run():
	while (rs_c != -1):
		int c = rs_c & 255
		if (rs_hash_is_ascii_ident(c)):
			# The common byte: rs_htake with its tab accounting (a no-op
			# for an identifier byte) and rs_hash_put's growth check inline.
			if (rs_hash_tok_len + 2 > rs_hash_tok_size): rs_hash_put(c)
			else:
				rs_hash_tok[rs_hash_tok_len] = c
				rs_hash_tok_len = rs_hash_tok_len + 1
			rs_next()
		else if ((c >= 194) && (c <= 244)):
			int need = 1
			if (c >= 240): need = 3
			else if (c >= 224): need = 2
			rs_htake()
			int j = 0
			while (j < need):
				int d = rs_c & 255
				if ((rs_c == -1) || (d < 128) || (d > 191)): return 0
				rs_htake()
				j = j + 1
		else: return 1
	return 1


int rs_hash_is_run_char(int c):
	return (c == '<') || (c == '=') || (c == '>') || (c == '|') || (c == '&') || (c == '!')


# One get_token: the token in rs_hash_tok (rs_hash_tok_len 0 at EOF),
# newline_out[0] set when a newline was skipped before it. 0 when the
# real tokenizer would have errored.
int rs_hash_token(int* newline_out):
	int w = 1
	int newline = 0
	while (w):
		w = 0
		while ((rs_c == ' ') || (rs_c == 9) || (rs_c == 10)):
			if (rs_c == 10): newline = 1
			rs_hnext()
		rs_hash_tok_len = 0
		if (rs_hash_ident_run() == 0): return 0
		if (rs_hash_tok_len == 1):
			int p = rs_hash_tok[0]
			if (((p == 's') || (p == 'c')) && (rs_c == '"')):
				rs_htake()
				if (rs_hash_quoted('"') == 0): return 0
			else if ((p == 'f') && (rs_c == '"')):
				rs_htake()
				if (rs_hash_template_chunk() == 0): return 0
		if (rs_hash_tok_len > 0):
			if (('0' <= rs_hash_tok[0]) && (rs_hash_tok[0] <= '9')):
				if (rs_c == '.'):
					rs_htake()
					while (rs_hash_is_ascii_ident(rs_c)): rs_htake()
				int last = rs_hash_tok[rs_hash_tok_len - 1]
				if ((rs_hash_tok_len >= 2) && (rs_hash_tok[1] != 'x') && ((last == 'e') || (last == 'E'))):
					if ((rs_c == '+') || (rs_c == '-')):
						rs_htake()
						while (('0' <= rs_c) && (rs_c <= '9')): rs_htake()
		if (rs_hash_tok_len == 0):
			while (rs_hash_is_run_char(rs_c)): rs_htake()
		if (rs_hash_tok_len == 0):
			if ((rs_c == '+') || (rs_c == '-') || (rs_c == '*') || (rs_c == '%') || (rs_c == '^')):
				rs_htake()
				if (rs_c == '='): rs_htake()
				else if ((rs_hash_tok[0] == '+') && (rs_c == '+')): rs_htake()
				else if ((rs_hash_tok[0] == '-') && (rs_c == '-')): rs_htake()
		if (rs_hash_tok_len == 0):
			if (rs_c == ':'):
				rs_htake()
				if (rs_c == '='): rs_htake()
		if (rs_hash_tok_len == 0):
			if (rs_c == 39):
				rs_htake()
				if (rs_hash_quoted(39) == 0): return 0
			else if (rs_c == '"'):
				rs_htake()
				if (rs_hash_quoted('"') == 0): return 0
			else if (rs_c == '/'):
				rs_htake()
				if (rs_c == '*'):
					rs_hnext()
					while ((rs_c != '/') && (rs_c != -1)):
						while ((rs_c != '*') && (rs_c != -1)): rs_hnext()
						rs_hnext()
					rs_hnext()
					w = 1
				else if (rs_c == '='): rs_htake()
			else if (rs_c == '#'):
				rs_htake()
				rs_hnext()
				while ((rs_c != 10) && (rs_c != -1)): rs_hnext()
				w = 1
			else if (rs_c != -1): rs_htake()
	rs_hash_put(0)
	rs_hash_tok_len = rs_hash_tok_len - 1
	newline_out[0] = newline
	return 1


# The defhash of the definition starting at file offset start (64 hex,
# malloc'd), or 0 when the span could not be read or lexed.
char* rs_hash_span(int start):
	rs_abort = 0
	rs_begin(start)
	rs_hash_tabs = 0
	rs_next()
	if (rs_abort || (rs_c == -1)): return 0
	profile_hash_begin()
	int first = 1
	int newline = 0
	while (1):
		if (rs_hash_token(&newline) == 0): return 0
		if (rs_abort): return 0
		if (rs_hash_tok_len == 0): break
		if ((first == 0) && newline && (rs_hash_tabs == 0)): break
		first = 0
		profile_hash_token(rs_hash_tok, rs_hash_tok_len)
	return profile_hash_end()


# Before the heuristic, with the function's symbol: the profile's class
# for it (0 unknown, 1 cold, 2 hot), hashing the definition's span from
# the scanner's byte source when the profile knows the name.
int rs_profile_begin(int symbol):
	rs_profile_class = 0
	rs_profile_weighted = 0
	int start = profile_use_function_prepare(symbol, sym_record_name(symbol))
	if (start >= 0):
		char* hex = 0
		if ((file >= 0) && (file < GETCHAR_MAX_FD)): hex = rs_hash_span(start)
		profile_use_function_classify(hex)
		if (hex != 0): free(hex)
	rs_profile_class = profile_function_class()
	if (profile_function_entries() >= 0): rs_profile_weighted = 1
	if (rs_profile_class == 1): rs_profile_cold_skipped = rs_profile_cold_skipped + 1
	if (rs_profile_class == 2): rs_profile_hot_scanned = rs_profile_hot_scanned + 1
	return rs_profile_class


void rs_profile_pass_begin():
	rs_profile_ordinal = 0


# A while/for head was just pushed (rs_loop_count counts it): its use
# weight is the profile's head evaluations per entry, 1 when it never
# ran, capped so sums cannot overflow.
void rs_profile_loop_note():
	rs_profile_ordinal = rs_profile_ordinal + 1
	if (rs_profile_weighted == 0): return
	if ((rs_loop_count < 1) || (rs_loop_count > 64)): return
	int weight = 1
	int iters = profile_loop_iters(rs_profile_ordinal)
	if (iters > 0):
		int entries = profile_function_entries()
		if (entries < 1): entries = 1
		weight = iters / entries
		if (weight < 1): weight = 1
		if (weight > 1048576): weight = 1048576
	rs_profile_loop_weight[rs_loop_count - 1] = weight


int rs_profile_weight():
	if ((rs_loop_count < 1) || (rs_loop_count > 64)): return 1
	return rs_profile_loop_weight[rs_loop_count - 1]


void rs_profile_stats_dump():
	print_int0(c"regalloc: full passes promoting nothing: ", rs_profile_fruitless)
	print_error(c"\x0a")
	if (profile_use_active() == 0): return
	print_int0(c"regalloc: profile: cold bodies skipped: ", rs_profile_cold_skipped)
	print_int0(c" hot bodies scanned: ", rs_profile_hot_scanned)
	print_error(c"\x0a")
