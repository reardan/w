.global _start
.text
_start:
    mov $8, %edi
    call malloc
#if defined(LEAK_REACHABLE)
    mov %rax, saved(%rip)
#endif
#if defined(LEAK_POSSIBLE)
    add $1, %rax
    mov %rax, saved(%rip)
#endif
    xor %ebx, %ebx
    xor %edi, %edi
    mov $60, %eax
    syscall
.data
saved:
    .quad 0
.section .note.GNU-stack,"",@progbits
