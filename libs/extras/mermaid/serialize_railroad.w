# Canonical railroad source in the diagram's own notation (constructor IR,
# EBNF, ABNF or PEG). Expressions are written so that reparsing creates them
# in the same order: IR constructors before their arguments, the other
# notations operands before their wrappers, sequences, choices and
# exceptions between their first and second operand. An ABNF choice built
# by `=/` (created after both alternatives) is written back as an
# incremental rule at its place in the source order.
import libs.extras.mermaid.serialize_common

struct mm_rail_writer:
	mm_serializer* out
	mm_rail_grammar* g
	int kind

int mm_serialize_rail_valid(mm_rail_writer* w, int index):
	if (index < 0 || index >= w.g.expressions.length):
		w.out.failed = 1
		return 0
	return 1

# Lowest and highest expression index in the subtree at index.
int mm_serialize_rail_bound(mm_rail_writer* w, int index, int high, int depth):
	if (depth > 64 || mm_serialize_rail_valid(w, index) == 0):
		w.out.failed = 1
		return index
	int best = index
	for int child in w.g.expressions[index].children:
		int value = mm_serialize_rail_bound(w, child, high, depth + 1)
		if (high && value > best): best = value
		if (high == 0 && value < best): best = value
	return best

void mm_serialize_rail_literal(mm_rail_writer* w, char* text):
	mm_serializer* out = w.out
	if (w.kind == MM_RAIL_ABNF):
		char* suffix = c" (case-insensitive)"
		int length = strlen(text)
		int cut = strlen(suffix)
		int insensitive = length >= cut && strcmp(text + length - cut, suffix) == 0
		if (insensitive == 0): mm_out(out, c"%s")
		mm_out_char(out, '"')
		int end = length
		if (insensitive): end = length - cut
		for i in range(end):
			if (text[i] == '"'): out.failed = 1
			mm_out_char(out, text[i])
		mm_out_char(out, '"')
		return
	mm_out_char(out, '"')
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (c == '"' || c == 92):
			mm_out_char(out, 92)
			mm_out_char(out, c)
		else if (c == 10): mm_out(out, c"\\n")
		else if (c == 13): mm_out(out, c"\\r")
		else if (c == 9): mm_out(out, c"\\t")
		else: mm_out_char(out, c)
	mm_out_char(out, '"')

void mm_serialize_rail_name(mm_rail_writer* w, char* name):
	int ok = isalpha(name[0]) || name[0] == '_'
	for i in range(strlen(name)):
		int c = name[i] & 255
		if (mm_id_char(c) == 0 && c != '-'): ok = 0
		if (c == '-' && name[i + 1] == '>'): ok = 0
		if (w.kind == MM_RAIL_ABNF && c >= 'A' && c <= 'Z'): ok = 0
	if (ok == 0): w.out.failed = 1
	mm_out(w.out, name)

void mm_serialize_rail_ir(mm_rail_writer* w, int index, int depth):
	mm_serializer* out = w.out
	if (depth > 32 || mm_serialize_rail_valid(w, index) == 0):
		out.failed = 1
		return
	mm_rail_expr* e = w.g.expressions[index]
	list[char*] names = list[char*]{c"", c"terminal", c"nonterminal", c"sequence", c"choice", c"optional", c"zeroOrMore", c"oneOrMore", c"special"}
	if (e.kind < 1 || e.kind > MM_RAIL_SPECIAL):
		out.failed = 1
		__w_list_free(cast(__w_list*, names))
		return
	mm_out(out, names[e.kind])
	__w_list_free(cast(__w_list*, names))
	mm_out_char(out, '(')
	if (e.kind == MM_RAIL_TERMINAL || e.kind == MM_RAIL_REFERENCE || e.kind == MM_RAIL_SPECIAL):
		if (e.children.length != 0): out.failed = 1
		mm_serialize_rail_literal(w, e.text)
	else:
		if (e.children.length == 0 || (e.kind != MM_RAIL_SEQUENCE && e.kind != MM_RAIL_CHOICE && e.children.length != 1)): out.failed = 1
		for i in range(e.children.length):
			if (i > 0): mm_out(out, c", ")
			int child = e.children[i]
			if (child <= index): out.failed = 1
			mm_serialize_rail_ir(w, child, depth + 1)
	mm_out_char(out, ')')

# Precedence: 0 choice, 1 sequence, 2 exception term, 3 atom.
int mm_serialize_rail_level(mm_rail_writer* w, int index):
	mm_rail_expr* e = w.g.expressions[index]
	if (e.kind == MM_RAIL_CHOICE): return 0
	if (e.kind == MM_RAIL_SEQUENCE): return 1
	if (e.kind == MM_RAIL_EXCEPT): return 2
	# Postfix operators bind to an atom and are not atoms themselves.
	if (w.kind == MM_RAIL_PEG && (e.kind == MM_RAIL_OPTIONAL || e.kind == MM_RAIL_ZERO || e.kind == MM_RAIL_ONE)): return 2
	if (w.kind == MM_RAIL_EBNF && e.kind == MM_RAIL_ONE): return 2
	if (e.kind == MM_RAIL_AND || e.kind == MM_RAIL_NOT || e.kind == MM_RAIL_REPEAT): return 2
	return 3

void mm_serialize_rail_expr(mm_rail_writer* w, int index, int need, int depth);

void mm_serialize_rail_operand(mm_rail_writer* w, int index, int need, int depth):
	if (mm_serialize_rail_valid(w, index) == 0): return
	int level = mm_serialize_rail_level(w, index)
	if (level < need):
		mm_out_char(w.out, '(')
		mm_serialize_rail_expr(w, index, 0, depth + 1)
		mm_out_char(w.out, ')')
	else: mm_serialize_rail_expr(w, index, need, depth + 1)

void mm_serialize_rail_expr(mm_rail_writer* w, int index, int need, int depth):
	mm_serializer* out = w.out
	if (depth > 64 || mm_serialize_rail_valid(w, index) == 0):
		out.failed = 1
		return
	mm_rail_expr* e = w.g.expressions[index]
	int k = e.kind
	int arity = e.children.length
	if (k == MM_RAIL_TERMINAL):
		mm_serialize_rail_literal(w, e.text)
	else if (k == MM_RAIL_REFERENCE): mm_serialize_rail_name(w, e.text)
	else if (k == MM_RAIL_SPECIAL):
		if (w.kind == MM_RAIL_PEG && strcmp(e.text, c"any character") == 0): mm_out_char(out, '.')
		else if (w.kind == MM_RAIL_EBNF):
			mm_out_char(out, '?')
			mm_out_plain(out, e.text, c"?")
			mm_out_char(out, '?')
		else: out.failed = 1
	else if (k == MM_RAIL_NUMERIC || k == MM_RAIL_CLASS):
		if ((k == MM_RAIL_NUMERIC && w.kind != MM_RAIL_ABNF) || (k == MM_RAIL_CLASS && w.kind != MM_RAIL_PEG)): out.failed = 1
		mm_out_plain(out, e.text, 0)
	else if (k == MM_RAIL_SEQUENCE || k == MM_RAIL_CHOICE):
		if (arity < 2): out.failed = 1
		for i in range(arity):
			if (i > 0):
				if (k == MM_RAIL_CHOICE && w.kind == MM_RAIL_EBNF): mm_out(out, c" | ")
				else if (k == MM_RAIL_CHOICE): mm_out(out, c" / ")
				else if (w.kind == MM_RAIL_EBNF): mm_out(out, c", ")
				else: mm_out_char(out, 32)
			if (k == MM_RAIL_CHOICE): mm_serialize_rail_operand(w, e.children[i], 1, depth)
			else: mm_serialize_rail_operand(w, e.children[i], 2, depth)
	else if (k == MM_RAIL_EXCEPT):
		if (arity != 2 || w.kind != MM_RAIL_EBNF): out.failed = 1
		else:
			mm_serialize_rail_operand(w, e.children[0], 2, depth)
			mm_out(out, c" - ")
			mm_serialize_rail_operand(w, e.children[1], 3, depth)
	else if (arity != 1): out.failed = 1
	else if (k == MM_RAIL_AND || k == MM_RAIL_NOT):
		if (w.kind != MM_RAIL_PEG): out.failed = 1
		if (k == MM_RAIL_AND): mm_out_char(out, '&')
		else: mm_out_char(out, '!')
		mm_serialize_rail_operand(w, e.children[0], 2, depth)
	else if (k == MM_RAIL_REPEAT):
		if (w.kind != MM_RAIL_ABNF || e.minimum < 0 || (e.maximum >= 0 && e.maximum < e.minimum)): out.failed = 1
		if (e.minimum == e.maximum): mm_out_int(out, e.minimum)
		else:
			if (e.minimum != 0): mm_out_int(out, e.minimum)
			mm_out_char(out, '*')
			if (e.maximum >= 0): mm_out_int(out, e.maximum)
		mm_serialize_rail_operand(w, e.children[0], 3, depth)
	else if ((k == MM_RAIL_OPTIONAL || k == MM_RAIL_ZERO) && w.kind != MM_RAIL_PEG):
		if (k == MM_RAIL_ZERO && w.kind != MM_RAIL_EBNF): out.failed = 1
		if (k == MM_RAIL_OPTIONAL): mm_out(out, c"[ ")
		else: mm_out(out, c"{ ")
		mm_serialize_rail_expr(w, e.children[0], 0, depth + 1)
		if (k == MM_RAIL_OPTIONAL): mm_out(out, c" ]")
		else: mm_out(out, c" }")
	else if (k == MM_RAIL_OPTIONAL || k == MM_RAIL_ZERO || k == MM_RAIL_ONE):
		if (w.kind == MM_RAIL_ABNF): out.failed = 1
		mm_serialize_rail_operand(w, e.children[0], 3, depth)
		if (k == MM_RAIL_OPTIONAL): mm_out_char(out, '?')
		else if (k == MM_RAIL_ZERO): mm_out_char(out, '*')
		else: mm_out_char(out, '+')
	else: out.failed = 1

struct mm_rail_statement:
	int start
	int rule
	int expression
	int incremental

void mm_serialize_rail_title(mm_serializer* out, mm_document* d, char* title):
	if (title[0] == 0): return
	mm_out(out, c"title ")
	int plain = title[0] > 32 && title[0] != '"' && title[0] != 39
	int length = strlen(title)
	for i in range(length):
		if (title[i] == 10 || title[i] == 13): out.failed = 1
	if (plain): mm_out(out, title)
	else if (d.kind == MM_RAIL_ABNF):
		int quote = '"'
		if (index_of(title, c"\"") >= 0): quote = 39
		if (quote == 39 && index_of(title, c"'") >= 0): out.failed = 1
		mm_out_char(out, quote)
		mm_out(out, title)
		mm_out_char(out, quote)
	else:
		mm_rail_writer w
		w.out = out
		w.g = d.railroad
		w.kind = d.kind
		mm_serialize_rail_literal(&w, title)
	mm_out_line(out)

void mm_serialize_railroad_body(mm_serializer* out, mm_document* d, int variant):
	mm_rail_grammar* g = d.railroad
	if (g == 0 || d.nodes.length != 0 || d.edges.length != 0 || d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.style_definitions.length != 0):
		out.failed = 1
		return
	if (d.kind == MM_RAIL_IR): mm_out(out, c"railroad-beta\n")
	else if (d.kind == MM_RAIL_EBNF): mm_out(out, c"railroad-ebnf-beta\n")
	else if (d.kind == MM_RAIL_ABNF): mm_out(out, c"railroad-abnf-beta\n")
	else: mm_out(out, c"railroad-peg-beta\n")
	mm_serialize_rail_title(out, d, g.title)
	mm_serialize_accessibility(out, d)
	mm_rail_writer w
	w.out = out
	w.g = g
	w.kind = d.kind
	# Rule definitions and ABNF `=/` increments, in source (expression) order.
	list[mm_rail_statement*] statements = new list[mm_rail_statement*]
	for r in range(g.rules.length):
		int root = g.rules[r].expression
		if (mm_serialize_rail_valid(&w, root) == 0): break
		while (d.kind == MM_RAIL_ABNF):
			mm_rail_expr* e = g.expressions[root]
			if (e.kind != MM_RAIL_CHOICE || e.children.length != 2): break
			if (root < mm_serialize_rail_bound(&w, e.children[1], 1, 0)): break
			int added = e.children[1]
			statements.push(new mm_rail_statement(mm_serialize_rail_bound(&w, added, 0, 0), r, added, 1))
			root = e.children[0]
			if (out.failed): break
		statements.push(new mm_rail_statement(mm_serialize_rail_bound(&w, root, 0, 0), r, root, 0))
	# Insertion sort by first expression index.
	for i in range(1, statements.length):
		int j = i
		while (j > 0 && statements[j - 1].start > statements[j].start):
			mm_rail_statement* swap = statements[j]
			statements[j] = statements[j - 1]
			statements[j - 1] = swap
			j = j - 1
	for mm_rail_statement* s in statements:
		if (out.failed): break
		mm_serialize_rail_name(&w, g.rules[s.rule].name)
		if (s.incremental): mm_out(out, c" =/ ")
		else if (d.kind == MM_RAIL_PEG): mm_out(out, c" <- ")
		else: mm_out(out, c" = ")
		if (d.kind == MM_RAIL_IR): mm_serialize_rail_ir(&w, s.expression, 0)
		else: mm_serialize_rail_expr(&w, s.expression, 0, 0)
		if (d.kind == MM_RAIL_ABNF): mm_out_line(out)
		else: mm_out(out, c" ;\n")
	for mm_rail_statement* s in statements: free(s)
	__w_list_free(cast(__w_list*, statements))
