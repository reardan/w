#!/bin/sh
# Native qualification for the JavaScript/ParserGenerator work. Normal Linux
# targets are source-owned; this supplements the host's tests_darwin selection.
set -eu
cd "$(dirname "$0")/../.."
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo 'run_javascript_tests: requires Apple Silicon macOS' >&2
    exit 1
fi
if [ ! -x bin/wv2_darwin ]; then
    ./wbuild build_darwin
fi
w_js_compiler=bin/wv2_darwin
compile() {
    "$w_js_compiler" arm64_darwin check --json "$1"
    "$w_js_compiler" arm64_darwin "$1" -o "$2.new"
    mv -f "$2.new" "$2"
}
generate() {
    bin/javascript_pg_darwin "$1" -o "$2.next"
    mv -f "$2.next" "$2"
}
compile tools/parser_generator.w bin/javascript_pg_darwin
generate libs/extras/grammars/javascript.pg bin/generated_javascript_parser.w
generate libs/extras/grammars/antlr_to_pg/antlr4.pg bin/generated_antlr4_parser.w
generate libs/extras/grammars/antlr_to_pg/pg.pg bin/generated_pg_parser.w
generate tests/parser_generator/stateful_sample.pg bin/generated_stateful_parser.w
generate tests/parser_generator/stateful_legacy.pg bin/generated_stateful_legacy.w
generate tests/parser_generator/ast_predicate.pg bin/generated_ast_predicate.w
generate libs/extras/grammars/graphql.pg bin/generated_grammars_graphql_parser.w
compile tests/grammars/graphql_demo.w bin/javascript_graphql_darwin
bin/javascript_graphql_darwin
compile tools/antlr_to_pg.w bin/javascript_antlr_darwin
compile tests/antlr_to_pg_strict_test.w bin/javascript_antlr_strict_darwin
bin/javascript_antlr_strict_darwin
sh libs/extras/grammars/antlr_to_pg/testdata/strict/check.sh bin/javascript_antlr_darwin
compile tests/parser_generator/stateful_runtime_test.w bin/javascript_runtime_darwin
bin/javascript_runtime_darwin
compile tests/parser_generator/generated_stateful_test.w bin/javascript_stateful_darwin
bin/javascript_stateful_darwin
for suite in lexical parser validation bindings restrictions ast roundtrip transform text runtime runtime_invoke browser_runtime; do
    compile "tests/javascript/${suite}_test.w" "bin/javascript_${suite}_darwin"
    "bin/javascript_${suite}_darwin"
done
bin/javascript_roundtrip_darwin memory
compile examples/javascript/inspect.w bin/javascript_inspect_darwin
compile examples/javascript/build.w bin/javascript_build_darwin
compile examples/javascript/transform.w bin/javascript_transform_darwin
bin/javascript_build_darwin > bin/javascript_built.mjs
bin/javascript_inspect_darwin --module --check bin/javascript_built.mjs
python3 tools/javascript_unicode.py --check
# The explicit compatibility runner requires the pinned Node release. Missing
# or mismatched Node fails visibly; no tests are silently skipped.
python3 tools/javascript_compatibility.py --parser bin/javascript_inspect_darwin --builder bin/javascript_build_darwin --transform bin/javascript_transform_darwin --runtime-compiler bin/wv2_darwin --runtime-arch arm64_darwin
node --check bin/javascript_built.mjs
node --input-type=module -e 'import { greet } from "./bin/javascript_built.mjs"; if (greet("world") !== "Hello, world") process.exit(1);'
echo 'JavaScript native qualification passed'
