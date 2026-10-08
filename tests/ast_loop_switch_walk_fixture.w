# S2.2c: for-loop and switch headers parsed before they are emitted, then
# walked from their records (--ast-emit-retained). Compiled in both modes
# by ast_retained_emit_test, which requires identical images and
# diagnostics: the duplicate-case and case-type warnings below are emitted
# by the switch walk's case phases, and the multi-line headers make the
# walk emit before lexing past a header value.
import lib.generator
import lib.utf8

enum walk_color:
	walk_red
	walk_green
	walk_blue

struct walk_countdown:
	int start

walk_countdown* walk_countdown_new(int start):
	walk_countdown* c = cast(walk_countdown*, malloc(4))
	c.start = start
	return c

int walk_countdown_iter_begin(walk_countdown* c):
	return c.start

int walk_countdown_iter_done(walk_countdown* c, int cursor):
	return cursor <= 0

int walk_countdown_iter_next(walk_countdown* c, int cursor):
	return cursor - 1

int walk_countdown_iter_value(walk_countdown* c, int cursor):
	return cursor

int walk_limit(int n):
	return n + 1

void walk_take_char(char c):
	pass

generator int walk_numbers(int limit):
	for i in range(limit):
		if (i == 4): return
		yield i * 2

int walk_ranges():
	int total = 0
	for int i in range 3: total = total + i
	for i in range(1, walk_limit(4)):
		if (i == 2): continue
		total = total + i * 10
	for int i in range(10, 0, -3):
		total = total + i
		if (i < 3): break
	for i in range(
			2,
			walk_limit(3)): total = total + 1000
	for i in range(walk_limit(0)):
		for j in range(i, 3, 1):
			if (j == 2): break
			total = total + 7
	return total

int walk_containers():
	int total = 0
	list[int] values = new list[int]
	values.push(3)
	values.push(4)
	values.push(5)
	for v in values: total = total + v
	for i, v in values: total = total + i * v
	for i, v in enumerate(values): total = total + i
	map[int, int] squares = new map[int, int]
	squares[2] = 4
	squares[3] = 9
	for int k, int v in squares: total = total + k * 100 + v
	set[int] seen = new set[int]
	seen.add(6)
	for k in seen: total = total + k
	int[3] fixed
	fixed[0] = 1
	fixed[1] = 2
	fixed[2] = 3
	for int x in fixed: total = total + x
	for c in "ab": total = total + c
	walk_countdown* down = walk_countdown_new(3)
	for int x in down:
		if (x == 1): break
		total = total + x
	free(down)
	for n in walk_numbers(9):
		if (n == 4): break
		total = total + n
	for n in walk_numbers(9):
		if (n == 2): return total
	return total

int walk_switches(int n, char* name, walk_color color):
	int total = 0
	switch n:
		case 1: total = 1
		case 2, 3:
			total = 2
		case 1: total = 99
		case 'a': total = 3
		default: total = 4
	switch (n + 1):
		case 5, 6: total = total + 50
		case 7: break
	switch name:
		case c"abc": total = total + 100
		case "def", c"ghi":
			total = total + 200
		default:
			switch color:
				case walk_red: total = total + 1000
				case walk_green, walk_red: total = total + 2000
	switch color:
	for i in range(4):
		switch i:
			case 1: continue
			case 2: break
			case 3:
				if (n == 3): break
				total = total + 5
		total = total + i
	switch n:
		case "x": total = total + 1
	return total

int main():
	walk_take_char(65)
	if (walk_ranges() == 0): return 1
	if (walk_containers() == 0): return 2
	if (walk_switches(2, c"ghi", walk_blue) == 0): return 3
	return 0
