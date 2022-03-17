# Machine independent:
void elf_header(int cpu_class):
	/* NIDENT: 16 bytes */
	emit(4, "\x7f\x45\x4c\x46") /* magic */
	emit_int8(cpu_class) /* class: 0: none, 1: 32 bit, 2: 64 bit. */
	emit_int8(1) /* data encoding: 0: none, 1: Least signficiant, 2: Most significant */
	emit_int8(1) /* version: always 1 */
	emit_int8(0) /* OS ABI: 0: none (usually used), 1: HP-UX, 2: NetBSD, 3: Linux */
	emit_int8(0) /* ABI VERSION */
	emit_zeros(7) /* padding */

