# Explicit subset parser: unknown syntax fails instead of silently dropping it.
import libs.extras.mermaid.model
import lib.utf8

struct mm_parser:
	mm_document* doc
	int pos
	int scope
	int global_nodes

int mm_peek(mm_parser* p):
	if (p.pos >= p.doc.length): return 0
	return p.doc.source[p.pos] & 255

int mm_match(mm_parser* p, char* text):
	int n = strlen(text)
	if (n > p.doc.length - p.pos): return 0
	for i in range(n):
		if (p.doc.source[p.pos + i] != text[i]): return 0
	p.pos = p.pos + n
	return 1

void mm_space(mm_parser* p):
	while (mm_peek(p) == 32 || mm_peek(p) == 9 || mm_peek(p) == 13): p.pos = p.pos + 1

int mm_end(mm_parser* p):
	mm_space(p)
	if (p.pos + 1 < p.doc.length && p.doc.source[p.pos] == '%' && p.doc.source[p.pos + 1] == '%'): return 1
	return mm_peek(p) == 0 || mm_peek(p) == 10 || mm_peek(p) == ';'

void mm_separators(mm_parser* p):
	while (1):
		mm_space(p)
		if (mm_match(p, c"%%")):
			if (mm_peek(p) == '{'): mm_error(p.doc, p.pos, c"Mermaid configuration directives are not supported in the native renderer")
			while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
		else if (mm_peek(p) == 10 || mm_peek(p) == ';'): p.pos = p.pos + 1
		else: return

char* mm_quoted(mm_parser* p):
	p.pos = p.pos + 1
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != '"' && mm_peek(p) != 10): p.pos = p.pos + 1
	char* text = str_copy_range(p.doc.source, start, p.pos)
	if (mm_peek(p) == '"'): p.pos = p.pos + 1
	else: mm_error(p.doc, start - 1, c"unterminated quoted text")
	return text

int mm_id_char(int c):
	return isalnum(c) || c == '_' || c >= 128

char* mm_identifier(mm_parser* p):
	mm_space(p)
	if (mm_peek(p) == '"'): return mm_quoted(p)
	int start = p.pos
	while (mm_id_char(mm_peek(p)) || (p.doc.kind == MM_ER && mm_peek(p) == '-')): p.pos = p.pos + 1
	if (p.pos == start): mm_error(p.doc, start, c"expected entity or node identifier")
	return str_copy_range(p.doc.source, start, p.pos)

char* mm_word(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != 32 && mm_peek(p) != 9 && mm_peek(p) != ';' && mm_peek(p) != '}' && mm_peek(p) != '"'): p.pos = p.pos + 1
	if (p.pos == start): mm_error(p.doc, start, c"expected attribute type or name")
	return str_copy_range(p.doc.source, start, p.pos)

int mm_attribute_word(char* text, int name):
	int i = 0
	if (name && text[0] == '*'): i = 1
	if (isalpha(text[i]) == 0 && (text[i] & 255) < 128): return 0
	i = i + 1
	while (text[i] != 0):
		int c = text[i] & 255
		if (mm_id_char(c) == 0 && c != '-' && c != '(' && c != ')' && c != '[' && c != ']'):
			if (name || c != '?' || text[i + 1] != 0): return 0
		i = i + 1
	return 1

char* mm_until(mm_parser* p, int close):
	mm_space(p)
	char* text
	if (mm_peek(p) == '"'):
		text = mm_quoted(p)
		mm_space(p)
	else:
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != close): p.pos = p.pos + 1
		int end = p.pos
		while (end > start && p.doc.source[end - 1] == 32): end = end - 1
		text = str_copy_range(p.doc.source, start, end)
	if (mm_peek(p) == close): p.pos = p.pos + 1
	else: mm_error(p.doc, p.pos, c"expected closing label delimiter")
	return text

int mm_direction(mm_parser* p):
	char* dir = mm_identifier(p)
	int ok = strcmp(dir, c"TB") == 0 || strcmp(dir, c"TD") == 0 || strcmp(dir, c"BT") == 0 || strcmp(dir, c"LR") == 0 || strcmp(dir, c"RL") == 0
	if (ok):
		free(p.doc.direction)
		p.doc.direction = dir
	else:
		free(dir)
		mm_error(p.doc, p.pos, c"expected direction TB, TD, BT, LR or RL")
	return ok

# Accessible metadata shared by statement-based diagram parsers.
int mm_metadata(mm_parser* p):
	int start = p.pos
	int description = 0
	if (mm_match(p, c"accTitle")):
		if (mm_id_char(mm_peek(p))):
			p.pos = start
			return 0
	else if (mm_match(p, c"accDescr")):
		if (mm_id_char(mm_peek(p))):
			p.pos = start
			return 0
		description = 1
	else: return 0
	mm_space(p)
	int block = 0
	if (description && mm_match(p, c"{")): block = 1
	else if (mm_match(p, c":") == 0):
		mm_error(p.doc, p.pos, c"expected accessibility colon or description block")
		return 1
	mm_space(p)
	start = p.pos
	while (mm_peek(p) != 0):
		if (block && mm_peek(p) == '}'): break
		if (block == 0 && (mm_peek(p) == 10 || mm_peek(p) == ';')): break
		p.pos = p.pos + 1
	int end = p.pos
	while (end > start && (p.doc.source[end - 1] & 255) <= 32): end = end - 1
	char* value = str_copy_range(p.doc.source, start, end)
	if (description):
		free(p.doc.accessibility_description)
		p.doc.accessibility_description = value
	else:
		free(p.doc.accessibility_title)
		p.doc.accessibility_title = value
	if (block && mm_match(p, c"}") == 0): mm_error(p.doc, p.pos, c"unterminated accessibility description")
	return 1
