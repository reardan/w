# Host for source-owned compiler-diagnostic targets that have no natural
# fixture of their own (issue #323: every target is declared in the
# sources). Nothing here is compiled or run; the directives below are
# the whole point of the file:
#   import_diagnostic_test  path-shaped / wildcard import spellings
#   read_error_test         a directory passed (or imported) as a source
#   self_host_warning_test  w.w compiles warning-free, 32- and 64-bit
#   repl_warning_test       repl.w compiles warning-free, 32- and 64-bit
#   unsafe_import_test      no production source imports libs.x.unsafe
# Inputs that are not valid W (so cannot be tracked .w files, which
# parser_generator_w_test parses) live in tests/diagnostic_inputs/ and
# are copied under bin/ by the steps that use them.
int main():
	return 0
# wbuild: target=import_diagnostic_test tag=tests dep=wv2 data=tests/diagnostic_inputs/import_path_shaped.w.txt data=tests/diagnostic_inputs/import_slash.w.txt data=tests/diagnostic_inputs/import_wildcard.w.txt
# wbuild: step="cp tests/diagnostic_inputs/import_path_shaped.w.txt bin/import_path_shaped_fixture.w"
# wbuild: step="bin/wv2 bin/import_path_shaped_fixture.w -o /dev/null" expect_fail expect_stderr="cannot locate 'lib/assert.w': import paths are dotted module names, not file paths; try 'import lib.assert'" reject_stderr="lib/assert/w.w"
# wbuild: step="bin/wv2 check --json bin/import_path_shaped_fixture.w" expect_fail expect_stdout="\"severity\": \"error\"" expect_stdout="cannot locate 'lib/assert.w': import paths are dotted module names, not file paths; try 'import lib.assert'"
# wbuild: step="cp tests/diagnostic_inputs/import_slash.w.txt bin/import_slash_fixture.w"
# wbuild: step="bin/wv2 bin/import_slash_fixture.w -o /dev/null" expect_fail expect_stderr="cannot locate 'lib/no_such_module': import paths are dotted module names, not file paths; try 'import lib.no_such_module'"
# wbuild: step="cp tests/diagnostic_inputs/import_wildcard.w.txt bin/import_wildcard_fixture.w"
# wbuild: step="bin/wv2 bin/import_wildcard_fixture.w -o /dev/null" expect_fail expect_stderr="import wildcard '.*' is not supported (an import already makes the whole module visible); use 'import lib.assert'"
# wbuild: target=read_error_test tag=tests dep=wv2 data=tests/diagnostic_inputs/read_error_root.w.txt
# wbuild: step="mkdir -p bin/read_error_dir.w"
# wbuild: step="bin/wv2 check bin/read_error_dir.w" expect_fail expect_stderr="read error while reading '" expect_stderr="/bin/read_error_dir.w'"
# wbuild: step="bin/wv2 check --json bin/read_error_dir.w" expect_fail expect_stdout="\"severity\": \"error\"" expect_stdout="\"message\": \"read error while reading '" expect_stdout="/bin/read_error_dir.w'\""
# wbuild: step="cp tests/diagnostic_inputs/read_error_root.w.txt bin/read_error_root.w"
# wbuild: step="bin/wv2 check bin/read_error_root.w" expect_fail expect_stderr="read error while reading '" expect_stderr="/bin/read_error_dir.w'"
# wbuild: target=self_host_warning_test tag=tests dep=wv2
# wbuild: step="bin/wv2 w.w -o bin/self_host_warning_check" reject_stderr="warning:"
# wbuild: step="bin/wv2 x64 w.w -o bin/self_host_warning_check_64" reject_stderr="warning:"
# wbuild: target=repl_warning_test tag=tests dep=wv2
# wbuild: step="bin/wv2 repl.w -o bin/repl_warning_check" reject_stderr="warning:"
# wbuild: step="bin/wv2 x64 repl.w -o bin/repl_warning_check_64" reject_stderr="warning:"
# wbuild: target=unsafe_import_test tag=tests
# wbuild: step="git grep --untracked -n -E import[[:space:]]+libs\\.x\\.unsafe -- :(glob)*.w :(glob)lib/**/*.w :(glob)libs/standard/**/*.w :(glob)libs/asm/**/*.w :(glob)libs/extras/**/*.w :(glob)structures/**/*.w :(glob)compiler/**/*.w :(glob)grammar/**/*.w :(glob)code_generator/**/*.w :(glob)debugger/**/*.w :(glob)tools/**/*.w :(glob)examples/**/*.w :(glob)graphics/**/*.w" expect_status=1
