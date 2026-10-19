# wbuild: arch_only=x64
# U0.4: the shared w-orm contracts and the library fixture model are
# self-consistent (docs/projects/orm.md).
import libs.standard.orm.contract
import tests.orm.fixtures.library_orm
import lib.assert


void check_fields_fit(orm_model_desc* m):
	for orm_field_desc* f in m.fields:
		if (f.offset >= 0):
			assert1(f.offset + f.size <= m.struct_size)
		if (f.rel_offset >= 0):
			assert1(f.rel_offset + sizeof(int) <= m.struct_size)
		if (f.null_offset >= 0):
			assert1(f.null_offset + sizeof(int) <= m.struct_size)
		if (orm_field_has_column(f)):
			assert1(f.offset >= 0)
		else:
			assert1(f.offset == -1)
			assert1(f.rel_offset >= 0)


void test_registry():
	library_register()
	list[orm_model_desc*] models = orm_registry_models()
	assert_equal(3, models.length)
	orm_model_desc* book = orm_model_lookup(c"Book")
	assert1(book == Book_desc())
	assert_equal(sizeof(Book), book.struct_size)
	assert1(strcmp(book.table, c"library_book") == 0)
	assert1(book.history)
	assert1(strcmp(orm_model_pk(book).name, c"id") == 0)
	orm_field_desc* author = orm_model_field(book, c"author")
	assert1(author.kind == ORM_FK)
	assert1(strcmp(author.column, c"author_id") == 0)
	assert1(orm_field_target(author) == Author_desc())
	orm_field_desc* tags = orm_model_field(book, c"tags")
	assert1(orm_field_target(tags) == Tag_desc())
	assert1(orm_field_has_column(tags) == 0)
	orm_field_desc* books = orm_model_field(Author_desc(), c"books")
	assert1(orm_field_target(books) == book)
	assert1(orm_model_field(book, c"nope") == 0)
	for orm_model_desc* m in models: check_fields_fit(m)


void test_slots():
	Book b
	b.id = 7
	b.title = c"Dune"
	b.pages = 412
	orm_model_desc* m = Book_desc()
	assert_equal(7, orm_slot_get(&b, orm_model_field(m, c"id").offset))
	assert1(cast(char*, orm_slot_get(&b, orm_model_field(m, c"title").offset)) == b.title)
	orm_slot_set(&b, orm_model_field(m, c"pages").offset, 500)
	assert_equal(500, b.pages)
	orm_slot_set(&b, orm_model_field(m, c"pages").null_offset, 1)
	assert_equal(1, b.pages__isnull)
	Author a
	a.books = new list[void*]
	Book* bp = &b
	a.books.push(bp)
	assert_equal(500, Author_books(&a)[0].pages)


void test_paths():
	list[char*] parts = orm_path_split(c"author__name__icontains")
	assert_equal(3, parts.length)
	assert1(strcmp(parts[0], c"author") == 0)
	assert1(strcmp(parts[1], c"name") == 0)
	assert1(strcmp(parts[2], c"icontains") == 0)
	parts = orm_path_split(c"published_at")
	assert_equal(1, parts.length)
	assert1(strcmp(parts[0], c"published_at") == 0)
	assert_equal(0, orm_path_split(0).length)


void test_clone():
	orm_query* q = orm_query_new(ORM_Q_SELECT, Book_desc())
	orm_where* w = orm_where_new(ORM_W_LOOKUP)
	w.lhs = orm_expr_new(ORM_E_FIELD)
	w.lhs.path = c"title"
	w.lookup = c"exact"
	w.rhs = orm_expr_new(ORM_E_VALUE)
	w.rhs.value = c"Dune"
	q.where = w
	q.select_related.push(c"author")
	orm_query* c = orm_query_clone(q)
	c.select_related.push(c"author__x")
	c.limit = 5
	assert_equal(1, q.select_related.length)
	assert_equal(2, c.select_related.length)
	assert_equal(-1, q.limit)
	assert1(c.where == q.where)


void test_result():
	orm_result* r = orm_result_new(Book_desc())
	Book* b = cast(Book*, orm_result_alloc(r, sizeof(Book)))
	assert_equal(0, b.id)
	b.title = orm_result_strdup(r, c"Hyperion")
	b.tags = orm_result_list(r)
	r.rows.push(b)
	assert1(strcmp(b.title, c"Hyperion") == 0)
	orm_result_free(r)


void test_db_and_migration():
	orm_migration* mig = orm_migration_new(c"library", c"0002_index")
	orm_op* op = orm_op_new(ORM_OP_ADD_INDEX, ORM_PHASE_EXPAND, c"library_book")
	op.non_atomic = 1
	orm_migration_add(mig, op)
	assert_equal(0, mig.atomic)
	assert_equal(1000, op.batch_size)
	if (sql_sqlite_available() == 0):
		println(c"orm_contract: SKIP SQLite (libsqlite3.so.0 unavailable)")
		return
	orm_dialect d
	d.id = ORM_DIALECT_SQLITE
	d.bind_style = sql_bind_question
	orm_db* db = orm_db_new(sql_open_sqlite(c":memory:"), &d)
	db.log_queries = 1
	assert1(orm_db_exec_sql(db, c"CREATE TABLE t(x INTEGER)"))
	sql_builder* b = sql_builder_new(d.bind_style)
	sql_builder_append(b, c"INSERT INTO t(x) VALUES (")
	sql_builder_bind(b, c"42")
	sql_builder_append(b, c")")
	sql_result* r = orm_db_execute(db, b)
	assert1(r != 0)
	sql_result_free(r)
	sql_builder_free(b)
	assert_equal(2, db.query_count)
	assert1(strcmp(db.query_log[1], c"INSERT INTO t(x) VALUES (?)") == 0)
	assert_equal(0, orm_db_exec_sql(db, c"SELECT * FROM missing_table"))
	assert1(strlen(orm_db_error(db)) > 0)
	sql_close(db.conn)


int main():
	test_registry()
	test_slots()
	test_paths()
	test_clone()
	test_result()
	test_db_and_migration()
	println(c"orm_contract_test: OK")
	return 0
