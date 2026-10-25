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
const int MM_RAIL_CLASS = 13
const int MM_RAIL_EXCEPT = 14

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
	char* name = str_copy_range(p.doc.source, start, p.pos)
	if (p.doc.kind == MM_RAIL_ABNF):
		for i in range(strlen(name)):
			if (name[i] >= 'A' && name[i] <= 'Z'): name[i] = cast(char, name[i] + 32)
	return name

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

# Quoted literal with the upstream escape set of each notation. IR, EBNF and
# PEG strings (`"..."` or `'...'`) decode `\n`, `\r` and `\t` and take any
# other escaped character literally (`\"`, `\\`, `\x` -> `x`); they may span
# lines. ABNF strings follow RFC 5234: double quotes only, no escapes, so a
# backslash is an ordinary character. `title` reuses this decoding, except
# that an ABNF title may also be single-quoted.
char* mm_rail_literal_mode(mm_parser* p, int title):
	mm_rail_space(p)
	int quote = mm_peek(p)
	int raw = p.doc.kind == MM_RAIL_ABNF
	if (quote != '"' && (quote != 39 || (raw && title == 0))):
		if (raw && quote == 39): mm_error(p.doc, p.pos, c"ABNF literals must be double-quoted")
		else: mm_error(p.doc, p.pos, c"expected quoted grammar literal")
		return strclone(c"")
	p.pos = p.pos + 1
	string_builder* s = string_new()
	while (mm_peek(p) != 0 && mm_peek(p) != quote):
		if (title && mm_peek(p) == 10): break
		if (raw == 0 && mm_peek(p) == 92 && p.pos + 1 < p.doc.length):
			p.pos = p.pos + 1
			int escaped = mm_peek(p)
			if (escaped == 'n'): escaped = 10
			else if (escaped == 'r'): escaped = 13
			else if (escaped == 't'): escaped = 9
			string_append_char(s, escaped)
			p.pos = p.pos + 1
		else:
			string_append_char(s, mm_peek(p))
			p.pos = p.pos + 1
	if (mm_peek(p) == quote): p.pos = p.pos + 1
	else: mm_error(p.doc, p.pos, c"unterminated grammar literal")
	char* result = strclone(s.data)
	string_free(s)
	return result

char* mm_rail_literal(mm_parser* p):
	return mm_rail_literal_mode(p, 0)

# A rule head (`name =`, `name ::=`, `name =/`, `Name <-`) at the start of a
# line ends the previous rule when its `;` was omitted. Upstream requires
# the semicolon; every grammar it accepts keeps its meaning here.
int mm_rail_rule_head(mm_parser* p):
	int i = p.pos - 1
	while (i >= 0 && (p.doc.source[i] == ' ' || p.doc.source[i] == 9 || p.doc.source[i] == 13)): i = i - 1
	if (i >= 0 && p.doc.source[i] != 10): return 0
	i = p.pos
	int c = mm_peek(p)
	if (isalpha(c) == 0 && c != '_'): return 0
	while (i < p.doc.length && (mm_id_char(p.doc.source[i]) || p.doc.source[i] == '-')):
		if (p.doc.source[i] == '-' && i + 1 < p.doc.length && p.doc.source[i + 1] == '>'): break
		i = i + 1
	while (i < p.doc.length && (p.doc.source[i] == ' ' || p.doc.source[i] == 9)): i = i + 1
	if (i >= p.doc.length): return 0
	c = p.doc.source[i]
	if (p.doc.kind == MM_RAIL_PEG): return c == '<' && i + 1 < p.doc.length && p.doc.source[i + 1] == '-'
	if (c == ':'): return i + 2 < p.doc.length && p.doc.source[i + 1] == ':' && p.doc.source[i + 2] == '='
	return c == '='

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
	if (mm_match(p, c"x") || mm_match(p, c"X")): base = 16
	else if (mm_match(p, c"d") || mm_match(p, c"D")): base = 10
	else if (mm_match(p, c"b") || mm_match(p, c"B")): base = 2
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

# Preserve the bracket spelling while validating consuming character ranges.
int mm_rail_class_char(mm_parser* p):
	int c = mm_peek(p)
	if (c == 0 || c == 10 || c == ']'):
		mm_error(p.doc, p.pos, c"expected PEG class character")
		return -1
	p.pos = p.pos + 1
	if (c != 92): return c
	c = mm_peek(p)
	if (c == 0 || c == 10):
		mm_error(p.doc, p.pos, c"unterminated PEG class escape")
		return -1
	p.pos = p.pos + 1
	if (c == 'n'): return 10
	if (c == 'r'): return 13
	if (c == 't'): return 9
	if (c != 92 && c != ']' && c != '[' && c != '-'):
		mm_error(p.doc, p.pos, c"unsupported PEG class escape")
	return c

int mm_rail_class(mm_parser* p):
	int start = p.pos
	p.pos = p.pos + 1
	int count = 0
	while (p.doc.error == 0 && mm_peek(p) != ']'):
		int low = mm_rail_class_char(p)
		count = count + 1
		if (mm_peek(p) == '-' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] != ']'):
			p.pos = p.pos + 1
			int high = mm_rail_class_char(p)
			if (high < low): mm_error(p.doc, p.pos, c"PEG character range is reversed")
	if (count == 0): mm_error(p.doc, p.pos, c"empty PEG character class")
	mm_rail_expect(p, c"]")
	char* text = str_copy_range(p.doc.source, start, p.pos)
	int result = mm_rail_add(p, MM_RAIL_CLASS, text)
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
	int explicit_case = 0
	if (p.doc.kind == MM_RAIL_ABNF):
		if (mm_match(p, c"%s") || mm_match(p, c"%S")): explicit_case = 1
		else if (mm_match(p, c"%i") || mm_match(p, c"%I")): explicit_case = 2
		if (explicit_case && mm_peek(p) != '"'): mm_error(p.doc, p.pos, c"ABNF %s/%i requires a double-quoted string")
	if (mm_peek(p) == '"' || mm_peek(p) == 39):
		char* text = mm_rail_literal(p)
		if (p.doc.kind == MM_RAIL_ABNF && explicit_case != 1):
			string_builder* label = string_from(text)
			string_append(label, c" (case-insensitive)")
			char* insensitive = strclone(label.data)
			string_free(label)
			free(text)
			text = insensitive
		result = mm_rail_add(p, MM_RAIL_TERMINAL, text)
		free(text)
	else if (p.doc.kind == MM_RAIL_PEG && mm_peek(p) == '['): result = mm_rail_class(p)
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

int mm_rail_term(mm_parser* p, int depth):
	int first = mm_rail_atom(p, depth)
	mm_rail_space(p)
	while (p.doc.error == 0 && p.doc.kind == MM_RAIL_EBNF && mm_match(p, c"-")):
		int parent = mm_rail_add(p, MM_RAIL_EXCEPT, c"")
		mm_rail_child(p, parent, first)
		mm_rail_child(p, parent, mm_rail_atom(p, depth))
		first = parent
		mm_rail_space(p)
	return first

int mm_rail_sequence(mm_parser* p, int depth):
	int first = mm_rail_term(p, depth + 1)
	int parent = -1
	while (p.doc.error == 0):
		mm_rail_space(p)
		int c = mm_peek(p)
		if (c == 0 || c == ';' || c == ')' || c == ']' || c == '}' || c == '|' || c == '/'): break
		if (mm_rail_rule_head(p)): break
		if (p.doc.kind == MM_RAIL_EBNF): mm_match(p, c",")
		if (parent < 0):
			parent = mm_rail_add(p, MM_RAIL_SEQUENCE, c"")
			mm_rail_child(p, parent, first)
		mm_rail_child(p, parent, mm_rail_term(p, depth + 1))
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

# Link each reference to the rule it names (upstream draws references as plain
# boxes and never inlines them; recursive grammars therefore stay finite).
void mm_rail_resolve(mm_rail_grammar* g):
	for mm_rail_expr* e in g.expressions:
		if (e.kind != MM_RAIL_REFERENCE): continue
		e.target = 0
		for i in range(g.rules.length):
			mm_rail_rule* rule = g.rules[i]
			if (strcmp(rule.name, e.text) == 0): e.target = i + 1

void mm_rail_body(mm_parser* p):
	mm_rail_grammar* g = p.doc.railroad
	mm_rail_space(p)
	while (p.doc.error == 0 && mm_peek(p) != 0):
		if (mm_metadata(p)): mm_space(p)
		else if (mm_match(p, c"title ")):
			mm_space(p)
			free(g.title)
			if (mm_peek(p) == '"' || mm_peek(p) == 39): g.title = mm_rail_literal_mode(p, 1)
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
			mm_rail_rule* existing = 0
			for mm_rail_rule* other in g.rules:
				if (strcmp(other.name, name) == 0): existing = other
			mm_rail_space(p)
			int incremental = p.doc.kind == MM_RAIL_ABNF && mm_match(p, c"=/")
			if (incremental == 0):
				if (p.doc.kind == MM_RAIL_PEG): mm_rail_expect(p, c"<-")
				else if (mm_match(p, c"::=") == 0): mm_rail_expect(p, c"=")
			if (incremental && existing == 0): mm_error(p.doc, p.pos, c"incremental ABNF rule requires an earlier definition")
			if (incremental == 0 && existing != 0): mm_error(p.doc, p.pos, c"duplicate grammar rule")
			int expression = -1
			if (p.doc.kind == MM_RAIL_IR): expression = mm_rail_atom(p, 0)
			else: expression = mm_rail_expression(p, 0)
			if (incremental && existing != 0):
				int choice = mm_rail_add(p, MM_RAIL_CHOICE, c"")
				mm_rail_child(p, choice, existing.expression)
				mm_rail_child(p, choice, expression)
				existing.expression = choice
				free(name)
			else: g.rules.push(new mm_rail_rule(name, expression))
			mm_rail_space(p)
			if (mm_match(p, c";")):
				if (p.doc.kind == MM_RAIL_ABNF):
					while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
			else if (p.doc.error == 0 && mm_peek(p) != 0 && mm_rail_rule_head(p) == 0): mm_error(p.doc, p.pos, c"expected grammar delimiter")
		mm_rail_space(p)
	if (g.rules.length == 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"railroad diagram requires a grammar rule")
	mm_rail_resolve(g)
