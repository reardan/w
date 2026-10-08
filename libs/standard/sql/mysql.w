import libs.standard.sql.mysql_native

void sql_mysql_error(sql_connection* c):
	sql_error_set(c, cast(char*, sql_native_call(__sql_mysql_error, c.handle)))

# Uses the opaque MYSQL API, compatible with MySQL 8 and MariaDB Connector/C.
# flags=0 deliberately leaves multi-statement execution and LOCAL INFILE off.
sql_connection* sql_open_mysql(char* host, char* user, char* password, char* database, int port = 3306):
	sql_connection* c = sql_connection_new(SQL_MYSQL)
	if (sql_mysql_available() == 0):
		sql_error_set(c, c"sql: libmysqlclient.so.21/libmariadb.so.3 unavailable (Linux x64 required)")
		return c
	if (host == 0 || user == 0 || password == 0 || database == 0 || port < 1 || port > 65535):
		sql_error_set(c, c"sql: invalid MySQL connection arguments")
		return c
	c.handle = sql_native_call(__sql_mysql_init)
	if (c.handle == 0):
		sql_error_set(c, c"sql: MySQL allocation failed")
		return c
	int timeout = 5
	int local_infile = 0
	int ok = sql_native_call(__sql_mysql_options, c.handle, 0, cast(int, &timeout)) == 0
	if (sql_native_call(__sql_mysql_options, c.handle, 8, cast(int, &local_infile)) != 0): ok = 0
	if (ok): ok = sql_native_call(__sql_mysql_real_connect, c.handle, cast(int, host), cast(int, user), cast(int, password), cast(int, database), port, 0, 0) != 0
	if (ok): ok = sql_native_call(__sql_mysql_set_character_set, c.handle, cast(int, c"utf8mb4")) == 0
	if (ok == 0):
		sql_mysql_error(c)
		sql_native_call(__sql_mysql_close, c.handle)
		c.handle = 0
	return c

sql_result* sql_mysql_query(sql_connection* c, char* query):
	if (sql_native_call(__sql_mysql_real_query, c.handle, cast(int, query), strlen(query)) != 0):
		sql_mysql_error(c)
		return 0
	int result = sql_native_call(__sql_mysql_store_result, c.handle)
	if (result == 0 && sql_native_call(__sql_mysql_field_count, c.handle) != 0):
		sql_mysql_error(c)
		return 0
	int columns = 0
	if (result != 0): columns = sql_native_call(__sql_mysql_num_fields, result)
	sql_result* r = sql_result_new(columns)
	int ok = 1
	if (columns > SQL_MAX_COLUMNS): ok = sql_error_set(c, c"sql: column limit exceeded")
	if (ok):
		for col in range(columns):
			# MYSQL_FIELD's first member is char* name in both native clients;
			# no dependence on its size or the remainder of its layout.
			char** field = cast(char**, sql_native_call(__sql_mysql_fetch_field_direct, result, col))
			char* name = field[0]
			if (sql_result_name(c, r, name, strlen(name)) == 0): ok = 0
	while (ok && result != 0):
		char** row = cast(char**, sql_native_call(__sql_mysql_fetch_row, result))
		if (row == 0):
			if (sql_native_call(__sql_mysql_errno, c.handle) != 0):
				sql_mysql_error(c)
				ok = 0
			break
		if (r.rows >= SQL_MAX_ROWS):
			ok = sql_error_set(c, c"sql: row limit exceeded")
			break
		int* lengths = cast(int*, sql_native_call(__sql_mysql_fetch_lengths, result))
		if (lengths == 0):
			ok = sql_error_set(c, c"sql: MySQL row lengths unavailable")
			break
		for col in range(columns):
			int length = -1
			if (row[col] != 0): length = lengths[col]
			if (sql_result_cell(c, r, row[col], length) == 0):
				ok = 0
				break
		r.rows = r.rows + 1
	r.affected = sql_native_call(__sql_mysql_affected_rows, c.handle)
	if (result != 0): sql_native_call(__sql_mysql_free_result, result)
	# Stored procedures can return multiple results even with multi-statements
	# disabled. Drain all of them and report unsupported, keeping sync.
	int next = sql_native_call(__sql_mysql_next_result, c.handle)
	if (next != -1):
		if (next > 0): sql_mysql_error(c)
		else: sql_error_set(c, c"sql: multiple result sets are unsupported")
		ok = 0
		while (next == 0):
			int extra = sql_native_call(__sql_mysql_store_result, c.handle)
			if (extra != 0): sql_native_call(__sql_mysql_free_result, extra)
			next = sql_native_call(__sql_mysql_next_result, c.handle)
	if (ok == 0):
		sql_result_free(r)
		return 0
	return r
