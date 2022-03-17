import integer


char *code
int code_size
int codepos
int base_code_offset
int code_offset

int word_size
int word_size_log2


void resize_code(int n):
	if (code_size <= codepos + n):
		int x = (codepos + n) << 1
		code = realloc(code, code_size, x)
		code_size = x


void emit(int n, char *s):
	resize_code(n)
	int i = 0
	while (i < n):
		code[codepos] = s[i]
		codepos = codepos + 1
		i = i + 1


void emit_string(char* s):
	emit(strlen(s) + 1, s)


void emit_string_raw(char* s):
	print_int("strlen(s)= ", strlen(s))
	emit(strlen(s), s)


void emit_i(int v, int n):
	resize_code(n)
	char* p = code + codepos
	save_i(p, v, n)
	codepos = codepos + n


void emit_int8(int v):
	emit_i(v, 1)


void emit_int16(int v):
	emit_i(v, 2)


void emit_int32(int v):
	emit_i(v, 4)


void emit_int64(int v):
	emit_i(v, 8)


void emit_int(int v):
	emit_int32(v)


void emit_zeros(int num):
	while (num > 0):
		emit_int8(0)
		num = num - 1
