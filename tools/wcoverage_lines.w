# Execution coverage report for --coverage's statement counters. Kept
# separate from wcoverage's default static module-reachability report.
import lib.lib
import lib.args
import lib.file
import lib.str


struct wcov_line:
	char* path
	int line
	int hit


void wcov_lines_fail(char* detail):
	print2(c"wcoverage lines: ")
	println2(detail)
	exit(2)


# Validate unsigned decimal without overflow. Counts can span the full
# uint64 range even when this tool is built for x86; only hit/miss matters.
int wcov_decimal_nonzero(char* text):
	if (text[0] == 0): wcov_lines_fail(c"empty decimal field")
	int nonzero = 0
	for i in range(strlen(text)):
		if ((text[i] < '0') || (text[i] > '9')): wcov_lines_fail(c"invalid decimal field")
		if (text[i] != '0'): nonzero = 1
	return nonzero


int wcov_small_decimal(char* text):
	wcov_decimal_nonzero(text)
	int value = 0
	for i in range(strlen(text)):
		int digit = text[i] - '0'
		if ((value > 214748364) || ((value == 214748364) && (digit > 7))): wcov_lines_fail(c"index or line number too large")
		value = value * 10 + digit
	return value


char* wcov_line_key(char* path, int line):
	char* digits = itoa(line)
	char* padded = strclone(c"0000000000")
	int n = strlen(digits)
	for i in range(n): padded[10 - n + i] = digits[i]
	char* prefix = strjoin(path, c":")
	char* key = strjoin(prefix, padded)
	free(prefix)
	free(padded)
	free(digits)
	return key


list[wcov_line*] wcov_line_map(char* path, map[char*, wcov_line*] all):
	list[char*] lines = file_read_lines(path)
	if ((lines == 0) || (lines.length == 0)): wcov_lines_fail(c"cannot read map")
	list[char*] header = split(lines[0], '\t')
	if (header.length != 3): wcov_lines_fail(c"invalid map header")
	if (strcmp(header[0], c"# wprofmap v1") != 0): wcov_lines_fail(c"expected wprofmap v1")
	int expected = wcov_small_decimal(header[2])
	list[wcov_line*] counters = new list[wcov_line*]
	int statements = 0
	for i in range(1, lines.length):
		if (lines[i][0] == 0): continue
		list[char*] fields = split(lines[i], '\t')
		if (fields.length != 7): wcov_lines_fail(c"invalid map row")
		if (wcov_small_decimal(fields[0]) != counters.length): wcov_lines_fail(c"map indices must be consecutive")
		wcov_line* entry = 0
		if (strcmp(fields[1], c"s") == 0):
			statements = statements + 1
			int line = wcov_small_decimal(fields[5])
			if (line == 0): wcov_lines_fail(c"source line must be positive")
			char* key = wcov_line_key(fields[4], line)
			if (key in all): entry = all[key]
			else:
				entry = new wcov_line()
				entry.path = strclone(fields[4])
				entry.line = line
				entry.hit = 0
				all[key] = entry
		elif ((strcmp(fields[1], c"f") != 0) && (strcmp(fields[1], c"l") != 0)): wcov_lines_fail(c"unknown counter kind")
		counters.push(entry)
	if (counters.length != expected): wcov_lines_fail(c"map counter count mismatch")
	if (statements == 0): wcov_lines_fail(c"no statement counters; compile with --coverage")
	return counters


void wcov_line_dump(char* path, list[wcov_line*] counters):
	list[char*] lines = file_read_lines(path)
	if (lines == 0): wcov_lines_fail(c"cannot read dump")
	for char* line in lines:
		if (line[0] == 0): continue
		list[char*] fields = split(line)
		if (fields.length != 2): wcov_lines_fail(c"invalid dump row")
		int index = wcov_small_decimal(fields[0])
		if (index >= counters.length): wcov_lines_fail(c"dump index outside map")
		int hit = wcov_decimal_nonzero(fields[1])
		wcov_line* entry = counters[index]
		if ((entry != 0) && hit): entry.hit = 1


int wcov_lines_main():
	map[char*, wcov_line*] all = new map[char*, wcov_line*]
	list[wcov_line*] counters = 0
	set[char*] files = new set[char*]
	int dumps = 0
	for i in range(2, args_count()):
		char* arg = args_get(i)
		if (strcmp(arg, c"--file") == 0):
			i = i + 1
			if (i >= args_count()): wcov_lines_fail(c"--file requires a source path")
			files.add(args_get(i))
		elif (ends_with(arg, c".wprofmap")):
			if ((counters != 0) && (dumps == 0)): wcov_lines_fail(c"each map requires a dump")
			counters = wcov_line_map(arg, all)
			dumps = 0
		else:
			if (counters == 0): wcov_lines_fail(c"usage: wcoverage lines [--file path] <binary.wprofmap> <dump> [<map> <dump> ...]")
			wcov_line_dump(arg, counters)
			dumps = dumps + 1
	if ((counters == 0) || (dumps == 0)): wcov_lines_fail(c"each map requires a dump")
	list[char*] keys = new list[char*]
	for char* key in all: keys.push(key)
	keys.sort()
	int total = 0
	int hits = 0
	for char* key in keys:
		wcov_line* entry = all[key]
		if ((files.length > 0) && ((entry.path in files) == 0)): continue
		total = total + 1
		hits = hits + entry.hit
		print(entry.path)
		print(c":")
		print(itoa(entry.line))
		if (entry.hit): println(c": hit")
		else: println(c": miss")
	if (total == 0): wcov_lines_fail(c"no executable lines matched")
	print(c"line coverage: ")
	print(itoa(hits))
	print(c"/")
	print(itoa(total))
	print(c" (")
	print(itoa(hits * 100 / total))
	println(c"%)")
	return 0
