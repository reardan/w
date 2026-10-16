/* Freestanding static ELF avoids requiring a libc/loader model to test
 * machine instruction checking inside a separately compiled C object. */
.global _start
.text
_start:
    sub $32, %rsp
#if defined(CLEAN)
    movb $0, (%rsp)
#endif
#if defined(INVALID)
    mov $1, %rdi
#else
    mov %rsp, %rdi
#endif
    call wgrind_precompiled_load
#if defined(MASKED)
    and $0, %eax
#endif
#if defined(UNSUPPORTED)
    ud2
#endif
    test %eax, %eax
    jnz failure
    add $32, %rsp
    xor %edi, %edi
    mov $60, %eax
    syscall
failure:
    mov $5, %edi
    mov $60, %eax
    syscall
.section .note.GNU-stack,"",@progbits
