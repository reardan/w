# Fixture for c_import_verbose_note_test (build.base.json): the header
# declares a static function, which is not exported by the library, so
# c_import skips it. -v surfaces the skip as a plain informational note
# on stderr ("note: c_import skipped ..."); without -v nothing prints,
# and '-v --strict' still succeeds because a note is not a warning
# (libs/extras/c_import/importer.w's ci_skip_extern_function;
# docs/projects/ai_tooling.md). Unprototyped declarations, the shape
# this fixture used before, now import as variadic functions instead of
# skipping.
c_import "libc.so.6" c"tests/c_import_skip_note_fixture.h"


int main(int argc, int argv):
	return 0
