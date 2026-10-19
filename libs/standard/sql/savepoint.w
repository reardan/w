# Savepoints (nested transactions) on top of sql_begin/sql_commit/sql_rollback.
# SQLite and PostgreSQL only. See docs/projects/orm/u0_3.md.
import libs.standard.sql.client
import lib.mem

const int SQL_SAVEPOINT_NAME_MAX = 63

# 1 when name is an ASCII identifier (letters, digits, underscore, not
# starting with a digit) of 1..63 bytes.
int sql_savepoint_name_valid(char* name):
	if (name == 0): return 0
	int n = 0
	while (name[n] != 0):
		int ch = name[n] & 255
		int alpha = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
		int digit = ch >= '0' && ch <= '9'
		if (alpha == 0 && digit == 0): return 0
		if (n == 0 && digit): return 0
		n = n + 1
		if (n > SQL_SAVEPOINT_NAME_MAX): return 0
	return n > 0

# Allocated "w_sp_<depth>" for the ORM's nesting; 0 for a negative depth.
char* sql_savepoint_name(int depth):
	if (depth < 0): return 0
	char* digits = itoa(depth)
	int n = strlen(digits)
	char* name = cast(char*, malloc(n + 6))
	mem_copy(name, c"w_sp_", 5)
	mem_copy(cast(char*, &name[5]), digits, n + 1)
	free(digits)
	return name

# prefix + "\"" + name + "\"" as an allocated string. name is already valid,
# so it holds no quote characters.
char* sql_savepoint_statement(char* prefix, char* name):
	int p = strlen(prefix)
	int n = strlen(name)
	char* s = cast(char*, malloc(p + n + 3))
	mem_copy(s, prefix, p)
	s[p] = '"'
	mem_copy(cast(char*, &s[p + 1]), name, n)
	s[p + n + 1] = '"'
	s[p + n + 2] = 0
	return s

int sql_savepoint_run(sql_connection* c, char* prefix, char* name):
	if (c == 0): return 0
	sql_error_set(c, c"")
	if (c.driver != SQL_SQLITE && c.driver != SQL_POSTGRES):
		return sql_error_set(c, c"sql: savepoints are not supported for this client")
	if (c.handle == 0): return sql_error_set(c, c"sql: connection is closed")
	if (c.transaction == 0): return sql_error_set(c, c"sql: savepoint requires an active transaction (sql_begin)")
	if (sql_savepoint_name_valid(name) == 0):
		return sql_error_set(c, c"sql: invalid savepoint name (ASCII letters, digits, underscore; not starting with a digit; at most 63 bytes)")
	char* query = sql_savepoint_statement(prefix, name)
	int ok = sql_exec(c, query)
	free(query)
	return ok

int sql_savepoint(sql_connection* c, char* name):
	return sql_savepoint_run(c, c"SAVEPOINT ", name)

# Releases name and every savepoint opened after it; their work stays in
# the enclosing transaction.
int sql_release_savepoint(sql_connection* c, char* name):
	return sql_savepoint_run(c, c"RELEASE SAVEPOINT ", name)

# Undoes work since name was opened and keeps name open. On PostgreSQL this
# also clears an aborted transaction state left by a failed statement.
int sql_rollback_to_savepoint(sql_connection* c, char* name):
	return sql_savepoint_run(c, c"ROLLBACK TO SAVEPOINT ", name)
