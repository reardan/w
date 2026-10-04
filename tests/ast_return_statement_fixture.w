import lib.lib
import lib.utf8

struct ast_return_record:
	int number
	int tag

int ast_return_events
void ast_return_note(int n): ast_return_events = ast_return_events * 10 + n

int ast_return_choose(int n):
	defer ast_return_note(1)
	if (n): return n + 1
	return 0

ast_return_record ast_return_make(int n):
	ast_return_record value = ast_return_record(n, 3)
	defer ast_return_note(2)
	return value

ast_return_record ast_return_forward(int n): return ast_return_make(n)
void ast_return_bare(int n):
	defer ast_return_note(3)
	if (n): return
	ast_return_note(4)

void ast_return_empty(): return
bool ast_return_bool(int n): return n != 0
int16 ast_return_narrow(int n): return n
string ast_return_text(int n): return f"n={n:04}"
int ast_return_metadata(list[int] values):
	int length = values.length
	if (length): return values[0]
	return 0

int main():
	if (ast_return_choose(4) != 5): return 1
	if (ast_return_events != 1): return 2
	ast_return_record value = ast_return_forward(7)
	if (value.number != 7 || value.tag != 3): return 3
	if (ast_return_events != 12): return 4
	ast_return_bare(1)
	if (ast_return_events != 123): return 5
	ast_return_empty()
	if (ast_return_bool(7) != true): return 6
	if (ast_return_narrow(-123) != -123): return 7
	if (ast_return_text(42) != s"n=0042"): return 8
	list[int] values = new list[int]
	values.push(9)
	if (ast_return_metadata(values) != 9): return 9
	return 0
