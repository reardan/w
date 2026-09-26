# wbuild: target=wtest_runnable_test tag=tests dep=wtest data=tests/wtest/manifest_runnable.json data=tests/wtest/runnable_fixture/ data=tools/wtest_runnable_e2e.w
# wbuild: step="bin/wv2 tools/wtest_runnable_e2e.w -o bin/wtest_runnable_e2e"
# wbuild: step="bin/wtest_runnable_e2e" expect_stdout="wtest_runnable_scratch_test: OK"
/*
Fixture-driven checks for bin/wtest's --runnable-here filter
(tools/test_map.w). The filter's probes ask about THIS host (is the
32-bit ELF loader installed? the 64-bit one? an NVIDIA GPU?), so a
frozen expect-file case cannot assert both directions on every
machine -- the same lesson as manifest_unavailable.json's fictional
tools/mac/ path (tests/wtest/map_expectations.expect). This program
instead probes the host itself with the same evidence the filter
uses and asserts the matching direction: on a host WITH the loader
the target is kept, on one WITHOUT it the target is dropped and the
stderr reason names the missing loader. Run from the repo root.

The marker-path invocations select through a non-.w path, so they
compute no import closures. The closure-level invocation passes .w
changed paths on purpose: rule (b) then computes the fixture roots'
closures (touching bin/.wtest_deps_cache, which is safe -- entries
validate individually and wtest_archs_test already shares the file) so
the filter can attribute needs declared in IMPORTED modules
(ai_tooling_next_steps.md 2026-07-29).

Run by the wtest_runnable_test target (directives above). It replaced
tools/wtest_runnable_scratch_test.sh (issue #323: no shell scripts);
bin/wtest is spawned through lib/process.w with argv vectors and
controlled environment vectors -- no /bin/sh. The script's empty PATH
directory is a pid-scoped directory under bin/.
*/
import lib.lib
import lib.env
import tools.wtest_scratch


char* MANIFEST


struct wtest_out:
	char* out    # stdout
	char* err    # stderr


# bin/wtest changed -f MANIFEST <flag> <paths...> under envp (0 = inherit).
wtest_out* run_wtest(char** envp, char* flag, list[char*] paths):
	char** argv = strv_new(5 + paths.length)
	strv_set(argv, 0, c"bin/wtest")
	strv_set(argv, 1, c"changed")
	strv_set(argv, 2, c"-f")
	strv_set(argv, 3, MANIFEST)
	strv_set(argv, 4, flag)
	int i = 0
	while (i < paths.length):
		strv_set(argv, 5 + i, paths[i])
		i = i + 1
	spawn_options* opts = spawn_options_new()
	opts.env = envp
	process_result* r = process_run(c"bin/wtest", argv, opts, 0, 0)
	free(opts)
	free(cast(void*, argv))
	if (r == 0): fail(c"could not spawn bin/wtest")
	wtest_out* o = new wtest_out()
	o.out = r.stdout_text
	o.err = r.stderr_text
	return o


list[char*] marker():
	list[char*] paths = new list[char*]
	paths.push(c"widget/runnable.dat")
	return paths


int has_gpu():
	return path_exists(c"/dev/nvidiactl") || path_exists(c"/dev/nvidia0") || (process_which(c"nvidia-smi") != 0)


# Copy of the current environment without any "name=" entry.
char** env_without(char* name):
	char** base = env_current()
	int count = env_vector_count(base)
	char** v = strv_new(count)
	int out = 0
	for i in range(count):
		char* entry = env_entry_at(base, i)
		if (env_match_name(entry, name) < 0):
			strv_set(v, out, entry)
			out = out + 1
	return v


int main(int argc, char** argv):
	# The scratch directory is the empty PATH entry of the runner probes.
	sc_init(c"wtest_runnable_scratch_test", c"wtest_runnable_e2e_")
	sc_require(c"bin/wtest")
	MANIFEST = c"tests/wtest/manifest_runnable.json"
	int has32 = path_exists(c"/lib/ld-linux.so.2")
	int has64 = path_exists(c"/lib64/ld-linux-x86-64.so.2")
	int gpu = has_gpu()

	# --available alone must keep every loader/GPU/soname fixture target:
	# those probes are part of --runnable-here, not of the older flag (the
	# rn_shc_*/rn_wrun_* runner targets are asserted separately below --
	# their --available probes legitimately vary by host).
	wtest_out* o = run_wtest(0, c"--available", marker())
	list[char*] keep = split(c"rn_dyn32 rn_dyn64 rn_gpu rn_static rn_compile_only rn_dyn_imp rn_gpu_imp rn_plain_imp rn_broken_imp rn_dyn_missing rn_cuda_clib", ' ')
	int k = 0
	while (k < keep.length):
		if (has_line(o.out, keep[k]) == 0): fail(strjoin(c"--available dropped ", keep[k]))
		k = k + 1

	o = run_wtest(0, c"--runnable-here", marker())
	char* out = o.out
	char* err = o.err

	# A statically linked run target and a compile-only target are
	# runnable on every host.
	if (has_line(out, c"rn_static") == 0): fail(c"--runnable-here dropped the static target")
	if (has_line(out, c"rn_compile_only") == 0):
		fail(c"--runnable-here dropped the compile-only target")

	# 32-bit dynamically linked run target (root declares c_lib): needs
	# the i386 ELF interpreter.
	if (has32):
		if (has_line(out, c"rn_dyn32") == 0):
			fail(c"host has /lib/ld-linux.so.2 but rn_dyn32 was dropped")
	else:
		if (has_line(out, c"rn_dyn32")):
			fail(c"no /lib/ld-linux.so.2 on this host but rn_dyn32 was kept")
		if (contains(err, c"/lib/ld-linux.so.2 not found") == 0):
			fail(c"drop reason did not name /lib/ld-linux.so.2")

	# Same root compiled for x64: needs the 64-bit interpreter instead.
	if (has64):
		if (has_line(out, c"rn_dyn64") == 0):
			fail(c"host has the 64-bit loader but rn_dyn64 was dropped")
	else:
		if (has_line(out, c"rn_dyn64")):
			fail(c"no 64-bit loader on this host but rn_dyn64 was kept")
		if (contains(err, c"/lib64/ld-linux-x86-64.so.2 not found") == 0):
			fail(c"drop reason did not name the 64-bit loader")

	# GPU run target (root imports lib.cuda): needs the NVIDIA driver.
	if (gpu):
		if (has_line(out, c"rn_gpu") == 0): fail(c"host has an NVIDIA GPU but rn_gpu was dropped")
	else:
		if (has_line(out, c"rn_gpu")): fail(c"no NVIDIA GPU on this host but rn_gpu was kept")
		if (contains(err, c"no NVIDIA GPU") == 0): fail(c"drop reason did not name the missing GPU")

	# The soname probe (ai_tooling_next_steps.md 2026-08-04):
	# dyn_missing.w names a library NO host has, so rn_dyn_missing is
	# dropped everywhere -- without the 64-bit loader the reason is the
	# loader itself, with it the reason must name the missing soname.
	if (has_line(out, c"rn_dyn_missing")):
		fail(c"rn_dyn_missing was kept (missing c_lib soname not probed)")
	if (has64):
		if (contains(err, c"libwtest_no_such_lib.so.9 not found") == 0):
			fail(c"rn_dyn_missing's drop reason did not name the missing soname")

	# libcuda keeps its GPU-bit behavior: c_lib "libcuda.so.1" is probed
	# via the NVIDIA driver evidence, never via the standard-lib-dir
	# soname probe (libcuda lives wherever the driver installer put it).
	if (gpu):
		if (has64 && (has_line(out, c"rn_cuda_clib") == 0)):
			fail(c"GPU host dropped rn_cuda_clib (libcuda must use the GPU bit, not the soname probe)")
	else:
		if (has_line(out, c"rn_cuda_clib")):
			fail(c"no NVIDIA GPU on this host but rn_cuda_clib was kept")
		if (contains(err, c"libcuda.so.1 not found")):
			fail(c"rn_cuda_clib was dropped by a libcuda soname probe instead of the GPU bit")

	# Closure-level attribution (ai_tooling_next_steps.md 2026-07-29): the
	# needy directives below live in imported modules, never in the
	# roots, so this invocation passes the modules as .w changed paths --
	# rule (b) selects the importing roots' targets AND computes their
	# closures, which the filter then scans. broken_imp.w (a root whose
	# closure can never be computed -- its second import does not exist)
	# rides along to pin the fallback: root-only scan, no directives,
	# kept everywhere.
	list[char*] mods = new list[char*]
	mods.push(c"tests/wtest/runnable_fixture/dep_dyn.w")
	mods.push(c"tests/wtest/runnable_fixture/dep_gpu.w")
	mods.push(c"tests/wtest/runnable_fixture/dep_plain.w")
	mods.push(c"tests/wtest/runnable_fixture/broken_imp.w")
	o = run_wtest(0, c"--runnable-here", mods)
	out = o.out
	char* err2 = o.err

	# A clean import chain must not have needs invented for it, and the
	# closure-less root must fall back to its own (directive-free) text.
	if (has_line(out, c"rn_plain_imp") == 0):
		fail(c"closure scan dropped rn_plain_imp (clean import chain)")
	if (has_line(out, c"rn_broken_imp") == 0):
		fail(c"closure-less root rn_broken_imp was dropped instead of falling back to the root text")

	# dep_dyn.w carries the c_lib directive: the x86 root that merely
	# imports it needs the i386 loader now.
	if (has32):
		if (has_line(out, c"rn_dyn_imp") == 0):
			fail(c"host has /lib/ld-linux.so.2 but rn_dyn_imp was dropped")
	else:
		if (has_line(out, c"rn_dyn_imp")):
			fail(c"no /lib/ld-linux.so.2 on this host but rn_dyn_imp was kept (imported c_lib not attributed)")
		if (contains(err2, c"/lib/ld-linux.so.2 not found") == 0):
			fail(c"rn_dyn_imp drop reason did not name /lib/ld-linux.so.2")

	# dep_gpu.w imports lib.cuda: the root that merely imports IT needs
	# the NVIDIA driver now (the lib/tensor.w shape).
	if (gpu):
		if (has_line(out, c"rn_gpu_imp") == 0):
			fail(c"host has an NVIDIA GPU but rn_gpu_imp was dropped")
	else:
		if (has_line(out, c"rn_gpu_imp")):
			fail(c"no NVIDIA GPU on this host but rn_gpu_imp was kept (imported lib.cuda not attributed)")
		if (contains(err2, c"no NVIDIA GPU") == 0):
			fail(c"rn_gpu_imp drop reason did not name the missing GPU")

	# 'sh -c'-wrapped runner steps (ai_tooling_next_steps.md 2026-08-05,
	# point 1): the runner path hides inside the '-c' command string --
	# pac_corrupt_test_arm64's shape -- so --available must scan the
	# string for the known runner spellings ('bin/wrun arm64', 'bin/wrun
	# wasm'); the direct 'bin/wrun <mode>' argv shape (rn_wrun_*, every
	# generated arm64/wasm twin's run step) is probed the same way.
	# Probed deterministically by
	# controlling the evidence the filter reads: an empty PATH removes
	# qemu, wasmtime and node (QEMU_ARM64 unset), while a set QEMU_ARM64
	# is itself positive evidence the arm64 runner works.
	char** bare = env_copy_with(env_without(c"QEMU_ARM64"), c"PATH", sc_dir)
	o = run_wtest(bare, c"--available", marker())
	out = o.out
	err = o.err
	if (has_line(out, c"rn_shc_arm64")):
		fail(c"no qemu on PATH but the sh -c arm64 runner target was kept")
	if (has_line(out, c"rn_shc_wasm")):
		fail(c"no wasm runtime on PATH but the sh -c wasm runner target was kept")
	if (has_line(out, c"rn_wrun_arm64")):
		fail(c"no qemu on PATH but the bin/wrun arm64 runner target was kept")
	if (has_line(out, c"rn_wrun_wasm")):
		fail(c"no wasm runtime on PATH but the bin/wrun wasm runner target was kept")
	if (contains(err, c"qemu-aarch64-static not found") == 0):
		fail(c"sh -c arm64 drop reason did not name qemu")
	if (contains(err, c"no wasm runtime (wasmtime or node) found") == 0):
		fail(c"sh -c wasm drop reason did not name the wasm runtime")
	if (has_line(out, c"rn_static") == 0):
		fail(c"empty PATH dropped rn_static (only runner-shaped steps may be probed)")
	o = run_wtest(env_copy_with(bare, c"QEMU_ARM64", c"qemu-aarch64"), c"--available", marker())
	if (has_line(o.out, c"rn_shc_arm64") == 0):
		fail(c"QEMU_ARM64 set but the sh -c arm64 runner target was dropped")
	if (has_line(o.out, c"rn_wrun_arm64") == 0):
		fail(c"QEMU_ARM64 set but the bin/wrun arm64 runner target was dropped")

	return sc_ok()
