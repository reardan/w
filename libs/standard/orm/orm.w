# w-orm runtime entry point (unit U1.3, docs/projects/orm/u1_3.md).
#
# Import this module (generated API modules do): it opens databases and
# pulls in the queryset (query.w), expression builders (expr.w), loading
# (load.w) and writes (write.w).
#
#   orm_db* db = orm_open_sqlite(c":memory:")
#   orm_result* r = Book_objects(db).filter(q(c"title__icontains", c"dune")).select_related(c"author").all()
#   for Book* b in Book_rows(r): println(b.author.name)
#   orm_result_free(r)
#   orm_close(db)
import libs.standard.orm.write
import libs.standard.orm.dialect_sqlite
import libs.standard.orm.dialect_postgres


# Opens a SQLite database with foreign keys enforced. Always returns an
# orm_db; check orm_is_open and orm_db_error. The PRAGMA is not counted in
# db.query_count.
orm_db* orm_open_sqlite(char* path):
	sql_connection* conn = sql_open_sqlite(path)
	orm_db* db = orm_db_new(conn, orm_dialect_sqlite())
	if (sql_is_open(conn) == 0):
		orm_db_set_error(db, sql_error(conn))
		return db
	orm_db_exec_sql(db, c"PRAGMA foreign_keys = ON")
	db.query_count = 0
	return db


# Opens a PostgreSQL connection (libpq conninfo). Same contract as
# orm_open_sqlite.
orm_db* orm_open_postgres(char* conninfo):
	sql_connection* conn = sql_open_postgres(conninfo)
	orm_db* db = orm_db_new(conn, orm_dialect_postgres())
	if (sql_is_open(conn) == 0): orm_db_set_error(db, sql_error(conn))
	return db


int orm_is_open(orm_db* db):
	return db != 0 && sql_is_open(db.conn)


# Closes the connection and frees the orm_db (not results it produced).
void orm_close(orm_db* db):
	if (db == 0): return
	if (db.conn != 0): sql_close(db.conn)
	for char* s in db.query_log: free(s)
	db.query_log.free()
	for orm_callback* cb in db.on_commit: free(cast(void*, cb))
	db.on_commit.free()
	if (db.error != 0): free(db.error)
	free(cast(void*, db))


# All rows of model m, lazily: M_objects(db) in generated code.
orm_queryset* orm_objects(orm_db* db, orm_model_desc* m):
	return orm_queryset_new(db, orm_query_new(ORM_Q_SELECT, m))


# A zeroed heap row (with empty M2M/reverse lists) that outlives any
# result. Free it with orm_row_free; strings you store in it stay yours.
void* orm_row_new(orm_model_desc* m):
	int size = orm_row_alloc_size(m)
	char* row = cast(char*, malloc(size))
	for i in range(size): row[i] = 0
	for orm_field_desc* fd in m.fields:
		if ((fd.kind == ORM_M2M || fd.kind == ORM_REVERSE_FK) && fd.rel_offset >= 0):
			list[void*] l = new list[void*]
			orm_slot_set(row, fd.rel_offset, cast(int, l))
	orm_row_meta* meta = new orm_row_meta()
	meta.owned = new list[void*]
	orm_row_meta_set(m, row, meta)
	return row


# Frees a row from orm_row_new: its relation lists, the strings the ORM
# stored into it (timestamps, defaults, refresh) and the row itself. Rows
# it points to through FK slots are not freed.
void orm_row_free(orm_model_desc* m, void* row):
	if (row == 0): return
	for orm_field_desc* fd in m.fields:
		if ((fd.kind == ORM_M2M || fd.kind == ORM_REVERSE_FK) && fd.rel_offset >= 0):
			list[void*] l = cast(list[void*], orm_slot_get(row, fd.rel_offset))
			if (l != 0): l.free()
	orm_row_meta* meta = orm_row_meta_get(m, row)
	if (meta != 0 && meta.result == 0):
		if (meta.owned != 0):
			for void* p in meta.owned: free(p)
			meta.owned.free()
		free(cast(void*, meta))
	free(row)
