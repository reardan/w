/* Execute-only memory is a valid CPU operation but outside the checker's
 * current access-permission model. Both creation paths must say incomplete. */
.global _start
.text
_start:
    xor %edi, %edi
    mov $4096, %esi
#if defined(PROTECT)
    mov $3, %edx
#else
    mov $4, %edx
#endif
    mov $34, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    mov $9, %eax
    syscall
    cmp $-4095, %rax
    jae failure
#if defined(PROTECT)
    mov %rax, %rbx
    movb $0xc3, (%rbx)
    mov %rbx, %rdi
    mov $4096, %esi
    mov $4, %edx
    mov $10, %eax
    syscall
    test %eax, %eax
    jnz failure
    call *%rbx
#endif
    xor %edi, %edi
    mov $60, %eax
    syscall
failure:
    mov $1, %edi
    mov $60, %eax
    syscall
.section .note.GNU-stack,"",@progbits
