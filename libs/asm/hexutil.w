/*
Hex encode/decode, byte-diff assertions and the corpus fixture loader
for the assembler/disassembler libraries
(docs/projects/assembler_disassembler.md, issue #164).

Corpus fixture format (tests/asm/corpus_*.txt): one entry per line,
`hexbytes|assembly-text`; `#` starts a comment line; blank lines are
ignored. Multi-instruction sequences join their text parts with ' ; '.

Compiled by the seed-compat gate (asm_seed_gate): only seed-understood
syntax here.
*/
import lib.lib
import lib.file


int asm_hex_digit(int c):
	if (c >= '0' && c <= '9'):
		return c - '0'
	if (c >= 'a' && c <= 'f'):
		return c - 'a' + 10
	if (c >= 'A' && c <= 'F'):
		return c - 'A' + 10
	return -1


# Decode a NUL- or delimiter-terminated run of hex pairs into out
# (which must hold max bytes). Returns the byte count, or -1 on an odd
# digit count / non-hex character / overflow.
int asm_hex_decode(char* hex, char* out, int max):
	int count = 0
	int i = 0
	while (asm_hex_digit(hex[i]) >= 0):
		int hi = asm_hex_digit(hex[i])
		int lo = asm_hex_digit(hex[i + 1])
		if (lo < 0):
			return -1
		if (count >= max):
			return -1
		out[count] = (hi << 4) | lo
		count = count + 1
		i = i + 2
	return count


# Malloc'd lowercase hex string for n bytes.
char* asm_hex_encode(char* bytes, int n):
	char* digits = c"0123456789abcdef"
	char* text = malloc(n * 2 + 1)
	int i = 0
	while (i < n):
		int v = bytes[i] & 255
		text[i * 2] = digits[v >> 4]
		text[i * 2 + 1] = digits[v & 15]
		i = i + 1
	text[n * 2] = 0
	return text


# Assert two byte ranges are identical; on mismatch print both as hex
# with a caret under the first differing byte pair and exit(1).
void asm_assert_bytes_equal(char* context, char* want, int want_length, char* got, int got_length):
	int equal = want_length == got_length
	int diff = -1
	int i = 0
	while (i < want_length && i < got_length):
		if ((want[i] & 255) != (got[i] & 255)):
			if (diff < 0):
				diff = i
			equal = 0
		i = i + 1
	if (equal):
		return
	if (diff < 0):
		diff = i
	print2(c"byte mismatch: ")
	println2(context)
	print2(c"  want [")
	print2(itoa(want_length))
	print2(c"] ")
	println2(asm_hex_encode(want, want_length))
	print2(c"  got  [")
	print2(itoa(got_length))
	print2(c"] ")
	println2(asm_hex_encode(got, got_length))
	print2(c"  first difference at byte ")
	println2(itoa(diff))
	exit(1)


############################### corpus loader #################################

struct asm_corpus_entry:
	char* bytes    # decoded bytes (malloc'd)
	int length
	char* text     # assembly text (malloc'd; ' ; '-joined for sequences)
	int line       # 1-based fixture line for diagnostics


# Load a corpus fixture. Returns the entries, or an empty list when the
# file is missing; malformed lines print a diagnostic and exit(1) so a
# broken fixture cannot silently shrink coverage.
list[asm_corpus_entry] asm_corpus_load(char* path):
	list[asm_corpus_entry] entries = new list[asm_corpus_entry]
	list[char*] lines = file_read_lines(path)
	if (cast(int, lines) == 0):
		return entries
	int index = 0
	while (index < lines.length):
		char* line = lines[index]
		index = index + 1
		if (line[0] == 0):
			continue
		if (line[0] == '#'):
			continue
		int bar = 0
		while (line[bar] != 0 && line[bar] != '|'):
			bar = bar + 1
		int ok = 1
		if (line[bar] != '|'):
			ok = 0
		char* bytes = 0
		int length = -1
		if (ok):
			bytes = malloc(bar / 2 + 1)
			length = asm_hex_decode(line, bytes, bar / 2 + 1)
			if (length <= 0):
				ok = 0
			if (length * 2 != bar):
				ok = 0
		if (ok == 0):
			print2(c"bad corpus line ")
			print2(itoa(index))
			print2(c" in ")
			print2(path)
			print2(c": ")
			println2(line)
			exit(1)
		asm_corpus_entry entry
		entry.bytes = bytes
		entry.length = length
		entry.text = strclone(line + bar + 1)
		entry.line = index
		entries.push(entry)
	return entries
