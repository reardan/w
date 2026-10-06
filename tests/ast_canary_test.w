# Cheap required-AST canary for the ordinary `./wbuild tests` run.
#
# The full required-mode corpus is `./wbuild ast_expression_suite`
# (tools/wast_audit.w), a slow serial leg of its own in CI. These two
# targets keep the compiler's own source on the AST path between suite
# runs: each host compiler checks w.w with a retained forest and rejects
# any runtime expression that would still fall back to the streaming
# parser. ast_canary_test runs the 32-bit host (bin/wv2) for the x86
# target; ast_canary_64_test runs the 64-bit host (bin/wv2_64) for the
# x64 target. A check writes no image, so neither step touches bin/.
# There is no program here: the file only owns the two targets below.
#
# wbuild: target=ast_canary_test tag=tests dep=wv2
# wbuild: step="bin/wv2 check --quiet --ast-retain --ast-required w.w"
# wbuild: target=ast_canary_64_test tag=tests_x64 dep=build_x64
# wbuild: step="bin/wv2_64 x64 check --quiet --ast-retain --ast-required w.w"
