import libs.standard.sql.sqlite_native

void sql_sqlite_error(sql_connection* c):
	sql_error_set(c, cast(char*, sql_native_call(__sql_sqlite3_errmsg, c.handle)))

# Always returns an owned connection, including on error. Inspect sql_is_open.
sql_connection* sql_open_sqlite(char* path):
	sql_connection* c = sql_connection_new(SQL_SQLITE)
	if (sql_sqlite_available() == 0):
		sql_error_set(c, c"sql: libsqlite3.so.0 unavailable (Linux x64 required)")
		return c
	if (path == 0):
		sql_error_set(c, c"sql: SQLite path is required")
		return c
	int handle = 0
	int rc = sql_native_call(__sql_sqlite3_open_v2, cast(int, path), cast(int, &handle), 6)
	c.handle = handle
	if (rc != 0):
		if (handle != 0):
			sql_sqlite_error(c)
			sql_native_call(__sql_sqlite3_close, handle)
		else: sql_error_set(c, c"sql: SQLite open failed")
		c.handle = 0
	else: sql_native_call(__sql_sqlite3_busy_timeout, handle, 5000)
	return c

# Prepares exactly one statement and binds text parameters. Returns the
# native statement handle, or 0 with the connection error set.
int sql_sqlite_prepare(sql_connection* c, char* query, int count, char** params):
	int stmt = 0
	char* tail = 0
	int rc = sql_native_call(__sql_sqlite3_prepare_v2, c.handle, cast(int, query), -1, cast(int, &stmt), cast(int, &tail))
	if (rc != 0):
		sql_sqlite_error(c)
		if (stmt != 0): sql_native_call(__sql_sqlite3_finalize, stmt)
		return 0
	if (stmt == 0):
		sql_error_set(c, c"sql: expected one SQL statement")
		return 0
	# Prepare the tail too, accepting whitespace/comments but never executing
	# an ignored second statement. Values always go through native binding.
	while (tail != 0 && tail[0] != 0):
		int extra = 0
		char* next = 0
		rc = sql_native_call(__sql_sqlite3_prepare_v2, c.handle, cast(int, tail), -1, cast(int, &extra), cast(int, &next))
		if (rc != 0 || extra != 0):
			if (extra != 0): sql_native_call(__sql_sqlite3_finalize, extra)
			sql_native_call(__sql_sqlite3_finalize, stmt)
			sql_error_set(c, c"sql: expected one SQL statement")
			return 0
		tail = next
	if (sql_native_call(__sql_sqlite3_bind_parameter_count, stmt) != count):
		sql_native_call(__sql_sqlite3_finalize, stmt)
		sql_error_set(c, c"sql: parameter count mismatch")
		return 0
	for i in range(count):
		if (params[i] == 0): rc = sql_native_call(__sql_sqlite3_bind_null, stmt, i + 1)
		else: rc = sql_native_call(__sql_sqlite3_bind_text, stmt, i + 1, cast(int, params[i]), -1, -1)
		if (rc != 0):
			sql_sqlite_error(c)
			sql_native_call(__sql_sqlite3_finalize, stmt)
			return 0
	return stmt

sql_result* sql_sqlite_query(sql_connection* c, char* query, int count, char** params):
	int before = sql_native_call(__sql_sqlite3_total_changes64, c.handle)
	int stmt = sql_sqlite_prepare(c, query, count, params)
	if (stmt == 0): return 0
	int rc = 0
	int columns = sql_native_call(__sql_sqlite3_column_count, stmt)
	if (columns > SQL_MAX_COLUMNS):
		sql_native_call(__sql_sqlite3_finalize, stmt)
		sql_error_set(c, c"sql: column limit exceeded")
		return 0
	sql_result* r = sql_result_new(columns)
	int ok = 1
	for col in range(columns):
		char* name = cast(char*, sql_native_call(__sql_sqlite3_column_name, stmt, col))
		if (sql_result_name(c, r, name, strlen(name)) == 0): ok = 0
	while (ok):
		rc = sql_native_call(__sql_sqlite3_step, stmt)
		if (rc == 101): break
		if (rc != 100):
			sql_sqlite_error(c)
			ok = 0
			break
		if (r.rows >= SQL_MAX_ROWS):
			ok = sql_error_set(c, c"sql: row limit exceeded")
			break
		for col in range(columns):
			int kind = sql_native_call(__sql_sqlite3_column_type, stmt, col)
			char* value = 0
			int length = -1
			if (kind != 5):
				if (kind == 4): value = cast(char*, sql_native_call(__sql_sqlite3_column_blob, stmt, col))
				else: value = cast(char*, sql_native_call(__sql_sqlite3_column_text, stmt, col))
				length = sql_native_call(__sql_sqlite3_column_bytes, stmt, col)
			if (sql_result_cell(c, r, value, length) == 0):
				ok = 0
				break
		r.rows = r.rows + 1
	if (ok && columns == 0): r.affected = sql_native_call(__sql_sqlite3_total_changes64, c.handle) - before
	rc = sql_native_call(__sql_sqlite3_finalize, stmt)
	if (ok && rc != 0):
		sql_sqlite_error(c)
		ok = 0
	if (ok == 0):
		sql_result_free(r)
		return 0
	return r

# Streaming: the statement stays prepared on the cursor until it ends or is freed.
int sql_sqlite_cursor_open(sql_connection* c, sql_cursor* cur, char* query, int count, char** params):
	int stmt = sql_sqlite_prepare(c, query, count, params)
	if (stmt == 0): return 0
	int columns = sql_native_call(__sql_sqlite3_column_count, stmt)
	if (columns > SQL_MAX_COLUMNS):
		sql_native_call(__sql_sqlite3_finalize, stmt)
		return sql_error_set(c, c"sql: column limit exceeded")
	for col in range(columns):
		char* name = cast(char*, sql_native_call(__sql_sqlite3_column_name, stmt, col))
		cur.names.push(sql_copy(name, strlen(name)))
	cur.columns = columns
	cur.handle = stmt
	return 1

# 1 = row, 0 = done, -1 = error (connection error set).
int sql_sqlite_cursor_step(sql_connection* c, sql_cursor* cur):
	int rc = sql_native_call(__sql_sqlite3_step, cur.handle)
	if (rc == 100): return 1
	if (rc == 101): return 0
	sql_sqlite_error(c)
	return -1

# Finalizes the statement. Returns 0 (with the error set) if finalize reports one.
int sql_sqlite_cursor_close(sql_connection* c, sql_cursor* cur):
	if (cur.handle == 0): return 1
	int rc = sql_native_call(__sql_sqlite3_finalize, cur.handle)
	cur.handle = 0
	return rc == 0

# Borrowed until the next step. Non-NULL values are NUL-terminated; text
# conversion of a BLOB keeps its bytes (embedded NULs included).
char* sql_sqlite_cursor_value(sql_cursor* cur, int col):
	if (sql_native_call(__sql_sqlite3_column_type, cur.handle, col) == 5): return 0
	char* value = cast(char*, sql_native_call(__sql_sqlite3_column_text, cur.handle, col))
	if (value == 0): return c""
	return value

int sql_sqlite_cursor_value_length(sql_cursor* cur, int col):
	if (sql_native_call(__sql_sqlite3_column_type, cur.handle, col) == 5): return -1
	sql_native_call(__sql_sqlite3_column_text, cur.handle, col)
	return sql_native_call(__sql_sqlite3_column_bytes, cur.handle, col)
