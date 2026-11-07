/* Bare startup for tests/kernel_codegen_test.w: no libc, built with
   -mno-red-zone like kernel code, so every byte below %rsp is dead at
   every instruction of the linked program. Prints kc_main's checksum and the
   deepest frame-pointer chain kc_c_unwind walked. */
long kc_main(void);
long kc_callback(long a, long b);

extern char __executable_start[], etext[];
static long kc_max_frames, kc_bad_frames;

/* Walk the frame-pointer chain the way a kernel's frame-pointer
   unwinder does: [fp] is the caller's fp and [fp+8] a return address
   inside .text, up to _start's frame (whose saved fp is 0). */
long kc_c_unwind(void)
{
	void **fp = __builtin_frame_address(0);
	long n = 0;
	while (fp[0] != 0) {
		char *ret = fp[1];
		if (ret < __executable_start || ret >= etext || n > 10000) {
			kc_bad_frames++;
			break;
		}
		fp = (void **)fp[0];
		n++;
	}
	if (n > kc_max_frames)
		kc_max_frames = n;
	return n;
}

long kc_c_mix(long a, long b, long c, long d, long e, long f, long g, long h)
{
	return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + kc_callback(a + 5, (h & 3) + 1);
}

static void kc_write(const char *s, long n)
{
	long r;
	__asm__ volatile("syscall" : "=a"(r) : "a"(1L), "D"(1L), "S"(s), "d"(n) : "rcx", "r11", "memory");
}

void _start(void)
{
	char buf[32];
	long v = kc_main();
	int neg = v < 0;
	unsigned long u = neg ? -(unsigned long)v : (unsigned long)v;
	int i = 31;
	buf[i--] = '\n';
	do {
		buf[i--] = (char)('0' + u % 10);
		u /= 10;
	} while (u);
	if (neg)
		buf[i--] = '-';
	kc_write(buf + i + 1, 31 - i);
	/* the deepest chain walked: a single digit or two */
	char frames[16] = "frames ";
	frames[7] = (char)('0' + kc_max_frames / 10);
	frames[8] = (char)('0' + kc_max_frames % 10);
	frames[9] = '\n';
	kc_write(frames, 10);
	if (kc_bad_frames)
		kc_write("bad frame chain\n", 16);
	__asm__ volatile("syscall" : : "a"(60L), "D"(0L));
	for (;;)
		;
}
