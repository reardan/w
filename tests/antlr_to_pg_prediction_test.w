# wbuild: target=antlr_to_pg_prediction_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg --strict --stateful --prediction tests/grammars/antlr_prediction/Prediction.g4 -o bin/prediction.pg --parser-name prediction --matchers bin/prediction_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/prediction.pg -o bin/prediction_parser.w"
# wbuild: step="bin/antlr_to_pg --strict --stateful tests/grammars/antlr_prediction/Prediction.g4 -o bin/native_prediction.pg --parser-name native_prediction --matchers bin/native_prediction_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/native_prediction.pg -o bin/native_prediction_parser.w"
# wbuild: step="bin/wv2 --strict tests/grammars/antlr_prediction/runtime.w -o bin/prediction_runtime"
# wbuild: step="bin/prediction_runtime"
# wbuild: step="bin/wv2 x64 --strict tests/grammars/antlr_prediction/runtime.w -o bin/prediction_runtime_x64"
# wbuild: step="bin/prediction_runtime_x64"
import lib.assert


int main():
	assert1(1)
	return 0
