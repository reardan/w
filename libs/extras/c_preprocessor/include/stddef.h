/* Minimal stddef.h for c_import, mirroring the glibc __need_* protocol:
   a bare include defines everything; defining __need_X first requests just
   that item. Each item keeps its own guard because this file is included
   many times with different __need_* sets. */

#if defined __need_size_t || defined __need_NULL || defined __need_wchar_t || defined __need_ptrdiff_t || defined __need_wint_t
#define W_CPP_STDDEF_PARTIAL
#endif

#if defined __need_size_t || !defined W_CPP_STDDEF_PARTIAL
#ifndef W_CPP_STDDEF_SIZE_T
#define W_CPP_STDDEF_SIZE_T
typedef unsigned long size_t;
#endif
#undef __need_size_t
#endif

#if defined __need_ptrdiff_t || !defined W_CPP_STDDEF_PARTIAL
#ifndef W_CPP_STDDEF_PTRDIFF_T
#define W_CPP_STDDEF_PTRDIFF_T
typedef long ptrdiff_t;
#endif
#undef __need_ptrdiff_t
#endif

#if defined __need_wchar_t || !defined W_CPP_STDDEF_PARTIAL
#ifndef W_CPP_STDDEF_WCHAR_T
#define W_CPP_STDDEF_WCHAR_T
typedef int wchar_t;
#endif
#undef __need_wchar_t
#endif

#if defined __need_wint_t || !defined W_CPP_STDDEF_PARTIAL
#ifndef W_CPP_STDDEF_WINT_T
#define W_CPP_STDDEF_WINT_T
typedef unsigned int wint_t;
#endif
#undef __need_wint_t
#endif

#ifndef NULL
#define NULL ((void*)0)
#endif
#undef __need_NULL

#undef W_CPP_STDDEF_PARTIAL
