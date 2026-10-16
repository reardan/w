.global _start
.section .text
_start:
    mov $9, %eax
    xor %edi, %edi
    mov $65536, %esi
    mov $3, %edx
    mov $34, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    lea 65536(%rax), %rsi
#ifdef FORK_FLAGS
    mov $17, %edi
#else
    mov $0x10f00, %edi
#endif
    xor %edx, %edx
    xor %r10d, %r10d
    xor %r8d, %r8d
    mov $56, %eax
    syscall
    test %rax, %rax
    jz child
parent:
    jmp parent
child:
#ifdef BLOCK_FUTEX
    lea word(%rip), %rdi
    xor %esi, %esi
    xor %edx, %edx
    xor %r10d, %r10d
    xor %r8d, %r8d
    xor %r9d, %r9d
    mov $202, %eax
#else
    sub $8, %rsp
    xor %edi, %edi
    mov %rsp, %rsi
    mov $1, %edx
    xor %eax, %eax
#endif
    syscall
    mov $1, %edi
    mov $231, %eax
    syscall
.section .data
word: .quad 0
.section .note.GNU-stack,"",@progbits
