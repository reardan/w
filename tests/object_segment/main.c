/* Host for tests/object_segment/library.w (tests/object_segment_test.w):
   a per-CPU area in the kernel's style. seg_hot, flat_hot, counter and
   counters are the template; the %gs base is pointed at a copy of the
   page that holds them (arch_prctl(ARCH_SET_GS)), so a %gs-relative
   access at a variable's own address reaches the copy and the template
   stays untouched. gcc's own __seg_gs accesses cross-check W's. Built
   with -fno-stack-protector: the %fs test briefly replaces glibc's
   thread pointer, so nothing in between may touch TLS. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <asm/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

struct percpu_hot {
	void *current;
	int32_t preempt_count;
	int32_t cpu_number;
	uint16_t flags;
	int16_t delta;
	uint8_t small;
	int8_t tiny;
	int64_t wide;
};

#define AREA 8192
__attribute__((aligned(4096))) struct {
	struct percpu_hot seg_hot;
	struct percpu_hot flat_hot;
	int64_t counter;
	int64_t counters[4];
} template_area;
#define seg_hot template_area.seg_hot
extern struct percpu_hot seg_hot_sym __asm__("seg_hot");
extern struct percpu_hot flat_hot_sym __asm__("flat_hot");
extern int64_t counter_sym __asm__("counter");
extern int64_t counters_sym[] __asm__("counters");
__asm__(".globl seg_hot, flat_hot, counter, counters\n"
	".set seg_hot, template_area\n"
	".set flat_hot, template_area + 40\n"
	".set counter, template_area + 80\n"
	".set counters, template_area + 88\n");

int32_t w_cpu_number(void);
void *w_current(void);
void w_set_current(void *);
int32_t w_preempt_add(int32_t);
int64_t w_widths(void);
void w_store_widths(int64_t);
int64_t w_counter(void);
void w_set_counter(int64_t);
void *w_current_by_pointer(void);
int64_t w_sum_counters(long);
int32_t w_fs_cpu_number(void);
uint64_t w_seg_hot_offset(void);

static unsigned char copy[AREA] __attribute__((aligned(4096)));
static int failures;

static void check(const char *what, long got, long want) {
	if (got != want) {
		printf("FAIL %s: got %ld, want %ld\n", what, got, want);
		failures++;
	}
}

static long arch_prctl(long code, unsigned long addr) {
	long ret;
	__asm__ volatile("syscall" : "=a"(ret) : "a"((long)SYS_arch_prctl), "D"(code), "S"(addr) : "rcx", "r11", "memory");
	return ret;
}

/* The copy's view of a template object. */
#define IN_COPY(type, sym) ((type *)(copy + ((char *)&(sym) - (char *)&template_area)))

/* gcc's own segment accesses, for the cross-check. */
static int32_t c_seg_cpu_number(void) {
	return *(volatile int32_t __seg_gs *)(uintptr_t)&seg_hot_sym.cpu_number;
}

static int32_t fs_call(void) {
	unsigned long saved;
	int32_t value;
	arch_prctl(ARCH_GET_FS, (unsigned long)&saved);
	arch_prctl(ARCH_SET_FS, (unsigned long)copy - (unsigned long)&template_area);
	value = w_fs_cpu_number();
	arch_prctl(ARCH_SET_FS, saved);
	return value;
}

int main(void) {
	struct percpu_hot *hot = IN_COPY(struct percpu_hot, seg_hot_sym);
	struct percpu_hot *flat = IN_COPY(struct percpu_hot, flat_hot_sym);
	int64_t *count = IN_COPY(int64_t, counter_sym);
	int64_t *counts = IN_COPY(int64_t, counters_sym[0]);
	memset(&template_area, 0x5a, sizeof template_area);
	memset(copy, 0, sizeof copy);
	hot->cpu_number = 3;
	hot->preempt_count = 10;
	hot->current = &failures;
	flat->current = &copy;
	flat->flags = 0xfff0;
	flat->delta = -7;
	flat->small = 200;
	flat->tiny = -100;
	flat->wide = 1LL << 40;
	flat->cpu_number = 2;
	*count = 77;
	for (int i = 0; i < 4; i++) counts[i] = 100 + i;
	if (arch_prctl(ARCH_SET_GS, (unsigned long)copy - (unsigned long)&template_area) != 0) {
		printf("FAIL arch_prctl(ARCH_SET_GS)\n");
		return 1;
	}
	check("gcc cpu_number", c_seg_cpu_number(), 3);
	check("cpu_number", w_cpu_number(), 3);
	check("current", (long)w_current(), (long)&failures);
	w_set_current(&copy);
	check("set current", (long)hot->current, (long)&copy);
	check("preempt add", w_preempt_add(5), 16);
	check("preempt stored", hot->preempt_count, 16);
	check("widths", w_widths(), 0xfff0 - 7 + 200 - 100 + (1LL << 40));
	w_store_widths(9);
	check("store flags", flat->flags, 9);
	check("store delta", flat->delta, -9);
	check("store small", flat->small, 10);
	check("store tiny", flat->tiny, -10);
	check("store wide", flat->wide, 9000);
	check("counter", w_counter(), 77);
	w_set_counter(-5);
	check("set counter", *count, -5);
	check("pointer object", (long)w_current_by_pointer(), (long)&copy);
	check("sum", w_sum_counters(4), 406);
	check("sum stored", counts[3], 104);
	check("fs", fs_call(), 7);
	check("fs store", flat->tiny, 5);
	check("offset", (long)w_seg_hot_offset(), (long)&seg_hot_sym.preempt_count);
	/* the template is untouched: every access went through the segment */
	check("template counter", counter_sym, 0x5a5a5a5a5a5a5a5aLL);
	check("template cpu", seg_hot_sym.cpu_number, 0x5a5a5a5a);
	if (failures) return 1;
	printf("object segment OK\n");
	return 0;
}
