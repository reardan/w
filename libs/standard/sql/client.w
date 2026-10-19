# Public facade for the five native clients in issue #495.
# Synchronous, single-threaded Linux x64 API. See docs/projects/sql.md.
import libs.standard.sql.sqlite
import libs.standard.sql.postgres
import libs.standard.sql.mysql
import libs.standard.sql.sqlserver
import libs.standard.sql.oracle

# Text parameters, NULL pointer = SQL NULL. Placeholder syntax stays native:
# SQLite ? / ?1, PostgreSQL $1, Oracle :1. MySQL/FreeTDS currently accept
# only trusted SQL with no parameters; requests for binding fail explicitly.
sql_result* sql_query_params(sql_connection* c, char* query, int count, char** params):
	if (c == 0): return 0
	sql_error_set(c, c"")
	if (c.handle == 0):
		sql_error_set(c, c"sql: connection is closed")
		return 0
	if (query == 0 || count < 0 || count > 32767 || (count > 0 && params == 0)):
		sql_error_set(c, c"sql: invalid query arguments")
		return 0
	if (c.cursor != 0):
		sql_error_set(c, c"sql: connection has an open cursor; free it first")
		return 0
	if (c.driver == SQL_SQLITE): return sql_sqlite_query(c, query, count, params)
	if (c.driver == SQL_POSTGRES): return sql_postgres_query(c, query, count, params)
	if (c.driver == SQL_ORACLE): return sql_oracle_query(c, query, count, params)
	if (count != 0):
		sql_error_set(c, c"sql: parameter binding is not implemented for this client")
		return 0
	if (c.driver == SQL_MYSQL): return sql_mysql_query(c, query)
	if (c.driver == SQL_SQLSERVER): return sql_sqlserver_query(c, query)
	sql_error_set(c, c"sql: unknown driver")
	return 0

sql_result* sql_query(sql_connection* c, char* query):
	return sql_query_params(c, query, 0, cast(char**, 0))

# Commands and queries share one result contract. Exec discards any rows.
int sql_exec(sql_connection* c, char* query):
	sql_result* r = sql_query(c, query)
	if (r == 0): return 0
	sql_result_free(r)
	return 1

int sql_begin(sql_connection* c):
	if (c == 0): return 0
	if (c.cursor != 0): return sql_error_set(c, c"sql: connection has an open cursor; free it first")
	if (c.handle == 0 || c.transaction): return sql_error_set(c, c"sql: transaction requires an open, idle connection")
	int ok = 1
	if (c.driver == SQL_SQLSERVER): ok = sql_exec(c, c"BEGIN TRANSACTION")
	else if (c.driver != SQL_ORACLE): ok = sql_exec(c, c"BEGIN")
	else: sql_error_set(c, c"")
	if (ok): c.transaction = 1
	return ok

int sql_end_transaction(sql_connection* c, int commit):
	if (c == 0): return 0
	if (c.handle == 0 || c.transaction == 0): return sql_error_set(c, c"sql: no active transaction")
	if (c.cursor != 0): return sql_error_set(c, c"sql: connection has an open cursor; free it first")
	# PostgreSQL accepts COMMIT in an aborted transaction but performs a
	# rollback. Do not report that as a successfully committed transaction.
	if (commit && c.driver == SQL_POSTGRES && sql_native_call(__sql_PQtransactionStatus, c.handle) == 3):
		if (sql_exec(c, c"ROLLBACK")): c.transaction = 0
		return sql_error_set(c, c"sql: PostgreSQL transaction was aborted and could not commit")
	int ok = 0
	if (c.driver == SQL_ORACLE):
		sql_error_set(c, c"")
		int stub = __sql_OCITransRollback
		if (commit): stub = __sql_OCITransCommit
		ok = sql_oracle_ok(c, sql_native_call(stub, c.handle, c.error_handle, 0))
	else if (commit): ok = sql_exec(c, c"COMMIT")
	else: ok = sql_exec(c, c"ROLLBACK")
	if (ok): c.transaction = 0
	return ok

int sql_commit(sql_connection* c): return sql_end_transaction(c, 1)
int sql_rollback(sql_connection* c): return sql_end_transaction(c, 0)

# Releases native state and unlocks the connection. finished = the native
# command already completed, so nothing needs cancelling or draining.
void sql_cursor_detach(sql_cursor* cur, int finished):
	sql_connection* c = cur.connection
	if (c == 0): return
	if (cur.driver == SQL_SQLITE): sql_sqlite_cursor_close(c, cur)
	else: sql_postgres_cursor_close(c, cur, finished)
	if (c.cursor == cast(int, cur)): c.cursor = 0
	cur.connection = 0

# Finalizes (SQLite) or cancels and drains (PostgreSQL) an unfinished cursor;
# the connection stays usable. Safe after sql_close and on 0.
void sql_cursor_free(sql_cursor* cur):
	if (cur == 0): return
	sql_cursor_detach(cur, 0)
	for i in range(cur.names.length): free(cur.names[i])
	cur.names.free()
	free(cur)

# Frees the connection, including failed opens. Results are independent copies.
# Native disconnect rolls back an outstanding uncommitted transaction.
void sql_close(sql_connection* c):
	if (c == 0): return
	# Native close/finish discards the unfinished command; no need to drain.
	if (c.cursor != 0): sql_cursor_detach(cast(sql_cursor*, c.cursor), 1)
	if (c.handle != 0):
		if (c.driver == SQL_SQLITE): sql_native_call(__sql_sqlite3_close, c.handle)
		else if (c.driver == SQL_POSTGRES): sql_native_call(__sql_PQfinish, c.handle)
		else if (c.driver == SQL_MYSQL): sql_native_call(__sql_mysql_close, c.handle)
		else if (c.driver == SQL_SQLSERVER):
			__sql_tds_current = c
			sql_native_call(__sql_dbclose, c.handle)
	if (c.driver == SQL_ORACLE && c.environment != 0): sql_oracle_release(c)
	if (__sql_tds_current == c): __sql_tds_current = 0
	if (c.error != 0): free(c.error)
	free(c)

# Streaming cursors (SQLite and PostgreSQL). Rows are read one at a time with
# no row or total-size limit. While a cursor is open (until it reaches the end,
# fails, or is freed) every other query on its connection fails. Returns an
# owned cursor, or 0 with sql_error(c) set.
sql_cursor* sql_query_cursor(sql_connection* c, char* query, int count, char** params):
	if (c == 0): return 0
	sql_error_set(c, c"")
	if (c.handle == 0):
		sql_error_set(c, c"sql: connection is closed")
		return 0
	if (query == 0 || count < 0 || count > 32767 || (count > 0 && params == 0)):
		sql_error_set(c, c"sql: invalid query arguments")
		return 0
	if (c.cursor != 0):
		sql_error_set(c, c"sql: connection has an open cursor; free it first")
		return 0
	if (c.driver != SQL_SQLITE && c.driver != SQL_POSTGRES):
		sql_error_set(c, c"sql: cursors are only implemented for SQLite and PostgreSQL")
		return 0
	sql_cursor* cur = new sql_cursor()
	cur.connection = c
	cur.driver = c.driver
	cur.names = new list[char*]
	int ok = 0
	if (c.driver == SQL_SQLITE): ok = sql_sqlite_cursor_open(c, cur, query, count, params)
	else: ok = sql_postgres_cursor_open(c, cur, query, count, params)
	if (ok == 0):
		cur.connection = 0
		sql_cursor_free(cur)
		return 0
	if (cur.state == 2): cur.connection = 0
	else: c.cursor = cast(int, cur)
	return cur

# 1 = a row is available, 0 = end of rows, -1 = error (see sql_error of the
# connection). The connection is released as soon as 0 or -1 is returned.
# A cursor whose connection was closed returns -1.
int sql_cursor_next(sql_cursor* cur):
	if (cur == 0): return -1
	if (cur.state == 2): return 0
	if (cur.state == -1): return -1
	sql_connection* c = cur.connection
	if (c == 0 || c.handle == 0):
		cur.state = -1
		return -1
	int rc = 0
	if (cur.driver == SQL_SQLITE): rc = sql_sqlite_cursor_step(c, cur)
	else: rc = sql_postgres_cursor_step(c, cur)
	if (rc == 1):
		cur.state = 1
		return 1
	if (rc == 0):
		if (cur.driver == SQL_SQLITE && sql_sqlite_cursor_close(c, cur) == 0):
			sql_sqlite_error(c)
			rc = -1
	cur.state = 2
	if (rc < 0): cur.state = -1
	sql_cursor_detach(cur, 1)
	return rc

int sql_cursor_columns(sql_cursor* cur):
	if (cur == 0): return 0
	return cur.columns

# Borrowed until sql_cursor_free.
char* sql_cursor_column_name(sql_cursor* cur, int col):
	if (cur == 0 || col < 0 || col >= cur.names.length): return 0
	return cur.names[col]

int sql_cursor_has_row(sql_cursor* cur, int col):
	return cur != 0 && cur.state == 1 && cur.connection != 0 && col >= 0 && col < cur.columns

# Borrowed until the next sql_cursor_next or sql_cursor_free. NULL and invalid
# requests return 0; use sql_cursor_value_length for binary data.
char* sql_cursor_value(sql_cursor* cur, int col):
	if (sql_cursor_has_row(cur, col) == 0): return 0
	if (cur.driver == SQL_SQLITE): return sql_sqlite_cursor_value(cur, col)
	return sql_postgres_cursor_value(cur, col)

# Byte length, -1 for SQL NULL, -2 for an invalid column or no current row.
int sql_cursor_value_length(sql_cursor* cur, int col):
	if (sql_cursor_has_row(cur, col) == 0): return -2
	if (cur.driver == SQL_SQLITE): return sql_sqlite_cursor_value_length(cur, col)
	return sql_postgres_cursor_value_length(cur, col)
