# --import-root e2e program (tools/import_root_e2e.w): 'ir_absent' exists
# in no root and nowhere on the default search path, so the cannot-locate
# diagnostic names the import roots among the places searched.
import ir_mod
import ir_absent


int main():
	return 0
