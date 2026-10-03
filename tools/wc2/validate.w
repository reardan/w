# Target-independent literal helpers shared with semantic analysis.
import tools.wc2.expressions


void wc2_node_error(wc2_module* m, wc2_node* node, char* message):
	pg_diagnostics_add(m.diagnostics, node.filename, node.line, node.column, message, c"", node.text)


# Accumulate two 16-bit limbs so overflow checking and sign extension are
# identical in 32-bit and 64-bit hosts. W accepts 32 significant literal bits.
int wc2_integer32(char* text, int* value):
	if (strcmp(text, c"true") == 0):
		*value = 1
		return 1
	if (strcmp(text, c"false") == 0):
		*value = 0
		return 1
	if (wc2_integer_spelling(text) == 0): return 0
	int base = 10
	int i = 0
	if ((text[0] == '0') && (text[1] == 'x')):
		base = 16
		i = 2
	if ((text[0] == '0') && (text[1] == 'b')):
		base = 2
		i = 2
	int low = 0
	int high = 0
	while (text[i]):
		int digit = text[i] - '0'
		if ((text[i] >= 'a') && (text[i] <= 'f')): digit = text[i] - 'a' + 10
		if ((text[i] >= 'A') && (text[i] <= 'F')): digit = text[i] - 'A' + 10
		low = low * base + digit
		high = high * base + (low >> 16)
		if (high > 65535): return 0
		low = low & 65535
		i = i + 1
	if (high >= 32768): high = high - 65536
	*value = (high << 16) | low
	return 1
