#ifndef C_IMPORT_PREPROCESS_FIXTURE_H
#define C_IMPORT_PREPROCESS_FIXTURE_H

#include "c_import_preprocess_child.h"

#define CI_PP_FIELD(name) int name;

typedef struct pp_point {
	CI_PP_FIELD(x)
	CI_PP_FIELD(y)
} pp_point;

enum pp_color {
	pp_red = CI_PP_ENUM_VALUE
};

#endif
