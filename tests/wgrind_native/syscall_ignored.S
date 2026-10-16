.global _start
.text
_start:
    mov 16(%rsp), %r13
    sub $16, %rsp
    /* open ignores mode without O_CREAT/O_TMPFILE. */
    mov (%rsp), %rdx
    mov %r13, %rdi
    xor %esi, %esi
    mov $2, %eax
    syscall
    cmp $0, %rax
    jl failure
    mov %rax, %rdi
    mov $3, %eax
    syscall
    /* An int file descriptor ignores its undefined upper 32 bits. */
    mov (%rsp), %rdi
    shl $32, %rdi
    or $1, %rdi
    mov %r13, %rsi
    xor %edx, %edx
    mov $1, %eax
    syscall
    /* Anonymous mappings ignore fd and the offset's page number. */
    mov (%rsp), %r8
    mov (%rsp), %r9
    shl $12, %r9
    xor %edi, %edi
    mov $4096, %esi
    mov $3, %edx
    mov $34, %r10d
    mov $9, %eax
    syscall
    cmp $-4095, %rax
    jae failure
    xor %edi, %edi
    mov $60, %eax
    syscall
failure:
    mov $1, %edi
    mov $60, %eax
    syscall
.section .note.GNU-stack,"",@progbits
