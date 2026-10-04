import lib.lib

struct ast_control_record:
	int value

int ast_control_events
void ast_control_note(int n): ast_control_events = ast_control_events * 10 + n
ast_control_record ast_control_make(int n): return ast_control_record(n)
T ast_control_identity[T](T value): return value

int ast_control_classify(int value):
	defer ast_control_note(1)
	if value < 0:
		if value < -5: return -2
		else: return -1
	elif value == 0: return 0
	else {
		return 1
	}

int ast_control_next(int* value):
	*value += 1
	return *value < 5

int main():
	if (ast_control_classify(-7) != -2): return 1
	if (ast_control_classify(-1) != -1): return 2
	if (ast_control_classify(0) != 0): return 3
	if (ast_control_classify(1) != 1): return 4
	if (ast_control_events != 1111): return 5
	int value = 0
	int sum = 0
	while ast_control_next(&value):
		if value == 2: continue
		elif value == 4: break
		sum += value
	if (sum != 4 || value != 4): return 6
	while (value > 0) {
		value -= 1
	}
	if (value != 0): return 7
	int* pointer = &sum
	if pointer:
		if *pointer != 4: return 8
	else: return 9
	float fraction = 1.5
	if fraction: sum += 1
	else: return 10
	bool enabled = false
	while enabled: return 11
	if ast_control_make(1).value:
		if (ast_control_identity[int](sum) != 5): return 12
	else: return 13
	list[int] values = list[int]{1, 2, 3}
	list[int] sliced = values[1:]
	if (sliced.length == 2 && sliced[0] == 2):
		if (f"{ast_control_identity[int](sliced[1]):02}" != s"03"): return 14
	else: return 15
	values.free()
	sliced.free()
	return 0
