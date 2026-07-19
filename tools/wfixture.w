/*
wfixture: the compile-diagnostic fixture runner.

Compile-only fixtures (tests/*fixture*.w and friends) provoke compiler
warnings or errors whose exact message text is part of the contract.
The expected diagnostics used to live far from the code, as
expect_stderr/reject_stderr/expect_fail fields on build.json steps;
wfixture single-sources them, LLVM-lit style: each fixture carries its
own expectations as directive lines in its header comment, and a
build.json step shrinks to

	{"cmd": ["bin/wfixture", "bin/wv2", "tests/a_fixture.w", ...]}

Directive syntax — comment lines at the top of the fixture, before the
first non-comment line (later comments are not scanned):

	# expect_stderr: <substring>   stderr must contain <substring>
	                               (repeatable, checked in order)
	# reject_stderr: <substring>   stderr must NOT contain <substring>
	                               (repeatable)
	# expect_fail                  the compile must exit nonzero
	                               (without it the compile must exit 0)

The needle is everything after ": " to the end of the line, verbatim,
and matching is a plain byte-wise substring search — exactly the
semantics of wexec's expect_stderr/reject_stderr step fields that these
directives replace. A header comment line that starts with "# expect_"
or "# reject_" but is not one of the forms above is an error (it is
probably a typo'd directive), and a fixture with no directives at all
is an error too (it would assert nothing).

Sidecar fallback: a fixture whose byte content cannot safely carry
header lines (for example, one whose assertions depend on its exact
leading bytes) may put the same directive lines in a "<fixture>.expect"
file next to it (tests/foo_fixture.w -> tests/foo_fixture.w.expect).
When the sidecar exists it is used instead of the fixture header, and
every non-blank sidecar line must be a comment or directive. Prefer
in-file directives; use the sidecar only when the header lines would
change what the fixture tests.

For each fixture wfixture runs

	<compiler> <fixture> -o bin/<basename>

as a child process via lib.process (basename = the fixture's filename
without its ".w" suffix), checks the exit status and every directive
against the captured stderr, and prints one PASS/FAIL line per fixture
with expected-vs-actual detail on failure. The exit status is nonzero
when any fixture fails.

Usage: wfixture <compiler> <fixture.w>...
*/
import lib.lib
import lib.env
import lib.file
import lib.process
import lib.stream
import structures.string


list[char*] wfixture_expects   # expect_stderr needles, in directive order
list[char*] wfixture_rejects   # reject_stderr needles, in directive order
int wfixture_expect_fail       # 1 when the compile must exit nonzero
int wfixture_directives        # total directives parsed for this fixture


void wfixture_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wfixture <compiler> <fixture.w>...")
	stream_flush(err)


# One diagnostic line about a fixture: "wfixture: <fixture>: <message>".
void wfixture_note(char* fixture, char* message):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wfixture: ")
	stream_write_cstr(err, fixture)
	stream_write_cstr(err, c": ")
	stream_write_line(err, message)
	stream_flush(err)


void wfixture_note2(char* fixture, char* message, char* detail):
	string_builder* s = string_new()
	string_append(s, message)
	string_append(s, detail)
	wfixture_note(fixture, s.data)
	string_free(s)


# Same substring semantics as wexec_str_contains in tools/wexec.w: a
# plain byte-wise search, and an empty needle always matches.
int wfixture_str_contains(char* haystack, char* needle):
	int n = strlen(needle)
	if (n == 0):
		return 1
	int i = 0
	while (haystack[i] != 0):
		int j = 0
		while ((j < n) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == n):
			return 1
		i = i + 1
	return 0


# Parse one header line. Returns 0 on success, 1 on a malformed
# directive (a comment that looks like a directive but is not one).
int wfixture_parse_line(char* fixture, char* line):
	if (starts_with(line, c"# expect_stderr: ")):
		wfixture_expects.push(strclone(line + strlen(c"# expect_stderr: ")))
		wfixture_directives = wfixture_directives + 1
		return 0
	if (starts_with(line, c"# reject_stderr: ")):
		wfixture_rejects.push(strclone(line + strlen(c"# reject_stderr: ")))
		wfixture_directives = wfixture_directives + 1
		return 0
	if (strcmp(line, c"# expect_fail") == 0):
		wfixture_expect_fail = 1
		wfixture_directives = wfixture_directives + 1
		return 0
	if (starts_with(line, c"# expect_") || starts_with(line, c"# reject_")):
		wfixture_note2(fixture, c"malformed directive line: ", line)
		return 1
	return 0


# Collect directives from text. In header mode (the fixture itself) the
# scan stops at the first line that is neither blank nor a '#' comment;
# in sidecar mode every non-blank line must be a comment or directive.
# Returns 0 on success, 1 on a malformed line.
int wfixture_parse_text(char* fixture, char* text, int sidecar):
	int failed = 0
	int i = 0
	while ((text[i] != 0) && (failed == 0)):
		int start = i
		while ((text[i] != 0) && (text[i] != 10)):
			i = i + 1
		int length = i - start
		if (text[i] == 10):
			i = i + 1
		char* line = malloc(length + 1)
		strncpy(line, text + start, length)
		line[length] = 0
		if (length == 0):
			free(line)
		else if (line[0] == '#'):
			failed = wfixture_parse_line(fixture, line)
			free(line)
		else if (sidecar):
			wfixture_note2(fixture, c"sidecar line is not a directive or comment: ", line)
			free(line)
			failed = 1
		else:
			# First code line: the fixture header is over.
			free(line)
			return 0
	return failed


# Read the fixture's directives, preferring the "<fixture>.expect"
# sidecar when it exists. Returns 0 on success, 1 on any error.
int wfixture_load_directives(char* fixture):
	wfixture_expects = new list[char*]
	wfixture_rejects = new list[char*]
	wfixture_expect_fail = 0
	wfixture_directives = 0

	string_builder* sidecar_path = string_new()
	string_append(sidecar_path, fixture)
	string_append(sidecar_path, c".expect")
	int sidecar = 0
	char* text = file_read_text(sidecar_path.data)
	string_free(sidecar_path)
	if (text != 0):
		sidecar = 1
	else:
		text = file_read_text(fixture)
	if (text == 0):
		wfixture_note(fixture, c"cannot read fixture")
		return 1
	int failed = wfixture_parse_text(fixture, text, sidecar)
	free(text)
	if (failed):
		return 1
	if (wfixture_directives == 0):
		wfixture_note(fixture, c"no directives found (want '# expect_stderr: ...', '# reject_stderr: ...' or '# expect_fail')")
		return 1
	return 0


# tests/foo_fixture.w -> bin/foo_fixture (the same scratch path the
# build.json compile steps used).
char* wfixture_output_path(char* fixture):
	char* base = fixture
	int i = 0
	while (fixture[i] != 0):
		if (fixture[i] == '/'):
			base = fixture + i + 1
		i = i + 1
	string_builder* s = string_new()
	string_append(s, c"bin/")
	string_append(s, base)
	if ((s.length > 2) && ends_with(s.data, c".w")):
		s.length = s.length - 2
		s.data[s.length] = 0
	char* path = s.data
	free(s)
	return path


# execve does no PATH lookup, so a compiler name without a slash must
# be resolved here (same as wexec_resolve_program in tools/wexec.w).
char* wfixture_resolve_program(char* name):
	int i = 0
	while (name[i] != 0):
		if (name[i] == '/'):
			return name
		i = i + 1
	char* path = env_get(c"PATH")
	if (path == 0):
		path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	while (at_end == 0):
		string_clear(candidate)
		while ((path[p] != ':') && (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0):
			at_end = 1
		else:
			p = p + 1
		if (candidate.length > 0):
			string_append_char(candidate, '/')
			string_append(candidate, name)
			int fd = open(candidate.data, 0, 0)
			if (fd >= 0):
				close(fd)
				return candidate.data
	string_free(candidate)
	return name


void wfixture_echo_command(char* compiler, char* fixture, char* out_path):
	string_builder* line = string_new()
	string_append(line, c"$ ")
	string_append(line, compiler)
	string_append(line, c" ")
	string_append(line, fixture)
	string_append(line, c" -o ")
	string_append(line, out_path)
	wstream* out = stdout_writer()
	stream_write_line(out, line.data)
	stream_flush(out)
	string_free(line)


# Check exit status and every directive against the captured stderr.
# Returns the number of failed checks, reporting each one.
int wfixture_check(char* fixture, process_result* result):
	int failures = 0
	if (result.status < 0):
		wfixture_note(fixture, c"command timed out or could not be waited on")
		return 1
	if (wfixture_expect_fail):
		if (result.status == 0):
			wfixture_note(fixture, c"command was expected to fail but exited 0")
			failures = failures + 1
	else:
		if (result.status != 0):
			string_builder* s = string_new()
			string_append(s, c"command failed with exit status ")
			string_append_int(s, result.status)
			wfixture_note(fixture, s.data)
			string_free(s)
			failures = failures + 1
	for char* needle in wfixture_expects:
		if (wfixture_str_contains(result.stderr_text, needle) == 0):
			wfixture_note2(fixture, c"expected stderr to contain: ", needle)
			failures = failures + 1
	for char* needle in wfixture_rejects:
		if (wfixture_str_contains(result.stderr_text, needle)):
			wfixture_note2(fixture, c"expected stderr to not contain: ", needle)
			failures = failures + 1
	return failures


void wfixture_free_directives():
	for char* needle in wfixture_expects:
		free(needle)
	for char* needle in wfixture_rejects:
		free(needle)


void wfixture_verdict(char* verdict, char* fixture):
	wstream* out = stdout_writer()
	stream_write_cstr(out, c"wfixture: ")
	stream_write_cstr(out, verdict)
	stream_write_cstr(out, c" ")
	stream_write_line(out, fixture)
	stream_flush(out)


# Run one fixture end to end. Returns 0 on pass, 1 on fail.
int wfixture_run(char* compiler, char* fixture):
	if (wfixture_load_directives(fixture)):
		wfixture_verdict(c"FAIL", fixture)
		return 1

	char* out_path = wfixture_output_path(fixture)
	wfixture_echo_command(compiler, fixture, out_path)
	char** argv = strv_new(4)
	strv_set(argv, 0, compiler)
	strv_set(argv, 1, fixture)
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, out_path)
	char* program = wfixture_resolve_program(compiler)
	process_result* result = process_run(program, argv, 0, 0, 0)
	free(cast(char*, argv))
	free(out_path)
	if (result == 0):
		wfixture_note(fixture, c"failed to spawn compiler")
		wfixture_free_directives()
		wfixture_verdict(c"FAIL", fixture)
		return 1

	int failures = wfixture_check(fixture, result)
	if (failures > 0):
		# Expected-vs-actual: the misses are reported above, here is
		# what the compiler actually said.
		wfixture_note(fixture, c"actual stderr follows")
		wstream* err = stderr_writer()
		if (result.stderr_length > 0):
			stream_write_cstr(err, result.stderr_text)
		stream_write_line(err, c"wfixture: end of actual stderr")
		stream_flush(err)
	process_result_free(result)
	wfixture_free_directives()
	if (failures > 0):
		wfixture_verdict(c"FAIL", fixture)
		return 1
	wfixture_verdict(c"PASS", fixture)
	return 0


int main(int argc, int argv):
	if (argc < 3):
		wfixture_usage()
		return 1
	char** compiler_arg = argv + __word_size__
	char* compiler = *compiler_arg
	int total = 0
	int failed = 0
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		failed = failed + wfixture_run(compiler, *arg)
		total = total + 1
		i = i + 1
	string_builder* s = string_new()
	if (failed > 0):
		string_append(s, c"wfixture: FAILED (")
		string_append_int(s, failed)
		string_append(s, c" of ")
		string_append_int(s, total)
		string_append(s, c" fixtures)")
		wstream* err = stderr_writer()
		stream_write_line(err, s.data)
		stream_flush(err)
		string_free(s)
		return 1
	string_append(s, c"wfixture: OK (")
	string_append_int(s, total)
	string_append(s, c" fixtures)")
	wstream* out = stdout_writer()
	stream_write_line(out, s.data)
	stream_flush(out)
	string_free(s)
	return 0
