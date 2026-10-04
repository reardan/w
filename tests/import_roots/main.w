# --import-root e2e program (tools/import_root_e2e.w): prints which root
# supplied 'ir_mod', the value of the module only root b/ holds, and the
# word size reported by the per-arch module inside root a/.
import lib.lib
import ir_mod
import ir_only_b
import ir_pkg.__arch__.ir_arch


int main():
	print(c"which=")
	print(ir_which())
	print(c" only_b=")
	print(itoa(ir_only_b()))
	print(c" word=")
	println(itoa(ir_arch_word()))
	return 0
