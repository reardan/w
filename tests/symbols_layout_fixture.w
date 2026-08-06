# Fixture for symbols_test's --layout steps: native struct layout with a
# nested struct field, a pointer field, an inline array field (whose size
# includes the 2-word runtime descriptor header), an int64 field, and a
# union. Offsets are the compiler's packed sums, and int/pointer widths
# follow the word size, so the x64 selector steps see different numbers:
# sym_layout_point.y sits at offset 4 on the default target and 8 on x64.

struct sym_layout_point:
	int x
	int y

struct sym_layout_inner:
	char tag
	int value

struct sym_layout_outer:
	char kind_tag
	sym_layout_inner inner
	sym_layout_point* link
	int[3] cells
	int64 wide

union sym_layout_union:
	int word
	int64 big
	char small

int main():
	sym_layout_point p
	p.x = 1
	p.y = 2
	return p.x + p.y - 3
