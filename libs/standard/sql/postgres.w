import libs.standard.sql.postgres_native

# libpq conninfo string or URI; libpq owns TLS/authentication negotiation.
sql_connection* sql_open_postgres(char* conninfo):
	sql_connection* c = sql_connection_new(SQL_POSTGRES)
	if (sql_postgres_available() == 0):
		sql_error_set(c, c"sql: libpq.so.5 unavailable (Linux x64 required)")
		return c
	if (conninfo == 0):
		sql_error_set(c, c"sql: PostgreSQL conninfo is required")
		return c
	c.handle = sql_native_call(__sql_PQconnectdb, cast(int, conninfo))
	if (c.handle == 0): sql_error_set(c, c"sql: PostgreSQL allocation failed")
	else if (sql_native_call(__sql_PQstatus, c.handle) != 0):
		sql_error_set(c, cast(char*, sql_native_call(__sql_PQerrorMessage, c.handle)))
		sql_native_call(__sql_PQfinish, c.handle)
		c.handle = 0
	return c

sql_result* sql_postgres_query(sql_connection* c, char* query, int count, char** params):
	# Extended query protocol: one command, text results, $1-style parameters.
	int result = sql_native_call(__sql_PQexecParams, c.handle, cast(int, query), count, 0, cast(int, params), 0, 0, 0)
	if (result == 0):
		sql_error_set(c, cast(char*, sql_native_call(__sql_PQerrorMessage, c.handle)))
		return 0
	int status = sql_native_call(__sql_PQresultStatus, result)
	if (status != 1 && status != 2):
		if (status == 3 || status == 4 || status == 8):
			# COPY leaves libpq in a streaming state. Closing is the only safe
			# basic-client recovery without implementing its separate protocol.
			sql_error_set(c, c"sql: COPY is unsupported; connection closed")
			sql_native_call(__sql_PQfinish, c.handle)
			c.handle = 0
		else: sql_error_set(c, cast(char*, sql_native_call(__sql_PQresultErrorMessage, result)))
		sql_native_call(__sql_PQclear, result)
		return 0
	int columns = sql_native_call(__sql_PQnfields, result)
	int rows = sql_native_call(__sql_PQntuples, result)
	if (columns > SQL_MAX_COLUMNS || rows > SQL_MAX_ROWS):
		sql_native_call(__sql_PQclear, result)
		sql_error_set(c, c"sql: result dimensions exceed limits")
		return 0
	sql_result* r = sql_result_new(columns)
	int ok = 1
	for col in range(columns):
		char* name = cast(char*, sql_native_call(__sql_PQfname, result, col))
		if (sql_result_name(c, r, name, strlen(name)) == 0): ok = 0
	int row = 0
	while (ok && row < rows):
		for col in range(columns):
			int length = -1
			char* value = 0
			if (sql_native_call(__sql_PQgetisnull, result, row, col) == 0):
				value = cast(char*, sql_native_call(__sql_PQgetvalue, result, row, col))
				length = sql_native_call(__sql_PQgetlength, result, row, col)
			if (sql_result_cell(c, r, value, length) == 0):
				ok = 0
				break
		row = row + 1
	r.rows = rows
	char* affected = cast(char*, sql_native_call(__sql_PQcmdTuples, result))
	if (affected != 0 && affected[0] != 0): r.affected = atoi(affected)
	sql_native_call(__sql_PQclear, result)
	if (ok == 0):
		sql_result_free(r)
		return 0
	return r

# Streaming uses libpq single-row mode: one PGresult per row, then a final
# TUPLES_OK/COMMAND_OK result, then null. The connection is busy until null.

# Discards results until libpq reports the command finished.
void sql_postgres_drain(sql_connection* c):
	while (1):
		int result = sql_native_call(__sql_PQgetResult, c.handle)
		if (result == 0): return
		int status = sql_native_call(__sql_PQresultStatus, result)
		sql_native_call(__sql_PQclear, result)
		if (status == 3 || status == 4 || status == 8):
			# See sql_postgres_query: COPY cannot be drained by this client.
			sql_native_call(__sql_PQfinish, c.handle)
			c.handle = 0
			return

# Consumes a non-row result: 0 = command finished (drained), -1 = error set.
int sql_postgres_cursor_finish(sql_connection* c, int result):
	int status = sql_native_call(__sql_PQresultStatus, result)
	if (status == 1 || status == 2):
		sql_native_call(__sql_PQclear, result)
		sql_postgres_drain(c)
		return 0
	if (status == 3 || status == 4 || status == 8):
		sql_native_call(__sql_PQclear, result)
		sql_error_set(c, c"sql: COPY is unsupported; connection closed")
		sql_native_call(__sql_PQfinish, c.handle)
		c.handle = 0
		return -1
	char* message = cast(char*, sql_native_call(__sql_PQresultErrorMessage, result))
	if (status == 0): message = c"sql: expected one SQL statement"
	else if (message == 0 || message[0] == 0): message = c"sql: PostgreSQL query failed"
	sql_error_set(c, message)
	sql_native_call(__sql_PQclear, result)
	sql_postgres_drain(c)
	return -1

# 1 = opened (cur.pending holds the first row, or cur.state is 2 when the
# command produced no rows), 0 = error set and the connection idle again.
int sql_postgres_cursor_open(sql_connection* c, sql_cursor* cur, char* query, int count, char** params):
	# Cancelling outside a transaction only aborts the streamed statement;
	# inside one it would abort the whole transaction, so drain instead.
	cur.cancel_ok = sql_native_call(__sql_PQtransactionStatus, c.handle) == 0
	if (sql_native_call(__sql_PQsendQueryParams, c.handle, cast(int, query), count, 0, cast(int, params), 0, 0, 0) != 1):
		return sql_error_set(c, cast(char*, sql_native_call(__sql_PQerrorMessage, c.handle)))
	if (sql_native_call(__sql_PQsetSingleRowMode, c.handle) != 1):
		sql_postgres_drain(c)
		return sql_error_set(c, c"sql: PostgreSQL single-row mode unavailable")
	int result = sql_native_call(__sql_PQgetResult, c.handle)
	if (result == 0): return sql_error_set(c, cast(char*, sql_native_call(__sql_PQerrorMessage, c.handle)))
	int status = sql_native_call(__sql_PQresultStatus, result)
	if (status == 9 || status == 2):
		int columns = sql_native_call(__sql_PQnfields, result)
		if (columns > SQL_MAX_COLUMNS):
			sql_native_call(__sql_PQclear, result)
			# Drain without cancelling; the error is the column limit.
			sql_postgres_drain(c)
			return sql_error_set(c, c"sql: column limit exceeded")
		for col in range(columns):
			char* name = cast(char*, sql_native_call(__sql_PQfname, result, col))
			cur.names.push(sql_copy(name, strlen(name)))
		cur.columns = columns
	if (status == 9):
		cur.pending = result
		return 1
	if (sql_postgres_cursor_finish(c, result) != 0): return 0
	cur.state = 2
	return 1

# 1 = row in cur.result, 0 = done, -1 = error (connection error set).
int sql_postgres_cursor_step(sql_connection* c, sql_cursor* cur):
	if (cur.result != 0):
		sql_native_call(__sql_PQclear, cur.result)
		cur.result = 0
	int result = cur.pending
	cur.pending = 0
	if (result == 0): result = sql_native_call(__sql_PQgetResult, c.handle)
	if (result == 0): return 0
	if (sql_native_call(__sql_PQresultStatus, result) == 9):
		cur.result = result
		return 1
	return sql_postgres_cursor_finish(c, result)

# Releases row results; an unfinished command is cancelled (outside a
# transaction) and drained so the connection accepts the next query.
void sql_postgres_cursor_close(sql_connection* c, sql_cursor* cur, int finished):
	if (cur.result != 0): sql_native_call(__sql_PQclear, cur.result)
	if (cur.pending != 0): sql_native_call(__sql_PQclear, cur.pending)
	cur.result = 0
	cur.pending = 0
	if (finished || c.handle == 0): return
	if (cur.cancel_ok):
		int cancel = sql_native_call(__sql_PQgetCancel, c.handle)
		if (cancel != 0):
			char[256] message
			sql_native_call(__sql_PQcancel, cancel, cast(int, &message[0]), 256)
			sql_native_call(__sql_PQfreeCancel, cancel)
	sql_postgres_drain(c)

# Borrowed until the next step; libpq NUL-terminates every value.
char* sql_postgres_cursor_value(sql_cursor* cur, int col):
	if (sql_native_call(__sql_PQgetisnull, cur.result, 0, col) != 0): return 0
	return cast(char*, sql_native_call(__sql_PQgetvalue, cur.result, 0, col))

int sql_postgres_cursor_value_length(sql_cursor* cur, int col):
	if (sql_native_call(__sql_PQgetisnull, cur.result, 0, col) != 0): return -1
	return sql_native_call(__sql_PQgetlength, cur.result, 0, col)
