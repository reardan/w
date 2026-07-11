/*
wvdiff: unified line-diff CLI, dogfooding libs/extras/vcs/diff.w's Myers
diff and unified-format renderer (docs/projects/version_control.md,
Wave 1).

Usage: wvdiff <old> <new>

Prints a `diff -u`-style unified diff of <old> vs <new> to stdout, with
3 lines of context. Exit status follows the diff(1) convention: 0 when
the files compare equal (nothing is printed), 1 when they differ, 2 on
a usage or I/O error (missing/unreadable file).
*/
import lib.lib
import lib.stream
import lib.file
import libs.extras.vcs.diff


void wvdiff_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wvdiff <old> <new>")
	stream_flush(err)


int wvdiff_read_error(char* path):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wvdiff: cannot read '")
	stream_write_cstr(err, path)
	stream_write_line(err, c"'")
	stream_flush(err)
	return 2


int main(int argc, int argv):
	if (argc != 3):
		wvdiff_usage()
		return 2
	char** old_arg = argv + __word_size__
	char** new_arg = argv + 2 * __word_size__
	char* old_path = *old_arg
	char* new_path = *new_arg

	char* old_text = file_read_text(old_path)
	if (old_text == 0):
		return wvdiff_read_error(old_path)
	char* new_text = file_read_text(new_path)
	if (new_text == 0):
		return wvdiff_read_error(new_path)

	diff_result* result = diff_text(old_text, new_text, diff_default_context())
	if (diff_is_identical(result)):
		return 0

	wstream* out = stdout_writer()
	diff_render_unified(out, old_path, new_path, result)
	stream_flush(out)
	return 1
