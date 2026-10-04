int ast_statement_flow():
	int i = 0
	int total = 0
	while (i < 7):
		int local = i
		i = i + 1
		if (i == 2): continue
		switch i:
			case 3:
				int inner = local
				total = total + 30 + inner - local
				break
			case 5: continue
			default: total = total + i
		if (i == 6): break
	return total


int main():
	pass
	if (ast_statement_flow() != 41): return 1
	if (0): debugger
	return 0
