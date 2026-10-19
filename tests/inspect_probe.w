# A small binary inspected on the host even when compiled for ARM64.
int inspect_answer(int value):
	return value + 42

int main():
	return inspect_answer(0) - 42
