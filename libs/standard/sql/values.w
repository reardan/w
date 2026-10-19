# Typed access to sql_result cells (docs/projects/orm/u0_1.md).
#
# Every client returns values as text in its own textual form (SQLite
# 0/1 booleans, PostgreSQL t/f, ISO-ish timestamps). These helpers parse
# that text once. The sql_value_* readers return 1 on success and write
# *out; they return 0 and leave *out untouched for SQL NULL, an invalid
# row/column index, or text that does not parse. The sql_parse_* forms
# take a NUL-terminated string; the *_n forms take an explicit length so
# a cell holding an embedded NUL is rejected rather than truncated.
import libs.standard.sql.common
import libs.standard.time.format

# The smallest word-sized int (-2^63 on x64, -2^31 on x86).
int sql_int_min():
	return 1 << (__word_size__ * 8 - 1)

# 1 when the cell is SQL NULL. An invalid index (no such cell) also
# reports 1: there is no value to read either way.
int sql_value_is_null(sql_result* r, int row, int col):
	return sql_value_length(r, row, col) < 0

# Optional sign then one or more decimal digits, nothing else (no
# spaces, no exponent). Rejects values outside the word size.
int sql_parse_int_n(char* text, int length, int* out):
	if (text == 0 || length <= 0): return 0
	int pos = 0
	int negative = 0
	if (text[0] == '-' || text[0] == '+'):
		negative = text[0] == '-'
		pos = 1
	if (pos >= length): return 0
	# Accumulate as a negative number so the minimum int fits.
	int min = sql_int_min()
	int limit = min / 10
	int value = 0
	while (pos < length):
		int c = text[pos] & 255
		if (c < '0' || c > '9'): return 0
		int d = c - '0'
		if (value < limit): return 0
		value = value * 10
		if (value < min + d): return 0
		value = value - d
		pos = pos + 1
	if (!negative):
		if (value == min): return 0
		value = 0 - value
	*out = value
	return 1

int sql_parse_int(char* text, int* out):
	if (text == 0): return 0
	return sql_parse_int_n(text, strlen(text), out)

int sql_value_int(sql_result* r, int row, int col, int* out):
	int length = sql_value_length(r, row, col)
	if (length < 0): return 0
	return sql_parse_int_n(sql_value(r, row, col), length, out)

# Case-insensitive match of text[0..length) against a lower-case word.
int sql_text_is_word(char* text, int length, char* word):
	if (length != strlen(word)): return 0
	for i in range(length):
		int c = text[i] & 255
		if (c >= 'A' && c <= 'Z'): c = c + 32
		if (c != (word[i] & 255)): return 0
	return 1

# SQLite 0/1, PostgreSQL t/f, and true/false, in any case.
int sql_parse_bool_n(char* text, int length, int* out):
	if (text == 0 || length <= 0): return 0
	if (sql_text_is_word(text, length, c"1") || sql_text_is_word(text, length, c"t") || sql_text_is_word(text, length, c"true")):
		*out = 1
		return 1
	if (sql_text_is_word(text, length, c"0") || sql_text_is_word(text, length, c"f") || sql_text_is_word(text, length, c"false")):
		*out = 0
		return 1
	return 0

int sql_parse_bool(char* text, int* out):
	if (text == 0): return 0
	return sql_parse_bool_n(text, strlen(text), out)

int sql_value_bool(sql_result* r, int row, int col, int* out):
	int length = sql_value_length(r, row, col)
	if (length < 0): return 0
	return sql_parse_bool_n(sql_value(r, row, col), length, out)

# Splits a decimal string into its digit counts. Accepts an optional
# sign, digits, and at most one '.' with at least one digit on each side
# of it (-12.50, 7, +0.5; not .5, 5., 1e3, NaN or Infinity). *int_digits
# excludes leading zeros, so 007.10 has 1 integer and 2 fraction digits.
int sql_decimal_shape(char* text, int length, int* int_digits, int* frac_digits):
	if (text == 0 || length <= 0): return 0
	int pos = 0
	if (text[0] == '-' || text[0] == '+'): pos = 1
	int whole = 0
	int significant = 0
	while (pos < length && (text[pos] & 255) >= '0' && (text[pos] & 255) <= '9'):
		if (significant > 0 || text[pos] != '0'): significant = significant + 1
		whole = whole + 1
		pos = pos + 1
	if (whole == 0): return 0
	int frac = 0
	if (pos < length && text[pos] == '.'):
		pos = pos + 1
		while (pos < length && (text[pos] & 255) >= '0' && (text[pos] & 255) <= '9'):
			frac = frac + 1
			pos = pos + 1
		if (frac == 0): return 0
	if (pos != length): return 0
	*int_digits = significant
	*frac_digits = frac
	return 1

int sql_decimal_valid(char* text):
	if (text == 0): return 0
	int whole = 0
	int frac = 0
	return sql_decimal_shape(text, strlen(text), &whole, &frac)

# Does a valid decimal fit a DECIMAL(digits, places) column without
# rounding? At most digits - places significant integer digits and at
# most places fraction digits.
int sql_decimal_fits(char* text, int digits, int places):
	if (text == 0 || places < 0 || digits < places): return 0
	int whole = 0
	int frac = 0
	if (!sql_decimal_shape(text, strlen(text), &whole, &frac)): return 0
	return whole <= digits - places && frac <= places

# Borrowed decimal text (valid until sql_result_free).
int sql_value_decimal(sql_result* r, int row, int col, char** out):
	int length = sql_value_length(r, row, col)
	if (length < 0): return 0
	char* text = sql_value(r, row, col)
	int whole = 0
	int frac = 0
	if (!sql_decimal_shape(text, length, &whole, &frac)): return 0
	*out = text
	return 1

# Newly allocated decimal text; the caller frees it. Handles the
# minimum int.
char* sql_format_int(int v):
	return itoa(v)

# Dates and timestamps: anything Python's fromisoformat accepts, which
# covers SQLite's "YYYY-MM-DD HH:MM:SS[.fff]" and PostgreSQL's
# "YYYY-MM-DD HH:MM:SS[.ffffff][+HH[:MM]]". PostgreSQL's infinity and
# BC forms are rejected.
int sql_parse_datetime(char* text, datetime* out):
	if (text == 0): return 0
	return datetime_fromisoformat(text, out)

int sql_parse_date(char* text, date* out):
	if (text == 0): return 0
	return date_fromisoformat(text, out)

int sql_value_datetime(sql_result* r, int row, int col, datetime* out):
	int length = sql_value_length(r, row, col)
	if (length < 0): return 0
	char* text = sql_value(r, row, col)
	if (strlen(text) != length): return 0
	return datetime_fromisoformat(text, out)

int sql_value_date(sql_result* r, int row, int col, date* out):
	int length = sql_value_length(r, row, col)
	if (length < 0): return 0
	char* text = sql_value(r, row, col)
	if (strlen(text) != length): return 0
	return date_fromisoformat(text, out)
