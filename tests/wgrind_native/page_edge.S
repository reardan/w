.global _start
.text
_start:
    jmp edge
.balign 4096
page_start:
    .skip 4080, 0x90
exit_path:
    xor %edi, %edi
    mov $60, %eax
    syscall
    .skip 4094 - (. - page_start), 0x90
edge:
#if defined(TRUNCATED)
    .byte 0x48, 0xb8 /* movabs requires eight more, unmapped bytes */
#else
    jmp exit_path
#endif
.section .note.GNU-stack,"",@progbits
