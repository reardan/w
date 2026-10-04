int main():
	int a = 2 +
		3 *
		4
	if (a != 14): return 1
	a = a | # Continue after a comment too.
		32
	if (a != 46): return 2
	a++
	if (a != 47): return 3
	a-- # The next statement does not belong to this expression.
	if (a != 46): return 4
	int b = 9 + /* intervening comment */
		2
	if (b != 11): return 5
	return 0
