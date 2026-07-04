#ifndef C_IMPORT_MACRO_FIXTURE_H
#define C_IMPORT_MACRO_FIXTURE_H

#define CI_HEADER_CONSTANT 77
#define CI_HEADER_OFFSET (CI_HEADER_CONSTANT + 5)
#define CI_HEADER_PASTED CI_HEADER_ ## CONSTANT

typedef int ci_macro_int;

#if defined(CI_HEADER_CONSTANT) && CI_HEADER_OFFSET == 82
typedef int ci_if_type;
#endif

#endif
