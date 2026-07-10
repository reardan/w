struct casm_point:
	int x
	int y


int main():
	map[int, casm_point] m = new map[int, casm_point]
	casm_point p
	p.x = 1
	p.y = 2
	m[1] = p
	m[1] += p
	return 0
