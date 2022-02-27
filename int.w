/*
int type: signed word

currently it's used for nearly everything
this is not appropriate because it's signed

*/

# Big Endian Load / Store
void save_i(char* p, int v, int n):
	int i = 0
	while (i < n):
		p[i] = v
		v = v >> 8
		i = i + 1


void save_int(char *p, int v):
	save_i(p, v, 4)


int load_i(char* p, int n):
	int result = 0
	while (n > 0):
		result = (result << 8) + (p[n - 1] & 255)
		n = n - 1
	return result


int load_int(char *p):
	return load_i(p, 4)