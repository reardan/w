# sort_by/sorted_by/min_by/max_by keys follow the sort rule: int-like
# (signed words) or char* (contents) only.
# wbuild: fixture_group=list_it_error_test
# expect_fail
# expect_stderr: list sort_by key requires int-like or char* elements, got 'string'
l := list[int]{1, 2}
l.sort_by(f"{it}")
