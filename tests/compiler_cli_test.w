# wbuild: step="bin/wv2" expect_fail expect_stderr="usage: w [x64"
# wbuild: step="bin/wv2 tests/no_such_cli_file.w -o bin/cli_missing" expect_fail expect_stderr="no such file: 'tests/no_such_cli_file.w'"
# wbuild: step="bin/wv2 -v -v tests/no_such_cli_file.w -o bin/cli_missing" expect_fail expect_stderr="not found error"
# wbuild: step="bin/wv2 tests/cli_probe.w -o bin/cli_probe"
# wbuild: step="bin/wv2 -v -v tests/cli_probe.w -o bin/cli_probe_v"
# wbuild: step="sh -c 'bin/wv2 \"$PWD/tests/cli_probe.w\" -o bin/cli_probe_abs'"
# wbuild: step="bin/wv2 tests/cli_path_import_probe.w -o bin/cli_badimport" expect_fail expect_stderr="import paths are dotted module names"
# wbuild: step="bin/wv2 tests/cli_probe.w -o /no/such/dir/cli_out" expect_fail expect_stderr="could not open output file"
#
# The optimizer/codegen option battery: every spelling of each toggle
# compiles the probe, so link_option() recognizes (and the backends
# honor) both the default-on and the disabled form of each pass.
# tests/regalloc_diff_test.w drives the no-* forms too, but it is
# excluded from ./wbuild tests; these steps keep the parsing covered
# inside the standard suite (and under the coverage harness).
# wbuild: step="bin/wv2 --stats-selfcheck tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 -O0 tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-cond-branch tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --cond-branch tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-loop-rotate tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --loop-rotate tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-ivopts tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --ivopts tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-narrow-regs tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --narrow-regs tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-expr-regs tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --expr-regs tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-x86-budget tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --x86-budget tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-regs tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-direct-calls tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --inline tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --no-inline tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 --stats tests/cli_probe.w -o bin/cli_flagged"
# wbuild: step="bin/wv2 wasm --wasm-acc=globals tests/cli_probe.w -o bin/cli_probe.wasm"
# wbuild: step="bin/wv2 wasm --wasm-acc=locals tests/cli_probe.w -o bin/cli_probe.wasm"
#
# Subcommands and their usage text.
# wbuild: step="bin/wv2 check" expect_fail expect_stderr="usage: w check [--json]"
# wbuild: step="bin/wv2 check --imports tests/cli_probe.w"
# wbuild: step="bin/wv2 deps --help" expect_stdout="usage: w deps [--jso"
# wbuild: step="bin/wv2 deps tests/cli_probe.w" expect_stdout="tests/cli_probe.w"
# wbuild: step="bin/wv2 defhash --help" expect_stdout="usage: w defhash"
# wbuild: step="bin/wv2 defhash tests/cli_probe.w" expect_stdout="\"kind\": \"function\""
# wbuild: step="bin/wv2 symbols --help" expect_stdout="usage: w symbols [--json]"
# wbuild: step="bin/wv2 symbols --json tests/cli_probe.w" expect_stdout="\"kind\": \"function\""
# The types probe declares struct/enum/alias/union types so
# symbols_type_kind_name() spells every kind name; the wasm/win64/x64
# selectors light the arch-name branches.
# wbuild: step="bin/wv2 symbols --json tests/cli_types_probe.w" expect_stdout="\"kind\": \"alias\"" expect_stdout="\"kind\": \"union\"" expect_stdout="\"kind\": \"struct\"" expect_stdout="\"kind\": \"enum\""
# wbuild: step="bin/wv2 x64 symbols --json tests/cli_probe.w" expect_stdout="\"arch\": \"x64\""
# wbuild: step="bin/wv2 wasm symbols --json tests/cli_probe.w" expect_stdout="\"arch\": \"wasm\""
# wbuild: step="bin/wv2 win64 symbols --json tests/cli_probe.w" expect_stdout="\"arch\": \"win64\""
/*
compiler_cli_test: command-line surface of bin/wv2 that the rest of the
suite never exercises (docs/projects/line_coverage.md drive: these paths
were invisible to compiler_coverage).

Covers, in compiler/compiler.w: the bare-compiler usage diagnostic, the
missing-input diagnostics with and without -v (file_not_found_error
speaks only under verbosity), absolute-path inputs, the path-style
import hint, the output-open failure, every spelling of the optimizer
and codegen toggles in link_option (the no-* twins otherwise ride only
on tests/regalloc_diff_test.w, which ./wbuild tests excludes), the
--wasm-acc recognition, and the check/deps/defhash/symbols subcommands
including their --help usage text, JSON type-kind names for every user
type kind, and the per-arch arch names.

tests/cli_probe.w is the minimal compile input; tests/cli_types_probe.w
declares one type of every user-declarable kind; tests/
cli_path_import_probe.w spells an import as a file path to provoke the
dotted-module hint.
*/
import lib.lib

# The steps above are the test; the program body only has to exist so
# the target's compile step succeeds.
int main():
	return 0
