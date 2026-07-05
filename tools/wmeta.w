/*
wmeta: the package.wmeta metadata checker (design: docs/package_metadata.txt).

Usage: wmeta check [package.wmeta]

Loads the package metadata file (default: package.wmeta in the current
directory), validates its fields, verifies every declared module maps to an
existing source file under the package root (expanding __arch__ to both x86
and x64), and follows "path" dependencies recursively: each vendored
package.wmeta must parse, its package name must match the dependency entry,
its version must satisfy the declared constraint, and no two packages in
the resulting set may claim the same top-level module path.

This is tooling-only validation: the compiler's import resolution is
untouched, and a build that does not run from an isolated root can still
pick up files from an ancestor W tree (see docs/package_metadata.txt).
*/
import lib.lib
import lib.stream
import lib.wmeta
import structures.string


void wmeta_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wmeta check [package.wmeta]")
	stream_flush(err)


int main(int argc, int argv):
	if (argc < 2):
		wmeta_usage()
		return 1
	char** command = argv + __word_size__
	if (strcmp(*command, c"check") != 0):
		wmeta_usage()
		return 1
	char* meta_path = c"package.wmeta"
	if (argc >= 3):
		char** arg = argv + 2 * __word_size__
		meta_path = *arg

	wmeta_check* check = wmeta_check_file(meta_path)
	if (check.errors.length > 0):
		wstream* err = stderr_writer()
		for char* message in check.errors:
			stream_write_cstr(err, c"wmeta: error: ")
			stream_write_line(err, message)
		stream_flush(err)
		return 1

	wmeta_package* root = check.packages[0]
	string_builder* s = string_new()
	string_append(s, c"wmeta: OK package '")
	string_append(s, root.name)
	string_append(s, c"' version ")
	string_append(s, root.version)
	string_append(s, c" (")
	string_append_int(s, root.modules.length)
	string_append(s, c" modules, ")
	string_append_int(s, check.packages.length - 1)
	string_append(s, c" path dependencies)")
	wstream* out = stdout_writer()
	stream_write_line(out, s.data)
	stream_flush(out)
	string_free(s)
	return 0
