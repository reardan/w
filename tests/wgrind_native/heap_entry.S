.global _start
.text
_start:
    mov $8, %edi
    call malloc
    mov %rax, %rbx
#if defined(HEAP_UNDEFINED)
    movb (%rbx), %al
    test %al, %al
    jz after
#endif
#if defined(HEAP_OVERFLOW)
    movb $1, 8(%rbx)
#endif
#if defined(HEAP_CLEAN)
    movb $1, (%rbx)
#endif
after:
    mov %rbx, %rdi
    call free
#if defined(HEAP_UAF)
    movb $1, (%rbx)
#endif
#if defined(HEAP_DOUBLE)
    mov %rbx, %rdi
    call free
#endif
    xor %edi, %edi
    mov $60, %eax
    syscall
.section .note.GNU-stack,"",@progbits
