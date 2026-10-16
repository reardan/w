.global _start
.section .text
_start:
    sub $16, %rsp
    mov %rsp, vectors(%rip)
    lea 8(%rsp), %rax
    mov %rax, vectors+16(%rip)
#ifdef FAILED
    mov $-1, %rdi
#else
    xor %edi, %edi
#endif
    lea vectors(%rip), %rsi
    mov $2, %edx
    mov $19, %eax
    syscall
#ifdef FAILED
    cmp $-9, %rax
#else
    cmp $3, %rax
#endif
    jne failure
#ifdef FAILED
    movzbl (%rsp), %eax
#else
#ifdef TAIL
    movzbl 9(%rsp), %eax
#else
    movzbl 8(%rsp), %eax
#endif
#endif
    test %eax, %eax
    jz finish
finish:
    xor %edi, %edi
    mov $231, %eax
    syscall
failure:
    mov $1, %edi
    mov $231, %eax
    syscall
.section .data
vectors: .quad 0, 2, 0, 2
.section .note.GNU-stack,"",@progbits
