import lib.lib
import structures.string


struct url:
	char* scheme
	char* netloc
	char* path
	char* params
	char* query
	char* fragment


char* url_empty():
	return strclone(c"")


int url_is_scheme_char(int ch):
	return (('a' <= ch) & (ch <= 'z')) | (('A' <= ch) & (ch <= 'Z')) | (('0' <= ch) & (ch <= '9')) | (ch == '+') | (ch == '-') | (ch == '.')


int url_hex_value(int ch):
	if (('0' <= ch) & (ch <= '9')):
		return ch - '0'
	if (('a' <= ch) & (ch <= 'f')):
		return ch - 'a' + 10
	if (('A' <= ch) & (ch <= 'F')):
		return ch - 'A' + 10
	return -1


int url_hex_char(int value):
	if (value < 10):
		return '0' + value
	return 'A' + value - 10


int url_unreserved(int ch):
	if ((('a' <= ch) & (ch <= 'z')) | (('A' <= ch) & (ch <= 'Z')) | (('0' <= ch) & (ch <= '9'))):
		return 1
	return (ch == '-') | (ch == '.') | (ch == '_') | (ch == '~') | (ch == '/')


char* url_slice(char* text, int start, int end):
	int n = end - start
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = text[start + i]
		i = i + 1
	out[n] = 0
	return out


void url_lower_in_place(char* text):
	int i = 0
	while (text[i] != 0):
		if (('A' <= text[i]) & (text[i] <= 'Z')):
			text[i] = text[i] + 32
		i = i + 1


int url_find_scheme_end(char* text):
	if ((text[0] < 'A') | ((text[0] > 'Z') & (text[0] < 'a')) | (text[0] > 'z')):
		return -1
	int i = 1
	while (text[i] != 0):
		if (text[i] == ':'):
			return i
		if ((text[i] == '/') | (text[i] == '?') | (text[i] == '#')):
			return -1
		if (url_is_scheme_char(text[i]) == 0):
			return -1
		i = i + 1
	return -1


url* url_parse(char* text):
	url* result = new url
	result.scheme = url_empty()
	result.netloc = url_empty()
	result.path = url_empty()
	result.params = url_empty()
	result.query = url_empty()
	result.fragment = url_empty()
	if (text == 0):
		return result

	int length = strlen(text)
	int pos = 0
	int scheme_end = url_find_scheme_end(text)
	if (scheme_end >= 0):
		free(result.scheme)
		result.scheme = url_slice(text, 0, scheme_end)
		url_lower_in_place(result.scheme)
		pos = scheme_end + 1

	if ((text[pos] == '/') & (text[pos + 1] == '/')):
		pos = pos + 2
		int start = pos
		while ((text[pos] != 0) & (text[pos] != '/') & (text[pos] != '?') & (text[pos] != '#')):
			pos = pos + 1
		free(result.netloc)
		result.netloc = url_slice(text, start, pos)

	int path_start = pos
	while ((text[pos] != 0) & (text[pos] != '?') & (text[pos] != '#')):
		pos = pos + 1
	int path_end = pos
	int params_start = -1
	int scan = path_start
	while (scan < path_end):
		if (text[scan] == '/'):
			params_start = -1
		else if ((text[scan] == ';') & (params_start < 0)):
			params_start = scan
		scan = scan + 1
	if (params_start >= 0):
		free(result.path)
		free(result.params)
		result.path = url_slice(text, path_start, params_start)
		result.params = url_slice(text, params_start + 1, path_end)
	else:
		free(result.path)
		result.path = url_slice(text, path_start, path_end)

	if (text[pos] == '?'):
		pos = pos + 1
		int query_start = pos
		while ((text[pos] != 0) & (text[pos] != '#')):
			pos = pos + 1
		free(result.query)
		result.query = url_slice(text, query_start, pos)

	if (text[pos] == '#'):
		free(result.fragment)
		result.fragment = url_slice(text, pos + 1, length)
	return result


char* url_unparse(url* u):
	string_builder* s = string_new()
	if (u.scheme[0] != 0):
		string_append(s, u.scheme)
		string_append_char(s, ':')
	if (u.netloc[0] != 0):
		string_append(s, c"//")
		string_append(s, u.netloc)
	string_append(s, u.path)
	if (u.params[0] != 0):
		string_append_char(s, ';')
		string_append(s, u.params)
	if (u.query[0] != 0):
		string_append_char(s, '?')
		string_append(s, u.query)
	if (u.fragment[0] != 0):
		string_append_char(s, '#')
		string_append(s, u.fragment)
	char* result = strclone(s.data)
	string_free(s)
	return result


char* url_quote(char* text):
	string_builder* s = string_new()
	int i = 0
	while (text[i] != 0):
		int ch = text[i] & 255
		if (url_unreserved(ch)):
			string_append_char(s, ch)
		else:
			string_append_char(s, '%')
			string_append_char(s, url_hex_char((ch >> 4) & 15))
			string_append_char(s, url_hex_char(ch & 15))
		i = i + 1
	char* result = strclone(s.data)
	string_free(s)
	return result


char* url_unquote(char* text):
	string_builder* s = string_new()
	int i = 0
	while (text[i] != 0):
		if (text[i] == '%'):
			int hi = url_hex_value(text[i + 1])
			int lo = url_hex_value(text[i + 2])
			if ((hi < 0) | (lo < 0)):
				string_free(s)
				return 0
			string_append_char(s, (hi << 4) | lo)
			i = i + 3
		else:
			string_append_char(s, text[i])
			i = i + 1
	char* result = strclone(s.data)
	string_free(s)
	return result
