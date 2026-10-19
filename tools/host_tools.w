# Shared support for native repository utilities and subprocess test drivers.
# Commands are argv vectors, never interpolated shell programs. Scratch paths
# are private and removed on both successful completion and reported failure.
import lib.args
import lib.file
import lib.bytes
import lib.process
import lib.sha256
import structures.json
import libs.standard.fs.tempfile
import libs.standard.fs.shutil

list[char*] ht_scratch
list[process*] ht_children
type ht_cleanup_fn = fn() -> void
ht_cleanup_fn* ht_on_cleanup

void ht_cleanup():
	if (ht_on_cleanup != 0):
		ht_cleanup_fn* callback = ht_on_cleanup
		ht_on_cleanup = 0
		callback()
	if (ht_children != 0):
		for process* child in ht_children:
			if (!child.reaped):
				process_kill_group(child, 9)
				process_wait(child)
	if (ht_scratch == 0): return
	for char* path in ht_scratch: shutil_rmtree(path)

void ht_require(int ok, char* message);

process* ht_spawn(list[char*] command, spawn_options* options):
	char* executable = process_which(command[0])
	ht_require(executable != 0, strjoin(c"command unavailable: ", command[0]))
	char** argv = strv_new(command.length)
	for i in range(command.length): strv_set(argv, i, command[i])
	process* child = process_spawn(executable, argv, options)
	free(cast(void*, argv))
	ht_require(child != 0, strjoin(c"cannot spawn: ", command[0]))
	if (ht_children == 0): ht_children = new list[process*]
	ht_children.push(child)
	return child

char* ht_quote(char* value):
	string_builder* out = string_from(c"'")
	for i in range(strlen(value)):
		if (value[i] == 39): string_append(out, c"'\"'\"'")
		else: string_append_char(out, value[i])
	string_append_char(out, 39)
	return out.data

void ht_require(int ok, char* message):
	if (ok): return
	println2(message)
	ht_cleanup()
	exit(1)

char* ht_temp():
	char* path = tempfile_mkdtemp_in(0, c"w-host-", c"")
	ht_require(path != 0, c"cannot create private temporary directory")
	if (ht_scratch == 0): ht_scratch = new list[char*]
	ht_scratch.push(path)
	return path

string_builder* ht_read(char* path):
	wstream* input = stream_open_read(path)
	ht_require(input != 0, strjoin(c"cannot read: ", path))
	string_builder* data = string_new()
	io_result result
	int status = stream_read_all_checked(input, data, &result)
	stream_close(input)
	ht_require(status == IO_OK, strjoin(c"read failed: ", path))
	return data

void ht_write(char* path, char* data, int length):
	io_result result
	# Generated data and source files are not executable. Script fixtures opt in
	# explicitly with chmod, just as compiler outputs do.
	int fd = open(path, 577, 420)
	ht_require(fd >= 0, strjoin(c"cannot write: ", path))
	int status = io_write_all(fd, data, length, &result)
	io_result closed
	io_close(fd, &closed)
	ht_require(status == IO_OK && closed.status == IO_OK, strjoin(c"write failed: ", path))

list[char*] ht_split(char* text, int delimiter):
	list[char*] parts = new list[char*]
	int start = 0
	int pos = 0
	while (1):
		if (text[pos] == delimiter || text[pos] == 0):
			parts.push(path_clone_range(text + start, pos - start))
			start = pos + 1
		if (text[pos] == 0): break
		pos = pos + 1
	return parts

# Only for constant command prefixes; append user-supplied arguments with push.
list[char*] ht_command(char* prefix):
	return ht_split(prefix, ' ')

process_result* ht_run(list[char*] command, spawn_options* options, char* input, int timeout):
	ht_require(command.length > 0, c"empty command")
	char* executable = process_which(command[0])
	ht_require(executable != 0, strjoin(c"command unavailable: ", command[0]))
	char** argv = strv_new(command.length)
	for i in range(command.length): strv_set(argv, i, command[i])
	process_result* result = process_run(executable, argv, options, input, timeout)
	free(cast(void*, argv))
	ht_require(result != 0, strjoin(c"cannot spawn: ", command[0]))
	return result

void ht_success(process_result* result):
	if (result.status == 0): return
	print2(result.stdout_text)
	print2(result.stderr_text)
	ht_require(0, strjoin(c"command failed, status ", itoa(result.status)))

process_result* ht_checked(list[char*] command):
	process_result* result = ht_run(command, 0, 0, 30000)
	ht_success(result)
	return result

int ht_contains(char* text, char* needle):
	int n = strlen(needle)
	int size = strlen(text)
	for i in range(size - n + 1):
		if (bytes_equal(text + i, n, needle, n)): return 1
	return 0

char* ht_digest(char* data, int length):
	char[32] digest
	sha256(data, length, &digest[0])
	string_builder* out = string_new()
	char* digits = c"0123456789abcdef"
	for i in range(32):
		string_append_char(out, digits[(digest[i] & 255) >> 4])
		string_append_char(out, digits[digest[i] & 15])
	return out.data

char* ht_literal(char* data, int length, int escape_all):
	string_builder* out = string_new()
	char* digits = c"0123456789abcdef"
	for i in range(length):
		int ch = data[i] & 255
		if (!escape_all && ch >= 32 && ch < 127 && ch != 34 && ch != 92): string_append_char(out, ch)
		else:
			string_append(out, c"\\x")
			string_append_char(out, digits[ch >> 4])
			string_append_char(out, digits[ch & 15])
	return out.data

void ht_generated(char* path, string_builder* output, int check):
	if (check):
		string_builder* old = ht_read(path)
		ht_require(bytes_equal(old.data, old.length, output.data, output.length), strjoin(c"generated file needs regeneration: ", path))
		string_free(old)
	else: ht_write(path, output.data, output.length)

# Bounds-checked binary field access, including overflow on 32-bit hosts.
int ht_uint(string_builder* data, int offset, int width):
	ht_require(offset >= 0 && width > 0 && offset <= data.length && width <= data.length - offset, c"truncated binary field")
	int value = 0
	int i = width
	while (i > 0):
		i = i - 1
		ht_require(value <= (json_int_max() - (data.data[offset + i] & 255)) / 256, c"binary field exceeds host integer range")
		value = value * 256 + (data.data[offset + i] & 255)
	return value

void ht_sort(list[char*] values):
	# Shell sort avoids quadratic archive/fixture inventories.
	int gap = values.length / 2
	while (gap > 0):
		for i in range(gap, values.length):
			char* value = values[i]
			int j = i
			while (j >= gap && bytes_compare(values[j - gap], strlen(values[j - gap]), value, strlen(value)) > 0):
				values[j] = values[j - gap]
				j = j - gap
			values[j] = value
		gap = gap / 2

json_value* ht_json(char* path):
	json_value* value = json_parse(ht_read(path).data)
	ht_require(value != 0, strjoin(c"invalid JSON: ", path))
	return value

json_value* ht_field(json_value* value, char* key):
	ht_require(value != 0 && value.type == json_type_object(), c"expected JSON object")
	json_value* field = json_object_get(value, key)
	ht_require(field != 0, strjoin(c"missing JSON field: ", key))
	return field

char* ht_text(json_value* value, char* key):
	json_value* field = ht_field(value, key)
	ht_require(field.type == json_type_string(), strjoin(c"expected JSON string: ", key))
	return field.string_value

int ht_number(json_value* value, char* key):
	json_value* field = ht_field(value, key)
	ht_require(field.type == json_type_int(), strjoin(c"expected JSON integer: ", key))
	return field.int_value

void ht_equal_file(char* path, char* expected):
	ht_require(strcmp(ht_read(path).data, expected) == 0, strjoin(c"unexpected file contents: ", path))

list[char*] ht_argv(char* a, char* b = 0, char* c = 0, char* d = 0, char* e = 0, char* f = 0, char* g = 0, char* h = 0, char* i = 0, char* j = 0):
	list[char*] command = new list[char*]
	command.push(a)
	if (b != 0): command.push(b)
	if (c != 0): command.push(c)
	if (d != 0): command.push(d)
	if (e != 0): command.push(e)
	if (f != 0): command.push(f)
	if (g != 0): command.push(g)
	if (h != 0): command.push(h)
	if (i != 0): command.push(i)
	if (j != 0): command.push(j)
	return command

void ht_mkdir(char* path):
	if (shutil_is_dir(path)): return
	char* parent = path_dirname(path)
	if (strcmp(path, parent) != 0): ht_mkdir(parent)
	ht_require(mkdir(path, 493) == 0 || shutil_is_dir(path), strjoin(c"cannot create directory: ", path))

char* ht_repeat(int ch, int count):
	string_builder* out = string_new()
	for i in range(count): string_append_char(out, ch)
	return out.data

# Resolve existing symlinks component by component; unlike lexical normalization,
# parent traversal after a symlink is interpreted against its resolved target.
char* ht_resolve(char* path):
	char* absolute = path
	if (!path_is_absolute(path)):
		char[4096] cwd
		if (getcwd(&cwd[0], 4096) < 0): return 0
		absolute = strjoin(strjoin(&cwd[0], c"/"), path)
	list[char*] parts = ht_split(absolute, '/')
	char* current = c"/"
	int links = 0
	int i = 0
	while (i < parts.length):
		char* part = parts[i]
		i = i + 1
		if (part[0] == 0 || strcmp(part, c".") == 0): continue
		if (strcmp(part, c"..") == 0):
			current = path_dirname(current)
			continue
		char* candidate = path_join(current, part)
		char[4097] target
		int length = readlink(candidate, &target[0], 4096)
		if (length < 0):
			current = candidate
			continue
		links = links + 1
		if (links > 40 || length == 4096): return 0
		target[length] = 0
		list[char*] next = ht_split(&target[0], '/')
		while (i < parts.length):
			next.push(parts[i])
			i = i + 1
		parts = next
		i = 0
		if (target[0] == '/'): current = c"/"
	return current
