# Lexer-rule shape analysis for the matcher generator: command refusals,
# right-recursion unrolling, nested-delimiter shapes, refuse reasons.
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.charsets
import libs.extras.grammars.antlr_to_pg.matchers_ascii

int at_command_is_refused(char* command):
	if (command == 0):
		return 0
	# Stateful metadata executes commands after choosing a match. Their
	# full ordered list is validated separately by the semantic audit.
	if (g_at_stateful): return 0
	if (strcmp(command, c"skip") == 0):
		return 0
	if (strcmp(command, c"channel") == 0):
		return 0
	# type(...) only remaps the token id; matching can still run. The
	# remap itself is ignored (pg has no token-type rewrite).
	if (strcmp(command, c"type") == 0):
		return 0
	return 1


int at_altlist_can_match_empty(list[at_alt*] alts);
int at_element_can_match_empty(at_element* e);


int at_elements_can_match_empty(list[at_element*] elements):
	int i = 0
	while (i < elements.length):
		at_element* e = elements[i]
		if (at_element_can_match_empty(e) == 0):
			return 0
		i = i + 1
	return 1


int at_element_can_match_empty(at_element* e):
	if ((e.suffix == '?') || (e.suffix == '*')):
		return 1
	if (e.kind == 3):
		return at_altlist_can_match_empty(e.group_alts)
	if (e.kind == 2):
		at_rule* frag = at_lookup_lexer_piece(e.text)
		if (frag != 0):
			return at_altlist_can_match_empty(frag.alts)
	return 0


int at_altlist_can_match_empty(list[at_alt*] alts):
	if (alts == 0):
		return 1
	if (alts.length == 0):
		return 1
	int i = 0
	while (i < alts.length):
		at_alt* alt = alts[i]
		if (at_elements_can_match_empty(alt.elements)):
			return 1
		i = i + 1
	return 0


char* at_refuse_reason_element(at_element* e, int depth);
char* at_refuse_reason_altlist(list[at_alt*] alts, int depth);
int at_is_nested_delim_frag(at_rule* frag, int* out_d, int* out_open, int* out_close);
int at_is_self_nested_block_comment(at_rule* rule, int* out_open_len, char** out_open, int* out_close_len, char** out_close);
int at_unroll_right_recursion(at_rule* rule);
void at_emit_c_char_literal(string_builder* out, int c);


# True when `e` (or its nested group) mentions `name` as a lexer/fragment ref.
int at_element_refs_name(at_element* e, char* name):
	if (e == 0):
		return 0
	if (e.kind == 2):
		if (e.text != 0):
			if (strcmp(e.text, name) == 0):
				return 1
		return 0
	if (e.kind == 3):
		if (e.group_alts == 0):
			return 0
		int i = 0
		while (i < e.group_alts.length):
			at_alt* a = e.group_alts[i]
			int j = 0
			while (j < a.elements.length):
				if (at_element_refs_name(a.elements[j], name)):
					return 1
				j = j + 1
			i = i + 1
	return 0


int at_alt_refs_name(at_alt* alt, char* name):
	int i = 0
	while (i < alt.elements.length):
		if (at_element_refs_name(alt.elements[i], name)):
			return 1
		i = i + 1
	return 0


int at_altlist_refs_name(list[at_alt*] alts, char* name):
	int i = 0
	while (i < alts.length):
		if (at_alt_refs_name(alts[i], name)):
			return 1
		i = i + 1
	return 0


# Clone an element shallowly (shared text / group_alts pointers).
at_element* at_clone_element(at_element* e):
	at_element* c = new at_element()
	c.kind = e.kind
	c.text = e.text
	c.group_alts = e.group_alts
	c.suffix = e.suffix
	c.sites = e.sites
	c.label = e.label
	c.nongreedy = e.nongreedy
	c.first = e.first
	c.last = e.last
	return c


list[at_element*] at_clone_elements_prefix(list[at_element*] elements, int n):
	list[at_element*] out = new list[at_element*]
	int i = 0
	while (i < n):
		out.push(at_clone_element(elements[i]))
		i = i + 1
	return out


# Rewrites must not erase actions, predicates, labels, or matching options.
int at_rewrite_plain_alts(list[at_alt*] alts):
	int ai = 0
	while (ai < alts.length):
		at_alt* alt = alts[ai]
		if ((alt.label != 0) || ((alt.sites != 0) && (alt.sites.length > 0))): return 0
		int ei = 0
		while (ei < alt.elements.length):
			at_element* e = alt.elements[ei]
			if ((e.label != 0) || e.nongreedy): return 0
			if ((e.sites != 0) && (e.sites.length > 0)): return 0
			if ((e.kind == 3) && (at_rewrite_plain_alts(e.group_alts) == 0)): return 0
			ei = ei + 1
		ai = ai + 1
	return 1


int at_rewrite_consuming_alts(list[at_alt*] alts, int depth);

# A bounded proof, not an assumption that an unknown/cyclic reference consumes.
int at_rewrite_consuming_elements(list[at_element*] elements, int begin, int end, int depth):
	if (depth > 32): return 0
	int i = begin
	while (i < end):
		at_element* e = elements[i]
		if ((e.suffix != '?') && (e.suffix != '*')):
			if ((e.kind == 0) && (strlen(e.text) > 0)): return 1
			if ((e.kind == 1) || (e.kind == 4) || (e.kind == 5)): return 1
			if ((e.kind == 3) && at_rewrite_consuming_alts(e.group_alts, depth + 1)): return 1
			if (e.kind == 2):
				at_rule* piece = at_lookup_lexer_piece(e.text)
				if ((piece != 0) && at_rewrite_consuming_alts(piece.alts, depth + 1)): return 1
		i = i + 1
	return 0


int at_rewrite_consuming_alts(list[at_alt*] alts, int depth):
	if ((depth > 32) || (alts.length == 0)): return 0
	int i = 0
	while (i < alts.length):
		if (at_rewrite_consuming_elements(alts[i].elements, 0, alts[i].elements.length, depth + 1) == 0): return 0
		i = i + 1
	return 1


# A right-recursion loop must not greedily swallow the beginning of its
# required base. Compute conservative ASCII first sets; unknown/recursive
# starts refuse. Nullable prefixes contribute their set and the next element.
int at_rewrite_first_alts(list[at_alt*] alts, char* initial, int depth);

# The general legacy decoder falls back to literal letters for unknown
# escapes. That is not a proof: admit only unambiguous ASCII escapes here.
int at_rewrite_ascii_escape(char* raw, int i, int end, int* advance):
	if (i + 1 >= end): return -1
	int c = raw[i + 1]
	if ((c != 't') && (c != 'n') && (c != 'r') && (c != 92) && (c != ']') && (c != '-') && (c != '^')): return -1
	return at_parse_charset_escape(raw, i, end, advance)


int at_rewrite_first_element(at_element* e, char* initial, int depth):
	if (depth > 32): return 0
	if (e.kind == 0):
		if (strlen(e.text) == 0): return 1
		int c = cast(int, e.text[0]) & 255
		if (c > 127): return 0
		initial[c] = 1
		return 1
	if (e.kind == 3): return at_rewrite_first_alts(e.group_alts, initial, depth + 1)
	if (e.kind == 2):
		at_rule* piece = at_lookup_lexer_piece(e.text)
		if (piece != 0): return at_rewrite_first_alts(piece.alts, initial, depth + 1)
		return 0
	if ((e.kind != 1) || (e.text == 0) || at_charset_negated(e.text)): return 0
	int end = strlen(e.text) - 1
	if ((end < 1) || (e.text[0] != '[') || (e.text[end] != ']')): return 0
	int i = 1
	while (i < end):
		int advance = 1
		int low = cast(int, e.text[i]) & 255
		if (low == 92): low = at_rewrite_ascii_escape(e.text, i, end, &advance)
		if ((low < 0) || (low > 127) || (advance <= 0)): return 0
		i = i + advance
		int high = low
		if ((i + 1 < end) && (e.text[i] == '-')):
			i = i + 1
			advance = 1
			high = cast(int, e.text[i]) & 255
			if (high == 92): high = at_rewrite_ascii_escape(e.text, i, end, &advance)
			if ((high < low) || (high > 127) || (advance <= 0)): return 0
			i = i + advance
		while (low <= high):
			initial[low] = 1
			low = low + 1
	return 1


int at_rewrite_first_elements(list[at_element*] elements, int end, char* initial, int depth):
	if (depth > 32): return 0
	int i = 0
	while (i < end):
		if (at_rewrite_first_element(elements[i], initial, depth + 1) == 0): return 0
		if (at_rewrite_consuming_elements(elements, i, i + 1, 0)): return 1
		i = i + 1
	return 1


int at_rewrite_first_alts(list[at_alt*] alts, char* initial, int depth):
	if ((depth > 32) || (alts.length == 0)): return 0
	for at_alt* alt in alts:
		if (at_rewrite_first_elements(alt.elements, alt.elements.length, initial, depth + 1) == 0): return 0
	return 1


int at_rewrite_disjoint_initials(at_alt* prefix, at_alt* base):
	char* prefix_set = cast(char*, malloc(128))
	char* base_set = cast(char*, malloc(128))
	for i in range(128):
		prefix_set[i] = 0
		base_set[i] = 0
	int known = at_rewrite_first_elements(prefix.elements, prefix.elements.length - 1, prefix_set, 0)
	known = known && at_rewrite_first_elements(base.elements, base.elements.length, base_set, 0)
	int i = 0
	while (i < 128):
		if (prefix_set[i] && base_set[i]): known = 0
		i = i + 1
	free(prefix_set)
	free(base_set)
	return known


# Rewrite regular right-/left-recursive lexer shapes into loops:
#   X: PREFIX X?          → PREFIX+
#   X: BASE | PREFIX X    → PREFIX* BASE
#   X: BASE | X SUFFIX    → BASE SUFFIX*
#   X: PREFIX (MID X)*    → PREFIX (MID PREFIX)*
#   X: PREFIX (MID X)?    → PREFIX (MID PREFIX)*
# Returns 1 if the rule was rewritten.
int at_unroll_right_recursion(at_rule* rule):
	if (rule == 0):
		return 0
	if (rule.alts == 0):
		return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return 0
	if (at_rewrite_plain_alts(rule.alts) == 0): return 0
	char* name = rule.name
	# --- Shape: single alt, PREFIX then optional trailing self-ref ---
	if (rule.alts.length == 1):
		at_alt* alt = rule.alts[0]
		if (alt.elements.length >= 2):
			at_element* last = alt.elements[alt.elements.length - 1]
			if ((last.kind == 2) && (last.text != 0)):
				if (strcmp(last.text, name) == 0):
					if (last.suffix == '?'):
						# PREFIX must not itself mention name.
						int ok = at_rewrite_consuming_elements(alt.elements, 0, alt.elements.length - 1, 0)
						int i = 0
						while (i < alt.elements.length - 1):
							if (at_element_refs_name(alt.elements[i], name)):
								ok = 0
							i = i + 1
						if (ok):
							# PREFIX+ : wrap prefix elements in a + group (or mark sole elem +).
							if (alt.elements.length == 2):
								at_element* only = alt.elements[0]
								if (only.suffix == 0):
									only.suffix = '+'
									list[at_element*] elems = new list[at_element*]
									elems.push(only)
									alt.elements = elems
									return 1
							# Multi-element prefix → (PREFIX)+
							at_element* grp = new at_element()
							grp.kind = 3
							grp.text = 0
							grp.suffix = '+'
							grp.group_alts = new list[at_alt*]
							at_alt* body = new at_alt()
							body.elements = at_clone_elements_prefix(alt.elements, alt.elements.length - 1)
							grp.group_alts.push(body)
							list[at_element*] elems2 = new list[at_element*]
							elems2.push(grp)
							alt.elements = elems2
							return 1
		# --- Shape: PREFIX (MID X)* or PREFIX (MID X)? ---
		# A suffix after the recursive group would occur at every nesting
		# depth; flattening it to one trailing suffix changes the language.
		int gi = 0
		while (gi < alt.elements.length):
			at_element* ge = alt.elements[gi]
			if ((gi == alt.elements.length - 1) && (ge.kind == 3) && ((ge.suffix == '*') || (ge.suffix == '?'))):
				if (ge.group_alts != 0):
					if (ge.group_alts.length == 1):
						at_alt* galt = ge.group_alts[0]
						if (galt.elements.length >= 1):
							at_element* gself = galt.elements[galt.elements.length - 1]
							if ((gself.kind == 2) && (gself.suffix == 0) && (gself.text != 0)):
								if (strcmp(gself.text, name) == 0):
									# PREFIX (elems before gi), MID, and SUFFIX
									# (elems after gi) must not mention name.
									int ok = at_rewrite_consuming_elements(alt.elements, 0, gi, 0)
									int i = 0
									while (i < alt.elements.length):
										if (i != gi):
											if (at_element_refs_name(alt.elements[i], name)):
												ok = 0
										i = i + 1
									int j = 0
									while (j < galt.elements.length - 1):
										if (at_element_refs_name(galt.elements[j], name)):
											ok = 0
										j = j + 1
									if (ok):
										if (gi < 1):
											ok = 0
									if (ok):
										list[at_element*] new_g = new list[at_element*]
										j = 0
										while (j < galt.elements.length - 1):
											new_g.push(at_clone_element(galt.elements[j]))
											j = j + 1
										i = 0
										while (i < gi):
											new_g.push(at_clone_element(alt.elements[i]))
											i = i + 1
										galt.elements = new_g
										ge.suffix = '*'
										return 1
			gi = gi + 1
	# --- Shape: BASE | PREFIX X  (right-recursive alt) ---
	# --- Shape: BASE | X SUFFIX (left-recursive alt) ---
	if (rule.alts.length == 2):
		int base_i = -1
		int rec_i = -1
		int right_rec = 0
		int left_rec = 0
		int ai = 0
		while (ai < 2):
			at_alt* a = rule.alts[ai]
			if (at_alt_refs_name(a, name) == 0):
				base_i = ai
			else:
				if (a.elements.length >= 2):
					at_element* first = a.elements[0]
					at_element* last = a.elements[a.elements.length - 1]
					if ((last.kind == 2) && (last.suffix == 0) && (last.text != 0)):
						if (strcmp(last.text, name) == 0):
							# PREFIX X — PREFIX must not mention name
							int ok = 1
							int k = 0
							while (k < a.elements.length - 1):
								if (at_element_refs_name(a.elements[k], name)):
									ok = 0
								k = k + 1
							if (ok):
								rec_i = ai
								right_rec = 1
					if ((first.kind == 2) && (first.suffix == 0) && (first.text != 0)):
						if (strcmp(first.text, name) == 0):
							int ok2 = 1
							int k2 = 1
							while (k2 < a.elements.length):
								if (at_element_refs_name(a.elements[k2], name)):
									ok2 = 0
								k2 = k2 + 1
							if (ok2):
								rec_i = ai
								left_rec = 1
			ai = ai + 1
		if ((base_i >= 0) && (rec_i >= 0) && (base_i != rec_i)):
			at_alt* base = rule.alts[base_i]
			at_alt* rec = rule.alts[rec_i]
			if (at_rewrite_consuming_elements(base.elements, 0, base.elements.length, 0) == 0): return 0
			if (right_rec):
				if (at_rewrite_consuming_elements(rec.elements, 0, rec.elements.length - 1, 0) == 0): return 0
				if (at_rewrite_disjoint_initials(rec, base) == 0): return 0
				# PREFIX* BASE
				at_element* loop = new at_element()
				loop.kind = 3
				loop.text = 0
				loop.suffix = '*'
				loop.group_alts = new list[at_alt*]
				at_alt* pref = new at_alt()
				pref.elements = at_clone_elements_prefix(rec.elements, rec.elements.length - 1)
				loop.group_alts.push(pref)
				list[at_element*] elems = new list[at_element*]
				elems.push(loop)
				int bi = 0
				while (bi < base.elements.length):
					elems.push(at_clone_element(base.elements[bi]))
					bi = bi + 1
				at_alt* neu = new at_alt()
				neu.elements = elems
				list[at_alt*] alts = new list[at_alt*]
				alts.push(neu)
				rule.alts = alts
				return 1
			if (left_rec):
				if (at_rewrite_consuming_elements(rec.elements, 1, rec.elements.length, 0) == 0): return 0
				# BASE SUFFIX*
				list[at_element*] elems = new list[at_element*]
				int bi = 0
				while (bi < base.elements.length):
					elems.push(at_clone_element(base.elements[bi]))
					bi = bi + 1
				at_element* loop = new at_element()
				loop.kind = 3
				loop.text = 0
				loop.suffix = '*'
				loop.group_alts = new list[at_alt*]
				at_alt* suf = new at_alt()
				suf.elements = new list[at_element*]
				int si = 1
				while (si < rec.elements.length):
					suf.elements.push(at_clone_element(rec.elements[si]))
					si = si + 1
				loop.group_alts.push(suf)
				elems.push(loop)
				at_alt* neu = new at_alt()
				neu.elements = elems
				list[at_alt*] alts = new list[at_alt*]
				alts.push(neu)
				rule.alts = alts
				return 1
	return 0


# Lua/CMake/Rust-raw shape:
#   fragment F: D F D | OPEN .*? CLOSE
# where D/OPEN/CLOSE are single-byte literals. Returns 1 and fills outs.
int at_is_nested_delim_frag(at_rule* frag, int* out_d, int* out_open, int* out_close):
	if (frag == 0):
		return 0
	if (frag.alts.length != 2):
		return 0
	int rec_i = -1
	int base_i = -1
	int d_char = 0
	int open_char = 0
	int close_char = 0
	int ai = 0
	while (ai < 2):
		at_alt* a = frag.alts[ai]
		if (a.elements.length == 3):
			at_element* e0 = a.elements[0]
			at_element* e1 = a.elements[1]
			at_element* e2 = a.elements[2]
			# Nested ifs: W's & does not short-circuit, so null text must be
			# guarded before strlen/strcmp.
			if ((e0.kind == 0) && (e0.suffix == 0) && (e0.text != 0)):
				if ((e2.kind == 0) && (e2.suffix == 0) && (e2.text != 0)):
					if ((strlen(e0.text) == 1) & (strlen(e2.text) == 1)):
						if ((e1.kind == 2) && (e1.suffix == 0) && (e1.text != 0)):
							if ((strcmp(e1.text, frag.name) == 0) & (e0.text[0] == e2.text[0])):
								rec_i = ai
								d_char = e0.text[0]
						if ((e1.kind == 4) && (e1.suffix == '*')):
							base_i = ai
							open_char = e0.text[0]
							close_char = e2.text[0]
		ai = ai + 1
	if ((rec_i < 0) || (base_i < 0) || (rec_i == base_i)):
		return 0
	*out_d = d_char
	*out_open = open_char
	*out_close = close_char
	return 1


# Direct self-recursive nested open/close:
#   RULE: OPEN ( RULE | . )* CLOSE
#   RULE: OPEN ( RULE | ~[CLOSE] )* CLOSE   (ASL JSON_PATH_BRACK)
# (non-greedy ? on the star is ignored). Open/close are short ASCII literals.
# The non-self alt may be wildcard, charset, or negated charset — the emitter
# still scans byte-by-byte and only special-cases open/close prefixes.
int at_is_self_nested_block_comment(at_rule* rule, int* out_open_len, char** out_open, int* out_close_len, char** out_close):
	if (rule == 0):
		return 0
	if (rule.alts.length != 1):
		return 0
	at_alt* alt = rule.alts[0]
	if (alt.elements.length != 3):
		return 0
	at_element* e0 = alt.elements[0]
	at_element* e1 = alt.elements[1]
	at_element* e2 = alt.elements[2]
	if ((e0.kind != 0) || (e0.suffix != 0) || (e2.kind != 0) || (e2.suffix != 0)):
		return 0
	if ((e0.text == 0) || (e2.text == 0)):
		return 0
	if ((strlen(e0.text) < 1) | (strlen(e2.text) < 1)):
		return 0
	if ((e1.kind != 3) || (e1.suffix != '*')):
		return 0
	if (e1.group_alts == 0):
		return 0
	if (e1.group_alts.length != 2):
		return 0
	int saw_self = 0
	int saw_any = 0
	int gi = 0
	while (gi < e1.group_alts.length):
		at_alt* ga = e1.group_alts[gi]
		if (ga.elements.length == 1):
			at_element* ge = ga.elements[0]
			if ((ge.suffix == 0) && (ge.kind == 2) && (ge.text != 0)):
				if (strcmp(ge.text, rule.name) == 0):
					saw_self = 1
			# Wildcard, charset, or negated charset stand in for "other char".
			if ((ge.suffix == 0) && ((ge.kind == 4) || (ge.kind == 1) || (ge.kind == 5))):
				saw_any = 1
		gi = gi + 1
	if ((saw_self == 0) || (saw_any == 0)):
		return 0
	*out_open = e0.text
	*out_open_len = strlen(e0.text)
	*out_close = e2.text
	*out_close_len = strlen(e2.text)
	return 1


void at_emit_nested_delim_function(char* fn_name, int d_char, int open_char, int close_char, int is_token):
	string_append(g_matchers_out, c"\nint ")
	string_append(g_matchers_out, fn_name)
	string_append(g_matchers_out, c"(char* input, int index):\n")
	string_append(g_matchers_out, c"\tint _start = index\n")
	string_append(g_matchers_out, c"\tint depth = 0\n")
	string_append(g_matchers_out, c"\twhile (input[index] == ")
	at_emit_c_char_literal(g_matchers_out, d_char)
	string_append(g_matchers_out, c"):\n")
	string_append(g_matchers_out, c"\t\tdepth = depth + 1\n")
	string_append(g_matchers_out, c"\t\tindex = index + 1\n")
	string_append(g_matchers_out, c"\tif (input[index] != ")
	at_emit_c_char_literal(g_matchers_out, open_char)
	string_append(g_matchers_out, c"):\n")
	if (is_token):
		string_append(g_matchers_out, c"\t\treturn 0\n")
	else:
		string_append(g_matchers_out, c"\t\treturn -1\n")
	string_append(g_matchers_out, c"\tindex = index + 1\n")
	string_append(g_matchers_out, c"\twhile (input[index] != 0):\n")
	string_append(g_matchers_out, c"\t\tif (input[index] == ")
	at_emit_c_char_literal(g_matchers_out, close_char)
	string_append(g_matchers_out, c"):\n")
	string_append(g_matchers_out, c"\t\t\tint ok = 1\n")
	string_append(g_matchers_out, c"\t\t\tint k = 0\n")
	string_append(g_matchers_out, c"\t\t\twhile (k < depth):\n")
	string_append(g_matchers_out, c"\t\t\t\tif (input[index + 1 + k] != ")
	at_emit_c_char_literal(g_matchers_out, d_char)
	string_append(g_matchers_out, c"):\n")
	string_append(g_matchers_out, c"\t\t\t\t\tok = 0\n")
	string_append(g_matchers_out, c"\t\t\t\tk = k + 1\n")
	string_append(g_matchers_out, c"\t\t\tif (ok):\n")
	string_append(g_matchers_out, c"\t\t\t\tindex = index + 1 + depth\n")
	string_append(g_matchers_out, c"\t\t\t\treturn index - _start\n")
	string_append(g_matchers_out, c"\t\tindex = index + 1\n")
	if (is_token):
		string_append(g_matchers_out, c"\treturn 0\n")
	else:
		string_append(g_matchers_out, c"\treturn -1\n")


void at_emit_lit_prefix_check(string_builder* out, char* lit, int lit_len, char* fail_return):
	int i = 0
	while (i < lit_len):
		string_append(out, c"\tif (input[index + ")
		string_append_int(out, i)
		string_append(out, c"] != ")
		at_emit_c_char_literal(out, lit[i])
		string_append(out, c"):\n")
		string_append(out, c"\t\treturn ")
		string_append(out, fail_return)
		string_append_char(out, 10)
		i = i + 1
	string_append(out, c"\tindex = index + ")
	string_append_int(out, lit_len)
	string_append_char(out, 10)


void at_emit_nested_block_comment_function(char* fn_name, char* open, int open_len, char* close, int close_len, int is_token):
	# Depth-counted nesting for '/*' ( self | . )* '*/' shapes.
	char* fail = c"-1"
	if (is_token):
		fail = c"0"
	string_append(g_matchers_out, c"\nint ")
	string_append(g_matchers_out, fn_name)
	string_append(g_matchers_out, c"(char* input, int index):\n")
	string_append(g_matchers_out, c"\tint _start = index\n")
	at_emit_lit_prefix_check(g_matchers_out, open, open_len, fail)
	string_append(g_matchers_out, c"\tint depth = 1\n")
	string_append(g_matchers_out, c"\twhile ((depth > 0) && (input[index] != 0)):\n")
	# nested open?
	string_append(g_matchers_out, c"\t\tint is_open = 1\n")
	int i = 0
	while (i < open_len):
		string_append(g_matchers_out, c"\t\tif (input[index + ")
		string_append_int(g_matchers_out, i)
		string_append(g_matchers_out, c"] != ")
		at_emit_c_char_literal(g_matchers_out, open[i])
		string_append(g_matchers_out, c"):\n")
		string_append(g_matchers_out, c"\t\t\tis_open = 0\n")
		i = i + 1
	string_append(g_matchers_out, c"\t\tint is_close = 1\n")
	i = 0
	while (i < close_len):
		string_append(g_matchers_out, c"\t\tif (input[index + ")
		string_append_int(g_matchers_out, i)
		string_append(g_matchers_out, c"] != ")
		at_emit_c_char_literal(g_matchers_out, close[i])
		string_append(g_matchers_out, c"):\n")
		string_append(g_matchers_out, c"\t\t\tis_close = 0\n")
		i = i + 1
	string_append(g_matchers_out, c"\t\tif (is_open):\n")
	string_append(g_matchers_out, c"\t\t\tdepth = depth + 1\n")
	string_append(g_matchers_out, c"\t\t\tindex = index + ")
	string_append_int(g_matchers_out, open_len)
	string_append_char(g_matchers_out, 10)
	string_append(g_matchers_out, c"\t\telse if (is_close):\n")
	string_append(g_matchers_out, c"\t\t\tdepth = depth - 1\n")
	string_append(g_matchers_out, c"\t\t\tindex = index + ")
	string_append_int(g_matchers_out, close_len)
	string_append_char(g_matchers_out, 10)
	string_append(g_matchers_out, c"\t\telse:\n")
	string_append(g_matchers_out, c"\t\t\tindex = index + 1\n")
	string_append(g_matchers_out, c"\tif (depth != 0):\n")
	string_append(g_matchers_out, c"\t\treturn ")
	string_append(g_matchers_out, fail)
	string_append_char(g_matchers_out, 10)
	string_append(g_matchers_out, c"\treturn index - _start\n")


char* at_refuse_reason_element(at_element* e, int depth):
	if (depth > 64):
		return c"element nesting too deep"
	if ((e.suffix == '*') || (e.suffix == '+')):
		int saved = e.suffix
		e.suffix = 0
		int empty_body = at_element_can_match_empty(e)
		e.suffix = saved
		if (empty_body):
			return c"loop body can match empty (try-all divergence risk)"
	if (e.kind == 0):
		# UTF-8 / non-ASCII literals match as raw byte sequences.
		return 0
	if (e.kind == 1):
		if (e.text == 0):
			return c"charset missing text"
		# Non-ASCII charsets are rewritten (ASCII subset or UTF-8 literal
		# fold) before refuse; anything still non-ASCII here is a bug.
		if (at_charset_has_non_ascii(e.text)):
			return c"non-ASCII charset"
		return 0
	if (e.kind == 5):
		if (e.text == 0):
			# ~ ( 'a' | 'b' ) groups are folded at build time when possible;
			# anything else (nested groups, refs) is refused.
			return c"negated atom is not a charset (or singleton-literal group)"
		if (at_charset_has_non_ascii(e.text)):
			return c"non-ASCII negated charset"
		return 0
	if (e.kind == 4):
		return 0
	if (e.kind == 3):
		return at_refuse_reason_altlist(e.group_alts, depth + 1)
	if (e.kind == 2):
		# Trailing/standalone EOF in a lexer rule is an end-anchor; matching
		# length is unaffected (input[index]==0 already ends the scan).
		if (strcmp(e.text, c"EOF") == 0):
			return 0
		at_rule* frag = at_lookup_lexer_piece(e.text)
		if (frag == 0):
			return c"reference to unknown lexer/fragment name in lexer rule"
		# Use value==1 (not contains): clearing a key sets value to 0 but
		# leaves the slot occupied, so contains would stay true forever.
		if (g_frag_generating.get(frag.name, 0) == 1):
			int d = 0
			int o = 0
			int c = 0
			if (at_is_nested_delim_frag(frag, &d, &o, &c)):
				return 0
			int ol = 0
			int cl = 0
			char* os = 0
			char* cs = 0
			if (at_is_self_nested_block_comment(frag, &ol, &os, &cl, &cs)):
				return 0
			# Attempt unroll once; if it removes the cycle, re-check.
			if (at_unroll_right_recursion(frag)):
				return at_refuse_reason_altlist(frag.alts, depth + 1)
			return c"recursive fragment reference"
		g_frag_generating[frag.name] = 1
		# Unroll before approximating / refusing so regular right-recursion
		# becomes a loop the rest of the pipeline understands.
		at_unroll_right_recursion(frag)
		char* approx = at_approx_altlist_ascii(frag.alts)
		char* reason = 0
		if (approx != 0):
			reason = approx
		else:
			reason = at_refuse_reason_altlist(frag.alts, depth + 1)
		g_frag_generating[frag.name] = 0
		return reason
	return c"unknown element kind"


char* at_refuse_reason_altlist(list[at_alt*] alts, int depth):
	if (alts == 0):
		return c"missing alternatives"
	int i = 0
	while (i < alts.length):
		at_alt* alt = alts[i]
		int j = 0
		while (j < alt.elements.length):
			at_element* e = alt.elements[j]
			char* reason = at_refuse_reason_element(e, depth)
			if (reason != 0):
				return reason
			j = j + 1
		i = i + 1
	return 0


char* at_refuse_reason_rule(at_rule* rule):
	if (at_command_is_refused(rule.command)):
		string_builder* b = string_new()
		string_append(b, c"lexer command '")
		string_append(b, rule.command)
		string_append(b, c"' (mode/pushMode/popMode/more) is not supported")
		char* result = strclone(b.data)
		string_free(b)
		return result
	int d = 0
	int o = 0
	int c = 0
	if (at_is_nested_delim_frag(rule, &d, &o, &c)):
		return 0
	int ol = 0
	int cl = 0
	char* os = 0
	char* cs = 0
	if (at_is_self_nested_block_comment(rule, &ol, &os, &cl, &cs)):
		return 0
	# Regular right-/left-recursive shapes → loops before ASCII approx.
	at_unroll_right_recursion(rule)
	char* approx = at_approx_altlist_ascii(rule.alts)
	if (approx != 0):
		return approx
	return at_refuse_reason_altlist(rule.alts, 0)
