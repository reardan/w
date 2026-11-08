/* Driver for tests/kernel_codegen/reads.w: every bare read must fault on
   a PROT_NONE page; address arithmetic alone must not. Prints "reads OK". */
#include <stdio.h>
#include <stdint.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

void kr_deref(long *p);
void kr_index(long *p);
void kr_byte(char *p);
void kr_field(void *q);
void kr_global_read(void);
long *kr_global_address(void);
void kr_nothing(long *p);

static void *page;

static void call_deref(void) { kr_deref(page); }
static void call_index(void) { kr_index(page); }
static void call_byte(void) { kr_byte(page); }
static void call_field(void) { kr_field(page); }
static void call_nothing(void) { kr_nothing(page); }

static void call_global(void)
{
	uintptr_t at = (uintptr_t)kr_global_address() & ~(uintptr_t)4095;
	if (mprotect((void *)at, 4096, PROT_NONE) != 0)
		_exit(2);
	kr_global_read();
}

static int faults(void (*f)(void))
{
	pid_t pid = fork();
	if (pid == 0) {
		f();
		_exit(0);
	}
	int status = 0;
	waitpid(pid, &status, 0);
	return WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV;
}

int main(void)
{
	int bad = 0;
	page = mmap(0, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (page == MAP_FAILED)
		return 2;
	struct { const char *name; void (*f)(void); int want; } cases[] = {
		{"kr_deref", call_deref, 1},
		{"kr_index", call_index, 1},
		{"kr_byte", call_byte, 1},
		{"kr_field", call_field, 1},
		{"kr_global_read", call_global, 1},
		{"kr_nothing", call_nothing, 0},
	};
	for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
		if (faults(cases[i].f) != cases[i].want) {
			printf("%s: %s\n", cases[i].name, cases[i].want ? "read dropped" : "unexpected read");
			bad = 1;
		}
	}
	if (!bad)
		puts("reads OK");
	return 0;
}
