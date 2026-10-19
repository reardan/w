# One type of every user-declarable kind, for tests/compiler_cli_test.w
# to read back through `w symbols --json` (kind names for struct, enum,
# alias and union).
struct cli_point:
	int x
	int y

enum cli_color:
	cli_red
	cli_green

type cli_len = int

union cli_cell:
	int as_int
	float as_float

int main():
	cli_point p
	cli_color c = cli_red
	cli_len n = 0
	cli_cell cell
	return p.x + c + n + cell.as_int
