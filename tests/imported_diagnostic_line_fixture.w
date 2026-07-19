# Regression for the imported-file diagnostic line-number bug (wave 1b,
# docs/projects/ai_tooling_next_steps.md's "w check --bool-ops position/
# chain bugs" entry). Two distinct manifestations of the same root
# cause, both pinned here:
#
# (1) a warning fired *inside* the imported tests/imported_diagnostic_
#     line_leaf.w must report that file's own physical line, not one
#     higher (compile_save saved line_number + 1, and a paired defect
#     let the importer's still-pending lookahead leak into the
#     imported file's freshly-reset line_number before its first byte
#     was read).
# (2) a warning fired in *this* file, after the import statement
#     completes, must still report this file's own physical line
#     (naively dropping the '+ 1' without also preserving the
#     importer's pending lookahead across the nested compile undercounts
#     by one instead).
# expect_stderr: bitwise '&' on bool operands in a condition does not short-circuit; did you mean '&&'?
# expect_stderr: /tests/imported_diagnostic_line_leaf.w:10
# expect_stderr: /tests/imported_diagnostic_line_fixture.w:25
import lib.lib
import tests.imported_diagnostic_line_leaf


int check_after_import(int a, int b):
	if (a == 1 & b == 2):
		return 1
	return 0


int main():
	return check_after_import(imported_diagnostic_line_warn(1, 2), 2)
