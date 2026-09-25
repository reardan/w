/*
End-to-end test for W-generated crash dumps (lib/crash_dump.w) and
their processing by tools/wcore.w.

Runs the crash fixtures with W_CRASH_DUMP set, so the in-process
fatal-signal handler writes its own ET_CORE dump. Unlike wcore_test
(kernel cores), this needs no core_pattern/RLIMIT_CORE cooperation,
so it never skips. For a 32-bit and a 64-bit fixture it checks:
  * the stderr report carries registers, the build-id and the dump path,
    and the process still dies of the original signal;
  * "%p" in W_CRASH_DUMP expands to the pid;
  * wcore finds the binary through the dump's "W" exe-path note (no
    binary argument), verifies the build-id, and symbolizes the trace;
  * a different same-architecture W binary is refused by build-id;
  * an unwritable dump path is reported and the crash still happens.
Prerequisites, built by the crash_dump_test target before this runs:
bin/wcore, bin/crash_dump_fixture{32,64}, bin/crash_dump_div{32,64}.

Run by the crash_dump_test target (tests/crash_null_deref_fixture.w.wbuild).
It replaced tools/crash_dump_test.sh (issue #323: no shell scripts):
every child is spawned through lib/process.w with an argv vector and an
environment vector carrying W_CRASH_DUMP -- no /bin/sh. Each case's
scratch directory is pid-scoped under bin/.
*/
import lib.lib
import lib.env
import lib.process
import lib.path
import lib.str
import lib.shell_commands
import lib.dir
import structures.string


char* WCORE
char* ROOT
int FAILED = 0


void out(char* s):
	write(1, s, strlen(s))


char* cat3(char* a, char* b, char* c):
	return strjoin(strjoin(a, b), c)


# Echo text with every line prefixed by "    | " (the script's
# `echo "$2" | sed 's/^/    | /'`).
void out_indented(char* text):
	int start = 0
	int i = 0
	while (1):
		if ((text[i] == 10) || (text[i] == 0)):
			out(c"    | ")
			write(1, text + start, i - start)
			out(c"\n")
			if ((text[i] == 0) || (text[i + 1] == 0)):
				return
			start = i + 1
		i = i + 1


void fail_line(char* desc, char* what):
	out(c"FAIL: ")
	out(desc)
	out(c": ")
	out(what)
	out(c"\n")
	FAILED = 1


# expect <case> <output> <substring>
void expect(char* desc, char* text, char* needle):
	if (index_of(text, needle) < 0):
		fail_line(desc, cat3(c"output does not contain '", needle, c"'"))
		out_indented(text)


struct run_out:
	int status
	char* text


# Runs path argv... (argv[0] = path) with W_CRASH_DUMP=dump (0 = leave the
# environment alone). want selects the captured text: 1 = stdout+stderr
# (2>&1), 2 = stderr only (2>&1 >/dev/null).
run_out* run(char* path, char* a1, char* a2, char* a3, char* dump, int want):
	char** argv = strv_new(4)
	strv_set(argv, 0, path)
	int n = 1
	if (a1 != 0):
		strv_set(argv, n, a1)
		n = n + 1
	if (a2 != 0):
		strv_set(argv, n, a2)
		n = n + 1
	if (a3 != 0):
		strv_set(argv, n, a3)
	spawn_options* opts = spawn_options_new()
	if (dump != 0):
		opts.env = env_copy_with(env_current(), c"W_CRASH_DUMP", dump)
	process_result* r = process_run(path, argv, opts, 0, 120000)
	free(opts)
	free(cast(void*, argv))
	run_out* o = new run_out()
	if (r == 0):
		o.status = 127
		o.text = c"(could not spawn the child)"
		return o
	o.status = r.status
	if (want == 2):
		o.text = strclone(r.stderr_text)
	else:
		o.text = strjoin(r.stdout_text, r.stderr_text)
	process_result_free(r)
	return o


# First "w.*.core" entry of dir in name order, as a dir-relative path,
# or 0 when there is none.
char* find_dump(char* dir):
	list[char*] names = dir_names(dir)
	if (names == 0):
		return 0
	for char* name in names:
		if ((name[0] == 'w') && (name[1] == '.') && (strlen(name) > 7) && ends_with(name, c".core")):
			return path_join(dir, name)
	return 0


# run_case <description> <fixture> <div-fixture> <ip-register> <other-binary>
void run_case(char* desc, char* fixture, char* divfix, char* ipreg, char* other):
	string_builder* d = string_new()
	string_append(d, c"bin/crash_dump_e2e_")
	string_append_int(d, getpid())
	string_append(d, c"_")
	string_append(d, ipreg)
	char* dir = d.data
	dir_remove_all(dir)
	shell_commands_mkdir_one(dir, 1)
	char* absdir = path_join(ROOT, dir)

	char* sdesc = strjoin(desc, c" (stderr)")
	run_out* r = run(path_join(ROOT, fixture), 0, 0, 0, path_join(absdir, c"w.%p.core"), 2)
	if (r.status != 139):
		fail_line(desc, strjoin(c"expected death by SIGSEGV (status 139), got ", itoa(r.status)))
	expect(sdesc, r.text, c"fatal signal: SIGSEGV")
	expect(sdesc, r.text, c"registers:")
	expect(sdesc, r.text, cat3(c" ", ipreg, c"=0x"))
	expect(sdesc, r.text, c"build-id: ")
	expect(sdesc, r.text, cat3(c"crash dump written to ", absdir, c"/w."))
	char* core = find_dump(dir)
	if (core == 0):
		fail_line(desc, strjoin(c"no dump file appeared in ", dir))
		dir_remove_all(dir)
		return
	if (ends_with(core, c"w.%p.core")):
		fail_line(desc, c"%p was not expanded")

	r = run(WCORE, core, 0, 0, 0, 1)
	expect(desc, r.text, c"source: W crash handler dump")
	expect(desc, r.text, c"(core and binary match)")
	expect(desc, r.text, c"SIGSEGV (invalid memory reference)")
	expect(desc, r.text, c"faulting address: 0x00000000")
	expect(desc, r.text, c"at crash_deep (")
	expect(desc, r.text, c"at crash_mid (")
	expect(desc, r.text, c"at main (")
	expect(desc, r.text, c"crash_null_deref_fixture.w:")
	expect(desc, r.text, cat3(c"  ", ipreg, c" 0x"))

	char* jdesc = strjoin(desc, c" (--json)")
	r = run(WCORE, c"--json", core, fixture, 0, 1)
	expect(jdesc, r.text, c"\"source\":\"w_crash_dump\"")
	expect(jdesc, r.text, c"\"build_id_verified\":true")
	expect(jdesc, r.text, c"\"signal\":11")
	expect(jdesc, r.text, c"\"si_code\":1")
	expect(jdesc, r.text, c"\"function\":\"crash_deep\"")
	expect(jdesc, r.text, c"\"trace_exact\":true")

	r = run(WCORE, core, other, 0, 0, 1)
	if (r.status == 0):
		fail_line(desc, c"wcore accepted a binary with a different build-id")
	expect(strjoin(desc, c" (wrong binary)"), r.text, c"build-id mismatch")

	# SIGFPE: the faulting address is the pc.
	char* div_core = path_join(dir, c"div.core")
	run(divfix, 0, 0, 0, div_core, 1)
	char* fdesc = strjoin(desc, c" (SIGFPE)")
	r = run(WCORE, div_core, 0, 0, 0, 1)
	expect(fdesc, r.text, c"SIGFPE (arithmetic exception)")
	expect(fdesc, r.text, c"at crash_divide (")

	# Unwritable path: reported, and the process still dies of SIGSEGV.
	char* missing = path_join(dir, c"missing/x.core")
	char* udesc = strjoin(desc, c" (unwritable)")
	r = run(fixture, 0, 0, 0, missing, 2)
	expect(udesc, r.text, strjoin(c"crash dump: cannot write ", missing))
	expect(udesc, r.text, c"at crash_deep (")
	if (r.status != 139):
		fail_line(udesc, strjoin(c"expected status 139, got ", itoa(r.status)))

	dir_remove_all(dir)


int main(int argc, char** argv):
	WCORE = c"bin/wcore"
	ROOT = malloc(4096)
	if (getcwd(ROOT, 4096) <= 0):
		out(c"FAIL: getcwd failed\n")
		return 1

	run_case(c"32-bit dump", c"bin/crash_dump_fixture32", c"bin/crash_dump_div32", c"eip", c"bin/crash_dump_div32")
	run_case(c"64-bit dump", c"bin/crash_dump_fixture64", c"bin/crash_dump_div64", c"rip", c"bin/crash_dump_div64")

	if (FAILED != 0):
		return 1
	out(c"crash dump test OK\n")
	return 0
