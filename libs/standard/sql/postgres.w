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
