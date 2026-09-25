/*
End-to-end check that the REPL survives a pathologically nested entry.

Usage: bin/repl_giant_entry_e2e <repl-binary> <fixture>

Feeds <fixture> (tests/repl_giant_entry_fixture.txt: one entry of
thousands of nested parentheses, then a print and :quit) to the REPL's
stdin and checks that the parser reports "expression nesting too deep"
on stderr instead of overflowing its stack, and that the next entry
still runs ("second entry ran" on stdout) with a zero exit status.

Run by repl_test / repl_test_x64 (tests/repl_fixture.w.wbuild). It
replaced the `sh -c "./bin/repl < tests/repl_giant_entry_fixture.txt"`
steps (issue #323: no shell): the child is spawned through lib/process.w
with an argv vector and the fixture as its piped stdin -- no /bin/sh.
Prints "repl giant entry OK" on success; exits 1 with a diagnostic
otherwise.
*/
import lib.lib
import lib.process
import lib.file
import lib.str


int FAILED = 0


void out(char* s):
	write(1, s, strlen(s))


void fail(char* what, process_result* r):
	out(c"FAIL: ")
	out(what)
	out(c"\n--- stdout ---\n")
	out(r.stdout_text)
	out(c"\n--- stderr ---\n")
	out(r.stderr_text)
	out(c"\n")
	FAILED = 1


int main(int argc, char** argv):
	if (argc != 3):
		out(c"usage: repl_giant_entry_e2e <repl-binary> <fixture>\n")
		return 2
	char* repl = argv[1]
	char* input = file_read_text(argv[2])
	if (input == 0):
		out(c"FAIL: cannot read fixture\n")
		return 1
	char** child_argv = strv_new(1)
	strv_set(child_argv, 0, repl)
	spawn_options* opts = spawn_options_new()
	process_result* r = process_run(repl, child_argv, opts, input, 120000)
	if (r == 0):
		out(c"FAIL: could not spawn the REPL\n")
		return 1
	if (r.status != 0): fail(c"REPL exited with a nonzero status", r)
	if (index_of(r.stdout_text, c"second entry ran") < 0):
		fail(c"stdout lacks 'second entry ran'", r)
	if (index_of(r.stderr_text, c"expression nesting too deep") < 0):
		fail(c"stderr lacks 'expression nesting too deep'", r)
	process_result_free(r)
	if (FAILED): return 1
	out(c"repl giant entry OK\n")
	return 0
