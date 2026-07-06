struct ca_pair:
	int a
	int b


int main():
	ca_pair x
	ca_pair y
	x.a = 1
	x.b = 2
	y.a = 3
	y.b = 4
	x += y
	return 0
