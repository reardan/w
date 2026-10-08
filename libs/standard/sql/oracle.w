import libs.standard.sql.oracle_native

int sql_oracle_ok(sql_connection* c, int rc):
	if (rc == 0 || rc == 1): return 1
	char[2048] message
	message[0] = 0
	int number = 0
	if (c.error_handle != 0): sql_native_call(__sql_OCIErrorGet, c.error_handle, 1, 0, cast(int, &number), cast(int, &message[0]), 2048, 2)
	message[2047] = 0
	if (message[0] != 0): return sql_error_set(c, &message[0])
	return sql_error_set(c, c"sql: Oracle OCI operation failed")

void sql_oracle_release(sql_connection* c):
	if (c.handle != 0): sql_native_call(__sql_OCILogoff, c.handle, c.error_handle)
	if (c.error_handle != 0): sql_native_call(__sql_OCIHandleFree, c.error_handle, 2)
	if (c.environment != 0): sql_native_call(__sql_OCIHandleFree, c.environment, 1)
	c.handle = 0
	c.error_handle = 0
	c.environment = 0

# connect_identifier is an Oracle Net alias or Easy Connect host:port/service.
sql_connection* sql_open_oracle(char* connect_identifier, char* user, char* password):
	sql_connection* c = sql_connection_new(SQL_ORACLE)
	if (sql_oracle_available() == 0):
		sql_error_set(c, c"sql: Oracle Instant Client libclntsh.so unavailable (Linux x64 required)")
		return c
	if (connect_identifier == 0 || user == 0 || password == 0):
		sql_error_set(c, c"sql: Oracle connection arguments are required")
		return c
	int env = 0
	# AL32UTF8 for both client character sets; all callback allocators default.
	int rc = sql_native_call13(__sql_OCIEnvNlsCreate, cast(int, &env), 0, 0, 0, 0, 0, 0, 0, 873, 873, 0, 0, 0)
	c.environment = env
	if (sql_oracle_ok(c, rc) == 0):
		sql_oracle_release(c)
		return c
	int error_handle = 0
	rc = sql_native_call(__sql_OCIHandleAlloc, env, cast(int, &error_handle), 2, 0, 0)
	c.error_handle = error_handle
	if (sql_oracle_ok(c, rc) == 0):
		sql_oracle_release(c)
		return c
	int handle = 0
	rc = sql_native_call13(__sql_OCILogon2, env, error_handle, cast(int, &handle), cast(int, user), strlen(user), cast(int, password), strlen(password), cast(int, connect_identifier), strlen(connect_identifier), 0, 0, 0, 0)
	c.handle = handle
	if (sql_oracle_ok(c, rc) == 0): sql_oracle_release(c)
	return c

# AttrGet writes native ub2/ub4 outputs. Zero the whole W word beforehand.
int sql_oracle_attr(sql_connection* c, int handle, int kind, int attribute, int* out):
	*out = 0
	return sql_oracle_ok(c, sql_native_call(__sql_OCIAttrGet, handle, kind, cast(int, out), 0, attribute, c.error_handle))

sql_result* sql_oracle_query(sql_connection* c, char* query, int count, char** params):
	int stmt = 0
	int rc = sql_native_call(__sql_OCIStmtPrepare2, c.handle, cast(int, &stmt), c.error_handle, cast(int, query), strlen(query), 0, 0, 1, 0)
	if (sql_oracle_ok(c, rc) == 0):
		if (stmt != 0): sql_native_call(__sql_OCIStmtRelease, stmt, c.error_handle, 0, 0, 0)
		return 0
	int* indicators = cast(int*, malloc((count + 1) * 8))
	int ok = 1
	for i in range(count):
		int bind = 0
		char* value = params[i]
		int size = 1
		indicators[i] = -1
		if (value != 0):
			indicators[i] = 0
			size = strlen(value) + 1
		else: value = c""
		# SQLT_STR; OCI copies/converts on execute, before this function returns.
		rc = sql_native_call13(__sql_OCIBindByPos, stmt, cast(int, &bind), c.error_handle, i + 1, cast(int, value), size, 5, cast(int, &indicators[i]), 0, 0, 0, 0, 0)
		if (sql_oracle_ok(c, rc) == 0):
			ok = 0
			break
	int kind = 0
	if (ok): ok = sql_oracle_attr(c, stmt, 4, 24, &kind)
	# Scalar SQL only: PL/SQL can hide implicit results and output binds.
	if (ok && (kind == 8 || kind == 9)): ok = sql_error_set(c, c"sql: PL/SQL blocks are unsupported")
	if (ok):
		int iterations = 1
		int mode = 0
		if (kind == 1): iterations = 0
		else if (c.transaction == 0): mode = 32
		rc = sql_native_call(__sql_OCIStmtExecute, c.handle, stmt, c.error_handle, iterations, 0, 0, 0, mode)
		ok = sql_oracle_ok(c, rc)
	int columns = 0
	if (ok && kind == 1): ok = sql_oracle_attr(c, stmt, 4, 18, &columns)
	if (columns > SQL_MAX_COLUMNS):
		ok = sql_error_set(c, c"sql: column limit exceeded")
		columns = 0
	sql_result* r = sql_result_new(columns)
	list[char*] buffers = new list[char*]
	# Four native output slots per column: indicator, length, return code, define.
	int* slots = cast(int*, malloc((columns + 1) * 32))
	if (ok):
		for col in range(columns):
			int param = 0
			rc = sql_native_call(__sql_OCIParamGet, stmt, 4, c.error_handle, cast(int, &param), col + 1)
			if (sql_oracle_ok(c, rc) == 0):
				ok = 0
				break
			int name = 0
			int name_length = 0
			rc = sql_native_call(__sql_OCIAttrGet, param, 53, cast(int, &name), cast(int, &name_length), 4, c.error_handle)
			ok = sql_oracle_ok(c, rc)
			if (ok): ok = sql_result_name(c, r, cast(char*, name), name_length)
			int dtype = 0
			if (ok): ok = sql_oracle_attr(c, param, 53, 2, &dtype)
			sql_native_call(__sql_OCIDescriptorFree, param, 53)
			# Reject LOBs, LONGs, objects and cursor descriptors. They need a
			# separate streaming API; never reinterpret a locator as text.
			if (ok && dtype != 1 && dtype != 2 && dtype != 12 && dtype != 23 && dtype != 96 && dtype != 100 && dtype != 101 && dtype != 180 && dtype != 181 && dtype != 182 && dtype != 183 && dtype != 231):
				ok = sql_error_set(c, c"sql: Oracle column type unsupported; CAST to VARCHAR2")
			if (ok == 0): break
			char* buffer = cast(char*, malloc(32768))
			buffers.push(buffer)
			for j in range(4): slots[col * 4 + j] = 0
			int output_type = 1
			if (dtype == 23): output_type = 23
			rc = sql_native_call13(__sql_OCIDefineByPos, stmt, cast(int, &slots[col * 4 + 3]), c.error_handle, col + 1, cast(int, buffer), 32767, output_type, cast(int, &slots[col * 4]), cast(int, &slots[col * 4 + 1]), cast(int, &slots[col * 4 + 2]), 0, 0, 0)
			if (sql_oracle_ok(c, rc) == 0):
				ok = 0
				break
	while (ok && columns > 0):
		rc = sql_native_call(__sql_OCIStmtFetch2, stmt, c.error_handle, 1, 2, 0, 0)
		if (rc == 100): break
		if (sql_oracle_ok(c, rc) == 0):
			ok = 0
			break
		if (r.rows >= SQL_MAX_ROWS):
			ok = sql_error_set(c, c"sql: row limit exceeded")
			break
		for col in range(columns):
			int indicator = slots[col * 4] & 65535
			int length = slots[col * 4 + 1] & 65535
			if (indicator == 65535): length = -1
			else if (indicator != 0 || slots[col * 4 + 2] != 0 || length > 32767):
				ok = sql_error_set(c, c"sql: Oracle value truncated or conversion failed")
				break
			if (sql_result_cell(c, r, buffers[col], length) == 0):
				ok = 0
				break
		r.rows = r.rows + 1
	if (ok && columns == 0): ok = sql_oracle_attr(c, stmt, 4, 9, &r.affected)
	rc = sql_native_call(__sql_OCIStmtRelease, stmt, c.error_handle, 0, 0, 0)
	if (ok): ok = sql_oracle_ok(c, rc)
	for i in range(buffers.length): free(buffers[i])
	buffers.free()
	free(slots)
	free(indicators)
	if (ok == 0):
		sql_result_free(r)
		return 0
	return r
