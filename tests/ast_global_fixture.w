# Storage descriptors, scalar widths, early constants and TLS layout.
struct ast_global_inner:
	int tag
	int[3] values

struct ast_global_outer:
	ast_global_inner inner
	char[5] text
	int tail

ast_global_outer ast_global_record
int[4] ast_global_array
const int ast_global_base = 19
int ast_global_derived = ast_global_base * 2 + 4
uint8 ast_global_small = 255
int16 ast_global_signed = -123
int* ast_global_null = 0
thread_local int ast_global_tls
thread_local int16 ast_global_tls_small

int main():
	if (ast_global_derived != 42 || ast_global_small != 255 || ast_global_signed != -123): return 1
	if (ast_global_null != 0 || ast_global_tls != 0 || ast_global_tls_small != 0): return 2
	if (ast_global_record.inner.values[0] != 0 || ast_global_record.text[4] != 0 || ast_global_array[3] != 0): return 3
	ast_global_record.inner.tag = 7
	ast_global_record.inner.values[2] = 23
	ast_global_record.text[4] = 'z'
	ast_global_record.tail = 11
	ast_global_array[3] = 29
	ast_global_tls = 31
	ast_global_tls_small = -17
	if (ast_global_record.inner.tag != 7 || ast_global_record.inner.values[2] != 23): return 4
	if (ast_global_record.text[4] != 'z' || ast_global_record.tail != 11 || ast_global_array[3] != 29): return 5
	if (ast_global_tls != 31 || ast_global_tls_small != -17): return 6
	return 0
