# wbuild: arch_only=x64
# wbuild: target=orm_compile_postgres_local_test tag=tests dep=orm_compile_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_compile_test"
# U1.2: golden SQL + bound values for the w-orm compiler on SQLite and
# PostgreSQL, then a sample of the statements run against real SQLite
# in-memory tables (and PostgreSQL when W_SQL_POSTGRES is set).
# Expected SQL is written with ` for the identifier quote ".
import libs.standard.orm.compile
import tests.orm.fixtures.library_orm
import lib.assert
import lib.env


# ---------------------------------------------------------------------------
# Tree builders (the queryset API lives in U1.3; these are plain C3 nodes)

orm_expr* e_field(char* path):
	orm_expr* e = orm_expr_new(ORM_E_FIELD)
	e.path = path
	return e


orm_expr* e_val(char* v):
	orm_expr* e = orm_expr_new(ORM_E_VALUE)
	e.value = v
	return e


orm_expr* e_int(char* v):
	orm_expr* e = orm_expr_new(ORM_E_INT)
	e.value = v
	return e


orm_expr* e_null():
	return orm_expr_new(ORM_E_NULL)


orm_expr* e_call(int kind, char* name, orm_expr* a, orm_expr* b = 0):
	orm_expr* e = orm_expr_new(kind)
	e.name = name
	if (a != 0): e.args.push(a)
	if (b != 0): e.args.push(b)
	return e


orm_expr* e_func(char* name, orm_expr* a = 0, orm_expr* b = 0):
	return e_call(ORM_E_FUNC, name, a, b)


orm_expr* e_agg(char* name, orm_expr* a = 0, int distinct = 0):
	orm_expr* e = e_call(ORM_E_AGG, name, a)
	e.distinct = distinct
	return e


orm_expr* e_binop(char* op, orm_expr* a, orm_expr* b):
	return e_call(ORM_E_BINOP, op, a, b)


orm_expr* e_outer(char* path):
	orm_expr* e = orm_expr_new(ORM_E_OUTER_REF)
	e.path = path
	return e


orm_expr* e_sub(int kind, orm_query* q):
	orm_expr* e = orm_expr_new(kind)
	e.subquery = q
	return e


orm_where* w_lk(char* path, char* op, orm_expr* rhs):
	orm_where* w = orm_where_new(ORM_W_LOOKUP)
	w.lhs = e_field(path)
	w.lookup = op
	w.rhs = rhs
	return w


orm_where* w_eq(char* path, char* v):
	return w_lk(path, c"exact", e_val(v))


orm_where* w_list(char* path, char* op, char* a, char* b, char* c3 = 0):
	orm_where* w = w_lk(path, op, 0)
	if (a != 0): w.rhs_list.push(e_val(a))
	if (b != 0): w.rhs_list.push(e_val(b))
	if (c3 != 0): w.rhs_list.push(e_val(c3))
	return w


orm_where* w_node(int kind, orm_where* a, orm_where* b = 0):
	orm_where* w = orm_where_new(kind)
	w.children.push(a)
	if (b != 0): w.children.push(b)
	return w


orm_where* w_and(orm_where* a, orm_where* b): return w_node(ORM_W_AND, a, b)
orm_where* w_or(orm_where* a, orm_where* b): return w_node(ORM_W_OR, a, b)
orm_where* w_not(orm_where* a): return w_node(ORM_W_NOT, a)


orm_order* ord(char* path, int descending = 0, int nulls = 0):
	orm_order* o = new orm_order()
	o.expr = e_field(path)
	o.descending = descending
	o.nulls = nulls
	return o


void annotate(orm_query* q, char* name, orm_expr* e):
	orm_annotation* a = new orm_annotation()
	a.name = name
	a.expr = e
	q.annotations.push(a)


void value(orm_query* q, char* name, orm_expr* e):
	q.select.push(e)
	q.select_names.push(name)


orm_assignment* asg(char* field, orm_expr* v):
	orm_assignment* s = new orm_assignment()
	s.field = field
	s.value = v
	return s


orm_query* sel(orm_model_desc* m): return orm_query_new(ORM_Q_SELECT, m)


orm_query* book_q(): return sel(Book_desc())
orm_query* author_q(): return sel(Author_desc())


# ---------------------------------------------------------------------------
# Golden helpers

char* BOOK_COLS():
	return c"`t0`.`id`, `t0`.`title`, `t0`.`author_id`, `t0`.`status`, `t0`.`price`, `t0`.`pages`, `t0`.`published_at`"


char* AUTHOR_COLS():
	return c"`t0`.`id`, `t0`.`name`, `t0`.`email`, `t0`.`created`"


# ` -> ", and "{cols}"/"{acols}" expand to the Book / Author column lists.
char* expand(char* s):
	string_builder* b = string_new()
	int i = 0
	while (s[i] != 0):
		if (starts_with(&s[i], c"{cols}")):
			string_append(b, BOOK_COLS())
			i = i + 6
			continue
		if (starts_with(&s[i], c"{acols}")):
			string_append(b, AUTHOR_COLS())
			i = i + 7
			continue
		string_append_char(b, s[i])
		i = i + 1
	for j in range(b.length):
		if (b.data[j] == '`'): b.data[j] = '"'
	char* r = strclone(b.data)
	string_free(b)
	return r


# PostgreSQL text of a SQLite golden: ? -> $1, $2, ... outside quotes.
char* dollars(char* s):
	string_builder* b = string_new()
	int n = 0
	int quoted = 0
	for i in range(strlen(s)):
		if (s[i] == '\''): quoted = quoted == 0
		if (s[i] == '?' && quoted == 0):
			n = n + 1
			string_append_char(b, '$')
			string_append_int(b, n)
		else:
			string_append_char(b, s[i])
	char* r = strclone(b.data)
	string_free(b)
	return r


char* params_text(orm_compiled* out):
	string_builder* b = string_new()
	for i in range(orm_compiled_param_count(out)):
		if (i > 0): string_append_char(b, '|')
		char* p = orm_compiled_param(out, i)
		if (p == 0): string_append(b, c"NULL")
		else: string_append(b, p)
	char* r = strclone(b.data)
	string_free(b)
	return r


orm_compiled* compile_ok(orm_query* q, orm_dialect* d):
	orm_compiled* out = orm_compiled_new(d)
	int ok = orm_compile(q, d, out)
	if (ok == 0):
		print(c"unexpected compile error: ")
		println(out.error)
	assert1(ok)
	return out


void check(orm_query* q, orm_dialect* d, char* want_sql, char* want_params):
	orm_compiled* out = compile_ok(q, d)
	char* sql = orm_compiled_sql(out)
	if (strcmp(sql, want_sql) != 0):
		print(c"dialect: ")
		println(d.name)
	assert_strings_equal(want_sql, sql)
	char* got = params_text(out)
	assert_strings_equal(want_params, got)
	free(got)
	orm_compiled_free(out)


# Same SQL on both dialects apart from the placeholder style.
void golden(orm_query* q, char* sqlite_sql, char* params):
	char* s = expand(sqlite_sql)
	char* p = dollars(s)
	check(q, orm_dialect_sqlite(), s, params)
	check(q, orm_dialect_postgres(), p, params)
	free(s)
	free(p)


# Dialect-specific SQL (and values).
void golden2(orm_query* q, char* sqlite_sql, char* sqlite_params, char* pg_sql, char* pg_params):
	char* s = expand(sqlite_sql)
	char* p = expand(pg_sql)
	check(q, orm_dialect_sqlite(), s, sqlite_params)
	check(q, orm_dialect_postgres(), p, pg_params)
	free(s)
	free(p)


# An SQLite build without FILTER / NULLS FIRST (< 3.30): exercises the
# emulations the compiler picks from the capability flags.
orm_dialect* old_sqlite():
	orm_dialect* d = new orm_dialect()
	orm_dialect* s = orm_dialect_sqlite()
	d.id = s.id
	d.name = s.name
	d.bind_style = s.bind_style
	d.max_params = s.max_params
	return d


void fails(orm_query* q, orm_dialect* d, char* want):
	orm_compiled* out = orm_compiled_new(d)
	assert_equal(0, orm_compile(q, d, out))
	assert1(out.error != 0)
	assert_contains(out.error, want)
	free(out.error)
	orm_compiled_free(out)


# ---------------------------------------------------------------------------
# Extra test models: a deprecated column and a nullable FK

struct Gadget:
	int id
	char* name
	char* old
	int book_id
	int book_id__isnull
	Book* book


orm_model_desc* __gadget_desc


orm_model_desc* Gadget_desc():
	if (__gadget_desc != 0): return __gadget_desc
	Gadget probe
	orm_model_desc* m = orm_model_new(c"Gadget", c"test_gadget", sizeof(Gadget))
	orm_model_add_field(m, orm_field_new(c"id", c"id", ORM_INT, __library_offset(&probe, &probe.id), ORM_F_PK | ORM_F_AUTO))
	orm_model_add_field(m, orm_field_new(c"name", c"name", ORM_TEXT, __library_offset(&probe, &probe.name), 0))
	orm_model_add_field(m, orm_field_new(c"old", c"old", ORM_TEXT, __library_offset(&probe, &probe.old), ORM_F_DEPRECATED))
	orm_field_desc* f = orm_model_add_field(m, orm_field_new(c"book", c"book_id", ORM_FK, __library_offset(&probe, &probe.book_id), ORM_F_NULL | ORM_F_INDEXED))
	f.null_offset = __library_offset(&probe, &probe.book_id__isnull)
	f.rel_model = c"Book"
	f.rel_offset = __library_offset(&probe, &probe.book)
	f.on_delete = ORM_SET_NULL
	orm_register(m)
	__gadget_desc = m
	return m


# ---------------------------------------------------------------------------
# SELECT basics

void test_select_columns():
	orm_query* q = book_q()
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0`", c"")
	orm_compiled* out = compile_ok(q, orm_dialect_sqlite())
	assert_equal(7, out.columns.length)
	assert1(out.columns[2].field == orm_model_field(Book_desc(), c"author"))
	assert1(out.columns[2].model == Book_desc())
	assert_strings_equal(c"", out.columns[2].rel_path)
	assert_strings_equal(c"author", out.columns[2].name)
	orm_compiled_free(out)
	q.only_fields.push(c"title")
	golden(q, c"SELECT `t0`.`id`, `t0`.`title` FROM `library_book` AS `t0`", c"")
	orm_query* g = sel(Gadget_desc())
	golden(g, c"SELECT `t0`.`id`, `t0`.`name`, `t0`.`book_id` FROM `test_gadget` AS `t0`", c"")


void test_where_tree():
	orm_query* q = book_q()
	q.where = w_and(w_eq(c"title", c"Dune"), w_or(w_lk(c"pages", c"gt", e_val(c"100")), w_not(w_eq(c"status", c"draft"))))
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0` WHERE `t0`.`title` = ? AND (`t0`.`pages` > ? OR NOT (`t0`.`status` = ?))", c"Dune|100|draft")
	# exclude() on a nullable column keeps the NULL rows (Django semantics)
	q.where = w_not(w_eq(c"pages", c"5"))
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0` WHERE NOT (`t0`.`pages` = ? AND `t0`.`pages` IS NOT NULL)", c"5")
	q.where = orm_where_new(ORM_W_OR)
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0` WHERE 1 = 0", c"")
	q.where = orm_where_new(ORM_W_TRUE)
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0` WHERE 1 = 1", c"")


char* where_sql(orm_where* w, orm_dialect* d):
	orm_query* q = book_q()
	q.only_fields.push(c"id")
	q.where = w
	orm_compiled* out = compile_ok(q, d)
	char* prefix = c"SELECT \"t0\".\"id\" FROM \"library_book\" AS \"t0\" WHERE "
	char* sql = orm_compiled_sql(out)
	assert1(starts_with(sql, prefix))
	char* r = strclone(&sql[strlen(prefix)])
	orm_compiled_free(out)
	return r


# Lookup golden: the WHERE text on each dialect and the bound values.
void lk(orm_where* w, char* sqlite_where, char* pg_where, char* sqlite_params, char* pg_params = 0):
	if (pg_params == 0): pg_params = sqlite_params
	orm_query* q = book_q()
	q.only_fields.push(c"id")
	q.where = w
	string_builder* s = string_new()
	string_append(s, c"SELECT `t0`.`id` FROM `library_book` AS `t0` WHERE ")
	string_append(s, sqlite_where)
	string_builder* p = string_new()
	string_append(p, c"SELECT `t0`.`id` FROM `library_book` AS `t0` WHERE ")
	if (pg_where == 0):
		char* pw = dollars(sqlite_where)
		string_append(p, pw)
		free(pw)
	else:
		string_append(p, pg_where)
	golden2(q, s.data, sqlite_params, p.data, pg_params)
	string_free(s)
	string_free(p)


void test_lookups():
	lk(w_lk(c"pages", c"exact", e_null()), c"`t0`.`pages` IS NULL", 0, c"")
	lk(w_lk(c"pages", c"ne", e_null()), c"`t0`.`pages` IS NOT NULL", 0, c"")
	lk(w_eq(c"title", c"x"), c"`t0`.`title` = ?", 0, c"x")
	lk(w_lk(c"title", c"iexact", e_val(c"DUNE")), c"LOWER(`t0`.`title`) = LOWER(?)", 0, c"DUNE")
	lk(w_lk(c"pages", c"ne", e_val(c"3")), c"`t0`.`pages` <> ?", 0, c"3")
	lk(w_lk(c"pages", c"lt", e_val(c"1")), c"`t0`.`pages` < ?", 0, c"1")
	lk(w_lk(c"pages", c"lte", e_val(c"2")), c"`t0`.`pages` <= ?", 0, c"2")
	lk(w_lk(c"pages", c"gt", e_val(c"3")), c"`t0`.`pages` > ?", 0, c"3")
	lk(w_lk(c"pages", c"gte", e_val(c"4")), c"`t0`.`pages` >= ?", 0, c"4")
	lk(w_list(c"id", c"in", c"1", c"2", c"3"), c"`t0`.`id` IN (?, ?, ?)", 0, c"1|2|3")
	lk(w_list(c"id", c"in", 0, 0), c"1 = 0", 0, c"")
	lk(w_not(w_list(c"id", c"in", 0, 0)), c"NOT (1 = 0)", 0, c"")
	lk(w_list(c"pages", c"range", c"10", c"20"), c"`t0`.`pages` BETWEEN ? AND ?", 0, c"10|20")
	lk(w_lk(c"published_at", c"isnull", e_val(c"1")), c"`t0`.`published_at` IS NULL", 0, c"")
	lk(w_lk(c"published_at", c"isnull", e_val(c"false")), c"`t0`.`published_at` IS NOT NULL", 0, c"")
	lk(w_lk(c"title", c"contains", e_val(c"50%_a\\b*?[")), c"`t0`.`title` GLOB ?", c"`t0`.`title` LIKE $1 ESCAPE '\\'", c"*50%_a\\b[*][?][[]*", c"%50\\%\\_a\\\\b*?[%")
	lk(w_lk(c"title", c"icontains", e_val(c"5%")), c"LOWER(`t0`.`title`) LIKE LOWER(?) ESCAPE '\\'", c"`t0`.`title` ILIKE $1 ESCAPE '\\'", c"%5\\%%")
	lk(w_lk(c"title", c"startswith", e_val(c"Du")), c"`t0`.`title` GLOB ?", c"`t0`.`title` LIKE $1 ESCAPE '\\'", c"Du*", c"Du%")
	lk(w_lk(c"title", c"istartswith", e_val(c"du")), c"LOWER(`t0`.`title`) LIKE LOWER(?) ESCAPE '\\'", c"`t0`.`title` ILIKE $1 ESCAPE '\\'", c"du%")
	lk(w_lk(c"title", c"endswith", e_val(c"ne")), c"`t0`.`title` GLOB ?", c"`t0`.`title` LIKE $1 ESCAPE '\\'", c"*ne", c"%ne")
	lk(w_lk(c"title", c"iendswith", e_val(c"_E")), c"LOWER(`t0`.`title`) LIKE LOWER(?) ESCAPE '\\'", c"`t0`.`title` ILIKE $1 ESCAPE '\\'", c"%\\_E")
	orm_query* q = book_q()
	q.where = w_lk(c"title", c"regex", e_val(c"^D.*e$"))
	check(q, orm_dialect_postgres(), expand(c"SELECT {cols} FROM `library_book` AS `t0` WHERE `t0`.`title` ~ $1"), c"^D.*e$")
	fails(q, orm_dialect_sqlite(), c"lookup 'regex' is not supported on sqlite")
	# F() on the right-hand side, and an in-list that skips NULLs
	lk(w_lk(c"pages", c"gt", e_field(c"author__id")), c"`t0`.`pages` > `t0`.`author_id`", 0, c"")
	orm_where* w = w_list(c"id", c"in", c"1", 0)
	w.rhs_list.push(e_null())
	lk(w, c"`t0`.`id` IN (?)", 0, c"1")


void test_lookup_errors():
	orm_query* q = book_q()
	q.where = w_eq(c"nope", c"1")
	fails(q, orm_dialect_sqlite(), c"unknown field 'nope' on model Book (path 'nope')")
	q.where = w_eq(c"author__nope", c"1")
	fails(q, orm_dialect_postgres(), c"unknown field 'nope' on model Author (path 'author__nope')")
	q.where = w_eq(c"title__name", c"1")
	fails(q, orm_dialect_sqlite(), c"field 'title' on model Book is not a relation")
	q.where = w_lk(c"pages", c"contains", e_val(c"1"))
	fails(q, orm_dialect_sqlite(), c"lookup 'contains' is not valid for field 'pages' of model Book")
	q.where = w_lk(c"title", c"between", e_val(c"1"))
	fails(q, orm_dialect_postgres(), c"unknown lookup 'between'")
	q.where = w_lk(c"pages", c"gt", e_null())
	fails(q, orm_dialect_postgres(), c"lookup 'gt' needs a non-null value")
	q.where = w_list(c"pages", c"range", c"1", 0)
	fails(q, orm_dialect_sqlite(), c"lookup 'range' needs exactly two values")
	q.where = w_eq(c"title", c"x")
	q.for_update = 1
	fails(q, orm_dialect_sqlite(), c"FOR UPDATE is not supported on sqlite")
	q = book_q()
	q.where = orm_where_new(ORM_W_EXPR)
	q.where.lhs = e_func(c"bad name", e_field(c"title"))
	fails(q, orm_dialect_sqlite(), c"invalid function name 'bad name'")
	q.where.lhs = e_int(c"1; DROP TABLE x")
	fails(q, orm_dialect_sqlite(), c"not an integer")


# ---------------------------------------------------------------------------
# Relations

void test_relation_paths():
	orm_query* q = book_q()
	q.where = w_eq(c"author__name", c"Herbert")
	q.order.push(ord(c"author__email"))
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0` INNER JOIN `library_author` AS `t1` ON `t1`.`id` = `t0`.`author_id` WHERE `t1`.`name` = ? ORDER BY `t1`.`email`", c"Herbert")
	q = author_q()
	q.where = w_lk(c"books__title", c"startswith", e_val(c"D"))
	golden2(q, c"SELECT {acols} FROM `library_author` AS `t0` LEFT JOIN `library_book` AS `t1` ON `t1`.`author_id` = `t0`.`id` WHERE `t1`.`title` GLOB ?", c"D*", c"SELECT {acols} FROM `library_author` AS `t0` LEFT JOIN `library_book` AS `t1` ON `t1`.`author_id` = `t0`.`id` WHERE `t1`.`title` LIKE $1 ESCAPE '\\'", c"D%")
	q = book_q()
	q.where = w_and(w_eq(c"tags__name", c"scifi"), w_eq(c"author__books__tags__name", c"x"))
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0` LEFT JOIN `library_book_tags` AS `t1` ON `t1`.`book_id` = `t0`.`id` LEFT JOIN `library_tag` AS `t2` ON `t2`.`id` = `t1`.`tag_id` INNER JOIN `library_author` AS `t3` ON `t3`.`id` = `t0`.`author_id` LEFT JOIN `library_book` AS `t4` ON `t4`.`author_id` = `t3`.`id` LEFT JOIN `library_book_tags` AS `t5` ON `t5`.`book_id` = `t4`.`id` LEFT JOIN `library_tag` AS `t6` ON `t6`.`id` = `t5`.`tag_id` WHERE `t2`.`name` = ? AND `t6`.`name` = ?", c"scifi|x")
	# a relation as the last part means its primary key; FK__pk needs no join
	q = book_q()
	q.where = w_and(w_eq(c"tags", c"3"), w_eq(c"author__pk", c"1"))
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0` LEFT JOIN `library_book_tags` AS `t1` ON `t1`.`book_id` = `t0`.`id` LEFT JOIN `library_tag` AS `t2` ON `t2`.`id` = `t1`.`tag_id` WHERE `t2`.`id` = ? AND `t0`.`author_id` = ?", c"3|1")


void test_select_related():
	orm_query* q = book_q()
	q.select_related.push(c"author")
	q.where = w_eq(c"author__name", c"Herbert")
	golden(q, c"SELECT {cols}, `t1`.`id`, `t1`.`name`, `t1`.`email`, `t1`.`created` FROM `library_book` AS `t0` INNER JOIN `library_author` AS `t1` ON `t1`.`id` = `t0`.`author_id` WHERE `t1`.`name` = ?", c"Herbert")
	orm_compiled* out = compile_ok(q, orm_dialect_postgres())
	assert_equal(11, out.columns.length)
	assert1(out.columns[8].model == Author_desc())
	assert_strings_equal(c"author", out.columns[8].rel_path)
	assert_strings_equal(c"name", out.columns[8].name)
	orm_compiled_free(out)
	# nullable FK -> LEFT JOIN, and the chain stays LEFT past it
	q = sel(Gadget_desc())
	q.select_related.push(c"book__author")
	golden(q, c"SELECT `t0`.`id`, `t0`.`name`, `t0`.`book_id`, `t1`.`id`, `t1`.`title`, `t1`.`author_id`, `t1`.`status`, `t1`.`price`, `t1`.`pages`, `t1`.`published_at`, `t2`.`id`, `t2`.`name`, `t2`.`email`, `t2`.`created` FROM `test_gadget` AS `t0` LEFT JOIN `library_book` AS `t1` ON `t1`.`id` = `t0`.`book_id` LEFT JOIN `library_author` AS `t2` ON `t2`.`id` = `t1`.`author_id`", c"")
	out = compile_ok(q, orm_dialect_sqlite())
	assert_strings_equal(c"book", out.columns[3].rel_path)
	assert_strings_equal(c"book__author", out.columns[10].rel_path)
	orm_compiled_free(out)
	q = book_q()
	q.select_related.push(c"tags")
	fails(q, orm_dialect_sqlite(), c"select_related: 'tags' on model Book is not a foreign key")


# ---------------------------------------------------------------------------
# Annotations, aggregates, grouping

void test_aggregates():
	orm_query* q = author_q()
	annotate(q, c"n", e_agg(c"COUNT", e_field(c"books")))
	q.having = w_lk(c"n", c"gt", e_val(c"1"))
	q.order.push(ord(c"n", 1))
	# SQLite compares a computed number with a text value as text: cast it
	golden2(q, c"SELECT {acols}, COUNT(`t1`.`id`) AS `n` FROM `library_author` AS `t0` LEFT JOIN `library_book` AS `t1` ON `t1`.`author_id` = `t0`.`id` GROUP BY {acols} HAVING COUNT(`t1`.`id`) > CAST(? AS INTEGER) ORDER BY `n` DESC", c"1", c"SELECT {acols}, COUNT(`t1`.`id`) AS `n` FROM `library_author` AS `t0` LEFT JOIN `library_book` AS `t1` ON `t1`.`author_id` = `t0`.`id` GROUP BY {acols} HAVING COUNT(`t1`.`id`) > $1 ORDER BY `n` DESC", c"1")
	q = book_q()
	value(q, c"status", e_field(c"status"))
	annotate(q, c"n", e_agg(c"COUNT"))
	annotate(q, c"authors", e_agg(c"COUNT", e_field(c"author"), 1))
	annotate(q, c"total", e_agg(c"SUM", e_field(c"pages")))
	annotate(q, c"avg", e_agg(c"AVG", e_field(c"pages")))
	annotate(q, c"lo", e_agg(c"MIN", e_field(c"price")))
	annotate(q, c"hi", e_agg(c"MAX", e_field(c"price")))
	golden(q, c"SELECT `t0`.`status`, COUNT(*) AS `n`, COUNT(DISTINCT `t0`.`author_id`) AS `authors`, SUM(`t0`.`pages`) AS `total`, AVG(`t0`.`pages`) AS `avg`, MIN(`t0`.`price`) AS `lo`, MAX(`t0`.`price`) AS `hi` FROM `library_book` AS `t0` GROUP BY `t0`.`status`", c"")
	orm_compiled* out = compile_ok(q, orm_dialect_sqlite())
	assert_equal(7, out.columns.length)
	assert1(out.columns[1].model == 0)
	assert_strings_equal(c"n", out.columns[1].name)
	orm_compiled_free(out)
	# aggregate() style: only aggregates, no GROUP BY; FILTER and its fallback
	q = book_q()
	orm_expr* pub = e_agg(c"COUNT")
	pub.filter = w_eq(c"status", c"pub")
	value(q, c"pub", pub)
	orm_expr* big = e_agg(c"SUM", e_field(c"pages"))
	big.filter = w_lk(c"pages", c"gt", e_val(c"300"))
	value(q, c"big", big)
	golden(q, c"SELECT COUNT(*) FILTER (WHERE `t0`.`status` = ?) AS `pub`, SUM(`t0`.`pages`) FILTER (WHERE `t0`.`pages` > ?) AS `big` FROM `library_book` AS `t0`", c"pub|300")
	orm_dialect* old = old_sqlite()
	check(q, old, expand(c"SELECT COUNT(CASE WHEN `t0`.`status` = ? THEN 1 END) AS `pub`, SUM(CASE WHEN `t0`.`pages` > ? THEN `t0`.`pages` END) AS `big` FROM `library_book` AS `t0`"), c"pub|300")
	# explicit group_by, functions, binops, CASE, an expression in GROUP BY
	q = book_q()
	value(q, c"author_id", e_field(c"author"))
	value(q, c"len", e_func(c"LENGTH", e_func(c"LOWER", e_field(c"title"))))
	annotate(q, c"double", e_binop(c"*", e_field(c"pages"), e_int(c"2")))
	annotate(q, c"m", e_agg(c"MAX", e_field(c"pages")))
	golden(q, c"SELECT `t0`.`author_id` AS `author_id`, LENGTH(LOWER(`t0`.`title`)) AS `len`, (`t0`.`pages` * 2) AS `double`, MAX(`t0`.`pages`) AS `m` FROM `library_book` AS `t0` GROUP BY `t0`.`author_id`, 2, 3", c"")
	q.group_by.push(e_field(c"author"))
	golden(q, c"SELECT `t0`.`author_id` AS `author_id`, LENGTH(LOWER(`t0`.`title`)) AS `len`, (`t0`.`pages` * 2) AS `double`, MAX(`t0`.`pages`) AS `m` FROM `library_book` AS `t0` GROUP BY `t0`.`author_id`", c"")
	q = book_q()
	orm_expr* cs = orm_expr_new(ORM_E_CASE)
	orm_when* wh = new orm_when()
	wh.condition = w_lk(c"pages", c"gte", e_val(c"500"))
	wh.then = e_val(c"long")
	cs.whens.push(wh)
	cs.else_expr = e_val(c"short")
	value(q, c"size", cs)
	value(q, c"greatest", e_func(c"GREATEST", e_field(c"pages"), e_int(c"10")))
	value(q, c"now", e_func(c"NOW"))
	golden2(q, c"SELECT CASE WHEN `t0`.`pages` >= ? THEN ? ELSE ? END AS `size`, MAX(`t0`.`pages`, 10) AS `greatest`, CURRENT_TIMESTAMP AS `now` FROM `library_book` AS `t0`", c"500|long|short", c"SELECT CASE WHEN `t0`.`pages` >= $1 THEN $2 ELSE $3 END AS `size`, GREATEST(`t0`.`pages`, 10) AS `greatest`, CURRENT_TIMESTAMP AS `now` FROM `library_book` AS `t0`", c"500|long|short")


void test_subqueries():
	# latest title per author: correlated scalar subquery
	orm_query* sub = book_q()
	value(sub, c"title", e_field(c"title"))
	orm_where* corr = orm_where_new(ORM_W_LOOKUP)
	corr.lhs = e_field(c"author")
	corr.lookup = c"exact"
	corr.rhs = e_outer(c"id")
	sub.where = corr
	sub.order.push(ord(c"id", 1))
	sub.limit = 1
	orm_query* q = author_q()
	annotate(q, c"latest", e_sub(ORM_E_SUBQUERY, sub))
	golden(q, c"SELECT {acols}, (SELECT `u0`.`title` FROM `library_book` AS `u0` WHERE `u0`.`author_id` = `t0`.`id` ORDER BY `u0`.`id` DESC LIMIT 1) AS `latest` FROM `library_author` AS `t0`", c"")
	# EXISTS with a correlated reference plus a bound value, joined inside
	orm_query* ex = book_q()
	orm_where* c2 = orm_where_new(ORM_W_LOOKUP)
	c2.lhs = e_field(c"author")
	c2.lookup = c"exact"
	c2.rhs = e_outer(c"id")
	ex.where = w_and(c2, w_eq(c"tags__name", c"scifi"))
	q = author_q()
	q.where = w_and(w_lk(c"name", c"ne", e_val(c"x")), orm_where_new(ORM_W_EXPR))
	q.where.children[1].lhs = e_sub(ORM_E_EXISTS, ex)
	golden(q, c"SELECT {acols} FROM `library_author` AS `t0` WHERE `t0`.`name` <> ? AND EXISTS(SELECT 1 FROM `library_book` AS `u0` LEFT JOIN `library_book_tags` AS `u1` ON `u1`.`book_id` = `u0`.`id` LEFT JOIN `library_tag` AS `u2` ON `u2`.`id` = `u1`.`tag_id` WHERE `u0`.`author_id` = `t0`.`id` AND `u2`.`name` = ?)", c"x|scifi")
	# id IN (subquery)
	orm_query* ids = sel(Tag_desc())
	value(ids, c"id", e_field(c"id"))
	ids.where = w_lk(c"name", c"istartswith", e_val(c"s"))
	q = book_q()
	q.where = w_lk(c"tags", c"in", e_sub(ORM_E_SUBQUERY, ids))
	golden2(q, c"SELECT {cols} FROM `library_book` AS `t0` LEFT JOIN `library_book_tags` AS `t1` ON `t1`.`book_id` = `t0`.`id` LEFT JOIN `library_tag` AS `t2` ON `t2`.`id` = `t1`.`tag_id` WHERE `t2`.`id` IN (SELECT `u0`.`id` FROM `library_tag` AS `u0` WHERE LOWER(`u0`.`name`) LIKE LOWER(?) ESCAPE '\\')", c"s%", c"SELECT {cols} FROM `library_book` AS `t0` LEFT JOIN `library_book_tags` AS `t1` ON `t1`.`book_id` = `t0`.`id` LEFT JOIN `library_tag` AS `t2` ON `t2`.`id` = `t1`.`tag_id` WHERE `t2`.`id` IN (SELECT `u0`.`id` FROM `library_tag` AS `u0` WHERE `u0`.`name` ILIKE $1 ESCAPE '\\')", c"s%")
	# errors: two columns, OUTER_REF at the top level
	q = author_q()
	annotate(q, c"bad", e_sub(ORM_E_SUBQUERY, book_q()))
	fails(q, orm_dialect_sqlite(), c"subquery must select exactly one column")
	q = book_q()
	q.where = orm_where_new(ORM_W_LOOKUP)
	q.where.lhs = e_field(c"id")
	q.where.lookup = c"exact"
	q.where.rhs = e_outer(c"id")
	fails(q, orm_dialect_sqlite(), c"OUTER_REF 'id' used outside a subquery")


void test_window_order_limit():
	orm_query* q = book_q()
	q.only_fields.push(c"title")
	orm_expr* win = orm_expr_new(ORM_E_WINDOW)
	win.args.push(e_func(c"ROW_NUMBER"))
	win.partition_by.push(e_field(c"author"))
	win.order_by.push(ord(c"pages", 1))
	annotate(q, c"rank", win)
	orm_expr* run = orm_expr_new(ORM_E_WINDOW)
	run.args.push(e_agg(c"SUM", e_field(c"pages")))
	run.order_by.push(ord(c"id"))
	annotate(q, c"running", run)
	golden(q, c"SELECT `t0`.`id`, `t0`.`title`, ROW_NUMBER() OVER (PARTITION BY `t0`.`author_id` ORDER BY `t0`.`pages` DESC) AS `rank`, SUM(`t0`.`pages`) OVER (ORDER BY `t0`.`id`) AS `running` FROM `library_book` AS `t0`", c"")
	q = book_q()
	q.distinct = 1
	q.order.push(ord(c"pages", 1, ORM_NULLS_LAST))
	q.order.push(ord(c"-title"))
	q.order.push(ord(c"published_at", 0, ORM_NULLS_FIRST))
	q.limit = 10
	q.offset = 20
	golden(q, c"SELECT DISTINCT {cols} FROM `library_book` AS `t0` ORDER BY `t0`.`pages` DESC NULLS LAST, `t0`.`title` DESC, `t0`.`published_at` NULLS FIRST LIMIT 10 OFFSET 20", c"")
	orm_dialect* old = old_sqlite()
	check(q, old, expand(c"SELECT DISTINCT {cols} FROM `library_book` AS `t0` ORDER BY CASE WHEN `t0`.`pages` IS NULL THEN 1 ELSE 0 END, `t0`.`pages` DESC, `t0`.`title` DESC, CASE WHEN `t0`.`published_at` IS NULL THEN 1 ELSE 0 END DESC, `t0`.`published_at` LIMIT 10 OFFSET 20"), c"")
	q = book_q()
	q.offset = 5
	golden2(q, c"SELECT {cols} FROM `library_book` AS `t0` LIMIT -1 OFFSET 5", c"", c"SELECT {cols} FROM `library_book` AS `t0` OFFSET 5", c"")
	q.offset = 0
	q.limit = 0
	golden(q, c"SELECT {cols} FROM `library_book` AS `t0` LIMIT 0", c"")


void test_for_update():
	orm_query* q = book_q()
	q.where = w_eq(c"id", c"1")
	q.for_update = 1
	check(q, orm_dialect_postgres(), expand(c"SELECT {cols} FROM `library_book` AS `t0` WHERE `t0`.`id` = $1 FOR UPDATE"), c"1")
	q.skip_locked = 1
	check(q, orm_dialect_postgres(), expand(c"SELECT {cols} FROM `library_book` AS `t0` WHERE `t0`.`id` = $1 FOR UPDATE SKIP LOCKED"), c"1")
	q.skip_locked = 0
	q.nowait = 1
	q.where = w_eq(c"tags__name", c"a")
	check(q, orm_dialect_postgres(), expand(c"SELECT {cols} FROM `library_book` AS `t0` LEFT JOIN `library_book_tags` AS `t1` ON `t1`.`book_id` = `t0`.`id` LEFT JOIN `library_tag` AS `t2` ON `t2`.`id` = `t1`.`tag_id` WHERE `t2`.`name` = $1 FOR UPDATE OF `t0` NOWAIT"), c"a")
	q.skip_locked = 1
	fails(q, orm_dialect_postgres(), c"cannot combine SKIP LOCKED and NOWAIT")


# ---------------------------------------------------------------------------
# Writes

void test_update_delete():
	orm_query* q = orm_query_new(ORM_Q_UPDATE, Book_desc())
	q.assignments.push(asg(c"price", e_binop(c"*", e_field(c"price"), e_val(c"1.1"))))
	q.assignments.push(asg(c"author", e_val(c"2")))
	q.where = w_eq(c"id", c"7")
	golden(q, c"UPDATE `library_book` SET `price` = (`price` * ?), `author_id` = ? WHERE `id` = ?", c"1.1|2|7")
	q.where = w_and(w_eq(c"author__name", c"Herbert"), w_lk(c"pages", c"gt", e_val(c"10")))
	q.returning.push(c"id")
	golden(q, c"UPDATE `library_book` SET `price` = (`price` * ?), `author_id` = ? WHERE `id` IN (SELECT `t0`.`id` FROM `library_book` AS `t0` INNER JOIN `library_author` AS `t1` ON `t1`.`id` = `t0`.`author_id` WHERE `t1`.`name` = ? AND `t0`.`pages` > ?) RETURNING `id`", c"1.1|2|Herbert|10")
	orm_compiled* out = compile_ok(q, orm_dialect_sqlite())
	assert_equal(1, out.columns.length)
	assert_strings_equal(c"id", out.columns[0].name)
	orm_compiled_free(out)
	# a correlated subquery in SET refers to the unaliased table
	orm_query* cnt = book_q()
	value(cnt, c"n", e_agg(c"COUNT"))
	orm_where* corr = orm_where_new(ORM_W_LOOKUP)
	corr.lhs = e_field(c"author")
	corr.lookup = c"exact"
	corr.rhs = e_outer(c"id")
	cnt.where = corr
	orm_query* u = orm_query_new(ORM_Q_UPDATE, Author_desc())
	u.assignments.push(asg(c"name", e_func(c"UPPER", e_field(c"name"))))
	u.assignments.push(asg(c"email", e_binop(c"||", e_sub(ORM_E_SUBQUERY, cnt), e_val(c"@x"))))
	golden(u, c"UPDATE `library_author` SET `name` = UPPER(`name`), `email` = ((SELECT COUNT(*) AS `n` FROM `library_book` AS `u0` WHERE `u0`.`author_id` = `library_author`.`id`) || ?)", c"@x")
	u = orm_query_new(ORM_Q_UPDATE, Book_desc())
	u.assignments.push(asg(c"title", e_field(c"author__name")))
	fails(u, orm_dialect_sqlite(), c"related path 'author' cannot be used in this statement")
	u = orm_query_new(ORM_Q_UPDATE, Book_desc())
	u.assignments.push(asg(c"tags", e_val(c"1")))
	fails(u, orm_dialect_sqlite(), c"UPDATE: field 'tags' on model Book has no writable column")
	u = orm_query_new(ORM_Q_UPDATE, Book_desc())
	fails(u, orm_dialect_sqlite(), c"UPDATE needs at least one assignment")
	orm_query* d = orm_query_new(ORM_Q_DELETE, Book_desc())
	golden(d, c"DELETE FROM `library_book`", c"")
	d.where = w_lk(c"published_at", c"isnull", e_val(c"1"))
	golden(d, c"DELETE FROM `library_book` WHERE `published_at` IS NULL", c"")
	d.where = w_eq(c"tags__name", c"old")
	golden(d, c"DELETE FROM `library_book` WHERE `id` IN (SELECT `t0`.`id` FROM `library_book` AS `t0` LEFT JOIN `library_book_tags` AS `t1` ON `t1`.`book_id` = `t0`.`id` LEFT JOIN `library_tag` AS `t2` ON `t2`.`id` = `t1`.`tag_id` WHERE `t2`.`name` = ?)", c"old")
	d.limit = 3
	fails(d, orm_dialect_sqlite(), c"DELETE cannot use LIMIT/OFFSET")


list[orm_assignment*] tag_row(char* id, char* name):
	list[orm_assignment*] row = new list[orm_assignment*]
	row.push(asg(c"id", e_val(id)))
	row.push(asg(c"name", e_val(name)))
	return row


void test_insert():
	orm_query* q = orm_query_new(ORM_Q_INSERT, Book_desc())
	q.assignments.push(asg(c"title", e_val(c"Dune")))
	q.assignments.push(asg(c"author", e_val(c"1")))
	q.assignments.push(asg(c"pages", e_null()))
	q.returning.push(c"id")
	q.returning.push(c"status")
	golden(q, c"INSERT INTO `library_book` (`title`, `author_id`, `pages`) VALUES (?, ?, NULL) RETURNING `id`, `status`", c"Dune|1")
	orm_query* t = orm_query_new(ORM_Q_INSERT, Tag_desc())
	t.insert_rows.push(tag_row(c"1", c"scifi"))
	list[orm_assignment*] r2 = new list[orm_assignment*]
	r2.push(asg(c"name", e_val(0)))
	r2.push(asg(c"id", e_val(c"2")))
	t.insert_rows.push(r2)
	golden(t, c"INSERT INTO `library_tag` (`id`, `name`) VALUES (?, ?), (?, ?)", c"1|scifi|2|NULL")
	t.conflict_action = ORM_CONFLICT_NOTHING
	golden(t, c"INSERT INTO `library_tag` (`id`, `name`) VALUES (?, ?), (?, ?) ON CONFLICT DO NOTHING", c"1|scifi|2|NULL")
	t.conflict_action = ORM_CONFLICT_UPDATE
	fails(t, orm_dialect_postgres(), c"ON CONFLICT DO UPDATE needs conflict fields")
	t.conflict_fields.push(c"name")
	fails(t, orm_dialect_postgres(), c"ON CONFLICT DO UPDATE needs update fields")
	t.update_fields.push(c"id")
	t.returning.push(c"id")
	golden(t, c"INSERT INTO `library_tag` (`id`, `name`) VALUES (?, ?), (?, ?) ON CONFLICT (`name`) DO UPDATE SET `id` = excluded.`id` RETURNING `id`", c"1|scifi|2|NULL")
	orm_query* e = orm_query_new(ORM_Q_INSERT, Tag_desc())
	golden(e, c"INSERT INTO `library_tag` DEFAULT VALUES", c"")
	e.assignments.push(asg(c"name", e_field(c"id")))
	fails(e, orm_dialect_sqlite(), c"field 'id' cannot be referenced in INSERT values")
	orm_query* bad = orm_query_new(ORM_Q_INSERT, Tag_desc())
	bad.insert_rows.push(tag_row(c"1", c"a"))
	list[orm_assignment*] short_row = new list[orm_assignment*]
	short_row.push(asg(c"id", e_val(c"2")))
	bad.insert_rows.push(short_row)
	fails(bad, orm_dialect_sqlite(), c"INSERT rows must set the same fields")


# ---------------------------------------------------------------------------
# Real databases: the compiled statements must run

sql_result* run(sql_connection* conn, orm_query* q, orm_dialect* d):
	orm_compiled* out = compile_ok(q, d)
	sql_result* r = sql_query_params(conn, orm_compiled_sql(out), orm_compiled_param_count(out), sql_builder_values(out.sql))
	if (r == 0):
		print(c"failed SQL: ")
		println(orm_compiled_sql(out))
	asserts(sql_error(conn), r != 0)
	orm_compiled_free(out)
	return r


int run_rows(sql_connection* conn, orm_query* q, orm_dialect* d):
	sql_result* r = run(conn, q, d)
	int n = r.rows
	sql_result_free(r)
	return n


char* run_first(sql_connection* conn, orm_query* q, orm_dialect* d, int column):
	sql_result* r = run(conn, q, d)
	assert1(r.rows > 0)
	char* v = strclone(sql_value(r, 0, column))
	sql_result_free(r)
	return v


void exec_ok(sql_connection* conn, char* text):
	asserts(sql_error(conn), sql_exec(conn, text))


void create_tables(sql_connection* conn):
	exec_ok(conn, c"CREATE TEMP TABLE library_author(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, created TEXT)")
	exec_ok(conn, c"CREATE TEMP TABLE library_tag(id INTEGER PRIMARY KEY, name TEXT UNIQUE)")
	exec_ok(conn, c"CREATE TEMP TABLE library_book(id INTEGER PRIMARY KEY, title TEXT NOT NULL, author_id INTEGER NOT NULL REFERENCES library_author(id), status TEXT NOT NULL DEFAULT 'draft', price NUMERIC(8, 2), pages INTEGER, published_at TEXT)")
	exec_ok(conn, c"CREATE TEMP TABLE library_book_tags(id INTEGER PRIMARY KEY, book_id INTEGER NOT NULL, tag_id INTEGER NOT NULL)")


list[orm_assignment*] book_row(char* id, char* title, char* author, char* pages, char* price):
	list[orm_assignment*] row = new list[orm_assignment*]
	row.push(asg(c"id", e_val(id)))
	row.push(asg(c"title", e_val(title)))
	row.push(asg(c"author", e_val(author)))
	row.push(asg(c"pages", e_val(pages)))
	row.push(asg(c"price", e_val(price)))
	return row


void fill(sql_connection* conn, orm_dialect* d):
	orm_query* a = orm_query_new(ORM_Q_INSERT, Author_desc())
	a.insert_rows.push(new list[orm_assignment*])
	a.insert_rows[0].push(asg(c"id", e_val(c"1")))
	a.insert_rows[0].push(asg(c"name", e_val(c"Herbert")))
	a.insert_rows.push(new list[orm_assignment*])
	a.insert_rows[1].push(asg(c"id", e_val(c"2")))
	a.insert_rows[1].push(asg(c"name", e_val(c"Le Guin")))
	assert_equal(2, run(conn, a, d).affected)
	orm_query* b = orm_query_new(ORM_Q_INSERT, Book_desc())
	b.insert_rows.push(book_row(c"1", c"Dune", c"1", c"412", c"9.99"))
	b.insert_rows.push(book_row(c"2", c"Dune Messiah", c"1", c"256", c"7.50"))
	b.insert_rows.push(book_row(c"3", c"The Dispossessed", c"2", c"387", c"8.00"))
	list[orm_assignment*] nulls = book_row(c"4", c"100% Pure_Fiction", c"2", 0, c"1.00")
	b.insert_rows.push(nulls)
	b.returning.push(c"id")
	b.returning.push(c"status")
	sql_result* r = run(conn, b, d)
	assert_equal(4, r.rows)
	assert_strings_equal(c"draft", sql_value(r, 0, 1))
	sql_result_free(r)
	orm_query* t = orm_query_new(ORM_Q_INSERT, Tag_desc())
	t.insert_rows.push(tag_row(c"1", c"scifi"))
	t.insert_rows.push(tag_row(c"2", c"classic"))
	run(conn, t, d)
	exec_ok(conn, c"INSERT INTO library_book_tags(id, book_id, tag_id) VALUES (1, 1, 1), (2, 1, 2), (3, 2, 1), (4, 3, 2)")


void db_reads(sql_connection* conn, orm_dialect* d):
	orm_query* q = book_q()
	q.select_related.push(c"author")
	q.where = w_and(w_lk(c"author__name", c"istartswith", e_val(c"her")), w_lk(c"tags__name", c"in", 0))
	q.where.children[1].rhs_list.push(e_val(c"scifi"))
	q.distinct = 1
	q.order.push(ord(c"-id"))
	assert_equal(2, run_rows(conn, q, d))
	assert_strings_equal(c"Dune Messiah", run_first(conn, q, d, 1))
	q = book_q()
	q.where = w_lk(c"title", c"contains", e_val(c"0% Pure_"))
	assert_equal(1, run_rows(conn, q, d))
	q.where = w_lk(c"title", c"contains", e_val(c"dune"))
	assert_equal(0, run_rows(conn, q, d))
	q.where = w_lk(c"title", c"icontains", e_val(c"dune"))
	assert_equal(2, run_rows(conn, q, d))
	q.where = w_not(w_lk(c"pages", c"gt", e_val(c"300")))
	assert_equal(2, run_rows(conn, q, d))
	q.where = w_list(c"pages", c"range", c"200", c"400")
	assert_equal(2, run_rows(conn, q, d))
	q.where = w_list(c"id", c"in", 0, 0)
	assert_equal(0, run_rows(conn, q, d))
	orm_query* agg = author_q()
	annotate(agg, c"n", e_agg(c"COUNT", e_field(c"books")))
	orm_expr* long_books = e_agg(c"COUNT")
	long_books.filter = w_lk(c"books__pages", c"gt", e_val(c"300"))
	annotate(agg, c"long_books", long_books)
	agg.having = w_lk(c"n", c"gte", e_val(c"2"))
	agg.order.push(ord(c"name"))
	sql_result* r = run(conn, agg, d)
	assert_equal(2, r.rows)
	assert_strings_equal(c"2", sql_value(r, 0, 4))
	assert_strings_equal(c"1", sql_value(r, 0, 5))
	sql_result_free(r)
	orm_query* sub = book_q()
	value(sub, c"title", e_field(c"title"))
	orm_where* corr = orm_where_new(ORM_W_LOOKUP)
	corr.lhs = e_field(c"author")
	corr.lookup = c"exact"
	corr.rhs = e_outer(c"id")
	sub.where = corr
	sub.order.push(ord(c"pages", 1, ORM_NULLS_LAST))
	sub.limit = 1
	orm_query* top = author_q()
	annotate(top, c"longest", e_sub(ORM_E_SUBQUERY, sub))
	top.order.push(ord(c"id"))
	assert_strings_equal(c"Dune", run_first(conn, top, d, 4))
	orm_query* w = book_q()
	w.only_fields.push(c"title")
	orm_expr* win = orm_expr_new(ORM_E_WINDOW)
	win.args.push(e_func(c"ROW_NUMBER"))
	win.partition_by.push(e_field(c"author"))
	win.order_by.push(ord(c"pages", 1))
	annotate(w, c"rank", win)
	w.order.push(ord(c"id"))
	r = run(conn, w, d)
	assert_equal(4, r.rows)
	assert_strings_equal(c"1", sql_value(r, 0, 2))
	assert_strings_equal(c"2", sql_value(r, 1, 2))
	sql_result_free(r)


void db_writes(sql_connection* conn, orm_dialect* d):
	orm_query* u = orm_query_new(ORM_Q_UPDATE, Book_desc())
	u.assignments.push(asg(c"pages", e_binop(c"+", e_field(c"pages"), e_int(c"1"))))
	u.where = w_eq(c"author__name", c"Herbert")
	u.returning.push(c"pages")
	assert_equal(2, run_rows(conn, u, d))
	orm_query* t = orm_query_new(ORM_Q_INSERT, Tag_desc())
	t.insert_rows.push(tag_row(c"9", c"scifi"))
	t.conflict_action = ORM_CONFLICT_UPDATE
	t.conflict_fields.push(c"name")
	t.update_fields.push(c"id")
	run(conn, t, d)
	t.conflict_action = ORM_CONFLICT_NOTHING
	run(conn, t, d)
	orm_query* tags = sel(Tag_desc())
	tags.where = w_eq(c"name", c"scifi")
	assert_strings_equal(c"9", run_first(conn, tags, d, 0))
	orm_query* del = orm_query_new(ORM_Q_DELETE, Book_desc())
	del.where = w_eq(c"author__name", c"Le Guin")
	assert_equal(2, run(conn, del, d).affected)
	assert_equal(2, run_rows(conn, book_q(), d))
	if (d.supports_for_update):
		orm_query* lock = book_q()
		lock.for_update = 1
		lock.skip_locked = 1
		assert_equal(2, run_rows(conn, lock, d))


void test_sqlite():
	if (sql_sqlite_available() == 0):
		println(c"orm_compile: SKIP SQLite (libsqlite3.so.0 unavailable)")
		return
	sql_connection* conn = sql_open_sqlite(c":memory:")
	asserts(sql_error(conn), sql_is_open(conn))
	create_tables(conn)
	fill(conn, orm_dialect_sqlite())
	db_reads(conn, orm_dialect_sqlite())
	db_writes(conn, orm_dialect_sqlite())
	sql_close(conn)


void test_postgres():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm_compile PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return
	sql_connection* conn = sql_open_postgres(conninfo)
	asserts(sql_error(conn), sql_is_open(conn))
	create_tables(conn)
	fill(conn, orm_dialect_postgres())
	db_reads(conn, orm_dialect_postgres())
	db_writes(conn, orm_dialect_postgres())
	sql_close(conn)
	println(c"orm_compile PostgreSQL: OK")


int main():
	library_register()
	Gadget_desc()
	char* missing = 0
	assert1(orm_registry_resolve(&missing))
	assert1(orm_dialect_sqlite() == orm_dialect_sqlite())
	assert_equal(ORM_DIALECT_POSTGRES, orm_dialect_postgres().id)
	assert_equal(sql_bind_dollar, orm_dialect_postgres().bind_style)
	assert_equal(0, orm_dialect_sqlite().supports_for_update)
	test_select_columns()
	test_where_tree()
	test_lookups()
	test_lookup_errors()
	test_relation_paths()
	test_select_related()
	test_aggregates()
	test_subqueries()
	test_window_order_limit()
	test_for_update()
	test_update_delete()
	test_insert()
	test_sqlite()
	test_postgres()
	println(c"orm_compile_test: OK")
	return 0
