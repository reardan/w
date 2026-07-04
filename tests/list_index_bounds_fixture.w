# Runtime fixture: indexing past the end must abort with a nonzero exit.
int main():
	list[int] l = list[int]{1, 2}
	int x = l[5]
	return 0
