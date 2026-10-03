# --import-root e2e program (tools/import_root_e2e.w): imports root b/'s
# ir_warn, whose warning must name the resolved file inside the root.
import ir_warn


int main():
	return ir_warn_mask() + 1
