import lib


/*int range(int max):
	int i = 0
	while (i < max):
		yield i
		i = i + 1


int main():
	print("printing two iterated elements: ")
	int it = range(4)
	print(itoa(it()))
	print(", ")
	print(itoa(it()))
	println(".")
	println("printing 0...9: ")

	return 0*/


int main():
	for int i in range(10):
		print_int("range: ", i)
	return 0
