/* Augments the default linker script (ld -T with INSERT): collects the
   initcall levels in order and the .w_table entries into tables, like a
   kernel's linker script. */
SECTIONS
{
	.w_tables : {
		__w_initcalls_start = .;
		KEEP(*(SORT(.w_initcall.*)))
		__w_initcalls_end = .;
		__w_table_start = .;
		KEEP(*(.w_table))
		__w_table_end = .;
	}
}
INSERT AFTER .data;
