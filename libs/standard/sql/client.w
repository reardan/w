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

# Frees the connection, including failed opens. Results are independent copies.
# Native disconnect rolls back an outstanding uncommitted transaction.
void sql_close(sql_connection* c):
	if (c == 0): return
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
