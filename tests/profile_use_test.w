# wbuild: tool=tools/wprof.w deps=tests/profile_use_fixture.w
/*
--profile-use end to end (unit P2, docs/projects/register_allocation_pgo.md
§3.4-§3.5): for x86 and x64, compile tests/profile_use_fixture.w plain,
take its profile (--profile-generate, one run with W_PROFILE_OUT, bin/wprof
merge), and compile it again with --profile-use --stats. Asserts:

  - the program's output is unchanged;
  - with the profile cut down to the fixture's own entries (the runtime
    closure's malloc_debug_env_check loops are hot too, and would be
    aligned as well), the stats summary classifies hot_sum hot and
    exactly one loop head was aligned: hot_sum's, and the image has the
    nop pad right before a 16-byte-aligned head (the bytes are read back
    from the file);
  - the profile drives the register pre-scan (phase B): hot_sum is the
    one hot body scanned, cold_step, never_called and main are skipped
    as cold (--stats "regalloc: profile:" line);
  - a stale entry (hot_sum's hash edited in the profile) is "stale", not
    matched: nothing is aligned and, with promotion off on both sides
    (--no-regs, so alignment is the profile's only effect), the image is
    byte-identical to the plain build;
  - a header-only profile classifies nothing (no file is covered) and
    the image is byte-identical to the plain build;
  - a missing profile is an error.
*/
import lib.lib
import lib.testing
import lib.assert
import lib.file
import lib.str
import lib.env
import lib.process
import structures.string


char* pu_fixture():
	return c"tests/profile_use_fixture.w"


# Spawn path with argv (NULL-terminated) and an optional env; stdout and
# stderr are captured (malloc'd), the exit status stored in status[0].
# The compiler's --stats output is small, so reading the two pipes one
# after the other cannot fill either.
char* pu_run(char* path, char** argv, char** env, int* status, char** stderr_out):
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null
	opts.stdout_mode = process_pipe
	opts.stderr_mode = process_pipe
	opts.env = env
	process* child = process_spawn(path, argv, opts)
	free(opts)
	asserts(c"spawn failed", child != 0)
	string_builder* err = string_new()
	string_builder* text = string_new()
	char* chunk = cast(char*, malloc(4096))
	int n = read(child.stderr_fd, chunk, 4096)
	while (n > 0):
		string_append_bytes(err, chunk, n)
		n = read(child.stderr_fd, chunk, 4096)
	close(child.stderr_fd)
	n = read(child.stdout_fd, chunk, 4096)
	while (n > 0):
		string_append_bytes(text, chunk, n)
		n = read(child.stdout_fd, chunk, 4096)
	free(chunk)
	close(child.stdout_fd)
	status[0] = process_wait(child)
	process_free(child)
	char* result = strclone(text.data)
	if (stderr_out != 0): stderr_out[0] = strclone(err.data)
	string_free(text)
	string_free(err)
	return result


# bin/wv2 [x64] --quiet [flag...] fixture -o out; returns the compiler's
# stderr (malloc'd) and asserts exit status `expected`.
char* pu_compile(char* arch, char* flag1, char* flag2, char* flag3, char* out, int expected):
	char** argv = strv_new(11)
	int n = 0
	strv_set(argv, n, c"bin/wv2")
	n = n + 1
	if (strcmp(arch, c"x64") == 0):
		strv_set(argv, n, c"x64")
		n = n + 1
	strv_set(argv, n, c"--quiet")
	n = n + 1
	if (flag1 != 0):
		strv_set(argv, n, flag1)
		n = n + 1
	if (flag2 != 0):
		strv_set(argv, n, flag2)
		n = n + 1
	if (flag3 != 0):
		strv_set(argv, n, flag3)
		n = n + 1
	strv_set(argv, n, pu_fixture())
	n = n + 1
	strv_set(argv, n, c"-o")
	n = n + 1
	strv_set(argv, n, out)
	int status = 0
	char* err = 0
	char* text = pu_run(c"bin/wv2", argv, 0, &status, &err)
	free(text)
	free(cast(void*, argv))
	if (status != expected): println2(err)
	assert_equal(expected, status)
	return err


# Run the fixture binary once, optionally with W_PROFILE_OUT=raw; its
# stdout (malloc'd).
char* pu_run_fixture(char* binary, char* raw):
	char** argv = strv_new(2)
	strv_set(argv, 0, binary)
	char** env = 0
	if (raw != 0): env = env_copy_with(env_current(), c"W_PROFILE_OUT", raw)
	int status = 0
	char* text = pu_run(binary, argv, env, &status, 0)
	assert_equal(0, status)
	free(cast(void*, argv))
	return text


void pu_merge(char* out, char* map, char* raw):
	char** argv = strv_new(7)
	strv_set(argv, 0, c"bin/wprof")
	strv_set(argv, 1, c"merge")
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, out)
	strv_set(argv, 4, map)
	strv_set(argv, 5, raw)
	int status = 0
	char* text = pu_run(c"bin/wprof", argv, 0, &status, 0)
	free(text)
	assert_equal(0, status)
	free(cast(void*, argv))


# The whole file as bytes (malloc'd), length in size[0].
char* pu_read_bytes(char* path, int* size):
	int fd = open(path, 0, 0)
	asserts(c"cannot open binary", fd >= 0)
	int capacity = 1 << 20
	char* bytes = cast(char*, malloc(capacity))
	int length = 0
	int n = read(fd, bytes, capacity)
	while (n > 0):
		length = length + n
		if (length + 65536 > capacity):
			bytes = realloc(bytes, capacity, capacity * 2)
			capacity = capacity * 2
		n = read(fd, bytes + length, capacity - length)
	close(fd)
	size[0] = length
	return bytes


int pu_same_file(char* a, char* b):
	int size_a = 0
	int size_b = 0
	char* bytes_a = pu_read_bytes(a, &size_a)
	char* bytes_b = pu_read_bytes(b, &size_b)
	int same = size_a == size_b
	int i = 0
	while (same && (i < size_a)):
		if (bytes_a[i] != bytes_b[i]): same = 0
		i = i + 1
	free(bytes_a)
	free(bytes_b)
	return same


# The integer after `field` in the "Profile use:" summary line of err.
int pu_stat(char* err, char* field):
	int at = index_of(err, c"Profile use: ")
	asserts(c"no Profile use summary in --stats output", at >= 0)
	char* line = err + at
	int f = index_of(line, field)
	asserts(c"summary field missing", f >= 0)
	return atoi(line + f + strlen(field))


# The integer after `field` anywhere in err (the regalloc stats lines
# precede the Profile use summary).
int pu_stat_any(char* err, char* field):
	int f = index_of(err, field)
	asserts(c"stats field missing", f >= 0)
	return atoi(err + f + strlen(field))


int pu_count(char* text, char* needle):
	int count = 0
	int at = index_of(text, needle)
	while (at >= 0):
		count = count + 1
		text = text + at + strlen(needle)
		at = index_of(text, needle)
	return count


# Write the fixture's own entries of the merged profile (the header and
# every line naming its file) to out. With make_stale, hot_sum's lines
# get the first hex digit of their hash changed, so the entry no longer
# matches the function.
void pu_write_filtered(char* profile, char* out, int make_stale):
	list[char*] lines = file_read_lines(profile)
	asserts(c"cannot read merged profile", lines != 0)
	string_builder* s = string_new()
	int kept = 0
	int edited = 0
	for char* line in lines:
		if (line[0] == '#'):
			string_append(s, line)
			string_append(s, c"\n")
			continue
		if (index_of(line, c" tests/profile_use_fixture.w ") < 0): continue
		kept = kept + 1
		if (make_stale && (index_of(line, c" hot_sum tests/profile_use_fixture.w ") >= 0)):
			char* copy = strclone(line)
			if (copy[2] == '0'): copy[2] = '1'
			else: copy[2] = '0'
			string_append(s, copy)
			free(copy)
			edited = edited + 1
		else: string_append(s, line)
		string_append(s, c"\n")
	# hot_sum f+l, cold_step f+l, main f+l
	assert_equal(6, kept)
	if (make_stale): assert_equal(2, edited)
	asserts(c"cannot write profile", file_write_text(out, s.data))
	string_free(s)


void pu_check_arch(char* arch):
	char* stem = strjoin(c"bin/profile_use_fixture_", arch)
	char* plain = strjoin(stem, c"_plain")
	char* plain_noregs = strjoin(stem, c"_plain_noregs")
	char* instrumented = strjoin(stem, c"_gen")
	char* map = strjoin(instrumented, c".wprofmap")
	char* raw = strjoin(instrumented, c".wprofraw")
	char* merged = strjoin(stem, c"_merged.wprof")
	char* profile = strjoin(stem, c".wprof")
	char* stale = strjoin(stem, c"_stale.wprof")
	char* empty = strjoin(stem, c"_empty.wprof")
	char* pgo = strjoin(stem, c"_pgo")
	char* pgo_stale = strjoin(stem, c"_pgo_stale")
	char* pgo_empty = strjoin(stem, c"_pgo_empty")

	free(pu_compile(arch, 0, 0, 0, plain, 0))
	free(pu_compile(arch, c"--no-regs", 0, 0, plain_noregs, 0))
	char* expected = pu_run_fixture(plain, 0)
	assert_strings_equal(c"1998005\n", expected)

	# Take the profile.
	free(pu_compile(arch, c"--profile-generate", 0, 0, instrumented, 0))
	unlink(raw)
	free(pu_run_fixture(instrumented, raw))
	pu_merge(merged, map, raw)
	pu_write_filtered(merged, profile, 0)

	# Use it: same output, hot_sum hot, its loop aligned.
	char* use_flag = strjoin(c"--profile-use=", profile)
	char* err = pu_compile(arch, use_flag, c"--stats", 0, pgo, 0)
	char* produced = pu_run_fixture(pgo, 0)
	assert_strings_equal(expected, produced)
	asserts(c"hot_sum is hot", pu_stat(err, c"hot ") >= 1)
	asserts(c"cold_step, never_called and main are cold", pu_stat(err, c"cold ") >= 3)
	assert_equal(0, pu_stat(err, c"stale "))
	# The scan: the fixture's profile covers only its own file, so the
	# runtime's bodies are unknown (static heuristic) and exactly the
	# fixture's bodies are decided by the profile.
	assert_equal(3, pu_stat_any(err, c"cold bodies skipped: "))
	assert_equal(1, pu_stat_any(err, c"hot bodies scanned: "))
	assert_equal(1, pu_stat(err, c"loops aligned "))
	assert_equal(1, pu_count(err, c"Profile use: aligned loop head at file offset "))
	asserts(c"the aligned loop is hot_sum's", index_of(err, c": hot_sum loop 1\n") >= 0)
	int at = index_of(err, c"aligned loop head at file offset ")
	int head = atoi(err + at + strlen(c"aligned loop head at file offset "))
	int pad_at = index_of(err + at, c" pad ")
	int pad = atoi(err + at + pad_at + 5)
	assert_equal(0, head & 15)
	int size = 0
	char* bytes = pu_read_bytes(pgo, &size)
	asserts(c"head inside the image", head < size)
	int i = head - pad
	while (i < head):
		assert_equal(0x90, bytes[i] & 255)
		i = i + 1
	if (pad > 0): asserts(c"the head itself is not a nop", (bytes[head] & 255) != 0x90)
	free(bytes)
	int plain_size = 0
	free(pu_read_bytes(plain, &plain_size))
	# Padding is inside the page the code occupies before the data
	# segment, so the sizes agree unless the pad crossed a page.
	if (pad == 0): asserts(c"no pad: image identical", pu_same_file(plain, pgo))
	else: asserts(c"pad: image differs", pu_same_file(plain, pgo) == 0)
	free(err)
	free(produced)

	# A stale entry is ignored: unknown class, nothing aligned, same bytes
	# (promotion off on both sides: the matched cold bodies would
	# otherwise skip the scan the plain build runs).
	pu_write_filtered(merged, stale, 1)
	char* stale_flag = strjoin(c"--profile-use=", stale)
	err = pu_compile(arch, stale_flag, c"--stats", c"--no-regs", pgo_stale, 0)
	asserts(c"hot_sum is stale", pu_stat(err, c"stale ") >= 1)
	assert_equal(0, pu_stat(err, c"loops aligned "))
	asserts(c"stale profile: image identical", pu_same_file(plain_noregs, pgo_stale))
	produced = pu_run_fixture(pgo_stale, 0)
	assert_strings_equal(expected, produced)
	free(produced)
	free(err)

	# A header-only profile covers no file: everything unknown, same bytes.
	asserts(c"cannot write empty profile", file_write_text(empty, c"# wprof v1 from: nothing\n"))
	char* empty_flag = strjoin(c"--profile-use=", empty)
	err = pu_compile(arch, empty_flag, c"--stats", 0, pgo_empty, 0)
	assert_equal(0, pu_stat(err, c"hot "))
	assert_equal(0, pu_stat(err, c"cold "))
	assert_equal(0, pu_stat(err, c"stale "))
	assert_equal(0, pu_stat(err, c"loops aligned "))
	asserts(c"empty profile: image identical", pu_same_file(plain, pgo_empty))
	free(err)

	# A missing profile is an error, not a silent plain build.
	err = pu_compile(arch, c"--profile-use=bin/profile_use_missing.wprof", 0, 0, pgo_empty, 1)
	asserts(c"missing profile reported", index_of(err, c"--profile-use: cannot read profile") >= 0)
	free(err)
	free(expected)


void test_profile_use_x86():
	pu_check_arch(c"x86")


void test_profile_use_x64():
	pu_check_arch(c"x64")
