# A profiled file calls a module from its import root, which itself uses
# a module from outside the root: the root module's own calls are its
# business.
# wfixture: --profile=script --import-root=tests/script_profile_roots
# reject_stderr: script profile:
import sp_alpha
import sp_alpha as alpha


int main():
	return sp_alpha_value() + alpha.sp_alpha_value() - 84
# wbuild: fixture_group=script_profile_error_test
