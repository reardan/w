# Types for import_alias_type_test: resolved through the qualified
# 'alias.TypeName' spelling in type positions (import ... as).
struct alias_point:
	int x
	int y

struct alias_box:
	alias_point corner
	int depth

type alias_word = int

int alias_type_helper_value():
	return 1337
