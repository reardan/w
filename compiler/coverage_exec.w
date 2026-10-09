/*
Self-coverage hook (docs/projects/line_coverage.md, "Compiler coverage").

When $W_COVERAGE_COMPILER (32-bit compiler builds) or
$W_COVERAGE_COMPILER_64 (64-bit builds) names an executable, the
compiler re-executes as that program with the same arguments before
doing anything else (bin/repl and bin/wdbg do the same for
$W_COVERAGE_REPL[_64] and $W_COVERAGE_WDBG[_64]). The named program is
the same source compiled with --coverage, so every output is unchanged;
the variable is cleared for the re-executed process so it does not
redirect again. When $W_COVERAGE_OUT names a directory, the instrumented
run's counters go to $W_COVERAGE_OUT/<tag>_x86/<pid>.raw (_x64 for
64-bit builds) through $W_PROFILE_OUT. A process started with
$W_PROFILE_OUT already set is being profiled by its caller and is not
redirected.

tools/wcoverage_suite.w drives it: setting the variables for one test-suite
run reroutes every compile the suite makes, including the compilers that
tests spawn themselves, without wrapper scripts or a scratch tree.

Compiled by the pinned seed (it is in w.w's import graph): seed-era syntax
only.
*/
import lib.env


void coverage_exec_redirect(char* variable, char* tag, int argv):
	char* name = variable
	char* arch = c"_x86/"
	if (__word_size__ == 8):
		name = strjoin(variable, c"_64")
		arch = c"_x64/"
	char* target = env_get(name)
	if (target == 0): return
	if (target[0] == 0): return
	# A caller profiling this very process (verify_pgo, profile_refresh)
	# set $W_PROFILE_OUT for it: run as asked, not as the coverage build.
	char* profile = env_get(c"W_PROFILE_OUT")
	if (profile != 0):
		if (profile[0] != 0): return
	char** envp = env_copy_with(env_current(), name, c"")
	char* out = env_get(c"W_COVERAGE_OUT")
	if (out != 0):
		if (out[0] != 0):
			char* dir = strjoin(out, c"/")
			char* sub = strjoin(strjoin(dir, tag), arch)
			char* stem = strjoin(sub, itoa(getpid()))
			envp = env_copy_with(envp, c"W_PROFILE_OUT", strjoin(stem, c".raw"))
	execve(target, cast(char**, argv), envp)
	print_error(c"error: cannot execute coverage build '")
	print_error(target)
	print_error(c"' named by $")
	print_error(name)
	print_error(c"\x0a")
	exit(1)
