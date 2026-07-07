# Compile-error fixture: a top-level 'defer' is a script-mode statement
# (it runs when the implicit main exits), so the function definition
# after it is a declaration after the first top-level statement.
import lib.lib

defer println(c"never")


int main():
	return 0
