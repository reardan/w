/* K&R declarations of real libc exports, plus tzname: the POSIX
   unknown-length extern array shape, resolved by the loader through
   the by-address array import. */

long labs();
long atol(nptr);
extern void tzset(void);
extern char *tzname[];
