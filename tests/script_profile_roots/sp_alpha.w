# A module in the script_profile_roots import root. Its own import
# resolves outside the root (tests/script_profile_outside.w), which a
# trusted module may do; the profiled file may not name what that
# module declares (scripting.md §5.2 P2b).
import tests.script_profile_outside


int sp_alpha_value():
	return sp_outside_value() + 1
