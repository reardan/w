import lib.lib

int coverage_unused():
	return 99

int coverage_choose(int flag):
	if (flag == 0):
		return 1
	elif (flag == 1):
		return 2
	else:
		return 3

int main(int argc, int argv):
	int total = 0
	for i in range(3):
		total = total + coverage_choose(argc - 1)
	while (total < 0):
		total = total + 1
	if (argc > 1):
		exit(0)
	return total - 3
