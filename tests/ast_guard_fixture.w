int ast_guard_calls


bool ast_guard_hit(int value):
	ast_guard_calls += 1
	return value > 0


int main():
	int i = 0
	int total = 0
	while (i < 8 && ast_guard_hit(1)):
		i += 1
		if (i == 2): continue
		elif (i == 6): break
		else: total += i
	if (total != 13 || ast_guard_calls != 6): return 1
	if (ast_guard_hit(0) && ast_guard_hit(1)): return 2
	if (ast_guard_hit(1) || ast_guard_hit(0)): total += 1
	if (total != 14 || ast_guard_calls != 8): return 3
	return 0
