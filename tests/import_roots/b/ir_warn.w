# --import-root fixture (tools/import_root_e2e.w): a module from root b/
# with one deliberate warning, so a diagnostic must name the resolved
# file inside the root.
int ir_warn_mask():
	int mask = 0xffffffff
	return mask
