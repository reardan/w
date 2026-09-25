/*
Where bin/wexec, bin/wtest and bin/wtest_map_check get their build
manifest (issue #323: the manifest is not committed).

With no -f override, the manifest is generated in memory from
build.base.json plus the source tree (tools/wbuildgen_lib.w), so it can
never be stale. A directory without build.base.json (the scratch trees
the wtest/wexec tests build) falls back to reading a build.json there.
An explicit -f path is always read as a file.
*/
import lib.lib
import lib.file
import tools.wbuildgen_lib


# The name to use for the manifest in diagnostics: the -f path, or
# "build.base.json" / "build.json" for the default resolutions.
char* manifest_source_label


/* Return the manifest JSON text, or 0 after setting
manifest_source_label (callers print their own "cannot read" error with
it; a generation failure has already printed wbuildgen's own error).
path = 0 means the default resolution above. scan_tree = 0 generates
build.base.json's targets only (see wbg_generate). */
char* manifest_source_text(char* path, int scan_tree):
	if (path != 0):
		manifest_source_label = path
		return file_read_text(path)
	char* base = file_read_text(c"build.base.json")
	if (base != 0):
		free(base)
		manifest_source_label = c"build.base.json"
		return wbg_generate(c"build.base.json", scan_tree)
	manifest_source_label = c"build.json"
	return file_read_text(c"build.json")
