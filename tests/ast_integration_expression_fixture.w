# Cross-branch AST replay: formatting, generic bindings, buffer promotion,
# aggregate temporaries, map defaults and owned return statements.
import lib.lib
import lib.utf8

struct ast_integration_record:
	int value

struct ast_integration_buffer:
	int value

struct ast_integration_later:
	int value

int ast_integration_order

T ast_integration_identity[T](T value): return value

int ast_integration_mark(int value):
	ast_integration_order = ast_integration_order * 10 + value
	return value

int ast_integration_present(void* first, void* second): return (first != 0) + (second != 0)

ast_integration_record ast_integration_make(int value):
	return ast_integration_record(value)

map[int, int] ast_integration_default():
	return new map[int, int](ast_integration_identity[ast_integration_record](ast_integration_make(ast_integration_mark(3))).value)

int[] ast_integration_array():
	return new int[ast_integration_identity[int](ast_integration_mark(4))]

string ast_integration_text(int value):
	return f"[{ast_integration_identity[int](value):04d}]/[{f"{value:x}":>4s}]"

int main():
	ast_integration_buffer[1] records
	records[0].value = 8
	if (f"{ast_integration_present(records, cast(ast_integration_later*, 0)):02d}/{ast_integration_identity[int](7):03d}" != s"01/007"): return 1
	if (ast_integration_text(42) != s"[0042]/[  2a]"): return 2
	if (f"{ast_integration_identity[ast_integration_record](ast_integration_make(ast_integration_mark(1))).value:02d}/{ast_integration_mark(2):02d}" != s"01/02"): return 3
	if (ast_integration_order != 12): return 4
	map[int, int] defaults = ast_integration_default()
	if (defaults[9] != 3 || ast_integration_order != 123): return 5
	int[] values = ast_integration_array()
	if (values.length != 4 || ast_integration_order != 1234): return 6
	values[1] = 42
	if (f"{ast_integration_identity[int](values[1:3][0]):04d}" != s"0042"): return 7
	defaults.free()
	return 0
