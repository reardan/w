#ifndef W_CPP_STDARG_H
#define W_CPP_STDARG_H

typedef __builtin_va_list va_list;
#define va_start(ap, last)
#define va_end(ap)
#define va_arg(ap, type) ((type)0)
#define va_copy(dst, src)

#endif
