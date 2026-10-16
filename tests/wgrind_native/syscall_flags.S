.global _start
.text
_start:
    sub $16, %rsp
#if defined(CLEAN)
    xor %eax, %eax
    cmp %eax, %eax
#else
    mov (%rsp), %rax
    cmp $0, %rax
#endif
    mov $39, %eax
    syscall
    test $64, %r11
    jz failure
    xor %edi, %edi
    mov $60, %eax
    syscall
failure:
    mov $5, %edi
    mov $60, %eax
    syscall
.section .note.GNU-stack,"",@progbits
