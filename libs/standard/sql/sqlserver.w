# SQL Server through FreeTDS DB-Library (native TDS, no ODBC).
import libs.standard.sql.sqlserver_native

sql_connection* __sql_tds_current
int __sql_tds_initialized

# FreeTDS's C callbacks enter W through a six-argument System V bridge.
# Save all C callee-saved registers; push register args in W argument order.
# The message callback's two trailing C arguments are intentionally unused.
int sql_tds_callback(int target):
	char* code = c"\x55\x53\x41\x54\x41\x55\x41\x56\x41\x57\x57\x56\x52\x51\x41\x50\x41\x51\x48\xb8\x00\x00\x00\x00\x00\x00\x00\x00\xff\xd0\x48\x83\xc4\x30\x41\x5f\x41\x5e\x41\x5d\x41\x5c\x5b\x5d\xc3"
	int page = mmap(0, 4096, 3, 34)
	if (page < 0): return 0
	mem_copy(cast(char*, page), code, 45)
	save_i(cast(char*, page + 20), target, 8)
	if (mprotect(page, 4096, 5) != 0):
		munmap(page, 4096)
		return 0
	return page

int sql_tds_error_callback(int process, int severity, int number, int os_number, char* message, char* os_message):
	if (__sql_tds_current != 0 && message != 0): sql_error_set(__sql_tds_current, message)
	return 2    # INT_CANCEL; default FreeTDS handling can terminate the process.

int sql_tds_message_callback(int process, int number, int state, int severity, char* message, char* server):
	if (severity >= 11 && __sql_tds_current != 0 && message != 0): sql_error_set(__sql_tds_current, message)
	return 0

int sql_tds_failure(sql_connection* c):
	if (sql_error(c)[0] == 0): sql_error_set(c, c"sql: FreeTDS operation failed")
	return 0

# server is a freetds.conf alias or host:port. TLS is configured in FreeTDS.
sql_connection* sql_open_sqlserver(char* server, char* user, char* password, char* database):
	sql_connection* c = sql_connection_new(SQL_SQLSERVER)
	if (sql_sqlserver_available() == 0):
		sql_error_set(c, c"sql: libsybdb.so.5 unavailable (Linux x64 required)")
		return c
	if (server == 0 || user == 0 || password == 0 || database == 0):
		sql_error_set(c, c"sql: SQL Server connection arguments are required")
		return c
	__sql_tds_current = c
	if (__sql_tds_initialized == 0):
		int errors = sql_tds_callback(cast(int, sql_tds_error_callback))
		int messages = sql_tds_callback(cast(int, sql_tds_message_callback))
		if (errors == 0 || messages == 0):
			sql_error_set(c, c"sql: unable to create FreeTDS callbacks")
			return c
		if (sql_native_call(__sql_dbinit) != 1):
			sql_tds_failure(c)
			return c
		# dbinit resets FreeTDS's error handler; install ours afterwards.
		sql_native_call(__sql_dberrhandle, errors)
		sql_native_call(__sql_dbmsghandle, messages)
		__sql_tds_initialized = 1
	int login = sql_native_call(__sql_dblogin)
	if (login == 0):
		sql_tds_failure(c)
		return c
	int ok = sql_native_call(__sql_dbsetlname, login, cast(int, user), 2) == 1
	if (sql_native_call(__sql_dbsetlname, login, cast(int, password), 3) != 1): ok = 0
	if (sql_native_call(__sql_dbsetlname, login, cast(int, c"UTF-8"), 10) != 1): ok = 0
	if (sql_native_call(__sql_dbsetlversion, login, 8) != 1): ok = 0
	if (ok): c.handle = sql_native_call(__sql_tdsdbopen, login, cast(int, server), 1)
	sql_native_call(__sql_dbloginfree, login)
	if (c.handle == 0): sql_tds_failure(c)
	else if (sql_native_call(__sql_dbuse, c.handle, cast(int, database)) != 1):
		sql_tds_failure(c)
		sql_native_call(__sql_dbclose, c.handle)
		c.handle = 0
	return c

sql_result* sql_sqlserver_query(sql_connection* c, char* query):
	__sql_tds_current = c
	if (sql_native_call(__sql_dbcmd, c.handle, cast(int, query)) != 1 || sql_native_call(__sql_dbsqlexec, c.handle) != 1):
		sql_tds_failure(c)
		sql_native_call(__sql_dbcancel, c.handle)
		return 0
	sql_result* r = sql_result_new(0)
	int ok = 1
	int seen = 0
	while (ok):
		int rc = sql_native_call(__sql_dbresults, c.handle)
		if (rc == 2): break
		if (rc != 1 || sql_error(c)[0] != 0):
			ok = sql_tds_failure(c)
			break
		int columns = sql_native_call(__sql_dbnumcols, c.handle)
		if (columns == 0):
			r.affected = sql_native_call(__sql_dbcount, c.handle)
			continue
		if (seen || columns > SQL_MAX_COLUMNS):
			ok = sql_error_set(c, c"sql: multiple result sets or excessive columns")
			break
		seen = 1
		r.columns = columns
		for col in range(columns):
			char* name = cast(char*, sql_native_call(__sql_dbcolname, c.handle, col + 1))
			if (sql_result_name(c, r, name, strlen(name)) == 0): ok = 0
		while (ok):
			rc = sql_native_call(__sql_dbnextrow, c.handle)
			if (rc == -2): break
			if (rc != -1):
				ok = sql_tds_failure(c)
				break
			if (r.rows >= SQL_MAX_ROWS):
				ok = sql_error_set(c, c"sql: row limit exceeded")
				break
			for col in range(columns):
				char* data = cast(char*, sql_native_call(__sql_dbdata, c.handle, col + 1))
				int length = sql_native_call(__sql_dbdatlen, c.handle, col + 1)
				if (data == 0): ok = sql_result_cell(c, r, data, -1)
				else if (length < 0 || length > SQL_MAX_CELL): ok = sql_error_set(c, c"sql: cell size limit exceeded")
				else:
					int kind = sql_native_call(__sql_dbcoltype, c.handle, col + 1)
					# Preserve raw binary; convert scalar types using FreeTDS.
					if (kind == 34 || kind == 37 || kind == 45): ok = sql_result_cell(c, r, data, length)
					else:
						int capacity = length * 4 + 256
						if (capacity > SQL_MAX_CELL): capacity = SQL_MAX_CELL
						char* text = cast(char*, malloc(capacity))
						int n = sql_native_call(__sql_dbconvert, c.handle, kind, cast(int, data), length, 47, cast(int, text), capacity)
						if (n < 0): ok = sql_tds_failure(c)
						else: ok = sql_result_cell(c, r, text, n)
						free(text)
				if (ok == 0): break
			r.rows = r.rows + 1
	if (sql_error(c)[0] != 0): ok = 0
	if (ok == 0):
		sql_native_call(__sql_dbcancel, c.handle)
		sql_result_free(r)
		return 0
	return r
