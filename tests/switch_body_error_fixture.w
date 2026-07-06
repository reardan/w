# Compile-error fixture: a switch body only contains case/default
# clauses; a plain statement between them is rejected.
int main():
	int r = 0
	switch (1):
		case 1:
			r = 10
		r = 20
	return r
