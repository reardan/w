/*
print/println of a float32 (grammar/print_builtin.w): the shortest
text that parses back to the same value, spelled like lib/format.w's
ftoa (lib/float_text.w). Kept apart from structures/prelude.w so only
programs that print a float import the formatter, and without
importing lib.format so it never collides with programs that c_import
libc's printf (lib/format.w defines a W printf).

Like the other __w_ runtimes this file must stay compatible with the
oldest compiler that may compile it: plain W only.
*/
import lib.lib
import lib.float_text


void __w_print_float32(float f):
	int32* p = cast(int32*, &f)
	char* s = float_text_shortest(*p, 32)
	write(1, s, strlen(s))
	free(s)
