/* Minimal stdarg.h for c_import. Supports the glibc __need___va_list
   protocol used by stdio.h and friends. */

#ifndef __GNUC_VA_LIST
#define __GNUC_VA_LIST
typedef __builtin_va_list __gnuc_va_list;
#endif

#ifdef __need___va_list
#undef __need___va_list
#else

#ifndef W_CPP_STDARG_H
#define W_CPP_STDARG_H
#ifndef _VA_LIST_DEFINED
#define _VA_LIST_DEFINED
typedef __gnuc_va_list va_list;
#endif
#define va_start(ap, last)
#define va_end(ap)
#define va_arg(ap, type) ((type)0)
#define va_copy(dst, src)
#endif

#endif
