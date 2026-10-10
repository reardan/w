/*
Induction-variable pointers for array walks (unit O7, wave B's B2 of
docs/projects/codegen_gap_plan.md §5.2): in an innermost loop, a
subscript 'a[i * n + k]' whose base and whose other names the loop never
assigns becomes a pointer register that holds '&a[i * n + k]' for the
loop's whole extent. The register is set once before the loop's entry
jump, every subscript of that shape in the loop is the operand '[p]',
and every statement that steps an induction variable ('k = k + 1',
'k += c', 'k++', a range loop's own increment) is followed by
'add p, stride' -- 'lea p,[p+R*8]' when the stride is a register-resident
name times a scale. The invariant "p == &a[index]" holds at every point
of the loop, so continue, break, return and a hidden call (which
recomputes p after it returns, ivopt_call_reload) need nothing else.

The compiler is single-pass: the loop's body is not a tree when its
head is emitted. The facts are therefore read from the source text, like
the register pre-scan's (compiler/regalloc_scan.w): when the pre-scan
closes an innermost loop it hands the loop's bytes to ivopt_scan_loop,
which lexes them and records

- the names the loop writes in any way (an assignment, a compound
  assignment, '++'/'--', '&name', a multi-assignment line) or declares;
- the induction variables: names whose only writes are whole-line
  'X = X + d', 'X = X - d', 'X += d', 'X -= d', 'X++', '++X' (d an
  integer literal or a name the loop never writes), keyed by the
  statement's file offset; a range loop's variable when the body never
  writes it;
- the candidate subscripts: 'B[index]' where B is never written, the
  index uses only integer literals, '+', '-', '*', parentheses and names
  that are either never written or induction variables, and the index is
  linear in each induction variable with a coefficient free of them.
  An index that addressing modes already fold for free ('a[k]',
  'a[k + 1]', 'a[n]') is left alone.

Anything the lexer does not follow (a nested loop, braces, ';', an
f-string, a nested function, goto, defer, yield, asm) declines the loop.
At the loop's head (regalloc_loop_enter) the names are resolved:
everything must be a word-sized int local or argument (the base a
pointer) that the pre-scan saw declared at most once and never
address-taken or called (rs_excluded), and the loop must be one that
owns caller-saved registers (call-free, no goto/defer, x64). A
candidate takes a free loop register or is dropped. At emission a
subscript is rewritten only when it is one the analysis recorded (by
its base name's file offset) and its base is the very symbol record
resolved at the head; a name of its index resolving to any other record
is an internal error. Both front ends ask at the same token -- the AST
emitter at an 'i' node (code_generator/expression_ast.w), the streaming
grammar before the primary (grammar/postfix_expr.w, which consumes the
whole subscript) -- so they emit byte-identical images; a subscript
that is not rewritten is emitted as before.

--no-ivopts (and -O0) turns the unit off; tests/regalloc_diff_test.w
compares every test program's behaviour with and without it, and
tests/ivopt_test.w exercises the shapes.
*/

# --- analysis tables (per function; ivopt_reset) ---------------------------
list[char*] iv_names       # interned identifier text
# expression nodes: kind 1 a name (a = name index), 2 an integer (a =
# value), '+', '-', '*' (a, b = children)
list[int] iv_nk
list[int] iv_na
list[int] iv_nb
# one record per analysed loop
list[int] iv_loop_offset
list[int] iv_loop_cand_first
list[int] iv_loop_cand_end
list[int] iv_loop_upd_first
list[int] iv_loop_upd_end
list[int] iv_loop_for_var  # a range loop's variable (name index), -1 for a while
list[int] iv_loop_cover_first
list[int] iv_loop_cover_end
list[int] iv_loop_occ_first
list[int] iv_loop_occ_end
# every candidate subscript in the source: the file offsets of its base
# name and of its ']', and the candidate it is (both front ends match a
# subscript by its base's offset, so they rewrite the same ones)
list[int] iv_occ_off
list[int] iv_occ_close
list[int] iv_occ_cand
# candidate subscripts
list[int] iv_cand_base     # name index
list[int] iv_cand_index    # node
list[int] iv_cand_coef_first
list[int] iv_cand_coef_end
list[int] iv_coef_name     # induction variable (name index)
list[int] iv_coef_tree     # its coefficient (node)
# induction steps
list[int] iv_upd_offset    # file offset of the statement
list[int] iv_upd_name
list[int] iv_upd_sign      # 1 or -1
list[int] iv_upd_delta     # node: an integer or a name
# names every occurrence of which in the loop is inside a candidate
# subscript: the loop's register pass need not load them
list[int] iv_cover_name

# --stats
int ivopt_loops
int ivopt_pointers
int ivopt_steps
int ivopt_remats

# --- the lexer's tokens ------------------------------------------------------
int iv_text_start          # the file offset of the text being analysed
list[int] iv_tk_kind       # 1 identifier, 2 integer, 3 other literal, 4 operator
list[int] iv_tk_off        # byte offset in the text
list[int] iv_tk_val        # identifier: name index; integer: value; operator: code
list[int] iv_tk_tabs       # leading tabs of its line when first on it, else -1
list[int] iv_tk_lstart     # 1: the first token of a logical line
list[int] iv_tk_step       # 1: the stepped name of a whole-line induction step
# per-analysis facts, indexed by name index
list[int] iv_la_written
list[int] iv_la_declared
list[int] iv_la_upd
list[int] iv_la_class      # 1 invariant, 2 induction variable, 3 neither
list[int] iv_la_occ
list[int] iv_la_inside
list[int] iv_la_inside_base   # ... of those, as a subscript's base

# --- the active loop (emission) ----------------------------------------------
int iv_active
int iv_active_loop
int iv_depth
list[int] iv_sym           # name index -> symbol record (-1 unresolved, -2 refused)
list[int] iv_act_cand      # candidate per pointer register
list[int] iv_act_reg
list[int] iv_act_es        # element size
list[int] iv_act_base_sym
list[int] iv_act_elem      # element type
int iv_steps_fired         # the active loop's steps emitted (each statement once)
int iv_range_fired


void iv_tables_ensure():
	if (iv_names != 0): return;
	iv_names = new list[char*]
	iv_nk = new list[int]
	iv_na = new list[int]
	iv_nb = new list[int]
	iv_loop_offset = new list[int]
	iv_loop_cand_first = new list[int]
	iv_loop_cand_end = new list[int]
	iv_loop_upd_first = new list[int]
	iv_loop_upd_end = new list[int]
	iv_loop_for_var = new list[int]
	iv_loop_cover_first = new list[int]
	iv_loop_cover_end = new list[int]
	iv_loop_occ_first = new list[int]
	iv_loop_occ_end = new list[int]
	iv_occ_off = new list[int]
	iv_occ_close = new list[int]
	iv_occ_cand = new list[int]
	iv_cand_base = new list[int]
	iv_cand_index = new list[int]
	iv_cand_coef_first = new list[int]
	iv_cand_coef_end = new list[int]
	iv_coef_name = new list[int]
	iv_coef_tree = new list[int]
	iv_upd_offset = new list[int]
	iv_upd_name = new list[int]
	iv_upd_sign = new list[int]
	iv_upd_delta = new list[int]
	iv_cover_name = new list[int]
	iv_tk_kind = new list[int]
	iv_tk_off = new list[int]
	iv_tk_val = new list[int]
	iv_tk_tabs = new list[int]
	iv_tk_lstart = new list[int]
	iv_tk_step = new list[int]
	iv_la_written = new list[int]
	iv_la_declared = new list[int]
	iv_la_upd = new list[int]
	iv_la_class = new list[int]
	iv_la_occ = new list[int]
	iv_la_inside = new list[int]
	iv_la_inside_base = new list[int]
	iv_sym = new list[int]
	iv_act_cand = new list[int]
	iv_act_reg = new list[int]
	iv_act_es = new list[int]
	iv_act_base_sym = new list[int]
	iv_act_elem = new list[int]


# No loop is being maintained (function end, REPL rollback).
void ivopt_active_reset():
	iv_active = 0
	ivopt_live = 0
	if (iv_act_reg == 0): return;
	iv_act_cand.clear()
	iv_act_reg.clear()
	iv_act_es.clear()
	iv_act_base_sym.clear()
	iv_act_elem.clear()


# Drop the function's analysis (the pre-scan's tables were cleared).
void ivopt_reset():
	iv_tables_ensure()
	ivopt_active_reset()
	for i in range(iv_names.length): free(iv_names[i])
	iv_names.clear()
	iv_nk.clear()
	iv_na.clear()
	iv_nb.clear()
	iv_loop_offset.clear()
	iv_loop_cand_first.clear()
	iv_loop_cand_end.clear()
	iv_loop_upd_first.clear()
	iv_loop_upd_end.clear()
	iv_loop_for_var.clear()
	iv_loop_cover_first.clear()
	iv_loop_cover_end.clear()
	iv_loop_occ_first.clear()
	iv_loop_occ_end.clear()
	iv_occ_off.clear()
	iv_occ_close.clear()
	iv_occ_cand.clear()
	iv_cand_base.clear()
	iv_cand_index.clear()
	iv_cand_coef_first.clear()
	iv_cand_coef_end.clear()
	iv_coef_name.clear()
	iv_coef_tree.clear()
	iv_upd_offset.clear()
	iv_upd_name.clear()
	iv_upd_sign.clear()
	iv_upd_delta.clear()
	iv_cover_name.clear()


int iv_node(int kind, int a, int b):
	iv_nk.push(kind)
	iv_na.push(a)
	iv_nb.push(b)
	return iv_nk.length - 1


# The name index of text[off..off+len), interned.
int iv_intern(char* text, int off, int len):
	for i in range(iv_names.length):
		char* s = iv_names[i]
		int j = 0
		while ((j < len) && (s[j] == text[off + j])): j = j + 1
		if ((j == len) && (s[len] == 0)): return i
	char* copy = cast(char*, malloc(len + 1))
	for j in range(len): copy[j] = text[off + j]
	copy[len] = 0
	iv_names.push(copy)
	return iv_names.length - 1


# --- the lexer -----------------------------------------------------------------
int iv_ident_start(int c):
	if ((c >= 'a') && (c <= 'z')): return 1
	if ((c >= 'A') && (c <= 'Z')): return 1
	return (c == '_') || (c >= 128)


int iv_ident_part(int c):
	if (iv_ident_start(c)): return 1
	return (c >= '0') && (c <= '9')


int iv_op2(int a, int b):
	return (a << 8) | b


# The operator at text[i] (its code, its length in iv_lex_len), 0 for a
# byte the analysis does not follow.
int iv_lex_len
int iv_lex_op(char* text, int i):
	int a = text[i] & 255
	int b = text[i + 1] & 255
	int c = 0
	if (b != 0): c = text[i + 2] & 255
	if (((a == '<') || (a == '>')) && (b == a) && (c == '=')):
		iv_lex_len = 3
		return (iv_op2(a, b) << 8) | c
	iv_lex_len = 2
	if ((b == '=') && ((a == '=') || (a == '!') || (a == '<') || (a == '>') || (a == '+') || (a == '-') || (a == '*') || (a == '/') || (a == '%') || (a == '&') || (a == '|') || (a == '^') || (a == ':'))): return iv_op2(a, b)
	if ((a == b) && ((a == '+') || (a == '-') || (a == '&') || (a == '|') || (a == '<') || (a == '>'))): return iv_op2(a, b)
	if ((a == '-') && (b == '>')): return iv_op2(a, b)
	iv_lex_len = 1
	if ((a == '+') || (a == '-') || (a == '*') || (a == '/') || (a == '%') || (a == '&') || (a == '|') || (a == '^')): return a
	if ((a == '~') || (a == '!') || (a == '<') || (a == '>') || (a == '=') || (a == '?') || (a == '.')): return a
	if ((a == ',') || (a == ':') || (a == '(') || (a == ')') || (a == '[') || (a == ']')): return a
	return 0


void iv_tok(int kind, int off, int val, int tabs, int lstart):
	iv_tk_kind.push(kind)
	iv_tk_off.push(off)
	iv_tk_val.push(val)
	iv_tk_tabs.push(tabs)
	iv_tk_lstart.push(lstart)
	iv_tk_step.push(0)


# Tokenize text[0..n): 1 when every byte was understood.
int iv_lex(char* text, int n):
	iv_tk_kind.clear()
	iv_tk_off.clear()
	iv_tk_val.clear()
	iv_tk_tabs.clear()
	iv_tk_lstart.clear()
	iv_tk_step.clear()
	int i = 0
	int tabs = 0         # leading tabs of the current physical line
	int line_first = 1   # no token on this physical line yet
	int depth = 0        # open '(' and '['
	int logical = 1      # the next token starts a logical line
	while (i < n):
		int c = text[i] & 255
		if (c == 10):
			i = i + 1
			tabs = 0
			line_first = 1
			if (depth == 0): logical = 1
			while ((i < n) && (text[i] == 9)):
				tabs = tabs + 1
				i = i + 1
			continue
		if ((c == ' ') || (c == 9) || (c == 13)):
			i = i + 1
			continue
		if (c == '#'):
			while ((i < n) && (text[i] != 10)): i = i + 1
			continue
		if ((c == '/') && (text[i + 1] == '*')):
			i = i + 2
			while ((i < n) && ((text[i] != '*') || (text[i + 1] != '/'))): i = i + 1
			if (i >= n): return 0
			i = i + 2
			continue
		int ltabs = -1
		if (line_first): ltabs = tabs
		int start = logical
		line_first = 0
		logical = 0
		if ((c == '"') || (c == 39) || (((c == 'c') || (c == 's')) && (text[i + 1] == '"'))):
			int quote = c
			int off = i
			if (c != 39):
				if (c != '"'): i = i + 1
				quote = '"'
			i = i + 1
			while ((i < n) && ((text[i] & 255) != quote)):
				if (text[i] == 10): return 0
				if (text[i] == 92): i = i + 1
				i = i + 1
			if (i >= n): return 0
			i = i + 1
			iv_tok(3, off, 0, ltabs, start)
			continue
		if (iv_ident_start(c)):
			int off = i
			while ((i < n) && iv_ident_part(text[i] & 255)): i = i + 1
			# an f-string or any other prefixed literal: not followed
			if (text[i] == '"'): return 0
			iv_tok(1, off, iv_intern(text, off, i - off), ltabs, start)
			continue
		if ((c >= '0') && (c <= '9')):
			int off = i
			int value = 0
			int ok = 1
			if ((c == '0') && ((text[i + 1] == 'x') || (text[i + 1] == 'X'))):
				i = i + 2
				int digits = 0
				while ((i < n) && iv_ident_part(text[i] & 255)):
					int d = text[i] & 255
					int v = -1
					if ((d >= '0') && (d <= '9')): v = d - '0'
					elif ((d >= 'a') && (d <= 'f')): v = d - 'a' + 10
					elif ((d >= 'A') && (d <= 'F')): v = d - 'A' + 10
					if ((v < 0) || (digits >= 6)): ok = 0
					else: value = (value << 4) | v
					digits = digits + 1
					i = i + 1
				if (digits == 0): ok = 0
			else:
				while ((i < n) && iv_ident_part(text[i] & 255)):
					int d = text[i] & 255
					if ((d < '0') || (d > '9') || (value > 1000000)): ok = 0
					else: value = value * 10 + (d - '0')
					i = i + 1
			# a float or a suffixed literal is an operand of another kind
			if (text[i] == '.'):
				ok = 0
				i = i + 1
				while ((i < n) && iv_ident_part(text[i] & 255)): i = i + 1
			if (ok): iv_tok(2, off, value, ltabs, start)
			else: iv_tok(3, off, 0, ltabs, start)
			continue
		int code = iv_lex_op(text, i)
		if (code == 0): return 0
		if ((code == '(') || (code == '[')): depth = depth + 1
		if ((code == ')') || (code == ']')):
			if (depth == 0): return 0
			depth = depth - 1
		iv_tok(4, i, code, ltabs, start)
		i = i + iv_lex_len
	return depth == 0


# --- token classes ---------------------------------------------------------------
int iv_is_op(int t, int code):
	if ((t < 0) || (t >= iv_tk_kind.length)): return 0
	return (iv_tk_kind[t] == 4) && (iv_tk_val[t] == code)


int iv_name_is(int t, char* word):
	if ((t < 0) || (t >= iv_tk_kind.length)): return 0
	if (iv_tk_kind[t] != 1): return 0
	return strcmp(iv_names[iv_tk_val[t]], word) == 0


# 2: a keyword the analysis declines the loop on; 1: a keyword that is
# not a variable; 0: a name.
int iv_keyword_kind(char* s):
	if ((strcmp(s, c"while") == 0) || (strcmp(s, c"for") == 0) || (strcmp(s, c"goto") == 0) || (strcmp(s, c"defer") == 0)): return 2
	if ((strcmp(s, c"yield") == 0) || (strcmp(s, c"asm") == 0) || (strcmp(s, c"raw_asm") == 0) || (strcmp(s, c"fn") == 0)): return 2
	if ((strcmp(s, c"lambda") == 0) || (strcmp(s, c"def") == 0) || (strcmp(s, c"struct") == 0) || (strcmp(s, c"union") == 0)): return 2
	if ((strcmp(s, c"enum") == 0) || (strcmp(s, c"import") == 0) || (strcmp(s, c"extern") == 0) || (strcmp(s, c"launch") == 0)): return 2
	if ((strcmp(s, c"gpu") == 0) || (strcmp(s, c"kernel") == 0) || (strcmp(s, c"type") == 0) || (strcmp(s, c"generator") == 0)): return 2
	if ((strcmp(s, c"if") == 0) || (strcmp(s, c"elif") == 0) || (strcmp(s, c"else") == 0) || (strcmp(s, c"in") == 0)): return 1
	if ((strcmp(s, c"return") == 0) || (strcmp(s, c"break") == 0) || (strcmp(s, c"continue") == 0) || (strcmp(s, c"pass") == 0)): return 1
	if ((strcmp(s, c"not") == 0) || (strcmp(s, c"and") == 0) || (strcmp(s, c"or") == 0) || (strcmp(s, c"switch") == 0)): return 1
	if ((strcmp(s, c"case") == 0) || (strcmp(s, c"default") == 0) || (strcmp(s, c"cast") == 0) || (strcmp(s, c"sizeof") == 0)): return 1
	if ((strcmp(s, c"true") == 0) || (strcmp(s, c"false") == 0) || (strcmp(s, c"null") == 0) || (strcmp(s, c"new") == 0)): return 1
	if ((strcmp(s, c"debugger") == 0) || (strcmp(s, c"print") == 0) || (strcmp(s, c"println") == 0) || (strcmp(s, c"it") == 0)): return 1
	return 0


int iv_tok_keyword(int t):
	if (iv_tk_kind[t] != 1): return 0
	return iv_keyword_kind(iv_names[iv_tk_val[t]])


# A token after which an operator is binary: an operand's end.
int iv_operand_end(int t):
	if (t < 0): return 0
	int k = iv_tk_kind[t]
	if ((k == 2) || (k == 3)): return 1
	if (k == 1): return iv_tok_keyword(t) == 0
	return iv_is_op(t, ')') || iv_is_op(t, ']')


int iv_assign_op(int t):
	if ((t < 0) || (t >= iv_tk_kind.length) || (iv_tk_kind[t] != 4)): return 0
	int v = iv_tk_val[t]
	if (v == '='): return 1
	if (v == iv_op2(':', '=')): return 1
	if ((v == iv_op2('+', '=')) || (v == iv_op2('-', '=')) || (v == iv_op2('*', '=')) || (v == iv_op2('/', '='))): return 1
	if ((v == iv_op2('%', '=')) || (v == iv_op2('&', '=')) || (v == iv_op2('|', '=')) || (v == iv_op2('^', '='))): return 1
	return v > 0xffff   # '<<=' '>>='


int iv_incdec(int t):
	return iv_is_op(t, iv_op2('+', '+')) || iv_is_op(t, iv_op2('-', '-'))


# A variable reference: a name that is not a keyword and not a field.
int iv_is_var(int t):
	if (iv_tk_kind[t] != 1): return 0
	if (iv_tok_keyword(t) != 0): return 0
	return iv_is_op(t - 1, '.') == 0


void iv_la_size():
	int n = iv_names.length
	iv_la_written.clear()
	iv_la_declared.clear()
	iv_la_upd.clear()
	iv_la_class.clear()
	iv_la_occ.clear()
	iv_la_inside.clear()
	iv_la_inside_base.clear()
	for i in range(n):
		iv_la_written.push(0)
		iv_la_declared.push(0)
		iv_la_upd.push(0)
		iv_la_class.push(0)
		iv_la_occ.push(0)
		iv_la_inside.push(0)
		iv_la_inside_base.push(0)


# --- the index parser --------------------------------------------------------------
int iv_ps_pos
int iv_ps_end
int iv_ps_fail

int iv_parse_expr();

int iv_parse_factor():
	if (iv_ps_pos >= iv_ps_end):
		iv_ps_fail = 1
		return -1
	int t = iv_ps_pos
	if (iv_is_op(t, '(')):
		iv_ps_pos = iv_ps_pos + 1
		int inner = iv_parse_expr()
		if ((iv_ps_fail == 0) && iv_is_op(iv_ps_pos, ')') && (iv_ps_pos < iv_ps_end)):
			iv_ps_pos = iv_ps_pos + 1
			return inner
		iv_ps_fail = 1
		return -1
	iv_ps_pos = iv_ps_pos + 1
	if (iv_tk_kind[t] == 2): return iv_node(2, iv_tk_val[t], 0)
	if ((iv_tk_kind[t] == 1) && iv_is_var(t)): return iv_node(1, iv_tk_val[t], 0)
	iv_ps_fail = 1
	return -1


int iv_parse_term():
	int left = iv_parse_factor()
	while ((iv_ps_fail == 0) && (iv_ps_pos < iv_ps_end) && iv_is_op(iv_ps_pos, '*')):
		iv_ps_pos = iv_ps_pos + 1
		int right = iv_parse_factor()
		left = iv_node('*', left, right)
	return left


int iv_parse_expr():
	int left = iv_parse_term()
	while ((iv_ps_fail == 0) && (iv_ps_pos < iv_ps_end) && (iv_is_op(iv_ps_pos, '+') || iv_is_op(iv_ps_pos, '-'))):
		int op = iv_tk_val[iv_ps_pos]
		iv_ps_pos = iv_ps_pos + 1
		int right = iv_parse_term()
		left = iv_node(op, left, right)
	return left


# Does the tree name an induction variable of the loop being analysed.
int iv_has_iv(int n):
	int k = iv_nk[n]
	if (k == 1): return iv_la_class[iv_na[n]] == 2
	if (k == 2): return 0
	return iv_has_iv(iv_na[n]) || iv_has_iv(iv_nb[n])


# Every name of the tree is an invariant or an induction variable.
int iv_names_ok(int n):
	int k = iv_nk[n]
	if (k == 1):
		int c = iv_la_class[iv_na[n]]
		return (c == 1) || (c == 2)
	if (k == 2): return 1
	return iv_names_ok(iv_na[n]) && iv_names_ok(iv_nb[n])


int iv_is_one(int n):
	return (iv_nk[n] == 2) && (iv_na[n] == 1)


# d(tree)/d(x): a node, -1 for zero, -2 when not linear.
int iv_deriv(int n, int x):
	int k = iv_nk[n]
	if (k == 1):
		if (iv_na[n] == x): return iv_node(2, 1, 0)
		return -1
	if (k == 2): return -1
	int dl = iv_deriv(iv_na[n], x)
	if (dl == -2): return -2
	int dr = iv_deriv(iv_nb[n], x)
	if (dr == -2): return -2
	if ((dl == -1) && (dr == -1)): return -1
	if (k == '*'):
		if ((dl != -1) && (dr != -1)): return -2
		# (x * c)' = c, not 1 * c
		if (dl != -1):
			if (iv_is_one(dl)): return iv_nb[n]
			return iv_node('*', dl, iv_nb[n])
		if (iv_is_one(dr)): return iv_na[n]
		return iv_node('*', iv_na[n], dr)
	if (dr == -1): return dl
	if (dl == -1):
		if (k == '+'): return dr
		return iv_node('-', iv_node(2, 0, 0), dr)
	return iv_node(k, dl, dr)


# An index the addressing modes fold already: one token, or an
# induction variable plus or minus a literal.
int iv_trivial_index(int n):
	int k = iv_nk[n]
	if ((k == 1) || (k == 2)): return 1
	if ((k != '+') && (k != '-')): return 0
	int l = iv_na[n]
	int r = iv_nb[n]
	if ((iv_nk[l] == 1) && (iv_nk[r] == 2)): return 1
	return (k == '+') && (iv_nk[l] == 2) && (iv_nk[r] == 1)


# Two trees of the same shape over the same names and values.
int iv_same_tree(int a, int b):
	if (iv_nk[a] != iv_nk[b]): return 0
	int k = iv_nk[a]
	if ((k == 1) || (k == 2)): return iv_na[a] == iv_na[b]
	return iv_same_tree(iv_na[a], iv_na[b]) && iv_same_tree(iv_nb[a], iv_nb[b])


# --- the analysis -----------------------------------------------------------------
# The whole-line induction steps: 'X = X + d', 'X = X - d', 'X += d',
# 'X -= d', 'X++', 'X--', '++X', '--X' as the logical line [s, e).
# Records the step and returns the token of X (-1: not a step).
int iv_step_line(int s, int e):
	int x = -1
	int sign = 1
	int delta = -1
	int n = e - s
	if ((n == 5) && iv_is_var(s) && iv_is_op(s + 1, '=') && iv_is_var(s + 2) && (iv_tk_val[s + 2] == iv_tk_val[s])):
		if (iv_is_op(s + 3, '+') || iv_is_op(s + 3, '-')):
			x = s
			if (iv_is_op(s + 3, '-')): sign = -1
			delta = s + 4
	elif ((n == 3) && iv_is_var(s) && (iv_is_op(s + 1, iv_op2('+', '=')) || iv_is_op(s + 1, iv_op2('-', '=')))):
		x = s
		if (iv_is_op(s + 1, iv_op2('-', '='))): sign = -1
		delta = s + 2
	elif ((n == 2) && iv_is_var(s) && iv_incdec(s + 1)):
		x = s
		if (iv_is_op(s + 1, iv_op2('-', '-'))): sign = -1
	elif ((n == 2) && iv_incdec(s) && iv_is_var(s + 1)):
		x = s + 1
		if (iv_is_op(s, iv_op2('-', '-'))): sign = -1
	if (x < 0): return -1
	int d = -1
	if (delta < 0): d = iv_node(2, 1, 0)
	elif (iv_tk_kind[delta] == 2): d = iv_node(2, iv_tk_val[delta], 0)
	elif (iv_is_var(delta) && (iv_tk_val[delta] != iv_tk_val[x])): d = iv_node(1, iv_tk_val[delta], 0)
	else: return -1
	iv_upd_offset.push(iv_text_start + iv_tk_off[s])
	iv_upd_name.push(iv_tk_val[x])
	iv_upd_sign.push(sign)
	iv_upd_delta.push(d)
	return x


# The pre-scan closed an innermost loop: its keyword is at file offset
# start, the line that ended it at end, and its keyword's line has tabs
# leading tabs. Records the loop's candidates and returns how many
# pointer registers it would use (0: none, or the loop was declined).
int iv_analyze(int start, int tabs);


# After ivopt_scan_loop found candidates: the names inside them, for
# the pre-scan's ranking (rs_iv_discount): how many times each is a
# candidate's base and how many times it is read in a candidate's index.
int ivopt_inside_names():
	return iv_la_inside.length

char* ivopt_inside_name(int i):
	return iv_names[i]

int ivopt_inside_base(int i):
	return iv_la_inside_base[i]

int ivopt_inside_index(int i):
	return iv_la_inside[i] - iv_la_inside_base[i]


int ivopt_scan_loop(int start, int end, int tabs):
	if (ivopt_disabled): return 0
	iv_tables_ensure()
	char* text = 0
	int n = inline_source_copy(start, end, &text)
	if (n <= 0): return 0
	iv_text_start = start
	int ok = iv_lex(text, n)
	int count = 0
	if (ok): count = iv_analyze(start, tabs)
	free(text)
	return count


int iv_analyze(int start, int tabs):
	int ntok = iv_tk_kind.length
	if (ntok < 3): return 0
	int is_for = iv_name_is(0, c"for")
	if ((is_for == 0) && (iv_name_is(0, c"while") == 0)): return 0
	# the header: the first logical line, ending in ':'
	int h_end = 1
	while ((h_end < ntok) && (iv_tk_lstart[h_end] == 0)): h_end = h_end + 1
	if (h_end >= ntok): return 0
	if (iv_is_op(h_end - 1, ':') == 0): return 0
	int for_var = -1
	int first = 1   # the first token the occurrence pass reads
	if (is_for):
		# 'for X in range(a[, b]):' -- the arguments run before the loop
		if ((h_end < 7) || (iv_is_var(1) == 0) || (iv_name_is(2, c"in") == 0) || (iv_name_is(3, c"range") == 0)): return 0
		if ((iv_is_op(4, '(') == 0) || (iv_is_op(h_end - 2, ')') == 0)): return 0
		int depth = 0
		int commas = 0
		int t = 5
		while (t < h_end - 2):
			if (iv_is_op(t, '(') || iv_is_op(t, '[')): depth = depth + 1
			if (iv_is_op(t, ')') || iv_is_op(t, ']')): depth = depth - 1
			if ((depth == 0) && iv_is_op(t, ',')): commas = commas + 1
			t = t + 1
		if (commas > 1): return 0
		for_var = iv_tk_val[1]
		first = h_end
	# the body's lines are indented past the keyword's line; nothing the
	# analysis does not follow anywhere in the loop
	for t in range(ntok):
		if ((t >= h_end) && (iv_tk_tabs[t] >= 0) && (iv_tk_tabs[t] <= tabs)): return 0
		if ((iv_tok_keyword(t) == 2) && (t != 0)): return 0
		if (iv_is_op(t, iv_op2('-', '>'))): return 0
	iv_la_size()
	int upd_first = iv_upd_offset.length
	# per logical line of the body: steps, multi-assignments, declarations
	int s = h_end
	while (s < ntok):
		int e = s + 1
		while ((e < ntok) && (iv_tk_lstart[e] == 0)): e = e + 1
		int x = iv_step_line(s, e)
		if (x >= 0):
			int name = iv_tk_val[x]
			iv_la_upd[name] = iv_la_upd[name] + 1
			iv_tk_step[x] = 1
		# a ',' outside brackets: a multi-assignment or a multi-declaration
		int depth = 0
		int comma = 0
		for t in range(s, e):
			if (iv_is_op(t, '(') || iv_is_op(t, '[')): depth = depth + 1
			if (iv_is_op(t, ')') || iv_is_op(t, ']')): depth = depth - 1
			if ((depth == 0) && iv_is_op(t, ',')): comma = 1
		if (comma):
			for t in range(s, e):
				if (iv_tk_kind[t] == 1): iv_la_written[iv_tk_val[t]] = 1
		# 'T* name' / 'T** name' at the line's start
		if (iv_is_var(s)):
			int t = s + 1
			while ((t < e) && iv_is_op(t, '*')): t = t + 1
			if ((t > s + 1) && (t < e) && (iv_tk_kind[t] == 1)): iv_la_declared[iv_tk_val[t]] = 1
		s = e
	# every occurrence (the condition of a while, and the body)
	for t in range(first, ntok):
		if (iv_is_var(t) == 0): continue
		int name = iv_tk_val[t]
		iv_la_occ[name] = iv_la_occ[name] + 1
		# a declaration: after a type name ('T name'), after ']'
		# ('T[4] name', 'list[T] name'), or 'name :='
		# (the previous token on the same logical line only)
		int prev = t - 1
		if (iv_tk_lstart[t]): prev = -1
		if (prev >= 0):
			if ((iv_tk_kind[prev] == 1) && (iv_tok_keyword(prev) == 0)): iv_la_declared[name] = 1
			if (iv_is_op(prev, ']')): iv_la_declared[name] = 1
		if (iv_is_op(t + 1, iv_op2(':', '='))): iv_la_declared[name] = 1
		# a step line's own 'X' is the step, not a write
		if (iv_tk_step[t]): continue
		if (iv_assign_op(t + 1) || iv_incdec(t + 1)): iv_la_written[name] = 1
		if ((t > 0) && iv_incdec(t - 1) && (iv_tk_lstart[t - 1] || (iv_operand_end(t - 2) == 0))): iv_la_written[name] = 1
		if ((t > 0) && iv_is_op(t - 1, '&') && (iv_tk_lstart[t - 1] || (iv_operand_end(t - 2) == 0))):
			if ((iv_is_op(t + 1, '[') == 0) && (iv_is_op(t + 1, '.') == 0)): iv_la_written[name] = 1
	# classify: induction variables, invariants
	for i in range(iv_names.length):
		int c = 3
		if (iv_la_written[i] || iv_la_declared[i]): c = 3
		elif (i == for_var): c = 2
		elif (iv_la_upd[i] > 0): c = 2
		else: c = 1
		iv_la_class[i] = c
	if (for_var >= 0):
		if (iv_la_upd[for_var] > 0): iv_la_class[for_var] = 3
	# a step by a name the loop writes, or of a name that is not an
	# induction variable after all, voids that variable
	int u = upd_first
	while (u < iv_upd_offset.length):
		int d = iv_upd_delta[u]
		if ((iv_nk[d] == 1) && (iv_la_class[iv_na[d]] != 1)): iv_la_class[iv_upd_name[u]] = 3
		u = u + 1
	u = upd_first
	int kept = upd_first
	while (u < iv_upd_offset.length):
		if (iv_la_class[iv_upd_name[u]] == 2):
			iv_upd_offset[kept] = iv_upd_offset[u]
			iv_upd_name[kept] = iv_upd_name[u]
			iv_upd_sign[kept] = iv_upd_sign[u]
			iv_upd_delta[kept] = iv_upd_delta[u]
			kept = kept + 1
		u = u + 1
	while (iv_upd_offset.length > kept):
		iv_upd_offset.pop()
		iv_upd_name.pop()
		iv_upd_sign.pop()
		iv_upd_delta.pop()
	# the candidate subscripts
	int cand_first = iv_cand_base.length
	int occ_first = iv_occ_off.length
	for t in range(first, ntok):
		if ((iv_is_var(t) == 0) || (iv_is_op(t + 1, '[') == 0)): continue
		int base = iv_tk_val[t]
		# the matching ']'
		int close = t + 2
		int depth = 1
		while ((close < ntok) && (depth > 0)):
			if (iv_is_op(close, '[') || iv_is_op(close, '(')): depth = depth + 1
			if (iv_is_op(close, ']') || iv_is_op(close, ')')): depth = depth - 1
			if (depth > 0): close = close + 1
		if (close >= ntok): continue
		if (iv_la_class[base] != 1): continue
		iv_ps_pos = t + 2
		iv_ps_end = close
		iv_ps_fail = 0
		int index = iv_parse_expr()
		if (iv_ps_fail || (iv_ps_pos != close)): continue
		if ((iv_names_ok(index) == 0) || iv_trivial_index(index)): continue
		# linear in every induction variable, coefficients free of them
		int coef_first = iv_coef_name.length
		int linear = 1
		for v in range(iv_names.length):
			if (iv_la_class[v] != 2): continue
			int dv = iv_deriv(index, v)
			if (dv == -2): linear = 0
			elif (dv >= 0):
				if (iv_has_iv(dv)): linear = 0
				else:
					iv_coef_name.push(v)
					iv_coef_tree.push(dv)
		if (linear == 0):
			while (iv_coef_name.length > coef_first):
				iv_coef_name.pop()
				iv_coef_tree.pop()
			continue
		# the names inside count as covered
		iv_la_inside[base] = iv_la_inside[base] + 1
		iv_la_inside_base[base] = iv_la_inside_base[base] + 1
		for q in range(t + 2, close):
			if (iv_is_var(q)): iv_la_inside[iv_tk_val[q]] = iv_la_inside[iv_tk_val[q]] + 1
		int same = -1
		for c in range(cand_first, iv_cand_base.length):
			if ((iv_cand_base[c] == base) && iv_same_tree(iv_cand_index[c], index)): same = c
		iv_occ_off.push(iv_text_start + iv_tk_off[t])
		iv_occ_close.push(iv_text_start + iv_tk_off[close])
		if (same >= 0):
			iv_occ_cand.push(same)
			while (iv_coef_name.length > coef_first):
				iv_coef_name.pop()
				iv_coef_tree.pop()
			continue
		iv_occ_cand.push(iv_cand_base.length)
		iv_cand_base.push(base)
		iv_cand_index.push(index)
		iv_cand_coef_first.push(coef_first)
		iv_cand_coef_end.push(iv_coef_name.length)
	int count = iv_cand_base.length - cand_first
	if (count == 0):
		while (iv_occ_off.length > occ_first):
			iv_occ_off.pop()
			iv_occ_close.pop()
			iv_occ_cand.pop()
		while (iv_upd_offset.length > upd_first):
			iv_upd_offset.pop()
			iv_upd_name.pop()
			iv_upd_sign.pop()
			iv_upd_delta.pop()
		return 0
	int cover_first = iv_cover_name.length
	for i in range(iv_names.length):
		if ((iv_la_occ[i] > 0) && (iv_la_inside[i] == iv_la_occ[i]) && (iv_la_class[i] == 1)): iv_cover_name.push(i)
	iv_loop_offset.push(start)
	iv_loop_cand_first.push(cand_first)
	iv_loop_cand_end.push(iv_cand_base.length)
	iv_loop_upd_first.push(upd_first)
	iv_loop_upd_end.push(iv_upd_offset.length)
	iv_loop_for_var.push(for_var)
	iv_loop_cover_first.push(cover_first)
	iv_loop_cover_end.push(iv_cover_name.length)
	iv_loop_occ_first.push(occ_first)
	iv_loop_occ_end.push(iv_occ_off.length)
	if (count > 4): count = 4
	return count


# --- emission ---------------------------------------------------------------------
int iv_word_int(int type):
	if (type < 0): return 0
	if (type_is_array(type) || (type_get_pointer_level(type) != 0)): return 0
	if (type_stack_words(type) != 1): return 0
	if (type_get_size(type) != word_size): return 0
	return type_canonical(type) == type_lookup(c"int")


# The symbol record a name of the active loop resolves to when the unit
# may trust its value: a local or an argument the pre-scan never saw
# address-taken or called (rs_excluded); -1 otherwise. Memoized per
# loop head in iv_sym (-3: not resolved yet).
int iv_resolve(int name):
	int r = iv_sym[name]
	if (r != -3): return r
	r = -1
	char* s = iv_names[name]
	int i = rs_lookup(s)
	int t = sym_probe(s)
	if ((i >= 0) && (t >= 0) && (rs_excluded[i] == 0)):
		int scope = table[t + 1]
		if ((scope == 'L') || (scope == 'A')): r = t
	iv_sym[name] = r
	return r


# Every name of the tree resolves to a word-sized int.
int iv_tree_ok(int n):
	int k = iv_nk[n]
	if (k == 2): return 1
	if (k == 1):
		int t = iv_resolve(iv_na[n])
		if (t < 0): return 0
		return iv_word_int(load_int(table + t + 6))
	return iv_tree_ok(iv_na[n]) && iv_tree_ok(iv_nb[n])


# The induction variable x of loop j can be maintained: a word-sized,
# non-const int whose every step is by a trusted value.
int iv_step_ok(int j, int x):
	int t = iv_resolve(x)
	if (t < 0): return 0
	int type = load_int(table + t + 6)
	if (type_is_const(type) || (iv_word_int(type) == 0)): return 0
	if (x == iv_loop_for_var[j]):
		if (ivopt_range_ok == 0): return 0
	for u in range(iv_loop_upd_first[j], iv_loop_upd_end[j]):
		if ((iv_upd_name[u] == x) && (iv_tree_ok(iv_upd_delta[u]) == 0)): return 0
	return 1


# A constant tree's value in iv_const_value, for magnitudes the 32-bit
# compiler computes exactly (anything larger is computed at run time).
int iv_const_value
int iv_const(int n):
	int k = iv_nk[n]
	if (k == 1): return 0
	if (k == 2):
		iv_const_value = iv_na[n]
		return 1
	if (iv_const(iv_na[n]) == 0): return 0
	int a = iv_const_value
	if (iv_const(iv_nb[n]) == 0): return 0
	int b = iv_const_value
	if ((a > 32767) || (a < -32767) || (b > 32767) || (b < -32767)): return 0
	if (k == '+'): iv_const_value = a + b
	elif (k == '-'): iv_const_value = a - b
	else: iv_const_value = a * b
	return 1


# The tree's value into the accumulator, through the grammar's own
# operand protocol (binary1 parks the left operand, pop_ebx_slot takes
# it back), so every fold the expression emitters make applies.
void iv_emit(int n):
	int k = iv_nk[n]
	if (k == 2):
		mov_eax_int(iv_na[n])
		return;
	if (k == 1):
		int t = iv_sym[iv_na[n]]
		sym_emit_value(t, iv_names[iv_na[n]])
		promote(load_int(table + t + 6))
		return;
	iv_emit(iv_na[n])
	binary1(3)
	iv_emit(iv_nb[n])
	pop_ebx_slot()
	if (k == '+'): alu_add()
	elif (k == '-'): alu_sub()
	else: alu_imul()


# Pointer a's value, base + index * element size, into the accumulator.
void iv_emit_address(int a):
	int c = iv_act_cand[a]
	iv_emit(iv_cand_index[c])
	int es = iv_act_es[a]
	if (es != 1): imul_eax_int32(es)
	binary1(3)
	int t = iv_act_base_sym[a]
	sym_emit_value(t, iv_names[iv_cand_base[c]])
	promote(load_int(table + t + 6))
	pop_ebx_slot()
	alu_add()


int iv_live_here():
	if (iv_active == 0): return 0
	if (inline_depth != 0): return 0
	return regalloc_loop_depth == iv_depth


# A loop statement's head (regalloc_loop_enter, after the loop was found
# eligible for registers): resolve the loop's candidates, give each a
# free loop register and set it.
void ivopt_loop_enter(int offset):
	if (iv_active || ivopt_disabled || (iv_names == 0)): return;
	if ((word_size != 8) || (target_isa != 0) || (target_os != 0)): return;
	if (inline_depth != 0): return;
	int j = -1
	for q in range(iv_loop_offset.length):
		if (iv_loop_offset[q] == offset): j = q
	if (j < 0): return;
	iv_sym.clear()
	for i in range(iv_names.length): iv_sym.push(-3)
	ivopt_active_reset()
	for c in range(iv_loop_cand_first[j], iv_loop_cand_end[j]):
		int base_t = iv_resolve(iv_cand_base[c])
		if (base_t < 0): continue
		int btype = load_int(table + base_t + 6)
		if ((type_get_pointer_level(btype) < 1) || type_is_array(btype) || type_is_const(btype) || (type_stack_words(btype) != 1)): continue
		int element = type_lookup_previous_pointer(btype)
		if (element < 0): continue
		int es = type_get_size(element)
		if ((es < 1) || (es > 4096)): continue
		if (iv_tree_ok(iv_cand_index[c]) == 0): continue
		int ok = 1
		for q in range(iv_cand_coef_first[c], iv_cand_coef_end[c]):
			if (iv_step_ok(j, iv_coef_name[q]) == 0): ok = 0
			elif (iv_tree_ok(iv_coef_tree[q]) == 0): ok = 0
		if (ok == 0): continue
		int reg = rl_take_register()
		if (reg == 0): break
		regalloc_reg_bind(reg, 0)
		regalloc_loop_owned = regalloc_loop_owned | (1 << reg)
		iv_act_cand.push(c)
		iv_act_reg.push(reg)
		iv_act_es.push(es)
		iv_act_base_sym.push(base_t)
		iv_act_elem.push(element)
	if (iv_act_reg.length == 0): return;
	be_notes_reset()
	for a in range(iv_act_reg.length):
		iv_emit_address(a)
		mov_reg_eax(iv_act_reg[a])
	be_notes_reset()
	iv_active = 1
	ivopt_live = 1
	iv_steps_fired = 0
	iv_range_fired = 0
	iv_active_loop = j
	iv_depth = regalloc_loop_depth
	ivopt_loops = ivopt_loops + 1
	ivopt_pointers = ivopt_pointers + iv_act_reg.length


# Whether the loop register pass may skip name: every use of it in the
# active loop is inside a subscript a pointer now addresses.
int ivopt_covers(char* name):
	if (iv_active == 0): return 0
	int j = iv_active_loop
	if (iv_act_reg.length != iv_loop_cand_end[j] - iv_loop_cand_first[j]): return 0
	for q in range(iv_loop_cover_first[j], iv_loop_cover_end[j]):
		if (strcmp(iv_names[iv_cover_name[q]], name) == 0): return 1
	return 0


# The loop's exit region has ended (regalloc_loop_leave, before it pops
# the loop): the pointers are dead.
void ivopt_loop_leave():
	if (iv_active == 0): return;
	if (regalloc_loop_depth != iv_depth): return;
	# fail-closed: every step the analysis recorded was emitted once,
	# and a range loop's increment once (else a pointer missed a step)
	int j = iv_active_loop
	int ranged = (iv_loop_for_var[j] >= 0) && (iv_sym[iv_loop_for_var[j]] >= 0)
	if ((iv_steps_fired != iv_loop_upd_end[j] - iv_loop_upd_first[j]) || (ranged && (iv_range_fired != 1))):
		error(c"internal error: induction pointer steps out of step with the loop (compile with --no-ivopts and report this)")
	for a in range(iv_act_reg.length):
		int reg = iv_act_reg[a]
		rl_free_mask = rl_free_mask | (1 << reg)
		regalloc_loop_owned = regalloc_loop_owned & ~(1 << reg)
		regalloc_reg_bind(reg, 0)
	ivopt_active_reset()


void iv_add_imm(int reg, int v):
	if (v == 0): return;
	if ((v >= -128) && (v <= 127)):
		add_reg_int8(reg, v)
		return;
	emit_rex(1, 0, reg)
	emit(1, c"\x81")
	emit_int8(0xc0 | (reg & 7))
	emit_int32(v)


# 1 when name node n times m is one 'lea reg,[reg+R*m]': the name in a
# register R and m a scale the SIB byte carries.
int iv_lea_step(int reg, int n, int m):
	if (iv_nk[n] != 1): return 0
	if ((m != 1) && (m != 2) && (m != 4) && (m != 8)): return 0
	int r = regalloc_sym_register(iv_sym[iv_na[n]])
	if ((r == 0) || (r == 4)): return 0
	emit_mem_insn(1, 1, c"\x8d", reg, reg, r, m, 0)
	return 1


# reg += coef * sign * delta * es
void iv_advance_one(int reg, int coef, int sign, int delta, int es):
	ivopt_steps = ivopt_steps + 1
	int cc = iv_const(coef)
	int c = iv_const_value
	int dc = iv_const(delta)
	int d = iv_const_value
	if (cc && dc && (c * d <= 32767) && (c * d >= -32767) && (es <= 4096)):
		iv_add_imm(reg, c * d * es * sign)
		return;
	if (cc && (c <= 4096) && (c >= -4096)):
		if (iv_lea_step(reg, delta, c * sign * es)): return;
	if (dc && (d <= 4096) && (d >= -4096)):
		if (iv_lea_step(reg, coef, d * sign * es)): return;
		# the runtime coefficient times a constant
		iv_emit(coef)
		if (d * sign * es != 1): imul_eax_int32(d * sign * es)
		add_reg_eax(reg)
		return;
	if (cc && (c <= 4096) && (c >= -4096)):
		iv_emit(delta)
		if (c * sign * es != 1): imul_eax_int32(c * sign * es)
		add_reg_eax(reg)
		return;
	iv_emit(coef)
	binary1(3)
	iv_emit(delta)
	pop_ebx_slot()
	alu_imul()
	if (sign * es != 1): imul_eax_int32(sign * es)
	add_reg_eax(reg)


# Induction variable x was just stepped by sign * delta.
void iv_advance(int x, int sign, int delta):
	for a in range(iv_act_reg.length):
		int c = iv_act_cand[a]
		for q in range(iv_cand_coef_first[c], iv_cand_coef_end[c]):
			if (iv_coef_name[q] == x): iv_advance_one(iv_act_reg[a], iv_coef_tree[q], sign, delta, iv_act_es[a])


# The statement that started at file offset offset has been emitted
# (grammar/statement.w): a recorded step of the active loop moves the
# pointers that follow its variable.
void ivopt_step(int offset):
	if (iv_live_here() == 0): return;
	int j = iv_active_loop
	for u in range(iv_loop_upd_first[j], iv_loop_upd_end[j]):
		if (iv_upd_offset[u] == offset):
			iv_steps_fired = iv_steps_fired + 1
			be_notes_reset()
			iv_advance(iv_upd_name[u], iv_upd_sign[u], iv_upd_delta[u])
			be_notes_reset()


# A range loop's increment (code_generator/loop_ast.w) added 1 to its
# variable.
void ivopt_range_step():
	if (iv_live_here() == 0): return;
	int x = iv_loop_for_var[iv_active_loop]
	if (x < 0): return;
	iv_range_fired = iv_range_fired + 1
	be_notes_reset()
	iv_advance(x, 1, iv_node(2, 1, 0))
	be_notes_reset()


# A call inside the loop (regalloc_call_reload, after the loop registers
# came back from their homes) clobbered the pointer registers: compute
# them again, keeping the call's result registers.
void ivopt_call_reload():
	if (iv_active == 0): return;
	ivopt_remats = ivopt_remats + 1
	push_slot()
	emit_int8(0x52)   # push rdx
	stack_pos = stack_pos + 1
	for a in range(iv_act_reg.length):
		iv_emit_address(a)
		mov_reg_eax(iv_act_reg[a])
	emit_int8(0x5a)   # pop rdx
	stack_pos = stack_pos - 1
	pop_eax_slot()


# The active pointer of the candidate subscript whose base name starts at
# file offset offset, -1 when none. Both front ends ask this at the
# base's token (the AST emitter from the 'i' node's base, postfix_expr
# before the streaming primary), so they rewrite the same subscripts.
int iv_occurrence(int offset):
	int j = iv_active_loop
	for o in range(iv_loop_occ_first[j], iv_loop_occ_end[j]):
		if (iv_occ_off[o] == offset):
			for a in range(iv_act_reg.length):
				if (iv_act_cand[a] == iv_occ_cand[o]): return a
			return -1
	return -1


# Symbol record t, met inside a rewritten subscript's index, is one the
# loop's head resolved; anything else means the scope changed under the
# analysis (it declines loops that declare names, so it cannot).
void iv_check_index_symbol(int t):
	for i in range(iv_sym.length):
		if (iv_sym[i] == t): return;
	error(c"internal error: induction pointer subscript resolves to a different name (compile with --no-ivopts and report this)")


void iv_check_index_tree(expression_ast* tree, int id):
	if (id < 0): return;
	if (tree.op[id] == 'v'): iv_check_index_symbol(tree.symbol[id])
	iv_check_index_tree(tree, tree.left[id])
	iv_check_index_tree(tree, tree.right[id])


# The pointer register that holds subscript node id's address, 0 when no
# active pointer was recorded for it.
int ivopt_subscript_register(expression_ast* tree, int id):
	if (iv_live_here() == 0): return 0
	if (tree.op[id] != 'i'): return 0
	int left = tree.left[id]
	if ((left < 0) || (tree.op[left] != 'v')): return 0
	int a = iv_occurrence(tree.offset[left])
	if (a < 0): return 0
	if ((iv_act_base_sym[a] != tree.symbol[left]) || (tree.value[id] != iv_act_es[a])): return 0
	iv_check_index_tree(tree, tree.right[id])
	return iv_act_reg[a]


# The streaming twin (grammar/postfix_expr.w): at a primary's first
# token, a recorded subscript 'B[index]' of the active loop is consumed
# whole and becomes the pointer register's address note; returns its
# element type, or -1 (nothing consumed).
int ivopt_stream_subscript():
	if (iv_live_here() == 0): return -1
	int a = iv_occurrence(token_start_offset)
	if (a < 0): return -1
	if (sym_probe(token) != iv_act_base_sym[a]): return -1
	int j = iv_active_loop
	int close = -1
	for o in range(iv_loop_occ_first[j], iv_loop_occ_end[j]):
		if (iv_occ_off[o] == token_start_offset): close = iv_occ_close[o]
	sym_lookup(token)
	get_token()
	while (token_start_offset < close):
		if (is_ident_start_byte(token[0] & 255)): iv_check_index_symbol(sym_lookup(token))
		get_token()
	expect(c"]")
	addr_form(iv_act_reg[a], -1, 1, 0)
	return iv_act_elem[a]


void ivopt_stats_dump():
	print_int0(c"ivopt: loops: ", ivopt_loops)
	print_int0(c" pointers: ", ivopt_pointers)
	print_int0(c" steps: ", ivopt_steps)
	print_int(c" call recomputes: ", ivopt_remats)
