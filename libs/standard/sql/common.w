# Basic synchronous SQL clients, Linux x64. See docs/projects/sql.md.
import lib.dlcall
import lib.mem

const int SQL_SQLITE = 1
const int SQL_POSTGRES = 2
const int SQL_MYSQL = 3
const int SQL_SQLSERVER = 4
const int SQL_ORACLE = 5
const int SQL_MAX_COLUMNS = 1024
const int SQL_MAX_ROWS = 100000
const int SQL_MAX_CELL = 1048576
const int SQL_MAX_BYTES = 67108864

struct sql_connection:
	int driver
	int handle
	int environment
	int error_handle
	char* error
	int transaction

struct sql_result:
	list[char*] names
	list[char*] values
	list[int] lengths
	int rows
	int columns
	int affected
	int bytes

# Pointer/integer C arguments only. No native structures are passed by value.
int sql_native_call13(int stub, int a0, int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12):
	int[13] args
	args[0] = a0
	args[1] = a1
	args[2] = a2
	args[3] = a3
	args[4] = a4
	args[5] = a5
	args[6] = a6
	args[7] = a7
	args[8] = a8
	args[9] = a9
	args[10] = a10
	args[11] = a11
	args[12] = a12
	return dl_call(stub, &args[0])

int sql_native_call(int stub, int a0 = 0, int a1 = 0, int a2 = 0, int a3 = 0, int a4 = 0, int a5 = 0, int a6 = 0, int a7 = 0, int a8 = 0):
	return sql_native_call13(stub, a0, a1, a2, a3, a4, a5, a6, a7, a8, 0, 0, 0, 0)

char* sql_copy(char* p, int n):
	char* copy = cast(char*, malloc(n + 1))
	if (n > 0): mem_copy(copy, p, n)
	copy[n] = 0
	return copy

int sql_error_set(sql_connection* c, char* message):
	# Copy before freeing: message may be the existing error.
	char* copy = sql_copy(message, strlen(message))
	if (c.error != 0): free(c.error)
	c.error = copy
	return 0

char* sql_error(sql_connection* c):
	if (c == 0): return c"sql: null connection"
	if (c.error == 0): return c""
	return c.error

sql_connection* sql_connection_new(int driver):
	sql_connection* c = new sql_connection()
	c.driver = driver
	return c

int sql_is_open(sql_connection* c):
	return c != 0 && c.handle != 0

sql_result* sql_result_new(int columns):
	sql_result* r = new sql_result()
	r.names = new list[char*]
	r.values = new list[char*]
	r.lengths = new list[int]
	r.columns = columns
	r.affected = -1
	return r

void sql_result_free(sql_result* r):
	if (r == 0): return
	for i in range(r.names.length): free(r.names[i])
	for i in range(r.values.length):
		if (r.values[i] != 0): free(r.values[i])
	r.names.free()
	r.values.free()
	r.lengths.free()
	free(r)

int sql_result_name(sql_connection* c, sql_result* r, char* name, int length):
	if (length < 0 || length > SQL_MAX_CELL || r.bytes > SQL_MAX_BYTES - length - 1):
		return sql_error_set(c, c"sql: result metadata limit exceeded")
	r.names.push(sql_copy(name, length))
	r.bytes = r.bytes + length + 1
	return 1

# NULL has length -1. Empty values own a non-null one-byte buffer.
int sql_result_cell(sql_connection* c, sql_result* r, char* value, int length):
	if (length < -1 || length > SQL_MAX_CELL || r.bytes > SQL_MAX_BYTES - length - 32):
		return sql_error_set(c, c"sql: result size limit exceeded")
	char* copy = 0
	if (length >= 0): copy = sql_copy(value, length)
	r.values.push(copy)
	r.lengths.push(length)
	r.bytes = r.bytes + length + 32
	return 1

char* sql_column_name(sql_result* r, int column):
	if (r == 0 || column < 0 || column >= r.names.length): return 0
	return r.names[column]

# Borrowed until sql_result_free; check sql_value_length for binary data.
char* sql_value(sql_result* r, int row, int column):
	if (r == 0 || row < 0 || row >= r.rows || column < 0 || column >= r.columns): return 0
	return r.values[row * r.columns + column]

# -1 = SQL NULL, -2 = invalid index.
int sql_value_length(sql_result* r, int row, int column):
	if (r == 0 || row < 0 || row >= r.rows || column < 0 || column >= r.columns): return -2
	return r.lengths[row * r.columns + column]
