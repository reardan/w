# Compile-error fixture: an f-string without a closing quote must fail
# with "unterminated template string literal".
int main():
	string s = f"never closed
	return 0
