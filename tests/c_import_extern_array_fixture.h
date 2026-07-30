/* Extern arrays of unknown and known length: imported by address as
   pointer globals (array-to-pointer decay), so indexing reads the
   library's own storage through a loader-filled slot. */

extern const char *const ci_arr_errlist[];
extern int ci_arr_counts[4];
extern char *ci_arr_names[];
extern int ci_arr_matrix[2][3];
extern unsigned short ci_arr_shorts[8];
