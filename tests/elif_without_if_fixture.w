# An 'elif' that does not follow an if branch at the same indent level
# is not a statement: like a dangling 'else', the name falls through to
# expression parsing and fails symbol lookup (issue #360).
# expect_fail
# expect_stderr: Cannot find symbol: 'elif'
int main():
	elif x == 0:
		return 1
	return 0
