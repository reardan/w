# Bounded native grammar parser for Mermaid 12.2 railroad notations.
import libs.extras.mermaid.parse_common

const int MM_RAIL_TERMINAL = 1
const int MM_RAIL_REFERENCE = 2
const int MM_RAIL_SEQUENCE = 3
const int MM_RAIL_CHOICE = 4
const int MM_RAIL_OPTIONAL = 5
const int MM_RAIL_ZERO = 6
const int MM_RAIL_ONE = 7
const int MM_RAIL_SPECIAL = 8
const int MM_RAIL_AND = 9
const int MM_RAIL_NOT = 10
const int MM_RAIL_NUMERIC = 11
const int MM_RAIL_REPEAT = 12

mm_rail_grammar* mm_rail_new(mm_document* d):
	mm_rail_grammar* g = new mm_rail_grammar()
	g.title = strclone(c"")
	g.expressions = new list[mm_rail_expr*]
	g.rules = new list[mm_rail_rule*]
	d.railroad = g
	return g

# Whitespace within grammar expressions includes newlines, but not semicolons.
void mm_rail_space(mm_parser* p):
	while (p.doc.error == 0):
		mm_space(p)
		if (mm_peek(p) == 10):
			p.pos = p.pos + 1
			continue
		if (mm_match(p, c"%%") || (p.doc.kind == MM_RAIL_PEG && mm_match(p, c"#"))):
			if (mm_peek(p) == '{'): mm_error(p.doc, p.pos, c"railroad configuration directives are unsupported")
			while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
			continue
		int comment = 0
		if (p.doc.kind == MM_RAIL_EBNF):
			if (mm_match(p, c"/*")): comment = 1
			else if (mm_match(p, c"(*")): comment = 2
		if (comment):
			int closed = 0
			while (mm_peek(p) != 0):
				if ((comment == 1 && mm_match(p, c"*/")) || (comment == 2 && mm_match(p, c"*)"))):
					closed = 1
					break
				p.pos = p.pos + 1
			if (closed == 0): mm_error(p.doc, p.pos, c"unterminated grammar comment")
			continue
		return

char* mm_rail_identifier(mm_parser* p):
	mm_rail_space(p)
	int start = p.pos
	if (isalpha(mm_peek(p)) == 0 && mm_peek(p) != '_'): mm_error(p.doc, p.pos, c"expected grammar identifier")
	while (mm_id_char(mm_peek(p)) || mm_peek(p) == '-'):
		if (mm_peek(p) == '-' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == '>'): break
		p.pos = p.pos + 1
	return str_copy_range(p.doc.source, start, p.pos)

int mm_rail_add(mm_parser* p, int kind, char* text):
	if (p.doc.railroad.expressions.length >= 1024):
		mm_error(p.doc, p.pos, c"railroad expression limit exceeded (1024)")
		return -1
	mm_rail_expr* expr = new mm_rail_expr()
	expr.kind = kind
	expr.text = strclone(text)
	expr.children = new list[int]
	expr.maximum = -1
	p.doc.railroad.expressions.push(expr)
	return p.doc.railroad.expressions.length - 1

void mm_rail_child(mm_parser* p, int parent, int child):
	if (parent < 0 || child < 0): return
	mm_rail_expr* expr = p.doc.railroad.expressions[parent]
	expr.children.push(child)

void mm_rail_expect(mm_parser* p, char* token):
	mm_rail_space(p)
	if (mm_match(p, token) == 0): mm_error(p.doc, p.pos, c"expected grammar delimiter")

char* mm_rail_literal(mm_parser* p):
	mm_rail_space(p)
	int quote = mm_peek(p)
	if (quote != '"' && quote != 39):
		mm_error(p.doc, p.pos, c"expected quoted grammar literal")
		return strclone(c"")
	p.pos = p.pos + 1
	string_builder* s = string_new()
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != quote):
		if (mm_match(p, c"\\")):
			if (mm_peek(p) == quote || mm_peek(p) == '\\'):
				string_append_char(s, mm_peek(p))
				p.pos = p.pos + 1
			else:
				mm_error(p.doc, p.pos, c"unsupported literal escape; use quoted literals or numeric ABNF values")
				break
		else:
			string_append_char(s, mm_peek(p))
			p.pos = p.pos + 1
	if (mm_peek(p) == quote): p.pos = p.pos + 1
	else: mm_error(p.doc, p.pos, c"unterminated grammar literal")
	char* result = strclone(s.data)
	string_free(s)
	return result

int mm_rail_wrap(mm_parser* p, int kind, int child):
	int index = mm_rail_add(p, kind, c"")
	mm_rail_child(p, index, child)
	return index


int mm_rail_expression(mm_parser* p, int depth);
int mm_rail_atom(mm_parser* p, int depth);

int mm_rail_ir(mm_parser* p, int depth):
	char* name = mm_rail_identifier(p)
	int kind = 0
	if (strcmp(name, c"terminal") == 0): kind = MM_RAIL_TERMINAL
	else if (strcmp(name, c"nonterminal") == 0): kind = MM_RAIL_REFERENCE
	else if (strcmp(name, c"special") == 0): kind = MM_RAIL_SPECIAL
	else if (strcmp(name, c"sequence") == 0): kind = MM_RAIL_SEQUENCE
	else if (strcmp(name, c"choice") == 0): kind = MM_RAIL_CHOICE
	else if (strcmp(name, c"optional") == 0): kind = MM_RAIL_OPTIONAL
	else if (strcmp(name, c"zeroOrMore") == 0): kind = MM_RAIL_ZERO
	else if (strcmp(name, c"oneOrMore") == 0): kind = MM_RAIL_ONE
	else: mm_error(p.doc, p.pos, c"unknown railroad constructor")
	free(name)
	mm_rail_expect(p, c"(")
	if (kind == MM_RAIL_TERMINAL || kind == MM_RAIL_REFERENCE || kind == MM_RAIL_SPECIAL):
		char* text = mm_rail_literal(p)
		int result = mm_rail_add(p, kind, text)
		free(text)
		mm_rail_expect(p, c")")
		return result
	int parent = mm_rail_add(p, kind, c"")
	if (parent < 0): return -1
	mm_rail_child(p, parent, mm_rail_atom(p, depth + 1))
	mm_rail_space(p)
	while (p.doc.error == 0 && mm_match(p, c",")):
		mm_rail_child(p, parent, mm_rail_atom(p, depth + 1))
		mm_rail_space(p)
	mm_rail_expr* expr = p.doc.railroad.expressions[parent]
	if (kind != MM_RAIL_SEQUENCE && kind != MM_RAIL_CHOICE && expr.children.length != 1): mm_error(p.doc, p.pos, c"unary railroad constructor requires one argument")
	mm_rail_expect(p, c")")
	return parent

int mm_rail_uint(mm_parser* p, int limit):
	int n = 0
	int start = p.pos
	while (isdigit(mm_peek(p))):
		if (n > limit / 10):
			mm_error(p.doc, p.pos, c"grammar numeric bound exceeded")
			return 0
		n = n * 10 + mm_peek(p) - '0'
		p.pos = p.pos + 1
	if (n > limit || start == p.pos): mm_error(p.doc, p.pos, c"expected bounded unsigned integer")
	return n

int mm_rail_digit(int c):
	if (c >= '0' && c <= '9'): return c - '0'
	if (c >= 'a' && c <= 'f'): return c - 'a' + 10
	if (c >= 'A' && c <= 'F'): return c - 'A' + 10
	return -1

int mm_rail_numeric_value(mm_parser* p, int base):
	int start = p.pos
	int value = 0
	while (1):
		int digit = mm_rail_digit(mm_peek(p))
		if (digit < 0 || digit >= base): break
		if (value > 1114111 / base):
			mm_error(p.doc, p.pos, c"ABNF numeric value outside Unicode range")
			return 0
		value = value * base + digit
		p.pos = p.pos + 1
	if (start == p.pos || value > 1114111): mm_error(p.doc, p.pos, c"invalid ABNF numeric value")
	return value

int mm_rail_numeric(mm_parser* p):
	int start = p.pos
	p.pos = p.pos + 1
	int base = 0
	if (mm_match(p, c"x")): base = 16
	else if (mm_match(p, c"d")): base = 10
	else if (mm_match(p, c"b")): base = 2
	if (base == 0):
		mm_error(p.doc, p.pos, c"expected ABNF %x, %d or %b value")
		return -1
	int low = mm_rail_numeric_value(p, base)
	if (mm_match(p, c"-")):
		int high = mm_rail_numeric_value(p, base)
		if (high < low): mm_error(p.doc, p.pos, c"ABNF numeric range is reversed")
	else:
		while (p.doc.error == 0 && mm_match(p, c".")): mm_rail_numeric_value(p, base)
	char* text = str_copy_range(p.doc.source, start, p.pos)
	int result = mm_rail_add(p, MM_RAIL_NUMERIC, text)
	free(text)
	return result

int mm_rail_atom(mm_parser* p, int depth):
	if (p.doc.error != 0): return -1
	if (depth > 32):
		mm_error(p.doc, p.pos, c"railroad nesting limit exceeded (32)")
		return -1
	mm_rail_space(p)
	if (p.doc.kind == MM_RAIL_IR): return mm_rail_ir(p, depth)
	if (p.doc.kind == MM_RAIL_ABNF && (isdigit(mm_peek(p)) || mm_peek(p) == '*')):
		int minimum = 0
		int maximum = -1
		if (isdigit(mm_peek(p))): minimum = mm_rail_uint(p, 1000000)
		maximum = minimum
		if (mm_match(p, c"*")):
			maximum = -1
			if (isdigit(mm_peek(p))): maximum = mm_rail_uint(p, 1000000)
		if (maximum >= 0 && maximum < minimum): mm_error(p.doc, p.pos, c"repetition maximum below minimum")
		int child = mm_rail_atom(p, depth + 1)
		int parent = mm_rail_wrap(p, MM_RAIL_REPEAT, child)
		if (parent >= 0):
			mm_rail_expr* expr = p.doc.railroad.expressions[parent]
			expr.minimum = minimum
			expr.maximum = maximum
		return parent
	if (p.doc.kind == MM_RAIL_PEG && (mm_peek(p) == '&' || mm_peek(p) == '!')):
		int kind = MM_RAIL_AND
		if (mm_peek(p) == '!'): kind = MM_RAIL_NOT
		p.pos = p.pos + 1
		return mm_rail_wrap(p, kind, mm_rail_atom(p, depth + 1))
	int result = -1
	if (mm_peek(p) == '"' || mm_peek(p) == 39):
		char* text = mm_rail_literal(p)
		if (p.doc.kind == MM_RAIL_ABNF):
			string_builder* label = string_from(text)
			string_append(label, c" (case-insensitive)")
			char* insensitive = strclone(label.data)
			string_free(label)
			free(text)
			text = insensitive
		result = mm_rail_add(p, MM_RAIL_TERMINAL, text)
		free(text)
	else if (p.doc.kind == MM_RAIL_ABNF && mm_peek(p) == '%'): result = mm_rail_numeric(p)
	else if (mm_match(p, c"(")):
		result = mm_rail_expression(p, depth + 1)
		mm_rail_expect(p, c")")
	else if (p.doc.kind != MM_RAIL_PEG && mm_match(p, c"[")):
		result = mm_rail_wrap(p, MM_RAIL_OPTIONAL, mm_rail_expression(p, depth + 1))
		mm_rail_expect(p, c"]")
	else if (p.doc.kind == MM_RAIL_EBNF && mm_match(p, c"{")):
		result = mm_rail_wrap(p, MM_RAIL_ZERO, mm_rail_expression(p, depth + 1))
		mm_rail_expect(p, c"}")
	else if (p.doc.kind == MM_RAIL_PEG && mm_match(p, c".")): result = mm_rail_add(p, MM_RAIL_SPECIAL, c"any character")
	else if (p.doc.kind == MM_RAIL_EBNF && mm_match(p, c"?")):
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != '?'): p.pos = p.pos + 1
		char* text = str_copy_range(p.doc.source, start, p.pos)
		result = mm_rail_add(p, MM_RAIL_SPECIAL, text)
		free(text)
		mm_rail_expect(p, c"?")
	else:
		char* name = mm_rail_identifier(p)
		result = mm_rail_add(p, MM_RAIL_REFERENCE, name)
		free(name)
	if (p.doc.kind != MM_RAIL_ABNF):
		mm_rail_space(p)
		if (mm_match(p, c"?")): result = mm_rail_wrap(p, MM_RAIL_OPTIONAL, result)
		else if (mm_match(p, c"*")): result = mm_rail_wrap(p, MM_RAIL_ZERO, result)
		else if (mm_match(p, c"+")): result = mm_rail_wrap(p, MM_RAIL_ONE, result)
	return result

int mm_rail_sequence(mm_parser* p, int depth):
	int first = mm_rail_atom(p, depth + 1)
	int parent = -1
	while (p.doc.error == 0):
		mm_rail_space(p)
		int c = mm_peek(p)
		if (c == 0 || c == ';' || c == ')' || c == ']' || c == '}' || c == '|' || c == '/'): break
		if (p.doc.kind == MM_RAIL_EBNF): mm_match(p, c",")
		if (parent < 0):
			parent = mm_rail_add(p, MM_RAIL_SEQUENCE, c"")
			mm_rail_child(p, parent, first)
		mm_rail_child(p, parent, mm_rail_atom(p, depth + 1))
	if (parent >= 0): return parent
	return first

int mm_rail_expression(mm_parser* p, int depth):
	int first = mm_rail_sequence(p, depth)
	int parent = -1
	while (p.doc.error == 0):
		mm_rail_space(p)
		int choice = 0
		if (p.doc.kind == MM_RAIL_EBNF): choice = mm_match(p, c"|")
		else: choice = mm_match(p, c"/")
		if (choice == 0): break
		if (parent < 0):
			parent = mm_rail_add(p, MM_RAIL_CHOICE, c"")
			mm_rail_child(p, parent, first)
		mm_rail_child(p, parent, mm_rail_sequence(p, depth))
	if (parent >= 0): return parent
	return first

void mm_rail_body(mm_parser* p):
	mm_rail_grammar* g = p.doc.railroad
	mm_rail_space(p)
	while (p.doc.error == 0 && mm_peek(p) != 0):
		if (mm_match(p, c"title ")):
			mm_space(p)
			free(g.title)
			if (mm_peek(p) == '"' || mm_peek(p) == 39): g.title = mm_rail_literal(p)
			else:
				int start = p.pos
				while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
				g.title = str_copy_range(p.doc.source, start, p.pos)
			mm_space(p)
			if (mm_peek(p) != 0 && mm_peek(p) != 10): mm_error(p.doc, p.pos, c"expected end of railroad title")
		else if (p.doc.kind == MM_RAIL_ABNF && mm_match(p, c";")):
			while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
		else:
			if (g.rules.length >= 256):
				mm_error(p.doc, p.pos, c"railroad rule limit exceeded (256)")
				return
			char* name = mm_rail_identifier(p)
			for mm_rail_rule* other in g.rules:
				if (strcmp(other.name, name) == 0): mm_error(p.doc, p.pos, c"duplicate grammar rule")
			mm_rail_rule* rule = new mm_rail_rule(name, -1)
			g.rules.push(rule)
			mm_rail_space(p)
			if (p.doc.kind == MM_RAIL_PEG): mm_rail_expect(p, c"<-")
			else if (mm_match(p, c"::=") == 0): mm_rail_expect(p, c"=")
			if (p.doc.kind == MM_RAIL_IR): rule.expression = mm_rail_atom(p, 0)
			else: rule.expression = mm_rail_expression(p, 0)
			mm_rail_expect(p, c";")
			if (p.doc.kind == MM_RAIL_ABNF):
				while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
		mm_rail_space(p)
	if (g.rules.length == 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"railroad diagram requires a grammar rule")
