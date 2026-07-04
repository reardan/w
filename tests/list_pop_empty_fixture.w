# Runtime fixture: popping an empty list must abort with a nonzero exit.
int main():
	list[int] l = new list[int]
	int x = l.pop()
	return 0
