# The Unicode Bidirectional Algorithm (UAX #9, Unicode 15.0.0) in W, with
# no native dependency (issue #459). graphics/ui/bidi.w uses it whenever
# FriBidi is unavailable; any program can call it directly.
#
#   bidi_resolve      rules P2-P3, X1-X10, W1-W7, N0-N2 and I1-I2 for one
#                     paragraph: original classes and resolved levels
#   bidi_line_levels  rule L1 for one line of a resolved paragraph
#   bidi_reorder      rule L2: the visual-to-logical index map of a line
#
# Characters removed by X9 (embedding/override controls, PDF and BN) keep
# their index and take the level of the preceding character (the
# paragraph level at the start), the "retaining" convention of UAX #9
# section 5.2. Mirroring (L4) and mark reordering (L3) are left to the
# shaper. https://www.unicode.org/reports/tr9/
import lib.lib
import lib.unicode_text

const int bidi_max_depth = 125

int bidi_removed(int c):
	return (c == ut_bidi_rle) || (c == ut_bidi_lre) || (c == ut_bidi_rlo) || (c == ut_bidi_lro) || (c == ut_bidi_pdf) || (c == ut_bidi_bn)

int bidi_isolate_initiator(int c):
	return (c == ut_bidi_lri) || (c == ut_bidi_rli) || (c == ut_bidi_fsi)

# A neutral or isolate formatting character for rules N1 and N2.
int bidi_neutral(int c):
	return (c == ut_bidi_b) || (c == ut_bidi_s) || (c == ut_bidi_ws) || (c == ut_bidi_on) || bidi_isolate_initiator(c) || (c == ut_bidi_pdi)

# Rules P2-P3 from index at: 0 for L, 1 for R/AL, -1 when no strong
# character comes first. Isolated text is skipped; stop_at_pdi ends the
# scan at the PDI matching an isolate that started just before at (FSI).
int bidi_first_strong(char* classes, int at, int count, int stop_at_pdi):
	int depth = 0
	for i in range(at, count):
		int c = classes[i]
		if (bidi_isolate_initiator(c)): depth = depth + 1
		else if (c == ut_bidi_pdi):
			if (depth > 0): depth = depth - 1
			else if (stop_at_pdi): return -1
		else if (c == ut_bidi_b): return -1
		else if (depth == 0):
			if (c == ut_bidi_l): return 0
			if ((c == ut_bidi_r) || (c == ut_bidi_al)): return 1
	return -1

# Strong direction of a resolved type for N0-N2: 0 L, 1 R (EN and AN
# count as R), -1 neutral.
int bidi_strong_dir(int t):
	if (t == ut_bidi_l): return 0
	if ((t == ut_bidi_r) || (t == ut_bidi_en) || (t == ut_bidi_an)): return 1
	return -1

int bidi_dir_type(int dir):
	if (dir == 0): return ut_bidi_l
	return ut_bidi_r

# Rules X1-X8. classes are original, types receive overrides, levels the
# explicit embedding levels.
void bidi_explicit(char* classes, int count, int para, char* types, char* levels):
	char[128] stack_level
	char[128] stack_override
	char[128] stack_isolate
	int top = 0
	stack_level[0] = para
	stack_override[0] = 0
	stack_isolate[0] = 0
	int overflow_isolate = 0
	int overflow_embedding = 0
	int valid_isolate = 0
	for i in range(count):
		int c = classes[i]
		types[i] = c
		int cur = stack_level[top]
		if ((c == ut_bidi_rle) || (c == ut_bidi_lre) || (c == ut_bidi_rlo) || (c == ut_bidi_lro)):
			levels[i] = cur
			int next = (cur + 2) & (0 - 2)
			if ((c == ut_bidi_rle) || (c == ut_bidi_rlo)): next = (cur + 1) | 1
			if ((next <= bidi_max_depth) && (overflow_isolate == 0) && (overflow_embedding == 0)):
				top = top + 1
				stack_level[top] = next
				stack_override[top] = 0
				if (c == ut_bidi_rlo): stack_override[top] = ut_bidi_r
				if (c == ut_bidi_lro): stack_override[top] = ut_bidi_l
				stack_isolate[top] = 0
			else if (overflow_isolate == 0): overflow_embedding = overflow_embedding + 1
		else if (bidi_isolate_initiator(c)):
			levels[i] = cur
			if (stack_override[top] != 0): types[i] = stack_override[top]
			int rtl = c == ut_bidi_rli
			if (c == ut_bidi_fsi): rtl = bidi_first_strong(classes, i + 1, count, 1) == 1
			int next = (cur + 2) & (0 - 2)
			if (rtl): next = (cur + 1) | 1
			if ((next <= bidi_max_depth) && (overflow_isolate == 0) && (overflow_embedding == 0)):
				valid_isolate = valid_isolate + 1
				top = top + 1
				stack_level[top] = next
				stack_override[top] = 0
				stack_isolate[top] = 1
			else: overflow_isolate = overflow_isolate + 1
		else if (c == ut_bidi_pdi):
			if (overflow_isolate > 0): overflow_isolate = overflow_isolate - 1
			else if (valid_isolate > 0):
				overflow_embedding = 0
				while (stack_isolate[top] == 0): top = top - 1
				top = top - 1
				valid_isolate = valid_isolate - 1
			levels[i] = stack_level[top]
			if (stack_override[top] != 0): types[i] = stack_override[top]
		else if (c == ut_bidi_pdf):
			if (overflow_isolate == 0):
				if (overflow_embedding > 0): overflow_embedding = overflow_embedding - 1
				else if ((stack_isolate[top] == 0) && (top >= 1)): top = top - 1
			levels[i] = stack_level[top]
		else if (c == ut_bidi_b): levels[i] = para
		else:
			levels[i] = cur
			if ((c != ut_bidi_bn) && (stack_override[top] != 0)): types[i] = stack_override[top]

# BD9: match[i] is the matching PDI of isolate initiator i, or -1; a PDI
# matched by an initiator gets -2.
void bidi_match_isolates(char* classes, int count, int32* match):
	int32* stack = cast(int32*, malloc((count + 1) * 4))
	int depth = 0
	for i in range(count):
		match[i] = -1
		int c = classes[i]
		if (bidi_isolate_initiator(c)):
			stack[depth] = i
			depth = depth + 1
		else if ((c == ut_bidi_pdi) && (depth > 0)):
			depth = depth - 1
			match[stack[depth]] = i
			match[i] = -2
		else if (c == ut_bidi_b): depth = 0
	free(stack)

# Rules W1-W7 on one isolating run sequence's types.
void bidi_weak(char* t, int n, int sos):
	for k in range(n):
		if (t[k] == ut_bidi_nsm):
			if (k == 0): t[k] = sos
			else if (bidi_isolate_initiator(t[k - 1]) || (t[k - 1] == ut_bidi_pdi)): t[k] = ut_bidi_on
			else: t[k] = t[k - 1]
	int strong = sos
	for k in range(n):
		int c = t[k]
		if ((c == ut_bidi_r) || (c == ut_bidi_l) || (c == ut_bidi_al)): strong = c
		else if ((c == ut_bidi_en) && (strong == ut_bidi_al)): t[k] = ut_bidi_an
	for k in range(n):
		if (t[k] == ut_bidi_al): t[k] = ut_bidi_r
	for k in range(1, n - 1):
		int left = t[k - 1]
		int right = t[k + 1]
		if ((t[k] == ut_bidi_es) && (left == ut_bidi_en) && (right == ut_bidi_en)): t[k] = ut_bidi_en
		else if ((t[k] == ut_bidi_cs) && (left == ut_bidi_en) && (right == ut_bidi_en)): t[k] = ut_bidi_en
		else if ((t[k] == ut_bidi_cs) && (left == ut_bidi_an) && (right == ut_bidi_an)): t[k] = ut_bidi_an
	int k = 0
	while (k < n):
		if (t[k] != ut_bidi_et):
			k = k + 1
			continue
		int end = k
		while ((end < n) && (t[end] == ut_bidi_et)): end = end + 1
		int adjacent = ((k > 0) && (t[k - 1] == ut_bidi_en)) || ((end < n) && (t[end] == ut_bidi_en))
		if (adjacent):
			for j in range(k, end): t[j] = ut_bidi_en
		k = end
	for j in range(n):
		if ((t[j] == ut_bidi_es) || (t[j] == ut_bidi_et) || (t[j] == ut_bidi_cs)): t[j] = ut_bidi_on
	strong = sos
	for j in range(n):
		int c = t[j]
		if ((c == ut_bidi_r) || (c == ut_bidi_l)): strong = c
		else if ((c == ut_bidi_en) && (strong == ut_bidi_l)): t[j] = ut_bidi_l

# Rule N0 on one isolating run sequence. seq maps positions to text
# indices; cps are the paragraph's codepoints and classes its originals.
void bidi_brackets(char* t, int n, int32* seq, int32* cps, char* classes, int sos, int level):
	int32[63] stack_close
	int32[63] stack_pos
	int depth = 0
	int32* pair_open = cast(int32*, malloc(n * 4 + 4))
	int32* pair_close = cast(int32*, malloc(n * 4 + 4))
	int pairs = 0
	for k in range(n):
		if (t[k] != ut_bidi_on): continue
		int partner = 0
		int kind = ut_bracket(cps[seq[k]], &partner)
		if (kind == 1):
			if (depth == 63): break
			stack_close[depth] = ut_bracket_canonical(partner)
			stack_pos[depth] = k
			depth = depth + 1
		else if (kind == 2):
			int want = ut_bracket_canonical(cps[seq[k]])
			int s = depth - 1
			while ((s >= 0) && (stack_close[s] != want)): s = s - 1
			if (s >= 0):
				# Keep the list sorted by opener position.
				int at = pairs
				while ((at > 0) && (pair_open[at - 1] > stack_pos[s])):
					pair_open[at] = pair_open[at - 1]
					pair_close[at] = pair_close[at - 1]
					at = at - 1
				pair_open[at] = stack_pos[s]
				pair_close[at] = k
				pairs = pairs + 1
				depth = s
	int embedding = level & 1
	for p in range(pairs):
		int open = pair_open[p]
		int close = pair_close[p]
		int found_e = 0
		int found_opposite = 0
		for k in range(open + 1, close):
			int d = bidi_strong_dir(t[k])
			if (d == embedding): found_e = 1
			else if (d >= 0): found_opposite = 1
		int dir = -1
		if (found_e): dir = embedding
		else if (found_opposite):
			int context = sos == ut_bidi_r
			int back = open - 1
			while (back >= 0):
				int d = bidi_strong_dir(t[back])
				if (d >= 0):
					context = d
					break
				back = back - 1
			if (context != embedding): dir = context
			else: dir = embedding
		if (dir < 0): continue
		int type = bidi_dir_type(dir)
		t[open] = type
		t[close] = type
		int mark = open + 1
		while ((mark < n) && (classes[seq[mark]] == ut_bidi_nsm)):
			t[mark] = type
			mark = mark + 1
		mark = close + 1
		while ((mark < n) && (classes[seq[mark]] == ut_bidi_nsm)):
			t[mark] = type
			mark = mark + 1
	free(pair_open)
	free(pair_close)

# Rules N1-N2.
void bidi_neutrals(char* t, int n, int sos, int eos, int level):
	int k = 0
	while (k < n):
		if (bidi_neutral(t[k]) == 0):
			k = k + 1
			continue
		int end = k
		while ((end < n) && bidi_neutral(t[end])): end = end + 1
		int left = 0
		if (sos == ut_bidi_r): left = 1
		if (k > 0): left = bidi_strong_dir(t[k - 1])
		int right = 0
		if (eos == ut_bidi_r): right = 1
		if (end < n): right = bidi_strong_dir(t[end])
		int dir = level & 1
		if ((left == right) && (left >= 0)): dir = left
		for j in range(k, end): t[j] = bidi_dir_type(dir)
		k = end

# Resolve one paragraph of count codepoints. base is 0 (LTR), 1 (RTL) or
# -1 (first strong character, else LTR). classes and levels receive count
# bytes: each character's original Bidi_Class and its resolved embedding
# level before line rule L1. Returns the paragraph embedding level.
int bidi_resolve(int32* cps, int count, int base, char* classes, char* levels):
	for i in range(count): classes[i] = ut_bidi_class(cps[i])
	int para = base
	if ((para != 0) && (para != 1)):
		para = bidi_first_strong(classes, 0, count, 0)
		if (para < 0): para = 0
	if (count == 0): return para
	char* types = cast(char*, malloc(count))
	int32* match = cast(int32*, malloc(count * 4))
	bidi_match_isolates(classes, count, match)
	bidi_explicit(classes, count, para, types, levels)
	# X9-X10: level runs over the characters X9 keeps, chained through
	# matched isolates into isolating run sequences.
	# Sequences read the explicit levels; I1-I2 write resolved ones.
	char* embed = cast(char*, malloc(count))
	for i in range(count): embed[i] = levels[i]
	int32* keep = cast(int32*, malloc(count * 4))
	int kept = 0
	for i in range(count):
		if (bidi_removed(classes[i]) == 0):
			keep[kept] = i
			kept = kept + 1
	int32* run_start = cast(int32*, malloc(kept * 4 + 4))
	int32* run_end = cast(int32*, malloc(kept * 4 + 4))
	int32* run_at = cast(int32*, malloc(count * 4))
	int runs = 0
	for k in range(kept):
		if ((k == 0) || (embed[keep[k]] != embed[keep[k - 1]])):
			run_start[runs] = k
			runs = runs + 1
		run_end[runs - 1] = k + 1
		run_at[keep[k]] = runs - 1
	char* used = cast(char*, malloc(runs + 1))
	for r in range(runs): used[r] = 0
	int32* seq = cast(int32*, malloc(kept * 4 + 4))
	char* t = cast(char*, malloc(kept + 1))
	for r in range(runs):
		if (used[r]): continue
		int n = 0
		int run = r
		while (run >= 0):
			used[run] = 1
			for k in range(run_start[run], run_end[run]):
				seq[n] = keep[k]
				n = n + 1
			int tail = seq[n - 1]
			run = -1
			if (bidi_isolate_initiator(classes[tail]) && (match[tail] >= 0)):
				int pdi = match[tail]
				if (bidi_removed(classes[pdi]) == 0):
					int next = run_at[pdi]
					if ((used[next] == 0) && (keep[run_start[next]] == pdi)): run = next
		int level = embed[seq[0]]
		int first_k = run_start[r]
		int before = para
		if (first_k > 0): before = embed[keep[first_k - 1]]
		int last = seq[n - 1]
		int after = para
		if (!bidi_isolate_initiator(classes[last])):
			int last_k = run_end[run_at[last]] - 1
			if (last_k + 1 < kept): after = embed[keep[last_k + 1]]
		int sos = ut_bidi_l
		if (max(level, before) & 1): sos = ut_bidi_r
		int eos = ut_bidi_l
		if (max(level, after) & 1): eos = ut_bidi_r
		for k in range(n): t[k] = types[seq[k]]
		bidi_weak(t, n, sos)
		bidi_brackets(t, n, seq, cps, classes, sos, level)
		bidi_neutrals(t, n, sos, eos, level)
		for k in range(n):
			int i = seq[k]
			int c = t[k]
			if ((level & 1) == 0):
				if (c == ut_bidi_r): levels[i] = level + 1
				else if ((c == ut_bidi_an) || (c == ut_bidi_en)): levels[i] = level + 2
			else if ((c == ut_bidi_l) || (c == ut_bidi_an) || (c == ut_bidi_en)): levels[i] = level + 1
	int previous = para
	for i in range(count):
		if (bidi_removed(classes[i])): levels[i] = previous
		else: previous = levels[i]
	free(types)
	free(embed)
	free(match)
	free(keep)
	free(run_start)
	free(run_end)
	free(run_at)
	free(used)
	free(seq)
	free(t)
	return para

# Whitespace for rule L1: white space, isolate controls and X9-removed
# characters.
int bidi_line_space(int c):
	return (c == ut_bidi_ws) || bidi_isolate_initiator(c) || (c == ut_bidi_pdi) || bidi_removed(c)

# Rule L1 on one line: levels (the line's copy of the resolved levels) and
# classes (original classes) both hold the line's count characters.
void bidi_line_levels(char* classes, char* levels, int count, int para):
	int trailing = 1
	int i = count - 1
	while (i >= 0):
		int c = classes[i]
		if ((c == ut_bidi_s) || (c == ut_bidi_b)):
			levels[i] = para
			trailing = 1
		else if (bidi_line_space(c)):
			if (trailing): levels[i] = para
		else: trailing = 0
		i = i - 1

# Rule L2: visual_to_logical[v] is the line index shown at visual
# position v (leftmost first).
void bidi_reorder(char* levels, int count, int32* visual_to_logical):
	int highest = 0
	int lowest_odd = 127
	for i in range(count):
		visual_to_logical[i] = i
		int value = levels[i]
		if (value > highest): highest = value
		if ((value & 1) && (value < lowest_odd)): lowest_odd = value
	int level = highest
	while ((level >= lowest_odd) && (level > 0)):
		int i = 0
		while (i < count):
			if (levels[visual_to_logical[i]] < level):
				i = i + 1
				continue
			int end = i
			while ((end < count) && (levels[visual_to_logical[end]] >= level)): end = end + 1
			int lo = i
			int hi = end - 1
			while (lo < hi):
				int swap = visual_to_logical[lo]
				visual_to_logical[lo] = visual_to_logical[hi]
				visual_to_logical[hi] = swap
				lo = lo + 1
				hi = hi - 1
			i = end
		level = level - 1
