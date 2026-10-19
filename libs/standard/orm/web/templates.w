# w-orm web templates (unit U4.3, docs/projects/orm/u4_3.md): a small
# Django-flavoured template language, autoescaped, loaded from a directory
# and cached.
#
#   orm_tpl_engine* e = orm_tpl_engine_new(c"tests/orm/templates")
#   orm_tpl_ctx* ctx = orm_tpl_ctx_new()
#   orm_tpl_set(ctx, c"books", orm_tpl_result(ctx, r))
#   char* html = orm_tpl_render(e, c"book_list.html", ctx)   # owned, 0 = orm_tpl_error(e)
#   orm_tpl_ctx_free(ctx)
#
# Syntax:
#   {{ book.title }}                 variable, HTML-escaped
#   {{ body|safe }}                  filters: safe escape upper lower title
#                                    length default:"x" join:", "
#                                    linebreaksbr truncatechars:n urlencode yesno:"a,b"
#   {% if a and not b %} {% elif x == "y" %} {% else %} {% endif %}
#                                    and / or / not, == != < > <= >= (ints compare
#                                    as numbers, everything else as text)
#   {% for b in books %} {{ forloop.counter }} {% empty %} {% endfor %}
#   {% include "row.html" %}
#   {% extends "base.html" %} {% block content %}...{% endblock %}
#   {% url "book_detail" id=book.id %}     through the context's url hook
#   {% csrf_token %} / {{ csrf_token }}    through the context's csrf hook
#   {# comment #}
#
# Lookups (a.b.c): maps by key, lists by index ("items.0") or "length",
# ORM rows through their descriptor: column fields by name, "pk",
# "<fk>_id", a loaded FK as the related row (an FK that was not
# select_related resolves to null: templates never query), M2M / reverse
# lists as filled by prefetch_related, and queryset annotations by name.
# A missing name is null and renders as "".
#
# Values live in the context's arena and are freed with orm_tpl_ctx_free.
import libs.standard.orm.load
import libs.standard.web.urlparse
import structures.string
import lib.str
import lib.file
import lib.path
import lib.container


const int ORM_TV_NULL = 0
const int ORM_TV_STR = 1
const int ORM_TV_INT = 2
const int ORM_TV_BOOL = 3
const int ORM_TV_LIST = 4
const int ORM_TV_MAP = 5
const int ORM_TV_ROW = 6


struct orm_tpl_value:
	int kind
	char* text                          # STR (arena-owned)
	int number                          # INT / BOOL
	int safe                            # STR already HTML (not escaped again)
	list[orm_tpl_value*] items          # LIST
	map[char*, orm_tpl_value*] fields   # MAP
	orm_model_desc* model               # ROW
	void* row                           # ROW


# (ctx, route name, params) -> owned path, or 0 when nothing matches.
type orm_tpl_url_fn = fn(void*, char*, map[char*, char*]) -> char*
# (ctx) -> borrowed CSRF token, or 0.
type orm_tpl_csrf_fn = fn(void*) -> char*


struct orm_tpl_ctx:
	orm_tpl_value* root
	list[orm_tpl_value*] scopes         # innermost last; root first
	list[orm_tpl_value*] arena
	list[char*] strings
	orm_tpl_url_fn* url_fn
	void* url_ctx
	orm_tpl_csrf_fn* csrf_fn
	void* csrf_ctx


# ---------------------------------------------------------------------------
# HTML escaping

# Owned copy of s with & < > " ' escaped (Django's escape()).
char* orm_html_escape(char* s):
	string_builder* out = string_new()
	if (s != 0):
		int i = 0
		while (s[i] != 0):
			int ch = s[i] & 255
			if (ch == '&'): string_append(out, c"&amp;")
			else if (ch == '<'): string_append(out, c"&lt;")
			else if (ch == '>'): string_append(out, c"&gt;")
			else if (ch == '"'): string_append(out, c"&quot;")
			else if (ch == 39): string_append(out, c"&#x27;")
			else: string_append_char(out, ch)
			i = i + 1
	char* text = out.data
	free(out)
	return text


void orm_html_append_escaped(string_builder* out, char* s):
	char* e = orm_html_escape(s)
	string_append(out, e)
	free(e)


char* orm_tpl_concat3(char* a, char* b, char* c):
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	string_append(s, c)
	char* out = s.data
	free(s)
	return out


# ---------------------------------------------------------------------------
# Context and values

orm_tpl_value* orm_tpl_value_new(orm_tpl_ctx* ctx, int kind):
	orm_tpl_value* v = new orm_tpl_value()
	v.kind = kind
	ctx.arena.push(v)
	return v


char* orm_tpl_keep(orm_tpl_ctx* ctx, char* owned):
	if (owned != 0): ctx.strings.push(owned)
	return owned


orm_tpl_value* orm_tpl_map(orm_tpl_ctx* ctx):
	orm_tpl_value* v = orm_tpl_value_new(ctx, ORM_TV_MAP)
	v.fields = new map[char*, orm_tpl_value*]
	return v


orm_tpl_value* orm_tpl_list(orm_tpl_ctx* ctx):
	orm_tpl_value* v = orm_tpl_value_new(ctx, ORM_TV_LIST)
	v.items = new list[orm_tpl_value*]
	return v


orm_tpl_ctx* orm_tpl_ctx_new():
	orm_tpl_ctx* ctx = new orm_tpl_ctx()
	ctx.arena = new list[orm_tpl_value*]
	ctx.strings = new list[char*]
	ctx.scopes = new list[orm_tpl_value*]
	ctx.root = orm_tpl_map(ctx)
	ctx.scopes.push(ctx.root)
	return ctx


void orm_tpl_ctx_free(orm_tpl_ctx* ctx):
	if (ctx == 0): return
	for orm_tpl_value* v in ctx.arena:
		if (v.kind == ORM_TV_LIST): v.items.free()
		if (v.kind == ORM_TV_MAP): map_free[char*, orm_tpl_value*](v.fields)
		free(cast(void*, v))
	ctx.arena.free()
	for char* s in ctx.strings: free(s)
	ctx.strings.free()
	ctx.scopes.free()
	free(cast(void*, ctx))


orm_tpl_value* orm_tpl_null(orm_tpl_ctx* ctx):
	return orm_tpl_value_new(ctx, ORM_TV_NULL)


# A copy of s (0 = null).
orm_tpl_value* orm_tpl_str(orm_tpl_ctx* ctx, char* s):
	if (s == 0): return orm_tpl_null(ctx)
	orm_tpl_value* v = orm_tpl_value_new(ctx, ORM_TV_STR)
	v.text = orm_tpl_keep(ctx, strclone(s))
	return v


# Takes ownership of s (malloc'd).
orm_tpl_value* orm_tpl_str_take(orm_tpl_ctx* ctx, char* s):
	if (s == 0): return orm_tpl_null(ctx)
	orm_tpl_value* v = orm_tpl_value_new(ctx, ORM_TV_STR)
	v.text = orm_tpl_keep(ctx, s)
	return v


# Trusted HTML (copied), rendered without escaping.
orm_tpl_value* orm_tpl_safe(orm_tpl_ctx* ctx, char* html):
	orm_tpl_value* v = orm_tpl_str(ctx, html)
	if (v.kind == ORM_TV_STR): v.safe = 1
	return v


orm_tpl_value* orm_tpl_int(orm_tpl_ctx* ctx, int n):
	orm_tpl_value* v = orm_tpl_value_new(ctx, ORM_TV_INT)
	v.number = n
	return v


orm_tpl_value* orm_tpl_bool(orm_tpl_ctx* ctx, int b):
	orm_tpl_value* v = orm_tpl_value_new(ctx, ORM_TV_BOOL)
	v.number = b != 0
	return v


# An ORM row (borrowed: it must outlive the render).
orm_tpl_value* orm_tpl_row(orm_tpl_ctx* ctx, orm_model_desc* m, void* row):
	if (row == 0): return orm_tpl_null(ctx)
	orm_tpl_value* v = orm_tpl_value_new(ctx, ORM_TV_ROW)
	v.model = m
	v.row = row
	return v


orm_tpl_value* orm_tpl_rows(orm_tpl_ctx* ctx, orm_model_desc* m, list[void*] rows):
	orm_tpl_value* l = orm_tpl_list(ctx)
	if (rows == 0): return l
	for void* row in rows: l.items.push(orm_tpl_row(ctx, m, row))
	return l


# The rows of an evaluated queryset (borrowed).
orm_tpl_value* orm_tpl_result(orm_tpl_ctx* ctx, orm_result* r):
	if (r == 0): return orm_tpl_list(ctx)
	return orm_tpl_rows(ctx, r.model, r.rows)


void orm_tpl_push(orm_tpl_value* l, orm_tpl_value* item):
	l.items.push(item)


void orm_tpl_put(orm_tpl_value* m, char* key, orm_tpl_value* v):
	m.fields[key] = v


void orm_tpl_put_str(orm_tpl_ctx* ctx, orm_tpl_value* m, char* key, char* s):
	m.fields[key] = orm_tpl_str(ctx, s)


# Sets a top-level name.
void orm_tpl_set(orm_tpl_ctx* ctx, char* key, orm_tpl_value* v):
	ctx.root.fields[key] = v


void orm_tpl_set_str(orm_tpl_ctx* ctx, char* key, char* s):
	orm_tpl_set(ctx, key, orm_tpl_str(ctx, s))


void orm_tpl_set_int(orm_tpl_ctx* ctx, char* key, int n):
	orm_tpl_set(ctx, key, orm_tpl_int(ctx, n))


void orm_tpl_set_url(orm_tpl_ctx* ctx, orm_tpl_url_fn* fn, void* fn_ctx):
	ctx.url_fn = fn
	ctx.url_ctx = fn_ctx


void orm_tpl_set_csrf(orm_tpl_ctx* ctx, orm_tpl_csrf_fn* fn, void* fn_ctx):
	ctx.csrf_fn = fn
	ctx.csrf_ctx = fn_ctx


int orm_tpl_truthy(orm_tpl_value* v):
	if (v == 0): return 0
	int k = v.kind
	if (k == ORM_TV_STR): return v.text[0] != 0
	if (k == ORM_TV_INT || k == ORM_TV_BOOL): return v.number != 0
	if (k == ORM_TV_LIST): return v.items.length > 0
	if (k == ORM_TV_MAP): return v.fields.length > 0
	if (k == ORM_TV_ROW): return 1
	return 0


# Owned text of a value as it prints (before escaping): null "", ints in
# decimal, booleans True/False, rows "<Model> object (<pk>)", lists and
# maps "".
char* orm_tpl_text(orm_tpl_value* v):
	if (v == 0): return strclone(c"")
	int k = v.kind
	if (k == ORM_TV_STR): return strclone(v.text)
	if (k == ORM_TV_INT): return itoa(v.number)
	if (k == ORM_TV_BOOL):
		if (v.number): return strclone(c"True")
		return strclone(c"False")
	if (k == ORM_TV_ROW):
		string_builder* s = string_new()
		string_append(s, v.model.name)
		string_append(s, c" object (")
		orm_field_desc* pk = orm_model_pk(v.model)
		if (pk != 0): string_append_int(s, orm_slot_get(v.row, pk.offset))
		string_append(s, c")")
		char* out = s.data
		free(s)
		return out
	return strclone(c"")


# The value of field fd on an ORM row.
orm_tpl_value* orm_tpl_field_value(orm_tpl_ctx* ctx, orm_field_desc* fd, void* row):
	int k = fd.kind
	if (k == ORM_M2M || k == ORM_REVERSE_FK):
		orm_tpl_value* l = orm_tpl_list(ctx)
		if (fd.rel_offset < 0): return l
		list[void*] rel = cast(list[void*], orm_slot_get(row, fd.rel_offset))
		if (rel == 0): return l
		for void* item in rel: l.items.push(orm_tpl_row(ctx, orm_field_target(fd), item))
		return l
	if (fd.offset < 0): return orm_tpl_null(ctx)
	if (k == ORM_FK):
		if (fd.rel_offset < 0): return orm_tpl_null(ctx)
		void* target = cast(void*, orm_slot_get(row, fd.rel_offset))
		return orm_tpl_row(ctx, orm_field_target(fd), target)
	int raw = orm_slot_get(row, fd.offset)
	if (orm_field_is_text_backed(fd)): return orm_tpl_str(ctx, cast(char*, raw))
	if (fd.null_offset >= 0 && orm_slot_get(row, fd.null_offset) != 0): return orm_tpl_null(ctx)
	if (k == ORM_BOOL): return orm_tpl_bool(ctx, raw)
	return orm_tpl_int(ctx, raw)


# Attribute `name` of an ORM row: a field, "pk", "<fk>_id" or an
# annotation; null when none matches.
orm_tpl_value* orm_tpl_row_attr(orm_tpl_ctx* ctx, orm_model_desc* m, void* row, char* name):
	orm_field_desc* fd = orm_model_field(m, name)
	if (fd == 0 && strcmp(name, c"pk") == 0): fd = orm_model_pk(m)
	if (fd != 0): return orm_tpl_field_value(ctx, fd, row)
	for orm_field_desc* f in m.fields:
		if (f.kind == ORM_FK && f.column != 0 && strcmp(f.column, name) == 0):
			return orm_tpl_int(ctx, orm_slot_get(row, f.offset))
	char* ann = orm_row_annotation(m, row, name)
	if (ann != 0): return orm_tpl_str(ctx, ann)
	return orm_tpl_null(ctx)


int orm_tpl_all_digits(char* s):
	if (s == 0 || s[0] == 0): return 0
	int i = 0
	while (s[i] != 0):
		if (s[i] < '0' || s[i] > '9'): return 0
		i = i + 1
	return 1


# One step of a dotted lookup.
orm_tpl_value* orm_tpl_attr(orm_tpl_ctx* ctx, orm_tpl_value* v, char* name):
	if (v == 0): return orm_tpl_null(ctx)
	int k = v.kind
	if (k == ORM_TV_MAP): return v.fields.get(name, orm_tpl_null(ctx))
	if (k == ORM_TV_ROW): return orm_tpl_row_attr(ctx, v.model, v.row, name)
	if (k == ORM_TV_LIST):
		if (strcmp(name, c"length") == 0): return orm_tpl_int(ctx, v.items.length)
		if (orm_tpl_all_digits(name)):
			int i = atoi(name)
			if (i < v.items.length): return v.items[i]
	return orm_tpl_null(ctx)


# The value bound to `name` in the innermost scope that has it.
orm_tpl_value* orm_tpl_lookup_name(orm_tpl_ctx* ctx, char* name):
	int i = ctx.scopes.length - 1
	while (i >= 0):
		orm_tpl_value* scope = ctx.scopes[i]
		if (name in scope.fields): return scope.fields[name]
		i = i - 1
	if (strcmp(name, c"csrf_token") == 0 && ctx.csrf_fn != 0):
		return orm_tpl_str(ctx, ctx.csrf_fn(ctx.csrf_ctx))
	return orm_tpl_null(ctx)


# ---------------------------------------------------------------------------
# Compiled templates

const int ORM_TN_TEXT = 1
const int ORM_TN_VAR = 2
const int ORM_TN_IF = 3
const int ORM_TN_FOR = 4
const int ORM_TN_INCLUDE = 5
const int ORM_TN_BLOCK = 6
const int ORM_TN_CSRF = 7
const int ORM_TN_URL = 8

const int ORM_TE_PATH = 1
const int ORM_TE_STR = 2
const int ORM_TE_INT = 3
const int ORM_TE_NOT = 4
const int ORM_TE_AND = 5
const int ORM_TE_OR = 6
const int ORM_TE_CMP = 7
const int ORM_TE_CONST = 8     # True / False / None (number 1 / 0 / -1)


struct orm_tpl_expr:
	int kind
	char* text                 # STR literal, CMP operator
	int number
	list[char*] path           # PATH
	list[void*] filters        # orm_tpl_filter*
	void* a                    # orm_tpl_expr*
	void* b


struct orm_tpl_filter:
	char* name
	orm_tpl_expr* arg          # 0 when none


struct orm_tpl_node:
	int kind
	int line
	char* text                 # TEXT
	orm_tpl_expr* expr         # VAR, IF condition, FOR iterable
	char* name                 # FOR loop variable, BLOCK name, INCLUDE template, URL route
	list[void*] body           # orm_tpl_node*
	list[void*] alt            # IF else branch / FOR empty branch
	list[char*] keys           # URL keyword names
	list[orm_tpl_expr*] args   # URL keyword values


struct orm_tpl:
	char* name
	char* parent               # extends target, or 0
	list[orm_tpl_node*] nodes
	map[char*, orm_tpl_node*] blocks
	list[void*] all_nodes      # every node, for freeing
	list[orm_tpl_expr*] all_exprs
	list[char*] strings


struct orm_tpl_engine:
	char* dir
	map[char*, orm_tpl*] cache
	char* error                # last compile or render error (owned), "" when none
	int loads                  # template files read (cache misses)
	int max_depth              # include / extends nesting limit


# ---------------------------------------------------------------------------
# Template source -> raw tokens

const int ORM_TT_TEXT = 1
const int ORM_TT_VAR = 2
const int ORM_TT_TAG = 3


struct orm_tpl_tok:
	int kind
	char* text                 # owned: literal text or the trimmed inside of {{ }} / {% %}
	int line


struct orm_tpl_parser:
	orm_tpl* tpl
	list[orm_tpl_tok*] toks
	int pos
	char* error                # owned "name:line: message"


int orm_tpl_parser_fail(orm_tpl_parser* p, int line, char* a, char* b):
	if (p.error != 0): return 0
	string_builder* s = string_new()
	string_append(s, p.tpl.name)
	string_append_char(s, ':')
	string_append_int(s, line)
	string_append(s, c": ")
	string_append(s, a)
	if (b != 0): string_append(s, b)
	p.error = s.data
	free(s)
	return 0


int orm_tpl_count_lines(char* s, int start, int end):
	int n = 0
	for i in range(start, end):
		if (s[i] == '\n'): n = n + 1
	return n


int orm_tpl_find(char* s, int from, char* needle):
	int i = index_of(s + from, needle)
	if (i < 0): return -1
	return from + i


# Splits source into text / {{ }} / {% %} tokens ({# #} dropped).
int orm_tpl_lex(orm_tpl_parser* p, char* src):
	int n = strlen(src)
	int pos = 0
	int line = 1
	while (pos < n):
		int open = orm_tpl_find(src, pos, c"{")
		while (open >= 0 && open + 1 < n && src[open + 1] != '{' && src[open + 1] != '%' && src[open + 1] != '#'):
			open = orm_tpl_find(src, open + 1, c"{")
		if (open < 0 || open + 1 >= n): open = n
		if (open > pos):
			orm_tpl_tok* t = new orm_tpl_tok()
			t.kind = ORM_TT_TEXT
			t.text = substring(src, pos, open)
			t.line = line
			p.toks.push(t)
			line = line + orm_tpl_count_lines(src, pos, open)
		if (open >= n): return 1
		char kind = src[open + 1]
		char* close = c"}}"
		if (kind == '%'): close = c"%}"
		if (kind == '#'): close = c"#}"
		int end = orm_tpl_find(src, open + 2, close)
		if (end < 0):
			if (kind == '%'): return orm_tpl_parser_fail(p, line, c"unclosed tag", 0)
			if (kind == '#'): return orm_tpl_parser_fail(p, line, c"unclosed comment", 0)
			return orm_tpl_parser_fail(p, line, c"unclosed variable", 0)
		if (kind != '#'):
			orm_tpl_tok* t2 = new orm_tpl_tok()
			t2.kind = ORM_TT_VAR
			if (kind == '%'): t2.kind = ORM_TT_TAG
			char* inner = substring(src, open + 2, end)
			t2.text = strip(inner)
			free(inner)
			t2.line = line
			p.toks.push(t2)
		line = line + orm_tpl_count_lines(src, open, end)
		pos = end + 2
	return 1


# ---------------------------------------------------------------------------
# Tag contents -> words

const int ORM_TW_WORD = 1
const int ORM_TW_STR = 2
const int ORM_TW_OP = 3
const int ORM_TW_PUNCT = 4


struct orm_tpl_word:
	int kind
	char* text


struct orm_tpl_words:
	list[orm_tpl_word*] items
	int pos
	int line


void orm_tpl_words_free(orm_tpl_words* w):
	for orm_tpl_word* it in w.items:
		free(it.text)
		free(cast(void*, it))
	w.items.free()
	free(cast(void*, w))


int orm_tpl_word_char(int ch):
	return isalnum(ch) || ch == '_' || ch == '.' || ch == '-'


orm_tpl_words* orm_tpl_split(orm_tpl_parser* p, char* s, int line):
	orm_tpl_words* w = new orm_tpl_words()
	w.items = new list[orm_tpl_word*]
	w.line = line
	int i = 0
	int n = strlen(s)
	while (i < n):
		int ch = s[i] & 255
		if (isspace(ch)):
			i = i + 1
			continue
		orm_tpl_word* it = new orm_tpl_word()
		if (ch == '"' || ch == 39):
			int j = i + 1
			while (j < n && (s[j] & 255) != ch): j = j + 1
			if (j >= n):
				free(cast(void*, it))
				orm_tpl_parser_fail(p, line, c"unterminated string in: ", s)
				return w
			it.kind = ORM_TW_STR
			it.text = substring(s, i + 1, j)
			i = j + 1
		else if (ch == '=' || ch == '!' || ch == '<' || ch == '>'):
			int j2 = i + 1
			if (j2 < n && s[j2] == '='): j2 = j2 + 1
			it.kind = ORM_TW_OP
			it.text = substring(s, i, j2)
			if (strcmp(it.text, c"=") == 0): it.kind = ORM_TW_PUNCT
			i = j2
		else if (ch == '|' || ch == ':' || ch == ','):
			it.kind = ORM_TW_PUNCT
			it.text = substring(s, i, i + 1)
			i = i + 1
		else if (orm_tpl_word_char(ch)):
			int j3 = i
			while (j3 < n && orm_tpl_word_char(s[j3] & 255)): j3 = j3 + 1
			it.kind = ORM_TW_WORD
			it.text = substring(s, i, j3)
			i = j3
		else:
			free(cast(void*, it))
			orm_tpl_parser_fail(p, line, c"unexpected character in: ", s)
			return w
		w.items.push(it)
	return w


orm_tpl_word* orm_tpl_peek(orm_tpl_words* w):
	if (w.pos >= w.items.length): return 0
	return w.items[w.pos]


int orm_tpl_peek_is(orm_tpl_words* w, int kind, char* text):
	orm_tpl_word* it = orm_tpl_peek(w)
	if (it == 0 || it.kind != kind): return 0
	return text == 0 || strcmp(it.text, text) == 0


# ---------------------------------------------------------------------------
# Expressions

orm_tpl_expr* orm_tpl_expr_new(orm_tpl_parser* p, int kind):
	orm_tpl_expr* e = new orm_tpl_expr()
	e.kind = kind
	e.filters = new list[void*]
	p.tpl.all_exprs.push(e)
	return e


char* orm_tpl_own(orm_tpl_parser* p, char* s):
	p.tpl.strings.push(s)
	return s


int orm_tpl_filter_known(char* name, int* takes_arg):
	takes_arg[0] = 0
	if (strcmp(name, c"safe") == 0 || strcmp(name, c"escape") == 0 || strcmp(name, c"upper") == 0): return 1
	if (strcmp(name, c"lower") == 0 || strcmp(name, c"title") == 0 || strcmp(name, c"length") == 0): return 1
	if (strcmp(name, c"linebreaksbr") == 0 || strcmp(name, c"urlencode") == 0): return 1
	takes_arg[0] = 1
	if (strcmp(name, c"default") == 0 || strcmp(name, c"join") == 0 || strcmp(name, c"truncatechars") == 0): return 1
	if (strcmp(name, c"yesno") == 0): return 1
	return 0


# primary: a dotted name, "string", integer, True / False / None.
orm_tpl_expr* orm_tpl_parse_primary(orm_tpl_parser* p, orm_tpl_words* w):
	orm_tpl_word* it = orm_tpl_peek(w)
	if (it == 0):
		orm_tpl_parser_fail(p, w.line, c"expected a value", 0)
		return 0
	if (it.kind == ORM_TW_STR):
		w.pos = w.pos + 1
		orm_tpl_expr* s = orm_tpl_expr_new(p, ORM_TE_STR)
		s.text = orm_tpl_own(p, strclone(it.text))
		return s
	if (it.kind != ORM_TW_WORD):
		orm_tpl_parser_fail(p, w.line, c"unexpected ", it.text)
		return 0
	w.pos = w.pos + 1
	char* t = it.text
	if (orm_tpl_all_digits(t) || (t[0] == '-' && orm_tpl_all_digits(t + 1))):
		orm_tpl_expr* n = orm_tpl_expr_new(p, ORM_TE_INT)
		n.number = atoi(t)
		return n
	if (strcmp(t, c"True") == 0 || strcmp(t, c"False") == 0 || strcmp(t, c"None") == 0):
		orm_tpl_expr* c = orm_tpl_expr_new(p, ORM_TE_CONST)
		if (t[0] == 'T'): c.number = 1
		else if (t[0] == 'N'): c.number = -1
		return c
	orm_tpl_expr* e = orm_tpl_expr_new(p, ORM_TE_PATH)
	e.path = split(t, '.')
	for char* part in e.path:
		orm_tpl_own(p, part)
		if (part[0] == 0):
			orm_tpl_parser_fail(p, w.line, c"bad variable name: ", t)
			return 0
	return e


# primary ('|' filter (':' primary)?)*
orm_tpl_expr* orm_tpl_parse_filtered(orm_tpl_parser* p, orm_tpl_words* w):
	orm_tpl_expr* e = orm_tpl_parse_primary(p, w)
	if (e == 0): return 0
	while (orm_tpl_peek_is(w, ORM_TW_PUNCT, c"|")):
		w.pos = w.pos + 1
		orm_tpl_word* name = orm_tpl_peek(w)
		if (name == 0 || name.kind != ORM_TW_WORD):
			orm_tpl_parser_fail(p, w.line, c"expected a filter name", 0)
			return 0
		w.pos = w.pos + 1
		int takes = 0
		if (orm_tpl_filter_known(name.text, &takes) == 0):
			orm_tpl_parser_fail(p, w.line, c"unknown filter: ", name.text)
			return 0
		orm_tpl_filter* f = new orm_tpl_filter()
		f.name = orm_tpl_own(p, strclone(name.text))
		if (orm_tpl_peek_is(w, ORM_TW_PUNCT, c":")):
			w.pos = w.pos + 1
			f.arg = orm_tpl_parse_primary(p, w)
			if (f.arg == 0):
				free(cast(void*, f))
				return 0
		e.filters.push(cast(void*, f))
		if (takes && f.arg == 0):
			orm_tpl_parser_fail(p, w.line, c"filter needs an argument: ", f.name)
			return 0
	return e


orm_tpl_expr* orm_tpl_parse_or(orm_tpl_parser* p, orm_tpl_words* w);


orm_tpl_expr* orm_tpl_parse_not(orm_tpl_parser* p, orm_tpl_words* w):
	if (orm_tpl_peek_is(w, ORM_TW_WORD, c"not")):
		w.pos = w.pos + 1
		orm_tpl_expr* inner = orm_tpl_parse_not(p, w)
		if (inner == 0): return 0
		orm_tpl_expr* n = orm_tpl_expr_new(p, ORM_TE_NOT)
		n.a = cast(void*, inner)
		return n
	orm_tpl_expr* left = orm_tpl_parse_filtered(p, w)
	if (left == 0): return 0
	if (orm_tpl_peek_is(w, ORM_TW_OP, 0)):
		orm_tpl_word* op = orm_tpl_peek(w)
		if (strcmp(op.text, c"!") == 0):
			orm_tpl_parser_fail(p, w.line, c"unknown operator !", 0)
			return 0
		w.pos = w.pos + 1
		orm_tpl_expr* right = orm_tpl_parse_filtered(p, w)
		if (right == 0): return 0
		orm_tpl_expr* c = orm_tpl_expr_new(p, ORM_TE_CMP)
		c.text = orm_tpl_own(p, strclone(op.text))
		c.a = cast(void*, left)
		c.b = cast(void*, right)
		return c
	return left


orm_tpl_expr* orm_tpl_parse_and(orm_tpl_parser* p, orm_tpl_words* w):
	orm_tpl_expr* left = orm_tpl_parse_not(p, w)
	while (left != 0 && orm_tpl_peek_is(w, ORM_TW_WORD, c"and")):
		w.pos = w.pos + 1
		orm_tpl_expr* right = orm_tpl_parse_not(p, w)
		if (right == 0): return 0
		orm_tpl_expr* e = orm_tpl_expr_new(p, ORM_TE_AND)
		e.a = cast(void*, left)
		e.b = cast(void*, right)
		left = e
	return left


orm_tpl_expr* orm_tpl_parse_or(orm_tpl_parser* p, orm_tpl_words* w):
	orm_tpl_expr* left = orm_tpl_parse_and(p, w)
	while (left != 0 && orm_tpl_peek_is(w, ORM_TW_WORD, c"or")):
		w.pos = w.pos + 1
		orm_tpl_expr* right = orm_tpl_parse_and(p, w)
		if (right == 0): return 0
		orm_tpl_expr* e = orm_tpl_expr_new(p, ORM_TE_OR)
		e.a = cast(void*, left)
		e.b = cast(void*, right)
		left = e
	return left


int orm_tpl_expect_end(orm_tpl_parser* p, orm_tpl_words* w, char* tag):
	orm_tpl_word* extra = orm_tpl_peek(w)
	if (extra == 0): return 1
	string_builder* s = string_new()
	string_append(s, c"unexpected '")
	string_append(s, extra.text)
	string_append(s, c"' in ")
	string_append(s, tag)
	orm_tpl_parser_fail(p, w.line, s.data, 0)
	string_free(s)
	return 0


# ---------------------------------------------------------------------------
# Nodes

orm_tpl_node* orm_tpl_node_new(orm_tpl_parser* p, int kind, int line):
	orm_tpl_node* n = new orm_tpl_node()
	n.kind = kind
	n.line = line
	n.body = new list[void*]
	n.alt = new list[void*]
	p.tpl.all_nodes.push(cast(void*, n))
	return n


char* orm_tpl_tag_name(char* text):
	int i = 0
	while (text[i] != 0 && isspace(text[i]) == 0): i = i + 1
	return substring(text, 0, i)


# Parses nodes into `out` until a tag whose first word is in `stops`
# (comma-separated, e.g. "elif,else,endif"); returns that tag's token
# (not consumed past), or 0 at end of input. *ok is 0 after an error.
orm_tpl_tok* orm_tpl_parse_nodes(orm_tpl_parser* p, list[void*] out, char* stops, int* ok);


int orm_tpl_name_in(char* name, char* list_text):
	if (list_text == 0): return 0
	list[char*] names = split(list_text, ',')
	int found = 0
	for char* n in names:
		if (strcmp(n, name) == 0): found = 1
		free(n)
	names.free()
	return found


# {% if %} ... {% elif %} ... {% else %} ... {% endif %}; tok is the
# opening if/elif tag.
orm_tpl_node* orm_tpl_parse_if(orm_tpl_parser* p, orm_tpl_tok* tok, char* rest):
	orm_tpl_node* n = orm_tpl_node_new(p, ORM_TN_IF, tok.line)
	orm_tpl_words* w = orm_tpl_split(p, rest, tok.line)
	if (p.error == 0):
		if (w.items.length == 0): orm_tpl_parser_fail(p, tok.line, c"if needs a condition", 0)
		else:
			n.expr = orm_tpl_parse_or(p, w)
			if (n.expr != 0): orm_tpl_expect_end(p, w, c"if")
	orm_tpl_words_free(w)
	if (p.error != 0): return 0
	int ok = 1
	orm_tpl_tok* end = orm_tpl_parse_nodes(p, n.body, c"elif,else,endif", &ok)
	if (ok == 0): return 0
	if (end == 0):
		orm_tpl_parser_fail(p, tok.line, c"unclosed if", 0)
		return 0
	char* name = orm_tpl_tag_name(end.text)
	if (strcmp(name, c"elif") == 0):
		orm_tpl_node* chained = orm_tpl_parse_if(p, end, end.text + 4)
		free(name)
		if (chained == 0): return 0
		n.alt.push(cast(void*, chained))
		return n
	if (strcmp(name, c"else") == 0):
		free(name)
		orm_tpl_tok* fin = orm_tpl_parse_nodes(p, n.alt, c"endif", &ok)
		if (ok == 0): return 0
		if (fin == 0):
			orm_tpl_parser_fail(p, tok.line, c"unclosed if", 0)
			return 0
		return n
	free(name)
	return n


# {% for x in expr %} ... {% empty %} ... {% endfor %}
orm_tpl_node* orm_tpl_parse_for(orm_tpl_parser* p, orm_tpl_tok* tok, char* rest):
	orm_tpl_node* n = orm_tpl_node_new(p, ORM_TN_FOR, tok.line)
	orm_tpl_words* w = orm_tpl_split(p, rest, tok.line)
	if (p.error == 0):
		orm_tpl_word* var = orm_tpl_peek(w)
		if (var == 0 || var.kind != ORM_TW_WORD || index_of(var.text, c".") >= 0):
			orm_tpl_parser_fail(p, tok.line, c"for needs 'for name in value'", 0)
		else:
			n.name = orm_tpl_own(p, strclone(var.text))
			w.pos = w.pos + 1
			if (orm_tpl_peek_is(w, ORM_TW_WORD, c"in") == 0): orm_tpl_parser_fail(p, tok.line, c"for needs 'for name in value'", 0)
			else:
				w.pos = w.pos + 1
				n.expr = orm_tpl_parse_filtered(p, w)
				if (n.expr != 0): orm_tpl_expect_end(p, w, c"for")
	orm_tpl_words_free(w)
	if (p.error != 0): return 0
	int ok = 1
	orm_tpl_tok* end = orm_tpl_parse_nodes(p, n.body, c"empty,endfor", &ok)
	if (ok == 0): return 0
	if (end == 0):
		orm_tpl_parser_fail(p, tok.line, c"unclosed for", 0)
		return 0
	if (starts_with(end.text, c"empty")):
		orm_tpl_tok* fin = orm_tpl_parse_nodes(p, n.alt, c"endfor", &ok)
		if (ok == 0): return 0
		if (fin == 0):
			orm_tpl_parser_fail(p, tok.line, c"unclosed for", 0)
			return 0
	return n


# The single quoted-string argument of include / extends.
char* orm_tpl_string_arg(orm_tpl_parser* p, char* rest, int line, char* tag):
	orm_tpl_words* w = orm_tpl_split(p, rest, line)
	char* out = 0
	if (p.error == 0):
		orm_tpl_word* it = orm_tpl_peek(w)
		if (it == 0 || it.kind != ORM_TW_STR || w.items.length != 1): orm_tpl_parser_fail(p, line, tag, c" needs one quoted template name")
		else: out = orm_tpl_own(p, strclone(it.text))
	orm_tpl_words_free(w)
	return out


# {% url "name" key=value ... %}
orm_tpl_node* orm_tpl_parse_url(orm_tpl_parser* p, orm_tpl_tok* tok, char* rest):
	orm_tpl_node* n = orm_tpl_node_new(p, ORM_TN_URL, tok.line)
	n.keys = new list[char*]
	n.args = new list[orm_tpl_expr*]
	orm_tpl_words* w = orm_tpl_split(p, rest, tok.line)
	if (p.error == 0):
		orm_tpl_word* name = orm_tpl_peek(w)
		if (name == 0 || name.kind != ORM_TW_STR): orm_tpl_parser_fail(p, tok.line, c"url needs a quoted route name", 0)
		else:
			n.name = orm_tpl_own(p, strclone(name.text))
			w.pos = w.pos + 1
			while (p.error == 0 && orm_tpl_peek(w) != 0):
				orm_tpl_word* key = orm_tpl_peek(w)
				if (key.kind != ORM_TW_WORD || w.pos + 1 >= w.items.length || w.items[w.pos + 1].kind != ORM_TW_PUNCT || strcmp(w.items[w.pos + 1].text, c"=") != 0):
					orm_tpl_parser_fail(p, tok.line, c"url arguments are name=value", 0)
				else:
					n.keys.push(orm_tpl_own(p, strclone(key.text)))
					w.pos = w.pos + 2
					orm_tpl_expr* v = orm_tpl_parse_filtered(p, w)
					if (v != 0): n.args.push(v)
	orm_tpl_words_free(w)
	if (p.error != 0): return 0
	return n


int orm_tpl_no_args(orm_tpl_parser* p, orm_tpl_tok* tok, char* rest, char* tag):
	char* r = strip(rest)
	int empty = r[0] == 0
	free(r)
	if (empty == 0): return orm_tpl_parser_fail(p, tok.line, tag, c" takes no arguments")
	return 1


void orm_tpl_collect_blocks(orm_tpl* t, list[void*] nodes);


orm_tpl_tok* orm_tpl_parse_nodes(orm_tpl_parser* p, list[void*] out, char* stops, int* ok):
	while (p.pos < p.toks.length):
		orm_tpl_tok* tok = p.toks[p.pos]
		p.pos = p.pos + 1
		if (tok.kind == ORM_TT_TEXT):
			orm_tpl_node* t = orm_tpl_node_new(p, ORM_TN_TEXT, tok.line)
			t.text = tok.text
			tok.text = 0
			out.push(cast(void*, t))
			continue
		if (tok.kind == ORM_TT_VAR):
			orm_tpl_words* w = orm_tpl_split(p, tok.text, tok.line)
			orm_tpl_node* v = orm_tpl_node_new(p, ORM_TN_VAR, tok.line)
			if (p.error == 0):
				if (w.items.length == 0): orm_tpl_parser_fail(p, tok.line, c"empty variable", 0)
				else:
					v.expr = orm_tpl_parse_filtered(p, w)
					if (v.expr != 0): orm_tpl_expect_end(p, w, c"variable")
			orm_tpl_words_free(w)
			if (p.error != 0):
				ok[0] = 0
				return 0
			out.push(cast(void*, v))
			continue
		char* name = orm_tpl_tag_name(tok.text)
		char* rest = tok.text + strlen(name)
		if (orm_tpl_name_in(name, stops)):
			free(name)
			return tok
		orm_tpl_node* node = 0
		if (strcmp(name, c"if") == 0): node = orm_tpl_parse_if(p, tok, rest)
		else if (strcmp(name, c"for") == 0): node = orm_tpl_parse_for(p, tok, rest)
		else if (strcmp(name, c"include") == 0):
			char* target = orm_tpl_string_arg(p, rest, tok.line, c"include")
			if (target != 0):
				node = orm_tpl_node_new(p, ORM_TN_INCLUDE, tok.line)
				node.name = target
		else if (strcmp(name, c"block") == 0):
			orm_tpl_words* bw = orm_tpl_split(p, rest, tok.line)
			if (p.error == 0):
				if (bw.items.length != 1 || bw.items[0].kind != ORM_TW_WORD): orm_tpl_parser_fail(p, tok.line, c"block needs one name", 0)
				else:
					node = orm_tpl_node_new(p, ORM_TN_BLOCK, tok.line)
					node.name = orm_tpl_own(p, strclone(bw.items[0].text))
			orm_tpl_words_free(bw)
			if (node != 0):
				if (node.name in p.tpl.blocks): orm_tpl_parser_fail(p, tok.line, c"block defined twice: ", node.name)
				else:
					p.tpl.blocks[node.name] = node
					int inner_ok = 1
					orm_tpl_tok* end = orm_tpl_parse_nodes(p, node.body, c"endblock", &inner_ok)
					if (inner_ok && end == 0): orm_tpl_parser_fail(p, tok.line, c"unclosed block ", node.name)
		else if (strcmp(name, c"extends") == 0):
			char* parent = orm_tpl_string_arg(p, rest, tok.line, c"extends")
			if (parent != 0):
				if (p.tpl.parent != 0 || stops != 0): orm_tpl_parser_fail(p, tok.line, c"extends must be the first tag", 0)
				else:
					for void* prev in out:
						orm_tpl_node* pn = cast(orm_tpl_node*, prev)
						if (pn.kind != ORM_TN_TEXT): orm_tpl_parser_fail(p, tok.line, c"extends must be the first tag", 0)
						else:
							char* stripped = strip(pn.text)
							if (stripped[0] != 0): orm_tpl_parser_fail(p, tok.line, c"extends must be the first tag", 0)
							free(stripped)
					p.tpl.parent = parent
			free(name)
			if (p.error != 0):
				ok[0] = 0
				return 0
			continue
		else if (strcmp(name, c"csrf_token") == 0):
			if (orm_tpl_no_args(p, tok, rest, c"csrf_token")): node = orm_tpl_node_new(p, ORM_TN_CSRF, tok.line)
		else if (strcmp(name, c"url") == 0): node = orm_tpl_parse_url(p, tok, rest)
		else: orm_tpl_parser_fail(p, tok.line, c"unknown or unexpected tag: ", name)
		free(name)
		if (p.error != 0 || node == 0):
			if (p.error == 0): orm_tpl_parser_fail(p, tok.line, c"bad tag", 0)
			ok[0] = 0
			return 0
		out.push(cast(void*, node))
	return 0


void orm_tpl_free(orm_tpl* t):
	if (t == 0): return
	for void* np in t.all_nodes:
		orm_tpl_node* n = cast(orm_tpl_node*, np)
		if (n.kind == ORM_TN_TEXT): free(n.text)
		n.body.free()
		n.alt.free()
		if (n.keys != 0): n.keys.free()
		if (n.args != 0): n.args.free()
		free(cast(void*, n))
	t.all_nodes.free()
	for orm_tpl_expr* e in t.all_exprs:
		for void* fp in e.filters: free(fp)
		e.filters.free()
		if (e.path != 0): e.path.free()
		free(cast(void*, e))
	t.all_exprs.free()
	for char* s in t.strings: free(s)
	t.strings.free()
	t.nodes.free()
	map_free[char*, orm_tpl_node*](t.blocks)
	free(t.name)
	free(cast(void*, t))


# Compiles source. Returns the template, or 0 with *error set to an owned
# "name:line: message".
orm_tpl* orm_tpl_compile(char* name, char* source, char** error):
	orm_tpl* t = new orm_tpl()
	t.name = strclone(name)
	t.nodes = new list[orm_tpl_node*]
	t.blocks = new map[char*, orm_tpl_node*]
	t.all_nodes = new list[void*]
	t.all_exprs = new list[orm_tpl_expr*]
	t.strings = new list[char*]
	orm_tpl_parser* p = new orm_tpl_parser()
	p.tpl = t
	p.toks = new list[orm_tpl_tok*]
	error[0] = 0
	list[void*] top = new list[void*]
	if (orm_tpl_lex(p, source)):
		int ok = 1
		orm_tpl_tok* stray = orm_tpl_parse_nodes(p, top, 0, &ok)
		if (ok && stray != 0): orm_tpl_parser_fail(p, stray.line, c"unexpected tag: ", stray.text)
	for void* np in top: t.nodes.push(cast(orm_tpl_node*, np))
	top.free()
	for orm_tpl_tok* tok in p.toks:
		if (tok.text != 0): free(tok.text)
		free(cast(void*, tok))
	p.toks.free()
	if (p.error != 0):
		error[0] = p.error
		free(cast(void*, p))
		orm_tpl_free(t)
		return 0
	free(cast(void*, p))
	return t


# ---------------------------------------------------------------------------
# Engine

orm_tpl_engine* orm_tpl_engine_new(char* dir):
	orm_tpl_engine* e = new orm_tpl_engine()
	e.dir = 0
	if (dir != 0): e.dir = strclone(dir)
	e.cache = new map[char*, orm_tpl*]
	e.error = strclone(c"")
	e.max_depth = 32
	return e


int orm_tpl_engine_fail(orm_tpl_engine* e, char* message):
	if (e.error != 0): free(e.error)
	e.error = strclone(message)
	return 0


int orm_tpl_engine_fail2(orm_tpl_engine* e, char* a, char* b):
	char* m = strjoin(a, b)
	orm_tpl_engine_fail(e, m)
	free(m)
	return 0


char* orm_tpl_error(orm_tpl_engine* e):
	return e.error


# Drops every cached template (they are re-read on next use).
void orm_tpl_engine_clear(orm_tpl_engine* e):
	for char* k, orm_tpl* t in e.cache: orm_tpl_free(t)
	map_free[char*, orm_tpl*](e.cache)
	e.cache = new map[char*, orm_tpl*]


void orm_tpl_engine_free(orm_tpl_engine* e):
	if (e == 0): return
	for char* k, orm_tpl* t in e.cache: orm_tpl_free(t)
	map_free[char*, orm_tpl*](e.cache)
	if (e.dir != 0): free(e.dir)
	free(e.error)
	free(cast(void*, e))


# Compiles source and caches it under name (replacing an older one).
# Returns 1, or 0 with orm_tpl_error.
int orm_tpl_add(orm_tpl_engine* e, char* name, char* source):
	char* err = 0
	orm_tpl* t = orm_tpl_compile(name, source, &err)
	if (t == 0):
		orm_tpl_engine_fail(e, err)
		free(err)
		return 0
	if (name in e.cache):
		orm_tpl_free(e.cache[name])
		e.cache.remove(name)
	e.cache[name] = t
	return 1


# The compiled template `name`: from the cache, else read from the
# engine's directory (names cannot leave it), compiled and cached. 0 with
# orm_tpl_error on failure.
orm_tpl* orm_tpl_get(orm_tpl_engine* e, char* name):
	if (name in e.cache): return e.cache[name]
	if (e.dir == 0):
		orm_tpl_engine_fail2(e, c"template not found: ", name)
		return 0
	char* path = path_join_within(e.dir, name)
	if (path == 0):
		orm_tpl_engine_fail2(e, c"template name escapes the template directory: ", name)
		return 0
	char* source = file_read_text(path)
	free(path)
	if (source == 0):
		orm_tpl_engine_fail2(e, c"template not found: ", name)
		return 0
	e.loads = e.loads + 1
	int ok = orm_tpl_add(e, name, source)
	free(source)
	if (ok == 0): return 0
	return e.cache[name]


# ---------------------------------------------------------------------------
# Rendering

struct orm_tpl_run:
	orm_tpl_engine* engine
	orm_tpl_ctx* ctx
	string_builder* out
	map[char*, orm_tpl_node*] blocks   # block overrides, child-most first
	int depth
	int failed
	char* where                        # name of the template being rendered


int orm_tpl_run_fail(orm_tpl_run* r, int line, char* a, char* b):
	if (r.failed): return 0
	r.failed = 1
	string_builder* s = string_new()
	string_append(s, r.where)
	string_append_char(s, ':')
	string_append_int(s, line)
	string_append(s, c": ")
	string_append(s, a)
	if (b != 0): string_append(s, b)
	orm_tpl_engine_fail(r.engine, s.data)
	string_free(s)
	return 0


orm_tpl_value* orm_tpl_eval(orm_tpl_run* r, orm_tpl_expr* e);


char* orm_tpl_title(char* s):
	char* out = strclone(s)
	int start = 1
	int i = 0
	while (out[i] != 0):
		int ch = out[i] & 255
		if (isalpha(ch)):
			if (start): out[i] = toupper(ch)
			else: out[i] = tolower(ch)
			start = 0
		else: start = isspace(ch) || ch == '-' || ch == '_'
		i = i + 1
	return out


orm_tpl_value* orm_tpl_apply_filter(orm_tpl_run* r, orm_tpl_value* v, orm_tpl_filter* f):
	orm_tpl_ctx* ctx = r.ctx
	char* n = f.name
	orm_tpl_value* arg = 0
	if (f.arg != 0): arg = orm_tpl_eval(r, f.arg)
	if (strcmp(n, c"safe") == 0):
		if (v.kind == ORM_TV_STR && v.safe): return v
		orm_tpl_value* s = orm_tpl_str_take(ctx, orm_tpl_text(v))
		s.safe = 1
		return s
	if (strcmp(n, c"escape") == 0):
		if (v.kind == ORM_TV_STR && v.safe): return v
		char* raw = orm_tpl_text(v)
		orm_tpl_value* e = orm_tpl_str_take(ctx, orm_html_escape(raw))
		free(raw)
		e.safe = 1
		return e
	if (strcmp(n, c"default") == 0):
		if (orm_tpl_truthy(v)): return v
		return arg
	if (strcmp(n, c"length") == 0):
		if (v.kind == ORM_TV_LIST): return orm_tpl_int(ctx, v.items.length)
		if (v.kind == ORM_TV_MAP): return orm_tpl_int(ctx, v.fields.length)
		if (v.kind == ORM_TV_STR): return orm_tpl_int(ctx, str_codepoints(v.text))
		return orm_tpl_int(ctx, 0)
	if (strcmp(n, c"yesno") == 0):
		char* choices = orm_tpl_text(arg)
		list[char*] parts = split(choices, ',')
		free(choices)
		char* pick = c""
		int idx = 1
		if (orm_tpl_truthy(v)): idx = 0
		else if (v.kind == ORM_TV_NULL && parts.length > 2): idx = 2
		if (idx < parts.length): pick = parts[idx]
		orm_tpl_value* out = orm_tpl_str(ctx, pick)
		for char* part in parts: free(part)
		parts.free()
		return out
	if (strcmp(n, c"join") == 0):
		if (v.kind != ORM_TV_LIST): return v
		char* sep = orm_tpl_text(arg)
		string_builder* sb = string_new()
		for i in range(v.items.length):
			orm_tpl_value* item = v.items[i]
			if (i > 0): orm_html_append_escaped(sb, sep)
			char* t = orm_tpl_text(item)
			if (item.kind == ORM_TV_STR && item.safe): string_append(sb, t)
			else: orm_html_append_escaped(sb, t)
			free(t)
		free(sep)
		orm_tpl_value* joined = orm_tpl_str_take(ctx, sb.data)
		free(sb)
		joined.safe = 1
		return joined
	int keep_safe = v.kind == ORM_TV_STR && v.safe
	char* text = orm_tpl_text(v)
	char* res = 0
	if (strcmp(n, c"upper") == 0 || strcmp(n, c"lower") == 0):
		res = text
		text = 0
		keep_safe = 0
		int i = 0
		while (res[i] != 0):
			if (n[0] == 'u'): res[i] = toupper(res[i])
			else: res[i] = tolower(res[i])
			i = i + 1
	else if (strcmp(n, c"title") == 0): res = orm_tpl_title(text)
	else if (strcmp(n, c"urlencode") == 0):
		res = url_quote(text)
		keep_safe = 0
	else if (strcmp(n, c"truncatechars") == 0):
		int limit = 0
		if (arg.kind == ORM_TV_INT): limit = arg.number
		else:
			char* at = orm_tpl_text(arg)
			limit = atoi(at)
			free(at)
		if (str_codepoints(text) <= limit): res = strclone(text)
		else:
			string_builder* tb = string_new()
			int i2 = 0
			int seen = 0
			while (text[i2] != 0 && seen < limit - 1):
				int w = str_char_width(text, i2)
				string_append_bytes(tb, text + i2, w)
				i2 = i2 + w
				seen = seen + 1
			string_append(tb, c"\xe2\x80\xa6")
			res = tb.data
			free(tb)
	else if (strcmp(n, c"linebreaksbr") == 0):
		string_builder* lb = string_new()
		char* escaped = 0
		if (keep_safe): escaped = strclone(text)
		else: escaped = orm_html_escape(text)
		int j = 0
		while (escaped[j] != 0):
			if (escaped[j] == '\n'): string_append(lb, c"<br>")
			else if (escaped[j] != '\r'): string_append_char(lb, escaped[j])
			j = j + 1
		free(escaped)
		res = lb.data
		free(lb)
		keep_safe = 1
	if (text != 0): free(text)
	orm_tpl_value* result = orm_tpl_str_take(ctx, res)
	result.safe = keep_safe
	return result


orm_tpl_value* orm_tpl_compare(orm_tpl_run* r, char* op, orm_tpl_value* a, orm_tpl_value* b):
	int c = 0
	int numeric = (a.kind == ORM_TV_INT || a.kind == ORM_TV_BOOL) && (b.kind == ORM_TV_INT || b.kind == ORM_TV_BOOL)
	if (numeric):
		if (a.number < b.number): c = -1
		else if (a.number > b.number): c = 1
	else if (a.kind == ORM_TV_NULL || b.kind == ORM_TV_NULL):
		if (a.kind != b.kind): c = 1
	else if (a.kind == ORM_TV_ROW && b.kind == ORM_TV_ROW):
		if (a.row != b.row): c = 1
	else:
		char* at = orm_tpl_text(a)
		char* bt = orm_tpl_text(b)
		c = strcmp(at, bt)
		free(at)
		free(bt)
	int res = 0
	if (strcmp(op, c"==") == 0): res = c == 0
	else if (strcmp(op, c"!=") == 0): res = c != 0
	else if (strcmp(op, c"<") == 0): res = c < 0
	else if (strcmp(op, c">") == 0): res = c > 0
	else if (strcmp(op, c"<=") == 0): res = c <= 0
	else if (strcmp(op, c">=") == 0): res = c >= 0
	return orm_tpl_bool(r.ctx, res)


orm_tpl_value* orm_tpl_eval(orm_tpl_run* r, orm_tpl_expr* e):
	orm_tpl_ctx* ctx = r.ctx
	orm_tpl_value* v = 0
	int k = e.kind
	if (k == ORM_TE_STR): v = orm_tpl_str(ctx, e.text)
	else if (k == ORM_TE_INT): v = orm_tpl_int(ctx, e.number)
	else if (k == ORM_TE_CONST):
		if (e.number < 0): v = orm_tpl_null(ctx)
		else: v = orm_tpl_bool(ctx, e.number)
	else if (k == ORM_TE_PATH):
		v = orm_tpl_lookup_name(ctx, e.path[0])
		for i in range(1, e.path.length): v = orm_tpl_attr(ctx, v, e.path[i])
	else if (k == ORM_TE_NOT): v = orm_tpl_bool(ctx, orm_tpl_truthy(orm_tpl_eval(r, cast(orm_tpl_expr*, e.a))) == 0)
	else if (k == ORM_TE_AND):
		v = orm_tpl_eval(r, cast(orm_tpl_expr*, e.a))
		if (orm_tpl_truthy(v)): v = orm_tpl_eval(r, cast(orm_tpl_expr*, e.b))
	else if (k == ORM_TE_OR):
		v = orm_tpl_eval(r, cast(orm_tpl_expr*, e.a))
		if (orm_tpl_truthy(v) == 0): v = orm_tpl_eval(r, cast(orm_tpl_expr*, e.b))
	else if (k == ORM_TE_CMP):
		orm_tpl_value* left = orm_tpl_eval(r, cast(orm_tpl_expr*, e.a))
		orm_tpl_value* right = orm_tpl_eval(r, cast(orm_tpl_expr*, e.b))
		v = orm_tpl_compare(r, e.text, left, right)
	if (v == 0): v = orm_tpl_null(ctx)
	for void* fp in e.filters: v = orm_tpl_apply_filter(r, v, cast(orm_tpl_filter*, fp))
	return v


void orm_tpl_emit(orm_tpl_run* r, orm_tpl_value* v):
	char* text = orm_tpl_text(v)
	if (v.kind == ORM_TV_STR && v.safe): string_append(r.out, text)
	else: orm_html_append_escaped(r.out, text)
	free(text)


int orm_tpl_render_nodes(orm_tpl_run* r, list[void*] nodes);
int orm_tpl_render_tpl(orm_tpl_run* r, orm_tpl* t, int line);


orm_tpl_value* orm_tpl_forloop(orm_tpl_ctx* ctx, int i, int n):
	orm_tpl_value* loop = orm_tpl_map(ctx)
	orm_tpl_put(loop, c"counter", orm_tpl_int(ctx, i + 1))
	orm_tpl_put(loop, c"counter0", orm_tpl_int(ctx, i))
	orm_tpl_put(loop, c"revcounter", orm_tpl_int(ctx, n - i))
	orm_tpl_put(loop, c"first", orm_tpl_bool(ctx, i == 0))
	orm_tpl_put(loop, c"last", orm_tpl_bool(ctx, i == n - 1))
	return loop


int orm_tpl_render_node(orm_tpl_run* r, orm_tpl_node* n):
	orm_tpl_ctx* ctx = r.ctx
	int k = n.kind
	if (k == ORM_TN_TEXT):
		string_append(r.out, n.text)
		return 1
	if (k == ORM_TN_VAR):
		orm_tpl_emit(r, orm_tpl_eval(r, n.expr))
		return 1
	if (k == ORM_TN_IF):
		if (orm_tpl_truthy(orm_tpl_eval(r, n.expr))): return orm_tpl_render_nodes(r, n.body)
		return orm_tpl_render_nodes(r, n.alt)
	if (k == ORM_TN_FOR):
		orm_tpl_value* seq = orm_tpl_eval(r, n.expr)
		if (seq.kind != ORM_TV_LIST || seq.items.length == 0): return orm_tpl_render_nodes(r, n.alt)
		int count = seq.items.length
		for i in range(count):
			orm_tpl_value* scope = orm_tpl_map(ctx)
			orm_tpl_put(scope, n.name, seq.items[i])
			orm_tpl_put(scope, c"forloop", orm_tpl_forloop(ctx, i, count))
			ctx.scopes.push(scope)
			int ok = orm_tpl_render_nodes(r, n.body)
			ctx.scopes.pop()
			if (ok == 0): return 0
		return 1
	if (k == ORM_TN_INCLUDE):
		orm_tpl* inc = orm_tpl_get(r.engine, n.name)
		if (inc == 0):
			char* why = strclone(r.engine.error)
			orm_tpl_run_fail(r, n.line, c"include: ", why)
			free(why)
			return 0
		map[char*, orm_tpl_node*] saved = r.blocks
		r.blocks = new map[char*, orm_tpl_node*]
		int ok2 = orm_tpl_render_tpl(r, inc, n.line)
		map_free[char*, orm_tpl_node*](r.blocks)
		r.blocks = saved
		return ok2
	if (k == ORM_TN_BLOCK):
		orm_tpl_node* use = r.blocks.get(n.name, n)
		return orm_tpl_render_nodes(r, use.body)
	if (k == ORM_TN_CSRF):
		char* token = 0
		if (ctx.csrf_fn != 0): token = ctx.csrf_fn(ctx.csrf_ctx)
		if (token != 0):
			string_append(r.out, c"<input type=\"hidden\" name=\"csrfmiddlewaretoken\" value=\"")
			orm_html_append_escaped(r.out, token)
			string_append(r.out, c"\">")
		return 1
	if (k == ORM_TN_URL):
		if (ctx.url_fn == 0): return orm_tpl_run_fail(r, n.line, c"url: no url resolver for ", n.name)
		map[char*, char*] params = new map[char*, char*]
		list[char*] texts = new list[char*]
		for i in range(n.keys.length):
			char* t = orm_tpl_text(orm_tpl_eval(r, n.args[i]))
			texts.push(t)
			params[n.keys[i]] = t
		char* url = ctx.url_fn(ctx.url_ctx, n.name, params)
		for char* t2 in texts: free(t2)
		texts.free()
		map_free[char*, char*](params)
		if (url == 0): return orm_tpl_run_fail(r, n.line, c"url: no route matches ", n.name)
		orm_html_append_escaped(r.out, url)
		free(url)
		return 1
	return 1


int orm_tpl_render_nodes(orm_tpl_run* r, list[void*] nodes):
	for void* np in nodes:
		if (orm_tpl_render_node(r, cast(orm_tpl_node*, np)) == 0): return 0
		if (r.failed): return 0
	return 1


# Renders t, following its extends chain: each level's blocks are kept
# unless a more-derived template already overrode them.
int orm_tpl_render_tpl(orm_tpl_run* r, orm_tpl* t, int line):
	r.depth = r.depth + 1
	if (r.depth > r.engine.max_depth):
		r.depth = r.depth - 1
		return orm_tpl_run_fail(r, line, c"include / extends nested too deeply at ", t.name)
	int ok = 0
	char* outer = r.where
	r.where = t.name
	if (t.parent != 0):
		for char* bname, orm_tpl_node* b in t.blocks:
			if ((bname in r.blocks) == 0): r.blocks[bname] = b
		orm_tpl* parent = orm_tpl_get(r.engine, t.parent)
		if (parent == 0):
			char* why = strclone(r.engine.error)
			orm_tpl_run_fail(r, line, c"extends: ", why)
			free(why)
		else: ok = orm_tpl_render_tpl(r, parent, line)
	else:
		list[void*] top = new list[void*]
		for orm_tpl_node* n in t.nodes: top.push(cast(void*, n))
		ok = orm_tpl_render_nodes(r, top)
		top.free()
	if (r.failed == 0): r.where = outer
	r.depth = r.depth - 1
	return ok


# Renders template `name` with ctx. Returns owned text, or 0 with
# orm_tpl_error(e) ("name:line: message" for syntax errors).
char* orm_tpl_render(orm_tpl_engine* e, char* name, orm_tpl_ctx* ctx):
	orm_tpl* t = orm_tpl_get(e, name)
	if (t == 0): return 0
	orm_tpl_run* r = new orm_tpl_run()
	r.engine = e
	r.ctx = ctx
	r.out = string_new()
	r.blocks = new map[char*, orm_tpl_node*]
	r.where = t.name
	orm_tpl_engine_fail(e, c"")
	int ok = orm_tpl_render_tpl(r, t, 1)
	map_free[char*, orm_tpl_node*](r.blocks)
	char* text = 0
	if (ok && r.failed == 0):
		text = r.out.data
		free(r.out)
	else: string_free(r.out)
	free(cast(void*, r))
	return text


# Compiles and renders source once (not cached under a file name: it is
# stored as "<string>").
char* orm_tpl_render_string(orm_tpl_engine* e, char* source, orm_tpl_ctx* ctx):
	if (orm_tpl_add(e, c"<string>", source) == 0): return 0
	return orm_tpl_render(e, c"<string>", ctx)
