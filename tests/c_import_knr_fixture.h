/* Old-style (K&R) declaration shapes: unprototyped declarations import
   as variadic functions with zero fixed parameters; a K&R definition
   (declaration list between declarator and body) parses and is ignored
   like any other function definition in an imported header. */

int ci_knr_no_params();
extern int ci_knr_extern_no_params();
int ci_knr_ident_params(a, b);
extern char *ci_knr_ptr_ret(name);
long ci_knr_long_ret();

int ci_knr_definition(x, y)
	int x;
	char *y;
{
	return x + 1;
}
