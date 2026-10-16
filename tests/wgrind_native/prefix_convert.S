/* Segment overrides before 66 must not turn CBW/CWD into the default
 * wider conversion in the shadow model. Reject until 16-bit forms exist. */
.global _start
.text
_start:
    sub $512, %rsp
#if defined(CWD)
    movzwl (%rsp), %eax
    xor %edx, %edx
#else
    movzbl (%rsp), %eax
#endif
#if defined(GS)
    .byte 0x65
#else
    .byte 0x64
#endif
#if defined(CWD)
    .byte 0x66, 0x99
    test $0x8000, %edx
#else
    .byte 0x66, 0x98
    movzbl %ah, %eax
    test $0x80, %eax
#endif
    jnz finish
finish:
    xor %edi, %edi
    mov $60, %eax
    syscall
.section .note.GNU-stack,"",@progbits
