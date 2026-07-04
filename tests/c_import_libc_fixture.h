__BEGIN_DECLS

typedef unsigned long ci_size_t;
typedef int ci_ssize_t;

typedef struct ci_stream ci_stream;
struct ci_stream {
	int fd;
	ci_size_t count;
};

extern ci_size_t fwrite(const void *__restrict __ptr, ci_size_t __size,
	ci_size_t __n, FILE *__restrict __s)
	__attribute__ ((__warn_unused_result__));
extern int fputs(const char *__restrict __s, FILE *__restrict __stream)
	__THROW __nonnull ((1, 2));
extern int printf(const char *__format, ...);
extern FILE *stdin;

static inline int ci_inline_ignored(int x) { return x; }

__END_DECLS
