/*
wbuildgen: the command-line face of tools/wbuildgen_lib.w, which holds
the generation rules.

The build manifest is not committed (issue #323): bin/wexec and bin/wtest
generate it in memory from build.base.json plus the source tree on every
run. This tool exists to look at it and to gate it:

Usage: wbuildgen [--check] [--base build.base.json] [--out bin/build.json]

Without --check the manifest is written to --out (default
bin/build.json, `./wbuild manifest`) for reading or diffing. It is a
snapshot: nothing reads it back.

--check generates the manifest and prints "wbuildgen: OK (...)" when
generation succeeds, which is the CI gate (`./wbuild manifest_check`):
a bad directive, a name collision, or a tool target naming an unknown
bin/ path fails it. With an explicit --out, --check also byte-compares
the generated manifest with that file, writes the fresh one to
bin/build.json.gen, and exits 1 with a per-target drift summary when
they differ.
*/
import tools.wbuildgen_lib


int main(int argc, int argv):
	char* base_path = c"build.base.json"
	char* out_path = c"bin/build.json"
	int explicit_out = 0
	int check_only = 0
	int i = 1
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--check") == 0):
			check_only = 1
		else if (strcmp(*arg, c"--base") == 0):
			i = i + 1
			if (i >= argc):
				wbg_usage()
				return 1
			char** base_value = argv + i * __word_size__
			base_path = *base_value
		else if (strcmp(*arg, c"--out") == 0):
			i = i + 1
			if (i >= argc):
				wbg_usage()
				return 1
			char** out_value = argv + i * __word_size__
			out_path = *out_value
			explicit_out = 1
		else:
			wbg_usage()
			return 1
		i = i + 1

	char* rendered = wbg_generate(base_path, 1)
	if (rendered == 0):
		return 1

	wstream* out = stdout_writer()
	if (check_only & (explicit_out == 0)):
		stream_write_cstr(out, c"wbuildgen: OK (")
		stream_write_line(out, wbg_summary)
		stream_flush(out)
		return 0
	if (check_only):
		char* current = file_read_text(out_path)
		if (current != 0):
			if (strcmp(current, rendered) == 0):
				stream_write_cstr(out, c"wbuildgen: OK ")
				stream_write_cstr(out, out_path)
				stream_write_cstr(out, c" is up to date (")
				stream_write_line(out, wbg_summary)
				stream_flush(out)
				return 0
		# Failure (usually EEXIST) is fine, like wexec_make_dirs.
		mkdir(c"bin", 493)
		file_write_text(c"bin/build.json.gen", rendered)
		wbg_error(c"regenerated manifest written to bin/build.json.gen")
		if (current == 0):
			wbg_error2(c"cannot read manifest ", out_path)
		else:
			wbg_report_drift(out_path, current, rendered)
		return 1

	# The default output lives under bin/, which a fresh checkout lacks.
	if (explicit_out == 0):
		mkdir(c"bin", 493)
	# Atomic rewrite: a concurrent reader must never see a torn file, so
	# the rendered manifest lands in a sibling temp file first and
	# rename(2) swaps it into place. The temp path is derived from
	# out_path so it stays on out_path's filesystem.
	char* tmp_path = wbg_concat(out_path, c".tmp")
	if (file_write_text(tmp_path, rendered) == 0):
		wbg_error2(c"cannot write ", tmp_path)
		free(tmp_path)
		return 1
	# stream_open_write creates 0755; the manifest is a plain 0644 text
	# file and rename(2) carries the temp file's mode over.
	chmod(tmp_path, 420)
	if (rename(tmp_path, out_path) != 0):
		wbg_error2(c"cannot rename manifest into place: ", out_path)
		free(tmp_path)
		return 1
	free(tmp_path)
	stream_write_cstr(out, c"wbuildgen: wrote ")
	stream_write_cstr(out, out_path)
	stream_write_cstr(out, c" (")
	stream_write_line(out, wbg_summary)
	stream_flush(out)
	return 0
