# w-orm REST pagination (unit U3.4, docs/projects/orm/u3_4.md): DRF's
# cursor, limit/offset and page-number styles over a queryset,
# HTTP-agnostic.
#
#   orm_paginator* p = orm_paginator_cursor(c"-published_at", 20)
#   orm_page* pg = orm_paginate(p, qs, params, c"/books")
#   char* body = orm_page_render(pg, serializer)    # {"next", "previous", "results"}
#   orm_page_free(pg)
#
# Cursor pagination (the default the plan recommends) never counts: the
# cursor is an opaque base64url token holding the ordering key and pk of
# the boundary row, and each page is one keyset query (WHERE key > v OR
# (key = v AND pk > id) ... LIMIT n + 1). Limit/offset and page-number
# pagination add {"count"} at the cost of one COUNT query.
import libs.standard.orm.rest.filter
import libs.standard.crypto.base64


const int ORM_PAGE_NUMBER = 1
const int ORM_PAGE_LIMIT_OFFSET = 2
const int ORM_PAGE_CURSOR = 3


struct orm_paginator:
	int style
	int page_size              # default page size / limit
	int max_page_size          # cap for client-chosen sizes
	char* page_param           # "page"
	char* page_size_param      # "page_size"; 0 = clients cannot choose
	char* limit_param          # "limit"
	char* offset_param         # "offset"
	char* cursor_param         # "cursor"
	char* ordering             # cursor: "field" or "-field" (a non-null column); pk breaks ties


struct orm_page:
	orm_result* result         # this page's rows (0 on error)
	int count                  # total rows, -1 when not counted (cursor)
	char* next                 # owned link, or 0
	char* previous
	json_value* error          # owned error object, or 0
	int status                 # 200, 404 (invalid page/cursor) or 500


orm_paginator* orm_paginator_new(int style, int page_size):
	orm_paginator* p = new orm_paginator()
	p.style = style
	if (page_size <= 0): page_size = 20
	p.page_size = page_size
	p.max_page_size = 100
	if (p.max_page_size < page_size): p.max_page_size = page_size
	p.page_param = c"page"
	p.limit_param = c"limit"
	p.offset_param = c"offset"
	p.cursor_param = c"cursor"
	return p


# ?page=N, with {"count"}; ?page_size=M when page_size_param is set.
orm_paginator* orm_paginator_page_number(int page_size):
	return orm_paginator_new(ORM_PAGE_NUMBER, page_size)


# ?limit=N&offset=M, with {"count"}.
orm_paginator* orm_paginator_limit_offset(int default_limit):
	return orm_paginator_new(ORM_PAGE_LIMIT_OFFSET, default_limit)


# ?cursor=..., ordered by `ordering` then pk, no count.
orm_paginator* orm_paginator_cursor(char* ordering, int page_size):
	orm_paginator* p = orm_paginator_new(ORM_PAGE_CURSOR, page_size)
	p.ordering = ordering
	return p


void orm_paginator_free(orm_paginator* p):
	free(cast(void*, p))


# Lets clients pick the page size with ?<param>=n, capped at max.
orm_paginator* orm_paginator_client_size(orm_paginator* p, char* param, int max):
	p.page_size_param = param
	if (max > 0): p.max_page_size = max
	return p


# Marks this paginator's parameters as reserved in fs, so filtering does
# not reject them.
void orm_paginator_reserve(orm_paginator* p, orm_filter_set* fs):
	if (p.style == ORM_PAGE_NUMBER): orm_filter_ignore(fs, p.page_param)
	else if (p.style == ORM_PAGE_LIMIT_OFFSET):
		orm_filter_ignore(fs, p.limit_param)
		orm_filter_ignore(fs, p.offset_param)
	else: orm_filter_ignore(fs, p.cursor_param)
	if (p.page_size_param != 0): orm_filter_ignore(fs, p.page_size_param)


void orm_page_free(orm_page* pg):
	if (pg == 0): return
	if (pg.result != 0): orm_result_free(pg.result)
	if (pg.next != 0): free(pg.next)
	if (pg.previous != 0): free(pg.previous)
	if (pg.error != 0): json_free(pg.error)
	free(cast(void*, pg))


orm_page* orm_page_fail(orm_page* pg, int status, char* detail):
	pg.status = status
	pg.error = orm_rest_detail(detail)
	return pg


# A positive int param, `fallback` when absent or invalid, capped at max.
int orm_page_positive(orm_params* params, char* name, int fallback, int max):
	if (name == 0): return fallback
	char* text = orm_params_get(params, name)
	int v = 0
	if (text == 0 || sql_parse_int(text, &v) == 0 || v <= 0): return fallback
	if (max > 0 && v > max): return max
	return v


int orm_page_size(orm_paginator* p, orm_params* params):
	return orm_page_positive(params, p.page_size_param, p.page_size, p.max_page_size)


# Link to base with params, `key` set to value (0 removes it).
char* orm_page_link(char* base, orm_params* params, char* key, char* value, char* key2, char* value2):
	orm_params* c = orm_params_clone(params)
	orm_params_set(c, key, value)
	if (key2 != 0): orm_params_set(c, key2, value2)
	char* url = orm_params_url(base, c)
	orm_params_free(c)
	return url


# qs ordered stably: its ordering (pk when none) with the pk appended.
orm_queryset* orm_page_stable(orm_queryset* qs):
	orm_field_desc* pk = orm_model_pk(qs.query.model)
	if (pk == 0): return qs
	for orm_order* o in qs.query.order:
		if (o.expr != 0 && o.expr.kind == ORM_E_FIELD && strcmp(o.expr.path, pk.name) == 0): return qs
	return qs.order_by(pk.name)


# ---------------------------------------------------------------------------
# Page number and limit/offset

orm_page* orm_paginate_page_number(orm_paginator* p, orm_queryset* qs, orm_params* params, char* base, orm_page* pg):
	int size = orm_page_size(p, params)
	int page = 1
	char* page_text = orm_params_get(params, p.page_param)
	if (page_text != 0 && page_text[0] != 0):
		if (strcmp(page_text, c"last") == 0): page = -1
		else if (sql_parse_int(page_text, &page) == 0 || page < 1): return orm_page_fail(pg, 404, c"Invalid page.")
	int count = qs.count()
	if (count < 0): return orm_page_fail(pg, 500, orm_db_error(qs.db))
	int pages = (count + size - 1) / size
	if (pages < 1): pages = 1
	if (page == -1): page = pages
	if (page > pages): return orm_page_fail(pg, 404, c"Invalid page.")
	pg.count = count
	pg.result = orm_page_stable(qs).slice((page - 1) * size, page * size).all()
	if (pg.result == 0): return orm_page_fail(pg, 500, orm_db_error(qs.db))
	if (page < pages):
		char* n = itoa(page + 1)
		pg.next = orm_page_link(base, params, p.page_param, n, 0, 0)
		free(n)
	if (page > 1):
		char* prev = 0
		if (page > 2): prev = itoa(page - 1)
		pg.previous = orm_page_link(base, params, p.page_param, prev, 0, 0)
		if (prev != 0): free(prev)
	return pg


orm_page* orm_paginate_limit_offset(orm_paginator* p, orm_queryset* qs, orm_params* params, char* base, orm_page* pg):
	int limit = orm_page_positive(params, p.limit_param, p.page_size, p.max_page_size)
	int offset = 0
	char* off_text = orm_params_get(params, p.offset_param)
	if (off_text != 0 && (sql_parse_int(off_text, &offset) == 0 || offset < 0)): offset = 0
	int count = qs.count()
	if (count < 0): return orm_page_fail(pg, 500, orm_db_error(qs.db))
	pg.count = count
	pg.result = orm_page_stable(qs).slice(offset, offset + limit).all()
	if (pg.result == 0): return orm_page_fail(pg, 500, orm_db_error(qs.db))
	char* lim = itoa(limit)
	if (offset + limit < count):
		char* n = itoa(offset + limit)
		pg.next = orm_page_link(base, params, p.limit_param, lim, p.offset_param, n)
		free(n)
	if (offset > 0):
		char* prev = 0
		if (offset - limit > 0): prev = itoa(offset - limit)
		pg.previous = orm_page_link(base, params, p.limit_param, lim, p.offset_param, prev)
		if (prev != 0): free(prev)
	free(lim)
	return pg


# ---------------------------------------------------------------------------
# Cursor

struct orm_cursor:
	int reverse                # 1: page before the position
	char* pk                   # boundary row pk text
	char* key                  # boundary ordering key text (0 when ordering by pk)


void orm_cursor_free(orm_cursor* c):
	if (c == 0): return
	if (c.pk != 0): free(c.pk)
	if (c.key != 0): free(c.key)
	free(cast(void*, c))


# Opaque token: base64url (no padding) of "<r>|<pk>|<key>".
char* orm_cursor_encode(int reverse, char* pk, char* key):
	string_builder* s = string_new()
	if (reverse): string_append(s, c"r|")
	else: string_append(s, c"f|")
	string_append(s, pk)
	string_append_char(s, '|')
	if (key != 0): string_append(s, key)
	char* b64 = base64_encode(s.data, strlen(s.data))
	string_free(s)
	int n = strlen(b64)
	for i in range(n):
		if (b64[i] == '+'): b64[i] = '-'
		else if (b64[i] == '/'): b64[i] = '_'
	while (n > 0 && b64[n - 1] == '='):
		n = n - 1
		b64[n] = 0
	return b64


# Decodes a token; 0 when it is not one this paginator produced.
orm_cursor* orm_cursor_decode(char* token, int keyed):
	int n = strlen(token)
	if (n == 0 || n > 4096): return 0
	string_builder* s = string_new()
	for i in range(n):
		int ch = token[i] & 255
		if (ch == '-'): ch = '+'
		else if (ch == '_'): ch = '/'
		else if (ch == '+' || ch == '/' || ch == '='): ch = '!'
		string_append_char(s, ch)
	while (s.length % 4 != 0): string_append_char(s, '=')
	int len = 0
	char* raw = base64_decode(s.data, s.length, &len)
	string_free(s)
	if (raw == 0): return 0
	if (len != strlen(raw) || len < 3 || (raw[0] != 'f' && raw[0] != 'r') || raw[1] != '|'):
		free(raw)
		return 0
	char* rest = raw + 2
	int bar = index_of(rest, c"|")
	int pk = 0
	char* pk_text = 0
	if (bar > 0): pk_text = substring(rest, 0, bar)
	if (pk_text == 0 || sql_parse_int(pk_text, &pk) == 0):
		if (pk_text != 0): free(pk_text)
		free(raw)
		return 0
	orm_cursor* c = new orm_cursor()
	c.reverse = raw[0] == 'r'
	c.pk = pk_text
	if (keyed): c.key = strclone(rest + bar + 1)
	free(raw)
	return c


# The cursor for the boundary row `row`.
char* orm_cursor_for_row(orm_model_desc* m, orm_field_desc* key_field, void* row, int reverse):
	orm_field_desc* pk = orm_model_pk(m)
	char* pk_text = orm_rest_field_text(pk, row)
	char* key = 0
	if (key_field != 0): key = orm_rest_field_text(key_field, row)
	char* token = orm_cursor_encode(reverse, pk_text, key)
	free(pk_text)
	if (key != 0): free(key)
	return token


orm_page* orm_paginate_cursor(orm_paginator* p, orm_queryset* qs, orm_params* params, char* base, orm_page* pg):
	orm_model_desc* m = qs.query.model
	orm_field_desc* pk = orm_model_pk(m)
	char* spec = p.ordering
	if (spec == 0 || spec[0] == 0): spec = pk.name
	int desc = spec[0] == '-'
	char* name = spec
	if (desc): name = spec + 1
	orm_field_desc* key_field = orm_model_field(m, name)
	if (key_field == 0 || orm_field_has_column(key_field) == 0 || (key_field.flags & ORM_F_NULL) != 0):
		return orm_page_fail(pg, 500, c"Cursor pagination needs a non-null column to order by.")
	if (key_field == pk): key_field = 0
	int size = orm_page_size(p, params)
	orm_cursor* cur = 0
	char* token = orm_params_get(params, p.cursor_param)
	if (token != 0 && token[0] != 0):
		cur = orm_cursor_decode(token, key_field != 0)
		if (cur == 0): return orm_page_fail(pg, 404, c"Invalid cursor")
	int reverse = cur != 0 && cur.reverse
	# Effective direction of this query: flipped when paging backwards.
	int qdesc = desc
	if (reverse): qdesc = !desc
	orm_queryset* q = qs.order_clear()
	if (key_field != 0):
		if (qdesc): q = q.order_by_expr(f(key_field.name), 1)
		else: q = q.order_by_expr(f(key_field.name), 0)
	q = q.order_by_expr(f(pk.name), qdesc)
	if (cur != 0):
		char* cmp = c"gt"
		if (qdesc): cmp = c"lt"
		orm_where* past_pk = q_lookup(pk.name, cmp, cur.pk)
		if (key_field != 0):
			orm_where* tie = q_and(q_eq(key_field.name, cur.key), past_pk)
			q = q.filter(q_or(q_lookup(key_field.name, cmp, cur.key), tie))
		else: q = q.filter(past_pk)
	q = q.limit(size + 1)
	pg.result = q.all()
	if (pg.result == 0):
		orm_cursor_free(cur)
		return orm_page_fail(pg, 500, orm_db_error(qs.db))
	list[void*] rows = pg.result.rows
	int more = rows.length > size
	if (more): rows.pop()
	if (reverse):
		int i = 0
		int j = rows.length - 1
		while (i < j):
			void* t = rows[i]
			rows[i] = rows[j]
			rows[j] = t
			i = i + 1
			j = j - 1
	int has_next = more
	int has_prev = cur != 0
	if (reverse):
		has_next = 1
		has_prev = more
	if (rows.length > 0):
		if (has_next):
			char* nt = orm_cursor_for_row(m, key_field, rows[rows.length - 1], 0)
			pg.next = orm_page_link(base, params, p.cursor_param, nt, 0, 0)
			free(nt)
		if (has_prev):
			char* pt = orm_cursor_for_row(m, key_field, rows[0], 1)
			pg.previous = orm_page_link(base, params, p.cursor_param, pt, 0, 0)
			free(pt)
	else if (cur != 0):
		# An empty page past either end links back to where it came from.
		char* back = orm_cursor_encode(!cur.reverse, cur.pk, cur.key)
		if (cur.reverse): pg.next = orm_page_link(base, params, p.cursor_param, back, 0, 0)
		else: pg.previous = orm_page_link(base, params, p.cursor_param, back, 0, 0)
		free(back)
	orm_cursor_free(cur)
	return pg


# ---------------------------------------------------------------------------
# Entry points

# One page of qs (already filtered and prepared). base is the link path
# ("/books"); other params are kept in the links. Check pg.error (with
# pg.status 404 for an invalid page or cursor, 500 for database errors).
orm_page* orm_paginate(orm_paginator* p, orm_queryset* qs, orm_params* params, char* base):
	if (params == 0):
		orm_params* empty = orm_params_new()
		orm_page* out = orm_paginate(p, qs, empty, base)
		orm_params_free(empty)
		return out
	orm_page* pg = new orm_page()
	pg.count = -1
	pg.status = 200
	if (p.style == ORM_PAGE_NUMBER): return orm_paginate_page_number(p, qs, params, base, pg)
	if (p.style == ORM_PAGE_LIMIT_OFFSET): return orm_paginate_limit_offset(p, qs, params, base, pg)
	return orm_paginate_cursor(p, qs, params, base, pg)


json_value* orm_rest_link_json(char* link):
	if (link == 0): return json_null()
	return json_string(link)


# The DRF envelope {"count", "next", "previous", "results"} ("count" only
# when counted), or a copy of the error object. Caller frees.
json_value* orm_page_json(orm_page* pg, orm_serializer* ser):
	if (pg.error != 0): return json_clone(pg.error)
	json_value* o = json_object()
	if (pg.count >= 0): json_object_set(o, c"count", json_int(pg.count))
	json_object_set(o, c"next", orm_rest_link_json(pg.next))
	json_object_set(o, c"previous", orm_rest_link_json(pg.previous))
	json_object_set(o, c"results", orm_serializer_result(ser, pg.result))
	return o


char* orm_page_render(orm_page* pg, orm_serializer* ser):
	return orm_rest_render(orm_page_json(pg, ser))
