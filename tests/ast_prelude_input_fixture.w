int main(int argc, char** argv):
	if (argc < 2): return 1
	char mode = argv[1][0]
	if (mode == 'l'):
		list[char*] data = lines()
		if (len(data) != 2): return 2
		println(data)
	else if (mode == 'w'):
		list[char*] data = words()
		if (len(data) != 4): return 3
		println(data)
	else:
		string header = input()
		if (header != s"header"): return 4
		list[int] data = ints()
		if (len(data) != 3 || data[1] != -2): return 5
		println(data)
		if (len(read_all()) != 0): return 6
	return 0
