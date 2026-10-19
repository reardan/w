# wbuild: arch_only=x64
import libs.standard.sql.client
import libs.standard.sql.values
import lib.assert

void check_int(char* text, int ok, int want):
	int got = 12345
	asserts(text, sql_parse_int(text, &got) == ok)
	if (ok): asserts(text, got == want)
	else: asserts(text, got == 12345)

void check_bool(char* text, int ok, int want):
	int got = 7
	asserts(text, sql_parse_bool(text, &got) == ok)
	if (ok): asserts(text, got == want)
	else: asserts(text, got == 7)

void check_format(int v, char* want):
	char* text = sql_format_int(v)
	assert_strings_equal(want, text)
	int back = 0
	assert1(sql_parse_int(text, &back))
	assert1(back == v)
	free(text)

void test_parsers():
	int max = ~sql_int_min()
	int min = sql_int_min()
	check_int(c"0", 1, 0)
	check_int(c"42", 1, 42)
	check_int(c"-42", 1, 0 - 42)
	check_int(c"+7", 1, 7)
	check_int(c"007", 1, 7)
	check_int(c"-0", 1, 0)
	check_int(c"9223372036854775807", 1, max)
	check_int(c"-9223372036854775808", 1, min)
	check_int(c"9223372036854775808", 0, 0)
	check_int(c"-9223372036854775809", 0, 0)
	check_int(c"99999999999999999999", 0, 0)
	check_int(c"", 0, 0)
	check_int(c"-", 0, 0)
	check_int(c"+", 0, 0)
	check_int(c" 1", 0, 0)
	check_int(c"1 ", 0, 0)
	check_int(c"1.0", 0, 0)
	check_int(c"1e3", 0, 0)
	check_int(c"0x10", 0, 0)
	check_int(c"--1", 0, 0)
	check_int(c"abc", 0, 0)
	int got = 3
	assert1(sql_parse_int(cast(char*, 0), &got) == 0)
	assert1(sql_parse_int_n(c"12", 1, &got))
	assert_equal(1, got)
	check_bool(c"1", 1, 1)
	check_bool(c"0", 1, 0)
	check_bool(c"t", 1, 1)
	check_bool(c"f", 1, 0)
	check_bool(c"T", 1, 1)
	check_bool(c"F", 1, 0)
	check_bool(c"true", 1, 1)
	check_bool(c"TRUE", 1, 1)
	check_bool(c"False", 1, 0)
	check_bool(c"", 0, 0)
	check_bool(c"2", 0, 0)
	check_bool(c"yes", 0, 0)
	check_bool(c"tru", 0, 0)
	check_bool(c"truee", 0, 0)
	check_bool(c" t", 0, 0)
	assert1(sql_parse_bool(cast(char*, 0), &got) == 0)
	assert1(sql_decimal_valid(c"-12.50"))
	assert1(sql_decimal_valid(c"12"))
	assert1(sql_decimal_valid(c"+0.5"))
	assert1(sql_decimal_valid(c"0"))
	assert1(sql_decimal_valid(c"") == 0)
	assert1(sql_decimal_valid(c"-") == 0)
	assert1(sql_decimal_valid(c".5") == 0)
	assert1(sql_decimal_valid(c"5.") == 0)
	assert1(sql_decimal_valid(c"1.2.3") == 0)
	assert1(sql_decimal_valid(c"1e3") == 0)
	assert1(sql_decimal_valid(c"NaN") == 0)
	assert1(sql_decimal_valid(c"1,5") == 0)
	assert1(sql_decimal_valid(c" 1") == 0)
	assert1(sql_decimal_valid(cast(char*, 0)) == 0)
	assert1(sql_decimal_fits(c"123.45", 5, 2))
	assert1(sql_decimal_fits(c"-999.99", 5, 2))
	assert1(sql_decimal_fits(c"0007.10", 3, 2))
	assert1(sql_decimal_fits(c"1234.5", 5, 2) == 0)
	assert1(sql_decimal_fits(c"1.234", 5, 2) == 0)
	assert1(sql_decimal_fits(c"0.5", 2, 0) == 0)
	assert1(sql_decimal_fits(c"5", 1, 2) == 0)
	assert1(sql_decimal_fits(c"x", 5, 2) == 0)
	check_format(0, c"0")
	check_format(0 - 17, c"-17")
	check_format(max, c"9223372036854775807")
	check_format(min, c"-9223372036854775808")
	datetime dt = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert1(sql_parse_datetime(c"2024-02-29 13:45:01.250", &dt))
	assert_equal(2024, dt.d.year)
	assert_equal(2, dt.d.month)
	assert_equal(29, dt.d.day)
	assert_equal(13, dt.t.hour)
	assert_equal(45, dt.t.minute)
	assert_equal(1, dt.t.second)
	assert_equal(250000000, dt.t.nanosecond)
	assert_equal(0, dt.has_offset)
	assert1(sql_parse_datetime(c"2024-01-02 03:04:05.123456+05:30", &dt))
	assert_equal(1, dt.has_offset)
	assert_equal(19800, dt.utc_offset)
	assert1(sql_parse_datetime(c"2024-01-02 03:04:05-08", &dt))
	assert_equal(0 - 28800, dt.utc_offset)
	assert1(sql_parse_datetime(c"2023-02-29 00:00:00", &dt) == 0)
	assert1(sql_parse_datetime(c"infinity", &dt) == 0)
	assert1(sql_parse_datetime(cast(char*, 0), &dt) == 0)
	date d = date_new(1, 1, 1)
	assert1(sql_parse_date(c"1999-12-31", &d))
	assert_equal(1999, d.year)
	assert_equal(31, d.day)
	assert1(sql_parse_date(c"1999-13-01", &d) == 0)
	assert1(sql_parse_date(cast(char*, 0), &d) == 0)

sql_result* values_query(sql_connection* c, char* query):
	sql_result* r = sql_query(c, query)
	asserts(sql_error(c), r != 0)
	return r

void test_sqlite():
	sql_connection* c = sql_open_sqlite(c":memory:")
	asserts(sql_error(c), sql_is_open(c))
	assert1(sql_exec(c, c"CREATE TABLE t(id INTEGER, flag BOOLEAN, price NUMERIC, note TEXT, at TEXT)"))
	char*[5] params
	params[0] = c"9223372036854775807"
	params[1] = c"1"
	params[2] = c"-12.50"
	params[3] = c"9223372036854775808"
	params[4] = c"2024-03-01 10:20:30"
	sql_result* r = sql_query_params(c, c"INSERT INTO t VALUES (?1, ?2, ?3, ?4, ?5)", 5, &params[0])
	asserts(sql_error(c), r != 0)
	sql_result_free(r)
	char* min_text = sql_format_int(sql_int_min())
	params[0] = min_text
	params[1] = c"0"
	params[2] = c"7"
	params[3] = c"abc"
	params[4] = c"2024-03-01"
	r = sql_query_params(c, c"INSERT INTO t VALUES (?1, ?2, ?3, ?4, ?5)", 5, &params[0])
	asserts(sql_error(c), r != 0)
	sql_result_free(r)
	free(min_text)
	assert1(sql_exec(c, c"INSERT INTO t VALUES (NULL, NULL, NULL, NULL, NULL)"))
	r = values_query(c, c"SELECT id, flag, price, note, at, CAST(price AS TEXT), x'310032' FROM t ORDER BY rowid")
	assert_equal(3, r.rows)
	int v = 99
	assert1(sql_value_is_null(r, 0, 0) == 0)
	assert1(sql_value_int(r, 0, 0, &v))
	assert1(v == ~sql_int_min())
	assert1(sql_value_int(r, 1, 0, &v))
	assert1(v == sql_int_min())
	assert1(sql_value_bool(r, 0, 1, &v))
	assert_equal(1, v)
	assert1(sql_value_bool(r, 1, 1, &v))
	assert_equal(0, v)
	char* text = 0
	assert1(sql_value_decimal(r, 0, 5, &text))
	assert_strings_equal(c"-12.5", text)
	assert1(sql_value_decimal(r, 1, 5, &text))
	assert_strings_equal(c"7", text)
	# Out-of-range integer text stays text in SQLite; it must not parse.
	v = 5
	assert1(sql_value_int(r, 0, 3, &v) == 0)
	assert1(sql_value_int(r, 1, 3, &v) == 0)
	assert1(sql_value_bool(r, 1, 3, &v) == 0)
	assert_equal(5, v)
	# An embedded NUL is rejected, not truncated to "1".
	assert1(sql_value_int(r, 0, 6, &v) == 0)
	assert1(sql_value_decimal(r, 0, 6, &text) == 0)
	datetime dt = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert1(sql_value_datetime(r, 0, 4, &dt))
	assert_equal(20, dt.t.minute)
	date d = date_new(1, 1, 1)
	assert1(sql_value_date(r, 1, 4, &d))
	assert_equal(3, d.month)
	assert1(sql_value_date(r, 0, 4, &d) == 0)
	assert1(sql_value_datetime(r, 0, 6, &dt) == 0)
	# NULL row: every reader fails and leaves *out alone.
	for col in range(5):
		assert1(sql_value_is_null(r, 2, col))
	v = 5
	assert1(sql_value_int(r, 2, 0, &v) == 0)
	assert1(sql_value_bool(r, 2, 1, &v) == 0)
	assert_equal(5, v)
	text = c"keep"
	assert1(sql_value_decimal(r, 2, 2, &text) == 0)
	assert_strings_equal(c"keep", text)
	assert1(sql_value_datetime(r, 2, 4, &dt) == 0)
	assert1(sql_value_date(r, 2, 4, &d) == 0)
	# Invalid indexes count as NULL.
	assert1(sql_value_is_null(r, 3, 0))
	assert1(sql_value_is_null(r, 0, 7))
	assert1(sql_value_is_null(r, -1, 0))
	assert1(sql_value_is_null(cast(sql_result*, 0), 0, 0))
	assert1(sql_value_int(r, 0, 7, &v) == 0)
	assert1(sql_value_bool(r, -1, 1, &v) == 0)
	assert1(sql_value_int(cast(sql_result*, 0), 0, 0, &v) == 0)
	assert_equal(5, v)
	sql_result_free(r)
	r = values_query(c, c"SELECT 1 = 1, 1 = 0, -9223372036854775808, '', 'TRUE'")
	assert1(sql_value_bool(r, 0, 0, &v))
	assert_equal(1, v)
	assert1(sql_value_bool(r, 0, 1, &v))
	assert_equal(0, v)
	assert1(sql_value_int(r, 0, 2, &v))
	assert1(v == sql_int_min())
	assert1(sql_value_is_null(r, 0, 3) == 0)
	assert1(sql_value_int(r, 0, 3, &v) == 0)
	assert1(sql_value_bool(r, 0, 4, &v))
	assert_equal(1, v)
	sql_result_free(r)
	sql_close(c)

int main():
	test_parsers()
	if (sql_sqlite_available() == 0):
		println(c"sql_values: SKIP SQLite (libsqlite3.so.0 unavailable)")
		return 0
	test_sqlite()
	println(c"sql_values: ok")
	return 0
