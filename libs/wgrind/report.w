# Allocation-free, deterministic JSON diagnostics. Site/origin values
# are tokens resolved to source locations by the execution frontend.
import libs.wgrind.shadow


char* wg_error_name(int kind):
	if (kind == WG_INVALID_READ): return c"invalid-read"
	if (kind == WG_INVALID_WRITE): return c"invalid-write"
	if (kind == WG_UNDEFINED): return c"undefined-value"
	if (kind == WG_INVALID_FREE): return c"invalid-free"
	if (kind == WG_DOUBLE_FREE): return c"double-free"
	if (kind == WG_BAD_REALLOC): return c"invalid-realloc"
	return c"incomplete"


int wg_text(char* dst, int at, char* text):
	int i = 0
	while (text[i]):
		dst[at] = text[i]
		at = at + 1
		i = i + 1
	return at


int wg_hex(char* dst, int at, int value):
	at = wg_text(dst, at, c"\"0x")
	char* digits = c"0123456789abcdef"
	for i in range(__word_size__ * 2):
		int shift = (__word_size__ * 2 - 1 - i) * 4
		dst[at] = digits[(value >> shift) & 15]
		at = at + 1
	dst[at] = '"'
	return at + 1


int wg_decimal(char* dst, int at, int value):
	char[24] digits
	int n = 0
	if (value < 0):
		dst[at] = '-'
		at = at + 1
	else: value = 0 - value
	# Keep the magnitude negative so even MIN_INT is representable.
	while (1):
		digits[n] = '0' - value % 10
		n = n + 1
		value = value / 10
		if (value == 0): break
	for i in range(n):
		dst[at] = digits[n - i - 1]
		at = at + 1
	return at


int wg_report(wg_context* c, int fd):
	if (c.error == 0): return 1
	# Fixed keys + eight at-most-word-sized numbers fit in 512 bytes.
	char[512] buffer
	char* dst = &buffer[0]
	int n = wg_text(dst, 0, c"{\"kind\":\"")
	n = wg_text(dst, n, wg_error_name(c.error))
	n = wg_text(dst, n, c"\",\"code\":")
	n = wg_decimal(dst, n, c.error)
	n = wg_text(dst, n, c",\"address\":")
	n = wg_hex(dst, n, c.error_address)
	n = wg_text(dst, n, c",\"size\":")
	n = wg_decimal(dst, n, c.error_size)
	n = wg_text(dst, n, c",\"site\":")
	n = wg_hex(dst, n, c.error_site)
	n = wg_text(dst, n, c",\"origin\":")
	n = wg_hex(dst, n, c.error_origin)
	n = wg_text(dst, n, c",\"allocation\":")
	n = wg_hex(dst, n, c.error_allocation)
	n = wg_text(dst, n, c",\"free\":")
	n = wg_hex(dst, n, c.error_free)
	n = wg_text(dst, n, c",\"offset\":")
	n = wg_decimal(dst, n, c.error_offset)
	n = wg_text(dst, n, c"}\n")
	int pos = 0
	while (pos < n):
		int result = write(fd, dst + pos, n - pos)
		if (result == -4): continue # EINTR
		if (result <= 0): return 0
		pos = pos + result
	return 1
