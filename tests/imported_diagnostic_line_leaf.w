# Companion module for tests/imported_diagnostic_line_fixture.w (wave
# 1b): a warning fired here, inside an imported (non-root) file, used
# to report one line too high -- compile_save (compiler/compiler.w)
# saved line_number + 1 before compiling an import and restored the
# inflated value, and the paired defect let the importer's still-
# pending lookahead character leak into this file's freshly-reset
# line_number before its first byte was even read. The '&' below must
# be reported at exactly this file's own physical line, not one high.
int imported_diagnostic_line_warn(int a, int b):
	if (a == 1 & b == 2):
		return 1
	return 0
